/*
 * 晗戈五笔 IBus 引擎
 * 薄 C 层：调用 libhangewubi.so 的 C FFI 接口
 */

#include <ibus.h>
#include <string.h>
#include <stdlib.h>
#include <locale.h>
#include "../../include/hangewubi.h"

/* ──────────────────────── 类型声明 ──────────────────────── */

typedef struct _IBusHangeWubiEngine      IBusHangeWubiEngine;
typedef struct _IBusHangeWubiEngineClass IBusHangeWubiEngineClass;

struct _IBusHangeWubiEngine {
    IBusEngine parent;
    /* Shift 切换跟踪 */
    gboolean shift_pressed;
    /* 候选表 */
    IBusLookupTable *table;
};

struct _IBusHangeWubiEngineClass {
    IBusEngineClass parent;
};

/* ──────────────────────── GObject 样板 ──────────────────────── */

#define IBUS_TYPE_HANGEWUBI_ENGINE (ibus_hangewubi_engine_get_type())

GType ibus_hangewubi_engine_get_type(void);

G_DEFINE_TYPE(IBusHangeWubiEngine, ibus_hangewubi_engine, IBUS_TYPE_ENGINE)

/* ──────────────────────── 前向声明 ──────────────────────── */

static void     engine_init          (IBusHangeWubiEngine *engine);
static void     engine_destroy       (IBusHangeWubiEngine *engine);
static gboolean engine_process_key   (IBusEngine *engine, guint keyval,
                                      guint keycode, guint modifiers);
static void     engine_focus_in      (IBusEngine *engine);
static void     engine_focus_out     (IBusEngine *engine);
static void     engine_reset         (IBusEngine *engine);
static void     engine_enable        (IBusEngine *engine);
static void     engine_disable       (IBusEngine *engine);

/* ──────────────────────── 全局状态 ──────────────────────── */

static gchar *g_data_dir = NULL;   /* 数据目录 */

/* ──────────────────────── 辅助函数 ──────────────────────── */

/* 更新预编辑文本和候选窗口 */
static void
sync_ui(IBusHangeWubiEngine *hw)
{
    IBusEngine *engine = (IBusEngine *)hw;

    /* 获取缓冲区 */
    char *buf = ffi_get_buffer();
    const char *buffer = buf ? buf : "";
    gboolean has_buffer = (buffer[0] != '\0');

    /* 更新 preedit */
    if (has_buffer) {
        IBusText *preedit = ibus_text_new_from_string(buffer);
        ibus_text_append_attribute(preedit,
            IBUS_ATTR_TYPE_UNDERLINE, IBUS_ATTR_UNDERLINE_SINGLE,
            0, g_utf8_strlen(buffer, -1));
        ibus_engine_update_preedit_text(engine, preedit, g_utf8_strlen(buffer, -1), TRUE);
    } else {
        ibus_engine_hide_preedit_text(engine);
    }
    if (buf) ffi_free_string(buf);

    /* 获取候选列表 */
    FfiCandidateList clist = ffi_get_candidates();

    if (clist.count == 0 || !has_buffer) {
        ibus_engine_hide_lookup_table(engine);
        ibus_engine_hide_auxiliary_text(engine);
        if (clist.candidates) ffi_free_candidate_list(clist);
        return;
    }

    /* 重建 lookup table */
    ibus_lookup_table_clear(hw->table);
    for (size_t i = 0; i < clist.count; i++) {
        /* 构建 "序号.候选 编码" 格式的标签 */
        IBusText *cand = ibus_text_new_from_string(clist.candidates[i].text);
        ibus_lookup_table_append_candidate(hw->table, cand);
    }
    ibus_lookup_table_set_cursor_visible(hw->table, FALSE);
    ibus_engine_update_lookup_table(engine, hw->table, TRUE);

    /* 辅助文本显示模式 */
    uint8_t mode = ffi_get_mode();
    const char *mode_str = (mode == 0) ? "[中]" :
                           (mode == 1) ? "[En]" :
                           (mode == 2) ? "[临英]" : "";
    IBusText *aux = ibus_text_new_from_string(mode_str);
    ibus_engine_update_auxiliary_text(engine, aux, TRUE);

    ffi_free_candidate_list(clist);
}

