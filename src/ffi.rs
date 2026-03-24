//! C FFI 导出层
//! 为 macOS InputMethodKit 的 Swift 薄壳提供接口

use crate::config::Config;
use crate::dict::DictEngine;
use crate::engine::{EngineAction, InputEngine, InputMode};
use crate::user_dict::UserDict;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::Mutex;

/// FFI 返回的动作类型
#[repr(C)]
pub enum FfiAction {
    /// 提交文本
    Commit = 0,
    /// 更新候选列表
    UpdateCandidates = 1,
    /// 重置
    Reset = 2,
    /// 未处理
    Unhandled = 3,
}

/// FFI 返回结果
#[repr(C)]
pub struct FfiResult {
    pub action: FfiAction,
    /// 提交的文本（需要调用 ffi_free_string 释放）
    pub text: *mut c_char,
}

/// 候选词信息
#[repr(C)]
pub struct FfiCandidate {
    pub text: *mut c_char,
    pub code: *mut c_char,
    pub is_user: bool,
}

/// 候选列表
#[repr(C)]
pub struct FfiCandidateList {
    pub candidates: *mut FfiCandidate,
    pub count: usize,
}

static ENGINE: Mutex<Option<InputEngine>> = Mutex::new(None);

fn with_engine<F, R>(f: F) -> R
where
    F: FnOnce(&mut InputEngine) -> R,
{
    let mut guard = ENGINE.lock().unwrap();
    let engine = guard.as_mut().expect("引擎未初始化，请先调用 ffi_init");
    f(engine)
}

fn action_to_ffi(action: EngineAction) -> FfiResult {
    match action {
        EngineAction::Commit(text) => {
            let c_text = CString::new(text).unwrap_or_default();
            FfiResult {
                action: FfiAction::Commit,
                text: c_text.into_raw(),
            }
        }
        EngineAction::UpdateCandidates => FfiResult {
            action: FfiAction::UpdateCandidates,
            text: std::ptr::null_mut(),
        },
        EngineAction::Reset => FfiResult {
            action: FfiAction::Reset,
            text: std::ptr::null_mut(),
        },
        EngineAction::Unhandled => FfiResult {
            action: FfiAction::Unhandled,
            text: std::ptr::null_mut(),
        },
    }
}

/// 初始化引擎
/// dict_path: 码表文件路径（UTF-8 C 字符串）
/// 返回加载的词条数，失败返回 -1
#[unsafe(no_mangle)]
pub extern "C" fn ffi_init(dict_path: *const c_char) -> i64 {
    let path = if dict_path.is_null() {
        PathBuf::from("data/wubi86.txt")
    } else {
        let c_str = unsafe { CStr::from_ptr(dict_path) };
        PathBuf::from(c_str.to_string_lossy().as_ref())
    };

    let mut dict = DictEngine::new();
    let count = match dict.load_from_file(&path) {
        Ok(c) => c,
        Err(_) => return -1,
    };

    let config = Config::default();
    let user_dict = UserDict::new();
    let new_engine = InputEngine::new(dict, user_dict, config);

    *ENGINE.lock().unwrap() = Some(new_engine);

    count as i64
}

/// 处理字母按键
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_key(key: c_char) -> FfiResult {
    let ch = key as u8 as char;
    with_engine(|e| {
        if ch.is_ascii_uppercase() {
            action_to_ffi(e.handle_uppercase(ch))
        } else {
            action_to_ffi(e.handle_key(ch))
        }
    })
}

/// 处理空格键
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_space() -> FfiResult {
    with_engine(|e| {
        if let Some(action) = e.handle_space_for_temp_english() {
            action_to_ffi(action)
        } else {
            action_to_ffi(e.handle_space())
        }
    })
}

/// 处理数字键 (1-9)
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_number(num: u8) -> FfiResult {
    with_engine(|e| action_to_ffi(e.handle_number(num as usize)))
}

/// 处理退格键
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_backspace() -> FfiResult {
    with_engine(|e| action_to_ffi(e.handle_backspace()))
}

