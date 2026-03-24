#!/bin/bash
# 构建函戈五笔 macOS 输入法
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/target/macos-app"
APP_NAME="HangeWubi.app"

echo "=== 构建函戈五笔 macOS 输入法 ==="

# 1. 编译 Rust 引擎
echo "[1/4] 编译 Rust 引擎..."
cd "$PROJECT_ROOT"
cargo build --release

# 2. 创建 .app bundle 结构
echo "[2/4] 创建 .app bundle..."
rm -rf "$BUILD_DIR/$APP_NAME"
mkdir -p "$BUILD_DIR/$APP_NAME/Contents/MacOS"
mkdir -p "$BUILD_DIR/$APP_NAME/Contents/Resources/data"

cp "$SCRIPT_DIR/Info.plist" "$BUILD_DIR/$APP_NAME/Contents/"

# 3. 编译 Swift 壳
echo "[3/4] 编译 Swift 壳..."
swiftc \
    -target arm64-apple-macos14.0 \
    -import-objc-header "$SCRIPT_DIR/BridgingHeader.h" \
    -L "$PROJECT_ROOT/target/release" \
    -lhangewubi \
    -framework InputMethodKit \
    -framework Cocoa \
    -o "$BUILD_DIR/$APP_NAME/Contents/MacOS/HangeWubi" \
    "$SCRIPT_DIR/main.swift" \
    "$SCRIPT_DIR/InputController.swift"

# 4. 复制资源文件
echo "[4/4] 复制资源..."
cp "$PROJECT_ROOT/target/release/libhangewubi.dylib" "$BUILD_DIR/$APP_NAME/Contents/MacOS/"
cp "$PROJECT_ROOT/data/wubi86.txt" "$BUILD_DIR/$APP_NAME/Contents/Resources/data/"
cp "$PROJECT_ROOT/data/config.toml" "$BUILD_DIR/$APP_NAME/Contents/Resources/data/"

# 修复 dylib 路径
install_name_tool -change \
    "target/release/libhangewubi.dylib" \
    "@executable_path/libhangewubi.dylib" \
    "$BUILD_DIR/$APP_NAME/Contents/MacOS/HangeWubi" 2>/dev/null || true

echo ""
echo "=== 构建完成 ==="
echo "输出: $BUILD_DIR/$APP_NAME"
echo ""
echo "安装方法:"
echo "  cp -r $BUILD_DIR/$APP_NAME ~/Library/Input\\ Methods/"
echo "  然后注销重新登录，在系统设置 > 键盘 > 输入源中添加"
