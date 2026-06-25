# CLAUDE.md — 仓库路由表（根）

> 晗戈五笔：高性能五笔输入法引擎。
> 这是一个 **「Rust 核心 + C-ABI 契约 + 多宿主」** 的 polyglot 仓库：所有输入法逻辑只在一个 Rust crate (`hangewubi`) 里，五个平台宿主都是「薄壳」，经唯一的 C 头消费同一份核心。
>
> 本文件不是面向用户的文档，是给 AI / 开发者读的「在哪改什么」硬约束与导航卡。动手前先读这里。

---

## 硬性跨语言约束（不可违反）

| # | 约束 | 含义 |
|---|------|------|
| ① | **核心唯一** | 所有共享逻辑（引擎 / 拆字 / 校验 / 解析 / 配置）只在 Rust 核心 `src/`。宿主一律薄，**禁止在宿主语言里重新实现任何引擎逻辑**——宿主只做平台集成、UI、把 C 契约转成本地习惯用法。 |
| ② | **契约唯一且为生成产物** | 跨语言契约只有一处 = `include/hangewubi.h`，**它由 cbindgen 从 `src/ffi.rs` 自动生成，禁止手工编辑**。改契约 = 改 `src/ffi.rs` → `cargo build` 重新生成头 → 各宿主适配。手改头文件会被漂移守卫拦下。 |
| ③ | **无 panic 跨界** | FFI 边界（`src/ffi.rs`）必须吞掉所有 panic：lock 从中毒（poison）恢复、引擎未初始化时返回安全默认值（空候选 / Unhandled / -1），release profile 设 `panic = "abort"`。任何 panic 都不得越过 C-ABI 进入宿主进程。 |
| ④ | **唯一裁判是 `make check`** | 合并前唯一的门禁是组合命令 `make check`：跑 Rust 测试 + clippy + fmt + **头文件漂移守卫**（重生成 `hangewubi.h` 并比对，确认未手改且与 `src/ffi.rs` 同步）+ 本机可构建的宿主。绿了才算过。 |

---

## 路由表：症状 → 去哪改

| 你想做的事 | 去哪改 | 备注 |
|-----------|--------|------|
| 改五笔编码 / 拆字 / 取码逻辑 | `src/engine.rs` + `src/dict.rs` | 引擎主体在 `engine.rs`，码表加载/查询在 `dict.rs` |
| 改码表数据结构 / 前缀查询 | `src/trie.rs` | |
| 改用户词典（自学习 / 持久化） | `src/user_dict.rs` | |
| 改默认配置 / 配置项 | `src/config.rs` | |
| 改标点 / 全半角映射 | `src/punctuation.rs` | |
| 改命令行工具行为 | `src/bin/cli.rs` | |
| **加 / 改一个跨语言 API** | `src/ffi.rs`（契约头自动重生成） | 改完 `cargo build`，再在**每个**宿主适配；切勿只改一个宿主 |
| 改「某语言如何呈现结果」（UI / 平台集成） | 对应 `platform/<host>/` | 见下方宿主一览；这里**不放**引擎逻辑 |
| **直接编辑 `include/hangewubi.h`** | **绝不**——它是生成产物 | 要改契约请改 `src/ffi.rs` |
| 改门禁 / CI / 漂移守卫 | `Makefile` / 漂移守卫脚本 | 见「门禁与版本钉死」 |

---

## 宿主一览

五个宿主都是薄壳，统一经 `include/hangewubi.h` 消费核心，差别只在「链接哪个产物」与「平台框架」。

| 宿主 | 路径 | 语言 / 框架 | 消费方式 | 子树导航 |
|------|------|------------|----------|----------|
| macOS | `platform/macos/` | Swift + InputMethodKit | BridgingHeader → C 头，链接 `libhangewubi.dylib`（cdylib） | `platform/macos/CLAUDE.md` |
| iOS | `platform/ios/` | Swift + 键盘扩展 + XcodeGen | BridgingHeader → C 头，链接 `libhangewubi.a`（staticlib） | `platform/ios/CLAUDE.md` |
| Android | `platform/android/` | Kotlin (`com.hangewubi.ime`) + JNI C 桥 + CMake/Gradle | JNI 桥 `#include "hangewubi.h"`，链接预编译 `libhangewubi.so`（cdylib） | `platform/android/CLAUDE.md` |
| Linux | `platform/linux/` | C + ibus | `#include` C 头，链接 `libhangewubi.so`（cdylib） | `platform/linux/CLAUDE.md` |
| Windows | `platform/windows/` | C++ + TSF | `#include` C 头 + `hangewubi_tsf.def`，链接 `hangewubi.dll`（cdylib） | `platform/windows/CLAUDE.md` |

核心 crate 产物形态见 `Cargo.toml`：`crate-type = ["lib", "cdylib", "staticlib"]`。

---

## 门禁与版本钉死

| 文件 | 作用 |
|------|------|
| `Makefile`（`make check`） | 唯一组合门禁，见约束 ④ |
| `rust-toolchain.toml` | 钉死 Rust 工具链版本（核心 + 各 target 交叉编译） |
| `versions.toml` | 钉死 cbindgen / NDK / 各宿主工具链等版本矩阵 |
| 头文件漂移守卫 | `make check` 内一步：重生成 `hangewubi.h` 并与仓库版本比对，防手改 / 防漂移 |
| `build-all.sh` / `ci-local.sh` | 本机跨平台构建 / 本地 CI 辅助脚本 |

> 上述钉死与守卫文件由配套任务维护，此处只引用其名；缺失时以 `make check` 的实际行为为准。

---

## 给改动者的硬规则

- diff 里每一行都应能追溯到需求；不要顺手重构没坏的东西。
- 动核心前先看 `src/` 有没有现成实现，别在宿主里造轮子（违反约束 ①）。
- 改了 `src/ffi.rs` 就是改了所有宿主的契约：重生成头 + 逐个宿主适配 + 跑 `make check`。
- 各子树细则见该子树的 `CLAUDE.md`。
