#!/bin/bash
# 构建函戈五笔 macOS 输入法
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/target/macos-app"
APP_NAME="HangeWubi.app"

echo "=== 构建函戈五笔 macOS 输入法 ==="

# 1. 编译 Rust 引擎
echo "[1/6] 编译 Rust 引擎..."
cd "$PROJECT_ROOT"
cargo build --release

# 2. 创建 .app bundle 结构
echo "[2/6] 创建 .app bundle..."
rm -rf "$BUILD_DIR/$APP_NAME"
mkdir -p "$BUILD_DIR/$APP_NAME/Contents/MacOS"
mkdir -p "$BUILD_DIR/$APP_NAME/Contents/Resources/data"

cp "$SCRIPT_DIR/Info.plist" "$BUILD_DIR/$APP_NAME/Contents/"

# 3. 编译 Swift 壳
echo "[3/6] 编译 Swift 壳..."
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
echo "[4/6] 复制资源..."
cp "$PROJECT_ROOT/target/release/libhangewubi.dylib" "$BUILD_DIR/$APP_NAME/Contents/MacOS/"
cp "$PROJECT_ROOT/data/wubi86.txt" "$BUILD_DIR/$APP_NAME/Contents/Resources/data/"
cp "$PROJECT_ROOT/data/config.toml" "$BUILD_DIR/$APP_NAME/Contents/Resources/data/"

# 复制本地化文件
cp -r "$SCRIPT_DIR/zh-Hans.lproj" "$BUILD_DIR/$APP_NAME/Contents/Resources/"
cp -r "$SCRIPT_DIR/en.lproj" "$BUILD_DIR/$APP_NAME/Contents/Resources/"

# 5. 生成菜单栏图标
echo "[5/6] 生成菜单栏图标..."
ICON_PATH="$BUILD_DIR/$APP_NAME/Contents/Resources/icon.png"
swift -e '
import AppKit
let size = NSSize(width: 16, height: 16)
let img = NSImage(size: size)
img.lockFocus()
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13),
    .foregroundColor: NSColor.black
]
"函".draw(at: NSPoint(x: 1, y: 0), withAttributes: attrs)
img.unlockFocus()
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
' "$ICON_PATH"

# 修复 dylib 路径（查找实际引用路径并替换为 @executable_path）
OLD_DYLIB_PATH=$(otool -L "$BUILD_DIR/$APP_NAME/Contents/MacOS/HangeWubi" | grep libhangewubi | awk '{print $1}')
if [ -n "$OLD_DYLIB_PATH" ]; then
    install_name_tool -change "$OLD_DYLIB_PATH" "@executable_path/libhangewubi.dylib" \
        "$BUILD_DIR/$APP_NAME/Contents/MacOS/HangeWubi"
fi

# 6. 代码签名（ad-hoc，不加 --options runtime 以避免 Team ID 不匹配）
echo "[6/6] 代码签名..."
codesign --force --sign - "$BUILD_DIR/$APP_NAME/Contents/MacOS/libhangewubi.dylib"
codesign --force --deep --sign - "$BUILD_DIR/$APP_NAME"

echo ""
echo "=== 构建完成 ==="
echo "输出: $BUILD_DIR/$APP_NAME"
echo ""
echo "安装方法:"
echo "  cp -r $BUILD_DIR/$APP_NAME ~/Library/Input\\ Methods/"
echo "  然后注销重新登录，在系统设置 > 键盘 > 输入源中添加"
