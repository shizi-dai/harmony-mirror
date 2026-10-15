#!/usr/bin/env bash
# ============================================================================
# 方案 A：hdc 投屏 + 反向控制（有触控，12fps 左右）
#
#   ./start-hdc-mirror.sh                      # 用已连接的设备（USB 或上次的无线地址）
#   ./start-hdc-mirror.sh 192.168.1.100:37000  # 指定无线调试地址（会记住）
#   QUALITY=medium PARALLEL=4 ./start-hdc-mirror.sh
#   python3 hdc-mirror.py --selftest            # 只测帧率
#
# 环境变量：
#   HDC_BIN   指定 hdc 路径（默认用项目内置的）
#   QUALITY   high | medium | low（默认 high）
#   PARALLEL  并行抓屏路数（默认 6；实测 12 路约 12fps，8 路约 10fps）
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
STATE_DIR="$ROOT/state"
mkdir -p "$STATE_DIR"

export HDC_BIN="${HDC_BIN:-$ROOT/vendor/openharmony-toolchains/hdc}"
LAST="$STATE_DIR/last_target"
QUALITY="${QUALITY:-high}"
PARALLEL="${PARALLEL:-6}"

if [ ! -x "$HDC_BIN" ]; then
    echo "找不到 hdc：$HDC_BIN" >&2
    echo "可执行 scripts/setup-hdc.sh 重新获取，或用 HDC_BIN=/path/to/hdc 指定。" >&2
    exit 1
fi

TARGET="${1:-}"
if [ -n "$TARGET" ]; then
    printf '%s\n' "$TARGET" >"$LAST"
elif [ -f "$LAST" ]; then
    TARGET="$(cat "$LAST")"
fi

ARGS=(--quality "$QUALITY" --parallel "$PARALLEL")
if [ -n "$TARGET" ]; then
    ARGS=("$TARGET" "${ARGS[@]}")
    echo "连接目标：$TARGET"
else
    echo "使用当前 hdc 设备（USB 或已连接的无线）"
fi

exec python3 "$HERE/hdc-mirror.py" "${ARGS[@]}"
