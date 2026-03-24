use crate::config::Config;
use crate::dict::DictEngine;
use crate::punctuation::PunctuationConverter;
use crate::user_dict::UserDict;

/// 候选词（统一的对外接口）
#[derive(Debug, Clone)]
pub struct Candidate {
    pub code: String,
    pub text: String,
    pub weight: u32,
    /// 是否来自用户词典
    pub is_user: bool,
}

/// 引擎动作：引擎处理按键后返回的动作
#[derive(Debug, Clone, PartialEq)]
pub enum EngineAction {
    /// 提交文本到应用程序
    Commit(String),
    /// 更新候选列表（继续输入中）
    UpdateCandidates,
    /// 编码已清空
    Reset,
    /// 按键未被引擎处理，交给系统
    Unhandled,
}

/// 输入模式
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum InputMode {
    Chinese,
    English,
    /// 临时英文模式（分号引导或大写字母触发，提交后自动回到中文）
    TempEnglish,
}

/// 五笔输入引擎
pub struct InputEngine {
    /// 当前编码缓冲区
    buffer: String,
    /// 当前候选列表
    candidates: Vec<Candidate>,
    /// 码表引擎
    dict: DictEngine,
    /// 用户词典
    user_dict: UserDict,
    /// 配置
    config: Config,
    /// 输入模式
    mode: InputMode,
    /// 标点转换器
    punctuation: PunctuationConverter,
    /// 临时英文缓冲区（分号引导模式使用）
    temp_english_buffer: String,
}

impl InputEngine {
    pub fn new(dict: DictEngine, user_dict: UserDict, config: Config) -> Self {
        Self {
            buffer: String::new(),
            candidates: Vec::new(),
            dict,
            user_dict,
            config,
            mode: InputMode::Chinese,
            punctuation: PunctuationConverter::new(),
            temp_english_buffer: String::new(),
        }
    }

    /// 获取当前编码
    pub fn buffer(&self) -> &str {
        &self.buffer
    }

    /// 获取当前候选列表
    pub fn candidates(&self) -> &[Candidate] {
        &self.candidates
    }

    /// 获取当前输入模式
    pub fn mode(&self) -> InputMode {
        self.mode
    }

    /// 切换中英文模式
    pub fn toggle_mode(&mut self) {
        self.mode = match self.mode {
            InputMode::Chinese => InputMode::English,
            InputMode::English | InputMode::TempEnglish => InputMode::Chinese,
        };
        self.reset();
    }

    /// 处理字母按键输入
    pub fn handle_key(&mut self, key: char) -> EngineAction {
        // 英文模式直接输出
        if self.mode == InputMode::English {
            return EngineAction::Commit(key.to_string());
        }

        // 临时英文模式：累积到缓冲区
        if self.mode == InputMode::TempEnglish {
            self.temp_english_buffer.push(key);
            self.buffer = self.temp_english_buffer.clone();
            return EngineAction::UpdateCandidates;
        }

        // 只接受 a-y（五笔有效键）和 z（万能键）
        if !key.is_ascii_lowercase() {
            return EngineAction::Unhandled;
        }

        self.buffer.push(key);
        self.update_candidates();

        // 四码唯一自动上屏
        if self.config.auto_commit_on_unique_four
            && self.buffer.len() == 4
            && self.candidates.len() == 1
        {
            let text = self.candidates[0].text.clone();
            let code = self.candidates[0].code.clone();
            self.user_dict.boost(&code, &text);
            self.reset();
            return EngineAction::Commit(text);
        }

        // 四码无匹配，自动清空
        if self.buffer.len() == 4 && self.candidates.is_empty() {
            self.reset();
            return EngineAction::Reset;
        }

        EngineAction::UpdateCandidates
    }

    /// 空格键：选择第一个候选
    pub fn handle_space(&mut self) -> EngineAction {
        if self.buffer.is_empty() {
            return EngineAction::Unhandled;
        }
        self.select_candidate(0)
    }

    /// 数字键选择候选 (1-9)
    pub fn handle_number(&mut self, num: usize) -> EngineAction {
        if self.buffer.is_empty() || num == 0 {
            return EngineAction::Unhandled;
        }
        self.select_candidate(num - 1)
    }

    /// 选择候选词
    fn select_candidate(&mut self, index: usize) -> EngineAction {
        if index >= self.candidates.len() {
            return EngineAction::Unhandled;
        }

        let candidate = self.candidates[index].clone();
        self.user_dict.boost(&candidate.code, &candidate.text);
        self.reset();
        EngineAction::Commit(candidate.text)
    }

