# CLAUDE.md — iOS 宿主

**这是 iOS 宿主。** 语言 Swift，自定义键盘扩展 + 容器 app，工程由 XcodeGen 从 `project.yml` 生成。

## 关键文件
- `project.yml` — XcodeGen 工程定义（两个 target、签名、链接、BridgingHeader、`target/aarch64-apple-ios*` 搜索路径）。
- `HangeWubiKeyboard/` — 键盘扩展（`com.apple.keyboard-service`）：`KeyboardViewController.swift`、`KeyboardView.swift`、`CandidateBarView.swift`、`KeyPreviewView.swift`。
- `HangeWubiKeyboard/BridgingHeader.h` — 引入唯一 C 头 `include/hangewubi.h`。
- `HangeWubi/` — 容器 app：`AppDelegate`/`SceneDelegate`/`MainViewController`/`SettingsViewController`。
- `build.sh` — 交叉编译核心 + 生成工程 + 构建（`dev` 模拟器 / `device` 真机 / `dist` Archive+IPA）。

## 薄宿主纪律
只做键盘扩展 UI、布局、触感反馈，把 C 契约转成 UIKit 习惯用法。**不得**在 Swift 里实现任何引擎 / 候选 / 配置逻辑——那只属于核心 `src/`。

## 如何消费核心
经 `BridgingHeader.h` → `include/hangewubi.h`（**生成产物，禁止手改**；改契约去核心 `src/ffi.rs`）。链接 **`libhangewubi.a`**（staticlib，扩展不便用 dylib）。`build.sh` 编译后**删除同目录 `.dylib`**，逼 `-lhangewubi` 选静态库；产物在 `target/aarch64-apple-ios{,-sim}/<profile>/`。

## 如何构建
```
./platform/ios/build.sh          # dev：交叉编译 .a + xcodegen + 装到模拟器
./platform/ios/build.sh device   # 真机
./platform/ios/build.sh dist     # Archive + 导出 IPA
```

> 跨语言约束与全局路由见根 `/CLAUDE.md`。