/* 隐藏所有 UI */
static void
hide_ui(IBusHangeWubiEngine *hw)
{
    IBusEngine *engine = (IBusEngine *)hw;
    ibus_engine_hide_preedit_text(engine);
    ibus_engine_hide_lookup_table(engine);
    ibus_engine_hide_auxiliary_text(engine);
}

/* 处理 FFI 返回结果并更新 UI，返回是否已处理 */
static gboolean
handle_ffi_result(IBusHangeWubiEngine *hw, FfiResult result)
{
    IBusEngine *engine = (IBusEngine *)hw;

    switch (result.action) {
    case FFI_ACTION_COMMIT:
        if (result.text) {
            IBusText *text = ibus_text_new_from_string(result.text);
            ibus_engine_commit_text(engine, text);
            ffi_free_string(result.text);
        }
        sync_ui(hw);
        return TRUE;

    case FFI_ACTION_UPDATE_CANDIDATES:
        sync_ui(hw);
        return TRUE;

    case FFI_ACTION_RESET:
        hide_ui(hw);
        return TRUE;

    case FFI_ACTION_UNHANDLED:
    default:
        if (result.text) ffi_free_string(result.text);
        return FALSE;
    }
}

/* ──────────────────────── IBus 引擎回调 ──────────────────────── */

static void
engine_init(IBusHangeWubiEngine *hw)
{
    hw->shift_pressed = FALSE;
    hw->table = ibus_lookup_table_new(5, 0, FALSE, TRUE);
    g_object_ref_sink(hw->table);

    /* 设置候选标签 1-5 */
    for (int i = 1; i <= 5; i++) {
        char label[4];
        snprintf(label, sizeof(label), "%d.", i);
        ibus_lookup_table_set_label(hw->table, i - 1,
            ibus_text_new_from_string(label));
    }
}

static void
engine_destroy(IBusHangeWubiEngine *hw)
{
    if (hw->table) {
        g_object_unref(hw->table);
        hw->table = NULL;
    }
    ((IBusObjectClass *)ibus_hangewubi_engine_parent_class)->destroy(
        (IBusObject *)hw);
}

