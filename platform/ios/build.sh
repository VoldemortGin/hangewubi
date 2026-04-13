#!/bin/bash
# 构建晗戈五笔 iOS 输入法
# 用法:
#   ./build.sh          — 模拟器构建（debug），安装到模拟器
#   ./build.sh dev      — 同上
#   ./build.sh device   — 真机构建（debug）
#   ./build.sh dist     — Archive + 导出 IPA（App Store 提交）
set -e

# ==================== 基本变量 ====================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_MODE="${1:-dev}"

# 签名相关常量
TEAM_ID="7H7QT6A3TG"
DEV_SIGNING_IDENTITY="Apple Development: Han Lin (72K7YZLT8B)"
DIST_SIGNING_IDENTITY="Apple Distribution: Han Lin (7H7QT6A3TG)"
APPLE_ID="gin.linhan@gmail.com"

# 构建输出目录
ARCHIVE_DIR="$PROJECT_ROOT/target/ios-archive"
DIST_DIR="$PROJECT_ROOT/target/ios-dist"

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

if [[ "$BUILD_MODE" != "dev" && "$BUILD_MODE" != "device" && "$BUILD_MODE" != "dist" ]]; then
    echo "错误: 未知的构建模式 '$BUILD_MODE'"
    echo "用法: $0 [dev|device|dist]"
    exit 1
fi

echo "=== 构建晗戈五笔 iOS 输入法 (v${VERSION}, 模式: ${BUILD_MODE}) ==="

# dist 模式需要加载凭据
if [[ "$BUILD_MODE" == "dist" ]]; then
    load_credentials

    if [ -z "$APPLE_APP_SPECIFIC_PASSWORD" ]; then
        echo ""
        echo "错误: dist 模式需要 APPLE_APP_SPECIFIC_PASSWORD 用于上传。"
        echo "请通过以下任一方式配置:"
        echo "  1. 在 ~/.apple-developer/config 中设置 APPLE_APP_SPECIFIC_PASSWORD=xxx"
        echo "  2. 添加 Keychain 项: security add-generic-password -s 'hangewubi-notarize' -a '$APPLE_ID' -w 'your-password'"
        echo "  3. 在项目根目录 .env 中设置 APPLE_APP_SPECIFIC_PASSWORD=xxx"
        exit 1
    fi
fi

# ==================== 确定 Rust 编译目标 ====================

if [[ "$BUILD_MODE" == "dev" ]]; then
    RUST_TARGET="aarch64-apple-ios-sim"
    CARGO_PROFILE=""
    PROFILE_DIR="debug"
elif [[ "$BUILD_MODE" == "device" ]]; then
    RUST_TARGET="aarch64-apple-ios"
    CARGO_PROFILE=""
    PROFILE_DIR="debug"
else
    # dist 模式用 release
    RUST_TARGET="aarch64-apple-ios"
    CARGO_PROFILE="--release"
    PROFILE_DIR="release"
fi

# ==================== 1. 检查 Rust target ====================

echo "[1/4] 检查 Rust iOS target..."
if ! rustup target list --installed | grep -q "$RUST_TARGET"; then
    echo "  添加 $RUST_TARGET target..."
    rustup target add "$RUST_TARGET"
fi

# ==================== 2. 编译 Rust 静态库 ====================

echo "[2/4] 编译 Rust 静态库 ($RUST_TARGET, ${PROFILE_DIR})..."
cd "$PROJECT_ROOT"

cargo build $CARGO_PROFILE --target "$RUST_TARGET"

# 删除所有动态库，确保 Xcode 链接器只能找到静态库 (.a)
# cargo 同时生成 .dylib 和 .a，而 -lhangewubi 会优先选择 .dylib，
# 导致 iOS 键盘扩展加载动态库时崩溃
# 注意：必须同时删除 deps/ 目录下的副本，否则链接器仍会找到它
find "$PROJECT_ROOT/target/$RUST_TARGET/$PROFILE_DIR" -name "libhangewubi.dylib" -delete -print 2>/dev/null | while read f; do
    echo "  删除动态库: $f"
done

# 验证静态库存在
STATIC_LIB="$PROJECT_ROOT/target/$RUST_TARGET/$PROFILE_DIR/libhangewubi.a"
if [ ! -f "$STATIC_LIB" ]; then
    echo "错误: 找不到静态库 $STATIC_LIB"
    exit 1
fi
echo "  静态库: $STATIC_LIB"

# ==================== 3. 生成 Xcode 项目 ====================

echo "[3/4] 生成 Xcode 项目..."
cd "$SCRIPT_DIR"
xcodegen generate
cd "$PROJECT_ROOT"

# ==================== 4. 构建 / Archive ====================

echo "[4/4] 构建 Xcode 项目..."

if [[ "$BUILD_MODE" == "dev" ]]; then
    # 模拟器构建
    echo "  构建 Debug (iOS Simulator)..."
    xcodebuild \
        -project "$SCRIPT_DIR/HangeWubi.xcodeproj" \
        -target HangeWubi \
        -configuration Debug \
        -sdk iphonesimulator \
        CODE_SIGNING_ALLOWED=NO \
        build

    echo ""
    echo "=== 构建完成 (v${VERSION}, 模式: dev — 模拟器) ==="

elif [[ "$BUILD_MODE" == "device" ]]; then
    # 真机构建
    echo "  构建 Debug (真机)..."
    xcodebuild \
        -project "$SCRIPT_DIR/HangeWubi.xcodeproj" \
        -target HangeWubi \
        -configuration Debug \
        -sdk iphoneos \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGNING_ALLOWED=NO \
        build

    echo ""
    echo "=== 构建完成 (v${VERSION}, 模式: device — 真机) ==="

elif [[ "$BUILD_MODE" == "dist" ]]; then
    # Archive + 导出 IPA
    ARCHIVE_PATH="$ARCHIVE_DIR/HangeWubi.xcarchive"

    echo "  Archive (App Store)..."
    mkdir -p "$ARCHIVE_DIR"
    rm -rf "$ARCHIVE_PATH"

    xcodebuild archive \
        -project "$SCRIPT_DIR/HangeWubi.xcodeproj" \
        -scheme HangeWubi \
        -configuration Release \
        -sdk iphoneos \
        -archivePath "$ARCHIVE_PATH" \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE=Automatic \
        SUPPORTED_PLATFORMS=iphoneos \
        SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD=NO

    # 生成 ExportOptions.plist
    EXPORT_OPTIONS="$ARCHIVE_DIR/ExportOptions.plist"
    cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>uploadSymbols</key>
    <true/>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

    # 导出 IPA
    echo "  导出 IPA..."
    mkdir -p "$DIST_DIR"
    rm -rf "$DIST_DIR"/*

    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$DIST_DIR" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -allowProvisioningUpdates

    echo ""
    echo "=== 构建完成 (v${VERSION}, 模式: dist — App Store) ==="
    echo "Archive: $ARCHIVE_PATH"
    echo "IPA 输出: $DIST_DIR/"
fi
