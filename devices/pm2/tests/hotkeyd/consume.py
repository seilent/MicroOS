#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import os
import struct
import sys
import tempfile

import gi

gi.require_version("GLib", "2.0")
from gi.repository import GLib

tree = sys.argv[1]
tables = tempfile.mkdtemp()
with open(os.path.join(tables, "m.conf"), "w") as f:
    f.write("guide tap steam-uri steam://t\n")
os.environ["MICROOS_HOTKEYD_TABLES"] = tables
loader = importlib.machinery.SourceFileLoader("hotkeyd", os.path.join(tree, "usr/libexec/microos/microos-hotkeyd"))
h = importlib.util.module_from_spec(importlib.util.spec_from_loader("hotkeyd", loader))
loader.exec_module(h)

EVENT = struct.Struct("llHHi")
ctx = GLib.MainContext.default()
failed = False


def fail(msg):
    global failed
    failed = True
    print(f"FAIL: {msg}", file=sys.stderr)


class Invocation:
    def __init__(self, log):
        self.log = log

    def return_value(self, _value):
        self.log.append("reply")

    def return_dbus_error(self, name, _msg):
        self.log.append(name)


def spin():
    while ctx.pending():
        ctx.iteration(False)


def read(d):
    d.readable(d.fds["p"][1], None, "p")


def daemon():
    d = h.Hotkeyd("m", None, None)
    r, w = os.pipe()
    os.set_blocking(r, False)
    d.fds["p"] = ("InputPlumber Keyboard", r)
    d.bufs["p"] = b""
    d.stack = [":1.1"]
    log = []
    d.fire = lambda key, gesture: log.append(f"fire {key} {gesture}")
    key = d.key
    d.key = lambda k, at, v: (log.append(f"key {k} {v}"), key(k, at, v))
    return d, w, log


def write(w, value):
    os.write(w, EVENT.pack(1, 0, 1, h.E.KEY_F13, value) + EVENT.pack(1, 0, 0, 0, 0))


d, w, log = daemon()
write(w, 1)
write(w, 0)
spin()
if log != []:
    fail(f"events dispatched without a read: {log}")
read(d)
spin()
if log != ["key guide 1", "key guide 0", "fire guide tap"]:
    fail(f"baseline tap: {log}")

d, w, log = daemon()
write(w, 1)
write(w, 0)
d.consume(":1.1", "guide", Invocation(log))
spin()
if log != ["reply", "key guide 1", "key guide 0"]:
    fail(f"queued down and up: {log}")
write(w, 1)
write(w, 0)
read(d)
if log[-3:] != ["key guide 1", "key guide 0", "fire guide tap"]:
    fail(f"press after a consumed one: {log}")

d, w, log = daemon()
write(w, 1)
read(d)
d.consume(":1.1", "guide", Invocation(log))
write(w, 0)
read(d)
spin()
if log != ["key guide 1", "reply", "key guide 0"]:
    fail(f"down read, up queued: {log}")

d, w, log = daemon()
d.consume(":1.1", "guide", Invocation(log))
write(w, 1)
write(w, 0)
read(d)
if log[-1] != "fire guide tap":
    fail(f"consume with the key up and nothing queued: {log}")

d, w, log = daemon()
write(w, 1)
write(w, 0)
d.consume(":1.2", "guide", Invocation(log))
spin()
if log != ["org.freedesktop.DBus.Error.AccessDenied"]:
    fail(f"consume from another name: {log}")
read(d)
if log[-1] != "fire guide tap":
    fail(f"a refused consume marked the press: {log}")

d, w, log = daemon()
d.consume(":1.1", "nokey", Invocation(log))
if log != ["org.freedesktop.DBus.Error.InvalidArgs"]:
    fail(f"consume of an unknown key: {log}")

sys.exit(1 if failed else 0)
