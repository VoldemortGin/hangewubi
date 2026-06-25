#!/bin/bash
# 本地 CI 薄包装：唯一裁判是 `make check`，本脚本只是它的入口，避免两套真相。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

echo "=== 晗戈五笔 本地 CI（= make check）==="
echo ""

make check

echo ""
echo "=== 本地 CI 完成 ==="
