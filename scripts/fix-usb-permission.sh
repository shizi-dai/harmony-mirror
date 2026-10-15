#!/usr/bin/env bash
# 让普通用户可以通过 USB 直接调试华为/鸿蒙设备（hdc / adb）
#
# 背景：手机开启「USB调试」后会枚举出 12d1:xxxx 的调试接口，
#       该设备节点默认属于 root:root，普通用户打不开（libusb_open 失败 -3）。
#       安装一条 udev 规则即可，需要 sudo 密码（本脚本由你手动执行）。
#
#   ./fix-usb-permission.sh
#
set -euo pipefail
RULE=/etc/udev/rules.d/71-harmony-hdc.rules

sudo tee "$RULE" >/dev/null <<'EOF'
# Huawei / HarmonyOS HDC + ADB debug interfaces
SUBSYSTEM=="usb", ATTR{idVendor}=="12d1", MODE="0660", GROUP="plugdev"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=usb

echo "已安装 $RULE"
echo "请重新插拔一次数据线，之后 USB 直连即可使用（无需再开无线调试）。"
