use crate::config::Config;
use crate::dict::DictEngine;
use crate::punctuation::PunctuationConverter;
use crate::user_dict::UserDict;
use std::path::Path;

// ==================== 排序权重层级（编译期固化）====================
// 三层从低到高：码表词频(≤MAX_DICT_WEIGHT) < 精确匹配加成 < 用户词典加成。
// 换码表时超过 MAX_DICT_WEIGHT 的原始权重会在 dict.rs 加载时被钳制到上限，
// 保证下方 const 断言的层级关系恒成立，"精确匹配优先 / 用户词典优先"不被静默破坏。

/// 码表候选权重上限：dict.rs 加载时把超过此值的权重钳制到此（见 `DictEngine::load_from_str`）。
/// `pub(crate)`：仅供 crate 内部固化层级，不对外导出（避免 cbindgen 泄漏进 C 契约头）。
pub(crate) const MAX_DICT_WEIGHT: u32 = 4096;
/// 精确匹配（编码长度 == 输入长度）权重加成。
const EXACT_MATCH_BOOST: u32 = 5000;
/// 拼音精确匹配加成：低于五笔精确加成，属码表层级内的相对提升，不构成独立层级。
const PINYIN_EXACT_BOOST: u32 = 1000;
/// 用户词典权重加成：叠加在用户词条原始权重（≤ `user_dict::WEIGHT_CAP`）之上，
/// 使用户候选（最低 `USER_DICT_BOOST` + 0）恒排在任何码表候选之前。
const USER_DICT_BOOST: u32 = 50000;

// 层级固化：编译期钉死"用户词典 > 精确匹配 > 码表词频"。
// ① 精确加成必须高于任何码表词频（含钳制上限）。
const _: () = assert!(EXACT_MATCH_BOOST > MAX_DICT_WEIGHT);
// ② 用户加成必须高于"精确匹配候选"能达到的最高排序权重（钳制上限 + 精确加成），
//    因用户候选原始权重 ≥ 0，故其排序权重恒 > 任何码表候选。
const _: () = assert!(USER_DICT_BOOST > EXACT_MATCH_BOOST + MAX_DICT_WEIGHT);
// ③ 拼音精确加成低于五笔精确加成（同权重时五笔精确排前）。
const _: () = assert!(PINYIN_EXACT_BOOST < EXACT_MATCH_BOOST);

/// 候选词（统一的对外接口）
#[derive(Debug, Clone)]
pub struct Candidate {
    pub code: String,
    pub text: String,
    pub weight: u32,
    /// 是否来自用户词典
    pub is_user: bool,
    /// 来源码表中的出现序（用于等权重时的确定性排序）
    pub origin_index: usize,
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

        // 拼音混输模式下，编码可能超过4码，放宽自动上屏限制
        let pinyin_active = self.config.pinyin_mixed_enabled && self.pinyin_dict.is_some();

        // 满码守卫：五笔全码=4，缓冲区已满时再敲字母不得增长成“>4 码零候选”死状态。
        if !pinyin_active && self.buffer.len() >= 4 {
            if self.config.auto_commit_first_five && !self.candidates.is_empty() {
                // 第五码顶字：顶当前页首选（与 handle_space 一致）、新键起新字
                let index = (self.current_page * self.config.candidate_count)
                    .min(self.candidates.len() - 1);
                let text = self.candidates[index].text.clone();
                let code = self.candidates[index].code.clone();
                self.user_dict.boost(&code, &text);
                self.reset();
                self.buffer.push(key);
                self.update_candidates();
                return EngineAction::Commit(text);
            }
            // 顶字关闭、或四码零候选（见下方 empty_code_action=0）：拒绝增长，
            // 缓冲区与候选保持不变，吞掉该键（不透传给宿主），等待退格修正。
            return EngineAction::UpdateCandidates;
        }

        self.buffer.push(key);
        self.update_candidates();

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

