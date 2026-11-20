use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// 候选词显示数量
    #[serde(default = "default_candidate_count")]
    pub candidate_count: usize,

    /// 四码唯一自动上屏
    #[serde(default = "default_true")]
    pub auto_commit_on_unique_four: bool,

    /// Z键万能键开关
    #[serde(default = "default_true")]
    pub wildcard_z_enabled: bool,

    /// 词组优先（false 则单字优先）
    #[serde(default = "default_true")]
    pub phrase_first: bool,

    /// 五码首选自动上屏
    #[serde(default = "default_true")]
    pub auto_commit_first_five: bool,

    /// Enter 键行为：0=输出编码, 1=清除, 2=不处理
    #[serde(default)]
    pub enter_key_action: u8,

    /// 空码行为：0=转临时英文, 1=提示音, 2=不处理
    #[serde(default)]
    pub empty_code_action: u8,

    /// 码表文件路径
    #[serde(default)]
    pub dict_path: Option<PathBuf>,

    /// 用户词典路径
    #[serde(default)]
    pub user_dict_path: Option<PathBuf>,

    /// 五笔拼音混合输入开关
    #[serde(default)]
    pub pinyin_mixed_enabled: bool,

    /// 拼音词典路径
    #[serde(default)]
    pub pinyin_dict_path: Option<PathBuf>,

    /// 逐码提示：开=候选含前缀匹配补充的更长编码条目并带编码提示；关=只显示精确匹配
    #[serde(default = "default_true")]
    pub code_hint: bool,

    /// 仅常用字：开=候选中含 GB2312 之外汉字的条目被过滤；关=显示全部
    #[serde(default)]
    pub common_chars_only: bool,

    /// 自动造词：开=连续逐字上屏的 2–4 字码表外词组出现第 2 次时自动作为自造词入库；默认关
    #[serde(default)]
    pub auto_phrase: bool,

    /// 词语联想：开=五笔上屏汉字后，候选列出以其开头的更长词条的后续部分；默认关
    #[serde(default)]
    pub association: bool,
}

fn default_candidate_count() -> usize {
    5
}

fn default_true() -> bool {
    true
}

impl Default for Config {
    fn default() -> Self {
        Self {
            candidate_count: 5,
            auto_commit_on_unique_four: true,
            wildcard_z_enabled: true,
            phrase_first: true,
            auto_commit_first_five: true,
            enter_key_action: 0,
            empty_code_action: 0,
            dict_path: None,
            user_dict_path: None,
            pinyin_mixed_enabled: false,
            pinyin_dict_path: None,
            code_hint: true,
            common_chars_only: false,
            auto_phrase: false,
            association: false,
        }
    }
}

impl Config {
    pub fn load(path: &std::path::Path) -> Result<Self, Box<dyn std::error::Error>> {
        let content = std::fs::read_to_string(path)?;
        let config: Config = toml::from_str(&content)?;
        Ok(config)
    }

    pub fn save(&self, path: &std::path::Path) -> Result<(), Box<dyn std::error::Error>> {
        let content = toml::to_string_pretty(self)?;
        std::fs::write(path, content)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let config = Config::default();
        assert_eq!(config.candidate_count, 5);
        assert!(config.auto_commit_on_unique_four);
        assert!(config.wildcard_z_enabled);
        assert!(config.phrase_first);
    }

    #[test]
    fn test_config_roundtrip() {
        let config = Config::default();
        let serialized = toml::to_string_pretty(&config).unwrap();
        let deserialized: Config = toml::from_str(&serialized).unwrap();
        assert_eq!(deserialized.candidate_count, config.candidate_count);
        assert_eq!(
            deserialized.auto_commit_on_unique_four,
            config.auto_commit_on_unique_four
        );
    }
}
