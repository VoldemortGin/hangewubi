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
    /// 当前候选列表（存储所有匹配结果，分页展示）
    candidates: Vec<Candidate>,
    /// 码表引擎
    dict: DictEngine,
    /// 拼音词典（可选）
    pinyin_dict: Option<DictEngine>,
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
    /// 当前页码（从 0 开始）
    current_page: usize,
}

impl InputEngine {
    pub fn new(dict: DictEngine, user_dict: UserDict, config: Config) -> Self {
        Self {
            buffer: String::new(),
            candidates: Vec::new(),
            dict,
            pinyin_dict: None,
            user_dict,
            config,
            mode: InputMode::Chinese,
            punctuation: PunctuationConverter::new(),
            temp_english_buffer: String::new(),
            current_page: 0,
        }
    }

    /// 设置拼音词典
    pub fn set_pinyin_dict(&mut self, pinyin_dict: DictEngine) {
        self.pinyin_dict = Some(pinyin_dict);
    }

    /// 获取当前编码
    pub fn buffer(&self) -> &str {
        &self.buffer
    }

    /// 获取当前页候选列表
    pub fn candidates(&self) -> &[Candidate] {
        let page_size = self.config.candidate_count;
        let start = self.current_page * page_size;
        let end = (start + page_size).min(self.candidates.len());
        if start >= self.candidates.len() {
            &[]
        } else {
            &self.candidates[start..end]
        }
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

        // 拼音混输模式下，编码可能超过4码，放宽自动上屏限制
        let pinyin_active = self.config.pinyin_mixed_enabled && self.pinyin_dict.is_some();

        // 四码唯一自动上屏（拼音混输时跳过，因为用户可能在输入拼音）
        if !pinyin_active
            && self.config.auto_commit_on_unique_four
            && self.buffer.len() == 4
            && self.candidates.len() == 1
        {
            let text = self.candidates[0].text.clone();
            let code = self.candidates[0].code.clone();
            self.user_dict.boost(&code, &text);
            self.reset();
            return EngineAction::Commit(text);
        }

        // 五码首选自动上屏（拼音混输时跳过）
        if !pinyin_active
            && self.config.auto_commit_first_five
            && self.buffer.len() == 5
            && !self.candidates.is_empty()
        {
            let text = self.candidates[0].text.clone();
            let code = self.candidates[0].code.clone();
            self.user_dict.boost(&code, &text);
            self.reset();
            return EngineAction::Commit(text);
        }

        // 四码无匹配（拼音混输时跳过）
        if !pinyin_active && self.buffer.len() == 4 && self.candidates.is_empty() {
            match self.config.empty_code_action {
                0 => {
                    // 转临时英文模式
                    self.reset();
                    return EngineAction::Reset;
                }
                1 => {
                    // 提示音（返回 UpdateCandidates，客户端可 beep）
                    self.buffer.pop();
                    self.update_candidates();
                    return EngineAction::UpdateCandidates;
                }
                _ => {
                    // 不处理：回退最后一码
                    self.buffer.pop();
                    self.update_candidates();
                    return EngineAction::UpdateCandidates;
                }
            }
        }

        EngineAction::UpdateCandidates
    }

    /// 空格键：选择当前页第一个候选
    pub fn handle_space(&mut self) -> EngineAction {
        if self.buffer.is_empty() {
            return EngineAction::Unhandled;
        }
        let index = self.current_page * self.config.candidate_count;
        self.select_candidate(index)
    }

