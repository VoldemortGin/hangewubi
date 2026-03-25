#!/bin/bash
# 构建函戈五笔 iOS 键盘 - Rust 静态库编译
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== 构建函戈五笔 iOS 静态库 ==="

# 1. Check for iOS target
echo "[1/3] 检查 Rust iOS target..."
if ! rustup target list --installed | grep -q "aarch64-apple-ios"; then
    echo "添加 aarch64-apple-ios target..."
    rustup target add aarch64-apple-ios
fi

# 2. Build Rust static library for iOS
echo "[2/3] 编译 Rust 静态库 (aarch64-apple-ios)..."
cd "$PROJECT_ROOT"
# Cargo.toml only has cdylib; we need staticlib for iOS.
# Temporarily patch Cargo.toml, build, then restore.
CARGO_TOML="$PROJECT_ROOT/Cargo.toml"
cp "$CARGO_TOML" "$CARGO_TOML.bak"
sed -i '' 's/crate-type = \["lib", "cdylib"\]/crate-type = ["lib", "cdylib", "staticlib"]/' "$CARGO_TOML"

cargo build --release --target aarch64-apple-ios

# Restore original Cargo.toml
mv "$CARGO_TOML.bak" "$CARGO_TOML"

STATIC_LIB="$PROJECT_ROOT/target/aarch64-apple-ios/release/libhangewubi.a"
if [ ! -f "$STATIC_LIB" ]; then
    echo "错误: 找不到静态库 $STATIC_LIB"
    echo "请确认 Cargo.toml 中 crate-type 包含 \"staticlib\""
    exit 1
fi
echo "静态库: $STATIC_LIB"

# 3. Verify data files
echo "[3/3] 验证数据文件..."
if [ ! -f "$PROJECT_ROOT/data/wubi86.txt" ]; then
    echo "错误: 找不到 data/wubi86.txt"
    exit 1
fi
echo "数据文件: $PROJECT_ROOT/data/wubi86.txt"

echo ""
echo "=== Rust 静态库编译完成 ==="
echo ""
echo "静态库路径: $STATIC_LIB"
echo "C 头文件:   $PROJECT_ROOT/include/hangewubi.h"
echo ""
echo "=== Xcode 项目配置说明 ==="
echo ""
echo "1. 打开 Xcode → File → New → Project → iOS → App"
echo "   - Product Name: HangeWubi"
echo "   - Bundle Identifier: com.hangewubi.app"
echo "   - Language: Swift"
echo "   - Interface: Storyboard (删除 Storyboard 后用代码创建)"
echo ""
echo "2. 添加 Keyboard Extension:"
echo "   File → New → Target → iOS → Custom Keyboard Extension"
echo "   - Product Name: HangeWubiKeyboard"
echo "   - Language: Swift"
echo ""
echo "3. 配置 Extension Target:"
echo "   a. Build Settings → Swift Compiler - General → Objective-C Bridging Header:"
echo "      设置为: \$(SRCROOT)/platform/ios/HangeWubiKeyboard/BridgingHeader.h"
echo "   b. Build Settings → Library Search Paths:"
echo "      添加: $PROJECT_ROOT/target/aarch64-apple-ios/release"
echo "   c. Build Settings → Other Linker Flags:"
echo "      添加: -lhangewubi"
echo "   d. Build Phases → Link Binary With Libraries:"
echo "      添加: $STATIC_LIB"
echo ""
echo "4. 复制源文件到 Xcode 项目:"
echo "   - Host App:  platform/ios/HangeWubi/*.swift"
echo "   - Extension: platform/ios/HangeWubiKeyboard/*.swift"
echo ""
echo "5. 添加数据文件到 Extension Target:"
echo "   将 data/wubi86.txt 拖入 HangeWubiKeyboard target 的 Copy Bundle Resources"
echo ""
echo "6. 设置 Extension Info.plist:"
echo "   用 platform/ios/HangeWubiKeyboard/Info.plist 中的 NSExtension 配置替换"
echo ""
echo "7. 设置最低部署版本: iOS 15.0"
echo ""
echo "8. 连接 iPhone 或使用模拟器 → Build & Run"
