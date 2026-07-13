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
        });
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
}
