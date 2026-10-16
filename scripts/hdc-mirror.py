#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
hdc_mirror.py —— 鸿蒙（HarmonyOS NEXT）手机投屏 + 反向控制

为什么不是 scrcpy：
    纯血鸿蒙（HarmonyOS 5/6）没有 Android 运行时，scrcpy 依赖的
    adb + scrcpy-server.jar 需要 app_process / ART 虚拟机，鸿蒙上并不存在，
    因此 scrcpy 无法用于鸿蒙手机。鸿蒙对应的官方调试桥是 hdc。

本工具直接基于 hdc 实现"投屏 + 控制"，免 root、不改系统分区：
    抓屏   : hdc shell snapshot_display -i 0 -t jpeg -f <设备文件>  +  hdc file recv
    点按   : hdc shell uitest uiInput click|doubleClick|longClick <x> <y>
    滑动   : hdc shell uitest uiInput swipe <x1> <y1> <x2> <y2> [速度]
    滚动   : hdc shell uitest uiInput dircFling <0左|1右|2上|3下> [速度]
    按键   : hdc shell uitest uiInput keyEvent Back|Home|Power
    文本   : hdc shell uitest uiInput text '<内容>'

    为提升帧率，抓屏采用多路并行（实测单路约 2.4fps，4 路可达 8fps+），
    每个抓屏线程写入设备上各自独立的文件，互不阻塞。

用法：
    ./start-hdc-mirror.sh                       # 推荐：自动找设备/复用上次无线地址
    python3 hdc-mirror.py                       # 使用当前已连接的 hdc 设备
    python3 hdc-mirror.py 192.168.1.100:37000   # 先 hdc tconn 再投屏（无线）
    python3 hdc-mirror.py --quality low --parallel 6
    python3 hdc-mirror.py --selftest --frames 12   # 只测帧率，不开窗口

详见 ../docs/02-hdc-mirror.md。

界面操作：
    左键单击        点按
    左键拖动        滑动
    左键双击        双击
    滚轮            上/下滚动
    右键            菜单（返回 / 主页 / 电源 / 输入文本 / 保存截图 / 画质 / 置顶）
    直接敲键盘      向手机输入文本（手机上是输入框且已获得焦点时生效）
    Esc             返回键
    Home            主页键
    Ctrl+S          保存当前画面
