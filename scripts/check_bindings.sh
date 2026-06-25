#!/usr/bin/env bash
# 契约绑定新鲜度守卫（铁律 6：漂移守卫）
#
# include/hangewubi.h 由 build.rs + cbindgen 从 src/ffi.rs 自动生成。
# 本脚本重新生成头文件并与已提交版本逐字节比对：若不一致，说明改了
# src/ffi.rs 却没提交重新生成的契约头 —— 即"契约漂移"。
set -euo pipefail

# 始终从仓库根运行，路径才稳定。
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

HEADER="include/hangewubi.h"

echo "[check_bindings] cargo build 重新生成 $HEADER ..."
cargo build

echo "[check_bindings] 比对 $HEADER 是否与已提交版本一致 ..."
if ! git diff --exit-code -- "$HEADER"; then
    echo "" >&2
    echo "契约漂移：改了 src/ffi.rs 但没提交重新生成的 $HEADER。" >&2
    echo "请运行 'cargo build' 后提交 $HEADER。" >&2
    exit 1
fi

echo "[check_bindings] OK：契约头新鲜，无漂移。"
