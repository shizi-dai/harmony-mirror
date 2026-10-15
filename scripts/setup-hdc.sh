#!/usr/bin/env bash
# ============================================================================
# 获取 / 刷新 hdc（鸿蒙调试桥客户端）
#
#   ./setup-hdc.sh                 # 检查项目内置的 hdc 是否可用
#   ./setup-hdc.sh --from-sdk      # 从 OpenHarmony SDK 重新提取（下载约 2.4GB）
#   VERSION=6.0-Release ./setup-hdc.sh --from-sdk
#
# hdc 来源：OpenHarmony SDK 的 toolchains（Apache-2.0），只依赖同目录的 libusb_shared.so。
# 项目已内置一份，正常情况无需运行本脚本。
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
DEST="$ROOT/vendor/openharmony-toolchains"
VERSION="${VERSION:-6.1-Release}"
URL="https://repo.huaweicloud.com/harmonyos/os/${VERSION}/ohos-sdk-windows_linux-public.tar.gz"
WORK="$ROOT/build/hdc-fetch"

c() { printf '\033[1;36m[hdc]\033[0m %s\n' "$*"; }
w() { printf '\033[1;33m[hdc]\033[0m %s\n' "$*"; }
e() { printf '\033[1;31m[hdc]\033[0m %s\n' "$*" >&2; }

verify() {
    [ -x "$DEST/hdc" ] || return 1
    "$DEST/hdc" -v >/dev/null 2>&1
}

if [ "${1:-}" != "--from-sdk" ]; then
    if verify; then
        c "项目内置 hdc 可用：$("$DEST/hdc" -v)"
        c "路径: $DEST/hdc"
        exit 0
    fi
    w "内置 hdc 不可用（可能被删或架构不符）"
    w "重新获取： $0 --from-sdk     （下载约 2.4GB）"
    w "或指定系统里已有的： HDC_BIN=/path/to/hdc ./scripts/start-hdc-mirror.sh"
    exit 1
fi

# ---------------------------------------------------------------- 从 SDK 提取
command -v curl >/dev/null || { e "需要 curl"; exit 1; }
command -v unzip >/dev/null || { e "需要 unzip: sudo apt install unzip"; exit 1; }

mkdir -p "$WORK"
c "下载 OpenHarmony SDK ($VERSION)，约 2.4GB，请耐心等待"
c "URL: $URL"
if ! curl -L --fail "$URL" | tar -xz -C "$WORK" --wildcards --no-anchored 'linux/toolchains*.zip'; then
    e "下载或解包失败"
    exit 1
fi

TC_ZIP="$(find "$WORK" -name 'toolchains*.zip' | head -1)"
[ -n "$TC_ZIP" ] || { e "没有在 SDK 里找到 toolchains 包"; exit 1; }

c "解压 $(basename "$TC_ZIP")"
rm -rf "$WORK/tc"
unzip -o -q "$TC_ZIP" -d "$WORK/tc" || { e "unzip 失败"; exit 1; }

mkdir -p "$DEST"
for f in hdc libusb_shared.so NOTICE.txt; do
    src="$(find "$WORK/tc" -name "$f" | head -1)"
    [ -n "$src" ] && cp -f "$src" "$DEST/$f"
done
chmod +x "$DEST/hdc" 2>/dev/null

if verify; then
    c "完成：$("$DEST/hdc" -v)"
    c "路径: $DEST/hdc"
    rm -rf "$WORK"
else
    e "提取后仍无法运行，请检查架构（本项目面向 x86_64）"
    exit 1
fi
