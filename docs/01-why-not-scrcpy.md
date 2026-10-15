# 01 · 为什么 scrcpy 用不了，以及鸿蒙投屏的三条协议

## scrcpy 的链路

scrcpy 要工作，需要三个前提：

1. 通过 **adb** 连接手机；
2. 把 `scrcpy-server.jar` 推到手机；
3. 用手机上的 `/system/bin/app_process`（**Android 运行时 ART**）启动这个 jar，服务端再用 MediaCodec 编码屏幕，通过 socket 回传。

纯血鸿蒙（HarmonyOS 5 / 6，内部基于 OpenHarmony）**不是 Android**：

| 依赖 | Android / EMUI | HarmonyOS NEXT |
| --- | --- | --- |
| 调试桥 | adb | **hdc** |
| 应用运行时 | ART（能跑 jar） | ArkTS / 方舟，**不能跑 scrcpy-server.jar** |
| `app_process` | 有 | **没有** |

所以 scrcpy、QtScrcpy、Escrcpy 等所有 adb 系投屏工具在鸿蒙手机上都不工作，**这不是配置问题**。
（社区同样反馈：[Scrcpy 无法识别鸿蒙 6.0](https://bbs.itying.com/topic/6a115059c4b04d0047fcada4)、[Genymobile/scrcpy#4137](https://github.com/Genymobile/scrcpy/issues/4137)）

## 鸿蒙自己的"无线传屏"是三条不同的协议

| 协议 | 手机里的实现 | Linux 能当接收端吗 |
| --- | --- | --- |
| **Huawei Cast+ / 分布式软总线(DSoftbus)** | `com.huawei.hmos.huaweicast` + `DSoftbus` 系统能力 | ❌ 私有协议，只对华为智慧屏 / 装了「华为电脑管家」的 Windows PC 开放，无 Linux 实现 |
| **Miracast（Wi-Fi Display，WFA 标准）** | 系统「无线投屏」找标准大屏时使用 | ✅ **可以**，本项目方案 B 就是它 |
| **DLNA** | 视频 App 里的"投电视" | ❌ 只能推媒体流，不是屏幕镜像 |

一个常见误区：**`gnome-network-displays`（GNOME Network Displays）是"发送端"**——把电脑投到电视。
方向正好相反，不能用它来接手机。Linux 上真正的 Miracast **接收端**只有
[MiracleCast](https://github.com/albfan/miraclecast)（C，本项目方案 B 使用）和
[lazycast](https://github.com/homeworkc/lazycast)（Python，深度绑定树莓派）。

## 那 Linux 上到底怎么投鸿蒙？

本项目把两条可行路线都做了：

- **方案 A（hdc）**：不用任何"投屏协议"，直接用鸿蒙的调试能力抓屏 + 注入输入。
  优点：**零安装、有触控**。缺点：帧率受限于手机截图服务（约 2–12fps）。
- **方案 B（Miracast sink）**：让电脑冒充一台 Miracast 大屏，手机用**原生投屏服务**推流。
  优点：**1080p/30–60fps/带声音**，手机几乎不发热。缺点：单向、要装依赖、投屏时电脑断网。

## 怎么验证你的手机支持 Miracast

手机侧不需要 root，只要开发者选项打开 USB 调试即可（`hdc` 用于查询）。在电脑上：

```bash
HDC=./vendor/openharmony-toolchains/hdc

# 1) 让 wpa_supplicant 参与 P2P 发现（注意网卡名被截断到 15 字符）
sudo wpa_cli -i wlp0s20f3 set wifi_display 1
sudo wpa_cli -i wlp0s20f3 p2p_find

# 2) 手机上打开「设置 → 更多连接 → 无线投屏」，让它搜 30 秒

# 3) 看发现了谁（重点看有没有 wfd_dev_info / wfd_subelems）
sudo wpa_cli -i wlp0s20f3 p2p_peers
sudo wpa_cli -i wlp0s20f3 p2p_peer <上面的 MAC>

# 4) 收尾
sudo wpa_cli -i wlp0s20f3 p2p_stop_find
sudo wpa_cli -i wlp0s20f3 set wifi_display 0
```

判读：

- `p2p_peer` 里有 `wfd_subelems=...`，且 `manufacturer=ohos` → **你的手机是标准 WFD source**，方案 B 可行 ✅
- 只有打印机、电视等设备有 WFD 信息，手机没有 → 鸿蒙可能只走私有链路，方案 B 只能放弃

本项目实测（华为 ADA-AL00U / HarmonyOS 6.1）：

```
aa:bb:cc:dd:ee:ff
manufacturer=ohos
device_name=MyPhone
pri_dev_type=10-0050F204-5
wfd_subelems=00000600101c4400c8     ← 00=设备信息子元素, 0006=长度,
                                      0010=能力位(source), 1c44=RTSP端口7236, c8=吞吐
```

## 参考

- [Wi-Fi Display 技术规范（Wi-Fi Alliance）](https://www.wi-fi.org/file/wi-fi-display-technical-specification-v11)
- [MiracleCast README](https://github.com/albfan/miraclecast)
- [hdc 官方文档（OpenHarmony）](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/dfx/hdc.md)
