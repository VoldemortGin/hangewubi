use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;

/// 用户词条
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserEntry {
    pub code: String,
    pub text: String,
    pub weight: u32,
    /// 使用次数
    pub use_count: u32,
    /// 是否为用户自造词条（码表外的词，经造词编码入库）；false 为词频学习/手工条目。
    /// 旧版 user_dict.json 无此字段，按 false 加载；为 false 时不写出，保持旧格式不变。
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub custom: bool,
}

/// 用户词典
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct UserDict {
    entries: HashMap<String, Vec<UserEntry>>,
}

/// 自学习创建的新词条初始权重
const LEARN_INITIAL_WEIGHT: u32 = 10;
/// 权重上限，防止长期使用后无限膨胀
const WEIGHT_CAP: u32 = 100_000;

impl UserDict {
    pub fn new() -> Self {
        Self::default()
    }

    /// 从文件加载用户词典
    pub fn load(path: &Path) -> Result<Self, Box<dyn std::error::Error>> {
        if !path.exists() {
            return Ok(Self::new());
        }
        let content = std::fs::read_to_string(path)?;
        let dict: UserDict = serde_json::from_str(&content)?;
        Ok(dict)
    }

    /// 保存用户词典到文件
    pub fn save(&self, path: &Path) -> Result<(), Box<dyn std::error::Error>> {
        let content = serde_json::to_string_pretty(self)?;
        std::fs::write(path, content)?;
        Ok(())
    }

    /// 添加用户词条
    pub fn add(&mut self, code: String, text: String, weight: u32) {
        let entries = self.entries.entry(code.clone()).or_default();
        // 避免重复
        if entries.iter().any(|e| e.text == text) {
            return;
        }
        entries.push(UserEntry {
            code,
            text,
            weight,
            use_count: 0,
            custom: false,
        });
    }

    /// 添加自造词条：已有同码同词的自造词返回 false；
    /// 已有同码同词的非自造条目（如手工添加）则升级为自造词并返回 true。
    pub fn add_custom(&mut self, code: String, text: String, weight: u32) -> bool {
        let entries = self.entries.entry(code.clone()).or_default();
        if let Some(e) = entries.iter_mut().find(|e| e.text == text) {
            if e.custom {
                return false;
            }
            e.custom = true;
            return true;
        }
        entries.push(UserEntry {
            code,
            text,
            weight,
            use_count: 0,
            custom: true,
        });
        true
    }

    /// 删除一条自造词（非自造的词频学习条目不受影响）
    pub fn remove_custom(&mut self, code: &str, text: &str) -> bool {
        let is_custom = self
            .entries
            .get(code)
            .is_some_and(|v| v.iter().any(|e| e.text == text && e.custom));
        is_custom && self.remove(code, text)
    }

    /// 是否已有同码同词的条目（自造或学习）
    pub fn contains(&self, code: &str, text: &str) -> bool {
        self.entries
            .get(code)
            .is_some_and(|v| v.iter().any(|e| e.text == text))
    }

    /// 全部自造词，按编码再按词排序（确定性顺序）
    pub fn custom_entries(&self) -> Vec<&UserEntry> {
        let mut list: Vec<&UserEntry> = self
            .entries
            .values()
            .flatten()
            .filter(|e| e.custom)
            .collect();
        list.sort_by(|a, b| a.code.cmp(&b.code).then(a.text.cmp(&b.text)));
        list
    }

    /// 编码以 `prefix` 开头且更长的自造词（前缀匹配补充）
    pub fn custom_longer_than(&self, prefix: &str) -> Vec<&UserEntry> {
        let mut list: Vec<&UserEntry> = self
            .entries
            .iter()
            .filter(|(code, _)| code.len() > prefix.len() && code.starts_with(prefix))
            .flat_map(|(_, v)| v.iter().filter(|e| e.custom))
            .collect();
        list.sort_by(|a, b| {
            b.weight
                .cmp(&a.weight)
                .then(a.code.cmp(&b.code))
                .then(a.text.cmp(&b.text))
        });
        list
    }

