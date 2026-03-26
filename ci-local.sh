#!/bin/bash
set -e

echo "=== 晗戈五笔 本地 CI ==="

echo ""
echo "[1/3] 运行全部测试..."
cargo test

echo ""
echo "[2/3] macOS Release 构建..."
cargo build --release
echo "  => target/release/libhangewubi.dylib"
echo "  => target/release/hangewubi-cli"

echo ""
echo "[3/3] Linux 交叉编译..."
if rustup target list --installed 2>/dev/null | grep -q "x86_64-unknown-linux-gnu"; then
    cargo build --release --target x86_64-unknown-linux-gnu
    echo "  => target/x86_64-unknown-linux-gnu/release/libhangewubi.so"
else
    echo "  跳过：未安装 x86_64-unknown-linux-gnu target"
    echo "  安装命令: rustup target add x86_64-unknown-linux-gnu"
fi

echo ""
echo "=== 本地 CI 完成 ==="