/// 处理 Escape 键
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_escape() -> FfiResult {
    with_engine(|e| action_to_ffi(e.handle_escape()))
}

/// 处理 Enter 键
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_enter() -> FfiResult {
    with_engine(|e| action_to_ffi(e.handle_enter()))
}

/// 处理标点符号
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_punctuation(ch: c_char) -> FfiResult {
    with_engine(|e| action_to_ffi(e.handle_punctuation(ch as u8 as char)))
}

/// 处理分号键
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_semicolon() -> FfiResult {
    with_engine(|e| action_to_ffi(e.handle_semicolon()))
}

/// 切换中英文模式
#[unsafe(no_mangle)]
pub extern "C" fn ffi_toggle_mode() {
    with_engine(|e| e.toggle_mode());
}

/// 获取当前输入模式
/// 0=中文, 1=英文, 2=临时英文
#[unsafe(no_mangle)]
pub extern "C" fn ffi_get_mode() -> u8 {
    with_engine(|e| match e.mode() {
        InputMode::Chinese => 0,
        InputMode::English => 1,
        InputMode::TempEnglish => 2,
    })
}

/// 获取当前编码缓冲区
/// 返回的字符串需要调用 ffi_free_string 释放
#[unsafe(no_mangle)]
pub extern "C" fn ffi_get_buffer() -> *mut c_char {
    with_engine(|e| {
        let buffer = e.buffer();
        CString::new(buffer).unwrap_or_default().into_raw()
    })
}

/// 获取候选列表
/// 返回的列表需要调用 ffi_free_candidate_list 释放
#[unsafe(no_mangle)]
pub extern "C" fn ffi_get_candidates() -> FfiCandidateList {
    with_engine(|e| {
        let candidates = e.candidates();
        let count = candidates.len();

        if count == 0 {
            return FfiCandidateList {
                candidates: std::ptr::null_mut(),
                count: 0,
            };
        }

        let mut ffi_candidates: Vec<FfiCandidate> = candidates
            .iter()
            .map(|c| FfiCandidate {
                text: CString::new(c.text.as_str()).unwrap_or_default().into_raw(),
                code: CString::new(c.code.as_str()).unwrap_or_default().into_raw(),
                is_user: c.is_user,
            })
            .collect();

        let ptr = ffi_candidates.as_mut_ptr();
        std::mem::forget(ffi_candidates);

        FfiCandidateList {
            candidates: ptr,
            count,
        }
    })
}

/// 释放 FFI 返回的字符串
#[unsafe(no_mangle)]
pub extern "C" fn ffi_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}

/// 释放候选列表
#[unsafe(no_mangle)]
pub extern "C" fn ffi_free_candidate_list(list: FfiCandidateList) {
    if list.candidates.is_null() || list.count == 0 {
        return;
    }
    unsafe {
        let candidates = Vec::from_raw_parts(list.candidates, list.count, list.count);
        for c in candidates {
            if !c.text.is_null() {
                drop(CString::from_raw(c.text));
            }
            if !c.code.is_null() {
                drop(CString::from_raw(c.code));
            }
        }
    }
}

/// 添加用户词条
#[unsafe(no_mangle)]
pub extern "C" fn ffi_add_user_word(code: *const c_char, text: *const c_char) {
    if code.is_null() || text.is_null() {
        return;
    }
    let code = unsafe { CStr::from_ptr(code) }.to_string_lossy().into_owned();
    let text = unsafe { CStr::from_ptr(text) }.to_string_lossy().into_owned();
    with_engine(|e| e.add_user_word(code, text));
}

/// 保存用户词典
#[unsafe(no_mangle)]
pub extern "C" fn ffi_save_user_dict(path: *const c_char) -> bool {
    if path.is_null() {
        return false;
    }
    let path = unsafe { CStr::from_ptr(path) }.to_string_lossy();
    with_engine(|e| e.user_dict().save(&PathBuf::from(path.as_ref())).is_ok())
}
