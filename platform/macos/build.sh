#!/bin/bash
# 构建晗戈五笔 macOS 输入法
# 用法:
#   ./build.sh          — 开发模式（ad-hoc 签名）
#   ./build.sh dev      — 同上
#   ./build.sh release  — Developer ID 签名 + 强化运行时
#   ./build.sh dist     — Developer ID 签名 + 公证 + DMG 打包
set -e

# ==================== 基本变量 ====================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/target/macos-app"
APP_NAME="HangeWubi.app"
BUILD_MODE="${1:-dev}"

# 签名相关常量
SIGNING_IDENTITY="Developer ID Application: Han Lin (7H7QT6A3TG)"
TEAM_ID="7H7QT6A3TG"
APPLE_ID="gin.linhan@gmail.com"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"

# 从 Cargo.toml 读取版本号
VERSION=$(grep '^version' "$PROJECT_ROOT/Cargo.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')

# ==================== 凭据加载 ====================

load_credentials() {
    # 优先从 ~/.apple-developer/config 读取
    if [ -f "$HOME/.apple-developer/config" ]; then
        echo "  从 ~/.apple-developer/config 加载凭据"
        source "$HOME/.apple-developer/config"
    fi

    # 回退到项目根目录的 .env
    if [ -z "$APPLE_APP_SPECIFIC_PASSWORD" ] && [ -f "$PROJECT_ROOT/.env" ]; then
        echo "  从 .env 加载凭据"
        source "$PROJECT_ROOT/.env"
    fi

    # 回退到 Keychain
    if [ -z "$APPLE_APP_SPECIFIC_PASSWORD" ]; then
        APPLE_APP_SPECIFIC_PASSWORD=$(security find-generic-password -s "hangewubi-notarize" -w 2>/dev/null || true)
        if [ -n "$APPLE_APP_SPECIFIC_PASSWORD" ]; then
            echo "  从 Keychain 加载凭据"
        fi
    fi
}

# ==================== 参数校验 ====================

if [[ "$BUILD_MODE" != "dev" && "$BUILD_MODE" != "release" && "$BUILD_MODE" != "dist" ]]; then
    echo "错误: 未知的构建模式 '$BUILD_MODE'"
    echo "用法: $0 [dev|release|dist]"
    exit 1
fi

echo "=== 构建晗戈五笔 macOS 输入法 (v${VERSION}, 模式: ${BUILD_MODE}) ==="

# release 和 dist 模式需要加载凭据
if [[ "$BUILD_MODE" == "release" || "$BUILD_MODE" == "dist" ]]; then
    load_credentials
fi

# dist 模式必须有 App-Specific Password
if [[ "$BUILD_MODE" == "dist" && -z "$APPLE_APP_SPECIFIC_PASSWORD" ]]; then
    echo ""
    echo "错误: dist 模式需要 APPLE_APP_SPECIFIC_PASSWORD 用于公证。"
    echo "请通过以下任一方式配置:"
    echo "  1. 在 ~/.apple-developer/config 中设置 APPLE_APP_SPECIFIC_PASSWORD=xxx"
    echo "  2. 添加 Keychain 项: security add-generic-password -s 'hangewubi-notarize' -a '$APPLE_ID' -w 'your-password'"
    echo "  3. 在项目根目录 .env 中设置 APPLE_APP_SPECIFIC_PASSWORD=xxx"
    exit 1
fi

# ==================== 1. 编译 Rust 引擎 ====================

echo "[1/6] 编译 Rust 引擎..."
cd "$PROJECT_ROOT"
cargo build --release

# ==================== 2. 创建 .app bundle 结构 ====================

echo "[2/6] 创建 .app bundle..."
rm -rf "$BUILD_DIR/$APP_NAME"
mkdir -p "$BUILD_DIR/$APP_NAME/Contents/MacOS"
mkdir -p "$BUILD_DIR/$APP_NAME/Contents/Resources/data"

cp "$SCRIPT_DIR/Info.plist" "$BUILD_DIR/$APP_NAME/Contents/"

# ==================== 3. 编译 Swift 壳 ====================

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

# ==================== 4. 复制资源文件 ====================

echo "[4/6] 复制资源..."
cp "$PROJECT_ROOT/target/release/libhangewubi.dylib" "$BUILD_DIR/$APP_NAME/Contents/MacOS/"
cp "$PROJECT_ROOT/data/wubi86.txt" "$BUILD_DIR/$APP_NAME/Contents/Resources/data/"
cp "$PROJECT_ROOT/data/config.toml" "$BUILD_DIR/$APP_NAME/Contents/Resources/data/"

# 复制应用图标
cp "$SCRIPT_DIR/AppIcon.icns" "$BUILD_DIR/$APP_NAME/Contents/Resources/AppIcon.icns"

# 复制本地化文件
cp -r "$SCRIPT_DIR/zh-Hans.lproj" "$BUILD_DIR/$APP_NAME/Contents/Resources/"
cp -r "$SCRIPT_DIR/en.lproj" "$BUILD_DIR/$APP_NAME/Contents/Resources/"

# ==================== 5. 生成菜单栏图标 ====================

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
"晗".draw(at: NSPoint(x: 1, y: 0), withAttributes: attrs)
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

# ==================== 6. 代码签名 ====================

echo "[6/6] 代码签名..."

if [[ "$BUILD_MODE" == "dev" ]]; then
    # 开发模式: ad-hoc 签名
    echo "  使用 ad-hoc 签名（开发模式）"
    codesign --force --sign - "$BUILD_DIR/$APP_NAME/Contents/MacOS/libhangewubi.dylib"
    codesign --force --deep --sign - "$BUILD_DIR/$APP_NAME"
else
    # release / dist 模式: Developer ID 签名 + 强化运行时
    echo "  使用 Developer ID 签名 + 强化运行时"

    # 先签 dylib
    codesign --force --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --timestamp \
        --entitlements "$ENTITLEMENTS" \
        "$BUILD_DIR/$APP_NAME/Contents/MacOS/libhangewubi.dylib"

    # 再签整个 .app（--deep 会递归签名所有内嵌的可执行文件和框架）
    codesign --force --deep --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --timestamp \
        --entitlements "$ENTITLEMENTS" \
        "$BUILD_DIR/$APP_NAME"

    # 验证签名
    echo "  验证签名..."
    codesign --verify --verbose=2 "$BUILD_DIR/$APP_NAME"
    echo "  签名验证通过"
fi

# ==================== 7. DMG 打包 + 公证（仅 dist 模式） ====================

if [[ "$BUILD_MODE" == "dist" ]]; then
    DMG_NAME="HangeWubi-${VERSION}.dmg"
    DMG_PATH="$BUILD_DIR/$DMG_NAME"

    echo ""
    echo "=== 创建 DMG 安装包 ==="

    # 创建 DMG（带自定义卷图标）
    echo "[DMG] 打包 $DMG_NAME ..."
    rm -f "$DMG_PATH"

    # 创建临时暂存目录，放入 app 和卷图标
    STAGING_DIR="$BUILD_DIR/dmg-staging"
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"
    cp -R "$BUILD_DIR/$APP_NAME" "$STAGING_DIR/"
    cp "$SCRIPT_DIR/AppIcon.icns" "$STAGING_DIR/.VolumeIcon.icns"
    SetFile -a C "$STAGING_DIR"

    hdiutil create -volname "HangeWubi" \
        -srcfolder "$STAGING_DIR" \
        -ov -format UDZO \
        "$DMG_PATH"

    # 清理暂存目录
    rm -rf "$STAGING_DIR"

    echo ""
    echo "=== 公证 DMG ==="

    # 提交公证
    echo "[公证] 提交 $DMG_NAME 到 Apple 公证服务..."
    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait

    # 装订公证票据
    echo "[公证] 装订公证票据..."
    xcrun stapler staple "$DMG_PATH"

    echo ""
    echo "=== 公证完成 ==="
    echo "DMG 输出: $DMG_PATH"
fi

# ==================== 完成 ====================

echo ""
echo "=== 构建完成 (v${VERSION}, 模式: ${BUILD_MODE}) ==="
echo "App 输出: $BUILD_DIR/$APP_NAME"

if [[ "$BUILD_MODE" == "dev" ]]; then
    echo ""
    echo "安装方法:"
    echo "  cp -r $BUILD_DIR/$APP_NAME ~/Library/Input\\ Methods/"
    echo "  然后注销重新登录，在系统设置 > 键盘 > 输入源中添加"
fi