    /// Backspace：删除末位编码
    pub fn handle_backspace(&mut self) -> EngineAction {
        if self.mode == InputMode::TempEnglish {
            if self.temp_english_buffer.is_empty() {
                self.mode = InputMode::Chinese;
                self.reset();
                return EngineAction::Reset;
            }
            self.temp_english_buffer.pop();
            if self.temp_english_buffer.is_empty() {
                self.mode = InputMode::Chinese;
                self.reset();
                return EngineAction::Reset;
            }
            self.buffer = self.temp_english_buffer.clone();
            return EngineAction::UpdateCandidates;
        }

        if self.buffer.is_empty() {
            return EngineAction::Unhandled;
        }

        self.buffer.pop();
        if self.buffer.is_empty() {
            self.candidates.clear();
            return EngineAction::Reset;
        }

        self.update_candidates();
        EngineAction::UpdateCandidates
    }

    /// Escape：清空编码
    pub fn handle_escape(&mut self) -> EngineAction {
        if self.mode == InputMode::TempEnglish {
            self.mode = InputMode::Chinese;
            self.reset();
            return EngineAction::Reset;
        }

        if self.buffer.is_empty() {
            return EngineAction::Unhandled;
        }
        self.reset();
        EngineAction::Reset
    }

    /// Enter：提交编码原文 / 临时英文提交
    pub fn handle_enter(&mut self) -> EngineAction {
        if self.mode == InputMode::TempEnglish {
            if self.temp_english_buffer.is_empty() {
                self.mode = InputMode::Chinese;
                self.reset();
                return EngineAction::Reset;
            }
            let text = self.temp_english_buffer.clone();
            self.mode = InputMode::Chinese;
            self.reset();
            return EngineAction::Commit(text);
        }

        if self.buffer.is_empty() {
            return EngineAction::Unhandled;
        }
        let text = self.buffer.clone();
        self.reset();
        EngineAction::Commit(text)
    }

    /// 空格键：临时英文模式下提交并回到中文
    pub fn handle_space_for_temp_english(&mut self) -> Option<EngineAction> {
        if self.mode != InputMode::TempEnglish {
            return None;
        }
        if self.temp_english_buffer.is_empty() {
            return Some(EngineAction::Unhandled);
        }
        // 临时英文模式下空格提交并回到中文
        let text = self.temp_english_buffer.clone();
        self.mode = InputMode::Chinese;
        self.reset();
        Some(EngineAction::Commit(text))
    }

    /// 处理标点符号
    pub fn handle_punctuation(&mut self, ch: char) -> EngineAction {
        // 先提交编码缓冲区中的内容（如果有）
        if !self.buffer.is_empty() && self.mode == InputMode::Chinese {
            // 有候选时，自动选中第一个候选
            if !self.candidates.is_empty() {
                let candidate = self.candidates[0].clone();
                self.user_dict.boost(&candidate.code, &candidate.text);
                let committed = candidate.text;
                self.reset();
                // 然后转换标点
                if let Some(punct) = self.punctuation.convert(ch) {
                    return EngineAction::Commit(format!("{}{}", committed, punct));
                }
                return EngineAction::Commit(committed);
            }
        }

        if self.mode == InputMode::English {
            return EngineAction::Commit(ch.to_string());
        }

        // 中文模式下转换标点
        if let Some(punct) = self.punctuation.convert(ch) {
            return EngineAction::Commit(punct);
        }

        EngineAction::Unhandled
    }

    /// 分号键：引导临时英文模式（清歌风格）
    pub fn handle_semicolon(&mut self) -> EngineAction {
        if self.mode == InputMode::English {
            return EngineAction::Commit(";".to_string());
        }

        // 如果编码缓冲区中有内容，分号作为普通标点处理
        if !self.buffer.is_empty() {
            return self.handle_punctuation(';');
        }

        // 进入临时英文模式
        self.mode = InputMode::TempEnglish;
        self.temp_english_buffer.clear();
        self.buffer.clear();
        EngineAction::UpdateCandidates
    }

    /// 处理大写字母：进入临时英文模式（首字母大写）
    pub fn handle_uppercase(&mut self, ch: char) -> EngineAction {
        if self.mode == InputMode::English {
            return EngineAction::Commit(ch.to_string());
        }

        if self.mode == InputMode::TempEnglish {
            self.temp_english_buffer.push(ch);
            self.buffer = self.temp_english_buffer.clone();
            return EngineAction::UpdateCandidates;
        }

        // 编码缓冲区非空时，先清空
        if !self.buffer.is_empty() {
            self.reset();
        }

        // 进入临时英文模式
        self.mode = InputMode::TempEnglish;
        self.temp_english_buffer.clear();
        self.temp_english_buffer.push(ch);
        self.buffer = self.temp_english_buffer.clone();
        EngineAction::UpdateCandidates
    }

