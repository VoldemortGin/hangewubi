# 晗戈五笔 Android 版

基于 Rust 核心引擎 + Kotlin `InputMethodService` 实现的五笔/拼音混输输入法。

## 功能

- 五笔 86 码输入
- 五笔 + 拼音混输（前缀匹配，五笔结果优先）
- 中英文模式切换（键盘上 `中/EN` 键）
- 设置页：自动上屏、候选数量、震动反馈、回车键行为、空码处理
- 深色模式自适应
- 按键震动反馈

## 构建

### 前置依赖

```bash
# Rust 交叉编译 target
rustup target add aarch64-linux-android x86_64-linux-android

# cargo-ndk（负责把 NDK 链接器塞给 cargo）
cargo install cargo-ndk

# Android SDK + NDK（建议通过 Android Studio 安装 API 34+ / NDK r26+）
export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/<ndk-version>"
```

### 编译 Rust 动态库

```bash
cd platform/android
./build.sh --release            # 默认构建 arm64-v8a + x86_64
./build.sh --release --abi arm64  # 或只构建单个 ABI
```

脚本会：
1. 把 `data/wubi86.txt` / `data/pinyin.txt` 拷到 `app/src/main/assets/data/`
2. 为每个 ABI 交叉编译 `libhangewubi.so`
3. 拷贝到 `app/src/main/jniLibs/<abi>/`

### 构建 APK

```bash
cd platform/android
./gradlew assembleDebug          # 开发版
./gradlew assembleRelease        # 发布版（未签名）
```

APK 产物在 `app/build/outputs/apk/`。

### 安装与调试

```bash
adb install app/build/outputs/apk/debug/app-debug.apk
adb logcat -s HangeWubiIME HangeWubiJNI
```

## 启用键盘

1. 在桌面打开「晗戈五笔」应用
2. 点击「打开输入法设置」，在系统设置里勾选「晗戈五笔」
3. 在任意输入框点击「切换当前输入法」或键盘上的 🌐 键，选中「晗戈五笔」
4. 在应用首页「应用设置」里按需打开震动反馈、拼音混输等

## 架构

```
┌─────────────────────────────────────────────┐
│  MainActivity / SettingsActivity (应用壳)      │
├─────────────────────────────────────────────┤
│  HangeWubiIME (InputMethodService)          │
│  ├── KeyboardView  (Canvas 自绘键盘)          │
│  └── CandidateView (候选栏)                   │
├─────────────────────────────────────────────┤
│  EngineBridge.kt (JNI 声明)                  │
│  hangewubi_jni.c (JNI 桥接)                  │
├─────────────────────────────────────────────┤
│  libhangewubi.so (Rust 引擎，cdylib)         │
└─────────────────────────────────────────────┘
```

关键文件：

- `app/src/main/java/com/hangewubi/ime/HangeWubiIME.kt` — 输入法服务入口
- `app/src/main/java/com/hangewubi/ime/KeyboardView.kt` — 键盘视图
- `app/src/main/java/com/hangewubi/ime/CandidateView.kt` — 候选栏
- `app/src/main/java/com/hangewubi/ime/EngineBridge.kt` — JNI 声明
- `app/src/main/jni/hangewubi_jni.c` — JNI 桥接
- `../../include/hangewubi.h` — Rust FFI 头文件（与 `src/ffi.rs` 同步）

## 已知限制

- 暂不支持自定义键盘布局（只有默认 QWERTY）
- 暂无拼音反查、用户词典管理 UI（引擎层已支持，可手工编辑 `data/pinyin.txt`）
- 仅构建 `arm64-v8a` + `x86_64`；如需 `armeabi-v7a` 请显式 `./build.sh --abi armv7`
