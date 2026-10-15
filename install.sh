#!/usr/bin/env bash
# ============================================================================
# 安装脚本 —— 为「方案 B：Miracast 接收端」准备依赖与程序
#
#   ./install.sh              # 安装（需要 sudo 密码）
#   ./install.sh --check      # 只体检，不安装任何东西
#
# 说明：
#   * 方案 A（hdc 投屏 + 控制）不需要本脚本，项目已内置 hdc，装好 Python 依赖即可。
#   * 本脚本做的事：
#       1. apt 安装编译依赖（约 76 个包 / 40MB）与 GStreamer 播放插件
#       2. 从 gitcode 镜像克隆 MiracleCast（GitHub 直连不通时的替代）
#       3. meson 构建并安装到 ~/.local（不需要 sudo）
#       4. 把 D-Bus 策略装到 /etc/dbus-1/system.d/（必须，否则 wifid 起不来）
#       5. 做一次断网前预检
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
VENDOR="$HERE/vendor"
SRC_DIR="$VENDOR/miraclecast"
BUILD_DIR="$HERE/build/miraclecast"
DBUS_POLICY=/etc/dbus-1/system.d/org.freedesktop.miracle.conf

# MiracleCast 源码（按可用性排序；GitHub 优先，国内镜像兜底）
CLONE_URLS=(
    "https://gitcode.com/ethanoy/miraclecast"
    "https://github.com/albfan/miraclecast"
)
APT_DEPS=(
    meson ninja-build libsystemd-dev libudev-dev libglib2.0-dev libreadline-dev
    gstreamer1.0-plugins-bad gstreamer1.0-libav
)
OPT_DEPS=(wmctrl)          # 让投屏窗口能自动置顶，可选

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

c() { printf '\033[1;36m[install]\033[0m %s\n' "$*"; }
w() { printf '\033[1;33m[install]\033[0m %s\n' "$*"; }
e() { printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; }

missing_pkgs() {
    local miss=()
    for p in "$@"; do
        dpkg -s "$p" >/dev/null 2>&1 || miss+=("$p")
    done
    printf '%s\n' "${miss[@]:-}"
}

# ---------------------------------------------------------------- 体检
c "环境体检"
MISSING="$(missing_pkgs "${APT_DEPS[@]}" | tr '\n' ' ')"
if [ -n "${MISSING// /}" ]; then
    w "缺少编译依赖: $MISSING"
else
    c "编译依赖齐全"
fi
MISSING_OPT="$(missing_pkgs "${OPT_DEPS[@]}" | tr '\n' ' ')"
[ -n "${MISSING_OPT// /}" ] && w "可选包未装: $MISSING_OPT（装了才能自动置顶投屏窗口）"

if command -v meson >/dev/null 2>&1 && [ -x "$PREFIX/bin/miracle-wifid" ]; then
    c "MiracleCast 已安装在 $PREFIX/bin"
    INSTALLED=1
else
    INSTALLED=0
fi
[ -f "$DBUS_POLICY" ] && c "D-Bus 策略已就位" || w "D-Bus 策略尚未安装"

if [ "$CHECK_ONLY" = "1" ]; then
    echo
    c "仅体检模式，未做任何修改。"
    exit 0
fi

# ---------------------------------------------------------------- 1. 依赖
if [ -n "${MISSING// /}" ]; then
    c "安装编译依赖（需要 sudo 密码）"
    sudo apt update -qq || true
    sudo apt install -y "${APT_DEPS[@]}" || { e "依赖安装失败"; exit 1; }
fi
if [ -n "${MISSING_OPT// /}" ]; then
    w "建议同时安装可选包（22KB，用于窗口自动置顶）： sudo apt install -y wmctrl"
fi

# ---------------------------------------------------------------- 2. 源码
if [ ! -d "$SRC_DIR/.git" ]; then
    mkdir -p "$VENDOR"
    ok=0
    for url in "${CLONE_URLS[@]}"; do
        c "克隆 MiracleCast: $url"
        if git clone --depth 1 "$url" "$SRC_DIR"; then ok=1; break; fi
        rm -rf "$SRC_DIR"
    done
    [ "$ok" = "1" ] || { e "克隆失败：GitHub/镜像都不通，请手动下载后放到 $SRC_DIR"; exit 1; }
else
    c "源码已存在: $SRC_DIR"
fi

# ---------------------------------------------------------------- 3. 构建
c "构建（meson + ninja）"
rm -rf "$BUILD_DIR"
meson setup "$BUILD_DIR" "$SRC_DIR" --prefix="$PREFIX" -Dbuild-tests=false >/dev/null || {
    e "meson 配置失败"; exit 1; }
ninja -C "$BUILD_DIR" >/dev/null || { e "编译失败"; exit 1; }
ninja -C "$BUILD_DIR" install >/dev/null || { e "安装失败"; exit 1; }
c "已安装到 $PREFIX/bin: $(ls "$PREFIX/bin" | grep -c miracle) 个 miracle-* 程序"

# ---------------------------------------------------------------- 4. D-Bus 策略
POLICY_SRC="$SRC_DIR/res/org.freedesktop.miracle.conf"
if [ -f "$POLICY_SRC" ] && [ ! -f "$DBUS_POLICY" ]; then
    c "安装 D-Bus 策略到 $DBUS_POLICY"
    sudo cp "$POLICY_SRC" "$DBUS_POLICY" || { e "复制失败"; exit 1; }
    if systemctl cat dbus 2>/dev/null | grep -q ExecReload; then
        sudo systemctl reload dbus || sudo systemctl restart dbus
    else
        sudo systemctl restart dbus
    fi
    sleep 1
fi

# ---------------------------------------------------------------- 5. 预检
c "预检：能否认领 D-Bus 名字"
REPLY="$(sudo dbus-send --system --print-reply --dest=org.freedesktop.DBus \
    / org.freedesktop.DBus.RequestName \
    string:org.freedesktop.miracle.wifi uint32:4 </dev/null 2>&1 || true)"
if echo "$REPLY" | grep -qE "uint32 (1|4)"; then
    c "预检通过 ✓"
else
    w "预检未通过，wifid 可能起不来："
    echo "$REPLY" | head -3
    w "可尝试: sudo systemctl restart dbus  然后重跑本脚本"
fi

c "预检 GStreamer 播放插件"
if [ -x "$SRC_DIR/res/test-viewer.sh" ]; then
    ( cd "$SRC_DIR" && bash res/test-viewer.sh 2>&1 | tail -3 )
fi

echo
c "安装完成。下一步："
echo "    ./scripts/doctor.sh              # 体检 3 秒钟"
echo "    ./scripts/run-miracast-sink.sh   # 开始接收手机投屏（会短暂断网）"
echo
echo "方案 A（有触控的 hdc 投屏）无需安装，直接： ./scripts/start-hdc-mirror.sh"
