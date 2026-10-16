#!/usr/bin/env bash
# ============================================================================
# 让这台电脑当 Miracast 接收端（Display Sink），接收手机的「无线投屏」
#
#   ./run-miracast-sink.sh
#
# 可选环境变量：
#   IFACE=wlp0s20f3   指定无线网卡（默认自动取第一块 wl* 网卡）
#   GO_INTENT=15      强制自己当 P2P GO（默认不指定，交给双方协商）
#   USE_DEV=1         启用 "no ifname" 变通（P2P 设备名被截断时可能需要）
#   UIBC=1            启用 UIBC 反向输入（能不能用取决于手机的 source 实现）
#   AUDIO=0           关闭声音（默认开）
#   KEEP_MIRROR=1     不停止现有的 hdc 投屏进程
#
# ⚠️ 脚本会临时停掉 NetworkManager / wpa_supplicant —— 电脑会断网。
#    退出时（输入 quit 或按 Ctrl+C）自动恢复网络和防火墙。
# ============================================================================
set -uo pipefail

# 解析符号链接，兼容「系统安装 + /usr/bin 软链」的调用方式
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "$SELF")" && pwd)"
ROOT="${HARMONY_MIRROR_ROOT:-$(dirname "$HERE")}"
PREFIX="${PREFIX:-$HOME/.local}"

# miracle-* 程序可能来自：用户自建（~/.local）、deb 系统安装（$ROOT/bin）、源码构建产物
BIN_DIRS=("$PREFIX/bin" "$ROOT/bin" "/usr/lib/harmony-mirror/bin" "/usr/local/bin")
find_miracle_dir() {
    for d in "${BIN_DIRS[@]}"; do
        [ -x "$d/miracle-wifid" ] && [ -x "$d/miracle-sinkctl" ] && { printf '%s\n' "$d"; return 0; }
    done
    return 1
}
MIRACLE_DIR="$(find_miracle_dir || true)"
# 子进程（miracle-dhcp / miracle-gst / uibc-viewer）按 PATH 查找，必须把这些目录都带上
RUN_PATH="$MIRACLE_DIR:$PREFIX/bin:$ROOT/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH="$RUN_PATH"

IFACE="${IFACE:-$(ls /sys/class/net 2>/dev/null | grep -E '^wl' | head -1)}"
AUDIO="${AUDIO:-1}"
GO_INTENT="${GO_INTENT:-}"
USE_DEV="${USE_DEV:-0}"
UIBC="${UIBC:-0}"
KEEP_MIRROR="${KEEP_MIRROR:-0}"

STAMP="$(date +%Y%m%d_%H%M%S)"
LOGDIR="$ROOT/logs/miracast-$STAMP"

c()  { printf '\033[1;36m[miracast]\033[0m %s\n' "$*"; }
w()  { printf '\033[1;33m[miracast]\033[0m %s\n' "$*"; }
e()  { printf '\033[1;31m[miracast]\033[0m %s\n' "$*" >&2; }

if [ -z "$MIRACLE_DIR" ]; then
    e "找不到 miracle-wifid / miracle-sinkctl"
    e "用户自建：$ROOT/install.sh    |    系统安装：sudo apt install ./harmony-mirror_*.deb"
    exit 1
fi
if [ -z "$IFACE" ]; then
    e "找不到无线网卡"
    exit 1
fi

# ---- --check：只检查，不动网络 ----
if [ "${1:-}" = "--check" ]; then
    c "只检查模式（不会改动任何东西）"
    ok=1
    c "miracle 目录    ✓ $MIRACLE_DIR"
    [ -x "$MIRACLE_DIR/miracle-sinkctl" ] && c "miracle-sinkctl ✓" || { e "缺 miracle-sinkctl"; ok=0; }
    [ -x "$MIRACLE_DIR/miracle-dhcp" ]    && c "miracle-dhcp    ✓（手机靠它拿 IP）" || { w "缺 miracle-dhcp，手机可能拿不到 IP"; }
    if [ -f /etc/dbus-1/system.d/org.freedesktop.miracle.conf ]; then
        c "D-Bus 策略      ✓ /etc/dbus-1/system.d/"
    else
        e "D-Bus 策略未安装（wifid 会以 -13 EACCES 退出）；本脚本首次运行会自动安装"
        ok=0
    fi
    for cand in "$ROOT/vendor/miraclecast/res/org.freedesktop.miracle.conf" \
                "$ROOT/build/miraclecast/res/org.freedesktop.miracle.conf"; do
        [ -f "$cand" ] && { c "策略源文件      ✓ $cand"; POLICY_FOUND=1; break; }
    done
    [ "${POLICY_FOUND:-0}" = "1" ] || w "找不到策略源文件（已安装到系统时无所谓）"
    c "无线网卡        ✓ $IFACE"
    iw list 2>/dev/null | grep -q "P2P-GO" && c "P2P-GO          ✓ 网卡支持 Wi-Fi Direct" || { e "网卡不支持 P2P-GO"; ok=0; }
    if strings /usr/sbin/wpa_supplicant 2>/dev/null | grep -q "^WFDIEs$"; then
        c "WiFi Display    ✓ wpa_supplicant 支持 WFD"
    else
        e "wpa_supplicant 未编译 CONFIG_WIFI_DISPLAY"; ok=0
    fi
    command -v wmctrl >/dev/null && c "wmctrl          ✓ 窗口会自动置顶" || w "没装 wmctrl（可选：sudo apt install wmctrl）"
    command -v gst-inspect-1.0 >/dev/null && c "GStreamer       ✓ 已安装" || { e "缺 gstreamer1.0-tools"; ok=0; }
    echo
    [ "$ok" = "1" ] && c "检查通过，可以直接运行： $0" || e "存在阻塞项，请先解决上面标 ✗ 的项"
    exit $((1-ok))
