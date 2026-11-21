use crate::charset::{is_gb2312_text, is_han, to_traditional};
use crate::config::Config;
use crate::dict::DictEngine;
use crate::punctuation::{PunctuationConverter, to_full_width};
use crate::user_dict::UserDict;
use std::collections::{HashMap, HashSet};
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

/// 自造词（手动 / 自动造词）入库初始权重，与手工添加用户词条一致
const CUSTOM_WORD_WEIGHT: u32 = 500;
/// 自动造词计数表条目上限：达到上限时整表清空重计，防止无限增长
const AUTO_PHRASE_COUNT_CAP: usize = 1024;
/// 自动造词：同一词组累计出现此次数时入库
const AUTO_PHRASE_THRESHOLD: u32 = 2;

/// 添加自造词失败原因
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum AddWordError {
    /// 无法按词组规则编码（含非汉字 / 有字查不到编码 / 全码位数不足）
    Unencodable,
    /// 码表里已有该词，或已有同码同词的自造词
    Exists,
}

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
    /// 编码提示：完整编码去掉已输入前缀后的剩余部分；精确匹配为空；
    /// z 通配匹配出的候选给出其完整编码
    pub hint: String,
}

/// 编码提示：精确匹配为空；通配候选给完整编码；前缀匹配给去掉已输入前缀后的剩余编码
fn remaining_code(buffer: &str, code: &str, wildcard: bool) -> String {
    if code == buffer {
        String::new()
    } else if wildcard {
        code.to_string()
    } else {
        code.strip_prefix(buffer).unwrap_or(code).to_string()
    }
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
    /// 逐码提示关闭过滤前的匹配数（四码唯一自动上屏据此判定，使开/关行为一致）
    match_count: usize,
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
    /// 紧挨着的上一个按键是否为直接上屏的数字（无编码时的数字键）；
    /// 用于让数字后的 `.` 保持半角小数点。任何其他按键都会清除它。
    after_digit: bool,
    /// 最近一次按键是否因空码被拒绝且配置要求提示音；由宿主经 `take_beep` 取走
    beep_pending: bool,
    /// 全角状态：为 true 时，原本以半角 ASCII 输出的内容改为全角
    full_width: bool,
    /// 繁体输出：为 true 时候选显示与上屏文本按字简→繁转换（内部候选/学习仍为简体）
    traditional: bool,
    /// 自动造词：最近连续逐字上屏的单个汉字（最多 4 个，任何打断即清空）
    phrase_seq: Vec<String>,
    /// 自动造词：码表外 2–4 字词组的出现计数（仅内存，不持久化）
    phrase_counts: HashMap<String, u32>,
    /// 词语联想：处于联想态时为触发联想的完整上屏文本（简体）；联想态下缓冲为空、
    /// 候选为联想词去掉该文本后的后续部分。None 即不在联想态
    assoc_text: Option<String>,
}

impl InputEngine {
    pub fn new(dict: DictEngine, user_dict: UserDict, config: Config) -> Self {
        Self {
            buffer: String::new(),
            candidates: Vec::new(),
            match_count: 0,
            dict,
            pinyin_dict: None,
            user_dict,
            config,
            mode: InputMode::Chinese,
            punctuation: PunctuationConverter::new(),
            temp_english_buffer: String::new(),
            current_page: 0,
            after_digit: false,
            beep_pending: false,
            full_width: false,
            traditional: false,
            phrase_seq: Vec::new(),
            phrase_counts: HashMap::new(),
            assoc_text: None,
        }
    }

    /// 切换中/英文标点，返回新状态（true=中文标点）
    pub fn toggle_chinese_punct(&mut self) -> bool {
        self.punctuation.enabled = !self.punctuation.enabled;
        self.punctuation.enabled
    }

    /// 当前是否中文标点
    pub fn chinese_punct(&self) -> bool {
        self.punctuation.enabled
    }

    /// 切换全角/半角，返回新状态（true=全角）
    pub fn toggle_full_width(&mut self) -> bool {
        self.full_width = !self.full_width;
        self.full_width
    }

    /// 当前是否全角
    pub fn full_width(&self) -> bool {
        self.full_width
    }

    /// 切换繁体输出，返回新状态（true=繁体）
    pub fn toggle_traditional(&mut self) -> bool {
        self.traditional = !self.traditional;
        self.traditional
    }

    /// 设置繁体输出
    pub fn set_traditional(&mut self, enabled: bool) {
        self.traditional = enabled;
    }

    /// 当前是否繁体输出
    pub fn traditional(&self) -> bool {
        self.traditional
    }

    /// 候选文本的输出形式（显示 / 上屏）：繁体输出开启时简→繁，否则原样
    pub fn output_text(&self, s: &str) -> String {
        if self.traditional {
            to_traditional(s)
        } else {
            s.to_string()
        }
    }

    /// 全角状态下把半角 ASCII 转全角，半角状态原样返回
    fn width(&self, s: &str) -> String {
        if self.full_width {
            to_full_width(s)
        } else {
            s.to_string()
        }
    }

    /// 标点输出文本：中文标点按映射转换，英文标点原样半角；全角状态下再转全角。
    /// 无需处理的字符返回 None
    fn punct_text(&mut self, ch: char) -> Option<String> {
        let text = if self.punctuation.enabled {
            self.punctuation.convert(ch)
        } else if PunctuationConverter::is_punctuation(ch) {
            Some(ch.to_string())
        } else {
            None
        };
        let text = match text {
            None if self.full_width && ch.is_ascii_graphic() => Some(ch.to_string()),
            other => other,
        };
        text.map(|t| self.width(&t))
    }

    /// 取走并清除「空码拒绝需提示音」标志
    pub fn take_beep(&mut self) -> bool {
        std::mem::take(&mut self.beep_pending)
    }

    /// 设置拼音词典
    pub fn set_pinyin_dict(&mut self, pinyin_dict: DictEngine) {
        self.pinyin_dict = Some(pinyin_dict);
    }

    /// 拼音词典是否已加载
    pub fn has_pinyin(&self) -> bool {
        self.pinyin_dict.is_some()
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
        self.after_digit = false;
        self.break_phrase_seq();
        self.mode = match self.mode {
            InputMode::Chinese => InputMode::English,
            InputMode::English | InputMode::TempEnglish => InputMode::Chinese,
        };
        self.reset();
    }

