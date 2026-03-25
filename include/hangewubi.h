// 函戈五笔 C FFI 头文件
// 自动生成 - 请勿手动编辑

#ifndef HANGEWUBI_H
#define HANGEWUBI_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// 动作类型
typedef enum {
    FFI_ACTION_COMMIT = 0,
    FFI_ACTION_UPDATE_CANDIDATES = 1,
    FFI_ACTION_RESET = 2,
    FFI_ACTION_UNHANDLED = 3,
} FfiAction;

// 返回结果
typedef struct {
    FfiAction action;
    char *text;  // 需要调用 ffi_free_string 释放
} FfiResult;

// 候选词
typedef struct {
    char *text;
    char *code;
    bool is_user;
} FfiCandidate;

// 候选列表
typedef struct {
    FfiCandidate *candidates;
    size_t count;
} FfiCandidateList;

// 初始化引擎，返回加载词条数，失败返回 -1
int64_t ffi_init(const char *dict_path);

// 按键处理
FfiResult ffi_handle_key(char key);
FfiResult ffi_handle_space(void);
FfiResult ffi_handle_number(uint8_t num);
FfiResult ffi_handle_backspace(void);
FfiResult ffi_handle_escape(void);
FfiResult ffi_handle_enter(void);
FfiResult ffi_handle_punctuation(char ch);
FfiResult ffi_handle_semicolon(void);
FfiResult ffi_handle_quote(void);

// 翻页
FfiResult ffi_next_page(void);
FfiResult ffi_prev_page(void);

// 模式管理
void ffi_toggle_mode(void);
uint8_t ffi_get_mode(void);  // 0=中文, 1=英文, 2=临时英文

// 状态查询
char *ffi_get_buffer(void);  // 需要 ffi_free_string 释放
FfiCandidateList ffi_get_candidates(void);  // 需要 ffi_free_candidate_list 释放

// 配置更新
void ffi_set_config(bool auto_commit_unique_4, bool auto_commit_first_5,
                    uint8_t enter_key_action, uint8_t empty_code_action,
                    uint8_t candidate_count);

// 用户词典
void ffi_add_user_word(const char *code, const char *text);
bool ffi_save_user_dict(const char *path);

// 内存释放
void ffi_free_string(char *s);
void ffi_free_candidate_list(FfiCandidateList list);

#ifdef __cplusplus
}
#endif

#endif // HANGEWUBI_H