fi

mkdir -p "$LOGDIR" 2>/dev/null || {
    LOGDIR="${XDG_CACHE_HOME:-$HOME/.cache}/harmony-mirror/miracast-$STAMP"
    mkdir -p "$LOGDIR"
}
UFW_WAS_ACTIVE=0
WIFID_PID=""

restore() {
    trap - EXIT INT TERM
    echo
    c "正在恢复环境..."
    [ -n "$WIFID_PID" ] && sudo kill "$WIFID_PID" 2>/dev/null
    sudo pkill -f miracle-sinkctl 2>/dev/null
    sudo pkill -f miracle-wifid 2>/dev/null
    sudo pkill -f gst-launch-1.0 2>/dev/null
    sudo pkill -f uibc-viewer 2>/dev/null
    sleep 1
    sudo systemctl start wpa_supplicant 2>/dev/null
    sudo systemctl start NetworkManager 2>/dev/null
    if [ "$UFW_WAS_ACTIVE" = "1" ]; then
        sudo ufw --force enable >/dev/null 2>&1 && c "ufw 已恢复启用"
    fi
    c "网络已恢复（WiFi 重连需要几秒）"
    c "日志目录: $LOGDIR"
    if [ "$KEEP_MIRROR" != "1" ]; then
        c "如需恢复 hdc 投屏: ./start-mirror.sh"
    fi
}
trap restore EXIT INT TERM

c "无线网卡: $IFACE   日志: $LOGDIR"

# ---- 1. 临时放行防火墙（P2P 链路上的 DHCP / RTSP 7236 会被 ufw 默认拒绝）----
if sudo ufw status 2>/dev/null | grep -qi "Status: active"; then
    UFW_WAS_ACTIVE=1
    w "检测到 ufw active，临时关闭（退出时自动恢复）"
    sudo ufw disable >"$LOGDIR/ufw.log" 2>&1
fi
if sudo iptables -S 2>/dev/null | grep -q "DROP\|REJECT"; then
    w "iptables 里还有 DROP/REJECT 规则，如果连不上可能需要额外放行"
fi

# ---- 1.5 D-Bus 策略（必须装在系统目录，否则 wifid 会以 EACCES 退出）----
# 症状：cannot claim org.freedesktop.miracle.wifi bus-name: -13
DBUS_POLICY=/etc/dbus-1/system.d/org.freedesktop.miracle.conf
if [ ! -f "$DBUS_POLICY" ]; then
    POLICY_SRC=""
    for cand in "$ROOT/vendor/miraclecast/res/org.freedesktop.miracle.conf" \
                "$ROOT/build/miraclecast/res/org.freedesktop.miracle.conf" \
                "$HERE/res/org.freedesktop.miracle.conf"; do
        [ -f "$cand" ] && POLICY_SRC="$cand" && break
    done
    if [ -z "$POLICY_SRC" ]; then
        e "找不到 org.freedesktop.miracle.conf，无法安装 D-Bus 策略"
        e "请先执行安装脚本 $ROOT/install.sh（它会把 MiracleCast 源码放在 vendor/miraclecast）"
        exit 1
    fi
    c "安装 D-Bus 策略到 $DBUS_POLICY"
    if ! sudo cp "$POLICY_SRC" "$DBUS_POLICY"; then
        e "复制 D-Bus 策略失败（需要 sudo 权限）"
        exit 1
    fi
    if systemctl cat dbus 2>/dev/null | grep -q "ExecReload"; then
        sudo systemctl reload dbus || sudo systemctl restart dbus
    else
        sudo systemctl restart dbus
    fi
    sleep 1
    c "D-Bus 策略已安装并生效"
else
    c "D-Bus 策略已存在: $DBUS_POLICY"
fi

# 断网前预检：试认领一下 D-Bus 名字（失败就提前退出，不白断网）
if command -v dbus-send >/dev/null 2>&1; then
    REPLY="$(sudo dbus-send --system --print-reply --dest=org.freedesktop.DBus \
        / org.freedesktop.DBus.RequestName \
        string:org.freedesktop.miracle.wifi uint32:4 2>&1 || true)"
    if echo "$REPLY" | grep -qE "uint32 (1|4)"; then
        c "D-Bus 名字预检通过"
    elif echo "$REPLY" | grep -qiE "access|denied|reject|not allowed"; then
        e "D-Bus 仍拒绝认领 org.freedesktop.miracle.wifi："
        echo "$REPLY" | head -3 >&2
        e "策略没生效，请先执行: sudo systemctl restart dbus  然后重跑本脚本"
        exit 1
    else
        w "D-Bus 名字预检结果异常，仍继续尝试：$(echo "$REPLY" | head -1)"
    fi
