use crate::trie::Trie;
use std::collections::HashMap;
use std::path::Path;
use std::sync::OnceLock;

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
    /// 反查索引：词条文本 → (最短编码, 最长编码) 的词条索引（首次反查时懒构建，add_entry 时失效）
    code_index: OnceLock<HashMap<String, (usize, usize)>>,
    /// 联想索引：首字 → 以该字开头的多字词条索引（首次联想时懒构建，add_entry 时失效）
    phrase_index: OnceLock<HashMap<char, Vec<usize>>>,
}

impl DictEngine {
    pub fn new() -> Self {
        Self {
            entries: Vec::new(),
            exact_map: HashMap::new(),
            trie: Trie::new(),
            code_index: OnceLock::new(),
            phrase_index: OnceLock::new(),
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
        self.code_index = OnceLock::new();
        self.phrase_index = OnceLock::new();
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

    /// 反查索引：最短编码等长取权重高者、最长编码等长取权重高者，再取先出现者
    fn code_index(&self) -> &HashMap<String, (usize, usize)> {
        self.code_index.get_or_init(|| {
            let mut map: HashMap<String, (usize, usize)> = HashMap::new();
            for (i, e) in self.entries.iter().enumerate() {
                let key = |k: &DictEntry| (k.code.len(), std::cmp::Reverse(k.weight));
                match map.get_mut(&e.text) {
                    None => {
                        map.insert(e.text.clone(), (i, i));
                    }
                    Some((short, long)) => {
                        if key(e) < key(&self.entries[*short]) {
                            *short = i;
                        }
                        let old = &self.entries[*long];
                        if (e.code.len(), e.weight) > (old.code.len(), old.weight) {
                            *long = i;
                        }
                    }
                }
            }
            map
        })
    }

    /// 反查：词条文本对应的最短编码（等长取权重高者，再取先出现者）
    pub fn shortest_code_of(&self, text: &str) -> Option<&str> {
        self.code_index()
            .get(text)
            .map(|&(i, _)| self.entries[i].code.as_str())
    }

    /// 反查：词条文本对应的全码，即码表中该文本最长的编码（等长取权重高者，再取先出现者）
    pub fn full_code_of(&self, text: &str) -> Option<&str> {
        self.code_index()
            .get(text)
            .map(|&(_, i)| self.entries[i].code.as_str())
    }

    /// 联想：文本以 `prefix` 开头且比它长的词条（码表出现序；同词多码会重复出现）
    pub fn words_with_prefix(&self, prefix: &str) -> Vec<&DictEntry> {
        let Some(first) = prefix.chars().next() else {
            return vec![];
        };
        let index = self.phrase_index.get_or_init(|| {
            let mut map: HashMap<char, Vec<usize>> = HashMap::new();
            for (i, e) in self.entries.iter().enumerate() {
                let mut chars = e.text.chars();
                if let (Some(c), Some(_)) = (chars.next(), chars.next()) {
                    map.entry(c).or_default().push(i);
                }
            }
            map
        });
        index
            .get(&first)
            .into_iter()
            .flatten()
            .map(|&i| &self.entries[i])
            .filter(|e| e.text.len() > prefix.len() && e.text.starts_with(prefix))
            .collect()
    }

    /// 按五笔 86 词组规则为词计算编码：
    /// 单字取全码；二字词各取前两码；三字词前两字各取首码、第三字取前两码；
    /// 四字及以上取第一、二、三字及末字的首码。
    /// 含非汉字、任一字码表查不到、或全码位数不足所需取码数时返回 None（不猜）。
    pub fn phrase_code(&self, word: &str) -> Option<String> {
        let chars: Vec<char> = word.chars().collect();
        if chars.is_empty() || !chars.iter().all(|&c| crate::charset::is_han(c)) {
            return None;
        }
        // (取码的字序号, 取前几码)
        let picks: Vec<(usize, usize)> = match chars.len() {
            1 => return self.full_code_of(word).map(str::to_string),
            2 => vec![(0, 2), (1, 2)],
            3 => vec![(0, 1), (1, 1), (2, 2)],
            n => vec![(0, 1), (1, 1), (2, 1), (n - 1, 1)],
        };
        let mut code = String::new();
        for (i, take) in picks {
            let full = self.full_code_of(chars[i].encode_utf8(&mut [0u8; 4]))?;
            code.push_str(full.get(..take).filter(|p| p.len() == take)?);
        }
        Some(code)
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

        // 再加前缀匹配（编码长度 > 输入长度）：只补充全为汉字的条目，
        // 假名、希腊字母等符号条目只在输入完整编码时（精确匹配）出现
        for entry in &prefix {
            if entry.code.len() > input.len()
                && entry.text.chars().all(crate::charset::is_han)
                && seen.insert((&entry.code, &entry.text))
            {
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
    /// 码表中是否存在 `lookup` 会匹配到的条目（与 `lookup` 同口径：含 z 通配时走等长通配，否则前缀）
    pub fn has_prefix(&self, input: &str, wildcard_enabled: bool) -> bool {
        if input.is_empty() {
            return false;
        }
        if wildcard_enabled && input.contains('z') {
            return !self.trie.wildcard_match(input).is_empty();
        }
        self.trie.has_prefix(input)
    }

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
    fn test_shortest_code_of() {
        let mut dict = DictEngine::new();
        dict.load_from_str("vbg\t好\t10\nvb\t好\t10\nvbf\t妇\t5\n");
        assert_eq!(dict.shortest_code_of("好"), Some("vb"));
        assert_eq!(dict.shortest_code_of("妇"), Some("vbf"));
        assert_eq!(dict.shortest_code_of("无"), None);
        dict.add_entry("v".into(), "好".into(), 1);
        assert_eq!(dict.shortest_code_of("好"), Some("v"));
    }

    fn phrase_dict() -> DictEngine {
        let mut dict = DictEngine::new();
        // 晗=jfwk 戈=agnt 五=gghg 笔=ttfn 输=lwgj 入=ty（只有二码：取首码够、取二码够）
        // 一=g / ggll（一级简码 + 全码）
        dict.load_from_str(
            "j\t晗\t1\njfwk\t晗\t1\na\t戈\t10\nagnt\t戈\t10\ngg\t五\t1\ngghg\t五\t1\n\
             t\t笔\t1\nttfn\t笔\t1\nlwgj\t输\t1\nty\t入\t1\ng\t一\t20\nggll\t一\t10\n\
             k\t口\t1\n",
        );
        dict
    }

    #[test]
    fn test_full_code_of_takes_longest() {
        let dict = phrase_dict();
        assert_eq!(dict.full_code_of("一"), Some("ggll"));
        assert_eq!(dict.shortest_code_of("一"), Some("g"));
        assert_eq!(dict.full_code_of("入"), Some("ty"));
        assert_eq!(dict.full_code_of("无"), None);
    }

    #[test]
    fn test_phrase_code_rules() {
        let dict = phrase_dict();
        // 单字：全码
        assert_eq!(dict.phrase_code("晗").as_deref(), Some("jfwk"));
        // 二字：各取前两码
        assert_eq!(dict.phrase_code("晗戈").as_deref(), Some("jfag"));
        assert_eq!(dict.phrase_code("一入").as_deref(), Some("ggty"));
        // 三字：首码 + 首码 + 前两码
        assert_eq!(dict.phrase_code("晗戈五").as_deref(), Some("jagg"));
        // 四字：各取首码
        assert_eq!(dict.phrase_code("晗戈五笔").as_deref(), Some("jagt"));
        // 五字及以上：一、二、三、末字首码
        assert_eq!(dict.phrase_code("晗戈五笔输入").as_deref(), Some("jagt"));
        assert_eq!(dict.phrase_code("晗戈五一笔输").as_deref(), Some("jagl"));
    }

    #[test]
    fn test_phrase_code_failures() {
        let dict = phrase_dict();
        // 查不到的字
        assert_eq!(dict.phrase_code("晗龘"), None);
        assert_eq!(dict.phrase_code("龘"), None);
        // 含非汉字
        assert_eq!(dict.phrase_code("晗a"), None);
        assert_eq!(dict.phrase_code("晗，戈"), None);
        assert_eq!(dict.phrase_code(""), None);
        // 全码位数不足所需取码数（口 只有一码，二字词需取两码）
        assert_eq!(dict.phrase_code("口晗"), None);
        // 只需首码时不受影响
        assert_eq!(dict.phrase_code("口晗戈五").as_deref(), Some("kjag"));
    }

    #[test]
    fn test_phrase_code_matches_real_dict() {
        // 真实码表：规则算出的编码与码表收录的词组编码一致
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("data/wubi86.txt");
        let mut dict = DictEngine::new();
        dict.load_from_file(&path).unwrap();
        for (word, code) in [
            ("中国", "khlg"),
            ("输入法", "ltif"),
            ("中华人民共和国", "kwwl"),
        ] {
            assert_eq!(dict.phrase_code(word).as_deref(), Some(code), "{word}");
        }
        assert_eq!(dict.phrase_code("晗戈").as_deref(), Some("jwag"));
    }

    #[test]
    fn test_words_with_prefix_and_invalidation() {
        let mut dict = DictEngine::new();
        dict.load_from_str("a\t中\t9\naa\t中国\t8\nkhlg\t中国\t7\nb\t国中\t6\nc\t中国人\t5\n");
        let texts = |d: &DictEngine, p: &str| -> Vec<String> {
            d.words_with_prefix(p)
                .iter()
                .map(|e| e.text.clone())
                .collect()
        };
        assert_eq!(texts(&dict, "中"), ["中国", "中国", "中国人"]);
        assert_eq!(texts(&dict, "中国"), ["中国人"]);
        assert!(texts(&dict, "中国人").is_empty());
        assert!(texts(&dict, "").is_empty());
        // 新增词条后索引失效重建
        dict.add_entry("d".into(), "中间".into(), 1);
        assert_eq!(texts(&dict, "中"), ["中国", "中国", "中国人", "中间"]);
    }

    #[test]
    fn test_prefix_supplement_only_han() {
        let mut dict = DictEngine::new();
        dict.load_from_str(
            "c\t又\t100
cojp\tァ\t890
cojp\tア\t880
copj\t①\t870
cbcd\t骚\t500
cojp\t𰀀\t10
",
        );
        let texts = |code: &str| -> Vec<String> {
            dict.lookup(code, false, 10)
                .iter()
                .map(|e| e.text.clone())
                .collect()
        };
        // 前缀补充只带出全为汉字的条目（含扩展区汉字）
        assert_eq!(texts("c"), vec!["又", "骚", "𰀀"]);
        assert_eq!(texts("coj"), vec!["𰀀"]);
        // 完整编码（精确匹配）仍能打出符号
        assert_eq!(texts("cojp"), vec!["ァ", "ア", "𰀀"]);
        assert_eq!(texts("copj"), vec!["①"]);
        // 前缀存在性不受过滤影响
        assert!(dict.has_prefix("co", false));
        assert!(dict.has_prefix("cop", false));
    }

    #[test]
    fn test_has_prefix() {
        let dict = sample_dict();
        assert!(dict.has_prefix("aad", false));
        assert!(dict.has_prefix("a", false));
        assert!(!dict.has_prefix("aac", false));
        assert!(!dict.has_prefix("", false));
        assert!(dict.has_prefix("az", true));
        assert!(!dict.has_prefix("az", false));
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
