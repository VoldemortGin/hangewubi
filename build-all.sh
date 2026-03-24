#!/bin/bash
# 函戈五笔跨平台构建脚本
set -e

echo "=== 函戈五笔跨平台构建 ==="

# 运行测试
echo "[测试] 运行全部测试..."
cargo test

# macOS (本地)
echo ""
echo "[macOS] 编译 Release..."
cargo build --release
echo "  => target/release/libfungewubi.dylib"
echo "  => target/release/fungewubi-cli"

# Windows (交叉编译)
if rustup target list --installed | grep -q "x86_64-pc-windows-gnu"; then
    echo ""
    echo "[Windows] 交叉编译..."
    cargo build --release --target x86_64-pc-windows-gnu
    echo "  => target/x86_64-pc-windows-gnu/release/fungewubi.dll"
else
    echo ""
    echo "[Windows] 跳过 (未安装 x86_64-pc-windows-gnu target)"
    echo "  安装: rustup target add x86_64-pc-windows-gnu"
fi

# Linux (交叉编译)
if rustup target list --installed | grep -q "x86_64-unknown-linux-gnu"; then
    echo ""
    echo "[Linux] 交叉编译..."
    cargo build --release --target x86_64-unknown-linux-gnu
    echo "  => target/x86_64-unknown-linux-gnu/release/libfungewubi.so"
else
    echo ""
    echo "[Linux] 跳过 (未安装 x86_64-unknown-linux-gnu target)"
    echo "  安装: rustup target add x86_64-unknown-linux-gnu"
fi

# Android (交叉编译)
if rustup target list --installed | grep -q "aarch64-linux-android"; then
    echo ""
    echo "[Android] 交叉编译..."
    cargo build --release --target aarch64-linux-android
    echo "  => target/aarch64-linux-android/release/libfungewubi.so"
else
    echo ""
    echo "[Android] 跳过 (未安装 aarch64-linux-android target)"
    echo "  安装: rustup target add aarch64-linux-android"
fi

echo ""
echo "=== 构建完成 ==="
