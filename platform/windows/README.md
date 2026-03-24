# 函戈五笔 Windows 版

## 技术方案

Windows 输入法使用 TSF (Text Services Framework) 框架：
- Rust 引擎编译为 `hangewubi.dll`
- C++ 薄壳实现 ITfTextInputProcessor 接口
- 注册为 COM 组件

## 构建步骤

### 前置要求
- Rust 工具链 (with `x86_64-pc-windows-msvc` target)
- Visual Studio Build Tools 2022+
- Windows SDK

### 交叉编译 (从 macOS)
```bash
rustup target add x86_64-pc-windows-gnu
cargo build --release --target x86_64-pc-windows-gnu
```

### 在 Windows 上原生编译
```powershell
cargo build --release
# 输出: target\release\hangewubi.dll
```

## 安装
1. 将 `hangewubi.dll` 复制到 `C:\Program Files\HangeWubi\`
2. 运行 `regsvr32 hangewubi.dll` 注册 COM 组件
3. 在设置 > 时间和语言 > 语言中添加输入法
