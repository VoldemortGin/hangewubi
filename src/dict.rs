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
    pub fn load_from_str(&mut self, content: &str) -> usize {
        let mut count = 0;
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
            let weight = parts.get(2).and_then(|w| w.parse().ok()).unwrap_or(100);

            self.add_entry(code, text, weight);
            count += 1;
        }
        count
    }

    /// 添加单个词条
    pub fn add_entry(&mut self, code: String, text: String, weight: u32) {
        let index = self.entries.len();
        self.trie.insert(&code, index);
        self.exact_map.entry(code.clone()).or_default().push(index);
        self.entries.push(DictEntry { code, text, weight });
    }

    /// 精确匹配查询
    pub fn lookup_exact(&self, code: &str) -> Vec<&DictEntry> {
        let mut results: Vec<&DictEntry> = self
            .exact_map
            .get(code)
            .map(|indices| indices.iter().map(|&i| &self.entries[i]).collect())
            .unwrap_or_default();

        // 按权重降序排列
        results.sort_by(|a, b| b.weight.cmp(&a.weight));
        results
    }

    /// 前缀匹配查询
    pub fn lookup_prefix(&self, prefix: &str) -> Vec<&DictEntry> {
        let indices = self.trie.prefix_match(prefix);
        let mut results: Vec<&DictEntry> = indices.iter().map(|&i| &self.entries[i]).collect();
        results.sort_by(|a, b| b.weight.cmp(&a.weight));
        results
    }

    /// Z键万能键查询
    pub fn lookup_wildcard(&self, pattern: &str) -> Vec<&DictEntry> {
        let indices = self.trie.wildcard_match(pattern);
        let mut results: Vec<&DictEntry> = indices.iter().map(|&i| &self.entries[i]).collect();
        results.sort_by(|a, b| b.weight.cmp(&a.weight));
        results
    }

    /// 查询候选词（综合方法）
    /// 如果 pattern 含 z 且启用万能键，用通配符匹配
    /// 否则先精确匹配，再前缀匹配补充
    pub fn lookup(&self, input: &str, wildcard_enabled: bool, max_results: usize) -> Vec<&DictEntry> {
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
            if entry.code.len() == input.len() {
                if seen.insert((&entry.code, &entry.text)) {
                    results.push(*entry);
                }
            }
        }

        // 再加前缀匹配（编码长度 > 输入长度）
        for entry in &prefix {
            if entry.code.len() > input.len() {
                if seen.insert((&entry.code, &entry.text)) {
                    results.push(*entry);
                }
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
}
