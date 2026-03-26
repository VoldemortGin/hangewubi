#!/usr/bin/env bash
# 晗戈五笔 Linux 构建脚本
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== 晗戈五笔 Linux 构建 ==="
echo "项目根目录: $PROJECT_ROOT"

# 检查依赖
for cmd in cargo gcc pkg-config; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "错误: 未找到 $cmd，请先安装"
        exit 1
    fi
done

if ! pkg-config --exists ibus-1.0; then
    echo "错误: 未找到 libibus-1.0 开发包"
    echo "  Debian/Ubuntu: sudo apt install libibus-1.0-dev"
    echo "  Fedora:        sudo dnf install ibus-devel"
    echo "  Arch:          sudo pacman -S ibus"
    exit 1
fi

# 1. 编译 Rust 库
echo ""
echo "--- 编译 Rust 库 (libhangewubi.so) ---"
cd "$PROJECT_ROOT"
cargo build --release
echo "libhangewubi.so 已生成: $PROJECT_ROOT/target/release/libhangewubi.so"

# 2. 编译 C IBus 引擎
echo ""
echo "--- 编译 IBus 引擎 ---"
IBUS_CFLAGS=$(pkg-config --cflags ibus-1.0)
IBUS_LIBS=$(pkg-config --libs ibus-1.0)

gcc -o "$PROJECT_ROOT/target/release/ibus-engine-hangewubi" \
    "$SCRIPT_DIR/ibus-engine-hangewubi.c" \
    -I"$PROJECT_ROOT/include" \
    $IBUS_CFLAGS \
    $IBUS_LIBS \
    -L"$PROJECT_ROOT/target/release" -lhangewubi \
    -Wl,-rpath,'/usr/lib/ibus-hangewubi' \
    -Wl,-rpath,'$ORIGIN' \
    -Wall -O2

echo "ibus-engine-hangewubi 已生成: $PROJECT_ROOT/target/release/ibus-engine-hangewubi"

echo ""
echo "=== 构建完成 ==="
echo ""
echo "如需安装，请运行: sudo bash $SCRIPT_DIR/install.sh"
echo "如需本地测试，请运行:"
echo "  LD_LIBRARY_PATH=$PROJECT_ROOT/target/release \\"
echo "  $PROJECT_ROOT/target/release/ibus-engine-hangewubi \\"
echo "  --data-dir $PROJECT_ROOT/data"