    /// 处理字母按键输入
    pub fn handle_key(&mut self, key: char) -> EngineAction {
        self.after_digit = false;
        self.beep_pending = false;
        self.cancel_association();
        // 英文模式直接输出
        if self.mode == InputMode::English {
            self.break_phrase_seq();
            return EngineAction::Commit(self.width(&key.to_string()));
        }

        // 临时英文模式：累积到缓冲区
        if self.mode == InputMode::TempEnglish {
            self.break_phrase_seq();
            self.temp_english_buffer.push(key);
            self.buffer = self.temp_english_buffer.clone();
            return EngineAction::UpdateCandidates;
        }

        // 只接受 a-y（五笔有效键）和 z（万能键）
        if !key.is_ascii_lowercase() {
            self.break_phrase_seq();
            return EngineAction::Unhandled;
        }

        // 拼音混输模式下，编码可能超过4码，放宽自动上屏限制
        // 临时拼音（首码 z 后接拼音反查）同样不受 4 码限制，且不受混输开关控制
        let pinyin_active = (self.config.pinyin_mixed_enabled && self.pinyin_dict.is_some())
            || (self.pinyin_dict.is_some()
                && (self.buffer.starts_with('z') || (self.buffer.is_empty() && key == 'z')));

        // 满码守卫：五笔全码=4，缓冲区已满时再敲字母不得增长成“>4 码零候选”死状态。
        if !pinyin_active && self.buffer.len() >= 4 {
            if self.config.auto_commit_first_five && !self.candidates.is_empty() {
                // 第五码顶字：顶当前页首选（与 handle_space 一致）、新键起新字
                let index = (self.current_page * self.config.candidate_count)
                    .min(self.candidates.len() - 1);
                let text = self.candidates[index].text.clone();
                let code = self.candidates[index].code.clone();
                self.user_dict.boost(&code, &text);
                self.note_commit(&text);
                self.reset();
                self.buffer.push(key);
                self.update_candidates();
                return EngineAction::Commit(self.output_text(&text));
            }
            // 顶字关闭：拒绝增长，
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
            && self.match_count == 1
        {
            let text = self.candidates[0].text.clone();
            let code = self.candidates[0].code.clone();
            self.user_dict.boost(&code, &text);
            self.note_commit(&text);
            self.reset();
            self.start_association(&text);
            return EngineAction::Commit(self.output_text(&text));
        }

        // 空码处理（拼音混输时跳过）
        // 空码 = 码表/用户词典里没有任何以当前编码为前缀的条目；与候选显示（逐码提示开关）解耦
        if !pinyin_active && self.candidates.is_empty() && !self.code_exists() {
            // 万能键通配只做等长匹配、不含前缀，未满四码的含 z 编码继续敲仍可能出字，不转英文
            let wildcard_pending = self.config.wildcard_z_enabled
                && self.buffer.len() < 4
                && self.buffer.contains('z');
            if self.config.empty_code_action == 0 && !wildcard_pending {
                // 转临时英文：整个缓冲（含新字母）转为临时英文缓冲，空格/回车作为英文上屏
                self.break_phrase_seq();
                self.mode = InputMode::TempEnglish;
                self.temp_english_buffer = std::mem::take(&mut self.buffer);
                self.buffer = self.temp_english_buffer.clone();
                return EngineAction::UpdateCandidates;
            }
            if self.buffer.len() == 4 {
                // 提示音 / 不处理：拒绝该键，回退最后一码（选项 1 置位，宿主经 ffi_take_beep 取走后发声）
                self.beep_pending = self.config.empty_code_action == 1;
                self.buffer.pop();
                self.update_candidates();
                return EngineAction::UpdateCandidates;
            }
        }

        EngineAction::UpdateCandidates
    }

    /// 空格键：选择当前页第一个候选
    pub fn handle_space(&mut self) -> EngineAction {
        self.after_digit = false;
        self.cancel_association();
        if self.buffer.is_empty() {
            self.break_phrase_seq();
            if self.full_width {
                return EngineAction::Commit(self.width(" "));
            }
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
        self.after_digit = false;
        // 联想态：选当前页第 num 个联想词；页内无此序号则取消联想，数字按无编码处理
        if self.is_associating() {
            if (1..=self.config.candidate_count).contains(&num) {
                let index = self.current_page * self.config.candidate_count + (num - 1);
                if index < self.candidates.len() {
                    return self.select_association(index);
                }
            }
            self.cancel_association();
        }
        // 临时英文态：数字是英文内容，追加进缓冲
        if self.mode == InputMode::TempEnglish {
            return self.handle_key(char::from(b'0' + (num % 10) as u8));
        }
        if self.buffer.is_empty() {
            self.break_phrase_seq();
            // 无编码：数字由宿主直接上屏，记下“上一键是数字”
            self.after_digit = self.mode == InputMode::Chinese;
            if self.full_width {
                return EngineAction::Commit(self.width(&num.to_string()));
            }
            return EngineAction::Unhandled;
        }
        if num == 0 {
            self.break_phrase_seq();
            return EngineAction::Unhandled;
        }
        // 有码零候选：吞掉数字键，保留缓冲区供退格修正
        if self.candidates.is_empty() {
            return EngineAction::UpdateCandidates;
        }
        // 序号超出当前页显示数：与“该序号无候选”一致，不得越页选到下一页
        if num > self.config.candidate_count {
            self.break_phrase_seq();
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
        // 临时拼音的编码是拼音串，不得写进五笔用户词典；也不参与自动造词、不触发联想
        let temp_pinyin = self.is_temp_pinyin();
        if !temp_pinyin {
            self.user_dict.boost(&candidate.code, &candidate.text);
            self.note_commit(&candidate.text);
        } else {
            self.break_phrase_seq();
        }
        self.reset();
        if !temp_pinyin {
            self.start_association(&candidate.text);
        }
        EngineAction::Commit(self.output_text(&candidate.text))
    }

    /// Backspace：删除末位编码
    pub fn handle_backspace(&mut self) -> EngineAction {
        self.after_digit = false;
        self.break_phrase_seq();
        self.cancel_association();
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
        self.after_digit = false;
        self.break_phrase_seq();
        // 联想态：只取消联想并吞掉该键
        if self.cancel_association() {
            return EngineAction::Reset;
        }
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
        self.after_digit = false;
        self.break_phrase_seq();
        self.cancel_association();
        if self.mode == InputMode::TempEnglish {
            if self.temp_english_buffer.is_empty() {
                self.mode = InputMode::Chinese;
                self.reset();
                return EngineAction::Reset;
            }
            let text = self.width(&self.temp_english_buffer);
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
        self.after_digit = false;
        if self.mode != InputMode::TempEnglish {
            return None;
        }
        self.break_phrase_seq();
        if self.temp_english_buffer.is_empty() {
            return Some(EngineAction::Unhandled);
        }
        // 临时英文模式下空格提交并回到中文
        let text = self.width(&self.temp_english_buffer);
        self.mode = InputMode::Chinese;
        self.reset();
        Some(EngineAction::Commit(text))
    }

    /// 处理标点符号
    pub fn handle_punctuation(&mut self, ch: char) -> EngineAction {
        let after_digit = std::mem::take(&mut self.after_digit);
        self.cancel_association();
        // 临时英文态：标点以英文半角原样追加进缓冲
        if self.mode == InputMode::TempEnglish {
            return self.handle_key(ch);
        }
        // 先提交编码缓冲区中的内容（如果有）
        if !self.buffer.is_empty() && self.mode == InputMode::Chinese {
            // 有候选时，自动选中当前页第一个候选
            let page_first = self.current_page * self.config.candidate_count;
            if page_first < self.candidates.len() {
                let candidate = self.candidates[page_first].clone();
                if !self.is_temp_pinyin() {
                    self.user_dict.boost(&candidate.code, &candidate.text);
                    self.note_commit(&candidate.text);
                }
                // 顶字上屏的字计入序列后，标点本身即打断
                self.break_phrase_seq();
                let committed = self.output_text(&candidate.text);
                self.reset();
                // 然后转换标点
                if let Some(punct) = self.punct_text(ch) {
                    return EngineAction::Commit(format!("{}{}", committed, punct));
                }
                return EngineAction::Commit(committed);
            }
            // 有码但零候选：先清空脏码，再上屏标点，避免残留
            self.break_phrase_seq();
            self.reset();
            if let Some(punct) = self.punct_text(ch) {
                return EngineAction::Commit(punct);
            }
            return EngineAction::Reset;
        }

        // 无编码时的标点（含英文模式）均为打断
        self.break_phrase_seq();
        if self.mode == InputMode::English {
            return EngineAction::Commit(self.width(&ch.to_string()));
        }

        // 数字后紧接 `.`：保持半角小数点（3.14 / 192.168.1.1）
        if ch == '.' && after_digit && self.punctuation.enabled {
            return EngineAction::Commit(self.width("."));
        }

        // 中文模式下转换标点
        if let Some(punct) = self.punct_text(ch) {
            return EngineAction::Commit(punct);
        }

        EngineAction::Unhandled
    }

    /// 分号键：编码非空时选第二候选，否则引导临时英文模式
    pub fn handle_semicolon(&mut self) -> EngineAction {
        self.after_digit = false;
        self.cancel_association();
        if self.mode == InputMode::English {
            self.break_phrase_seq();
            return EngineAction::Commit(self.width(";"));
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
        self.break_phrase_seq();
        self.mode = InputMode::TempEnglish;
        self.temp_english_buffer.clear();
        self.buffer.clear();
        EngineAction::UpdateCandidates
    }

    /// 单引号键：编码非空时选第三候选
    pub fn handle_quote(&mut self) -> EngineAction {
        self.after_digit = false;
        self.cancel_association();
        if self.mode == InputMode::English {
            self.break_phrase_seq();
            return EngineAction::Commit(self.width("'"));
        }

        if self.mode == InputMode::TempEnglish {
            return self.handle_punctuation('\'');
        }

        if !self.buffer.is_empty() {
            let index = self.current_page * self.config.candidate_count + 2;
            if index < self.candidates.len() {
                return self.select_candidate(index);
            }
            // 候选不足 3 个，不处理
            self.break_phrase_seq();
            return EngineAction::Unhandled;
        }

        // 缓冲区为空，作为标点处理
        self.handle_punctuation('\'')
    }

    /// 下一页
    pub fn next_page(&mut self) -> EngineAction {
        self.after_digit = false;
        let page_size = self.config.candidate_count;
        let next_start = (self.current_page + 1) * page_size;
        if next_start < self.candidates.len() {
            self.current_page += 1;
            EngineAction::UpdateCandidates
        } else {
            // 联想态翻到头：取消联想，该键交还按普通键处理
            self.cancel_association();
            EngineAction::Unhandled
        }
    }

    /// 上一页
    pub fn prev_page(&mut self) -> EngineAction {
        self.after_digit = false;
        if self.current_page > 0 {
            self.current_page -= 1;
            EngineAction::UpdateCandidates
        } else {
            self.cancel_association();
            EngineAction::Unhandled
        }
    }

    /// 处理大写字母：进入临时英文模式（首字母大写）
    pub fn handle_uppercase(&mut self, ch: char) -> EngineAction {
        self.after_digit = false;
        self.cancel_association();
        self.break_phrase_seq();
        if self.mode == InputMode::English {
            return EngineAction::Commit(self.width(&ch.to_string()));
        }

        if self.mode == InputMode::TempEnglish {
            self.temp_english_buffer.push(ch);
            self.buffer = self.temp_english_buffer.clone();
            return EngineAction::UpdateCandidates;
        }

        // 进入临时英文模式；在途编码保留，连同大写字母一起转为英文缓冲
        self.mode = InputMode::TempEnglish;
        self.temp_english_buffer = std::mem::take(&mut self.buffer);
        self.candidates.clear();
        self.current_page = 0;
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
        self.assoc_text = None;
    }

    /// 是否处于词语联想态（缓冲为空、候选为联想词后续部分）
    pub fn is_associating(&self) -> bool {
        self.assoc_text.is_some()
    }

    /// 取消联想（回到无编码空闲态），返回此前是否处于联想态；不在联想态时无任何副作用
    fn cancel_association(&mut self) -> bool {
        let was = self.is_associating();
        if was {
            self.reset();
        }
        was
    }

    /// 五笔上屏后尝试进入联想态：开关开启、中文模式、文本全为汉字，且码表/自造词中
    /// 有以该文本开头的更长词条时，候选置为这些词的后续部分（权重降序、去重）
    fn start_association(&mut self, text: &str) {
        if !self.config.association
            || self.mode != InputMode::Chinese
            || text.is_empty()
            || !text.chars().all(is_han)
        {
            return;
        }
        let base = self.dict.entry_count();
        let mut list: Vec<Candidate> = self
            .dict
            .words_with_prefix(text)
            .into_iter()
            .map(|e| (e.text.as_str(), e.weight, false, e.origin_index))
            .chain(
                self.user_dict
                    .custom_with_text_prefix(text)
                    .into_iter()
                    .enumerate()
                    .map(|(i, e)| {
                        (
                            e.text.as_str(),
                            e.weight.min(MAX_DICT_WEIGHT),
                            true,
                            base + i,
                        )
                    }),
            )
            .filter(|(word, ..)| !self.config.common_chars_only || is_gb2312_text(word))
            .map(|(word, weight, is_user, origin_index)| Candidate {
                code: String::new(),
                text: word[text.len()..].to_string(),
                weight,
                is_user,
                origin_index,
                hint: String::new(),
            })
            .collect();
        list.sort_by(|a, b| {
            b.weight
                .cmp(&a.weight)
                .then(a.origin_index.cmp(&b.origin_index))
        });
        let mut seen = HashSet::new();
        list.retain(|c| seen.insert(c.text.clone()));
        list.truncate(50);
        if !list.is_empty() {
            self.candidates = list;
            self.current_page = 0;
            self.assoc_text = Some(text.to_string());
        }
    }

    /// 选中联想词：上屏其后续部分，并以拼成的完整词继续联想。
    /// 联想词无编码可学，也不计入自动造词序列（打断）
    fn select_association(&mut self, index: usize) -> EngineAction {
        let full = format!(
            "{}{}",
            self.assoc_text.as_deref().unwrap_or_default(),
            self.candidates[index].text
        );
        let suffix = self.candidates[index].text.clone();
        self.break_phrase_seq();
        self.reset();
        self.start_association(&full);
        EngineAction::Commit(self.output_text(&suffix))
    }

    /// 是否处于临时拼音：缓冲首码为 z 且已加载拼音词典（无拼音词典时 z 仍按万能键处理）
    fn is_temp_pinyin(&self) -> bool {
        self.pinyin_dict.is_some() && self.buffer.starts_with('z')
    }

    /// 临时拼音候选：z 之后的字母按拼音查字，hint 为该字的最短五笔编码；不受逐码提示开关影响
    fn update_temp_pinyin_candidates(&mut self) {
        let Some(ref pinyin_dict) = self.pinyin_dict else {
            return;
        };
        let pinyin = &self.buffer[1..];
        if pinyin.is_empty() {
            return;
        }
        for entry in pinyin_dict.lookup(pinyin, false, 50) {
            if (self.config.common_chars_only && !is_gb2312_text(&entry.text))
                || self.candidates.iter().any(|c| c.text == entry.text)
            {
                continue;
            }
            let weight_boost = if entry.code.len() == pinyin.len() {
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
                hint: self
                    .dict
                    .shortest_code_of(&entry.text)
                    .unwrap_or_default()
                    .to_string(),
            });
        }
        self.match_count = self.candidates.len();
        self.candidates.sort_by(|a, b| {
            b.weight
                .cmp(&a.weight)
                .then(a.code.len().cmp(&b.code.len()))
                .then(a.origin_index.cmp(&b.origin_index))
        });
    }

    /// 码表（含 z 通配口径）、用户词典（精确）或自造词（前缀）里是否存在以当前编码为前缀的条目。
    /// 与逐码提示开关无关：开启时等价于“未过滤的候选列表非空”。
    fn code_exists(&self) -> bool {
        !self.buffer.is_empty()
            && (!self.user_dict.lookup(&self.buffer).is_empty()
                || self.user_dict.has_custom_prefix(&self.buffer)
                || self
                    .dict
                    .has_prefix(&self.buffer, self.config.wildcard_z_enabled))
    }

    /// 更新候选列表
    fn update_candidates(&mut self) {
        self.candidates.clear();
        self.match_count = 0;
        self.current_page = 0;

        if self.buffer.is_empty() {
            return;
        }

        if self.is_temp_pinyin() {
            self.update_temp_pinyin_candidates();
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
                hint: String::new(),
            });
        }

        // 自造词像码表词条一样参与前缀匹配补充：不加用户词典加成，权重钳到码表上限，
        // 保证排在精确匹配之后（通配模式只做等长匹配，不补充）
        let wildcard_mode = self.config.wildcard_z_enabled && self.buffer.contains('z');
        if !wildcard_mode {
            for (i, entry) in self
                .user_dict
                .custom_longer_than(&self.buffer)
                .iter()
                .enumerate()
            {
                self.candidates.push(Candidate {
                    code: entry.code.clone(),
                    text: entry.text.clone(),
                    weight: entry.weight.min(MAX_DICT_WEIGHT),
                    is_user: true,
                    origin_index: i,
                    hint: remaining_code(&self.buffer, &entry.code, false),
                });
            }
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
                    hint: remaining_code(&self.buffer, &entry.code, wildcard_mode),
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
                        hint: remaining_code(&self.buffer, &entry.code, false),
                    });
                }
            }
        }

        // 仅常用字：过滤含 GB2312 之外汉字的候选（只影响可见候选，不影响 code_exists）；
        // 之后的 match_count 即过滤后的可见匹配数，四码唯一自动上屏据此判定
        if self.config.common_chars_only {
            self.candidates.retain(|c| is_gb2312_text(&c.text));
        }

        // 逐码提示关闭：只保留精确匹配（编码长度 == 输入长度；z 通配本身即等长）
        self.match_count = self.candidates.len();
        if !self.config.code_hint {
            self.candidates.retain(|c| c.code.len() == buffer_len);
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

    /// 设置逐码提示开关（true=显示前缀匹配补充候选并带编码提示）
    pub fn set_code_hint(&mut self, enabled: bool) {
        self.config.code_hint = enabled;
    }

    /// 设置「仅常用字」开关（true=过滤 GB2312 之外的汉字候选）
    pub fn set_common_chars_only(&mut self, enabled: bool) {
        self.config.common_chars_only = enabled;
    }

    /// 设置「自动造词」开关；关闭时清空序列与计数
    pub fn set_auto_phrase(&mut self, enabled: bool) {
        self.config.auto_phrase = enabled;
        if !enabled {
            self.phrase_seq.clear();
            self.phrase_counts.clear();
        }
    }

    /// 设置「词语联想」开关；关闭时立即退出联想态
    pub fn set_association(&mut self, enabled: bool) {
        self.config.association = enabled;
        if !enabled {
            self.cancel_association();
        }
    }

    /// 预览：按五笔 86 词组规则为词计算编码（失败返回 None）
    pub fn preview_word_code(&self, word: &str) -> Option<String> {
        self.dict.phrase_code(word)
    }

    /// 按词自动计算编码并添加为自造词，成功返回编码
    pub fn add_custom_word(&mut self, word: &str) -> Result<String, AddWordError> {
        let code = self
            .dict
            .phrase_code(word)
            .ok_or(AddWordError::Unencodable)?;
        if self.dict.shortest_code_of(word).is_some() {
            return Err(AddWordError::Exists);
        }
        if self
            .user_dict
            .add_custom(code.clone(), word.to_string(), CUSTOM_WORD_WEIGHT)
        {
            Ok(code)
        } else {
            Err(AddWordError::Exists)
        }
    }

    /// 删除一条自造词（按词 + 编码）
    pub fn remove_custom_word(&mut self, word: &str, code: &str) -> bool {
        self.user_dict.remove_custom(code, word)
    }

    /// 全部自造词（词, 编码），按编码排序
    pub fn custom_words(&self) -> Vec<(String, String)> {
        self.user_dict
            .custom_entries()
            .into_iter()
            .map(|e| (e.text.clone(), e.code.clone()))
            .collect()
    }

    /// 自动造词：打断连续逐字上屏序列（宿主对引擎看不到的直通按键也经 FFI 调用）
    pub fn break_phrase_seq(&mut self) {
        self.phrase_seq.clear();
    }

    /// 自动造词：记录一次五笔上屏（简体内部值）。非单个汉字（多字词等）视为打断。
    /// 对以最新字结尾的 2–4 字后缀，码表与用户词典都没有的计数加一，累计第 2 次时入库为自造词。
    fn note_commit(&mut self, text: &str) {
        let mut chars = text.chars();
        let single_han = matches!((chars.next(), chars.next()),
            (Some(c), None) if crate::charset::is_han(c));
        if !self.config.auto_phrase || !single_han {
            self.break_phrase_seq();
            return;
        }
        self.phrase_seq.push(text.to_string());
        if self.phrase_seq.len() > 4 {
            self.phrase_seq.remove(0);
        }
        for n in 2..=self.phrase_seq.len() {
            let word = self.phrase_seq[self.phrase_seq.len() - n..].concat();
            if self.dict.shortest_code_of(&word).is_some() {
                continue;
            }
            let Some(code) = self.dict.phrase_code(&word) else {
                continue;
            };
            if self.user_dict.contains(&code, &word) {
                continue;
            }
            if !self.phrase_counts.contains_key(&word)
                && self.phrase_counts.len() >= AUTO_PHRASE_COUNT_CAP
            {
                self.phrase_counts.clear();
            }
            let count = self.phrase_counts.entry(word.clone()).or_insert(0);
            *count += 1;
            if *count >= AUTO_PHRASE_THRESHOLD {
                self.phrase_counts.remove(&word);
                self.user_dict.add_custom(code, word, CUSTOM_WORD_WEIGHT);
            }
        }
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
        self.break_phrase_seq();
        self.reset();
        self.mode = InputMode::Chinese;
        self.after_digit = false;
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
        // 空码不转英文（选项 2），才会留下零候选缓冲
        engine.config.empty_code_action = 2;
        // "abp" 无任何前缀命中 → 零候选
        for c in "abp".chars() {
            engine.handle_key(c);
        }
        assert_eq!(engine.buffer(), "abp");
        assert!(engine.candidates().is_empty());
        // 第四码使 abpq 仍为空码：被拒绝，缓冲区不增长
        let action = engine.handle_key('q');
        assert_eq!(action, EngineAction::UpdateCandidates);
        assert_eq!(engine.buffer(), "abp");
        // 退格可恢复
        engine.handle_backspace();
        assert_eq!(engine.buffer(), "ab");
    }

    // --- Fix 3：有码零候选时打标点先清空缓冲区再上屏 ---
    #[test]
    fn test_punctuation_with_zero_candidate_clears_buffer() {
        let mut engine = create_test_engine();
        // 空码不转英文（选项 2），才会留下零候选缓冲
        engine.config.empty_code_action = 2;
        for c in "abp".chars() {
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
        // 空码不转英文（选项 2），才会留下零候选缓冲
        engine.config.empty_code_action = 2;
        for c in "abp".chars() {
            engine.handle_key(c);
        }
        assert_eq!(engine.handle_space(), EngineAction::UpdateCandidates);
        assert_eq!(engine.buffer(), "abp");
        assert_eq!(engine.handle_number(1), EngineAction::UpdateCandidates);
        assert_eq!(engine.buffer(), "abp");
        engine.handle_backspace();
        assert_eq!(engine.buffer(), "ab");
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

    // --- 数字键选词不得越页：超出当前页显示数的序号视为无对应候选 ---
    #[test]
    fn test_number_select_does_not_cross_page() {
        let mut dict = DictEngine::new();
        dict.load_from_str("abcd\t甲\t5000\nabcd\t乙\t4000\nabcd\t丙\t3000\nabcd\t丁\t2000\n");
        let config = Config {
            candidate_count: 2,
            auto_commit_on_unique_four: true,
            wildcard_z_enabled: true,
            ..Config::default()
        };
        let mut engine = InputEngine::new(dict, UserDict::new(), config);
        for c in "abcd".chars() {
            engine.handle_key(c);
        }
        assert_eq!(engine.candidates().len(), 2);
        // 当前页只显示 甲、乙：按 3 不得上屏下一页的 丙
        assert_eq!(engine.handle_number(3), EngineAction::Unhandled);
        assert_eq!(engine.buffer(), "abcd");
        // 页内序号仍正常
        assert_eq!(
            engine.handle_number(2),
            EngineAction::Commit("乙".to_string())
        );
    }

    // --- 宿主追加加载依赖的翻页语义：翻页取数后翻回，空格仍取首页首选；翻到目标页再按页内序号选词 ---
    #[test]
    fn test_page_roundtrip_and_select_on_target_page() {
        let mut dict = DictEngine::new();
        dict.load_from_str("abcd\t甲\t5000\nabcd\t乙\t4000\nabcd\t丙\t3000\nabcd\t丁\t2000\n");
        let config = Config {
            candidate_count: 2,
            auto_commit_on_unique_four: true,
            wildcard_z_enabled: true,
            ..Config::default()
        };
        let mut engine = InputEngine::new(dict, UserDict::new(), config);
        for c in "abcd".chars() {
            engine.handle_key(c);
        }
        assert_eq!(engine.next_page(), EngineAction::UpdateCandidates);
        assert_eq!(engine.candidates()[1].text, "丁");
        assert_eq!(engine.next_page(), EngineAction::Unhandled);
        assert_eq!(engine.prev_page(), EngineAction::UpdateCandidates);
        assert_eq!(engine.candidates()[0].text, "甲");
        // 全局第 4 个（丁）= 第 1 页页内第 2 个
        engine.next_page();
        assert_eq!(
            engine.handle_number(2),
            EngineAction::Commit("丁".to_string())
        );

        // 翻回首页后空格取首页首选
        for c in "abcd".chars() {
            engine.handle_key(c);
        }
        let first = engine.candidates()[0].text.clone();
        engine.next_page();
        engine.prev_page();
        assert_eq!(engine.handle_space(), EngineAction::Commit(first));
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
    fn test_dot_after_digit_stays_half_width() {
        let mut engine = create_test_engine();
        // 3.14
        assert_eq!(engine.handle_number(3), EngineAction::Unhandled);
        assert_eq!(
            engine.handle_punctuation('.'),
            EngineAction::Commit(".".to_string())
        );
        assert_eq!(engine.handle_number(1), EngineAction::Unhandled);
        assert_eq!(engine.handle_number(4), EngineAction::Unhandled);
        // 192.168.1.1：每个小数点前都紧挨数字
        for n in [1, 9, 2] {
            engine.handle_number(n);
        }
        assert_eq!(
            engine.handle_punctuation('.'),
            EngineAction::Commit(".".to_string())
        );
        engine.handle_number(1);
        assert_eq!(
            engine.handle_punctuation('.'),
            EngineAction::Commit(".".to_string())
        );
        // 小数点本身不是数字：连按第二个 `.` 恢复为句号
        assert_eq!(
            engine.handle_punctuation('.'),
            EngineAction::Commit("。".to_string())
        );
    }

    #[test]
    fn test_dot_after_digit_then_other_key_is_full_width() {
        let others: [fn(&mut InputEngine) -> EngineAction; 5] = [
            |e| e.handle_key('a'),
            |e| e.handle_space(),
            |e| e.handle_punctuation(','),
            |e| e.handle_backspace(),
            |e| e.handle_escape(),
        ];
        for other in others {
            let mut engine = create_test_engine();
            engine.handle_number(3);
            other(&mut engine);
            // 清掉可能残留的在途编码，只验证 `.` 的输出
            engine.reset_input();
            assert_eq!(
                engine.handle_punctuation('.'),
                EngineAction::Commit("。".to_string())
            );
        }
        // 数字后隔了字母再按 `.`：先上屏候选再接句号
        let mut engine = create_test_engine();
        engine.handle_number(3);
        engine.handle_key('a');
        assert_eq!(
            engine.handle_punctuation('.'),
            EngineAction::Commit("工。".to_string())
        );
    }

    #[test]
    fn test_dot_after_number_select_is_full_width() {
        let mut engine = create_test_engine();
        engine.handle_key('a');
        assert_eq!(
            engine.handle_number(1),
            EngineAction::Commit("工".to_string())
        );
        assert_eq!(
            engine.handle_punctuation('.'),
            EngineAction::Commit("。".to_string())
        );
    }

    #[test]
    fn test_dot_after_digit_other_key_clears_state() {
        // 不经 reset_input：空格/退格/Esc/逗号等无编码按键各自清除“上一键是数字”
        let others: [fn(&mut InputEngine) -> EngineAction; 4] = [
            |e| e.handle_space(),
            |e| e.handle_backspace(),
            |e| e.handle_escape(),
            |e| e.handle_punctuation(','),
        ];
        for other in others {
            let mut engine = create_test_engine();
            engine.handle_number(3);
            other(&mut engine);
            assert_eq!(
                engine.handle_punctuation('.'),
                EngineAction::Commit("。".to_string())
            );
        }
    }

    #[test]
    fn test_half_width_symbols_and_ellipsis() {
        let mut engine = create_test_engine();
        for ch in ['@', '#', '%', '&', '+', '=', '*'] {
            assert_eq!(
                engine.handle_punctuation(ch),
                EngineAction::Commit(ch.to_string())
            );
        }
        assert_eq!(
            engine.handle_punctuation('^'),
            EngineAction::Commit("……".to_string())
        );
        // 有在途编码时：先上屏候选，符号半角跟随
        engine.handle_key('a');
        assert_eq!(
            engine.handle_punctuation('*'),
            EngineAction::Commit("工*".to_string())
        );
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
    fn test_empty_code_to_temp_english() {
        // 默认 empty_code_action=0：直接打 hello（h 无候选）整体转临时英文
        let mut engine = create_test_engine();
        for c in "hello".chars() {
            assert_eq!(engine.handle_key(c), EngineAction::UpdateCandidates);
        }
        assert_eq!(engine.mode(), InputMode::TempEnglish);
        assert_eq!(engine.buffer(), "hello");
        assert_eq!(
            engine.handle_enter(),
            EngineAction::Commit("hello".to_string())
        );
        assert!(engine.buffer().is_empty());
    }

    #[test]
    fn test_empty_code_mid_code_to_temp_english() {
        // a 有候选，ax 无候选 -> 含新字母整体转英文，空格上屏 "ax"
        let mut engine = create_test_engine();
        engine.handle_key('a');
        engine.handle_key('x');
        assert_eq!(engine.mode(), InputMode::TempEnglish);
        assert_eq!(engine.buffer(), "ax");
        engine.handle_key('1');
        assert_eq!(
            engine.handle_space_for_temp_english(),
            Some(EngineAction::Commit("ax1".to_string()))
        );
    }

    #[test]
    fn test_empty_code_wildcard_prefix_not_temp_english() {
        // 万能键 z 通配无前缀语义：az 等长无命中，但未满四码时不得转临时英文
        let mut engine = create_test_engine();
        engine.handle_key('a');
        engine.handle_key('z');
        assert!(engine.candidates().is_empty() || engine.mode() == InputMode::Chinese);
        engine.handle_key('z');
        engine.handle_key('z');
        assert_eq!(engine.mode(), InputMode::Chinese);
        assert_eq!(engine.buffer(), "azzz");
    }

    #[test]
    fn test_empty_code_reject_when_not_temp_english() {
        // 选项 1/2：四码空码仍拒绝该键、保持原编码，不转英文
        for action in [1u8, 2] {
            let mut engine = create_test_engine();
            engine.config.empty_code_action = action;
            for c in "aaaa".chars() {
                engine.handle_key(c);
            }
            assert_eq!(engine.mode(), InputMode::Chinese);
            assert_eq!(engine.buffer(), "aaa");
        }
    }

    #[test]
    fn test_take_beep() {
        for (action, expect) in [(1u8, true), (2, false)] {
            let mut engine = create_test_engine();
            engine.config.empty_code_action = action;
            for c in "aaaa".chars() {
                engine.handle_key(c);
            }
            assert_eq!(engine.take_beep(), expect);
            assert!(!engine.take_beep(), "取走后应复位");
        }
        let mut engine = create_test_engine();
        engine.config.empty_code_action = 1;
        engine.handle_key('a');
        assert!(!engine.take_beep());
    }

    #[test]
    fn test_empty_code_skipped_with_pinyin_mixed() {
        // 拼音混输开启时不走空码转英文
        let mut engine = create_test_engine();
        engine.config.pinyin_mixed_enabled = true;
        engine.pinyin_dict = Some(DictEngine::new());
        engine.handle_key('h');
        assert_eq!(engine.mode(), InputMode::Chinese);
        assert_eq!(engine.buffer(), "h");
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
    fn test_temp_english_digits_appended() {
        let mut engine = create_test_engine();
        engine.handle_uppercase('W');
        engine.handle_key('i');
        engine.handle_key('n');
        assert_eq!(engine.handle_number(1), EngineAction::UpdateCandidates);
        assert_eq!(engine.handle_number(0), EngineAction::UpdateCandidates);
        assert_eq!(engine.buffer(), "Win10");
        assert_eq!(
            engine.handle_enter(),
            EngineAction::Commit("Win10".to_string())
        );
        assert_eq!(engine.mode(), InputMode::Chinese);
    }

    #[test]
    fn test_temp_english_punctuation_appended() {
        let mut engine = create_test_engine();
        engine.handle_uppercase('M');
        engine.handle_key('r');
        assert_eq!(
            engine.handle_punctuation('.'),
            EngineAction::UpdateCandidates
        );
        engine.handle_uppercase('S');
        engine.handle_key('m');
        assert_eq!(engine.buffer(), "Mr.Sm");
        assert_eq!(
            engine.handle_punctuation(','),
            EngineAction::UpdateCandidates
        );
        assert_eq!(engine.handle_quote(), EngineAction::UpdateCandidates);
        assert_eq!(engine.buffer(), "Mr.Sm,'");
        assert_eq!(
            engine.handle_enter(),
            EngineAction::Commit("Mr.Sm,'".to_string())
        );
    }

    #[test]
    fn test_uppercase_with_pending_code_keeps_code() {
        let mut engine = create_test_engine();
        engine.handle_key('a');
        engine.handle_key('b');
        let action = engine.handle_uppercase('C');
        assert_eq!(action, EngineAction::UpdateCandidates);
        assert_eq!(engine.mode(), InputMode::TempEnglish);
        assert_eq!(engine.buffer(), "abC");
        assert_eq!(
            engine.handle_space_for_temp_english(),
            Some(EngineAction::Commit("abC".to_string()))
        );
        assert_eq!(engine.mode(), InputMode::Chinese);
    }

    #[test]
    fn test_english_punct_state() {
        let mut engine = create_test_engine();
        assert!(engine.chinese_punct());
        assert!(!engine.toggle_chinese_punct());
        assert!(!engine.chinese_punct());
        for ch in [',', '.', '?', '!', '(', '"', '^', '$'] {
            assert_eq!(
                engine.handle_punctuation(ch),
                EngineAction::Commit(ch.to_string())
            );
        }
        // 有在途编码：照常顶字，标点半角
        engine.handle_key('a');
        assert_eq!(
            engine.handle_punctuation(','),
            EngineAction::Commit("工,".to_string())
        );
        // 非标点集合内的字符仍放行
        assert_eq!(engine.handle_punctuation('/'), EngineAction::Unhandled);
        assert!(engine.toggle_chinese_punct());
        assert_eq!(
            engine.handle_punctuation(','),
            EngineAction::Commit("，".to_string())
        );
    }

    #[test]
    fn test_half_width_default_unchanged() {
        let mut engine = create_test_engine();
        assert!(!engine.full_width());
        assert_eq!(engine.handle_space(), EngineAction::Unhandled);
        assert_eq!(engine.handle_number(3), EngineAction::Unhandled);
        assert_eq!(engine.handle_punctuation('/'), EngineAction::Unhandled);
        engine.toggle_mode();
        assert_eq!(engine.handle_key('a'), EngineAction::Commit("a".into()));
        assert_eq!(engine.handle_number(3), EngineAction::Unhandled);
        assert_eq!(engine.handle_space(), EngineAction::Unhandled);
        assert_eq!(
            engine.handle_punctuation(','),
            EngineAction::Commit(",".into())
        );
    }

    #[test]
    fn test_full_width_english_mode() {
        let mut engine = create_test_engine();
        assert!(engine.toggle_full_width());
        engine.toggle_mode();
        assert_eq!(engine.handle_key('a'), EngineAction::Commit("ａ".into()));
        assert_eq!(
            engine.handle_uppercase('A'),
            EngineAction::Commit("Ａ".into())
        );
        assert_eq!(engine.handle_number(3), EngineAction::Commit("３".into()));
        assert_eq!(engine.handle_number(0), EngineAction::Commit("０".into()));
        assert_eq!(
            engine.handle_space(),
            EngineAction::Commit("\u{3000}".into())
        );
        assert_eq!(
            engine.handle_punctuation(','),
            EngineAction::Commit("，".into())
        );
        assert_eq!(
            engine.handle_punctuation('/'),
            EngineAction::Commit("／".into())
        );
        assert_eq!(engine.handle_semicolon(), EngineAction::Commit("；".into()));
        assert_eq!(engine.handle_quote(), EngineAction::Commit("＇".into()));
        // 切回半角恢复原行为
        assert!(!engine.toggle_full_width());
        assert_eq!(engine.handle_key('a'), EngineAction::Commit("a".into()));
    }

    #[test]
    fn test_full_width_chinese_mode() {
        let mut engine = create_test_engine();
        engine.toggle_full_width();
        assert_eq!(engine.handle_number(1), EngineAction::Commit("１".into()));
        assert_eq!(
            engine.handle_space(),
            EngineAction::Commit("\u{3000}".into())
        );
        // 中文标点映射结果本就全角；半角映射的符号转全角
        assert_eq!(
            engine.handle_punctuation(','),
            EngineAction::Commit("，".into())
        );
        assert_eq!(
            engine.handle_punctuation('@'),
            EngineAction::Commit("＠".into())
        );
        assert_eq!(
            engine.handle_punctuation('/'),
            EngineAction::Commit("／".into())
        );
        // 数字后的小数点也是全角
        engine.handle_number(3);
        assert_eq!(
            engine.handle_punctuation('.'),
            EngineAction::Commit("．".into())
        );
        // 英文标点 + 全角
        engine.toggle_chinese_punct();
        assert_eq!(
            engine.handle_punctuation(','),
            EngineAction::Commit("，".into())
        );
        assert_eq!(
            engine.handle_punctuation('.'),
            EngineAction::Commit("．".into())
        );
        // 编码输入与选词不受影响
        engine.handle_key('a');
        assert_eq!(engine.buffer(), "a");
        assert_eq!(engine.handle_space(), EngineAction::Commit("工".into()));
    }

    #[test]
    fn test_full_width_temp_english_commit() {
        let mut engine = create_test_engine();
        engine.toggle_full_width();
        engine.handle_uppercase('M');
        engine.handle_key('r');
        engine.handle_punctuation('.');
        engine.handle_number(2);
        assert_eq!(engine.buffer(), "Mr.2");
        assert_eq!(
            engine.handle_enter(),
            EngineAction::Commit("Ｍｒ．２".into())
        );
        engine.handle_uppercase('A');
        assert_eq!(
            engine.handle_space_for_temp_english(),
            Some(EngineAction::Commit("Ａ".into()))
        );
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
nihao\t你好\t9100
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
        // 输入 "nihao"（5 码）应匹配拼音 "你好"；z 开头的长拼音改走临时拼音（见 test_temp_pinyin_*）
        for c in "nihao".chars() {
            engine.handle_key(c);
        }
        let candidates = engine.candidates();
        assert!(candidates.iter().any(|c| c.text == "你好"));
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

    // ==================== z 临时拼音反查 ====================

    fn create_temp_pinyin_engine(code_hint: bool) -> InputEngine {
        let mut dict = DictEngine::new();
        dict.load_from_str(
            "a\t工\t9999
vbg\t好\t10
vb\t好\t10
tgbg\t号\t10
egn\t毫\t10
uwgn\t状\t10
",
        );
        let mut pinyin_dict = DictEngine::new();
        pinyin_dict.load_from_str(
            "hao\t好\t9000
hao\t号\t8000
hao\t毫\t7000
zhuang\t状\t9000
zhuang\t壮\t8000
",
        );
        let config = Config {
            candidate_count: 5,
            auto_commit_on_unique_four: true,
            auto_commit_first_five: true,
            wildcard_z_enabled: true,
            pinyin_mixed_enabled: false,
            code_hint,
            ..Config::default()
        };
        let mut engine = InputEngine::new(dict, UserDict::new(), config);
        engine.set_pinyin_dict(pinyin_dict);
        engine
    }

    fn type_keys(engine: &mut InputEngine, keys: &str) {
        for c in keys.chars() {
            engine.handle_key(c);
        }
    }

    #[test]
    fn test_temp_pinyin_candidates_and_hint() {
        let mut engine = create_temp_pinyin_engine(true);
        type_keys(&mut engine, "zhao");
        let texts: Vec<&str> = engine
            .candidates()
            .iter()
            .map(|c| c.text.as_str())
            .collect();
        assert_eq!(texts, ["好", "号", "毫"]);
        assert_eq!(hint_of(&engine, "好"), "vb"); // 取最短五笔编码
        assert_eq!(hint_of(&engine, "号"), "tgbg");
        assert_eq!(engine.mode(), InputMode::Chinese);
    }

    #[test]
    fn test_temp_pinyin_hint_empty_without_wubi_code() {
        let mut engine = create_temp_pinyin_engine(true);
        type_keys(&mut engine, "zzhuang");
        assert_eq!(hint_of(&engine, "状"), "uwgn");
        assert_eq!(hint_of(&engine, "壮"), "");
    }

    #[test]
    fn test_temp_pinyin_long_input_no_auto_commit() {
        for auto_commit in [true, false] {
            let mut engine = create_temp_pinyin_engine(true);
            engine.set_config(true, auto_commit, 0, 0, 5, false);
            type_keys(&mut engine, "zzhuang");
            assert_eq!(engine.buffer(), "zzhuang");
            assert_eq!(engine.candidates().len(), 2);
        }
    }

    #[test]
    fn test_temp_pinyin_no_match_keeps_buffer_no_english_no_beep() {
        for action in [0u8, 1, 2] {
            let mut engine = create_temp_pinyin_engine(true);
            engine.set_config(true, true, 0, action, 5, false);
            type_keys(&mut engine, "zqxjkw");
            assert_eq!(engine.buffer(), "zqxjkw");
            assert!(engine.candidates().is_empty());
            assert_eq!(engine.mode(), InputMode::Chinese);
            assert!(!engine.take_beep());
            assert_eq!(engine.handle_space(), EngineAction::UpdateCandidates);
            assert_eq!(engine.buffer(), "zqxjkw");
        }
    }

    #[test]
    fn test_temp_pinyin_single_z_no_empty_code() {
        let mut engine = create_temp_pinyin_engine(true);
        engine.handle_key('z');
        assert_eq!(engine.buffer(), "z");
        assert!(engine.candidates().is_empty());
        assert_eq!(engine.mode(), InputMode::Chinese);
        assert!(!engine.take_beep());
    }

    #[test]
    fn test_temp_pinyin_non_leading_z_stays_wildcard() {
        let mut engine = create_temp_pinyin_engine(true);
        type_keys(&mut engine, "az");
        assert_eq!(engine.buffer(), "az");
        assert_eq!(engine.mode(), InputMode::Chinese);
        // az 走万能键等长匹配，不是拼音（码表无 a? 的二码条目，故为空），且不转英文
        assert!(engine.candidates().iter().all(|c| c.code.len() == 2));
    }

    #[test]
    fn test_temp_pinyin_commit_returns_to_wubi_and_skips_learning() {
        let mut engine = create_temp_pinyin_engine(true);
        type_keys(&mut engine, "zhao");
        assert_eq!(engine.handle_space(), EngineAction::Commit("好".into()));
        assert_eq!(engine.buffer(), "");
        assert!(engine.user_dict().lookup("hao").is_empty());
        assert!(engine.user_dict().lookup("zhao").is_empty());
        assert!(engine.user_dict().lookup("vb").is_empty());
        // 回到正常五笔：a 出候选，四码规则恢复
        engine.handle_key('a');
        assert_eq!(engine.candidates()[0].text, "工");
        // 数字选字 / ; 选二候选同样不学习
        engine.handle_escape();
        type_keys(&mut engine, "zhao");
        assert_eq!(engine.handle_semicolon(), EngineAction::Commit("号".into()));
        type_keys(&mut engine, "zhao");
        assert_eq!(engine.handle_number(3), EngineAction::Commit("毫".into()));
        assert!(engine.user_dict().lookup("hao").is_empty());
        assert!(engine.user_dict().lookup("zhao").is_empty());
    }

    #[test]
    fn test_temp_pinyin_unaffected_by_code_hint_off() {
        let mut engine = create_temp_pinyin_engine(false);
        type_keys(&mut engine, "zhao");
        assert_eq!(engine.candidates().len(), 3);
        assert_eq!(hint_of(&engine, "好"), "vb");
        // 拼音前缀匹配（ha → hao）在逐码提示关闭时也保留
        engine.handle_backspace();
        engine.handle_backspace();
        assert_eq!(engine.buffer(), "zh");
        assert_eq!(engine.candidates().len(), 3);
    }

    #[test]
    fn test_temp_pinyin_backspace_and_escape() {
        let mut engine = create_temp_pinyin_engine(true);
        type_keys(&mut engine, "zhao");
        engine.handle_backspace();
        engine.handle_backspace();
        engine.handle_backspace();
        assert_eq!(engine.buffer(), "z");
        assert!(engine.candidates().is_empty());
        assert_eq!(engine.handle_backspace(), EngineAction::Reset);
        type_keys(&mut engine, "zhao");
        assert_eq!(engine.handle_escape(), EngineAction::Reset);
        assert_eq!(engine.buffer(), "");
    }

    #[test]
    fn test_temp_pinyin_independent_of_wildcard_switch() {
        let mut engine = create_temp_pinyin_engine(true);
        engine.config.wildcard_z_enabled = false;
        type_keys(&mut engine, "zhao");
        assert_eq!(engine.candidates().len(), 3);
    }

    #[test]
    fn test_real_dict_no_premature_temp_english() {
        // 逐码提示开/关两种配置下都不得误判空码
        // 「仅常用字」开关同样不得改变空码判定
        for code_hint in [true, false] {
            for common_chars_only in [false, true] {
                check_real_dict_no_premature_temp_english(code_hint, common_chars_only);
            }
        }
    }

    fn check_real_dict_no_premature_temp_english(code_hint: bool, common_chars_only: bool) {
        // 真实码表穷举：敲码表里任一编码时，其任何真前缀都不得被判空码而转临时英文
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("data/wubi86.txt");
        let mut dict = DictEngine::new();
        dict.load_from_file(&path).unwrap();
        // 去重后的全部真前缀（前缀判定只取决于前缀本身）
        let content = std::fs::read_to_string(&path).unwrap();
        let mut prefixes = std::collections::BTreeSet::new();
        let mut total = 0;
        for line in content.lines().filter(|l| !l.starts_with('#')) {
            let Some(code) = line.split('\t').next().filter(|c| !c.is_empty()) else {
                continue;
            };
            total += 1;
            for n in 1..code.len() {
                prefixes.insert(code[..n].to_string());
            }
        }
        assert!(total > 1000);

        let config = Config {
            candidate_count: 5,
            auto_commit_on_unique_four: true,
            wildcard_z_enabled: true,
            code_hint,
            common_chars_only,
            ..Config::default()
        };
        let mut engine = InputEngine::new(dict, UserDict::new(), config);
        let mut affected = Vec::new();
        for prefix in &prefixes {
            // 前缀按字典序遍历：退格回到与上一前缀的公共部分，只补敲差异键，避免重复查询
            let common = engine
                .buffer()
                .bytes()
                .zip(prefix.bytes())
                .take_while(|(a, b)| a == b)
                .count();
            while engine.buffer().len() > common {
                engine.handle_backspace();
            }
            for c in prefix[common..].chars() {
                engine.handle_key(c);
            }
            if engine.mode() == InputMode::TempEnglish {
                affected.push(prefix.clone());
                engine.reset_input();
            }
        }
        assert!(
            affected.is_empty(),
            "code_hint={} common_chars_only={} 码表 {} 条、{} 个真前缀中 {} 个被误判空码，例: {:?}",
            code_hint,
            common_chars_only,
            total,
            prefixes.len(),
            affected.len(),
            &affected[..affected.len().min(10)]
        );
    }

    // ==================== 编码提示 / 逐码提示 ====================

    fn hint_engine(code_hint: bool) -> InputEngine {
        let mut engine = create_test_engine();
        engine.set_code_hint(code_hint);
        engine
    }

    fn hint_of(engine: &InputEngine, text: &str) -> String {
        engine
            .candidates()
            .iter()
            .find(|c| c.text == text)
            .unwrap()
            .hint
            .clone()
    }

    #[test]
    fn test_hint_exact_and_prefix() {
        let mut engine = hint_engine(true);
        engine.handle_key('a');
        assert_eq!(hint_of(&engine, "工"), ""); // 精确匹配无提示
        assert_eq!(hint_of(&engine, "式"), "a"); // aa 去掉 a
        assert_eq!(hint_of(&engine, "芝"), "ad");
        engine.handle_key('a');
        assert_eq!(hint_of(&engine, "式"), "");
        assert_eq!(hint_of(&engine, "芝"), "d");
        engine.handle_key('d');
        assert_eq!(hint_of(&engine, "芽"), "k");
    }

    #[test]
    fn test_hint_user_dict() {
        let mut engine = hint_engine(true);
        engine.add_user_word("a".into(), "自".into());
        engine.handle_key('a');
        assert_eq!(hint_of(&engine, "自"), "");
        assert!(engine.candidates()[0].is_user);
        assert_eq!(hint_of(&engine, "式"), "a");
    }

    #[test]
    fn test_hint_wildcard_gives_full_code() {
        let mut engine = hint_engine(true);
        engine.handle_key('a');
        engine.handle_key('z');
        assert_eq!(hint_of(&engine, "式"), "aa");
        assert_eq!(hint_of(&engine, "节"), "ab");
    }

    #[test]
    fn test_code_hint_off_only_exact() {
        let mut engine = hint_engine(false);
        engine.handle_key('a');
        let texts: Vec<&str> = engine
            .candidates()
            .iter()
            .map(|c| c.text.as_str())
            .collect();
        assert_eq!(texts, vec!["工"]);
        engine.handle_key('a');
        let texts: Vec<&str> = engine
            .candidates()
            .iter()
            .map(|c| c.text.as_str())
            .collect();
        assert_eq!(texts, vec!["式"]);
        // 开启时同样的编码含补充候选
        let mut on = hint_engine(true);
        on.handle_key('a');
        assert!(on.candidates().len() > 1);
    }

    #[test]
    fn test_code_hint_off_wildcard_still_works() {
        let mut engine = hint_engine(false);
        engine.handle_key('a');
        engine.handle_key('z');
        assert!(engine.candidates().iter().any(|c| c.text == "式"));
    }

    #[test]
    fn test_code_hint_off_mid_prefix_not_empty_code() {
        // abc 无精确候选，但 abcn 存在：不得转临时英文，继续敲码可出字
        let mut engine = hint_engine(false);
        engine.handle_key('a');
        engine.handle_key('b');
        engine.handle_key('c');
        assert_eq!(engine.mode(), InputMode::Chinese);
        assert_eq!(engine.buffer(), "abc");
        assert!(engine.candidates().is_empty());
        // 无候选时空格 / 数字吞掉且不丢编码
        assert_eq!(engine.handle_space(), EngineAction::UpdateCandidates);
        assert_eq!(engine.handle_number(1), EngineAction::UpdateCandidates);
        assert_eq!(engine.buffer(), "abc");
        // 第四码到达唯一精确候选 -> 自动上屏
        assert_eq!(engine.handle_key('n'), EngineAction::Commit("苦".into()));
    }

    #[test]
    fn test_code_hint_off_true_empty_code_still_temp_english() {
        let mut engine = hint_engine(false);
        engine.handle_key('x');
        assert_eq!(engine.mode(), InputMode::TempEnglish);
    }

    #[test]
    fn test_code_hint_off_four_code_zero_match_rejected_like_on() {
        for hint in [true, false] {
            let mut engine = hint_engine(hint);
            engine.set_config(true, true, 0, 2, 5, false);
            for k in ['a', 'b', 'c'] {
                engine.handle_key(k);
            }
            engine.handle_key('x'); // abcx 无任何匹配：拒绝
            assert_eq!(engine.buffer(), "abc", "code_hint={hint}");
            assert_eq!(engine.mode(), InputMode::Chinese);
        }
    }

    #[test]
    fn test_unique_four_auto_commit_same_both_configs() {
        for hint in [true, false] {
            let mut engine = hint_engine(hint);
            for k in ['g', 'g', 'l'] {
                engine.handle_key(k);
            }
            assert_eq!(
                engine.handle_key('f'),
                EngineAction::Commit("王".into()),
                "code_hint={hint}"
            );
        }
        // 四码精确唯一但另有更长编码时：开/关都不自动上屏
        for hint in [true, false] {
            let config = Config {
                code_hint: hint,
                ..Config::default()
            };
            let mut engine = InputEngine::new(
                {
                    let mut d = DictEngine::new();
                    d.load_from_str("abcd\t甲\t100\nabcde\t乙\t100\n");
                    d
                },
                UserDict::new(),
                config,
            );
            for k in ['a', 'b', 'c'] {
                engine.handle_key(k);
            }
            assert_eq!(
                engine.handle_key('d'),
                EngineAction::UpdateCandidates,
                "code_hint={hint}"
            );
            assert_eq!(engine.buffer(), "abcd");
        }
    }

    // ==================== 繁体输出 / 仅常用字 ====================

    fn charset_engine() -> InputEngine {
        let mut dict = DictEngine::new();
        dict.load_from_str(
            "a\t国\t9000
a\t龘\t8000
b\t汉语\t9000
c\t龘龘\t9000
ffff\t龘\t9000
gggg\t王\t9000
gggg\t龘\t8000
hhhh\t龘\t9000
hhhh\t国\t8000
",
        );
        let config = Config {
            candidate_count: 5,
            ..Config::default()
        };
        InputEngine::new(dict, UserDict::new(), config)
    }

    fn type_last(engine: &mut InputEngine, keys: &str) -> EngineAction {
        let mut last = EngineAction::Reset;
        for c in keys.chars() {
            last = engine.handle_key(c);
        }
        last
    }

    fn texts(engine: &InputEngine) -> Vec<String> {
        engine.candidates().iter().map(|c| c.text.clone()).collect()
    }

    #[test]
    fn test_traditional_output_char_phrase_and_unknown() {
        let mut engine = charset_engine();
        assert!(!engine.traditional());
        assert!(engine.toggle_traditional());
        engine.handle_key('a');
        // 候选内部仍为简体；输出边界转换，未收录字（龘）原样
        assert_eq!(texts(&engine), vec!["国", "龘"]);
        assert_eq!(engine.output_text("国"), "國");
        assert_eq!(engine.output_text("龘"), "龘");
        assert_eq!(engine.handle_space(), EngineAction::Commit("國".into()));
        engine.handle_key('b');
        assert_eq!(engine.output_text("汉语"), "漢語");
        assert_eq!(engine.handle_space(), EngineAction::Commit("漢語".into()));
    }

    #[test]
    fn test_traditional_off_unchanged() {
        let mut engine = charset_engine();
        engine.handle_key('a');
        assert_eq!(engine.handle_space(), EngineAction::Commit("国".into()));
    }

    #[test]
    fn test_traditional_commit_paths() {
        let mut engine = charset_engine();
        engine.set_traditional(true);
        // 数字键选词
        type_keys(&mut engine, "gggg");
        assert_eq!(engine.handle_number(1), EngineAction::Commit("王".into()));
        // 标点顶字：标点本身不转换
        engine.handle_key('a');
        assert_eq!(
            engine.handle_punctuation(','),
            EngineAction::Commit("國，".into())
        );
        // 分号选第二候选
        engine.handle_key('a');
        assert_eq!(engine.handle_semicolon(), EngineAction::Commit("龘".into()));
        // 四码唯一自动上屏
        let mut engine = charset_engine();
        engine.set_traditional(true);
        engine.set_common_chars_only(true);
        assert_eq!(
            type_last(&mut engine, "hhhh"),
            EngineAction::Commit("國".into())
        );
    }

    #[test]
    fn test_traditional_does_not_affect_learning_or_buffers() {
        let mut engine = charset_engine();
        engine.set_traditional(true);
        engine.add_user_word("a".into(), "国".into());
        engine.handle_key('a');
        // 用户词典候选为简体内部值
        assert!(engine.candidates()[0].is_user);
        assert_eq!(engine.candidates()[0].text, "国");
        assert_eq!(engine.handle_space(), EngineAction::Commit("國".into()));
        // 学习/用户词典里存的仍是简体
        let stored: Vec<String> = engine
            .user_dict()
            .lookup("a")
            .iter()
            .map(|e| e.text.clone())
            .collect();
        assert!(stored.contains(&"国".to_string()));
        assert!(!stored.contains(&"國".to_string()));
        // 编码缓冲、临时英文不转换
        engine.handle_key('a');
        assert_eq!(engine.buffer(), "a");
        engine.handle_uppercase('X');
        assert_eq!(engine.buffer(), "aX");
    }

    #[test]
    fn test_traditional_pinyin_candidates() {
        let mut engine = create_temp_pinyin_engine(true);
        engine.set_traditional(true);
        type_keys(&mut engine, "zzhuang");
        assert_eq!(texts(&engine), vec!["状", "壮"]);
        assert_eq!(engine.handle_space(), EngineAction::Commit("狀".into()));
    }

    #[test]
    fn test_common_chars_filter_single_and_phrase() {
        let mut engine = charset_engine();
        engine.handle_key('a');
        assert_eq!(texts(&engine), vec!["国", "龘"]);
        engine.reset_input();
        engine.set_common_chars_only(true);
        engine.handle_key('a');
        assert_eq!(texts(&engine), vec!["国"]);
        engine.reset_input();
        // 词组：任一汉字不在 GB2312 即过滤；全合规词组保留
        engine.handle_key('c');
        assert!(engine.candidates().is_empty());
        engine.reset_input();
        engine.handle_key('b');
        assert_eq!(texts(&engine), vec!["汉语"]);
    }

    #[test]
    fn test_common_chars_off_unchanged() {
        let mut engine = charset_engine();
        engine.set_common_chars_only(true);
        engine.set_common_chars_only(false);
        engine.handle_key('c');
        assert_eq!(texts(&engine), vec!["龘龘"]);
    }

    #[test]
    fn test_common_chars_unique_four_uses_visible_candidates() {
        // 过滤前 gggg 有 2 个候选；过滤后唯一 → 自动上屏
        let mut engine = charset_engine();
        engine.set_common_chars_only(true);
        let action = type_last(&mut engine, "gggg");
        assert_eq!(action, EngineAction::Commit("王".into()));
        // 过滤关闭时不自动上屏
        let mut engine = charset_engine();
        type_keys(&mut engine, "gggg");
        assert_eq!(engine.candidates().len(), 2);
        // hhhh：过滤前 2 个、过滤后 1 个（国），同样自动上屏
        let mut engine = charset_engine();
        engine.set_common_chars_only(true);
        assert_eq!(
            type_last(&mut engine, "hhhh"),
            EngineAction::Commit("国".into())
        );
    }

    #[test]
    fn test_common_chars_all_filtered_is_not_empty_code() {
        // ffff 只有生僻字：不自动上屏、不转临时英文，候选为空但编码仍存在
        let mut engine = charset_engine();
        engine.set_common_chars_only(true);
        type_keys(&mut engine, "ffff");
        assert_eq!(engine.mode(), InputMode::Chinese);
        assert_eq!(engine.buffer(), "ffff");
        assert!(engine.candidates().is_empty());
        // 其前缀 fff 同样不被判空码
        engine.handle_backspace();
        assert_eq!(engine.mode(), InputMode::Chinese);
        assert_eq!(engine.buffer(), "fff");
    }

    #[test]
    fn test_common_chars_filters_temp_pinyin() {
        let mut dict = DictEngine::new();
        dict.load_from_str("a\t工\t9999\n");
        let mut pinyin = DictEngine::new();
        pinyin.load_from_str("wang\t王\t9000\nwang\t龘\t8000\n");
        let mut engine = InputEngine::new(dict, UserDict::new(), Config::default());
        engine.set_pinyin_dict(pinyin);
        engine.set_common_chars_only(true);
        type_keys(&mut engine, "zwang");
        assert_eq!(texts(&engine), vec!["王"]);
    }

    #[test]
    fn test_traditional_and_common_chars_together() {
        let mut engine = charset_engine();
        engine.set_traditional(true);
        engine.set_common_chars_only(true);
        engine.handle_key('a');
        // 过滤基于简体字：国保留（输出為國），龘被过滤
        assert_eq!(texts(&engine), vec!["国"]);
        assert_eq!(engine.handle_space(), EngineAction::Commit("國".into()));
        engine.handle_key('b');
        assert_eq!(engine.handle_space(), EngineAction::Commit("漢語".into()));
    }

    // ==================== 自造词 / 自动造词 ====================

    #[test]
    fn test_custom_word_candidates_prefix_hint_and_dedup() {
        let mut engine = create_test_engine();
        engine
            .user_dict
            .add_custom("aadk".into(), "自造".into(), 500);
        // 与码表同码同词：不重复出现
        engine.user_dict.add_custom("ab".into(), "节".into(), 500);
        engine.handle_key('a');
        assert_eq!(
            engine.candidates.iter().filter(|c| c.text == "节").count(),
            1
        );
        // 前缀补充：自造词排在精确匹配之后，带剩余编码提示
        assert_eq!(engine.candidates()[0].text, "工");
        engine.handle_key('a');
        assert_eq!(engine.candidates()[0].text, "式");
        assert_eq!(hint_of(&engine, "自造"), "dk");
        engine.handle_key('d');
        assert_eq!(hint_of(&engine, "自造"), "k");
        // 精确匹配（与码表「芽」同码）：用户加成排第一、无提示
        engine.handle_key('k');
        assert_eq!(engine.candidates()[0].text, "自造");
        assert_eq!(hint_of(&engine, "自造"), "");
        engine.handle_escape();
        engine.handle_key('a');
        engine.handle_key('b');
        assert_eq!(
            engine.candidates.iter().filter(|c| c.text == "节").count(),
            1
        );
    }

    #[test]
    fn test_custom_only_code_prefix_not_empty_code() {
        // xyuv 只存在于用户自造词：其真前缀 x / xy / xyu 不得被判空码转临时英文
        for code_hint in [true, false] {
            let mut engine = hint_engine(code_hint);
            engine
                .user_dict
                .add_custom("xyuv".into(), "自造".into(), 500);
            for k in ['x', 'y', 'u'] {
                engine.handle_key(k);
                assert_eq!(engine.mode(), InputMode::Chinese, "code_hint={code_hint}");
            }
            assert_eq!(engine.buffer(), "xyu");
            // 四码唯一：自动上屏
            assert_eq!(engine.handle_key('v'), EngineAction::Commit("自造".into()));
            // 真空码仍转临时英文
            engine.handle_key('x');
            engine.handle_key('q');
            assert_eq!(engine.mode(), InputMode::TempEnglish);
        }
    }

    #[test]
    fn test_custom_word_counts_for_unique_four() {
        let mut engine = create_test_engine();
        engine
            .user_dict
            .add_custom("abcn".into(), "苦瓜".into(), 500);
        type_keys(&mut engine, "abcn");
        // 码表「苦」+ 自造词「苦瓜」：非唯一，不自动上屏
        assert_eq!(engine.buffer(), "abcn");
        assert_eq!(engine.candidates().len(), 2);
    }

    fn phrase_engine(auto_phrase: bool) -> InputEngine {
        let mut dict = DictEngine::new();
        dict.load_from_str(
            "jfwk\t晗\t10
agnt\t戈\t10
agnt\t戋\t5
lgyi\t国\t10
ygkg\t语\t10
gghg\t五\t10
ttfn\t笔\t10
gtgt\t五笔\t10
",
        );
        let mut pinyin = DictEngine::new();
        pinyin.load_from_str("ge\t戈\t9000\n");
        let config = Config {
            auto_phrase,
            ..Config::default()
        };
        let mut engine = InputEngine::new(dict, UserDict::new(), config);
        engine.set_pinyin_dict(pinyin);
        engine
    }

    /// 逐字打出「晗戈」：晗经四码唯一自动上屏，戈经空格选首选
    fn type_hange(engine: &mut InputEngine) {
        assert_eq!(type_last(engine, "jfwk"), EngineAction::Commit("晗".into()));
        type_keys(engine, "agnt");
        assert_eq!(engine.handle_space(), EngineAction::Commit("戈".into()));
    }

    fn custom_words_of(engine: &InputEngine) -> Vec<(String, String)> {
        engine.custom_words()
    }

    #[test]
    fn test_add_custom_word_api() {
        let mut engine = phrase_engine(false);
        assert_eq!(engine.preview_word_code("晗戈").as_deref(), Some("jfag"));
        assert_eq!(engine.add_custom_word("晗戈"), Ok("jfag".into()));
        assert_eq!(engine.add_custom_word("晗戈"), Err(AddWordError::Exists));
        assert_eq!(engine.add_custom_word("五笔"), Err(AddWordError::Exists));
        assert_eq!(engine.add_custom_word("晗"), Err(AddWordError::Exists));
        assert_eq!(
            engine.add_custom_word("晗龘"),
            Err(AddWordError::Unencodable)
        );
        assert_eq!(
            engine.add_custom_word("晗A"),
            Err(AddWordError::Unencodable)
        );
        // 四码唯一：自动上屏
        assert_eq!(
            type_last(&mut engine, "jfag"),
            EngineAction::Commit("晗戈".into())
        );
        assert!(engine.remove_custom_word("晗戈", "jfag"));
        assert!(custom_words_of(&engine).is_empty());
    }

    #[test]
    fn test_auto_phrase_on_second_occurrence() {
        let mut engine = phrase_engine(true);
        type_hange(&mut engine);
        assert!(custom_words_of(&engine).is_empty());
        engine.handle_enter(); // 打断（空编码回车）
        type_hange(&mut engine);
        assert_eq!(
            custom_words_of(&engine),
            vec![("晗戈".to_string(), "jfag".to_string())]
        );
        // 入库后可直接打出
        assert_eq!(
            type_last(&mut engine, "jfag"),
            EngineAction::Commit("晗戈".into())
        );
    }

    #[test]
    fn test_auto_phrase_interrupted_not_added() {
        let mut engine = phrase_engine(true);
        for _ in 0..3 {
            assert_eq!(
                type_last(&mut engine, "jfwk"),
                EngineAction::Commit("晗".into())
            );
            engine.handle_backspace(); // 空编码退格：打断
            type_keys(&mut engine, "agnt");
            engine.handle_space();
            assert_eq!(
                engine.handle_punctuation(','),
                EngineAction::Commit("，".into())
            );
        }
        // 标点顶字：上屏的字计入，但标点之后打断
        for _ in 0..2 {
            type_keys(&mut engine, "jfwk");
            type_keys(&mut engine, "agnt");
            engine.handle_punctuation(',');
        }
        assert_eq!(
            custom_words_of(&engine),
            vec![("晗戈".to_string(), "jfag".to_string())]
        );
        // 多字词上屏同样打断
        let mut engine = phrase_engine(true);
        for _ in 0..2 {
            type_keys(&mut engine, "jfwk");
            type_keys(&mut engine, "gtgt");
            engine.handle_space();
            type_keys(&mut engine, "agnt");
            engine.handle_space();
            engine.handle_escape();
        }
        assert!(custom_words_of(&engine).is_empty());
    }

    #[test]
    fn test_auto_phrase_off_and_dict_word_not_added() {
        let mut engine = phrase_engine(false);
        for _ in 0..3 {
            type_hange(&mut engine);
            engine.handle_escape();
        }
        assert!(custom_words_of(&engine).is_empty());
        // 码表已有的词（五笔）不入库
        let mut engine = phrase_engine(true);
        for _ in 0..3 {
            type_keys(&mut engine, "gghg");
            type_keys(&mut engine, "ttfn");
            engine.handle_escape();
        }
        assert!(custom_words_of(&engine).is_empty());
        // 关闭开关清空计数：开→一次→关→开→一次，不入库
        let mut engine = phrase_engine(true);
        type_hange(&mut engine);
        engine.set_auto_phrase(false);
        engine.set_auto_phrase(true);
        engine.handle_escape();
        type_hange(&mut engine);
        assert!(custom_words_of(&engine).is_empty());
    }

    #[test]
    fn test_auto_phrase_skips_temp_pinyin() {
        let mut engine = phrase_engine(true);
        for _ in 0..3 {
            type_keys(&mut engine, "jfwk");
            type_keys(&mut engine, "zge");
            assert_eq!(engine.handle_space(), EngineAction::Commit("戈".into()));
            engine.handle_escape();
        }
        assert!(custom_words_of(&engine).is_empty());
    }

    #[test]
    fn test_auto_phrase_records_simplified_when_traditional() {
        let mut engine = phrase_engine(true);
        engine.set_traditional(true);
        for _ in 0..2 {
            assert_eq!(
                type_last(&mut engine, "lgyi"),
                EngineAction::Commit("國".into())
            );
            assert_eq!(
                type_last(&mut engine, "ygkg"),
                EngineAction::Commit("語".into())
            );
            engine.handle_escape();
        }
        assert_eq!(
            custom_words_of(&engine),
            vec![("国语".to_string(), "lgyg".to_string())]
        );
    }

    // ==================== 词语联想 ====================

    fn assoc_engine() -> InputEngine {
        let mut dict = DictEngine::new();
        dict.load_from_str(
            "a\t中\t9000
aa\t中国\t8000
aab\t中华人民共和国\t3000
ab\t中间\t7000
aac\t中国人\t6000
b\t国\t9000
bb\t国家\t8000
c\t人\t9000
gggg\t王\t9000
dddd\t大\t9000
dddd\t犬\t8000
d\t大\t5000
da\t大家\t4900
db\t大人\t4800
dc\t大国\t4700
dd\t大中\t4600
de\t大王\t4500
df\t大鹏\t4400
",
        );
        let mut pinyin = DictEngine::new();
        pinyin.load_from_str("zhong\t中\t9000\n");
        let config = Config {
            candidate_count: 5,
            ..Config::default()
        };
        let mut engine = InputEngine::new(dict, UserDict::new(), config);
        engine.set_pinyin_dict(pinyin);
        engine
    }

    /// 按操作串驱动引擎（k:字母 / upper:大写 / num:数字 / punct:标点 / space / bs / esc / enter / semi / quote / next / prev）
    fn apply_op(engine: &mut InputEngine, op: &str) -> EngineAction {
        let arg = op.split_once(':').map(|(_, a)| a.chars().next().unwrap());
        match op.split(':').next().unwrap() {
            "k" => engine.handle_key(arg.unwrap()),
            "upper" => engine.handle_uppercase(arg.unwrap()),
            "num" => engine.handle_number(arg.unwrap().to_digit(10).unwrap() as usize),
            "punct" => engine.handle_punctuation(arg.unwrap()),
            "space" => engine
                .handle_space_for_temp_english()
                .unwrap_or_else(|| engine.handle_space()),
            "bs" => engine.handle_backspace(),
            "esc" => engine.handle_escape(),
            "enter" => engine.handle_enter(),
            "semi" => engine.handle_semicolon(),
            "quote" => engine.handle_quote(),
            "next" => engine.next_page(),
            "prev" => engine.prev_page(),
            other => panic!("unknown op {other}"),
        }
    }

    /// 每步记录：动作 | 缓冲 | 模式 | 当前页候选（输出形式）| beep
    fn run_trace(engine: &mut InputEngine, ops: &[&str]) -> Vec<String> {
        ops.iter()
            .map(|op| {
                let action = apply_op(engine, op);
                let cands: Vec<String> = engine
                    .candidates()
                    .iter()
                    .map(|c| engine.output_text(&c.text))
                    .collect();
                let beep = engine.take_beep();
                format!(
                    "{op} => {action:?} | {} | {:?} | {} | {beep}",
                    engine.buffer(),
                    engine.mode(),
                    cands.join(","),
                )
            })
            .collect()
    }

    const REGRESSION_OPS: &[&str] = &[
        // 空格选字 / 数字选字
        "k:a", "space", "k:a", "num:2", // 四码唯一自动上屏
        "k:g", "k:g", "k:g", "k:g", // 第五码顶字
        "k:d", "k:d", "k:d", "k:d", "k:a",     // 标点顶字
        "punct:,", // 空编码空格 / 数字 / 数字后小数点
        "space", "num:3", "punct:.", "punct:.", // 翻页后选字
        "k:d", "next", "next", "prev", "next", "num:2", // 退格
        "bs", "k:a", "k:a", "bs", "bs", // 临时英文（分号引导）
        "semi", "k:h", "k:i", "space", // 临时拼音
        "k:z", "k:z", "k:h", "k:o", "k:n", "k:g", "space",
        // 大写临时英文 + 回车
        "upper:H", "k:i", "enter", // 单引号选第三 / 分号选第二
        "k:a", "quote", "k:a", "semi",
        // 空编码 Esc / 回车 / 编码回车 / 数字 0 / 单引号标点
        "esc", "enter", "k:a", "enter", "num:0", "quote", "k:b", "k:b", "esc",
        // 空码转临时英文
        "k:q", "k:q", "space",
    ];

    const REGRESSION_EXPECTED: &[&str] = &[
        "k:a => UpdateCandidates | a | Chinese | 中,中国,中间,中国人,中华人民共和国 | false",
        "space => Commit(\"中\") |  | Chinese |  | false",
        "k:a => UpdateCandidates | a | Chinese | 中,中国,中间,中国人,中华人民共和国 | false",
        "num:2 => Commit(\"中国\") |  | Chinese |  | false",
        "k:g => UpdateCandidates | g | Chinese | 王 | false",
        "k:g => UpdateCandidates | gg | Chinese | 王 | false",
        "k:g => UpdateCandidates | ggg | Chinese | 王 | false",
        "k:g => Commit(\"王\") |  | Chinese |  | false",
        "k:d => UpdateCandidates | d | Chinese | 大,大家,大人,大国,大中 | false",
        "k:d => UpdateCandidates | dd | Chinese | 大中,大,犬 | false",
        "k:d => UpdateCandidates | ddd | Chinese | 大,犬 | false",
        "k:d => UpdateCandidates | dddd | Chinese | 大,犬 | false",
        "k:a => Commit(\"大\") | a | Chinese | 中,中国,中间,中国人,中华人民共和国 | false",
        "punct:, => Commit(\"中，\") |  | Chinese |  | false",
        "space => Unhandled |  | Chinese |  | false",
        "num:3 => Unhandled |  | Chinese |  | false",
        "punct:. => Commit(\".\") |  | Chinese |  | false",
        "punct:. => Commit(\"。\") |  | Chinese |  | false",
        "k:d => UpdateCandidates | d | Chinese | 大,大家,大人,大国,大中 | false",
        "next => UpdateCandidates | d | Chinese | 大王,大鹏,大,犬 | false",
        "next => Unhandled | d | Chinese | 大王,大鹏,大,犬 | false",
        "prev => UpdateCandidates | d | Chinese | 大,大家,大人,大国,大中 | false",
        "next => UpdateCandidates | d | Chinese | 大王,大鹏,大,犬 | false",
        "num:2 => Commit(\"大鹏\") |  | Chinese |  | false",
        "bs => Unhandled |  | Chinese |  | false",
        "k:a => UpdateCandidates | a | Chinese | 中,中国,中间,中国人,中华人民共和国 | false",
        "k:a => UpdateCandidates | aa | Chinese | 中国,中国人,中华人民共和国 | false",
        "bs => UpdateCandidates | a | Chinese | 中,中国,中间,中国人,中华人民共和国 | false",
        "bs => Reset |  | Chinese |  | false",
        "semi => UpdateCandidates |  | TempEnglish |  | false",
        "k:h => UpdateCandidates | h | TempEnglish |  | false",
        "k:i => UpdateCandidates | hi | TempEnglish |  | false",
        "space => Commit(\"hi\") |  | Chinese |  | false",
        "k:z => UpdateCandidates | z | Chinese |  | false",
        "k:z => UpdateCandidates | zz | Chinese | 中 | false",
        "k:h => UpdateCandidates | zzh | Chinese | 中 | false",
        "k:o => UpdateCandidates | zzho | Chinese | 中 | false",
        "k:n => UpdateCandidates | zzhon | Chinese | 中 | false",
        "k:g => UpdateCandidates | zzhong | Chinese | 中 | false",
        "space => Commit(\"中\") |  | Chinese |  | false",
        "upper:H => UpdateCandidates | H | TempEnglish |  | false",
        "k:i => UpdateCandidates | Hi | TempEnglish |  | false",
        "enter => Commit(\"Hi\") |  | Chinese |  | false",
        "k:a => UpdateCandidates | a | Chinese | 中,中国,中间,中国人,中华人民共和国 | false",
        "quote => Commit(\"中间\") |  | Chinese |  | false",
        "k:a => UpdateCandidates | a | Chinese | 中,中国,中间,中国人,中华人民共和国 | false",
        "semi => Commit(\"中国\") |  | Chinese |  | false",
        "esc => Unhandled |  | Chinese |  | false",
        "enter => Unhandled |  | Chinese |  | false",
        "k:a => UpdateCandidates | a | Chinese | 中,中国,中间,中国人,中华人民共和国 | false",
        "enter => Commit(\"a\") |  | Chinese |  | false",
        "num:0 => Unhandled |  | Chinese |  | false",
        "quote => Commit(\"‘\") |  | Chinese |  | false",
        "k:b => UpdateCandidates | b | Chinese | 国,国家 | false",
        "k:b => UpdateCandidates | bb | Chinese | 国家 | false",
        "esc => Reset |  | Chinese |  | false",
        "k:q => UpdateCandidates | q | TempEnglish |  | false",
        "k:q => UpdateCandidates | qq | TempEnglish |  | false",
        "space => Commit(\"qq\") |  | Chinese |  | false",
    ];

    #[test]
    fn test_association_off_regression_trace() {
        // 期望值取自本功能改动前的引擎（基线快照），联想关闭时必须逐字节一致
        assert_eq!(
            run_trace(&mut assoc_engine(), REGRESSION_OPS),
            REGRESSION_EXPECTED
        );
        // 开过再关：同样逐字节一致
        let mut engine = assoc_engine();
        engine.set_association(true);
        engine.set_association(false);
        assert_eq!(run_trace(&mut engine, REGRESSION_OPS), REGRESSION_EXPECTED);
    }

    fn assoc_on() -> InputEngine {
        let mut engine = assoc_engine();
        engine.set_association(true);
        engine
    }

    fn commit_zhong(engine: &mut InputEngine) {
        engine.handle_key('a');
        assert_eq!(engine.handle_space(), EngineAction::Commit("中".into()));
    }

    #[test]
    fn test_association_trigger_and_select() {
        let mut engine = assoc_on();
        commit_zhong(&mut engine);
        assert!(engine.is_associating());
        assert_eq!(engine.buffer(), "");
        assert_eq!(texts(&engine), ["国", "间", "国人", "华人民共和国"]);
        assert!(
            engine
                .candidates()
                .iter()
                .all(|c| c.hint.is_empty() && c.code.is_empty())
        );
        // 数字选第 2 个：上屏后续部分；「中间」无更长词，联想结束
        assert_eq!(engine.handle_number(2), EngineAction::Commit("间".into()));
        assert!(!engine.is_associating());
        assert!(engine.candidates().is_empty());
        // 无联想词不进入：王
        assert_eq!(
            type_last(&mut engine, "gggg"),
            EngineAction::Commit("王".into())
        );
        assert!(!engine.is_associating());
        // 四码唯一自动上屏、分号/单引号选字同样触发
        engine.dict.add_entry("hhhh".into(), "中".into(), 10);
        assert_eq!(
            type_last(&mut engine, "hhhh"),
            EngineAction::Commit("中".into())
        );
        assert!(engine.is_associating());
        engine.handle_key('a');
        assert_eq!(engine.handle_quote(), EngineAction::Commit("中间".into()));
        assert!(!engine.is_associating());
        engine.handle_key('a');
        assert_eq!(
            engine.handle_semicolon(),
            EngineAction::Commit("中国".into())
        );
        assert_eq!(texts(&engine), ["人"]);
    }

    #[test]
    fn test_association_continuous() {
        let mut engine = assoc_on();
        commit_zhong(&mut engine);
        assert_eq!(engine.handle_number(1), EngineAction::Commit("国".into()));
        // 以「中国」继续联想
        assert!(engine.is_associating());
        assert_eq!(texts(&engine), ["人"]);
        assert_eq!(engine.handle_number(1), EngineAction::Commit("人".into()));
        assert!(!engine.is_associating());
    }

    #[test]
    fn test_association_number_out_of_page_is_plain_digit() {
        for num in [5, 9, 0] {
            let mut engine = assoc_on();
            commit_zhong(&mut engine);
            // 页内只有 4 个联想词：取消联想，数字按无编码处理（交给宿主、记下数字）
            assert_eq!(engine.handle_number(num), EngineAction::Unhandled);
            assert!(!engine.is_associating());
            assert!(engine.candidates().is_empty());
            assert_eq!(
                engine.handle_punctuation('.'),
                EngineAction::Commit(".".into())
            );
        }
        // 联想选词用掉的数字不算「输入了数字」
        let mut engine = assoc_on();
        commit_zhong(&mut engine);
        engine.handle_number(2);
        assert_eq!(
            engine.handle_punctuation('.'),
            EngineAction::Commit("。".into())
        );
    }

    #[test]
    fn test_association_other_keys_same_as_off() {
        let keys = [
            "k:a", "k:q", "space", "punct:,", "punct:.", "bs", "enter", "semi", "quote", "upper:H",
            "num:0", "next", "prev",
        ];
        for full_width in [false, true] {
            for key in keys {
                let ops = ["k:a", "space", key, "k:b", "k:i", "space", "esc"];
                let mut off = assoc_engine();
                let mut on = assoc_on();
                if full_width {
                    off.toggle_full_width();
                    on.toggle_full_width();
                }
                let t_off = run_trace(&mut off, &ops);
                let t_on = run_trace(&mut on, &ops);
                assert_eq!(t_off[2..], t_on[2..], "key={key} full_width={full_width}");
                assert!(!on.is_associating());
            }
        }
    }

    #[test]
    fn test_association_escape_only_cancels() {
        let mut engine = assoc_on();
        commit_zhong(&mut engine);
        assert_eq!(engine.handle_escape(), EngineAction::Reset);
        assert!(!engine.is_associating());
        assert!(engine.candidates().is_empty());
        // 之后与关闭时一致
        assert_eq!(engine.handle_escape(), EngineAction::Unhandled);
        // 中英切换 / reset_input / 关开关 均取消
        commit_zhong(&mut engine);
        engine.toggle_mode();
        assert!(!engine.is_associating());
        engine.toggle_mode();
        commit_zhong(&mut engine);
        engine.reset_input();
        assert!(!engine.is_associating());
        commit_zhong(&mut engine);
        engine.set_association(false);
        assert!(!engine.is_associating());
        assert!(engine.candidates().is_empty());
        engine.handle_key('a');
        engine.handle_space();
        assert!(!engine.is_associating());
    }

    #[test]
    fn test_association_paging() {
        let mut engine = assoc_on();
        engine.handle_key('d');
        assert_eq!(engine.handle_space(), EngineAction::Commit("大".into()));
        assert_eq!(texts(&engine), ["家", "人", "国", "中", "王"]);
        assert_eq!(engine.prev_page(), EngineAction::Unhandled);
        // 首页上翻到头：取消联想
        assert!(!engine.is_associating());
        engine.handle_key('d');
        engine.handle_space();
        assert_eq!(engine.next_page(), EngineAction::UpdateCandidates);
        assert_eq!(texts(&engine), ["鹏"]);
        assert_eq!(engine.handle_number(1), EngineAction::Commit("鹏".into()));
        engine.handle_key('d');
        engine.handle_space();
        engine.next_page();
        assert_eq!(engine.prev_page(), EngineAction::UpdateCandidates);
        assert_eq!(engine.handle_number(2), EngineAction::Commit("人".into()));
        engine.handle_key('d');
        engine.handle_space();
        engine.next_page();
        assert_eq!(engine.next_page(), EngineAction::Unhandled);
        assert!(!engine.is_associating());
    }

    #[test]
    fn test_association_not_triggered() {
        let mut engine = assoc_on();
        // 标点顶字
        engine.handle_key('a');
        assert_eq!(
            engine.handle_punctuation(','),
            EngineAction::Commit("中，".into())
        );
        assert!(!engine.is_associating());
        // 临时拼音
        type_keys(&mut engine, "zzhong");
        assert_eq!(engine.handle_space(), EngineAction::Commit("中".into()));
        assert!(!engine.is_associating());
        // 临时英文
        engine.handle_semicolon();
        type_keys(&mut engine, "hi");
        assert_eq!(
            engine.handle_space_for_temp_english(),
            Some(EngineAction::Commit("hi".into()))
        );
        assert!(!engine.is_associating());
        // 第五码顶字：新码已在途，不进入联想
        type_keys(&mut engine, "dddd");
        assert_eq!(engine.handle_key('a'), EngineAction::Commit("大".into()));
        assert!(!engine.is_associating());
        assert_eq!(engine.buffer(), "a");
        // 非汉字文本
        engine.handle_escape();
        engine.dict.add_entry("x".into(), "中a".into(), 1);
        engine.dict.add_entry("xx".into(), "中ab".into(), 1);
        engine.handle_key('x');
        engine.handle_space();
        assert!(!engine.is_associating());
    }

    #[test]
    fn test_association_traditional_and_common_chars() {
        let mut engine = assoc_on();
        engine.set_traditional(true);
        engine.handle_key('a');
        assert_eq!(engine.handle_space(), EngineAction::Commit("中".into()));
        let shown: Vec<String> = engine
            .candidates()
            .iter()
            .map(|c| engine.output_text(&c.text))
            .collect();
        assert_eq!(shown, ["國", "間", "國人", "華人民共和國"]);
        // 上屏繁体后续部分；继续联想按简体原文匹配
        assert_eq!(engine.handle_number(1), EngineAction::Commit("國".into()));
        assert_eq!(texts(&engine), ["人"]);

        let mut engine = assoc_on();
        engine.dict.add_entry("ae".into(), "中龘".into(), 100);
        commit_zhong(&mut engine);
        assert_eq!(texts(&engine), ["国", "间", "国人", "华人民共和国", "龘"]);
        engine.set_common_chars_only(true);
        engine.handle_escape();
        commit_zhong(&mut engine);
        assert_eq!(texts(&engine), ["国", "间", "国人", "华人民共和国"]);
    }

    #[test]
    fn test_association_no_learning_and_breaks_auto_phrase() {
        let mut engine = assoc_on();
        engine.set_auto_phrase(true);
        commit_zhong(&mut engine);
        assert_eq!(engine.phrase_seq, ["中"]);
        let before = engine.user_dict().entry_count();
        engine.handle_number(1);
        assert_eq!(engine.user_dict().entry_count(), before);
        assert!(engine.user_dict().lookup("").is_empty());
        assert!(engine.phrase_seq.is_empty());
    }

    #[test]
    fn test_association_custom_words() {
        let mut engine = assoc_on();
        engine
            .user_dict
            .add_custom("akto".into(), "中秋".into(), 500);
        // 与码表重复的自造词去重
        engine
            .user_dict
            .add_custom("akgh".into(), "中国".into(), 500);
        commit_zhong(&mut engine);
        assert_eq!(texts(&engine), ["国", "间", "国人", "华人民共和国", "秋"]);
        assert_eq!(engine.handle_number(5), EngineAction::Commit("秋".into()));
        assert!(engine.remove_custom_word("中秋", "akto"));
        commit_zhong(&mut engine);
        assert_eq!(texts(&engine), ["国", "间", "国人", "华人民共和国"]);
        // 自造词新增即时生效，且自身也能触发联想
        engine.handle_escape();
        engine
            .user_dict
            .add_custom("akgl".into(), "中国龙舟".into(), 500);
        commit_zhong(&mut engine);
        assert!(texts(&engine).contains(&"国龙舟".to_string()));
        engine.handle_escape();
        assert_eq!(
            type_last(&mut engine, "akgl"),
            EngineAction::Commit("中国龙舟".into())
        );
        assert!(!engine.is_associating());
    }
}