        // 四码无匹配（拼音混输时跳过）
        if !pinyin_active && self.buffer.len() == 4 && self.candidates.is_empty() {
            match self.config.empty_code_action {
                0 => {
                    // 不吞字：保留 4 码缓冲区显示在预编辑中（零候选），等待用户退格修正。
                    // 后续字母键由上方“满码守卫”拒绝增长，退格正常工作。
                    return EngineAction::UpdateCandidates;
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
        // 有码零候选：吞掉空格（不透传成空格上屏），保留缓冲区供退格修正
        if self.candidates.is_empty() {
            return EngineAction::UpdateCandidates;
        }
        let index = self.current_page * self.config.candidate_count;
        self.select_candidate(index)
    }

    /// 数字键选择候选 (1-9)
    pub fn handle_number(&mut self, num: usize) -> EngineAction {
        if self.buffer.is_empty() || num == 0 {
            return EngineAction::Unhandled;
        }
        // 有码零候选：吞掉数字键，保留缓冲区供退格修正
        if self.candidates.is_empty() {
            return EngineAction::UpdateCandidates;
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
            // 有码但零候选：先清空脏码，再上屏标点，避免残留
            self.reset();
            if let Some(punct) = self.punctuation.convert(ch) {
                return EngineAction::Commit(punct);
            }
            return EngineAction::Reset;
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
        for (i, entry) in user_entries.iter().enumerate() {
            self.candidates.push(Candidate {
                code: entry.code.clone(),
                text: entry.text.clone(),
                weight: entry.weight + USER_DICT_BOOST, // 用户词典权重加成（始终优先）
                is_user: true,
                origin_index: i,
            });
        }

        // 再查主码表（五笔）
        let dict_entries =
            self.dict
                .lookup(&self.buffer, self.config.wildcard_z_enabled, max_candidates);
        let buffer_len = self.buffer.len();
        for entry in dict_entries {
            // 避免与用户词典重复
            if !self
                .candidates
                .iter()
                .any(|c| c.text == entry.text && c.code == entry.code)
            {
                // 精确匹配（编码长度 == 输入长度）获得权重加成
                let weight_boost = if entry.code.len() == buffer_len {
                    EXACT_MATCH_BOOST
                } else {
                    0
                };
                self.candidates.push(Candidate {
                    code: entry.code.clone(),
                    text: entry.text.clone(),
                    weight: entry.weight + weight_boost,
                    is_user: false,
                    origin_index: entry.origin_index,
                });
            }
        }

        // 查拼音词典（如果启用混输）
        if self.config.pinyin_mixed_enabled
            && let Some(ref pinyin_dict) = self.pinyin_dict
        {
            let pinyin_entries = pinyin_dict.lookup(
                &self.buffer,
                false, // 拼音不使用万能键
                max_candidates,
            );
            for entry in pinyin_entries {
                // 避免与已有候选重复（按汉字去重）
                if !self.candidates.iter().any(|c| c.text == entry.text) {
                    // 拼音精确匹配加成低于五笔，前缀匹配不加成
                    let weight_boost = if entry.code.len() == buffer_len {
                        PINYIN_EXACT_BOOST
                    } else {
                        0
                    };
                    self.candidates.push(Candidate {
                        code: entry.code.clone(),
                        text: entry.text.clone(),
                        weight: entry.weight + weight_boost,
                        is_user: false,
                        origin_index: entry.origin_index,
                    });
                }
            }
        }

        // 确定性多级排序：权重降序 → 编码长度升序 → origin_index 升序
        // （精确匹配因加成自然排前面；等权重时按来源出现序稳定排列）
        self.candidates.sort_by(|a, b| {
            b.weight
                .cmp(&a.weight)
                .then(a.code.len().cmp(&b.code.len()))
                .then(a.origin_index.cmp(&b.origin_index))
        });
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
        // 候选数下限 1（0 会导致候选恒空 + 翻页页码无界增长），上限 10
        self.config.candidate_count = candidate_count.clamp(1, 10);
        self.config.pinyin_mixed_enabled = pinyin_mixed_enabled;
    }

    /// 获取用户词典引用（用于保存等操作）
    pub fn user_dict(&self) -> &UserDict {
        &self.user_dict
    }

    /// 从磁盘加载用户词典（加载失败不 panic，退化为空词典）
    pub fn load_user_dict(&mut self, path: &Path) {
        self.set_user_dict(UserDict::load(path).unwrap_or_default());
    }

    /// 用已构建好的用户词典替换当前词典（文件 IO 在调用方锁外完成）
    pub fn set_user_dict(&mut self, dict: UserDict) {
        self.user_dict = dict;
    }

    /// 手动添加用户词条
    pub fn add_user_word(&mut self, code: String, text: String) {
        self.user_dict.add(code, text, 500);
    }

    /// 删除用户词条
    pub fn remove_user_word(&mut self, code: &str, text: &str) -> bool {
        self.user_dict.remove(code, text)
    }

    /// FFI panic 恢复专用：把引擎清回已知干净状态（空组合缓冲 + 中文模式）。
    /// 供 `ffi::ffi_guard` 在捕获 panic 后调用，抹掉可能残留的中间组合状态。
    pub fn reset_input(&mut self) {
        self.reset();
        self.mode = InputMode::Chinese;
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

    fn create_dupe_test_engine() -> InputEngine {
        // abcd 为四码重码（候选≥2），不会四码唯一上屏；e 为另一个起首码
        let mut dict = DictEngine::new();
        dict.load_from_str(
            "abcd\t重\t5000
abcd\t码\t4000
e\t鹅\t9000
",
        );
        let config = Config {
            candidate_count: 5,
            auto_commit_on_unique_four: true,
            auto_commit_first_five: true,
            wildcard_z_enabled: true,
            ..Config::default()
        };
        InputEngine::new(dict, UserDict::new(), config)
    }

    #[test]
    fn test_fifth_code_pushes_first_candidate() {
        let mut engine = create_dupe_test_engine();
        // 输入四码重码：候选≥2，不应自动上屏，缓冲区停在 4 码
        for c in "abcd".chars() {
            engine.handle_key(c);
        }
        assert!(engine.candidates().len() >= 2);
        assert_eq!(engine.buffer(), "abcd");

        // 第五码：顶前字首选 "重" 上屏，新键 e 起新字
        let action = engine.handle_key('e');
        assert_eq!(action, EngineAction::Commit("重".to_string()));
        assert_eq!(engine.buffer(), "e");
        assert!(!engine.candidates().is_empty());
        assert!(engine.candidates().iter().any(|c| c.text == "鹅"));
    }

    #[test]
    fn test_fifth_code_no_dead_lock() {
        let mut engine = create_dupe_test_engine();
        // 复现旧 bug：四码重码后连敲两个字母，引擎不应卡死在“5 字符零候选”
        for c in "abcd".chars() {
            engine.handle_key(c);
        }
        // 第五码顶 "重"
        assert_eq!(
            engine.handle_key('a'),
            EngineAction::Commit("重".to_string())
        );
        assert_eq!(engine.buffer(), "a");
        assert!(!engine.candidates().is_empty());
    }

    // --- Fix 1：自学习影响排序 ---
    #[test]
    fn test_self_learning_reorders() {
        let mut dict = DictEngine::new();
        dict.load_from_str("ab\t甲\t5000\nab\t乙\t4000\n");
        let config = Config {
            candidate_count: 5,
            auto_commit_on_unique_four: true,
            ..Config::default()
        };
        let mut engine = InputEngine::new(dict, UserDict::new(), config);
        engine.handle_key('a');
        engine.handle_key('b');
        assert_eq!(engine.candidates()[0].text, "甲");
        // 选中第二候选 "乙" → 自学习
        assert_eq!(
            engine.handle_number(2),
            EngineAction::Commit("乙".to_string())
        );
        // 再次输入 ab：乙 应被学习提升到第一位
        engine.handle_key('a');
        engine.handle_key('b');
        assert_eq!(engine.candidates()[0].text, "乙");
        assert!(engine.candidates()[0].is_user);
    }

    // --- Fix 2：四码零匹配不吞字，保留缓冲区 ---
    #[test]
    fn test_four_code_zero_match_keeps_buffer() {
        let mut engine = create_test_engine();
        // "abpp" 无任何前缀命中 → 四码零候选
        for c in "abpp".chars() {
            engine.handle_key(c);
        }
        assert_eq!(engine.buffer(), "abpp");
        assert!(engine.candidates().is_empty());
        // 满码守卫：继续敲字母被拒绝，缓冲区不增长
        let action = engine.handle_key('q');
        assert_eq!(action, EngineAction::UpdateCandidates);
        assert_eq!(engine.buffer(), "abpp");
        // 退格可恢复
        engine.handle_backspace();
        assert_eq!(engine.buffer(), "abp");
    }

    // --- Fix 3：有码零候选时打标点先清空缓冲区再上屏 ---
    #[test]
    fn test_punctuation_with_zero_candidate_clears_buffer() {
        let mut engine = create_test_engine();
        for c in "abpp".chars() {
            engine.handle_key(c);
        }
        assert!(engine.candidates().is_empty());
        let action = engine.handle_punctuation(',');
        assert_eq!(action, EngineAction::Commit("，".to_string()));
        assert!(engine.buffer().is_empty());
    }

    // --- Fix 3：有码零候选时 space/number 被吞掉且缓冲区保留 ---
    #[test]
    fn test_space_number_with_zero_candidate_swallowed() {
        let mut engine = create_test_engine();
        for c in "abpp".chars() {
            engine.handle_key(c);
        }
        assert_eq!(engine.handle_space(), EngineAction::UpdateCandidates);
        assert_eq!(engine.buffer(), "abpp");
        assert_eq!(engine.handle_number(1), EngineAction::UpdateCandidates);
        assert_eq!(engine.buffer(), "abpp");
        engine.handle_backspace();
        assert_eq!(engine.buffer(), "abp");
    }

    // --- Fix 4：关闭顶字开关后，第五码被拒绝、不卡死 ---
    #[test]
    fn test_fifth_code_rejected_when_auto_commit_off() {
        let mut dict = DictEngine::new();
        dict.load_from_str("abcd\t重\t5000\nabcd\t码\t4000\n");
        let config = Config {
            candidate_count: 5,
            auto_commit_on_unique_four: true,
            auto_commit_first_five: false,
            wildcard_z_enabled: true,
            ..Config::default()
        };
        let mut engine = InputEngine::new(dict, UserDict::new(), config);
        for c in "abcd".chars() {
            engine.handle_key(c);
        }
        assert_eq!(engine.buffer(), "abcd");
        assert!(engine.candidates().len() >= 2);
        // 第五码：顶字关闭 → 拒绝增长，缓冲区与候选不变
        let action = engine.handle_key('e');
        assert_eq!(action, EngineAction::UpdateCandidates);
        assert_eq!(engine.buffer(), "abcd");
        assert!(engine.candidates().len() >= 2);
    }

    // --- Fix 5：set_user_dict 替换词典（FFI 锁外加载后 apply 的路径）---
    #[test]
    fn test_set_user_dict_replaces() {
        let mut engine = create_test_engine();
        let mut ud = UserDict::new();
        ud.add("a".into(), "替换".into(), 500);
        engine.set_user_dict(ud);
        engine.handle_key('a');
        assert!(engine.candidates().iter().any(|c| c.text == "替换"));
    }

    // --- Fix 6：candidate_count 下限 clamp 到 1 ---
    #[test]
    fn test_candidate_count_clamped() {
        let mut engine = create_test_engine();
        engine.set_config(true, true, 0, 0, 0, false); // candidate_count=0
        engine.handle_key('a');
        // clamp 到 >=1：候选不恒空，每页恰好 1 个
        assert_eq!(engine.candidates().len(), 1);
    }

    // --- Fix 7：第五码顶字取当前页首选，而非全局首选 ---
    #[test]
    fn test_fifth_code_pushes_current_page_first() {
        let mut dict = DictEngine::new();
        dict.load_from_str(
            "abcd\t甲\t5000\nabcd\t乙\t4000\nabcd\t丙\t3000\nabcd\t丁\t2000\ne\t鹅\t9000\n",
        );
        let config = Config {
            candidate_count: 2,
            auto_commit_on_unique_four: true,
            auto_commit_first_five: true,
            wildcard_z_enabled: true,
            ..Config::default()
        };
        let mut engine = InputEngine::new(dict, UserDict::new(), config);
        for c in "abcd".chars() {
            engine.handle_key(c);
        }
        // 翻到第 2 页（丙、丁）
        engine.next_page();
        assert_eq!(engine.candidates()[0].text, "丙");
        // 第五码顶字应顶当前页首选 "丙"，而非全局首选 "甲"
        let action = engine.handle_key('e');
        assert_eq!(action, EngineAction::Commit("丙".to_string()));
        assert_eq!(engine.buffer(), "e");
    }

    // --- 排序层级固化：精确匹配在对手权重被钳制后仍排前 ---
    #[test]
    fn test_exact_match_ranks_first_after_clamp() {
        let mut dict = DictEngine::new();
        // 精确匹配 "a"=甲 原始权重仅 1；前缀 "ab"=乙 原始权重远超上限（钳到 MAX_DICT_WEIGHT）。
        // 若无钳制，乙(9_000_000) 会盖过 甲(1+EXACT_MATCH_BOOST)；钳制后 甲 恒排前。
        dict.load_from_str("a\t甲\t1\nab\t乙\t9000000\n");
        let config = Config {
            candidate_count: 5,
            ..Config::default()
        };
        let mut engine = InputEngine::new(dict, UserDict::new(), config);
        engine.handle_key('a');
        assert_eq!(engine.candidates()[0].text, "甲");
    }

    // --- 排序层级固化：用户词典恒压过被钳制到上限的码表精确匹配 ---
    #[test]
    fn test_user_dict_beats_clamped_exact() {
        let mut dict = DictEngine::new();
        // 码表精确匹配 "a"=甲 权重顶到上限（+EXACT_MATCH_BOOST 后仍是码表层最高）
        dict.load_from_str("a\t甲\t9000000\n");
        let config = Config {
            candidate_count: 5,
            ..Config::default()
        };
        let mut engine = InputEngine::new(dict, UserDict::new(), config);
        engine.add_user_word("a".into(), "用户".into());
        engine.handle_key('a');
        assert_eq!(engine.candidates()[0].text, "用户");
        assert!(engine.candidates()[0].is_user);
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
