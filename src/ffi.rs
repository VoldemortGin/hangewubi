//! C FFI 导出层
//! 为所有平台（macOS/iOS/Android/Windows/Linux）提供统一的 C 接口
//!
//! **panic 隔离策略**：release profile 采用默认的 `unwind`（非 `abort`），
//! 每个 `pub extern "C"` 入口都经 [`ffi_guard`] 用 `catch_unwind` 包裹，
//! panic 被捕获后返回该函数的安全默认值（空候选 / Unhandled / -1 / false / 空指针），
//! 并尽力重置引擎组合状态。任何 panic 都不得越过 C-ABI 进入宿主进程。

// 这些 FFI 函数已在各自的 `///` 文档里说明指针参数契约。不写 `# Safety`
// 文档段是刻意的：cbindgen 开启了 documentation=true，会把 `# Safety` 段原样
// 拷进自动生成的 include/hangewubi.h，污染 C 契约头。
#![allow(clippy::missing_safety_doc)]

use crate::config::Config;
use crate::dict::DictEngine;
use crate::engine::{EngineAction, InputEngine, InputMode};
use crate::user_dict::UserDict;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{AssertUnwindSafe, catch_unwind};
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

impl FfiResult {
    /// 未处理结果（用于引擎未初始化等降级场景）
    fn unhandled() -> Self {
        FfiResult {
            action: FfiAction::Unhandled,
            text: std::ptr::null_mut(),
        }
    }
}

impl FfiCandidateList {
    /// 空候选列表（用于引擎未初始化等降级场景）
    fn empty() -> Self {
        FfiCandidateList {
            candidates: std::ptr::null_mut(),
            count: 0,
        }
    }
}

/// 在已初始化的引擎上执行闭包：锁中毒时从毒化状态恢复，
/// 引擎未初始化时返回 `default`，确保 FFI 边界永不 panic。
fn with_engine<F, R>(default: R, f: F) -> R
where
    F: FnOnce(&mut InputEngine) -> R,
{
    let mut guard = ENGINE.lock().unwrap_or_else(|p| p.into_inner());
    match guard.as_mut() {
        Some(engine) => f(engine),
        None => default,
    }
}

/// FFI 统一 panic 守卫：用 `catch_unwind` 包裹每个 `pub extern "C"` 入口的逻辑。
///
/// - 正常返回时透传闭包结果。
/// - 闭包 panic 时捕获之，调用 `default()` 返回该函数的安全默认值，
///   并尽力把引擎重置回干净状态（panic 可能使引擎停在中间组合态）。
///
/// `default` 用闭包惰性构造，仅在真正 panic 时才求值。
fn ffi_guard<T>(default: impl FnOnce() -> T, f: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(_) => {
            // panic 捕获后：拿锁（从 poison 恢复）尽力重置引擎组合状态。
            // reset 自身再包一层 catch_unwind，防止恢复路径二次 panic 逃逸。
            let _ = catch_unwind(AssertUnwindSafe(|| {
                let mut guard = ENGINE.lock().unwrap_or_else(|p| p.into_inner());
                if let Some(engine) = guard.as_mut() {
                    engine.reset_input();
                }
            }));
            default()
        }
    }
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
pub unsafe extern "C" fn ffi_init(dict_path: *const c_char) -> i64 {
    ffi_guard(
        || -1,
        || unsafe { ffi_init_with_pinyin(dict_path, std::ptr::null()) },
    )
}

/// 初始化引擎（支持拼音混输）
/// dict_path: 五笔码表路径
/// pinyin_dict_path: 拼音词典路径（可为 null）
/// 返回加载的词条数，失败返回 -1
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ffi_init_with_pinyin(
    dict_path: *const c_char,
    pinyin_dict_path: *const c_char,
) -> i64 {
    ffi_guard(
        || -1,
        || {
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
            let mut new_engine = InputEngine::new(dict, user_dict, config);

            // 加载拼音词典（如果提供了路径）
            if !pinyin_dict_path.is_null() {
                let pinyin_path = unsafe { CStr::from_ptr(pinyin_dict_path) };
                let pinyin_path = PathBuf::from(pinyin_path.to_string_lossy().as_ref());
                let mut pinyin_dict = DictEngine::new();
                if pinyin_dict.load_from_file(&pinyin_path).is_ok() {
                    new_engine.set_pinyin_dict(pinyin_dict);
                    new_engine.set_config(true, true, 0, 0, 5, true); // 默认启用拼音混输
                }
            }

            *ENGINE.lock().unwrap_or_else(|p| p.into_inner()) = Some(new_engine);

            count as i64
        },
    )
}

/// 处理字母按键
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_key(key: c_char) -> FfiResult {
    ffi_guard(FfiResult::unhandled, || {
        // c_char 的符号性因平台而异；先按位重解释为 u8，非 ASCII（>=128）时
        // 直接返回安全默认，避免 `as char` 静默截断出非法字符。
        let byte = key as u8;
        if !byte.is_ascii() {
            return FfiResult::unhandled();
        }
        let ch = byte as char;
        with_engine(FfiResult::unhandled(), |e| {
            if ch.is_ascii_uppercase() {
                action_to_ffi(e.handle_uppercase(ch))
            } else {
                action_to_ffi(e.handle_key(ch))
            }
        })
    })
}