    /// 数字键选择候选 (1-9)
    pub fn handle_number(&mut self, num: usize) -> EngineAction {
        if self.buffer.is_empty() || num == 0 {
            return EngineAction::Unhandled;
        }
        let index = self.current_page * self.config.candidate_count + (num - 1);
        self.select_candidate(index)
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
        match self.config.enter_key_action {
            0 => {
                // 输出编码原文
                let text = self.buffer.clone();
                self.reset();
                EngineAction::Commit(text)
            }
            1 => {
                // 清除编码
                self.reset();
                EngineAction::Reset
            }
            _ => {
                // 不处理
                EngineAction::Unhandled
            }
        }
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
            // 有候选时，自动选中当前页第一个候选
            let page_first = self.current_page * self.config.candidate_count;
            if page_first < self.candidates.len() {
                let candidate = self.candidates[page_first].clone();
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

    /// 分号键：编码非空时选第二候选，否则引导临时英文模式
    pub fn handle_semicolon(&mut self) -> EngineAction {
        if self.mode == InputMode::English {
            return EngineAction::Commit(";".to_string());
        }

        // 如果编码缓冲区中有内容，选择当前页第二个候选
        if !self.buffer.is_empty() {
            let index = self.current_page * self.config.candidate_count + 1;
            if index < self.candidates.len() {
                return self.select_candidate(index);
            }
            // 候选不足 2 个，按标点处理
            return self.handle_punctuation(';');
        }

        // 进入临时英文模式
        self.mode = InputMode::TempEnglish;
        self.temp_english_buffer.clear();
        self.buffer.clear();
        EngineAction::UpdateCandidates
    }

    /// 单引号键：编码非空时选第三候选
    pub fn handle_quote(&mut self) -> EngineAction {
        if self.mode == InputMode::English {
            return EngineAction::Commit("'".to_string());
        }

        if !self.buffer.is_empty() {
            let index = self.current_page * self.config.candidate_count + 2;
            if index < self.candidates.len() {
                return self.select_candidate(index);
            }
            // 候选不足 3 个，不处理
            return EngineAction::Unhandled;
        }

        // 缓冲区为空，作为标点处理
        self.handle_punctuation('\'')
    }

    /// 下一页
    pub fn next_page(&mut self) -> EngineAction {
        let page_size = self.config.candidate_count;
        let next_start = (self.current_page + 1) * page_size;
        if next_start < self.candidates.len() {
            self.current_page += 1;
            EngineAction::UpdateCandidates
        } else {
            EngineAction::Unhandled
        }
    }

    /// 上一页
    pub fn prev_page(&mut self) -> EngineAction {
        if self.current_page > 0 {
            self.current_page -= 1;
            EngineAction::UpdateCandidates
        } else {
            EngineAction::Unhandled
        }
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
        self.current_page = 0;
    }

    /// 更新候选列表
    fn update_candidates(&mut self) {
        self.candidates.clear();
        self.current_page = 0;

        if self.buffer.is_empty() {
            return;
        }

        // 最多存储的候选数（支持多页翻页）
        let max_candidates = 50;

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

        // 再查主码表（五笔）
        let dict_entries = self.dict.lookup(
            &self.buffer,
            self.config.wildcard_z_enabled,
            max_candidates,
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

        // 查拼音词典（如果启用混输）
        if self.config.pinyin_mixed_enabled {
            if let Some(ref pinyin_dict) = self.pinyin_dict {
                let pinyin_entries = pinyin_dict.lookup(
                    &self.buffer,
                    false, // 拼音不使用万能键
                    max_candidates,
                );
                for entry in pinyin_entries {
                    // 避免与已有候选重复（按汉字去重）
                    if !self.candidates.iter().any(|c| c.text == entry.text) {
                        // 拼音精确匹配加成低于五笔，前缀匹配不加成
                        let weight_boost = if entry.code.len() == buffer_len { 1000 } else { 0 };
                        self.candidates.push(Candidate {
                            code: entry.code.clone(),
                            text: entry.text.clone(),
                            weight: entry.weight + weight_boost,
                            is_user: false,
                        });
                    }
                }
            }
        }

        // 按权重排序（精确匹配因加成自然排前面）
        self.candidates.sort_by(|a, b| b.weight.cmp(&a.weight));
        self.candidates.truncate(max_candidates);
    }

    /// 更新配置（运行时由 FFI 调用）
    pub fn set_config(
        &mut self,
        auto_commit_unique_4: bool,
        auto_commit_first_5: bool,
        enter_key_action: u8,
        empty_code_action: u8,
        candidate_count: usize,
        pinyin_mixed_enabled: bool,
    ) {
        self.config.auto_commit_on_unique_four = auto_commit_unique_4;
        self.config.auto_commit_first_five = auto_commit_first_5;
        self.config.enter_key_action = enter_key_action;
        self.config.empty_code_action = empty_code_action;
        self.config.candidate_count = candidate_count;
        self.config.pinyin_mixed_enabled = pinyin_mixed_enabled;
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

    // --- 拼音混输测试 ---

    fn create_pinyin_test_engine() -> InputEngine {
        let mut dict = DictEngine::new();
        dict.load_from_str(
            "a\t工\t9999
aa\t式\t5000
gglf\t王\t8000
gggg\t王\t7000
bbbb\t子\t5500
",
        );

        let mut pinyin_dict = DictEngine::new();
        pinyin_dict.load_from_str(
            "wang\t王\t9000
wang\t网\t8500
wang\t忘\t7000
wang\t望\t6500
wo\t我\t9500
wo\t窝\t3000
ni\t你\t9400
zhongguo\t中国\t9000
zhong\t中\t8000
zhong\t钟\t5000
",
        );

        let config = Config {
            candidate_count: 5,
            auto_commit_on_unique_four: true,
            wildcard_z_enabled: true,
            pinyin_mixed_enabled: true,
            ..Config::default()
        };

        let mut engine = InputEngine::new(dict, UserDict::new(), config);
        engine.set_pinyin_dict(pinyin_dict);
        engine
    }

    #[test]
    fn test_pinyin_candidates_appear() {
        let mut engine = create_pinyin_test_engine();
        // 输入 "wo" 应该出现拼音候选 "我"
        engine.handle_key('w');
        engine.handle_key('o');
        let candidates = engine.candidates();
        assert!(!candidates.is_empty());
        assert!(candidates.iter().any(|c| c.text == "我"));
    }

    #[test]
    fn test_wubi_priority_over_pinyin() {
        let mut engine = create_pinyin_test_engine();
        // 输入 "a" 五笔匹配 "工"，应排在拼音结果之前
        engine.handle_key('a');
        let candidates = engine.candidates();
        assert_eq!(candidates[0].text, "工");
    }

    #[test]
    fn test_pinyin_long_input() {
        let mut engine = create_pinyin_test_engine();
        // 输入 "zhongguo" 应匹配拼音 "中国"
        for c in "zhongguo".chars() {
            engine.handle_key(c);
        }
        let candidates = engine.candidates();
        assert!(candidates.iter().any(|c| c.text == "中国"));
    }

    #[test]
    fn test_pinyin_no_auto_commit_at_four() {
        let mut engine = create_pinyin_test_engine();
        // 拼音混输模式下，四码不应自动上屏（用户可能在打拼音）
        engine.handle_key('g');
        engine.handle_key('g');
        engine.handle_key('l');
        let action = engine.handle_key('f');
        // 不应自动提交，应该继续显示候选
        assert_eq!(action, EngineAction::UpdateCandidates);
    }

    #[test]
    fn test_pinyin_disabled() {
        let mut dict = DictEngine::new();
        dict.load_from_str("a\t工\t9999\n");

        let mut pinyin_dict = DictEngine::new();
        pinyin_dict.load_from_str("wo\t我\t9500\n");

        let config = Config {
            pinyin_mixed_enabled: false,
            ..Config::default()
        };

        let mut engine = InputEngine::new(dict, UserDict::new(), config);
        engine.set_pinyin_dict(pinyin_dict);

        engine.handle_key('w');
        engine.handle_key('o');
        let candidates = engine.candidates();
        // 拼音关闭时不应出现拼音候选
        assert!(!candidates.iter().any(|c| c.text == "我"));
    }

    #[test]
    fn test_pinyin_dedup_with_wubi() {
        let mut engine = create_pinyin_test_engine();
        // 输入 "wang" 五笔无精确匹配，拼音有 "王"
        // 五笔的 "王" 在 gggg/gglf 下，"wang" 前缀不匹配五笔
        for c in "wang".chars() {
            engine.handle_key(c);
        }
        let candidates = engine.candidates();
        // "王" 应只出现一次（来自拼音）
        let wang_count = candidates.iter().filter(|c| c.text == "王").count();
        assert_eq!(wang_count, 1);
    }
}
