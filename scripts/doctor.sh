#!/usr/bin/env bash
# ============================================================================
# 环境体检 —— 3 秒内告诉你：两条投屏路线各自能不能跑、缺什么
#
#   ./doctor.sh
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
PREFIX="${PREFIX:-$HOME/.local}"
HDC="${HDC_BIN:-$ROOT/vendor/openharmony-toolchains/hdc}"

ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

hdr "系统"
printf '  %s / %s / %s\n' "$(uname -sr)" "$(lsb_release -ds 2>/dev/null || echo '未知发行版')" "${XDG_SESSION_TYPE:-?}"
[ -n "${DISPLAY:-}" ] && ok "图形会话 DISPLAY=$DISPLAY（投屏窗口需要它）" || warn "没有 DISPLAY，GUI 窗口可能无法显示"

hdr "方案 A：hdc 投屏 + 控制"
if [ -x "$HDC" ] && "$HDC" -v >/dev/null 2>&1; then
    ok "hdc 可用：$("$HDC" -v)  ($HDC)"
    TARGETS="$("$HDC" list targets 2>/dev/null | head -3)"
    if [ -n "$TARGETS" ]; then
        ok "已连接的设备："
        echo "$TARGETS" | sed 's/^/      /'
    else
        warn "当前没有 hdc 设备：手机上需开启「USB调试」并允许授权，或用无线调试地址"
    fi
else
    bad "找不到可用的 hdc（跑 scripts/setup-hdc.sh）"
fi
python3 -c "import tkinter" 2>/dev/null && ok "python3-tkinter 可用" || bad "缺 tkinter: sudo apt install python3-tk"
python3 -c "import PIL" 2>/dev/null && ok "Pillow 可用" || bad "缺 Pillow: pip3 install pillow"
[ -d /dev/bus/usb ] && ok "USB 设备节点可访问" || warn "看不到 /dev/bus/usb（用无线调试即可绕过）"

hdr "方案 B：Miracast 接收端"
# 无线网卡
IFACE="$(ls /sys/class/net 2>/dev/null | grep -E '^wl' | head -1)"
if [ -n "$IFACE" ]; then
    ok "无线网卡: $IFACE"
    if iw list 2>/dev/null | grep -q "P2P-GO"; then
        ok "网卡支持 P2P-GO（Wi-Fi Direct 必需）"
    else
        bad "网卡不支持 P2P-GO，方案 B 不可用"
    fi
else
    bad "没有无线网卡，方案 B 不可用"
fi
# wpa_supplicant 能力
if [ -x /usr/sbin/wpa_supplicant ]; then
    if strings /usr/sbin/wpa_supplicant 2>/dev/null | grep -q "^WFDIEs$"; then
        ok "wpa_supplicant 编译了 WiFi Display 支持"
    else
        bad "wpa_supplicant 未编译 CONFIG_WIFI_DISPLAY，方案 B 不可用"
    fi
else
    bad "找不到 wpa_supplicant"
fi
# NetworkManager P2P
if nmcli device 2>/dev/null | grep -q "wifi-p2p"; then
    ok "NetworkManager 已托管 P2P 设备"
else
    warn "NetworkManager 没有 P2P 设备（可能是 iwd，方案 B 不支持）"
fi
# MiracleCast
if [ -x "$PREFIX/bin/miracle-wifid" ] && [ -x "$PREFIX/bin/miracle-sinkctl" ]; then
    ok "MiracleCast 已安装：$PREFIX/bin"
else
    warn "MiracleCast 未安装（跑 ./install.sh）"
fi
[ -f /etc/dbus-1/system.d/org.freedesktop.miracle.conf ] \
    && ok "D-Bus 策略已就位" || warn "D-Bus 策略未安装（install.sh 会处理）"
# 播放插件
if command -v gst-inspect-1.0 >/dev/null; then
    MISS=""
    for p in udpsrc rtpjitterbuffer rtpmp2tdepay tsdemux h264parse avdec_h264 autovideosink; do
        gst-inspect-1.0 "$p" >/dev/null 2>&1 || MISS="$MISS $p"
    done
    [ -z "$MISS" ] && ok "GStreamer 播放插件齐全" || bad "缺 GStreamer 插件:$MISS（sudo apt install gstreamer1.0-plugins-bad gstreamer1.0-libav）"
else
    bad "没有 gst-inspect-1.0"
fi
command -v wmctrl >/dev/null && ok "wmctrl 可用（投屏窗口会自动置顶）" || warn "没装 wmctrl（可选，22KB）"
# 防火墙
if command -v ufw >/dev/null; then
    if sudo -n ufw status 2>/dev/null | grep -qi active; then
        warn "ufw 处于 active —— run-miracast-sink.sh 会临时关闭并在退出时恢复"
    else
        ok "ufw 未激活（或无法免密查询）"
    fi
fi

hdr "结论"
if [ -x "$HDC" ]; then
    echo "  • 想「能用鼠标键盘操作手机」→ ./scripts/start-hdc-mirror.sh"
fi
if [ -x "$PREFIX/bin/miracle-sinkctl" ]; then
    echo "  • 想「高清流畅看画面（含声音）」→ ./scripts/run-miracast-sink.sh"
else
    echo "  • 想用「高清流畅投屏」→ 先跑 ./install.sh"
fi
echo
