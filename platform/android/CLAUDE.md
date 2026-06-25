# CLAUDE.md — Android 宿主

**这是 Android 宿主。** Kotlin 输入法（`InputMethodService`）+ JNI C 桥，Gradle 工程，JNI 用 CMake 构建。
（注：本目录另有 `README.md` 讲面向用户/构建细节；本文件是导航卡，二者并存。）

## 关键文件
- `app/src/main/java/com/hangewubi/ime/` — Kotlin 宿主：`HangeWubiIME.kt`（IME 服务）、`KeyboardView.kt`、`CandidateView.kt`、`MainActivity.kt`、`SettingsActivity.kt`、`SettingsKey.kt`、`EngineBridge.kt`（JNI `external fun` 声明）。
- `app/src/main/jni/hangewubi_jni.c` — JNI C 桥，`#include "hangewubi.h"`，把 `Java_..._*` 调用转给核心 FFI。
- `app/src/main/jni/CMakeLists.txt` — 把核心声明为 `IMPORTED` 共享库并链接，头路径指向仓库 `include/`。
- `build.gradle.kts` / `app/build.gradle.kts` / `settings.gradle.kts` — Gradle 工程。
- `build.sh` — 用 cargo-ndk 交叉编译核心 `.so` 到各 ABI 的 `jniLibs/`。

## 薄宿主纪律
Kotlin 只做 IME 服务、键盘 UI、设置、触感；JNI C 桥只做类型搬运。**不得**在 Kotlin 或 JNI 里实现任何引擎 / 候选 / 配置逻辑——那只属于核心 `src/`。

## 如何消费核心
JNI 桥 `#include` 唯一 C 头 `include/hangewubi.h`（**生成产物，禁止手改**；改契约去核心 `src/ffi.rs`）。链接**预编译 `libhangewubi.so`**（cdylib，放在 `app/src/main/jniLibs/<abi>/`，CMake 中 `IMPORTED` + `IMPORTED_NO_SONAME`）。JNI 桥负责 `ffi_free_*` 释放，勿把裸指针泄回 Kotlin。

## 如何构建
```
./platform/android/build.sh --release   # 交叉编译核心 .so → jniLibs/<abi>/
# 然后用 Gradle 构建 APK（含 CMake 编译 JNI 桥）：
./platform/android/gradlew -p platform/android assembleDebug
```

> 跨语言约束与全局路由见根 `/CLAUDE.md`。