/// 处理空格键
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_space() -> FfiResult {
    ffi_guard(FfiResult::unhandled, || {
        with_engine(FfiResult::unhandled(), |e| {
            if let Some(action) = e.handle_space_for_temp_english() {
                action_to_ffi(action)
            } else {
                action_to_ffi(e.handle_space())
            }
        })
    })
}

/// 处理数字键 (1-9)
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_number(num: u8) -> FfiResult {
    ffi_guard(FfiResult::unhandled, || {
        with_engine(FfiResult::unhandled(), |e| {
            action_to_ffi(e.handle_number(num as usize))
        })
    })
}

/// 处理退格键
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_backspace() -> FfiResult {
    ffi_guard(FfiResult::unhandled, || {
        with_engine(FfiResult::unhandled(), |e| {
            action_to_ffi(e.handle_backspace())
        })
    })
}

/// 处理 Escape 键
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_escape() -> FfiResult {
    ffi_guard(FfiResult::unhandled, || {
        with_engine(FfiResult::unhandled(), |e| action_to_ffi(e.handle_escape()))
    })
}

/// 处理 Enter 键
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_enter() -> FfiResult {
    ffi_guard(FfiResult::unhandled, || {
        with_engine(FfiResult::unhandled(), |e| action_to_ffi(e.handle_enter()))
    })
}

/// 处理标点符号
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_punctuation(ch: c_char) -> FfiResult {
    ffi_guard(FfiResult::unhandled, || {
        // 同 ffi_handle_key：非 ASCII 字节直接降级为 Unhandled，不做截断。
        let byte = ch as u8;
        if !byte.is_ascii() {
            return FfiResult::unhandled();
        }
        let ch = byte as char;
        with_engine(FfiResult::unhandled(), |e| {
            action_to_ffi(e.handle_punctuation(ch))
        })
    })
}

/// 处理分号键
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_semicolon() -> FfiResult {
    ffi_guard(FfiResult::unhandled, || {
        with_engine(FfiResult::unhandled(), |e| {
            action_to_ffi(e.handle_semicolon())
        })
    })
}

/// 处理单引号键（选第三候选）
#[unsafe(no_mangle)]
pub extern "C" fn ffi_handle_quote() -> FfiResult {
    ffi_guard(FfiResult::unhandled, || {
        with_engine(FfiResult::unhandled(), |e| action_to_ffi(e.handle_quote()))
    })
}

/// 下一页
#[unsafe(no_mangle)]
pub extern "C" fn ffi_next_page() -> FfiResult {
    ffi_guard(FfiResult::unhandled, || {
        with_engine(FfiResult::unhandled(), |e| action_to_ffi(e.next_page()))
    })
}

/// 上一页
#[unsafe(no_mangle)]
pub extern "C" fn ffi_prev_page() -> FfiResult {
    ffi_guard(FfiResult::unhandled, || {
        with_engine(FfiResult::unhandled(), |e| action_to_ffi(e.prev_page()))
    })
}

/// 切换中英文模式
#[unsafe(no_mangle)]
pub extern "C" fn ffi_toggle_mode() {
    ffi_guard(
        || (),
        || {
            with_engine((), |e| e.toggle_mode());
        },
    );
}

/// 获取当前输入模式
/// 0=中文, 1=英文, 2=临时英文
#[unsafe(no_mangle)]
pub extern "C" fn ffi_get_mode() -> u8 {
    ffi_guard(
        || 0u8,
        || {
            with_engine(0u8, |e| match e.mode() {
                InputMode::Chinese => 0,
                InputMode::English => 1,
                InputMode::TempEnglish => 2,
            })
        },
    )
}

/// 获取当前编码缓冲区
/// 返回的字符串需要调用 ffi_free_string 释放
#[unsafe(no_mangle)]
pub extern "C" fn ffi_get_buffer() -> *mut c_char {
    ffi_guard(std::ptr::null_mut, || {
        with_engine(std::ptr::null_mut(), |e| {
            let buffer = e.buffer();
            CString::new(buffer).unwrap_or_default().into_raw()
        })
    })
}

