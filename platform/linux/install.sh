#!/usr/bin/env bash
# 函戈五笔 Linux 安装脚本
# 需要 root 权限 (sudo)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PREFIX="${PREFIX:-/usr}"
LIB_DIR="$PREFIX/lib/ibus-hangewubi"
SHARE_DIR="$PREFIX/share/ibus-hangewubi"
DATA_DIR="$SHARE_DIR/data"
COMPONENT_DIR="$PREFIX/share/ibus/component"

echo "=== 函戈五笔 Linux 安装 ==="
echo "安装前缀: $PREFIX"

# 检查是否以 root 运行（安装到 /usr 时需要）
if [[ "$PREFIX" == "/usr" && "$EUID" -ne 0 ]]; then
    echo "错误: 安装到 /usr 需要 root 权限，请使用 sudo"
    exit 1
fi

# 先构建
echo ""
echo "--- 构建 ---"
bash "$SCRIPT_DIR/build.sh"

RELEASE_DIR="$PROJECT_ROOT/target/release"

# 检查构建产物
for f in "$RELEASE_DIR/ibus-engine-hangewubi" "$RELEASE_DIR/libhangewubi.so"; do
    if [[ ! -f "$f" ]]; then
        echo "错误: 构建产物不存在: $f"
        exit 1
    fi
done

# 创建目录
echo ""
echo "--- 安装文件 ---"
install -d "$LIB_DIR"
install -d "$DATA_DIR"
install -d "$COMPONENT_DIR"

# 安装二进制文件
install -m 755 "$RELEASE_DIR/ibus-engine-hangewubi" "$LIB_DIR/"
echo "  已安装: $LIB_DIR/ibus-engine-hangewubi"

# 安装共享库
install -m 644 "$RELEASE_DIR/libhangewubi.so" "$LIB_DIR/"
echo "  已安装: $LIB_DIR/libhangewubi.so"

# 安装数据文件
install -m 644 "$PROJECT_ROOT/data/wubi86.txt" "$DATA_DIR/"
echo "  已安装: $DATA_DIR/wubi86.txt"

install -m 644 "$PROJECT_ROOT/data/config.toml" "$DATA_DIR/"
echo "  已安装: $DATA_DIR/config.toml"

# 安装 IBus 组件描述文件
install -m 644 "$SCRIPT_DIR/ibus-hangewubi.xml" "$COMPONENT_DIR/"
echo "  已安装: $COMPONENT_DIR/ibus-hangewubi.xml"

# 生成简易图标（如果不存在）
ICON_PATH="$SHARE_DIR/icon.png"
if [[ ! -f "$ICON_PATH" ]]; then
    # 尝试用 ImageMagick 生成简易图标
    if command -v convert &>/dev/null; then
        convert -size 64x64 xc:white \
            -font "Noto-Sans-CJK" -pointsize 48 \
            -gravity center -annotate 0 "五" \
            -fill '#2563eb' -draw "rectangle 0,0 63,63" \
            -fill white -gravity center -annotate 0 "五" \
            "$ICON_PATH" 2>/dev/null || true
        if [[ -f "$ICON_PATH" ]]; then
            echo "  已生成: $ICON_PATH"
        fi
    fi
    # 如果生成失败，创建一个占位提示
    if [[ ! -f "$ICON_PATH" ]]; then
        echo "  注意: 未能生成图标文件 $ICON_PATH"
        echo "  请手动放置 64x64 PNG 图标到该路径"
    fi
fi

# 更新共享库缓存
if command -v ldconfig &>/dev/null; then
    ldconfig 2>/dev/null || true
fi

echo ""
echo "=== 安装完成 ==="
echo ""

# 重启 IBus
if command -v ibus &>/dev/null; then
    echo "正在重启 IBus..."
    ibus restart &>/dev/null || true
    echo "IBus 已重启"
    echo ""
    echo "请在系统设置中添加「函戈五笔」输入法"
    echo "  或运行: ibus engine hangewubi"
else
    echo "IBus 未安装或不在 PATH 中，请手动重启 IBus"
fi
