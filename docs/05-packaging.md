# 05 · 二进制分发（让别人不用编译）

本项目可以打包成**安装即用**的二进制包，使用者不需要 meson、不需要编译 MiracleCast。

## 产物

| 文件 | 大小 | 适用 |
| --- | --- | --- |
| `harmony-mirror_<版本>_amd64.deb` | 约 2.7 MB | Debian / Ubuntu（`apt install` 一条命令，依赖自动拉取） |
| `harmony-mirror-<版本>-linux-x86_64.tar.gz` | 约 3.2 MB | 其它发行版（解压即用，方案 A 开箱可用） |

两者都内含：

- 预编译好的 `miracle-wifid` / `miracle-sinkctl` / `miracle-dhcp` / `miracle-uibcctl` / `miracle-wifictl` 与播放脚本
- 内置 `hdc` 3.2.0c（OpenHarmony 6.1 SDK）
- 全部脚本、文档，以及 Miracast 需要的 D-Bus 策略

## 安装 / 卸载

```bash
# 安装（依赖由 apt 自动解决）
sudo apt install ./harmony-mirror_1.0.0_amd64.deb

# 三个入口
harmony-mirror-doctor       # 环境体检
harmony-mirror              # 方案 A：hdc 投屏 + 控制
harmony-mirror-miracast     # 方案 B：Miracast 无线投屏

# 卸载
sudo apt remove harmony-mirror
```

安装后的布局：

```
/usr/lib/harmony-mirror/{scripts,bin,vendor}   程序与内置二进制
/usr/bin/harmony-mirror*                       → 指向上面脚本的软链
/etc/dbus-1/system.d/org.freedesktop.miracle.conf   Miracast 必需的 D-Bus 策略
/usr/share/doc/harmony-mirror/                 README、LICENSE、来源说明
```

> 脚本内部用 `readlink -f` 解析自身路径，所以通过 `/usr/bin` 软链调用也能正确定位资源。
> 系统安装时日志与状态会写到 `~/.cache/harmony-mirror/`（`/usr/lib` 普通用户不可写）。

## 自己构建

```bash
./install.sh                 # 先编译一次 MiracleCast（需要 sudo 装编译依赖）
./packaging/build-deb.sh     # 产出 dist/*.deb 与 dist/*.tar.gz
VERSION=1.1.0 ./packaging/build-deb.sh   # 指定版本号
```

打包脚本做四件事：

1. **反查依赖**：用 `ldd` + `dpkg -S` 从预编译程序的真实动态库推出 Ubuntu 包名
   （`libglib2.0-0t64 | libglib2.0-0` 这类跨版本回退会自动加上），写进 `Depends`
2. 摆好文件树，把 D-Bus 策略同时放进 `/etc`（随包安装）
3. 权限规范成 Debian 惯例（目录 755 / 文件 644 / 可执行 755）
4. `fakeroot dpkg-deb --build --root-owner-group` 打出 `.deb`，并顺带打一个便携 tarball

## 为什么不把 GStreamer 也内置？

播放是 GStreamer 在**运行时**动态加载插件（`tsdemux`、`avdec_h264`、`avdec_aac` …），
这些 `.so` 又牵连 `libavcodec` 等一整套库。要真内置得连 GStreamer 本体一起打包，
体积会涨到几百 MB 且极易出问题。

所以 `.deb` 选择把 `gstreamer1.0-plugins-bad`、`gstreamer1.0-libav` 等写进 `Depends`，
由 apt 拉取——**依然零编译**，只是会下载约 40 MB 依赖。

## 兼容性说明（重要）

预编译的 C 程序是**动态链接**的：

```
libc6 · libglib2.0-0 · libsystemd0 · libudev1 · libreadline8
```

- 同发行版、同等或更新的版本 → 直接可用（本包在 **Ubuntu 26.04 / glibc 2.43** 上构建）
- 更老的系统（glibc 更旧）→ 可能报 `GLIBC_x.xx not found`，此时请**从源码构建**
  （`./install.sh`），或使用对应发行版的 CI 产物
- 其它架构（arm64）→ 需在对应架构上重新构建

想扩充分发范围，最省事的办法是在 **CI 里构建**：`.github/workflows/build-deb.yml`
会在打 tag 时自动构建并上传到 Release（在较老的 runner 上构建，产物兼容性反而更好）。

## 发布到 GitHub Releases

```bash
# 打 tag 触发 CI（若启用了 workflow）
git tag v1.0.0 && git push origin v1.0.0
```

或手动发布：

```bash
# 需要 gh CLI（sudo apt install gh && gh auth login）
gh release create v1.0.0 dist/harmony-mirror_1.0.0_amd64.deb \
    dist/harmony-mirror-1.0.0-linux-x86_64.tar.gz \
    --title "v1.0.0" --notes "首个版本：hdc 投屏 + Miracast 接收端"
```

也可以在网页上：**Releases → Draft a new release → 选择 tag → 把 `dist/` 里两个文件拖进附件区**。

## 验证包内容（不安装也能检查）

```bash
dpkg-deb -I dist/harmony-mirror_1.0.0_amd64.deb     # 看 control（依赖、大小）
dpkg-deb -c dist/harmony-mirror_1.0.0_amd64.deb     # 看文件清单与权限
dpkg-deb -x dist/harmony-mirror_1.0.0_amd64.deb /tmp/x   # 解到目录，可直接跑
/tmp/x/usr/lib/harmony-mirror/scripts/run-miracast-sink.sh --check
```
