#!/usr/bin/env bash
# ============================================================================
# 打包：生成可直接安装的 .deb（内含预编译好的 MiracleCast，无需编译）
#       以及便携 tarball（非 Debian 系用）
#
#   ./packaging/build-deb.sh
#   VERSION=1.0.1 ./packaging/build-deb.sh
#
# 产物：
#   dist/harmony-mirror_<版本>_amd64.deb          一条命令安装，无编译
#   dist/harmony-mirror-<版本>-linux-x86_64.tar.gz 解压即用（方案 A 开箱可用）
#
# 前置：先跑过 ./install.sh（需要 ~/.local/bin 里已编译好的 miracle-* 程序）
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-1.0.0}"
PKG=harmony-mirror
ARCH=amd64
INSTALL_DIR="/usr/lib/$PKG"
MIRACLE_BIN="${MIRACLE_BIN:-$HOME/.local/bin}"
STAGE="$ROOT/build/pkg/$PKG"
DIST="$ROOT/dist"

c() { printf '\033[1;36m[pack]\033[0m %s\n' "$*"; }
e() { printf '\033[1;31m[pack]\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------- 0. 检查
[ -d "$ROOT/vendor/openharmony-toolchains" ] || { e "缺 vendor/openharmony-toolchains"; exit 1; }
MIRACLE_FILES=(miracle-wifid miracle-sinkctl miracle-dhcp miracle-uibcctl miracle-wifictl miracle-gst gstplayer uibc-viewer)
for f in "${MIRACLE_FILES[@]}"; do
    [ -f "$MIRACLE_BIN/$f" ] || { e "缺 $MIRACLE_BIN/$f —— 请先运行 ./install.sh（编译一次）"; exit 1; }
done
POLICY="$ROOT/vendor/miraclecast/res/org.freedesktop.miracle.conf"
[ -f "$POLICY" ] || { e "缺 $POLICY —— 请先运行 ./install.sh"; exit 1; }

# ---------------------------------------------------------------- 1. 计算运行时依赖
# 从预编译程序的真实动态库反查 Ubuntu 包名（带跨版本回退）
dep_of() {   # $1 = .so 文件名
    local so pkg
    so="$(ldd "$MIRACLE_BIN/miracle-wifid" 2>/dev/null | awk -v n="$1" '$1==n{print $3}')"
    [ -n "$so" ] || return 1
    pkg="$(dpkg -S "$(readlink -f "$so")" 2>/dev/null | cut -d: -f1 | head -1)"
    [ -n "$pkg" ] && printf '%s' "$pkg"
}
libc="$(dep_of libc.so.6 || echo libc6)"
libglib="$(dep_of libglib-2.0.so.0 || echo libglib2.0-0)"
libsystemd="$(dep_of libsystemd.so.0 || echo libsystemd0)"
libudev="$(dep_of libudev.so.1 || echo libudev1)"
libreadline="$(dep_of libreadline.so.8 || echo libreadline8)"

# glib/readline 在较新 Ubuntu 上带了 t64 后缀，加回退保证跨版本可装
[ "$libglib" = "libglib2.0-0" ] && libglib="libglib2.0-0t64 | libglib2.0-0"
[ "$libreadline" = "libreadline8" ] && libreadline="libreadline8t64 | libreadline8"

DEPENDS="python3, python3-tk, python3-pil,
 $libc, $libglib, $libsystemd, $libudev, $libreadline,
 gstreamer1.0-tools, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good,
 gstreamer1.0-plugins-bad, gstreamer1.0-libav"
DEPENDS="$(printf '%s' "$DEPENDS" | tr -d '\n' | sed 's/  */ /g')"

# ---------------------------------------------------------------- 2. 摆文件
c "准备打包目录"
rm -rf "$ROOT/build/pkg"
mkdir -p "$STAGE/DEBIAN" \
         "$STAGE$INSTALL_DIR/scripts" \
         "$STAGE$INSTALL_DIR/bin" \
         "$STAGE$INSTALL_DIR/vendor/openharmony-toolchains" \
         "$STAGE$INSTALL_DIR/vendor/miraclecast/res" \
         "$STAGE/usr/bin" \
         "$STAGE/usr/share/doc/$PKG" \
         "$STAGE/etc/dbus-1/system.d"

cp -a "$ROOT/scripts/."            "$STAGE$INSTALL_DIR/scripts/"
rm -rf "$STAGE$INSTALL_DIR/scripts/__pycache__"
cp -a "$ROOT/vendor/openharmony-toolchains/." "$STAGE$INSTALL_DIR/vendor/openharmony-toolchains/"
cp    "$POLICY"                    "$STAGE$INSTALL_DIR/vendor/miraclecast/res/"
for f in "${MIRACLE_FILES[@]}"; do
    cp "$MIRACLE_BIN/$f" "$STAGE$INSTALL_DIR/bin/$f"
done
cp "$POLICY"                       "$STAGE/etc/dbus-1/system.d/org.freedesktop.miracle.conf"
cp "$ROOT/README.md" "$ROOT/LICENSE" "$STAGE/usr/share/doc/$PKG/"
cp "$ROOT/vendor/openharmony-toolchains/PROVENANCE.md" "$STAGE/usr/share/doc/$PKG/"

# /usr/bin 软链（脚本内部用 readlink -f 解析，所以软链没问题）
ln -sf "$INSTALL_DIR/scripts/start-hdc-mirror.sh"   "$STAGE/usr/bin/harmony-mirror"
ln -sf "$INSTALL_DIR/scripts/run-miracast-sink.sh"  "$STAGE/usr/bin/harmony-mirror-miracast"
ln -sf "$INSTALL_DIR/scripts/doctor.sh"             "$STAGE/usr/bin/harmony-mirror-doctor"
ln -sf "$INSTALL_DIR/scripts/setup-hdc.sh"          "$STAGE/usr/bin/harmony-mirror-setup"

chmod 755 "$STAGE$INSTALL_DIR/bin/"* "$STAGE$INSTALL_DIR/scripts/"*.sh \
          "$STAGE$INSTALL_DIR/scripts/"*.py "$STAGE$INSTALL_DIR/vendor/openharmony-toolchains/hdc"


# ---------------------------------------------------------------- 3. control / 脚本
SIZE="$(du -sk "$STAGE" | cut -f1)"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: $ARCH
Maintainer: shizi-dai <shizi-dai@users.noreply.github.com>
Depends: $DEPENDS
Recommends: wmctrl
Section: utils
Priority: optional
Installed-Size: $SIZE
Homepage: https://github.com/shizi-dai/harmony-mirror
Description: Ubuntu/Linux 投屏并控制鸿蒙手机(HarmonyOS NEXT)
 两条互补路线：
  - hdc 抓屏投屏 + 反向控制（零依赖、支持触控、约 2-12fps）
  - Miracast 接收端（1080p/30-60fps、带声音，含预编译 MiracleCast，无需编译）
 内置 hdc 3.2.0c，免 root，不改系统分区。
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
# 让 dbus-daemon 读到新装的 org.freedesktop.miracle 策略
if command -v systemctl >/dev/null 2>&1; then
    systemctl reload dbus 2>/dev/null || systemctl restart dbus 2>/dev/null || true
fi
cat <<'MSG'

harmony-mirror 安装完成，两个入口：
  harmony-mirror-doctor      环境体检（建议先跑）
  harmony-mirror             方案 A：hdc 投屏 + 控制（有触控，无需额外安装）
  harmony-mirror-miracast    方案 B：Miracast 无线投屏（1080p+声音，投屏时电脑会短暂断网）

MSG
exit 0
EOF

cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    command -v systemctl >/dev/null 2>&1 && systemctl reload dbus 2>/dev/null || true
fi
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"

# 权限规范化成 Debian 惯例：目录 755 / 普通文件 644 / 可执行 755
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +
chmod 755 "$STAGE$INSTALL_DIR/bin/"* "$STAGE$INSTALL_DIR/scripts/"*.sh \
          "$STAGE$INSTALL_DIR/scripts/"*.py \
          "$STAGE$INSTALL_DIR/vendor/openharmony-toolchains/hdc" \
          "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"

# ---------------------------------------------------------------- 4. 打 .deb
mkdir -p "$DIST"
DEB="$DIST/${PKG}_${VERSION}_${ARCH}.deb"
c "构建 $DEB"
fakeroot dpkg-deb --build --root-owner-group "$STAGE" "$DEB" >/dev/null
c "完成：$DEB  ($(du -h "$DEB" | cut -f1))"

# ---------------------------------------------------------------- 5. 便携 tarball
TARNAME="${PKG}-${VERSION}-linux-x86_64"
TARROOT="$ROOT/build/tar/$TARNAME"
c "构建便携包 $TARNAME.tar.gz"
rm -rf "$ROOT/build/tar"; mkdir -p "$TARROOT"
cp -a "$STAGE$INSTALL_DIR/." "$TARROOT/"
install -d "$TARROOT/logs" "$TARROOT/state"
cp "$ROOT/README.md" "$ROOT/LICENSE" "$TARROOT/"
cat > "$TARROOT/install-deps.sh" <<'EOF'
#!/usr/bin/env bash
# 便携包专用：只安装「运行时依赖」，不做任何编译。
# 方案 A（hdc 投屏）不需要本脚本；只有方案 B（Miracast）需要。
set -euo pipefail
sudo apt update -qq
sudo apt install -y python3-tk python3-pil wmctrl \
    gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gstreamer1.0-libav
# D-Bus 策略（Miracast 必需）
sudo install -Dm644 vendor/miraclecast/res/org.freedesktop.miracle.conf \
    /etc/dbus-1/system.d/org.freedesktop.miracle.conf
sudo systemctl reload dbus || true
echo "运行时依赖已就绪。体检： ./scripts/doctor.sh"
EOF
chmod 755 "$TARROOT/install-deps.sh"
( cd "$ROOT/build/tar" && tar czf "$DIST/$TARNAME.tar.gz" "$TARNAME" )
c "完成：$DIST/$TARNAME.tar.gz  ($(du -h "$DIST/$TARNAME.tar.gz" | cut -f1))"

# ---------------------------------------------------------------- 6. 摘要
echo
c "依赖声明：$DEPENDS"
echo
ls -la "$DIST" | awk 'NR>1{printf "  %-46s %s\n", $9, $5}'