static gboolean
engine_process_key(IBusEngine *engine, guint keyval,
                   guint keycode, guint modifiers)
{
    IBusHangeWubiEngine *hw = (IBusHangeWubiEngine *)engine;

    /* 忽略 key release 事件（Shift 除外，见下方） */
    gboolean is_release = (modifiers & IBUS_RELEASE_MASK) != 0;

    /* ── Shift 切换逻辑 ── */
    if (keyval == IBUS_KEY_Shift_L || keyval == IBUS_KEY_Shift_R) {
        if (!is_release) {
            /* Shift 按下：仅在没有其他修饰键时标记 */
            guint other = modifiers & (IBUS_CONTROL_MASK | IBUS_MOD1_MASK |
                                        IBUS_SUPER_MASK | IBUS_META_MASK);
            hw->shift_pressed = (other == 0);
        } else {
            /* Shift 释放 */
            if (hw->shift_pressed) {
                hw->shift_pressed = FALSE;
                /* 若缓冲区有内容，先作为英文提交 */
                char *buf = ffi_get_buffer();
                if (buf && buf[0] != '\0') {
                    IBusText *text = ibus_text_new_from_string(buf);
                    ibus_engine_commit_text(engine, text);
                }
                if (buf) ffi_free_string(buf);
                /* 通过 ffi_handle_escape 清空引擎缓冲区 */
                FfiResult r = ffi_handle_escape();
                if (r.text) ffi_free_string(r.text);
                /* 切换模式 */
                ffi_toggle_mode();
                hide_ui(hw);
                return TRUE;
            }
        }
        return FALSE;
    }

    /* 任何非 Shift 的按键取消 Shift 跟踪 */
    if (!is_release) {
        hw->shift_pressed = FALSE;
    }

    /* 只处理 keyDown */
    if (is_release) return FALSE;

    /* 有 Ctrl/Alt/Super 修饰键的不处理 */
    if (modifiers & (IBUS_CONTROL_MASK | IBUS_MOD1_MASK |
                     IBUS_SUPER_MASK | IBUS_META_MASK)) {
        return FALSE;
    }

    FfiResult result;

    /* ── 按键分发 ── */

    /* 字母键 a-z / A-Z */
    if (keyval >= IBUS_KEY_a && keyval <= IBUS_KEY_z) {
        result = ffi_handle_key((char)keyval);
        return handle_ffi_result(hw, result);
    }
    if (keyval >= IBUS_KEY_A && keyval <= IBUS_KEY_Z) {
        result = ffi_handle_key((char)keyval);
        return handle_ffi_result(hw, result);
    }

    /* 数字键 1-9 */
    if (keyval >= IBUS_KEY_1 && keyval <= IBUS_KEY_9) {
        result = ffi_handle_number((uint8_t)(keyval - IBUS_KEY_0));
        return handle_ffi_result(hw, result);
    }

    /* 空格 */
    if (keyval == IBUS_KEY_space) {
        result = ffi_handle_space();
        return handle_ffi_result(hw, result);
    }

    /* 退格 */
    if (keyval == IBUS_KEY_BackSpace) {
        result = ffi_handle_backspace();
        return handle_ffi_result(hw, result);
    }

    /* Escape */
    if (keyval == IBUS_KEY_Escape) {
        result = ffi_handle_escape();
        return handle_ffi_result(hw, result);
    }

    /* Enter / Return */
    if (keyval == IBUS_KEY_Return || keyval == IBUS_KEY_KP_Enter) {
        result = ffi_handle_enter();
        return handle_ffi_result(hw, result);
    }

    /* 分号 */
    if (keyval == IBUS_KEY_semicolon) {
        result = ffi_handle_semicolon();
        return handle_ffi_result(hw, result);
    }

    /* 单引号 */
    if (keyval == IBUS_KEY_apostrophe) {
        result = ffi_handle_quote();
        return handle_ffi_result(hw, result);
    }

    /* 翻页：+ / = → 下一页 */
    if (keyval == IBUS_KEY_plus || keyval == IBUS_KEY_equal) {
        result = ffi_next_page();
        return handle_ffi_result(hw, result);
    }

    /* 翻页：- → 上一页 */
    if (keyval == IBUS_KEY_minus) {
        result = ffi_prev_page();
        return handle_ffi_result(hw, result);
    }

    /* 标点符号 */
    if (keyval >= 0x21 && keyval <= 0x7e) {
        char ch = (char)keyval;
        /* 排除已处理的键 */
        if (ch != ';' && ch != '\'') {
            result = ffi_handle_punctuation(ch);
            return handle_ffi_result(hw, result);
        }
    }

    return FALSE;
}

static void
engine_focus_in(IBusEngine *engine)
{
    IBusHangeWubiEngine *hw = (IBusHangeWubiEngine *)engine;
    sync_ui(hw);
    IBUS_ENGINE_CLASS(ibus_hangewubi_engine_parent_class)->focus_in(engine);
}

static void
engine_focus_out(IBusEngine *engine)
{
    IBusHangeWubiEngine *hw = (IBusHangeWubiEngine *)engine;
    /* 焦点离开时隐藏 UI */
    hide_ui(hw);
    hw->shift_pressed = FALSE;
    IBUS_ENGINE_CLASS(ibus_hangewubi_engine_parent_class)->focus_out(engine);
}

static void
engine_reset(IBusEngine *engine)
{
    IBusHangeWubiEngine *hw = (IBusHangeWubiEngine *)engine;
    FfiResult r = ffi_handle_escape();
    if (r.text) ffi_free_string(r.text);
    hide_ui(hw);
    hw->shift_pressed = FALSE;
    IBUS_ENGINE_CLASS(ibus_hangewubi_engine_parent_class)->reset(engine);
}

static void
engine_enable(IBusEngine *engine)
{
    IBUS_ENGINE_CLASS(ibus_hangewubi_engine_parent_class)->enable(engine);
}

static void
engine_disable(IBusEngine *engine)
{
    IBusHangeWubiEngine *hw = (IBusHangeWubiEngine *)engine;
    FfiResult r = ffi_handle_escape();
    if (r.text) ffi_free_string(r.text);
    hide_ui(hw);
    IBUS_ENGINE_CLASS(ibus_hangewubi_engine_parent_class)->disable(engine);
}

/* ──────────────────────── GObject 类初始化 ──────────────────────── */

