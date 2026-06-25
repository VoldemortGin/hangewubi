# CLAUDE.md — Linux 宿主

**这是 Linux 宿主。** 语言 C，框架 ibus（输入法框架引擎）。
（注：本目录另有 `README.md` 讲面向用户/安装细节；本文件是导航卡，二者并存。）

## 关键文件
- `ibus-engine-hangewubi.c` — ibus 引擎实现：接 ibus 事件、调核心 C 契约、把候选/提交交回 ibus。
- `build.sh` — 编译 ibus 引擎并链接核心 `.so`。

## 薄宿主纪律
只做 ibus 引擎集成、候选窗交互、把 C 契约转成 ibus 习惯用法。**不得**在 C 里实现任何引擎 / 候选 / 配置逻辑——那只属于核心 `src/`。

## 如何消费核心
`#include` 唯一 C 头 `include/hangewubi.h`（**生成产物，禁止手改**；改契约去核心 `src/ffi.rs`）。链接 **`libhangewubi.so`**（cdylib）。FFI 返回的字符串/列表记得调 `ffi_free_*` 释放。

## 如何构建
```
./platform/linux/build.sh
```
（核心 `.so` 可用根 `build-all.sh` 交叉编译到 `x86_64-unknown-linux-gnu`。）

> 跨语言约束与全局路由见根 `/CLAUDE.md`。
