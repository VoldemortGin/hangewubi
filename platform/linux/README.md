# 函戈五笔 Linux 版

## 技术方案

Linux 输入法通过 IBus 或 Fcitx5 框架集成：
- Rust 引擎编译为 `libfungewubi.so`
- IBus 引擎模块通过 C FFI 调用 Rust

### IBus 方案（推荐）
- 实现 `ibus-engine-fungewubi` 可执行文件
- 通过 D-Bus 与 IBus daemon 通信

### Fcitx5 方案
- 实现 Fcitx5 addon 插件
- 通过 Fcitx5 C++ API 调用 Rust FFI

## 构建步骤

### 前置要求
- Rust 工具链
- IBus 开发库: `sudo apt install libibus-1.0-dev`

### 编译
```bash
cargo build --release
# 输出: target/release/libfungewubi.so
```

## 安装 (IBus)
```bash
# 复制引擎
sudo cp target/release/libfungewubi.so /usr/lib/ibus-fungewubi/
sudo cp platform/linux/fungewubi.xml /usr/share/ibus/component/

# 重启 IBus
ibus restart
```
