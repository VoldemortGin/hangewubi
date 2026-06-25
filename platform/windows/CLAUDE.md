# CLAUDE.md — Windows 宿主

**这是 Windows 宿主。** 语言 C++，框架 TSF（Text Services Framework，COM 文本服务）。

## 关键文件
- `src/text_service.{cpp,h}` — `ITfTextInputProcessor` 文本服务主体（接键、调核心、上屏）。
- `src/composition.{cpp,h}` — 组词/composition 管理。
- `src/candidate_list.{cpp,h}` — 候选列表 UI。
- `src/class_factory.{cpp,h}` / `src/register.cpp` / `src/globals.h` — COM 工厂、注册/注销、CLSID 等全局。
- `hangewubi_tsf.def` — 导出符号定义（COM 入口）。
- `build.bat` / `install.bat` / `uninstall.bat` — 构建与注册脚本。

## 薄宿主纪律
只做 TSF/COM 集成、组词与候选 UI、把 C 契约转成 TSF 习惯用法。**不得**在 C++ 里实现任何引擎 / 候选 / 配置逻辑——那只属于核心 `src/`。

## 如何消费核心
`#include` 唯一 C 头 `include/hangewubi.h`（**生成产物，禁止手改**；改契约去核心 `src/ffi.rs`）。链接 **`hangewubi.dll`**（cdylib）。FFI 返回的字符串/列表记得调 `ffi_free_*` 释放。

## 如何构建
```
platform\windows\build.bat        :: 编译 TSF DLL
platform\windows\install.bat      :: 注册输入法（需管理员）
platform\windows\uninstall.bat    :: 注销
```
（核心 `hangewubi.dll` 可用根 `build-all.sh` 交叉编译到 `x86_64-pc-windows-gnu`。）

> 跨语言约束与全局路由见根 `/CLAUDE.md`。
