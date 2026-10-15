# 内置 hdc 的来源与许可

本目录下的三个文件来自 **OpenHarmony SDK** 的 `toolchains` 组件：

| 文件 | 大小 | 说明 |
| --- | --- | --- |
| `hdc` | 6.2 MB | 鸿蒙调试桥客户端（Device Connector），等价于 Android 的 adb |
| `libusb_shared.so` | 114 KB | hdc 唯一的非系统依赖（通过 `$ORIGIN` 相对路径加载） |
| `NOTICE.txt` | 523 KB | SDK 原文附带的第三方许可声明 |

## 来源

```
版本  : OpenHarmony 6.1.0.31 Release（hdc 自报 Ver: 3.2.0c）
包    : ohos-sdk-windows_linux-public.tar.gz
地址  : https://repo.huaweicloud.com/harmonyos/os/6.1-Release/ohos-sdk-windows_linux-public.tar.gz
路径  : linux/toolchains-linux-x64-6.1.0.31-Release.zip → toolchains/{hdc,libusb_shared.so,NOTICE.txt}
平台  : linux-x86_64
```

复现提取过程：

```bash
curl -L https://repo.huaweicloud.com/harmonyos/os/6.1-Release/ohos-sdk-windows_linux-public.tar.gz \
  | tar -xz --wildcards --no-anchored 'linux/toolchains*.zip'
unzip -o linux/toolchains-linux-x64-6.1.0.31-Release.zip -d tc
cp tc/toolchains/{hdc,libusb_shared.so,NOTICE.txt} vendor/openharmony-toolchains/
```

也可以直接运行本项目的 `scripts/setup-hdc.sh --from-sdk` 自动完成（会下载约 2.4GB）。

## 为什么内置

*hdc* 只存在于体积 2.4GB 的 SDK 整包里，而它自身只有 6.2MB；内置一份可以让本项目
**开箱即用**（方案 A 完全不需要安装任何东西）。若你更希望自己获取，删除本目录后运行
`scripts/setup-hdc.sh --from-sdk`，或用环境变量指定：`HDC_BIN=/path/to/hdc`。

## 许可

OpenHarmony SDK 采用 **Apache License 2.0**，版权归 OpenHarmony 项目所有，
第三方组件的完整声明见本目录的 `NOTICE.txt`。
本项目对这三个文件的再分发遵循同一许可；本项目自身的代码为 MIT（见根目录 `LICENSE`）。
