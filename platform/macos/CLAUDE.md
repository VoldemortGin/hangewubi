# CLAUDE.md — macOS 宿主

**这是 macOS 宿主。** 语言 Swift，框架 InputMethodKit（IMKit），系统输入法。

## 关键文件
- `main.swift` — 入口，注册 `IMKServer`、菜单栏图标。
- `InputController.swift` — `IMKInputController` 子类，接键盘事件、调 C 契约、把候选/提交交回系统。
- `BridgingHeader.h` — 引入唯一 C 头 `include/hangewubi.h`（`#import` 仓库根的头）。
- `Info.plist` / `entitlements.plist` / `*.lproj` / `AppIcon.icns` — bundle 元数据、签名授权、本地化、图标。
- `build.sh` — 构建 `.app`（`dev` ad-hoc / `release` Developer ID / `dist` 公证+DMG）。

## 薄宿主纪律
只做 IMKit 集成、菜单/UI、把 `FfiResult` / `FfiCandidateList` 转成 IMKit 习惯用法。**不得**在 Swift 里实现任何编码 / 拆字 / 候选 / 配置逻辑——那只属于核心 `src/`。

## 如何消费核心
经 `BridgingHeader.h` → `include/hangewubi.h`（**生成产物，禁止手改**；改契约去核心 `src/ffi.rs`）。链接 **`libhangewubi.dylib`**（cdylib），`build.sh` 用 `-lhangewubi -L target/release` 链接，并 `install_name_tool` 改成 `@executable_path/`。FFI 返回的字符串/列表记得调 `ffi_free_*` 释放。

## 如何构建
```
./platform/macos/build.sh        # dev：编译核心 + Swift 壳 + 打包 .app + ad-hoc 签名
./platform/macos/build.sh dist   # Developer ID 签名 + 公证 + DMG
```

> 跨语言约束与全局路由见根 `/CLAUDE.md`。
