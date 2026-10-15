# 03 · 方案 B：把电脑变成 Miracast 接收端

**特点：用手机原生投屏服务，1080p/30–60fps、带声音、手机几乎不发热；但单向无触控，且投屏期间电脑断网。**

## 原理

```
手机（WFD Source）                          电脑（WFD Sink，本项目）
   │  ① Wi-Fi Direct(P2P) 发现：手机扫到带 WFD IE 的"大屏"
   │◄────────────────────────────────────  wpa_supplicant 广播 WFDIEs
   │  ② P2P 组网（WPS-PBC 免配对，通常 2.4GHz）
   │◄────────────────────────────────────►
   │  ③ DHCP：一端发地址（实测手机当 GO，给电脑 192.168.49.6）
   │  ④ RTSP over TCP 7236：协商分辨率/编码（M1~M7）
   │◄────────────────────────────────────►
   │  ⑤ RTP/MPEG-TS over UDP 7236：H.264 视频 + AAC 音频
   │─────────────────────────────────────►  miracle-sinkctl 拉起 gst-launch 播放
```

电脑侧由 [MiracleCast](https://github.com/albfan/miraclecast) 提供：
`miracle-wifid`（P2P 组网 + 拉起 wpa_supplicant + DHCP）、`miracle-sinkctl`（RTSP 接收端控制台）、
`miracle-dhcp`（DHCP 客户端/服务端）、`miracle-uibcctl`（UIBC 反向输入）。
播放交给外部 `gst-launch-1.0`（脚本 `miracle-gst`），所以**编译期不需要 GStreamer 开发包**。

## 前置条件（`doctor.sh` 会自动检查）

| 项 | 要求 |
| --- | --- |
| 无线网卡 | 支持 `P2P-GO`（`iw list \| grep P2P-GO`） |
| wpa_supplicant | 编译了 `CONFIG_P2P` + `CONFIG_WIFI_DISPLAY`（二进制里能查到 `WFDIEs`） |
| NetworkManager | 能看到 `p2p-dev-*` 设备（Ubuntu 默认满足；**iwd 后端不支持**） |
| 手机 | 是标准 WFD source（检测方法见 [01-why-not-scrcpy.md](01-why-not-scrcpy.md)） |
| 其他 | `meson ninja-build libsystemd-dev libudev-dev libglib2.0-dev libreadline-dev gstreamer1.0-plugins-bad gstreamer1.0-libav` |

## 安装

```bash
./install.sh          # 需要 sudo 密码；只装一次
./install.sh --check  # 只看缺什么，不动系统
```

`install.sh` 做了 5 件事：

1. apt 安装编译依赖与 GStreamer 插件（实测 **76 个包 / 约 40MB**）
2. 从 **gitcode 镜像**克隆 MiracleCast（GitHub 直连不通时的替代）到 `vendor/miraclecast`
3. `meson` 构建并安装到 `~/.local`（**不需要 sudo**）
4. 把 D-Bus 策略装到 `/etc/dbus-1/system.d/`（**必需**，见坑 1）
5. 预检：尝试认领 D-Bus 名字 + 检查 GStreamer 播放插件

## 运行

```bash
./scripts/run-miracast-sink.sh --check   # 先只检查前置条件（不动网络）
./scripts/run-miracast-sink.sh
```

脚本会自动：临时关闭 ufw → 停 NetworkManager/wpa_supplicant（**从这里开始断网**）→
启动 `miracle-wifid` → 前台进入 `miracle-sinkctl`。
在 `miracle-sinkctl` 里：

```
list        # 看 Link 编号（通常是 2）
run 2       # 开始等待手机连接
```

然后手机：**设置 → 更多连接 → 无线投屏 → 选这台电脑**。
连上后电脑会弹出播放窗口（**标题是 `gst-launch-1.0`**，装了 wmctrl 会自动置顶）。
结束：关窗口只停画面，要完全退出在 sinkctl 里输入 `quit`（或 Ctrl+C），
脚本会自动恢复网络与防火墙。

### 手工步骤（不用脚本时）

```bash
# 1) D-Bus 策略（否则 wifid 起不来）
sudo cp vendor/miraclecast/res/org.freedesktop.miracle.conf /etc/dbus-1/system.d/
sudo systemctl reload dbus

# 2) 断网
sudo ufw disable                      # ufw 会挡 DHCP 与 RTSP
sudo systemctl stop NetworkManager wpa_supplicant

# 3) 组网守护（注意 PATH：wifid 用 PATH 找 miracle-dhcp）
export PATH="$HOME/.local/bin:$PATH"
sudo env "PATH=$HOME/.local/bin:/usr/sbin:/usr/bin:/sbin:/bin" miracle-wifid --log-level debug &

# 4) 接收端（注意传 DISPLAY/XAUTHORITY，否则 root 播放器开不了窗口）
sudo env "PATH=$HOME/.local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
     "DISPLAY=$DISPLAY" "XAUTHORITY=$XAUTHORITY" \
     "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" miracle-sinkctl --audio 1
#   list → run <link> → 手机投屏

# 5) 收工
sudo systemctl start wpa_supplicant NetworkManager && sudo ufw enable
```

## ⚠️ 四个必踩的坑（都已在脚本里自动处理）

### 坑 1：D-Bus 策略必须装到**系统目录**

```
ERROR: dbus: cannot claim org.freedesktop.miracle.wifi bus-name: -13   (-13 = EACCES)
```

`ninja install` 会把 `org.freedesktop.miracle.conf` 装到 `~/.local/etc/dbus-1/system.d/`，
**对系统总线无效**。必须：

```bash
sudo cp vendor/miraclecast/res/org.freedesktop.miracle.conf /etc/dbus-1/system.d/
sudo systemctl reload dbus
```

验证（期望 `uint32 1`）：

```bash
sudo dbus-send --system --print-reply --dest=org.freedesktop.DBus / \
  org.freedesktop.DBus.RequestName string:org.freedesktop.miracle.wifi uint32:4
```

### 坑 2：ufw 会挡住 DHCP 与 RTSP

默认策略 deny incoming 会挡掉手机发来的 DHCP(67) 和 RTSP(7236)，表现为
"手机点了但一直连不上 / 不弹画面"。解决：投屏期间 `sudo ufw disable`（脚本自动做并恢复）。

### 坑 3：`sudo` 重置 PATH，子进程找不到

`miracle-wifid` 用 `execvpe("miracle-dhcp", ...)` **按 PATH 查找** DHCP 子进程，
`miracle-sinkctl` 同理查找播放器 `miracle-gst` / `uibc-viewer`。
而 `sudo` 默认把 PATH 重置为 secure_path（不含 `~/.local/bin`），结果是：

- DHCP 起不来 → 手机拿不到 IP → 连不上
- 播放器起不来 → **日志里一行 gst 都没有**（而且失败信息是 debug 级，默认看不到，很容易误判成"没反应"）

必须用 `sudo env "PATH=..."` 显式传入。

### 坑 4：root 运行播放器需要 X 授权

播放器以 root 启动，但窗口要开在用户的桌面会话上，需要显式传：

```bash
DISPLAY=:0  XAUTHORITY=/run/user/1000/.mutter-Xwaylandauth.XXXX  XDG_RUNTIME_DIR=/run/user/1000
```

否则管线可能到 PLAYING 但看不到窗口。

## 实测结果

| 项 | 值 |
| --- | --- |
| P2P 角色 | 手机当 **GO**（`DIRECT-fd-MyPhone`，192.168.49.1），电脑为 client（192.168.49.6） |
| 组网 | WPS-PBC 免配对，2.4GHz ch1，`P2P-GROUP-FORMATION-SUCCESS` |
| 协商分辨率 | **1920×1080** |
| 视频 | H.264 → `avdec_h264` → `autovideosink`（实际落到 `xvimagesink`） |
| 音频 | AAC 48kHz 立体声 → `autoaudiosink`（落到 `alsasink`，经 pipewire-alsa 出声） |
| 播放窗口标题 | `gst-launch-1.0`（容易被别的窗口盖住 → 装 `wmctrl`，脚本会自动置顶） |

## 排错

日志目录：`logs/miracast-<时间戳>/`（`wifid.log` = 组网/DHCP，`sinkctl.log` = 控制台）。

**播放器的输出不在上面两个文件里**（被重定向到 systemd journal），要看：

```bash
journalctl --since "21:09:00" --until "21:11:00" | grep miracle-sinkctl-gst
```

用几行日志定位问题：

| 日志 | 含义 |
| --- | --- |
| `P2P-GO-NEG-SUCCESS` + `P2P-GROUP-FORMATION-SUCCESS` | P2P 组网成功 |
| `SINK connected` → `SINK set resolution WxH` | RTSP 协商成功，马上会拉播放器 |
| `running: /usr/bin/gst-launch-1.0 ...` | 播放器已启动 |
| `Setting pipeline to PLAYING` | 开始播放 |
| `Output window was closed` | 视频窗口被关了（不是错误） |
| `dhcp failed (2)` | 坑 3：PATH 没传对 |
| `cannot claim ... bus-name: -13` | 坑 1：D-Bus 策略 |
| 手机列表里找不到电脑 | 试 `GO_INTENT=15 ./scripts/run-miracast-sink.sh`（强制自己当 GO） |

## 可选调优

```bash
GO_INTENT=15 ./scripts/run-miracast-sink.sh   # 强制电脑当 P2P GO
AUDIO=0      ./scripts/run-miracast-sink.sh   # 静音
UIBC=1       ./scripts/run-miracast-sink.sh   # 尝试 UIBC 反向输入（多数手机不支持）
SCALE=608x1080 ./scripts/run-miracast-sink.sh # 缩放画面
USE_DEV=1    ./scripts/run-miracast-sink.sh   # P2P 设备名被截断时的变通
IFACE=wlan0  ./scripts/run-miracast-sink.sh   # 指定网卡
KEEP_MIRROR=1 ...                             # 不停止正在跑的 hdc 投屏
```

## 参考

- [MiracleCast（albfan fork）](https://github.com/albfan/miraclecast)
- [Wi-Fi Display 技术规范](https://www.wi-fi.org/file/wi-fi-display-technical-specification-v11)
