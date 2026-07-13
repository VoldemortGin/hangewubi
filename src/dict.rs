use crate::trie::Trie;
use std::collections::HashMap;
use std::path::Path;

/// 候选词条目
#[derive(Debug, Clone)]
pub struct DictEntry {
    /// 五笔编码
    pub code: String,
    /// 汉字/词组
    pub text: String,
    /// 权重（越大越靠前）
    pub weight: u32,
    /// 码表文件中的出现序（用于等权重时的确定性排序）
    pub origin_index: usize,
}

/// 码表引擎：管理五笔编码到汉字的映射
#[derive(Debug)]
pub struct DictEngine {
    /// 所有词条（按索引引用）
    entries: Vec<DictEntry>,
    /// 精确匹配索引：编码 → 词条索引列表
    exact_map: HashMap<String, Vec<usize>>,
    /// 前缀匹配 Trie
    trie: Trie,
}

impl DictEngine {
    pub fn new() -> Self {
        Self {
            entries: Vec::new(),
            exact_map: HashMap::new(),
            trie: Trie::new(),
        }
    }

    /// 从 TSV 文件加载码表
    /// 格式：编码<TAB>汉字<TAB>权重
    /// 以 # 开头的行为注释
    pub fn load_from_file(&mut self, path: &Path) -> Result<usize, Box<dyn std::error::Error>> {
        let content = std::fs::read_to_string(path)?;
        let count = self.load_from_str(&content);
        Ok(count)
    }

    /// 从字符串加载码表
    ///
    /// 权重超过 [`crate::engine::MAX_DICT_WEIGHT`] 的行会被钳制到该上限，
    /// 固化"精确匹配加成 / 用户词典加成 > 任何码表词频"的排序层级（见 engine.rs 顶部）。
    pub fn load_from_str(&mut self, content: &str) -> usize {
        let mut count = 0;
        #[cfg(debug_assertions)]
        let mut clamped = 0usize;
        for line in content.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }

            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() < 2 {
                continue;
            }

            let code = parts[0].to_string();
            let text = parts[1].to_string();
            let raw_weight: u32 = parts.get(2).and_then(|w| w.parse().ok()).unwrap_or(100);
            // 钳制到码表权重上限，防换码表（权重 >MAX_DICT_WEIGHT）静默破坏排序层级。
            let weight = raw_weight.min(crate::engine::MAX_DICT_WEIGHT);
            #[cfg(debug_assertions)]
            if raw_weight > crate::engine::MAX_DICT_WEIGHT {
                clamped += 1;
            }

            self.add_entry(code, text, weight);
            count += 1;
        }
        #[cfg(debug_assertions)]
        if clamped > 0 {
            eprintln!(
                "[dict] 已钳制 {clamped} 条超过 MAX_DICT_WEIGHT={} 的码表权重",
                crate::engine::MAX_DICT_WEIGHT
            );
        }
        count
    }

    /// 添加单个词条
    pub fn add_entry(&mut self, code: String, text: String, weight: u32) {
        let index = self.entries.len();
        self.trie.insert(&code, index);
        self.exact_map.entry(code.clone()).or_default().push(index);
        self.entries.push(DictEntry {
            code,
            text,
            weight,
            origin_index: index,
        });
    }

    /// 精确匹配查询
    pub fn lookup_exact(&self, code: &str) -> Vec<&DictEntry> {
        let mut results: Vec<&DictEntry> = self
            .exact_map
            .get(code)
            .map(|indices| indices.iter().map(|&i| &self.entries[i]).collect())
            .unwrap_or_default();

        // 按权重降序排列
        results.sort_by(|a, b| {
            b.weight
                .cmp(&a.weight)
                .then(a.code.len().cmp(&b.code.len()))
                .then(a.origin_index.cmp(&b.origin_index))
        });
        results
    }

    /// 前缀匹配查询
    pub fn lookup_prefix(&self, prefix: &str) -> Vec<&DictEntry> {
        let indices = self.trie.prefix_match(prefix);
        let mut results: Vec<&DictEntry> = indices.iter().map(|&i| &self.entries[i]).collect();
        results.sort_by(|a, b| {
            b.weight
                .cmp(&a.weight)
                .then(a.code.len().cmp(&b.code.len()))
                .then(a.origin_index.cmp(&b.origin_index))
        });
        results
    }

    /// Z键万能键查询
    pub fn lookup_wildcard(&self, pattern: &str) -> Vec<&DictEntry> {
        let indices = self.trie.wildcard_match(pattern);
        let mut results: Vec<&DictEntry> = indices.iter().map(|&i| &self.entries[i]).collect();
        results.sort_by(|a, b| {
            b.weight
                .cmp(&a.weight)
                .then(a.code.len().cmp(&b.code.len()))
                .then(a.origin_index.cmp(&b.origin_index))
        });
        results
    }

    /// 查询候选词（综合方法）
    /// 如果 pattern 含 z 且启用万能键，用通配符匹配
    /// 否则先精确匹配，再前缀匹配补充
    pub fn lookup(
        &self,
        input: &str,
        wildcard_enabled: bool,
        max_results: usize,
    ) -> Vec<&DictEntry> {
        if input.is_empty() {
            return vec![];
        }

        if wildcard_enabled && input.contains('z') {
            let mut results = self.lookup_wildcard(input);
            results.truncate(max_results);
            return results;
        }

        // 精确匹配放前面
        let exact = self.lookup_exact(input);
        if !exact.is_empty() && exact.len() >= max_results {
            return exact.into_iter().take(max_results).collect();
        }

        // 用前缀匹配补充
        let prefix = self.lookup_prefix(input);
        let mut results = Vec::new();
        let mut seen = std::collections::HashSet::new();

        // 先加精确匹配（编码长度 == 输入长度）
        for entry in &prefix {
            if entry.code.len() == input.len() && seen.insert((&entry.code, &entry.text)) {
                results.push(*entry);
            }
        }

        // 再加前缀匹配（编码长度 > 输入长度）
        for entry in &prefix {
            if entry.code.len() > input.len() && seen.insert((&entry.code, &entry.text)) {
                results.push(*entry);
            }
            if results.len() >= max_results {
                break;
            }
        }

        results.truncate(max_results);
        results
    }

    /// 获取总词条数
    pub fn entry_count(&self) -> usize {
        self.entries.len()
    }
}