static void
ibus_hangewubi_engine_class_init(IBusHangeWubiEngineClass *klass)
{
    IBusEngineClass *engine_class = IBUS_ENGINE_CLASS(klass);
    IBusObjectClass *ibus_object_class = IBUS_OBJECT_CLASS(klass);

    engine_class->process_key_event = engine_process_key;
    engine_class->focus_in          = engine_focus_in;
    engine_class->focus_out         = engine_focus_out;
    engine_class->reset             = engine_reset;
    engine_class->enable            = engine_enable;
    engine_class->disable           = engine_disable;

    ibus_object_class->destroy = (IBusObjectDestroyFunc)engine_destroy;
}

static void
ibus_hangewubi_engine_init(IBusHangeWubiEngine *hw)
{
    engine_init(hw);
}

/* ──────────────────────── main() ──────────────────────── */

static IBusBus      *g_bus   = NULL;
static IBusFactory  *g_factory = NULL;

static void
ibus_connect(void)
{
    g_bus = ibus_bus_new();
    if (!ibus_bus_is_connected(g_bus)) {
        g_printerr("无法连接 IBus 守护进程\n");
        exit(1);
    }

    g_factory = ibus_factory_new(ibus_bus_get_connection(g_bus));
    ibus_factory_add_engine(g_factory, "hangewubi",
                            IBUS_TYPE_HANGEWUBI_ENGINE);
}

static void
ibus_register(void)
{
    IBusComponent *component = ibus_component_new(
        "com.hangewubi.ibus",                  /* name */
        "晗戈五笔输入法",                        /* description */
        "0.1.0",                                /* version */
        "MIT",                                  /* license */
        "HangeWubi",                            /* author */
        "https://github.com/VoldemortGin/hangewubi", /* homepage */
        "",                                     /* command line */
        "ibus-hangewubi"                        /* textdomain */
    );

    IBusEngineDesc *desc = ibus_engine_desc_new(
        "hangewubi",                            /* name */
        "晗戈五笔",                              /* longname */
        "基于 Rust 的高性能五笔输入法",            /* description */
        "zh",                                   /* language */
        "MIT",                                  /* license */
        "HangeWubi",                            /* author */
        "/usr/share/ibus-hangewubi/icon.png",   /* icon */
        "us"                                    /* layout */
    );

    ibus_component_add_engine(component, desc);
    ibus_bus_register_component(g_bus, component);
    g_object_unref(component);
}

int
main(int argc, char **argv)
{
    setlocale(LC_ALL, "");

    gboolean ibus_mode = FALSE;

    /* 解析命令行参数 */
    for (int i = 1; i < argc; i++) {
        if (g_strcmp0(argv[i], "--ibus") == 0) {
            ibus_mode = TRUE;
        } else if (g_strcmp0(argv[i], "--data-dir") == 0 && i + 1 < argc) {
            g_data_dir = argv[++i];
        }
    }

    /* 确定数据目录 */
    const char *data_dir = g_data_dir ? g_data_dir : "/usr/share/ibus-hangewubi/data";

    /* 构建码表路径 */
    gchar *dict_path = g_build_filename(data_dir, "wubi86.txt", NULL);

    g_message("晗戈五笔 IBus 引擎启动");
    g_message("数据目录: %s", data_dir);
    g_message("码表路径: %s", dict_path);

    /* 初始化输入引擎 */
    int64_t count = ffi_init(dict_path);
    if (count < 0) {
        g_printerr("无法加载码表: %s\n", dict_path);
        g_free(dict_path);
        return 1;
    }
    g_message("已加载 %ld 条词条", (long)count);
    g_free(dict_path);

    /* 加载配置文件（如果存在） */
    gchar *config_path = g_build_filename(data_dir, "config.toml", NULL);
    if (g_file_test(config_path, G_FILE_TEST_EXISTS)) {
        g_message("加载配置: %s", config_path);
        /* 配置已在 ffi_init 中使用默认值，这里可以扩展 */
    }
    g_free(config_path);

    ibus_init();

    ibus_connect();

    if (ibus_mode) {
        ibus_bus_request_name(g_bus, "com.hangewubi.ibus", 0);
    } else {
        ibus_register();
    }

    ibus_main();

    return 0;
}
