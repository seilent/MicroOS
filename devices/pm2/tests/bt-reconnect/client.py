#!/usr/bin/env python3
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

NAME = "net.seilent.MicroOs.Reconnect"
PATH = "/net/seilent/MicroOs/Reconnect"
IFACE = "net.seilent.MicroOs.Reconnect1"
SIGS = {"SetRole": "s", "SetTarget": "o", "Hold": "b", "Scope": "b", "Want": ""}


def body(method, arg):
    t = SIGS[method]
    if not t:
        return None
    return GLib.Variant(f"({t})", ((arg == "true") if t == "b" else arg,))


def call(bus, method, arg=None):
    try:
        bus.call_sync(NAME, PATH, IFACE, method, body(method, arg), None, Gio.DBusCallFlags.NONE, 5000, None)
        return "ok"
    except GLib.Error as e:
        return Gio.dbus_error_get_remote_error(e) or e.message


def get(bus, prop):
    try:
        reply = bus.call_sync(NAME, PATH, "org.freedesktop.DBus.Properties", "Get", GLib.Variant("(ss)", (IFACE, prop)),
                              GLib.VariantType("(v)"), Gio.DBusCallFlags.NONE, 5000, None)
        return str(reply.unpack()[0])
    except GLib.Error as e:
        return Gio.dbus_error_get_remote_error(e) or e.message


def has_owner(bus, name):
    return bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                         GLib.Variant("(s)", (name,)), GLib.VariantType("(b)"), Gio.DBusCallFlags.NONE, 1000,
                         None).unpack()[0]


def main(cmd, *args):
    if cmd == "stub":
        bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        reply = bus.call_sync("net.seilent.Test.Bluez", "/test", "net.seilent.Test.Bluez", "Do",
                              GLib.Variant("(s)", (" ".join(args),)), GLib.VariantType("(s)"), Gio.DBusCallFlags.NONE,
                              5000, None)
        print(reply.unpack()[0])
        return 0
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    if cmd == "call":
        print(call(bus, *args))
        return 0
    if cmd == "get":
        print(get(bus, args[0]))
        return 0
    if cmd == "wait":
        prop, want, end = args[0], args[1], time.monotonic() + float(args[2])
        while time.monotonic() < end:
            if has_owner(bus, NAME) and get(bus, prop) == want:
                return 0
            time.sleep(0.05)
        print(get(bus, prop))
        return 1
    if cmd == "wait-name":
        end = time.monotonic() + float(args[0])
        while time.monotonic() < end:
            if has_owner(bus, NAME):
                return 0
            time.sleep(0.05)
        return 1
    if cmd == "own":
        reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                              GLib.Variant("(su)", (NAME, 4)), GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 1000,
                              None)
        print("owned" if reply.unpack()[0] == 1 else "not owned", flush=True)
        sys.stdin.read()
        return 0
    if cmd == "holder":
        print(bus.get_unique_name(), flush=True)
        for line in sys.stdin:
            words = line.split()
            print(call(bus, *words), flush=True)
        return 0
    if cmd == "gone":
        msg = Gio.DBusMessage.new_method_call(NAME, PATH, IFACE, args[0])
        msg.set_body(body(args[0], args[1]))
        msg.set_flags(Gio.DBusMessageFlags.NO_REPLY_EXPECTED)
        bus.send_message(msg, Gio.DBusSendMessageFlags.NONE)
        bus.flush_sync(None)
        print(bus.get_unique_name())
        bus.close_sync(None)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