    /// 重置状态
    fn reset(&mut self) {
        self.buffer.clear();
        self.candidates.clear();
        self.temp_english_buffer.clear();
    }

    /// 更新候选列表
    fn update_candidates(&mut self) {
        self.candidates.clear();

        if self.buffer.is_empty() {
            return;
        }

        // 先查用户词典
        let user_entries = self.user_dict.lookup(&self.buffer);
        for entry in user_entries {
            self.candidates.push(Candidate {
                code: entry.code.clone(),
                text: entry.text.clone(),
                weight: entry.weight + 50000, // 用户词典权重加成（始终优先）
                is_user: true,
            });
        }

        // 再查主码表
        let dict_entries = self.dict.lookup(
            &self.buffer,
            self.config.wildcard_z_enabled,
            self.config.candidate_count * 2, // 多取一些，合并后再截断
        );
        let buffer_len = self.buffer.len();
        for entry in dict_entries {
            // 避免与用户词典重复
            if !self.candidates.iter().any(|c| c.text == entry.text && c.code == entry.code) {
                // 精确匹配（编码长度 == 输入长度）获得权重加成
                let weight_boost = if entry.code.len() == buffer_len { 5000 } else { 0 };
                self.candidates.push(Candidate {
                    code: entry.code.clone(),
                    text: entry.text.clone(),
                    weight: entry.weight + weight_boost,
                    is_user: false,
                });
            }
        }

        // 按权重排序（精确匹配因加成自然排前面）
        self.candidates.sort_by(|a, b| b.weight.cmp(&a.weight));
        self.candidates
            .truncate(self.config.candidate_count);
    }

    /// 获取用户词典引用（用于保存等操作）
    pub fn user_dict(&self) -> &UserDict {
        &self.user_dict
    }

    /// 手动添加用户词条
    pub fn add_user_word(&mut self, code: String, text: String) {
        self.user_dict.add(code, text, 500);
    }

