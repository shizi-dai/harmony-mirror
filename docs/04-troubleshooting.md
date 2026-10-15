# 04 · 常见问题速查

先跑体检，一半的问题它会直接告诉你：

```bash
./scripts/doctor.sh
```

---

## 通用

| 症状 | 原因 / 解决 |
| --- | --- |
| 完全没头绪 | 先 `./scripts/doctor.sh`，它会分别检查两条路线的每个前置条件 |
| 想确认手机系统版本 | `./vendor/openharmony-toolchains/hdc shell "param get const.product.software.version"` |
| 手机重启后一切失效 | 无线调试端口会变；重新在手机上打开「无线调试」看新端口 |

## 方案 A（hdc 投屏 / 控制）

| 症状 | 原因 / 解决 |
| --- | --- |
| `hdc list targets` 为空 | 手机没开 USB 调试，或没点授权弹窗 |
| 列表显示 `Unauthorized` | 手机保持解锁，重新连接并在弹窗点「允许」 |
| `libusb_open fail -3` / USB 连不上 | 调试接口设备节点属 `root:root`。跑 `./scripts/fix-usb-permission.sh`（需 sudo），重新插拔；或改用无线调试 |
| `没有可用的 hdc 设备` | 内置 hdc 在 `vendor/openharmony-toolchains/hdc`；被删了跑 `./scripts/setup-hdc.sh` |
| 抓屏报 `suffix must be .jpeg` | 鸿蒙要求 jpeg 类型时后缀必须是 `.jpeg`（不是 `.jpg`） |
| 窗口一片黑 / 花屏 | 手机可能锁屏了；解锁即可。锁屏时 `snapshot_display` 抓到的是锁屏画面 |
| 只有 ~2fps | 加大并行：`PARALLEL=12 ./scripts/start-hdc-mirror.sh`（上限约 12fps） |
| 延长后卡顿 | 并行度过高会让手机发热降频，降到 6 试试 |
| 点击位置偏 | 手机旋转过？程序会按当前帧尺寸换算，若错位请重新打开窗口 |
| 键盘输入没反应 | 需要手机上已有一个**获得焦点**的输入框 |
| 缺少 tkinter / Pillow | `sudo apt install python3-tk` / `pip3 install pillow` |

## 方案 B（Miracast 接收端）

| 症状 | 原因 / 解决 |
| --- | --- |
| `cannot claim org.freedesktop.miracle.wifi bus-name: -13` | D-Bus 策略没装到系统目录（坑 1）。`install.sh` 会处理；手工：`sudo cp vendor/miraclecast/res/org.freedesktop.miracle.conf /etc/dbus-1/system.d/ && sudo systemctl reload dbus` |
| `找不到 miracle-wifid` | 还没安装：`./install.sh` |
| 手机投屏列表里**找不到电脑** | ① 先确认手机是标准 WFD source（见 01 文档）② 试 `GO_INTENT=15 ./scripts/run-miracast-sink.sh` ③ 重开手机的投屏界面再搜 |
| 手机点了但连不上 / 不弹画面 | ufw 在挡（坑 2）。脚本会自动关，若你手工跑的记得 `sudo ufw disable` |
| wifid 日志里 `dhcp failed` | PATH 没传对（坑 3）：要用 `sudo env "PATH=...包含~/.local/bin..."` |
| 日志里一行 gst 都没有 | 播放器没起来（坑 3），或失败信息是 debug 级被吞了。手工跑时给 sinkctl 加 `--log-level debug` |
| 管线到 PLAYING 但看不到窗口 | 窗口被别的窗口盖住（标题 `gst-launch-1.0`，Alt+Tab 找）；或 X 授权没传（坑 4） |
| 没有声音 | 音频走 `alsasink`→pipewire-alsa；可在手机上检查媒体音量，或 `AUDIO=0` 先静音 |
| 画面 1080p 横向、竖屏内容两侧有黑边 | 手机屏幕是竖屏（1224×2776），协商的是横向 1080p。用 `SCALE=` 调整窗口，或容忍黑边 |
| 投屏完电脑没网 | 脚本正常退出会自动恢复；若是强杀脚本，手工 `sudo systemctl start wpa_supplicant NetworkManager && sudo ufw enable` |
| 想彻底不折腾网络 | 换一条路：**手机 USB-C 有线投屏（DP Alt Mode）→ HDMI 采集卡 → 电脑**，免 root、零延迟、不动网络（要买采集卡；仍是单向） |

### 怎么查播放器的日志

播放器的输出被重定向到 systemd journal，不在 `logs/` 里：

```bash
journalctl --since "21:09:00" --until "21:11:00" | grep miracle-sinkctl-gst
```

常见关键行：`running: /usr/bin/gst-launch-1.0 ...`、`Setting pipeline to PLAYING`、
`Output window was closed`（窗口被关，不是错误）。

## 手机端

| 症状 | 原因 / 解决 |
| --- | --- |
| 找不到「开发者选项」 | 设置 → 关于手机 → 连点「版本号」7 次 |
| 找不到「无线调试」 | 先打开「USB调试」；部分机型需先插一次 USB |
| 「无线投屏」搜不到任何设备 | 确认手机 Wi-Fi 已打开；靠近电脑；两边都重开一次搜索 |
| 手机提示"不支持此设备" | 该手机可能只支持华为私有投屏（Cast+），方案 B 不可用，改用方案 A |

## 还是不行？

收集这些信息再提问，定位会快很多：

```bash
./scripts/doctor.sh
ls -la logs/miracast-*/                 # 方案 B 的日志目录
journalctl --since "-10 min" | grep -E "miracle|gst-launch"   # 方案 B 播放器日志
./vendor/openharmony-toolchains/hdc list targets -v            # 方案 A 设备状态
./vendor/openharmony-toolchains/hdc shell "param get const.product.software.version"
```
