#!/usr/bin/env python3
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

BLUEZ = "org.bluez"
CONTROL = "net.seilent.Test.Bluez"
LOGIN = "org.freedesktop.login1"
HCI = "/org/bluez/hci0"
MANAGER = "org.freedesktop.DBus.ObjectManager"
PROPS = "org.freedesktop.DBus.Properties"
ADAPTER = "org.bluez.Adapter1"
DEVICE = "org.bluez.Device1"
TRANSPORT = "org.bluez.MediaTransport1"
U = "-0000-1000-8000-00805f9b34fb"
KINDS = {
    "headset": ["0000110b" + U, "0000110e" + U],
    "phone": ["0000110a" + U, "0000110c" + U, "0000110e" + U],
    "both": ["0000110a" + U, "0000110b" + U, "0000110c" + U],
}
XML = f"""
<node>
  <interface name="{MANAGER}">
    <method name="GetManagedObjects"><arg type="a{{oa{{sa{{sv}}}}}}" direction="out"/></method>
  </interface>
  <interface name="{ADAPTER}"/>
  <interface name="{DEVICE}">
    <method name="Connect"/>
    <method name="Disconnect"/>
    <method name="ConnectProfile"><arg type="s" direction="in"/></method>
    <method name="DisconnectProfile"><arg type="s" direction="in"/></method>
  </interface>
  <interface name="{TRANSPORT}"/>
  <interface name="{CONTROL}">
    <method name="Do"><arg type="s" direction="in"/><arg type="s" direction="out"/></method>
  </interface>
</node>
"""
INFO = {i.name: i for i in Gio.DBusNodeInfo.new_for_xml(XML).interfaces}
TYPES = {"Powered": "b", "Discovering": "b", "Discoverable": "b", "UUIDs": "as", "Connected": "b", "Address": "s",
         "Device": "o", "UUID": "s", "State": "s"}

log = open(sys.argv[1], "a", buffering=1)
bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
objects = {}
regs = {}
replies = {}
defaults = {}
owned = False


def path_of(addr):
    return f"{HCI}/dev_{addr.replace(':', '_')}"


def variants(props):
    return {k: GLib.Variant(TYPES[k], v) for k, v in props.items()}


def flag(v):
    return v in ("1", "true")


def emit(path, iface, member, value):
    bus.emit_signal(None, path, iface, member, value)


def add(path, iface, props):
    objects.setdefault(path, {})[iface] = props
    if iface == DEVICE and path not in regs:
        regs[path] = bus.register_object_with_closures2(path, INFO[DEVICE], on_call, None, None)
    if owned:
        emit("/", MANAGER, "InterfacesAdded", GLib.Variant("(oa{sa{sv}})", (path, {iface: variants(props)})))


def remove(path, iface):
    if iface not in objects.get(path, {}):
        return
    del objects[path][iface]
    if not objects[path]:
        del objects[path]
    if iface == DEVICE and path in regs:
        bus.unregister_object(regs.pop(path))
    if owned:
        emit("/", MANAGER, "InterfacesRemoved", GLib.Variant("(oas)", (path, [iface])))


def change(path, iface, key, value):
    objects[path][iface][key] = value
    emit(path, PROPS, "PropertiesChanged", GLib.Variant("(sa{sv}as)", (iface, variants({key: value}), [])))


def own(on):
    global owned
    if on:
        reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                              GLib.Variant("(su)", (BLUEZ, 4)), GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 1000,
                              None)
        owned = reply.unpack()[0] == 1
    else:
        bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName",
                      GLib.Variant("(s)", (BLUEZ,)), GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 1000, None)
        owned = False


def answer(inv, spec):
    result = spec[0]
    if result == "ok":
        inv.return_value(None)
    elif result != "none":
        inv.return_dbus_error(result, spec[1])
    return GLib.SOURCE_REMOVE


def on_call(conn, sender, path, iface, method, params, inv):
    if iface == MANAGER:
        out = {p: {i: variants(props) for i, props in ifaces.items()} for p, ifaces in objects.items()}
        inv.return_value(GLib.Variant("(a{oa{sa{sv}}})", (out,)))
        return
    if iface == CONTROL:
        inv.return_value(GLib.Variant("(s)", (command(params.unpack()[0].split()),)))
        return
    args = params.unpack()
    log.write(f"{time.monotonic():.3f} {method} {path.rsplit('dev_', 1)[-1].replace('_', ':')} {' '.join(args)}\n")
    queue = replies.get(method) or []
    spec = queue.pop(0) if queue else defaults.get(method, ("ok", "", 0.0))
    if spec[2] > 0:
        GLib.timeout_add(int(spec[2] * 1000), answer, inv, spec)
    else:
        answer(inv, spec)


def command(words):
    op, args = words[0], words[1:]
    if op == "own":
        own(True)
    elif op == "disown":
        own(False)
    elif op == "adapter":
        add(HCI, ADAPTER, {"Powered": flag(args[0]), "Discovering": False, "Discoverable": False})
    elif op == "noadapter":
        remove(HCI, ADAPTER)
    elif op == "device":
        addr, kind, connected = args
        add(path_of(addr), DEVICE, {"Address": addr, "UUIDs": KINDS[kind], "Connected": flag(connected)})
    elif op == "remove":
        remove(path_of(args[0]), DEVICE)
    elif op == "prop" and args[0] == "adapter":
        change(HCI, ADAPTER, args[1], flag(args[2]))
    elif op == "prop":
        change(path_of(args[0]), DEVICE, args[1], flag(args[2]))
    elif op == "disconnected":
        addr, sig = args[0], args[1]
        values = {"ss": (args[2], "x"), "s": (args[2],), "sss": (args[2], "x", "y")}[sig]
        emit(path_of(addr), DEVICE, "Disconnected", GLib.Variant(f"({sig})", values))
    elif op == "transport":
        name, addr, uuid = args
        add(f"{path_of(addr)}/sep1/{name}", TRANSPORT, {"Device": path_of(addr), "UUID": uuid + U, "State": "idle"})
    elif op == "untransport":
        name, addr = args
        remove(f"{path_of(addr)}/sep1/{name}", TRANSPORT)
    elif op in ("reply", "default"):
        method, result = args[0], args[1]
        message = args[2] if len(args) > 2 else ""
        delay = float(args[3]) if len(args) > 3 else 0.0
        spec = (result, "" if message == "-" else message, delay)
        if op == "reply":
            replies.setdefault(method, []).append(spec)
        else:
            defaults[method] = spec
    elif op == "teardown":
        if ADAPTER in objects.get(HCI, {}) and objects[HCI][ADAPTER]["Powered"]:
            change(HCI, ADAPTER, "Powered", False)
        for path in sorted(p for p in objects if DEVICE in objects[p]):
            remove(path, DEVICE)
        remove(HCI, ADAPTER)
        own(False)
    elif op == "sleep":
        emit("/org/freedesktop/login1", f"{LOGIN}.Manager", "PrepareForSleep", GLib.Variant("(b)", (flag(args[0]),)))
    else:
        return f"unknown {op}"
    bus.flush_sync(None)
    return "ok"


bus.register_object_with_closures2("/", INFO[MANAGER], on_call, None, None)
bus.register_object_with_closures2("/test", INFO[CONTROL], on_call, None, None)
for name in (CONTROL, LOGIN):
    bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                  GLib.Variant("(su)", (name, 4)), GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 1000, None)
GLib.MainLoop().run()