    /// 删除用户词条
    pub fn remove_user_word(&mut self, code: &str, text: &str) -> bool {
        self.user_dict.remove(code, text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_engine() -> InputEngine {
        let mut dict = DictEngine::new();
        dict.load_from_str(
            "a\t工\t9999
aa\t式\t5000
aad\t芝\t2000
aadk\t芽\t1500
aadn\t萌\t1200
ab\t节\t4000
abcn\t苦\t3000
b\t了\t9998
bbbb\t子\t5500
gglf\t王\t8000
",
        );

        let config = Config {
            candidate_count: 5,
            auto_commit_on_unique_four: true,
            wildcard_z_enabled: true,
            ..Config::default()
        };

        InputEngine::new(dict, UserDict::new(), config)
    }

    #[test]
    fn test_basic_input() {
        let mut engine = create_test_engine();
        let action = engine.handle_key('a');
        assert_eq!(action, EngineAction::UpdateCandidates);
        assert_eq!(engine.buffer(), "a");
        assert!(!engine.candidates().is_empty());
        // "工" 应在候选中
        assert!(engine.candidates().iter().any(|c| c.text == "工"));
    }

    #[test]
    fn test_space_select() {
        let mut engine = create_test_engine();
        engine.handle_key('a');
        let action = engine.handle_space();
        assert_eq!(action, EngineAction::Commit("工".to_string()));
        assert!(engine.buffer().is_empty());
    }

    #[test]
    fn test_number_select() {
        let mut engine = create_test_engine();
        engine.handle_key('a');
        // 数字 1 选择第一个候选
        let action = engine.handle_number(1);
        assert_eq!(action, EngineAction::Commit("工".to_string()));
    }

    #[test]
    fn test_four_code_auto_commit() {
        let mut engine = create_test_engine();
        // gglf 唯一匹配 "王"
        engine.handle_key('g');
        engine.handle_key('g');
        engine.handle_key('l');
        let action = engine.handle_key('f');
        assert_eq!(action, EngineAction::Commit("王".to_string()));
        assert!(engine.buffer().is_empty());
    }

    #[test]
    fn test_backspace() {
        let mut engine = create_test_engine();
        engine.handle_key('a');
        engine.handle_key('b');
        assert_eq!(engine.buffer(), "ab");

        let action = engine.handle_backspace();
        assert_eq!(action, EngineAction::UpdateCandidates);
        assert_eq!(engine.buffer(), "a");
    }

    #[test]
    fn test_escape() {
        let mut engine = create_test_engine();
        engine.handle_key('a');
        let action = engine.handle_escape();
        assert_eq!(action, EngineAction::Reset);
        assert!(engine.buffer().is_empty());
    }

    #[test]
    fn test_enter_raw() {
        let mut engine = create_test_engine();
        engine.handle_key('a');
        engine.handle_key('b');
        let action = engine.handle_enter();
        assert_eq!(action, EngineAction::Commit("ab".to_string()));
    }

    #[test]
    fn test_english_mode() {
        let mut engine = create_test_engine();
        engine.toggle_mode();
        assert_eq!(engine.mode(), InputMode::English);

        let action = engine.handle_key('a');
        assert_eq!(action, EngineAction::Commit("a".to_string()));
    }

    #[test]
    fn test_user_dict_priority() {
        let mut engine = create_test_engine();
        engine.add_user_word("a".into(), "自定义".into());
        engine.handle_key('a');
        // 用户词条应排在第一
        assert_eq!(engine.candidates()[0].text, "自定义");
        assert!(engine.candidates()[0].is_user);
    }

    #[test]
    fn test_empty_operations() {
        let mut engine = create_test_engine();
        assert_eq!(engine.handle_space(), EngineAction::Unhandled);
        assert_eq!(engine.handle_backspace(), EngineAction::Unhandled);
        assert_eq!(engine.handle_escape(), EngineAction::Unhandled);
        assert_eq!(engine.handle_enter(), EngineAction::Unhandled);
    }

    #[test]
    fn test_punctuation_chinese_mode() {
        let mut engine = create_test_engine();
        let action = engine.handle_punctuation(',');
        assert_eq!(action, EngineAction::Commit("，".to_string()));

        let action = engine.handle_punctuation('.');
        assert_eq!(action, EngineAction::Commit("。".to_string()));
    }

    #[test]
    fn test_punctuation_english_mode() {
        let mut engine = create_test_engine();
        engine.toggle_mode();
        let action = engine.handle_punctuation(',');
        assert_eq!(action, EngineAction::Commit(",".to_string()));
    }

    #[test]
    fn test_punctuation_with_pending_code() {
        let mut engine = create_test_engine();
        engine.handle_key('a');
        // 输入标点应先提交候选再输出标点
        let action = engine.handle_punctuation(',');
        assert_eq!(action, EngineAction::Commit("工，".to_string()));
        assert!(engine.buffer().is_empty());
    }

    #[test]
    fn test_semicolon_temp_english() {
        let mut engine = create_test_engine();
        // 分号进入临时英文
        let action = engine.handle_semicolon();
        assert_eq!(action, EngineAction::UpdateCandidates);
        assert_eq!(engine.mode(), InputMode::TempEnglish);

        // 输入英文
        engine.handle_key('h');
        engine.handle_key('i');
        assert_eq!(engine.buffer(), "hi");

        // Enter 提交并回到中文
        let action = engine.handle_enter();
        assert_eq!(action, EngineAction::Commit("hi".to_string()));
        assert_eq!(engine.mode(), InputMode::Chinese);
    }

    #[test]
    fn test_uppercase_temp_english() {
        let mut engine = create_test_engine();
        // 大写字母进入临时英文
        let action = engine.handle_uppercase('H');
        assert_eq!(action, EngineAction::UpdateCandidates);
        assert_eq!(engine.mode(), InputMode::TempEnglish);
        assert_eq!(engine.buffer(), "H");

        // 继续输入
        engine.handle_key('e');
        engine.handle_key('l');
        engine.handle_key('l');
        engine.handle_key('o');
        assert_eq!(engine.buffer(), "Hello");

        // Enter 提交
        let action = engine.handle_enter();
        assert_eq!(action, EngineAction::Commit("Hello".to_string()));
        assert_eq!(engine.mode(), InputMode::Chinese);
    }

    #[test]
    fn test_temp_english_escape() {
        let mut engine = create_test_engine();
        engine.handle_semicolon();
        engine.handle_key('t');
        engine.handle_key('e');

        // Escape 取消临时英文
        let action = engine.handle_escape();
        assert_eq!(action, EngineAction::Reset);
        assert_eq!(engine.mode(), InputMode::Chinese);
        assert!(engine.buffer().is_empty());
    }

    #[test]
    fn test_temp_english_backspace() {
        let mut engine = create_test_engine();
        engine.handle_semicolon();
        engine.handle_key('a');
        engine.handle_key('b');

        // Backspace 删除
        engine.handle_backspace();
        assert_eq!(engine.buffer(), "a");

        // 继续 Backspace 回到中文
        engine.handle_backspace();
        assert_eq!(engine.mode(), InputMode::Chinese);
    }

    #[test]
    fn test_paired_punctuation() {
        let mut engine = create_test_engine();
        // 引号应交替输出左右
        let action1 = engine.handle_punctuation('"');
        assert_eq!(action1, EngineAction::Commit("\u{201c}".to_string()));
        let action2 = engine.handle_punctuation('"');
        assert_eq!(action2, EngineAction::Commit("\u{201d}".to_string()));
    }
}
