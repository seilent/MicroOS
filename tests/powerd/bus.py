#!/usr/bin/env python3
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

NAME = "net.seilent.MicroOs.Power"
PATH = "/net/seilent/MicroOs/Power"
PROPS = "org.freedesktop.DBus.Properties"
POWER = "net.seilent.MicroOs.Power1"


def call(bus, iface, method, args, reply=None):
    return bus.call_sync(NAME, PATH, iface, method, args, GLib.VariantType(reply) if reply else None,
                         Gio.DBusCallFlags.NONE, 5000, None)


def main(cmd, *args):
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    if cmd == "wait-name":
        end = time.monotonic() + float(args[0])
        while time.monotonic() < end:
            owner = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                                  "NameHasOwner", GLib.Variant("(s)", (NAME,)), GLib.VariantType("(b)"),
                                  Gio.DBusCallFlags.NONE, 1000, None)
            if owner.unpack()[0]:
                return 0
            time.sleep(0.05)
        return 1
    if cmd == "get":
        try:
            print(call(bus, PROPS, "Get", GLib.Variant("(ss)", args), "(v)").unpack()[0])
        except GLib.Error as e:
            print(Gio.dbus_error_get_remote_error(e))
            return 1
        return 0
    if cmd == "set":
        iface, prop, t, value = args
        v = {"u": int, "t": int, "b": lambda x: x == "true"}.get(t, str)(value)
        try:
            call(bus, PROPS, "Set", GLib.Variant("(ssv)", (iface, prop, GLib.Variant(t, v))))
        except GLib.Error as e:
            print(Gio.dbus_error_get_remote_error(e))
            return 1
        return 0
    if cmd == "calls":
        for a in args:
            if a == "holds":
                print(call(bus, PROPS, "Get", GLib.Variant("(ss)", (POWER, "Holds")), "(v)").unpack()[0])
                continue
            method, _, mode = a.partition(":")
            try:
                call(bus, POWER, method, GLib.Variant("(s)", (mode,)))
                print("ok")
            except GLib.Error as e:
                print(Gio.dbus_error_get_remote_error(e))
        return 0
    if cmd == "request":
        try:
            call(bus, POWER, "RequestUndervolt", GLib.Variant("(uss)", (int(args[0]), args[1], args[2])))
        except GLib.Error as e:
            print(Gio.dbus_error_get_remote_error(e))
            return 1
        return 0
    if cmd == "holder":
        for line in sys.stdin:
            method, _, mode = line.strip().partition(":")
            try:
                call(bus, POWER, method, GLib.Variant("(s)", (mode,)))
                print("ok", flush=True)
            except GLib.Error as e:
                print(Gio.dbus_error_get_remote_error(e), flush=True)
        return 0
    if cmd == "hold-gone":
        msg = Gio.DBusMessage.new_method_call(NAME, PATH, POWER, "Hold")
        msg.set_body(GLib.Variant("(s)", (args[0],)))
        msg.set_flags(Gio.DBusMessageFlags.NO_REPLY_EXPECTED)
        bus.send_message(msg, Gio.DBusSendMessageFlags.NONE)
        bus.flush_sync(None)
        bus.close_sync(None)
        return 0
    if cmd == "interfaces":
        xml = call(bus, "org.freedesktop.DBus.Introspectable", "Introspect", None, "(s)").unpack()[0]
        for i in Gio.DBusNodeInfo.new_for_xml(xml).interfaces:
            print(i.name)
        return 0
    if cmd == "monitor":
        out = open(args[0], "a", buffering=1)

        def changed(conn, sender, path, iface, signal, params):
            name, props, _ = params.unpack()
            for k, v in sorted(props.items()):
                out.write(f"{name} {k}={v}\n")

        def done(conn, sender, path, iface, signal, params):
            out.write("UndervoltRequestDone " + " ".join(str(v) for v in params.unpack()) + "\n")

        bus.signal_subscribe(NAME, PROPS, "PropertiesChanged", PATH, None, Gio.DBusSignalFlags.NONE, changed)
        bus.signal_subscribe(NAME, POWER, "UndervoltRequestDone", PATH, None, Gio.DBusSignalFlags.NONE, done)
        bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetId", None, None,
                      Gio.DBusCallFlags.NONE, 1000, None)
        out.write("ready\n")
        GLib.MainLoop().run()
    if cmd == "sleep":
        reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                              "RequestName", GLib.Variant("(su)", ("org.freedesktop.login1", 4)),
                              GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 1000, None)
        if reply.unpack()[0] != 1:
            return 1
        bus.emit_signal(None, "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "PrepareForSleep",
                        GLib.Variant("(b)", (args[0] == "true",)))
        bus.flush_sync(None)
        return 0
    if cmd == "systemd":
        states, units = {}, {}
        manager = Gio.DBusNodeInfo.new_for_xml(
            '<node><interface name="org.freedesktop.systemd1.Manager"><method name="Subscribe"/>'
            '<method name="GetUnit"><arg name="name" type="s" direction="in"/>'
            '<arg name="unit" type="o" direction="out"/></method></interface></node>').interfaces[0]
        unit = Gio.DBusNodeInfo.new_for_xml(
            '<node><interface name="org.freedesktop.systemd1.Unit">'
            '<property name="ActiveState" type="s" access="read"/></interface></node>').interfaces[0]

        def on_unit(conn, sender, path, iface, method, params, inv):
            inv.return_value(GLib.Variant("(v)", (GLib.Variant("s", states.get(units[path], "active")),)))

        def on_manager(conn, sender, path, iface, method, params, inv):
            if method == "Subscribe":
                print("Subscribe", flush=True)
                inv.return_value(None)
                return
            name = params.unpack()[0]
            path = "/org/freedesktop/systemd1/unit/" + "".join(c if c.isalnum() else f"_{ord(c):02x}" for c in name)
            if path not in units:
                units[path] = name
                bus.register_object(path, unit, on_unit, None, None)
            inv.return_value(GLib.Variant("(o)", (path,)))

        bus.register_object("/org/freedesktop/systemd1", manager, on_manager, None, None)
        reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                              "RequestName", GLib.Variant("(su)", ("org.freedesktop.systemd1", 4)),
                              GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 1000, None)
        if reply.unpack()[0] != 1:
            return 1

        def on_line(fd, cond):
            line = sys.stdin.readline()
            if not line:
                loop.quit()
                return False
            what, name, value = line.split()
            if what == "state":
                states[name] = value
            else:
                bus.emit_signal(None, "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager", "JobRemoved",
                                GLib.Variant("(uoss)", (1, "/org/freedesktop/systemd1/job/1", name, value)))
                bus.flush_sync(None)
            print("ok", flush=True)
            return True

        loop = GLib.MainLoop()
        GLib.io_add_watch(sys.stdin.fileno(), GLib.PRIORITY_DEFAULT, GLib.IOCondition.IN | GLib.IOCondition.HUP, on_line)
        print("ready", flush=True)
        loop.run()
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