    /// 联想：文本以 `prefix` 开头且比它长的自造词（每次实时扫描，增删即时生效）
    pub fn custom_with_text_prefix(&self, prefix: &str) -> Vec<&UserEntry> {
        let mut list: Vec<&UserEntry> = self
            .entries
            .values()
            .flatten()
            .filter(|e| e.custom && e.text.len() > prefix.len() && e.text.starts_with(prefix))
            .collect();
        list.sort_by(|a, b| a.code.cmp(&b.code).then(a.text.cmp(&b.text)));
        list
    }

    /// 是否存在编码以 `prefix` 开头（含相等）的自造词
    pub fn has_custom_prefix(&self, prefix: &str) -> bool {
        self.entries
            .iter()
            .any(|(code, v)| code.starts_with(prefix) && v.iter().any(|e| e.custom))
    }

    /// 删除用户词条
    pub fn remove(&mut self, code: &str, text: &str) -> bool {
        let Some(entries) = self.entries.get_mut(code) else {
            return false;
        };
        let before = entries.len();
        entries.retain(|e| e.text != text);
        let removed = entries.len() < before;
        if removed && self.entries.get(code).is_some_and(|e| e.is_empty()) {
            self.entries.remove(code);
        }
        removed
    }

    /// 提升词频（每次选中时调用）
    ///
    /// insert-or-increment 语义：条目已存在则累加词频，
    /// 不存在则以初始权重创建，使日常选字能被学习并提升排序。
    pub fn boost(&mut self, code: &str, text: &str) {
        let entries = self.entries.entry(code.to_string()).or_default();
        for entry in entries.iter_mut() {
            if entry.text == text {
                entry.use_count = entry.use_count.saturating_add(1);
                entry.weight = entry.weight.saturating_add(10).min(WEIGHT_CAP);
                return;
            }
        }
        entries.push(UserEntry {
            code: code.to_string(),
            text: text.to_string(),
            weight: LEARN_INITIAL_WEIGHT,
            use_count: 1,
            custom: false,
        });
    }

    /// 查询用户词条
    pub fn lookup(&self, code: &str) -> Vec<&UserEntry> {
        self.entries
            .get(code)
            .map(|entries| {
                let mut sorted: Vec<&UserEntry> = entries.iter().collect();
                // 权重降序；等权重时按 text 升序，保证跨重启的确定性顺序
                sorted.sort_by(|a, b| b.weight.cmp(&a.weight).then(a.text.cmp(&b.text)));
                sorted
            })
            .unwrap_or_default()
    }