impl Default for DictEngine {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_dict() -> DictEngine {
        let mut dict = DictEngine::new();
        dict.load_from_str(
            "# 测试码表
a\t工\t9999
aa\t式\t5000
aad\t芝\t2000
aadk\t芽\t1500
aadn\t萌\t1200
ab\t节\t4000
abc\t苛\t1000
b\t了\t9998
bb\t子\t5500
",
        );
        dict
    }

    #[test]
    fn test_load_dict() {
        let dict = sample_dict();
        assert_eq!(dict.entry_count(), 9);
    }

    #[test]
    fn test_exact_match() {
        let dict = sample_dict();
        let results = dict.lookup_exact("a");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].text, "工");
    }

    #[test]
    fn test_prefix_match() {
        let dict = sample_dict();
        let results = dict.lookup_prefix("aa");
        assert_eq!(results.len(), 4); // aa, aad, aadk, aadn
        // 应按权重排序
        assert_eq!(results[0].text, "式");
    }

    #[test]
    fn test_lookup_comprehensive() {
        let dict = sample_dict();
        let results = dict.lookup("a", false, 5);
        // 精确匹配 "工" 应排第一
        assert_eq!(results[0].text, "工");
        assert!(results.len() <= 5);
    }

    #[test]
    fn test_wildcard_lookup() {
        let dict = sample_dict();
        let results = dict.lookup("az", true, 10);
        // az 匹配 aa, ab
        assert!(results.iter().any(|e| e.text == "式"));
        assert!(results.iter().any(|e| e.text == "节"));
    }

    #[test]
    fn test_empty_input() {
        let dict = sample_dict();
        let results = dict.lookup("", false, 5);
        assert!(results.is_empty());
    }

    #[test]
    fn test_no_match() {
        let dict = sample_dict();
        let results = dict.lookup_exact("xyz");
        assert!(results.is_empty());
    }

    #[test]
    fn test_weight_clamped_to_max() {
        // 超过 MAX_DICT_WEIGHT 的码表权重在加载时被钳制到上限
        let mut dict = DictEngine::new();
        dict.load_from_str("a\t工\t99999\n");
        let entries = dict.lookup_exact("a");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].weight, crate::engine::MAX_DICT_WEIGHT);
    }

    #[test]
    fn test_weight_below_max_untouched() {
        // 未超限的权重原样保留
        let mut dict = DictEngine::new();
        dict.load_from_str("a\t工\t500\n");
        assert_eq!(dict.lookup_exact("a")[0].weight, 500);
    }

    #[test]
    fn test_deterministic_equal_weight_ordering() {
        // 5 个等权重、跨 trie 分支的重码（共享前缀 a），验证多次重建+查询的
        // 候选顺序完全一致，且等权重时按 origin_index（码表出现序）稳定排序。
        let content = "ab\t波\t100
ac\t茨\t100
ad\t德\t100
ae\t鹅\t100
af\t佛\t100
";
        let order = || {
            let mut dict = DictEngine::new();
            dict.load_from_str(content);
            dict.lookup("a", false, 10)
                .into_iter()
                .map(|e| e.text.clone())
                .collect::<Vec<String>>()
        };
        let expected = vec![
            "波".to_string(),
            "茨".to_string(),
            "德".to_string(),
            "鹅".to_string(),
            "佛".to_string(),
        ];
        let first = order();
        assert_eq!(first, expected);
        // 多次重建查询结果必须逐项一致（不受 HashMap 迭代序漂移影响）
        for _ in 0..50 {
            assert_eq!(order(), first);
        }
    }
}
