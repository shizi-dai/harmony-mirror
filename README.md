# harmony-mirror · Ubuntu ↔ 鸿蒙 投屏工具箱

在 Ubuntu / Linux 上把华为鸿蒙手机（HarmonyOS NEXT / 纯血鸿蒙）的画面投到电脑，并且能反过来用鼠标键盘操作手机。

**为什么不是 scrcpy？** 纯血鸿蒙没有 Android 运行时，scrcpy 依赖的 `adb + scrcpy-server.jar + app_process` 在鸿蒙上不存在。本项目用鸿蒙自己的调试桥 **hdc** 和鸿蒙自带的**无线投屏服务**，给出两条互补的路线：

| | 方案 A：hdc 投屏 | 方案 B：Miracast 接收端 |
| --- | --- | --- |
| 原理 | hdc 抓屏 + `uitest` 注入输入 | 电脑冒充 Miracast 接收端，手机原生投屏 |
| 画面 | 约 2–12 fps（可调并行度） | **1080p、30–60fps、带声音** |
| 延迟 | 约 0.3–1s | 约 0.3–1s |
| **触控/键盘** | ✅ **完整支持**（点击/滑动/长按/滚轮/文本输入） | ❌ 单向（Miracast UIBC 手机侧基本未实现） |
| 手机负载 | 较高（持续截图编码） | 低（走硬件编码器） |
| 安装 | **零安装**，项目已内置 hdc | 需装依赖 + 编译 MiracleCast（约 40MB） |
| 断网 | 不需要 | 投屏期间电脑**会短暂断网** |
| 适合 | 需要操作手机 | 需要高清看画面 |

> 两者可以同时使用：**Miracast 看画面 + hdc 控手机**。

---

## 实测环境与结果

本项目的所有步骤都在真实设备上端到端验证过：

| 项 | 值 |
| --- | --- |
| 手机 | HUAWEI ADA-AL00U，HarmonyOS 6.1.0.135(SP8C00E120R1P6)，API 24 |
| 手机分辨率 | 1224 × 2776 |
| 电脑 | Ubuntu 26.04.1 LTS，Wayland，Intel CNVi 无线网卡 |
| hdc | 3.2.0c（项目内置） |
| 方案 A 帧率 | 1 路 2.4fps → 6 路 7.2fps → 12 路 **12.3fps**（16 路饱和） |
| 方案 B 结果 | P2P 组网成功、**协商 1920×1080**、H.264 + AAC 正常解码播放 |

方案 B 的关键日志（证实真的跑通）：

```
P2P-GO-NEG-SUCCESS role=client freq=2412 wps_method=PBC
NOTICE: SINK connected
SINK set resolution 1920x1080
gst-launch-1.0 -v udpsrc port=7236 ! rtpjitterbuffer ! rtpmp2tdepay ! tsdemux
     ! h264parse ! avdec_h264 ! videoconvert ! autovideosink
Setting pipeline to PLAYING ...
```

---

## 快速开始

```bash
git clone https://github.com/<你的账号>/harmony-mirror.git && cd harmony-mirror

# 0. 体检：3 秒告诉你两条路线各自能不能跑、缺什么
./scripts/doctor.sh
```

**方案 A（推荐先试这个，零安装，带触控）**

```bash
# 手机：设置 → 系统和更新 → 开发者选项 → 打开「USB调试」
#       （可选）再打开「无线调试」，记下屏幕上的 IP:端口
./scripts/start-hdc-mirror.sh                      # USB 连接
./scripts/start-hdc-mirror.sh 192.168.1.100:37000  # 无线（会记住地址）
```

**方案 B（高清带声音，需要安装一次）**

```bash
./install.sh                    # 装依赖 + 编译 MiracleCast（需要 sudo 密码，约 40MB）
./scripts/run-miracast-sink.sh --check   # 只检查前置条件，不动网络
./scripts/run-miracast-sink.sh  # 开始接收；按屏幕提示操作，退出时自动恢复网络
```

---

## 目录结构

```
harmony-mirror/
├── install.sh                       方案 B 的一键安装（依赖 + MiracleCast + D-Bus 策略）
├── scripts/
│   ├── doctor.sh                    环境体检（强烈建议先跑）
│   ├── start-hdc-mirror.sh          方案 A 启动器（记住上次无线地址）
│   ├── hdc-mirror.py                方案 A 主程序（并行抓屏 + 输入注入）
│   ├── run-miracast-sink.sh         方案 B：一键接收端（自动处理断网/防火墙/X 授权）
│   ├── setup-hdc.sh                 重新获取 hdc（内置的那个被删时用）
│   └── fix-usb-permission.sh        修 USB 权限（一次性，需 sudo）
├── vendor/openharmony-toolchains/   内置 hdc 3.2.0c + libusb_shared.so（来源见 PROVENANCE.md）
└── docs/
    ├── 01-why-not-scrcpy.md         为什么 scrcpy 用不了、鸿蒙投屏的三条协议
    ├── 02-hdc-mirror.md             方案 A 原理、参数、调优、手工复现
    ├── 03-miracast-sink.md          方案 B 原理、依赖、四个坑、排错
    └── 04-troubleshooting.md        常见问题速查
```

---

## 两句原理

- **方案 A**：`hdc shell snapshot_display` 抓 JPEG → `hdc file recv` 取回 → 显示；输入用 `hdc shell uitest uiInput`（click/swipe/keyEvent/text）。为了帧率，程序**并行开多路抓屏**（单路约 2.4fps，12 路约 12fps，瓶颈是手机截图服务本身，降分辨率也没用）。
- **方案 B**：不用 hdc。电脑用 `wpa_supplicant` 的 Wi-Fi Direct(P2P) + **WiFi Display 信息元素**把自己伪装成一台 Miracast 接收设备，手机的「无线投屏」就会把它当成大屏；随后手机用标准 WFD/RTSP(7236) + RTP 把 1080p H.264 + AAC 推过来，电脑用 GStreamer 播放。

细节见 `docs/`。

---

## 已知限制

- 方案 B 投屏期间电脑**没有网络**（MiracleCast 需要独占 wpa_supplicant），退出脚本会自动恢复。
- 方案 B 目前只能单向看画面；反向控制（UIBC）在框架里存在，但手机的 source 端基本没实现。
- 方案 A 帧率受限于手机截图服务，无法做到电影级流畅，但操作延迟可接受。
- 只在内网/近场使用；Miracast 是点对点直连，手机与电脑距离不要太远。

## 许可

本项目自己的脚本与文档：MIT。内置的 hdc 来自 OpenHarmony SDK（Apache-2.0），MiracleCast 为 LGPL-2.1（通过 `install.sh` 从上游获取，不随本项目分发）。详见 `vendor/openharmony-toolchains/PROVENANCE.md` 与 `LICENSE`。
