# 晗戈五笔 Android 版

## 技术方案

Android 输入法通过 InputMethodService 集成：
- Rust 引擎通过 JNI 或 UniFFI 桥接到 Kotlin/Java
- 交叉编译为 `libhangewubi.so` (aarch64-linux-android)
- Kotlin 壳实现 InputMethodService

## 构建步骤

### 前置要求
- Rust 工具链
- Android NDK
- Android Studio

### 添加 Android 编译目标
```bash
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
```

### 交叉编译
```bash
# 需要配置 .cargo/config.toml 指定 NDK linker
cargo build --release --target aarch64-linux-android
```

### Android Studio 项目
在 `platform/android/app/` 下创建标准 Android InputMethodService 项目，
通过 JNI 加载 `libhangewubi.so`。

## JNI 桥接

使用 `jni` crate 或 `uniffi` 自动生成 Kotlin 绑定：

```toml
[dependencies]
jni = "0.21"
```
