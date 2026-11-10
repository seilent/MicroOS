#!/usr/bin/env python3
import errno
import importlib.machinery
import importlib.util
import os
import sys

tree, tmp = sys.argv[1:3]
loader = importlib.machinery.SourceFileLoader("hotkeyd", os.path.join(tree, "usr/libexec/microos/microos-hotkeyd"))
h = importlib.util.module_from_spec(importlib.util.spec_from_loader("hotkeyd", loader))
loader.exec_module(h)
logs = []
h.log = logs.append
failed = False


def fail(msg):
    global failed
    failed = True
    print(f"FAIL: {msg}", file=sys.stderr)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


if h.EVIOCGRAB != (1 << 30) | (4 << 16) | (ord("E") << 8) | 0x90:
    fail(f"EVIOCGRAB {h.EVIOCGRAB:#x}")
if h.EVIOCGKEY != (2 << 30) | ((0x2ff + 1) // 8 << 16) | (ord("E") << 8) | 0x18:
    fail(f"EVIOCGKEY {h.EVIOCGKEY:#x}")

h.TABLES = os.path.join(tree, "usr/lib/microos/hotkeys.d")
steam = {
    ("power", "tap"): ("steam-uri", "steam://shortpowerpress"), ("guide", "hold"): ("session-menu",),
    ("power", "hold"): ("steam-uri", "steam://longpowerpress"),
}
if h.load_table("steam") != steam or h.table_grabs("steam"):
    fail(f"steam table: {h.load_table('steam')} grab {h.table_grabs('steam')}")
android = {
    ("power", "tap"): ("suspend",), ("guide", "hold"): ("session-menu",),
    ("volup", "press"): ("volume", "up"), ("voldown", "press"): ("volume", "down"),
    ("power", "hold"): ("session-menu",),
}
if h.load_table("android") != android or not h.table_grabs("android"):
    fail(f"android table: {h.load_table('android')} grab {h.table_grabs('android')}")
if logs:
    fail(f"steam or android table logged: {logs}")

h.TABLES = os.path.join(tmp, "tables")
write(f"{h.TABLES}/a.conf", "grab\ngrab now\nvolup press volume up\n")
write(f"{h.TABLES}/a.conf.d/10-x.conf", "grab\n")
write(f"{h.TABLES}/b.conf", "volup press volume up\n")
write(f"{h.TABLES}/b.conf.d/10-x.conf", "grab\n")
logs.clear()
table = h.load_table("a")
if table != {("power", "tap"): ("suspend",), ("guide", "hold"): ("session-menu",), ("volup", "press"): ("volume", "up")}:
    fail(f"a table with grab: {table}")
if logs != [f"{h.TABLES}/a.conf:2: ignored: grab now", f"{h.TABLES}/a.conf.d/10-x.conf:1: ignored: grab"]:
    fail(f"grab with words or in a drop in: {logs}")
if not h.table_grabs("a") or h.table_grabs("b") or h.table_grabs("none"):
    fail(f"table_grabs a {h.table_grabs('a')} b {h.table_grabs('b')} none {h.table_grabs('none')}")

h.INPUT = os.path.join(tmp, "input")
h.TABLES = os.path.join(tree, "usr/lib/microos/hotkeys.d")
node = f"{h.INPUT}/event3/node"
write(f"{h.INPUT}/event3/device/name", "gpio-keys\n")
os.mkfifo(node)
write(f"{node}.keys", "")


def busy(_path, _fd, _on):
    raise OSError(errno.EBUSY, os.strerror(errno.EBUSY))


h.grab = busy
d = h.Hotkeyd("android", None, None)
if d.grabs != {"InputPlumber Keyboard", "gpio-keys", "pm8941_resin"}:
    fail(f"android grabs: {d.grabs}")
logs.clear()
d.reopen()
d.take_grab(node)
d.close_node(node, "closed")
d.reopen()
errs = [m for m in logs if m.startswith(f"cannot grab {node}: ")]
if len(errs) != 2:
    fail(f"EVIOCGRAB OSError not logged once per open: {logs}")
if node in d.pending_grab or any(m.startswith("grabbed ") for m in logs):
    fail(f"a refused grab: pending {d.pending_grab} {logs}")

sys.exit(1 if failed else 0)