fi

# ---- 2. 停掉会抢网卡的服务（断网开始）----
if [ "$KEEP_MIRROR" != "1" ]; then
    for p in $(ps -eo pid,args | awk '$2=="python3" && $3 ~ /hdc_mirror\.py$/ {print $1}'); do
        kill "$p" 2>/dev/null
    done
    c "已停止 hdc 投屏进程（断网后它也无法工作）"
fi

c "停止 NetworkManager / wpa_supplicant —— 现在开始断网"
sudo systemctl stop NetworkManager wpa_supplicant
sleep 2

# ---- 3. 启动 miracle-wifid ----
# 关键：wifid 用 PATH 查找它要拉起的子进程 miracle-dhcp（DHCP 服务器，
# 手机靠它拿 IP），而 sudo 默认会重置 PATH 为 secure_path（不含 ~/.local/bin），
# 所以必须用 sudo env 显式把 PATH 传进去，否则 DHCP 起不来。
WIFID_ARGS=(--log-level debug)
[ -n "$GO_INTENT" ] && WIFID_ARGS+=(--go-intent "$GO_INTENT")
[ "$USE_DEV" = "1" ] && WIFID_ARGS+=(--use-dev)
WIFID_ARGS+=(-i "$IFACE")

c "启动 miracle-wifid ${WIFID_ARGS[*]}"
sudo env "PATH=$RUN_PATH" "$MIRACLE_DIR/miracle-wifid" "${WIFID_ARGS[@]}" \
    >"$LOGDIR/wifid.log" 2>&1 &
WIFID_PID=$!
sleep 4

if ! sudo kill -0 "$WIFID_PID" 2>/dev/null; then
    e "miracle-wifid 启动失败，日志如下："
    tail -20 "$LOGDIR/wifid.log" >&2
    exit 1
fi
c "miracle-wifid 已运行 (pid $WIFID_PID)"

if grep -qi "dhcp failed" "$LOGDIR/wifid.log" 2>/dev/null; then
    w "wifid 日志里出现 dhcp 失败，手机可能拿不到 IP："
    grep -i "dhcp failed" "$LOGDIR/wifid.log" | head -3
fi

cat <<EOF

================================ 接下来在手机和这个终端里操作 ================================

  1) 在这个终端里输入：   list          （列出 wifi link，编号通常是 2）
  2) 然后输入：           run 2         （开始等待手机连接；编号按 list 结果填）

  3) 手机：设置 → 更多连接 → 无线投屏 → 选择出现的这台电脑

  4) 连上后电脑上会弹出播放窗口（标题是 gst-launch-1.0），显示手机画面。
     ★ 如果看不到窗口：按 Alt+Tab 找 "gst-launch-1.0"，它可能开在了其他窗口后面。
       装了 wmctrl 的话脚本会自动把它置顶。

  5) 结束：关掉播放窗口只停止画面；要完全退出请在 sinkctl 里输入 quit（或 Ctrl+C），
     脚本会自动恢复网络和防火墙。

  排查用的日志目录：
      $LOGDIR
      （wifid.log = 组网/DHCP，sinkctl.log = 控制台；播放器的输出在系统日志里：
        journalctl --since "<开始时间>" | grep miracle-sinkctl-gst）
============================================================================================

EOF

# 自动把播放窗口置顶（需要 wmctrl；窗口标题是 gst-launch-1.0）
if command -v wmctrl >/dev/null 2>&1; then
    (
        for _ in $(seq 1 1200); do
            if wmctrl -l 2>/dev/null | grep -qi "gst-launch"; then
                wmctrl -r "gst-launch-1.0" -b add,above 2>/dev/null
                wmctrl -a "gst-launch-1.0" 2>/dev/null
                c "已把投屏窗口置顶"
                break
            fi
            sleep 0.5
        done
    ) &
else
    w "未安装 wmctrl，投屏窗口不会自动置顶（可 sudo apt install wmctrl，仅 22KB）"
fi

# ---- 4. 前台运行 sinkctl（保持 DISPLAY / XAUTHORITY 供播放窗口使用）----
SINK_ARGS=(--audio "$AUDIO" --log-time)
[ "$UIBC" = "1" ] && SINK_ARGS+=(--uibc)
[ -n "${SCALE:-}" ] && SINK_ARGS+=(--scale "$SCALE")

sudo env \
    "PATH=$RUN_PATH" \
    "DISPLAY=${DISPLAY:-:0}" \
    "XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}" \
    "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}" \
    "$MIRACLE_DIR/miracle-sinkctl" "${SINK_ARGS[@]}" 2>&1 | tee "$LOGDIR/sinkctl.log"

# 正常退出会走到 trap -> restore