    /// 总词条数
    pub fn entry_count(&self) -> usize {
        self.entries.values().map(|v| v.len()).sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_add_and_lookup() {
        let mut dict = UserDict::new();
        dict.add("test".into(), "测试".into(), 100);
        let results = dict.lookup("test");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].text, "测试");
    }

    #[test]
    fn test_no_duplicate() {
        let mut dict = UserDict::new();
        dict.add("test".into(), "测试".into(), 100);
        dict.add("test".into(), "测试".into(), 200);
        assert_eq!(dict.entry_count(), 1);
    }

    #[test]
    fn test_remove() {
        let mut dict = UserDict::new();
        dict.add("test".into(), "测试".into(), 100);
        assert!(dict.remove("test", "测试"));
        assert_eq!(dict.entry_count(), 0);
    }

    #[test]
    fn test_boost() {
        let mut dict = UserDict::new();
        dict.add("test".into(), "测试".into(), 100);
        dict.boost("test", "测试");
        let results = dict.lookup("test");
        assert_eq!(results[0].weight, 110);
        assert_eq!(results[0].use_count, 1);
    }

    #[test]
    fn test_boost_creates_missing_entry() {
        // 自学习：对不存在的编码 boost 应创建条目（insert-or-increment）
        let mut dict = UserDict::new();
        dict.boost("a", "工");
        let results = dict.lookup("a");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].text, "工");
        assert_eq!(results[0].use_count, 1);
        assert_eq!(results[0].weight, LEARN_INITIAL_WEIGHT);

        // 再次 boost 同一词条应累加而非重复创建
        dict.boost("a", "工");
        let results = dict.lookup("a");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].use_count, 2);
        assert_eq!(results[0].weight, LEARN_INITIAL_WEIGHT + 10);
    }

    #[test]
    fn test_boost_weight_capped() {
        let mut dict = UserDict::new();
        dict.add("a".into(), "工".into(), WEIGHT_CAP);
        dict.boost("a", "工");
        // 已达上限，boost 不再增长
        assert_eq!(dict.lookup("a")[0].weight, WEIGHT_CAP);
    }

    #[test]
    fn test_save_and_load() {
        let mut dict = UserDict::new();
        dict.add("test".into(), "测试".into(), 100);

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("user_dict.json");
        dict.save(&path).unwrap();

        let loaded = UserDict::load(&path).unwrap();
        assert_eq!(loaded.entry_count(), 1);
        assert_eq!(loaded.lookup("test")[0].text, "测试");
    }

    #[test]
    fn test_custom_add_remove_list() {
        let mut dict = UserDict::new();
        dict.boost("jfag", "学习");
        assert!(dict.add_custom("jfag".into(), "晗戈".into(), 500));
        assert!(!dict.add_custom("jfag".into(), "晗戈".into(), 500));
        assert!(dict.add_custom("aaaa".into(), "甲乙".into(), 500));
        let list: Vec<(&str, &str)> = dict
            .custom_entries()
            .iter()
            .map(|e| (e.text.as_str(), e.code.as_str()))
            .collect();
        assert_eq!(list, [("甲乙", "aaaa"), ("晗戈", "jfag")]);
        assert!(dict.has_custom_prefix("jf"));
        assert!(dict.has_custom_prefix("jfag"));
        assert!(!dict.has_custom_prefix("jfb"));
        assert_eq!(dict.custom_longer_than("jf").len(), 1);
        assert!(dict.custom_longer_than("jfag").is_empty());
        // 学习条目不能经自造词接口删除；自造词可删
        assert!(!dict.remove_custom("jfag", "学习"));
        assert!(dict.remove_custom("jfag", "晗戈"));
        assert!(!dict.remove_custom("jfag", "晗戈"));
        assert!(dict.contains("jfag", "学习"));
        assert!(!dict.has_custom_prefix("jf"));
    }

    #[test]
    fn test_custom_upgrades_manual_entry() {
        let mut dict = UserDict::new();
        dict.add("jfag".into(), "晗戈".into(), 500);
        assert!(dict.custom_entries().is_empty());
        assert!(dict.add_custom("jfag".into(), "晗戈".into(), 500));
        assert_eq!(dict.custom_entries().len(), 1);
        assert_eq!(dict.entry_count(), 1);
    }

    #[test]
    fn test_custom_json_roundtrip_and_boost_keeps_flag() {
        let mut dict = UserDict::new();
        dict.add_custom("jfag".into(), "晗戈".into(), 500);
        dict.boost("jfag", "晗戈");
        dict.boost("a", "工");
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("user_dict.json");
        dict.save(&path).unwrap();
        let json = std::fs::read_to_string(&path).unwrap();
        // 学习条目不写 custom 字段（与旧格式一致）
        assert_eq!(json.matches("\"custom\"").count(), 1);
        let loaded = UserDict::load(&path).unwrap();
        assert_eq!(loaded.entry_count(), 2);
        let custom = loaded.custom_entries();
        assert_eq!(custom.len(), 1);
        assert_eq!((custom[0].text.as_str(), custom[0].use_count), ("晗戈", 1));
        assert!(!loaded.lookup("a")[0].custom);
    }

    #[test]
    fn test_load_legacy_format() {
        // 旧版 user_dict.json（无 custom 字段）：正常加载、不丢数据、全部视为学习条目
        let legacy = r#"{
  "entries": {
    "a": [
      { "code": "a", "text": "工", "weight": 30, "use_count": 3 },
      { "code": "a", "text": "戈", "weight": 10, "use_count": 1 }
    ],
    "xy": [
      { "code": "xy", "text": "自造", "weight": 500, "use_count": 0 }
    ]
  }
}"#;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("user_dict.json");
        std::fs::write(&path, legacy).unwrap();
        let loaded = UserDict::load(&path).unwrap();
        assert_eq!(loaded.entry_count(), 3);
        assert_eq!(loaded.lookup("a")[0].text, "工");
        assert_eq!(loaded.lookup("a")[0].weight, 30);
        assert_eq!(loaded.lookup("xy")[0].use_count, 0);
        assert!(loaded.custom_entries().is_empty());
    }
}