"""

import argparse
import io
import os
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import tkinter as tk

try:
    from PIL import Image, ImageTk
except ImportError:  # pragma: no cover
    sys.stderr.write("需要 Pillow：pip3 install pillow\n")
    raise

# 注意：鸿蒙 snapshot_display 在 type=jpeg 时要求文件名后缀必须是 .jpeg
REMOTE_FRAME_FMT = "/data/local/tmp/.hdc_mirror_%d.jpeg"

QUALITY_SCALE = {
    "high": 1.0,    # 原生分辨率，最清晰（实测并行抓取下并不比缩放慢）
    "medium": 0.7,  # 折中
    "low": 0.5,     # 数据量最小，无线带宽紧张时可用
}


def find_hdc():
    """定位 hdc 可执行文件（优先项目内置的，其次环境变量与系统 PATH）。"""
    here = os.path.dirname(os.path.realpath(__file__))   # realpath: 兼容软链调用
    root = os.environ.get("HARMONY_MIRROR_ROOT") or os.path.dirname(here)
    cands = [
        os.environ.get("HDC_BIN"),
        os.path.join(root, "vendor", "openharmony-toolchains", "hdc"),
        os.path.join(here, "hdc"),
        os.path.expanduser("~/.local/bin/hdc"),
        "/usr/local/bin/hdc",
        shutil.which("hdc"),
    ]
    for c in cands:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    raise SystemExit(
        "找不到 hdc。\n"
        "  本项目自带 vendor/openharmony-toolchains/hdc，若被删除可执行 scripts/setup-hdc.sh 重新获取，\n"
        "  或用环境变量指定：HDC_BIN=/path/to/hdc python3 hdc-mirror.py"
    )


def sh_quote(s):
    """把文本包成单引号 shell 字面量（供设备端 shell 使用）。"""
    return "'" + str(s).replace("'", "'\\''") + "'"


class HdcMirror:
    def __init__(self, hdc, target=None, quality="high", parallel=4,
                 device=None, max_box=1000):
        self.hdc = hdc
        self.target = target
        self.device = device
        self.parallel = max(1, int(parallel))
        self.max_box = (max_box, max_box)
        self.device_name = target or "USB"
        self.quality = quality
        self.scale = QUALITY_SCALE.get(quality, 1.0)

        self.native_w = 0
        self.native_h = 0
        self.frame_w = 0
        self.frame_h = 0

        self._stop = threading.Event()
        self._latest = None
        self._latest_lock = threading.Lock()
        self._cmd_q = queue.Queue()
        self._stamps = []
        self._fps = 0.0
        self._frames = 0
        self._last_error = ""
        self._tmpdir = tempfile.mkdtemp(prefix="hdc_mirror_")
        self._fail_streak = 0

    # ---------------- hdc 基础调用 ----------------

    def _base(self):
        cmd = [self.hdc]
        if self.device:
            cmd += ["-t", self.device]
        return cmd

    def shell(self, command, timeout=20):
        return subprocess.run(self._base() + ["shell", command],
                              capture_output=True, text=True, timeout=timeout)

    def connect(self):
        """建立连接：给了 ip:port 就走 tconn，否则用 USB。"""
        if self.target:
            r = self.shell("true", timeout=15)
            if r.returncode != 0:
                r = subprocess.run(self._base() + ["tconn", self.target],
                                   capture_output=True, text=True, timeout=25)
                out = (r.stdout or "") + (r.stderr or "")
                if "Connect OK" not in out and "connected" not in out.lower():
                    sys.stderr.write("hdc tconn 输出：%s\n" % out.strip())
        r = subprocess.run(self._base() + ["list", "targets"],
                           capture_output=True, text=True, timeout=20)
        # 注意：没有设备时 hdc 会打印 "[Empty]"，不能当成设备行
        lines = [l for l in (r.stdout or "").splitlines()
                 if l.strip() and "[Empty]" not in l]
        if not lines:
            raise SystemExit(
                "没有可用的 hdc 设备。请检查：\n"
                "  1) 手机已开启「USB调试」并点了「允许」\n"
                "  2) 无线调试的话端口是否变了（手机上重新查看）\n"
                "  然后重试： hdc tconn <IP:端口>")
        if "Unauthorized" in lines[0]:
            raise SystemExit("设备未授权：请在手机弹出的提示中点击「允许」。")
        return lines[0]

    def reconnect(self):
        """抓屏持续失败时尝试重新 tconn。"""
        if not self.target:
            return
        try:
            subprocess.run(self._base() + ["tconn", self.target],
                           capture_output=True, text=True, timeout=20)
        except Exception:
            pass

    def detect_native_size(self):
        try:
            r = self.shell("hidumper -s RenderService -a screen", timeout=15)
            m = re.search(r"render resolution=(\d+)x(\d+)", r.stdout or "")
            if m:
                self.native_w, self.native_h = int(m.group(1)), int(m.group(2))
                return
        except Exception:
            pass
        self.shell("snapshot_display -i 0 -t jpeg -f " + (REMOTE_FRAME_FMT % 99),
                   timeout=20)
        local = os.path.join(self._tmpdir, "probe.jpeg")
        subprocess.run(self._base() + ["file", "recv", REMOTE_FRAME_FMT % 99, local],
                       capture_output=True, timeout=20)
        try:
            with Image.open(local) as im:
                self.native_w, self.native_h = im.size
        except Exception:
            self.native_w, self.native_h = 1224, 2776
            sys.stderr.write("警告：无法读取屏幕分辨率，暂用 1224x2776 兜底\n")

    def _capture_size(self):
        """当前画质档位对应的设备端抓取尺寸（宽高取偶数，避免编码告警）。"""
        w = max(2, int(self.native_w * self.scale) // 2 * 2)
        h = max(2, int(self.native_h * self.scale) // 2 * 2)
        return w, h

    def set_quality(self, quality):
        self.quality = quality
        self.scale = QUALITY_SCALE.get(quality, 1.0)
        self.frame_w = self.frame_h = 0

    # ---------------- 抓屏 ----------------

    def start(self):
        self.connect()
        self.detect_native_size()
        self.frame_w, self.frame_h = self._capture_size()
        for i in range(self.parallel):
            threading.Thread(target=self._slot_worker, args=(i,), daemon=True).start()
        threading.Thread(target=self._input_loop, daemon=True).start()

    def stop(self):
        self._stop.set()
        try:
            self._cmd_q.put_nowait(None)
        except Exception:
            pass

    def _slot_worker(self, slot):
        """一路抓屏 + 取回 + 解码 + 缩放，多路并行提升帧率。"""
        remote = REMOTE_FRAME_FMT % slot
        local = os.path.join(self._tmpdir, "frame_%d.jpeg" % slot)
        while not self._stop.is_set():
            if self.frame_w == 0:
                self.frame_w, self.frame_h = self._capture_size()
            cmd = ("snapshot_display -i 0 -w %d -h %d -t jpeg -f %s"
                   % (self.frame_w, self.frame_h, remote))
            try:
                r = self.shell(cmd, timeout=20)
            except Exception as e:
                self._last_error = "hdc shell 异常: %s" % e
                time.sleep(0.3)
                continue
            out = (r.stdout or "") + (r.stderr or "")
            if "error" in out.lower():
                self._last_error = out.strip().splitlines()[-1][:120]
                self._fail_streak += 1
                if self._fail_streak in (5, 15, 30):
                    self.reconnect()
                time.sleep(0.3)
                continue
            try:
                subprocess.run(self._base() + ["file", "recv", remote, local],
                               capture_output=True, timeout=20)
                with open(local, "rb") as f:
                    data = f.read()
                img = Image.open(io.BytesIO(data))
                img.load()
            except Exception as e:
                self._last_error = "取回/解码失败: %s" % e
                time.sleep(0.2)
                continue
            # 在抓屏线程里完成缩放，GUI 线程只负责贴图
            if img.height > self.max_box[1] or img.width > self.max_box[0]:
                img.thumbnail(self.max_box, Image.BILINEAR)
            self._fail_streak = 0
            self._last_error = ""
            self._publish(img)

    def _publish(self, img):
        now = time.time()
        with self._latest_lock:
            self._latest = img
            self._frames += 1
            self._stamps.append(now)
            if len(self._stamps) > 40:
                self._stamps = self._stamps[-40:]
            fresh = [t for t in self._stamps if now - t <= 2.0]
            self._fps = len(fresh) / 2.0 if fresh else 0.0

    def latest(self):
        with self._latest_lock:
            return self._latest, self._frames

    @property
    def fps(self):
        return self._fps

    @property
    def last_error(self):
        return self._last_error

    # ---------------- 输入注入 ----------------

    def enqueue(self, command):
        self._cmd_q.put(command)

    def _input_loop(self):
        while not self._stop.is_set():
            try:
                cmd = self._cmd_q.get(timeout=0.5)
            except queue.Empty:
                continue
            if cmd is None:
                break
            try:
                self.shell(cmd, timeout=15)
            except Exception:
                pass

    def to_device(self, x, y, disp_w, disp_h):
        if not disp_w or not disp_h:
            return 0, 0
        return int(x * self.native_w / float(disp_w)), int(y * self.native_h / float(disp_h))

    def tap(self, x, y):
        self.enqueue("uitest uiInput click %d %d" % (x, y))

    def double_tap(self, x, y):
        self.enqueue("uitest uiInput doubleClick %d %d" % (x, y))

    def long_press(self, x, y):
        self.enqueue("uitest uiInput longClick %d %d" % (x, y))

    def swipe(self, x1, y1, x2, y2, velocity=1200):
        self.enqueue("uitest uiInput swipe %d %d %d %d %d" % (x1, y1, x2, y2, velocity))

    def fling(self, direction):
        self.enqueue("uitest uiInput dircFling %d 600" % direction)

    def key(self, name):
        self.enqueue("uitest uiInput keyEvent %s" % name)

    def send_text(self, text):
        if text:
            self.enqueue("uitest uiInput text %s" % sh_quote(text))


# ---------------------------------------------------------------- GUI

class MirrorWindow:
    STATUS_H = 26

    def __init__(self, root, mirror):
        self.root = root
        self.mirror = mirror
        self.photo = None
        self.disp_w = 0
        self.disp_h = 0
        self.press_xy = None
        self.moved = False
        self._typing = ""
        self._typing_job = None
        self._rendered = 0
        self._last_frames = -1
        self._top = False
        self._notice = ""
        self._notice_until = 0.0

        root.title("鸿蒙投屏 (hdc) —— %s" % mirror.device_name)
        root.configure(bg="#0d0d0d")
        root.bind("<Escape>", lambda e: mirror.key("Back"))
        root.bind("<Home>", lambda e: mirror.key("Home"))
        root.bind("<Control-s>", lambda e: self.save_frame())
        root.bind("<Key>", self.on_key)

        # 状态栏直接画在画布上（不用 Label），这样窗口尺寸完全由画面决定
        self.canvas = tk.Canvas(root, bg="#0d0d0d", highlightthickness=0,
                                width=440, height=966)
        self.canvas.pack()
        root.geometry("440x966")

        self.canvas.bind("<Button-1>", self.on_press)
        self.canvas.bind("<B1-Motion>", self.on_motion)
        self.canvas.bind("<ButtonRelease-1>", self.on_release)
        self.canvas.bind("<Button-3>", self.on_menu)
        self.canvas.bind("<Button-4>", lambda e: mirror.fling(3))
        self.canvas.bind("<Button-5>", lambda e: mirror.fling(2))
        self.canvas.bind("<MouseWheel>", lambda e: mirror.fling(3 if e.delta > 0 else 2))

        self.menu = tk.Menu(root, tearoff=0)
        self.menu.add_command(label="返回 / Back", command=lambda: mirror.key("Back"))
        self.menu.add_command(label="主页 / Home", command=lambda: mirror.key("Home"))
        self.menu.add_command(label="电源键 / Power", command=lambda: mirror.key("Power"))
        self.menu.add_separator()
        self.menu.add_command(label="长按屏幕中心", command=self.long_press_center)
        self.menu.add_command(label="输入文本…", command=self.ask_text)
        self.menu.add_command(label="保存当前画面 (Ctrl+S)", command=self.save_frame)
        self.menu.add_separator()
        q = tk.Menu(self.menu, tearoff=0)
        for label, key in (("高清（默认）", "high"), ("均衡", "medium"), ("流畅/省流量", "low")):
            q.add_command(label=label, command=lambda k=key: mirror.set_quality(k))
        self.menu.add_cascade(label="画质", menu=q)
        self.menu.add_checkbutton(label="窗口置顶", command=self.toggle_top)
        self.menu.add_separator()
        self.menu.add_command(label="退出", command=self.quit)

        root.protocol("WM_DELETE_WINDOW", self.quit)
        root.after(20, self.tick)

    # -------- 画面刷新 --------
    def tick(self):
        img, frames = self.mirror.latest()
        if img is not None and frames != self._last_frames:
            self._last_frames = frames
            w, h = img.size
            if (w, h) != (self.disp_w, self.disp_h):
                self.disp_w, self.disp_h = w, h
                self.canvas.config(width=w, height=h + self.STATUS_H)
                self.root.geometry("%dx%d" % (w, h + self.STATUS_H))
            self.photo = ImageTk.PhotoImage(img)
            self.canvas.delete("all")
            self.canvas.create_image(0, 0, anchor="nw", image=self.photo)
            self._rendered += 1
            if self._rendered % 30 == 1:
                print("[mirror] 已渲染 %d 帧，%.1f fps，画面 %dx%d，画质 %s"
                      % (self._rendered, self.mirror.fps, self.disp_w, self.disp_h,
                         self.mirror.quality), flush=True)
        txt = ("%s  %dx%d  %.1f fps  %s  %s"
               % (self.mirror.device_name, self.mirror.native_w,
                  self.mirror.native_h, self.mirror.fps,
                  self.mirror.quality, ("⚠ " + self.mirror.last_error)
                  if self.mirror.last_error else ""))
        if self._notice and time.time() < self._notice_until:
            txt = self._notice
        if self.disp_w:
            self.canvas.delete("status")
            self.canvas.create_text(
                6, self.disp_h + self.STATUS_H // 2, anchor="w",
                text=txt[:60], fill="#cfcfcf", font=("monospace", 9),
                tags="status")
        self.root.after(20, self.tick)

    # -------- 鼠标 --------
    def on_press(self, event):
        self.press_xy = (event.x, event.y)
        self.moved = False

    def on_motion(self, event):
        if self.press_xy and (abs(event.x - self.press_xy[0]) > 12
                              or abs(event.y - self.press_xy[1]) > 12):
            self.moved = True

    def on_release(self, event):
        if self.press_xy is None:
            return
        x1, y1 = self.press_xy
        self.press_xy = None
        if self.moved:
            dx1, dy1 = self.mirror.to_device(x1, y1, self.disp_w, self.disp_h)
            dx2, dy2 = self.mirror.to_device(event.x, event.y, self.disp_w, self.disp_h)
            self.mirror.swipe(dx1, dy1, dx2, dy2)
        else:
            dx, dy = self.mirror.to_device(event.x, event.y, self.disp_w, self.disp_h)
            self.mirror.tap(dx, dy)

    def on_menu(self, event):
        try:
            self.menu.tk_popup(event.x_root, event.y_root)
        finally:
            self.menu.grab_release()

    # -------- 键盘 --------
    def on_key(self, event):
        if event.keysym in ("Escape", "Home", "Control_L", "Control_R",
                            "Shift_L", "Shift_R", "Alt_L", "Alt_R"):
            return
        ch = event.char
        if not ch or not ch.isprintable():
            return
        self._typing += ch
        if self._typing_job:
            self.root.after_cancel(self._typing_job)
        self._typing_job = self.root.after(300, self.flush_typing)

    def flush_typing(self):
        self._typing_job = None
        text, self._typing = self._typing, ""
        self.mirror.send_text(text)

    # -------- 菜单动作 --------
    def long_press_center(self):
        self.mirror.long_press(self.mirror.native_w // 2, self.mirror.native_h // 2)

    def ask_text(self):
        dlg = tk.Toplevel(self.root)
        dlg.title("向手机输入文本")
        dlg.geometry("380x110")
        tk.Label(dlg, text="文本（请先在手机上点中输入框）:").pack(padx=10, pady=(10, 4), anchor="w")
        entry = tk.Entry(dlg, width=46)
        entry.pack(padx=10)
        entry.focus_set()
        tk.Button(dlg, text="发送",
                  command=lambda: (self.mirror.send_text(entry.get()), dlg.destroy())
                  ).pack(pady=8)
        entry.bind("<Return>", lambda e: (self.mirror.send_text(entry.get()), dlg.destroy()))

    def save_frame(self):
        img, _ = self.mirror.latest()
        if img is None:
            return
        d = os.path.join(os.path.expanduser("~"), "Pictures")
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, "harmony_%s.jpeg" % time.strftime("%Y%m%d_%H%M%S"))
        img.save(path, quality=92)
        self._notice = "已保存: %s" % path
        self._notice_until = time.time() + 6
        print("[mirror] 截图已保存: %s" % path, flush=True)

    def toggle_top(self):
        self._top = not self._top
        self.root.attributes("-topmost", self._top)

    def quit(self):
        self.mirror.stop()
        self.root.destroy()


# ---------------------------------------------------------------- selftest

def selftest(mirror, frames=12):
    mirror.connect()
    mirror.detect_native_size()
    mirror.frame_w, mirror.frame_h = mirror._capture_size()
    print("设备: %s  原生分辨率: %dx%d  画质: %s  并行: %d"
          % (mirror.device_name, mirror.native_w, mirror.native_h,
             mirror.quality, mirror.parallel))
    mirror._stop.clear()
    for i in range(mirror.parallel):
        threading.Thread(target=mirror._slot_worker, args=(i,), daemon=True).start()
    t0 = time.time()
    while mirror._frames < frames and time.time() - t0 < 60:
        time.sleep(0.05)
    dt = time.time() - t0
    print("抓取 %d 帧，用时 %.2fs，平均 %.2f fps"
          % (mirror._frames, dt, mirror._frames / dt if dt else 0))
    if mirror.last_error:
        print("最后错误: %s" % mirror.last_error)
    mirror.stop()
    return 0 if mirror._frames >= frames else 1


def main():
    ap = argparse.ArgumentParser(description="鸿蒙(HarmonyOS NEXT) 投屏 + 控制（基于 hdc）")
    ap.add_argument("target", nargs="?", default=None,
                    help="无线调试地址 ip:port（可选；USB 连接时省略）")
    ap.add_argument("--quality", choices=list(QUALITY_SCALE), default="high",
                    help="画质档位，默认 high")
    ap.add_argument("--parallel", type=int, default=6,
                    help="并行抓屏路数，默认 6（越大帧率越高，手机负载也越高；8 路可到 ~8.7fps）")
    ap.add_argument("--device", default=None, help="hdc 连接键（多设备时指定）")
    ap.add_argument("--max-size", type=int, default=1000,
                    help="窗口内画面的最大边长（像素），默认 1000")
    ap.add_argument("--selftest", action="store_true", help="只测帧率，不开窗口")
    ap.add_argument("--frames", type=int, default=12, help="selftest 抓取帧数")
    args = ap.parse_args()

    mirror = HdcMirror(find_hdc(), target=args.target, quality=args.quality,
                       parallel=args.parallel, device=args.device,
                       max_box=args.max_size)

    if args.selftest:
        return selftest(mirror, args.frames)

    mirror.connect()
    mirror.detect_native_size()
    try:
        r = mirror.shell("param get const.product.model", timeout=15)
        model = (r.stdout or "").strip().splitlines()[0].strip()
        if model:
            mirror.device_name = "%s%s" % (model, "  " + args.target if args.target else "")
    except Exception:
        pass
    mirror.start()

    root = tk.Tk()
    MirrorWindow(root, mirror)
    try:
        root.mainloop()
    finally:
        mirror.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
