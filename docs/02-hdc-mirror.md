# 02 · 方案 A：hdc 投屏 + 反向控制

**特点：零安装、有触控、约 2–12fps。**

## 原理

鸿蒙的 hdc 提供了和 adb 类似的能力，用它组合出投屏与控制：

| 功能 | 命令 |
| --- | --- |
| 抓屏 | `hdc shell snapshot_display -i 0 -t jpeg -f /data/local/tmp/x.jpeg` + `hdc file recv` |
| 点按 | `hdc shell uitest uiInput click <x> <y>`（还有 `doubleClick` / `longClick`） |
| 滑动 | `hdc shell uitest uiInput swipe <x1> <y1> <x2> <y2> [速度]` |
| 滚动 | `hdc shell uitest uiInput dircFling <0左 1右 2上 3下> [速度]` |
| 按键 | `hdc shell uitest uiInput keyEvent Back|Home|Power` |
| 文本 | `hdc shell uitest uiInput text '<内容>'` |

关键细节：

- **文件名后缀必须是 `.jpeg`**（`-t jpeg` 时鸿蒙会校验后缀，写 `.jpg` 直接报错）。
- 单路抓屏约 **2.4fps**（一次抓帧 ≈0.29s + 取回 0.06s）。为了帧率，程序**并行开多路抓屏**，
  每路写自己的设备文件，互不阻塞；实测并行抓屏在手机上可真正并发。

## 前置条件

**手机侧**

1. 设置 → 关于手机 → 连点「版本号」进入开发者模式
2. 设置 → 系统和更新 → 开发者选项 → 打开 **USB调试**
3. 首次连接时手机会弹「是否允许调试」→ 点**允许**（建议勾选始终允许）
4. 可选：打开**无线调试**，记下屏幕上的 `IP:端口`（每次开关都会变）

**电脑侧**

- Python 3 + `tkinter` + `Pillow`：`sudo apt install python3-tk && pip3 install pillow`
- 项目已内置 hdc，无需额外安装

## 使用

```bash
# USB 连接（手机插在电脑上）
./scripts/start-hdc-mirror.sh

# 无线（需要手机上「无线调试」显示的地址）
./scripts/start-hdc-mirror.sh 192.168.1.100:37000
# 之后再跑就直接复用上次地址
./scripts/start-hdc-mirror.sh

# 参数：画质与并行路数
QUALITY=medium PARALLEL=4 ./scripts/start-hdc-mirror.sh
```

`hdc-mirror.py` 的常用参数：

```
--quality high|medium|low   画质档位，默认 high（原生分辨率）
--parallel N                并行抓屏路数，默认 6
--max-size N                窗口内画面最大边长，默认 1000
--selftest --frames N       只测帧率，不开窗口
--device KEY                多设备时用 hdc -t 指定连接键
```

## 界面操作

| 操作 | 效果 |
| --- | --- |
| 左键单击 / 双击 / 拖动 | 点按 / 双击 / 滑动 |
| 滚轮 | 页面上/下滚动 |
| 右键 | 菜单：返回 / 主页 / 电源键 / 长按屏幕中心 / 输入文本 / 保存截图 / 画质 / 置顶 / 退出 |
| 直接敲键盘 | 向手机当前焦点输入框输入文本（停顿 0.3s 后发送，支持中文） |
| `Esc` / `Home` | 返回键 / 主页键 |
| `Ctrl+S` | 保存当前画面到 `~/Pictures/harmony_*.jpeg` |

## 帧率实测与调优

60 帧采样，手机原生分辨率 1224×2776：

| 并行路数 | 持续帧率 |
| --- | --- |
| 1 | 2.4 fps |
| 3 | 4.3 fps |
| 4 | 5.3 fps |
| 6（默认） | 7–8 fps |
| 8 | 10.0 fps |
| **12** | **12.3 fps**（瞬时峰值可到 15） |
| 16 | 12.1 fps（已饱和） |

- **降低分辨率换不到帧率**：`high`(1224×2776) 与 `low`(612×1388) 抓屏速度几乎一样
  （14.3 vs 15.9 fps），说明瓶颈是**手机截图服务本身**，不是编码、带宽或画质。
- 纯抓屏（不含取回/解码/显示）的硬上限约 **14–16 fps**。
- 并行度越高：手机耗电/发热越大，**画面延迟也越大**（12 路约 1s，6 路约 0.7s）。
  建议日常用 6，追求帧率用 12。

## 手工复现（不依赖本项目程序）

```bash
HDC=./vendor/openharmony-toolchains/hdc

$HDC list targets                                  # 看设备
$HDC tconn 192.168.1.100:37000                     # 无线连接（USB 可跳过）
$HDC shell "param get const.product.model"         # 手机型号
$HDC shell "snapshot_display -i 0 -t jpeg -f /data/local/tmp/a.jpeg"
$HDC file recv /data/local/tmp/a.jpeg /tmp/a.jpeg  # 这就是一张手机截图
$HDC shell "uitest uiInput click 600 1500"         # 点屏幕 (600,1500)
```

## 常见问题

- **`hdc list targets` 显示 `Unauthorized`** → 手机没点授权，保持解锁重新连接后点「允许」。
- **USB 连不上、`libusb_open fail -3`** → 调试接口节点属 `root:root`，跑一次
  `./scripts/fix-usb-permission.sh`（需 sudo 密码）装 udev 规则后重新插拔；或直接用无线调试。
- **抓屏报 `suffix must be .jpeg`** → 文件名后缀问题，见上文。
- **无线地址变了** → 手机「无线调试」重新查看端口，`./scripts/start-hdc-mirror.sh 新IP:新端口`。
- 更多见 [04-troubleshooting.md](04-troubleshooting.md)。