/// 获取候选列表
/// 返回的列表需要调用 ffi_free_candidate_list 释放
#[unsafe(no_mangle)]
pub extern "C" fn ffi_get_candidates() -> FfiCandidateList {
    ffi_guard(FfiCandidateList::empty, || {
        with_engine(FfiCandidateList::empty(), |e| {
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
    })
}

/// 释放 FFI 返回的字符串
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ffi_free_string(s: *mut c_char) {
    ffi_guard(
        || (),
        || {
            if !s.is_null() {
                unsafe {
                    drop(CString::from_raw(s));
                }
            }
        },
    );
}

/// 释放候选列表
#[unsafe(no_mangle)]
pub extern "C" fn ffi_free_candidate_list(list: FfiCandidateList) {
    ffi_guard(
        || (),
        || {
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
        },
    );
}

/// 更新引擎配置
#[unsafe(no_mangle)]
pub extern "C" fn ffi_set_config(
    auto_commit_unique_4: bool,
    auto_commit_first_5: bool,
    enter_key_action: u8,
    empty_code_action: u8,
    candidate_count: u8,
    pinyin_mixed_enabled: bool,
) {
    ffi_guard(
        || (),
        || {
            with_engine((), |e| {
                e.set_config(
                    auto_commit_unique_4,
                    auto_commit_first_5,
                    enter_key_action,
                    empty_code_action,
                    candidate_count as usize,
                    pinyin_mixed_enabled,
                );
            });
        },
    );
}

/// 添加用户词条
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ffi_add_user_word(code: *const c_char, text: *const c_char) {
    ffi_guard(
        || (),
        || {
            if code.is_null() || text.is_null() {
                return;
            }
            let code = unsafe { CStr::from_ptr(code) }
                .to_string_lossy()
                .into_owned();
            let text = unsafe { CStr::from_ptr(text) }
                .to_string_lossy()
                .into_owned();
            with_engine((), |e| e.add_user_word(code, text));
        },
    );
}

/// 保存用户词典
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ffi_save_user_dict(path: *const c_char) -> bool {
    ffi_guard(
        || false,
        || {
            if path.is_null() {
                return false;
            }
            let path = unsafe { CStr::from_ptr(path) }
                .to_string_lossy()
                .into_owned();
            // 锁内只克隆快照，序列化 + 写盘在锁外完成，绝不持全局锁做文件 IO
            let snapshot = with_engine(None, |e| Some(e.user_dict().clone()));
            let Some(dict) = snapshot else {
                return false;
            };
            dict.save(&PathBuf::from(path)).is_ok()
        },
    )
}

/// 从磁盘加载用户词典到引擎（启动时调用）
/// path: 用户词典 JSON 文件路径（与 ffi_save_user_dict 使用同一路径）
/// 文件不存在或解析失败时退化为空词典；引擎已初始化且 path 非空返回 true。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ffi_load_user_dict(path: *const c_char) -> bool {
    ffi_guard(
        || false,
        || {
            if path.is_null() {
                return false;
            }
            let path = unsafe { CStr::from_ptr(path) }
                .to_string_lossy()
                .into_owned();
            // 读文件 + 解析在锁外完成；锁内只做 apply，绝不持全局锁做文件 IO
            let loaded = UserDict::load(&PathBuf::from(path)).unwrap_or_default();
            with_engine(false, |e| {
                e.set_user_dict(loaded);
                true
            })
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    // FFI 测试共用全局 ENGINE，串行化以免并行相互污染状态。
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn install_test_engine() {
        let mut dict = DictEngine::new();
        dict.load_from_str("a\t工\t9999\nab\t节\t4000\n");
        let engine = InputEngine::new(dict, UserDict::new(), Config::default());
        *ENGINE.lock().unwrap_or_else(|p| p.into_inner()) = Some(engine);
    }

    fn clear_engine() {
        *ENGINE.lock().unwrap_or_else(|p| p.into_inner()) = None;
    }

    fn buffer_is_empty() -> bool {
        with_engine(true, |e| e.buffer().is_empty())
    }

    // ffi_guard 直接单元测试：正常闭包透传、panic 闭包返回默认值。
    #[test]
    fn ffi_guard_passes_through_and_defaults_on_panic() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // 正常闭包：返回其真实结果
        assert_eq!(ffi_guard(|| -1i64, || 42i64), 42);
        assert!(ffi_guard(|| false, || true));
        // panic 闭包：捕获并返回默认值，进程不死
        assert_eq!(ffi_guard(|| -1i64, || panic!("boom")), -1);
        assert!(!ffi_guard(|| false, || -> bool { panic!("boom") }));
    }

    // 穿透测试：经守卫路径触发 panic，证明 panic 不逃出 FFI、返回默认值、
    // 引擎状态被重置、且后续 FFI 调用仍正常工作。
    #[test]
    fn panic_does_not_escape_ffi_and_resets_engine() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        install_test_engine();

        // 建立组合中间状态：buffer == "a"
        let _ = ffi_handle_key(b'a' as c_char);
        assert!(!buffer_is_empty());

        // 经 ffi_guard 在引擎操作中途 panic：不逃逸、返回默认 Unhandled。
        let r = ffi_guard(FfiResult::unhandled, || {
            with_engine(FfiResult::unhandled(), |e| {
                e.handle_key('b'); // 先制造更多中间状态
                panic!("injected panic inside engine op");
            })
        });
        assert!(matches!(r.action, FfiAction::Unhandled));
        assert!(r.text.is_null());

        // 恢复路径已重置引擎组合状态。
        assert!(buffer_is_empty());

        // 后续 FFI 调用仍正常工作（状态干净、锁已从 poison 恢复）。
        let r2 = ffi_handle_key(b'a' as c_char);
        assert!(matches!(r2.action, FfiAction::UpdateCandidates));
        assert!(!buffer_is_empty());
        let mode = ffi_get_mode();
        assert_eq!(mode, 0); // 重置回中文模式

        clear_engine();
    }
}
