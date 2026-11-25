#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
bridge="${repo}/data/usr/libexec/microos/microos-android-bridge"

T=$(mktemp -d)
pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "${p}" 2>/dev/null || true; done
    rm -rf "${T:?}"
}
trap cleanup EXIT

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

for t in dbus-daemon gdbus python3; do
    command -v "$t" > /dev/null || { echo "FAIL: $t missing" >&2; exit 1; }
done

cat > "${T}/system.conf" <<EOF
<busconfig>
  <type>system</type>
  <listen>unix:path=${T}/system</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="*"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
EOF
dbus-daemon --config-file="${T}/system.conf" --nofork &
pids+=($!)
for _ in {1..50}; do [[ -S "${T}/system" ]] && break; sleep 0.1; done
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=${T}/system"

export STATE="${T}/state"
export HOME="${T}/home"
export MICROOS_WAYDROID_CFG="${T}/waydroid.cfg"
export MICROOS_BINDER_DIR="${T}/dev"
export MICROOS_WPCTL="${T}/bin/wpctl"
export MICROOS_PW_DUMP="${T}/bin/pw-dump"
export MICROOS_ANDROID_GUEST="${T}/bin/guest"
export MICROOS_BRIDGE_HOLD_MS=1000
export MICROOS_BRIDGE_POWER_S=2
export MICROOS_BRIDGE_WPCTL_S=1
export MICROOS_BRIDGE_PROMPT_S=1
export MICROOS_BRIDGE_CONNECT_S=2
export PYTHONPATH="${T}/py"
system="${HOME}/.local/share/microos-waydroid/waydroid/data/system"
mkdir -p "${STATE}/in" "${STATE}/out" "${STATE}/die" "${STATE}/sinks" "${T}/py" "${T}/bin" "${system}" \
    "${MICROOS_BINDER_DIR}"
: > "${MICROOS_BINDER_DIR}/anbox-binder"
for f in binder callbacks wpctl clients logind files nm bluez times guest; do : > "${STATE}/${f}"; done
printf '0\n' > "${STATE}/guest-airplane"
printf '30 1\n' > "${STATE}/sinks/a"
printf 'a\n' > "${STATE}/sinks/default"

cat > "${MICROOS_WAYDROID_CFG}" <<'EOF'
[waydroid]
binder = anbox-binder
vndbinder = anbox-vndbinder
hwbinder = anbox-hwbinder
binder_protocol = aidl3
service_manager_protocol = aidl3
EOF

cat > "${T}/py/sitecustomize.py" <<'FAKE'
import builtins
import os

STATE = os.environ.get("STATE")
real_stat = os.stat
real_open = builtins.open


def note(kind, path):
    if STATE and isinstance(path, (str, bytes, os.PathLike)) and os.path.basename(os.fsdecode(path)) == "packages.list":
        with real_open(os.path.join(STATE, "files"), "a") as handle:
            handle.write(kind + "\n")


def stat(path, *args, **kwargs):
    note("stat", path)
    return real_stat(path, *args, **kwargs)


def opened(path, *args, **kwargs):
    note("open", path)
    return real_open(path, *args, **kwargs)


os.stat = stat
builtins.open = opened
FAKE

cat > "${T}/py/gbinder.py" <<'FAKE'
import json
import os
import time

import gi

gi.require_version("GLib", "2.0")
from gi.repository import GLib

STATE = os.environ["STATE"]
INBOX = os.path.join(STATE, "in")
OUTBOX = os.path.join(STATE, "out")
DEATHS = os.path.join(STATE, "die")
IFACE = "net.seilent.microos.IBridge"
remotes = {}


def record(name, line):
    with open(os.path.join(STATE, name), "a") as handle:
        handle.write(line + "\n")


def flag(name):
    return os.path.exists(os.path.join(STATE, name))


def signed(value):
    return value - (1 << 32) if value & 0x80000000 else value


def later(func, *args):
    func(*args)
    return False


def words(text):
    if text is None:
        return [("w", -1)]
    units = text.encode("utf-16-le", "surrogatepass")
    data = units + b"\0\0"
    data += b"\0" * (-len(data) % 4)
    return [("w", len(units) // 2)] + [("w", signed(int.from_bytes(data[i:i + 4], "little")))
                                       for i in range(0, len(data), 4)]


def remote(name):
    if name not in remotes:
        remotes[name] = RemoteObject(name)
    return remotes[name]


def tokens(value):
    kind = value[0]
    if kind == "i":
        return [("w", value[1])]
    if kind == "s":
        return words(value[1])
    if kind == "S":
        return words(None)
    if kind == "o":
        return [("o", remote(value[1]))]
    if kind == "O":
        return [("o", None)]
    return [("x", None)]


class RemoteObject:
    def __init__(self, name):
        self.name = name
        self.dead = name is None
        self.handlers = {}
        self.next = 0

    def is_dead(self):
        return self.dead

    def add_death_handler(self, func):
        self.next += 1
        self.handlers[self.next] = func
        record("binder", f"death handler {self.name} {self.next}")
        return self.next

    def remove_handler(self, ident):
        record("binder", f"remove handler {self.name} {ident}")
        del self.handlers[ident]

    def die(self):
        self.dead = True
        for func in list(self.handlers.values()):
            func()


class Reader:
    def __init__(self, items):
        self.items = list(items)

    def read_int32(self):
        if self.items and self.items[0][0] == "x":
            raise RuntimeError("a reader fault")
        if not self.items or self.items[0][0] != "w":
            return False, 0
        return True, self.items.pop(0)[1]

    def read_nullable_object(self):
        if not self.items or self.items[0][0] != "o":
            return False, RemoteObject(None)
        found = self.items.pop(0)[1]
        return True, found if found is not None else RemoteObject(None)


class RemoteRequest:
    def __init__(self, euid, oneway, iface, items):
        self.euid = euid
        self.oneway = oneway
        self.iface = iface
        self.items = items

    def sender_euid(self):
        return self.euid

    def sender_pid(self):
        return 0 if self.oneway else 4242

    def interface(self):
        return self.iface.encode()

    def init_reader(self):
        return Reader(self.items)


class LocalReply:
    def __init__(self):
        self.values = []

    def append_int32(self, value):
        if not 0 <= value <= 0xFFFFFFFF:
            raise OverflowError("can't convert negative value to unsigned int")
        self.values.append(signed(value))

    def append_string16(self, value):
        self.values.append(value.encode().decode() if isinstance(value, str) else value.decode())


class LocalObject:
    def __init__(self, iface, handler):
        self.iface = iface
        self.handler = handler

    def new_reply(self):
        return LocalReply()


class Client:
    def __init__(self, remote_object, iface):
        record("binder", f"client {remote_object.name} {iface}")
        self.remote = remote_object

    def new_request(self):
        return LocalReply()

    def transact_sync_oneway(self, code, request):
        if self.remote.dead:
            record("binder", f"dead callback {self.remote.name} {code}")
            return -32
        record("callbacks", f"{self.remote.name} {code} {json.dumps(request.values)}")
        return 0


class ServiceManager:
    __slots__ = ("func", "list_func", "get_service_func", "up", "services", "presence")

    def __init__(self, device, manager=None, protocol=None):
        record("binder", f"manager {device} {manager} {protocol}")
        self.up = self.is_present()
        self.services = {}
        self.presence = []
        GLib.timeout_add(20, self.poll)

    def is_present(self):
        return not flag("sm-down")

    def new_local_object(self, iface, handler):
        record("binder", f"local {iface}")
        return LocalObject(iface, handler)

    def add_presence_handler(self, func):
        self.func = func
        record("binder", "presence handler")
        self.presence.append(func)
        return len(self.presence)

    def add_service(self, name, obj, func):
        self.add_service_func = func
        if not self.is_present():
            GLib.idle_add(later, func, -32)
            return 1
        record("binder", f"add {name} {obj.iface}")
        self.services[name] = obj
        GLib.idle_add(later, func, 0)
        return 1

    def poll(self):
        up = self.is_present()
        if up != self.up:
            self.up = up
            if not up:
                self.services.clear()
            record("binder", "present" if up else "gone")
            for func in self.presence:
                func()
        for name in sorted(os.listdir(DEATHS)):
            os.remove(os.path.join(DEATHS, name))
            record("binder", f"die {name}")
            remote(name).die()
        for name in sorted((n for n in os.listdir(INBOX) if n.isdigit()), key=int):
            path = os.path.join(INBOX, name)
            with open(path) as handle:
                call = json.load(handle)
            os.remove(path)
            self.serve(name, call)
        return True

    def serve(self, name, call):
        obj = self.services.get("microosbridge")
        if obj is None:
            text = "no service"
        else:
            items = [item for value in call["values"] for item in tokens(value)]
            flags = call["flags"]
            start = time.monotonic()
            slowest = 0
            for _ in range(call["repeat"]):
                began = time.monotonic()
                request = RemoteRequest(call["euid"], flags & 1, call["iface"], items)
                reply, status = obj.handler(request, call["code"], flags)
                slowest = max(slowest, time.monotonic() - began)
            if call["repeat"] > 1:
                record("binder", f"burst {call['repeat']} {time.monotonic() - start:.3f}")
            record("times", f"{call['code']} {slowest * 1000:.0f}")
            text = f"{status} {json.dumps(None if reply is None else reply.values)}"
        with open(os.path.join(OUTBOX, f".{name}"), "w") as handle:
            handle.write(text + "\n")
        os.rename(os.path.join(OUTBOX, f".{name}"), os.path.join(OUTBOX, name))
FAKE

cat > "${T}/bin/wpctl" <<'FAKE'
#!/usr/bin/python3
import os
import sys
import time

STATE = os.environ["STATE"]
SINKS = os.path.join(STATE, "sinks")


def record(line):
    with open(os.path.join(STATE, "wpctl"), "a") as handle:
        handle.write(line + "\n")


def store(name, hundredths, muted):
    path = os.path.join(SINKS, name)
    with open(path + ".tmp", "w") as handle:
        handle.write(f"{hundredths} {int(muted)}\n")
    os.replace(path + ".tmp", path)


with open(os.path.join(STATE, "clients"), "a") as handle:
    handle.write(f"{os.getpid()}\n")
verb, sink = sys.argv[1], sys.argv[2]
if sink != "@DEFAULT_AUDIO_SINK@" or verb not in ("get-volume", "set-volume", "set-mute"):
    record(f"bad {' '.join(sys.argv[1:])}")
    sys.exit(1)
if verb != "get-volume" and os.path.exists(os.path.join(STATE, "wpctl-hang")):
    record(f"hang {' '.join(sys.argv[1:])}")
    time.sleep(3600)
with open(os.path.join(SINKS, "default")) as handle:
    name = handle.read().strip()
with open(os.path.join(SINKS, name)) as handle:
    hundredths, muted = (int(field) for field in handle.read().split())
if verb == "get-volume":
    print(f"Volume: {hundredths // 100}.{hundredths % 100:02d}{' [MUTED]' if muted else ''}")
elif verb == "set-volume":
    value = round(float(sys.argv[3]) * 100)
    record(f"set-volume {sys.argv[3]}")
    if (hundredths * 15 + 50) // 100 == (value * 15 + 50) // 100:
        record(f"equal {hundredths} {value}")
    store(name, value, muted)
else:
    record(f"set-mute {sys.argv[3]}")
    store(name, hundredths, sys.argv[3] == "1")
FAKE

cat > "${T}/bin/pw-dump" <<'FAKE'
#!/usr/bin/python3
import os
import sys
import time

STATE = os.environ["STATE"]
SINKS = os.path.join(STATE, "sinks")
with open(os.path.join(STATE, "pw-dump.args"), "w") as handle:
    handle.write(" ".join(sys.argv[1:]) + "\n")
with open(os.path.join(STATE, "pw-dump.pid"), "w") as handle:
    handle.write(f"{os.getpid()}\n")
OBJECT = """[
  {
    "id": %d,
    "type": "PipeWire:Interface:%s",
    "permissions": [ "r", "w", "x", "m" ],
    "info": {
      "change-mask": [
        "props"
      ],
      "props": {
        "application.name": "%s"
      }
    }
  }
]"""
GONE = """[
  {
    "id": %d,
    "info": null
  }
]"""


def clients():
    with open(os.path.join(STATE, "clients")) as handle:
        return handle.read().count("\n")


ids = {"default": 29}
last = {}
started = clients()
client = 99
while True:
    seen = {}
    for name in os.listdir(SINKS):
        if not name.endswith(".tmp"):
            try:
                with open(os.path.join(SINKS, name)) as handle:
                    seen[name] = handle.read()
            except OSError:
                pass
    for name in sorted(set(seen) | set(last)):
        if seen.get(name) != last.get(name):
            ident = ids.setdefault(name, 29 + len(ids))
            if name not in seen:
                print(GONE % ident, flush=True)
            else:
                print(OBJECT % (ident, "Metadata" if name == "default" else "Node", name), flush=True)
    last = seen
    now = clients()
    for _ in range(started, now):
        client += 1
        print(OBJECT % (client, "Client", "wpctl"), flush=True)
        print(GONE % client, flush=True)
    started = now
    time.sleep(0.02)
FAKE
cat > "${T}/bin/guest" <<'FAKE'
#!/usr/bin/bash
cmd() {
    if [[ $# == 2 && "$1 $2" == "connectivity airplane-mode" ]]; then
        echo get >> "${STATE}/guest"
        if [[ "$(cat "${STATE}/guest-airplane")" == 1 ]]; then echo enabled; else echo disabled; fi
    elif [[ $# == 3 && "$1 $2" == "connectivity airplane-mode" && "$3" =~ ^(en|dis)able$ ]]; then
        echo "$3" >> "${STATE}/guest"
        if [[ "$3" == enable ]]; then echo 1; else echo 0; fi > "${STATE}/guest-airplane"
    else
        echo "bad cmd $*" >> "${STATE}/guest"
        return 1
    fi
}
if [[ $# != 2 || "$1" != sh ]]; then
    echo "bad $*" >> "${STATE}/guest"
    exit 2
fi
if [[ -e "${STATE}/guest-fails" ]]; then
    echo "microos-android-guest: cannot connect to 192.0.2.2:5555" >&2
    exit 255
fi
eval "$2"
FAKE
chmod 0755 "${T}/bin/wpctl" "${T}/bin/pw-dump" "${T}/bin/guest"

cat > "${T}/logind" <<'FAKE'
import os

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

STATE = os.environ["STATE"]
XML = """
<node>
  <interface name="org.freedesktop.login1.Manager">
    <method name="PowerOff"><arg type="b" direction="in"/></method>
    <method name="Reboot"><arg type="b" direction="in"/></method>
  </interface>
</node>
"""


def record(line):
    with open(os.path.join(STATE, "logind"), "a") as handle:
        handle.write(line + "\n")


def method(_conn, _sender, _path, _iface, name, params, invocation):
    record(f"{name} {str(params.unpack()[0]).lower()}")
    if os.path.exists(os.path.join(STATE, "logind-fails")):
        invocation.return_dbus_error("org.freedesktop.DBus.Error.AccessDenied", "refused in the stub")
        return
    invocation.return_value(None)


bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
for info in Gio.DBusNodeInfo.new_for_xml(XML).interfaces:
    bus.register_object("/org/freedesktop/login1", info, method, None, None)
Gio.bus_own_name_on_connection(bus, "org.freedesktop.login1", Gio.BusNameOwnerFlags.NONE,
                               lambda *_: record("ready"), None)
GLib.MainLoop().run()
FAKE
cat > "${T}/nm" <<'FAKE'
import os
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

STATE = os.environ["STATE"]
NAME = "org.freedesktop.NetworkManager"
BASE = "/org/freedesktop/NetworkManager"
DEVICE_PATH = BASE + "/Devices/3"
SETTINGS_PATH = BASE + "/Settings"
OM = "org.freedesktop.DBus.ObjectManager"
PROPS = "org.freedesktop.DBus.Properties"
DEVICE = NAME + ".Device"
WIRELESS = NAME + ".Device.Wireless"
POINT = NAME + ".AccessPoint"
ACTIVE = NAME + ".Connection.Active"
SETTINGS = NAME + ".Settings"
PROFILE = NAME + ".Settings.Connection"
XML = """
<node>
  <interface name="org.freedesktop.DBus.ObjectManager">
    <method name="GetManagedObjects"><arg type="a{oa{sa{sv}}}" direction="out"/></method>
    <signal name="InterfacesAdded"><arg type="o"/><arg type="a{sa{sv}}"/></signal>
    <signal name="InterfacesRemoved"><arg type="o"/><arg type="as"/></signal>
  </interface>
  <interface name="org.freedesktop.DBus.Properties">
    <method name="Get">
      <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/>
    </method>
    <method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
    <method name="Set">
      <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/>
    </method>
    <signal name="PropertiesChanged"><arg type="s"/><arg type="a{sv}"/><arg type="as"/></signal>
  </interface>
  <interface name="org.freedesktop.NetworkManager">
    <method name="ActivateConnection">
      <arg type="o" direction="in"/><arg type="o" direction="in"/><arg type="o" direction="in"/>
      <arg type="o" direction="out"/>
    </method>
    <method name="AddAndActivateConnection">
      <arg type="a{sa{sv}}" direction="in"/><arg type="o" direction="in"/><arg type="o" direction="in"/>
      <arg type="o" direction="out"/><arg type="o" direction="out"/>
    </method>
  </interface>
  <interface name="org.freedesktop.NetworkManager.Device"/>
  <interface name="org.freedesktop.NetworkManager.Device.Wireless">
    <method name="RequestScan"><arg type="a{sv}" direction="in"/></method>
  </interface>
  <interface name="org.freedesktop.NetworkManager.AccessPoint"/>
  <interface name="org.freedesktop.NetworkManager.Connection.Active">
    <signal name="StateChanged"><arg type="u"/><arg type="u"/></signal>
  </interface>
  <interface name="org.freedesktop.NetworkManager.Settings">
    <method name="ListConnections"><arg type="ao" direction="out"/></method>
    <signal name="NewConnection"><arg type="o"/></signal>
    <signal name="ConnectionRemoved"><arg type="o"/></signal>
  </interface>
  <interface name="org.freedesktop.NetworkManager.Settings.Connection">
    <method name="GetSettings"><arg type="a{sa{sv}}" direction="out"/></method>
    <method name="Update2">
      <arg type="a{sa{sv}}" direction="in"/><arg type="u" direction="in"/><arg type="a{sv}" direction="in"/>
      <arg type="a{sv}" direction="out"/>
    </method>
    <method name="Delete"/>
    <signal name="Updated"/>
  </interface>
  <interface name="test.Stub">
    <method name="Set">
      <arg type="o" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/>
      <arg type="v" direction="in"/>
    </method>
  </interface>
</node>
"""
POINTS = [("1", b"Homenet", 50, 1, 0, 0x188), ("2", b"Homenet", 70, 1, 0, 0x188), ("3", b"Cafenet", 80, 0, 0, 0),
          ("4", b"Owenet", 40, 1, 0, 0x888), ("5", b"Saenet", 30, 1, 0, 0x488), ("6", b"Corpnet", 60, 1, 0, 0x288),
          ("7", b"", 90, 1, 0, 0x188), ("8", b"Caf\xe9", 20, 0, 0, 0), ("9", b"Mixednet", 25, 1, 0, 0x588),
          ("10", b"Wepnet", 15, 1, 0, 0)] + [(str(11 + i), f"net{i:02d}".encode(), 1, 0, 0, 0) for i in range(30)]
FREE = ((OM, "GetManagedObjects"), (PROPS, "Get"), (PROPS, "GetAll"))
bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
infos = {info.name: info for info in Gio.DBusNodeInfo.new_for_xml(XML).interfaces}
objects = {}
ids = {}
profiles = {}
held = []
counters = {"profile": int(sys.argv[1]), "active": 1}


def record(line):
    with open(os.path.join(STATE, "nm"), "a") as handle:
        handle.write(line + "\n")


def flag(name):
    return os.path.exists(os.path.join(STATE, name))


def outcome():
    try:
        with open(os.path.join(STATE, "nm-outcome")) as handle:
            return handle.read().split()
    except OSError:
        return ["2"]


def groups(variant):
    found = {}
    for i in range(variant.n_children()):
        group = variant.get_child_value(i)
        values = group.get_child_value(1)
        entries = (values.get_child_value(j) for j in range(values.n_children()))
        found[group.get_child_value(0).get_string()] = {
            entry.get_child_value(0).get_string(): entry.get_child_value(1).get_variant() for entry in entries}
    return found


def canon(settings):
    fields = []
    for group in sorted(settings):
        for key, value in sorted(settings[group].items()):
            shown = bytes(value.unpack()).hex() if value.get_type_string() == "ay" else value.print_(False)
            fields.append(f"{group}.{key}={shown}")
    return " ".join(fields)


def later(invocation, reply):
    invocation.return_value(reply)
    return False


def export(path, interfaces):
    objects[path] = interfaces
    ids[path] = [bus.register_object(path, infos[name], method, None, None) for name in list(interfaces) + [PROPS]]
    bus.emit_signal(None, "/org/freedesktop", OM, "InterfacesAdded", GLib.Variant("(oa{sa{sv}})", (path, interfaces)))


def unexport(path):
    for ident in ids.pop(path):
        bus.unregister_object(ident)
    interfaces = objects.pop(path)
    bus.emit_signal(None, "/org/freedesktop", OM, "InterfacesRemoved", GLib.Variant("(oas)", (path, list(interfaces))))


def change(path, iface, name, value):
    objects[path][iface][name] = value
    bus.emit_signal(None, path, PROPS, "PropertiesChanged", GLib.Variant("(sa{sv}as)", (iface, {name: value}, [])))


def add_profile(settings):
    path = f"{SETTINGS_PATH}/{counters['profile']}"
    counters["profile"] += 1
    profiles[path] = settings
    export(path, {PROFILE: {}})
    bus.emit_signal(None, SETTINGS_PATH, SETTINGS, "NewConnection", GLib.Variant("(o)", (path,)))
    return path


def settle(path, point, state, reason):
    change(path, ACTIVE, "State", GLib.Variant("u", state))
    bus.emit_signal(None, path, ACTIVE, "StateChanged", GLib.Variant("(uu)", (state, reason)))
    if state == 2:
        change(DEVICE_PATH, WIRELESS, "ActiveAccessPoint", GLib.Variant("o", point))
        change(DEVICE_PATH, DEVICE, "State", GLib.Variant("u", 100))
    return False


def activate(profile, point):
    path = f"{BASE}/ActiveConnection/{counters['active']}"
    counters["active"] += 1
    export(path, {ACTIVE: {"State": GLib.Variant("u", 1), "Connection": GLib.Variant("o", profile)}})
    change(DEVICE_PATH, DEVICE, "ActiveConnection", GLib.Variant("o", path))
    fields = outcome()
    if fields[0] != "none":
        GLib.timeout_add(100, settle, path, point, int(fields[0]), int(fields[1]) if len(fields) > 1 else 0)
    return path


def method(_conn, _sender, path, iface, name, params, invocation):
    if flag("nm-hang") and (iface, name) not in FREE and iface != "test.Stub":
        record(f"hang {name}")
        held.append(invocation)
        return
    reply = None
    if iface == OM:
        reply = GLib.Variant("(a{oa{sa{sv}}})", (objects,))
    elif iface == PROPS and name == "Get":
        group, key = params.unpack()
        reply = GLib.Variant("(v)", (objects[path][group][key],))
    elif iface == PROPS and name == "GetAll":
        reply = GLib.Variant("(a{sv})", (objects[path][params.unpack()[0]],))
    elif iface in (PROPS, "test.Stub"):
        values = [params.get_child_value(i) for i in range(params.n_children())]
        target = values.pop(0).get_string() if iface == "test.Stub" else path
        if iface == PROPS:
            record(f"set {values[1].get_string()} {values[2].get_variant().print_(False)}")
        change(target, values[0].get_string(), values[1].get_string(), values[2].get_variant())
    elif name == "ActivateConnection":
        profile, _device, point = params.unpack()
        record(f"activate {profile} {point}")
        reply = GLib.Variant("(o)", (activate(profile, point),))
    elif name == "AddAndActivateConnection":
        settings = groups(params.get_child_value(0))
        point = params.get_child_value(2).get_string()
        record(f"add-activate {point} {canon(settings)}")
        profile = add_profile(settings)
        reply = GLib.Variant("(oo)", (profile, activate(profile, point)))
    elif name == "RequestScan":
        record("scan")
    elif name == "ListConnections":
        record("list")
        reply = GLib.Variant("(ao)", (sorted(profiles),))
    elif name == "GetSettings":
        record(f"get-settings {path}")
        public = {group: {key: value for key, value in values.items() if key != "psk"}
                  for group, values in profiles[path].items()}
        reply = GLib.Variant("(a{sa{sv}})", (public,))
        if flag("nm-slow-settings"):
            held.append(invocation)
            GLib.timeout_add(1000, later, invocation, reply)
            return
    elif name == "Update2":
        settings = groups(params.get_child_value(0))
        record(f"update2 {path} {params.get_child_value(1).get_uint32()} {canon(settings)}")
        profiles[path] = settings
        bus.emit_signal(None, path, PROFILE, "Updated", None)
        reply = GLib.Variant("(a{sv})", ({},))
    elif name == "Delete":
        record(f"delete {path}")
        del profiles[path]
        unexport(path)
        bus.emit_signal(None, SETTINGS_PATH, SETTINGS, "ConnectionRemoved", GLib.Variant("(o)", (path,)))
    invocation.return_value(reply)


export(BASE, {NAME: {"WirelessEnabled": GLib.Variant("b", True), "WirelessHardwareEnabled": GLib.Variant("b", True)}})
ids[BASE].append(bus.register_object(BASE, infos["test.Stub"], method, None, None))
export(SETTINGS_PATH, {SETTINGS: {}})
for ident, ssid, strength, flags, wpa, rsn in POINTS:
    export(f"{BASE}/AccessPoint/{ident}", {POINT: {
        "Ssid": GLib.Variant("ay", ssid), "Strength": GLib.Variant("y", strength), "Flags": GLib.Variant("u", flags),
        "WpaFlags": GLib.Variant("u", wpa), "RsnFlags": GLib.Variant("u", rsn)}})
export(DEVICE_PATH, {
    DEVICE: {"Interface": GLib.Variant("s", "wlan0"), "State": GLib.Variant("u", 30),
             "ActiveConnection": GLib.Variant("o", "/"), "DeviceType": GLib.Variant("u", 2)},
    WIRELESS: {"AccessPoints": GLib.Variant("ao", [f"{BASE}/AccessPoint/{point[0]}" for point in POINTS]),
               "ActiveAccessPoint": GLib.Variant("o", "/")}})
add_profile({"connection": {"id": GLib.Variant("s", "Homenet"), "type": GLib.Variant("s", "802-11-wireless")},
             "802-11-wireless": {"ssid": GLib.Variant("ay", b"Homenet")},
             "802-11-wireless-security": {"key-mgmt": GLib.Variant("s", "wpa-psk"),
                                          "psk": GLib.Variant("s", "Homepass1")}})
add_profile({"connection": {"id": GLib.Variant("s", "Wired"), "type": GLib.Variant("s", "802-3-ethernet")}})
bus.register_object("/org/freedesktop", infos[OM], method, None, None)
Gio.bus_own_name_on_connection(bus, NAME, Gio.BusNameOwnerFlags.NONE, lambda *_: record("ready"), None)
GLib.MainLoop().run()
FAKE

cat > "${T}/bluez" <<'FAKE'
import os

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

STATE = os.environ["STATE"]
NAME = "org.bluez"
HCI = "/org/bluez/hci0"
OM = "org.freedesktop.DBus.ObjectManager"
PROPS = "org.freedesktop.DBus.Properties"
ADAPTER = "org.bluez.Adapter1"
DEVICE = "org.bluez.Device1"
MANAGER = "org.bluez.AgentManager1"
XML = """
<node>
  <interface name="org.freedesktop.DBus.ObjectManager">
    <method name="GetManagedObjects"><arg type="a{oa{sa{sv}}}" direction="out"/></method>
    <signal name="InterfacesAdded"><arg type="o"/><arg type="a{sa{sv}}"/></signal>
    <signal name="InterfacesRemoved"><arg type="o"/><arg type="as"/></signal>
  </interface>
  <interface name="org.freedesktop.DBus.Properties">
    <method name="Get">
      <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/>
    </method>
    <method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
    <method name="Set">
      <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/>
    </method>
    <signal name="PropertiesChanged"><arg type="s"/><arg type="a{sv}"/><arg type="as"/></signal>
  </interface>
  <interface name="org.bluez.AgentManager1">
    <method name="RegisterAgent"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
    <method name="UnregisterAgent"><arg type="o" direction="in"/></method>
    <method name="RequestDefaultAgent"><arg type="o" direction="in"/></method>
  </interface>
  <interface name="org.bluez.Adapter1">
    <method name="StartDiscovery"/>
    <method name="StopDiscovery"/>
  </interface>
  <interface name="org.bluez.Device1">
    <method name="Connect"/>
    <method name="Disconnect"/>
    <method name="Pair"/>
  </interface>
  <interface name="test.Stub">
    <method name="Set">
      <arg type="o" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/>
      <arg type="v" direction="in"/>
    </method>
  </interface>
</node>
"""
FREE = ((OM, "GetManagedObjects"), (PROPS, "Get"), (PROPS, "GetAll"))
LONG = "L" * 63 + "\U0001F600tail"
bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
infos = {info.name: info for info in Gio.DBusNodeInfo.new_for_xml(XML).interfaces}
objects = {}
ids = {}
agent = {}
held = []


def record(line):
    with open(os.path.join(STATE, "bluez"), "a") as handle:
        handle.write(line + "\n")


def export(path, interfaces):
    objects[path] = interfaces
    ids[path] = [bus.register_object(path, infos[name], method, None, None) for name in list(interfaces) + [PROPS]]
    bus.emit_signal(None, "/", OM, "InterfacesAdded", GLib.Variant("(oa{sa{sv}})", (path, interfaces)))


def change(path, iface, name, value):
    objects[path][iface][name] = value
    bus.emit_signal(None, path, PROPS, "PropertiesChanged", GLib.Variant("(sa{sv}as)", (iface, {name: value}, [])))


def device(address, alias, paired, named=True):
    props = {"Address": GLib.Variant("s", address), "Alias": GLib.Variant("s", alias),
             "Paired": GLib.Variant("b", paired), "Trusted": GLib.Variant("b", paired),
             "Connected": GLib.Variant("b", False), "Adapter": GLib.Variant("o", HCI)}
    if named:
        props["Name"] = GLib.Variant("s", alias)
    path = f"{HCI}/dev_{address.replace(':', '_')}"
    if path not in objects:
        export(path, {DEVICE: props})
    return False


def pair(path, address, invocation):
    record(f"pair {address}")
    if not agent:
        invocation.return_dbus_error("org.bluez.Error.AuthenticationFailed", "no agent")
        return

    def replied(conn, result):
        try:
            conn.call_finish(result)
        except GLib.Error as error:
            record(f"agent {Gio.DBusError.get_remote_error(error)}")
            invocation.return_dbus_error("org.bluez.Error.AuthenticationRejected", "the agent said no")
            return
        change(path, DEVICE, "Paired", GLib.Variant("b", True))
        record(f"paired {address}")
        invocation.return_value(None)

    bus.call(agent["sender"], agent["path"], "org.bluez.Agent1", "RequestConfirmation",
             GLib.Variant("(ou)", (path, 123456)), None, Gio.DBusCallFlags.NONE, 30000, None, replied)


def method(_conn, sender, path, iface, name, params, invocation):
    if os.path.exists(os.path.join(STATE, "bluez-hang")) and (iface, name) not in FREE and iface != "test.Stub":
        record(f"hang {name}")
        held.append(invocation)
        return
    reply = None
    if iface == OM:
        reply = GLib.Variant("(a{oa{sa{sv}}})", (objects,))
    elif iface == PROPS and name == "Get":
        group, key = params.unpack()
        reply = GLib.Variant("(v)", (objects[path][group][key],))
    elif iface == PROPS and name == "GetAll":
        reply = GLib.Variant("(a{sv})", (objects[path][params.unpack()[0]],))
    elif iface in (PROPS, "test.Stub"):
        values = [params.get_child_value(i) for i in range(params.n_children())]
        target = values.pop(0).get_string() if iface == "test.Stub" else path
        if iface == PROPS:
            record(f"set {values[1].get_string()} {values[2].get_variant().print_(False)}")
        change(target, values[0].get_string(), values[1].get_string(), values[2].get_variant())
    elif name == "RegisterAgent":
        agent_path, capability = params.unpack()
        record(f"register {sender} {agent_path} {capability}")
        agent.update(sender=sender, path=agent_path)
    elif name == "RequestDefaultAgent":
        record(f"default {params.unpack()[0]}")
    elif name == "UnregisterAgent":
        record(f"unregister {params.unpack()[0]}")
        agent.clear()
    elif name == "StartDiscovery":
        record("start-discovery")
        change(HCI, ADAPTER, "Discovering", GLib.Variant("b", True))
        GLib.timeout_add(50, device, "AA:BB:CC:DD:EE:02", "Keyboard fixture", False)
    elif name == "StopDiscovery":
        record("stop-discovery")
        change(HCI, ADAPTER, "Discovering", GLib.Variant("b", False))
    elif name in ("Connect", "Disconnect"):
        record(f"{name.lower()} {objects[path][DEVICE]['Address'].get_string()}")
        change(path, DEVICE, "Connected", GLib.Variant("b", name == "Connect"))
    elif name == "Pair":
        pair(path, objects[path][DEVICE]["Address"].get_string(), invocation)
        return
    invocation.return_value(reply)


export("/org/bluez", {MANAGER: {}})
ids["/org/bluez"].append(bus.register_object("/org/bluez", infos["test.Stub"], method, None, None))
export(HCI, {ADAPTER: {"Address": GLib.Variant("s", "00:11:22:33:44:55"), "Powered": GLib.Variant("b", False),
                       "Discovering": GLib.Variant("b", False)}})
device("AA:BB:CC:DD:EE:01", "Headset fixture", True)
device("AA:BB:CC:DD:EE:03", LONG, True)
device("AA:BB:CC:DD:EE:04", "AA-BB-CC-DD-EE-04", False, False)
bus.register_object("/", infos[OM], method, None, None)
Gio.bus_own_name_on_connection(bus, NAME, Gio.BusNameOwnerFlags.NONE, lambda *_: record("ready"), None)
GLib.MainLoop().run()
FAKE

count() {
    local c
    c=$(grep -c -- "$1" "$2") || true
    echo "${c:-0}"
}

wait_for() {
    for _ in {1..100}; do
        [[ "$("$2")" == "$1" ]] && return 0
        sleep 0.05
    done
    return 1
}

wait_line() {
    for _ in {1..100}; do
        grep -qxF -- "$1" "$2" 2>/dev/null && return 0
        sleep 0.05
    done
    return 1
}

wait_log() { wait_line "microos-android-bridge: $1" "${T}/log"; }

wait_count() {
    for _ in {1..100}; do
        (( $(count "$2" "$3") >= $1 )) && return 0
        sleep 0.05
    done
    return 1
}

python3 "${T}/logind" &
pids+=($!)
wait_line ready "${STATE}/logind" || { echo "FAIL: fake logind did not start" >&2; exit 1; }

start_bridge() {
    : > "${T}/log"
    "${bridge}" > "${T}/log" 2>&1 &
    bridge_pid=$!
    pids+=("${bridge_pid}")
}

stop_bridge() {
    local rc=0
    kill -TERM "${bridge_pid}"
    for _ in {1..60}; do kill -0 "${bridge_pid}" 2>/dev/null || break; sleep 0.05; done
    kill -0 "${bridge_pid}" 2>/dev/null && fail "$1: the bridge did not stop within 3 s"
    wait "${bridge_pid}" || rc=$?
    [[ "${rc}" == 0 ]] || fail "$1: exit ${rc}: $(cat "${T}/log")"
    grep -q "Traceback" "${T}/log" && fail "$1: a traceback: $(cat "${T}/log")"
    return 0
}

seq=0
reply=
call() {
    local values=$3 flags=${4:-0} iface=${5:-net.seilent.microos.IBridge} repeat=${6:-1}
    seq=$((seq + 1))
    printf '{"euid": %s, "code": %s, "flags": %s, "iface": "%s", "repeat": %s, "values": %s}\n' \
        "$1" "$2" "${flags}" "${iface}" "${repeat}" "${values}" > "${STATE}/in/.${seq}"
    mv "${STATE}/in/.${seq}" "${STATE}/in/${seq}"
    for _ in {1..200}; do [[ -e "${STATE}/out/${seq}" ]] && break; sleep 0.02; done
    reply=$(cat "${STATE}/out/${seq}" 2>/dev/null || echo "no reply")
}

expect() {
    local what=$1 want=$2
    shift 2
    call "$@"
    [[ "${reply}" == "${want}" ]] || fail "${what}: ${reply}, want ${want}: $(tail -n 5 "${T}/log")"
}

uid=10123
bad='0 [-3, "bad argument", 0]'
refused='0 [-1, "refused", 0]'
hello() { call "${2:-${uid}}" 1 "[[\"i\", 1], [\"o\", \"$1\"]]"; }
report() { call "${uid}" 2 "[[\"i\", $1], [\"i\", $2], [\"i\", $3]]" 1; }
reason() { call "${2:-${uid}}" 11 "[[\"s\", \"$1\"]]"; }

entry() {
    echo "net.seilent.microos.helper $1 ${2:-0} /data/user/0/net.seilent.microos.helper" \
        "${3:-platform:privapp:targetSdkVersion=33} 3003 0 1"
}

packages() {
    printf '%s\n' "$@" > "${system}/packages.list.tmp"
    mv -f "${system}/packages.list.tmp" "${system}/packages.list"
}

sink() {
    printf '%s %s\n' "$2" "$3" > "${STATE}/sinks/$1.tmp"
    mv -f "${STATE}/sinks/$1.tmp" "${STATE}/sinks/$1"
}

host() { "${MICROOS_WPCTL}" get-volume @DEFAULT_AUDIO_SINK@; }

mark() {
    cb_seen=$(wc -l < "${STATE}/callbacks")
    w_seen=$(wc -l < "${STATE}/wpctl")
}

pushes() { tail -n +"$((cb_seen + 1))" "${STATE}/callbacks" | sed -n 's/^cb[0-9]* 1 //p' | paste -sd ' '; }

writes() {
    tail -n +"$((w_seen + 1))" "${STATE}/wpctl" | grep -E '^set-' | paste -sd ',' | sed 's/,/, /g'
}

registered() { count '^add microosbridge net.seilent.microos.IBridge$' "${STATE}/binder"; }

start_bridge
wait_log "microosbridge added" || fail "the start did not add microosbridge: $(cat "${T}/log")"
grep -qx "manager ${MICROOS_BINDER_DIR}/anbox-binder aidl3 aidl3" "${STATE}/binder" \
    || fail "the service manager is not the one waydroid.cfg names: $(cat "${STATE}/binder")"
grep -qx "local net.seilent.microos.IBridge" "${STATE}/binder" || fail "no IBridge object: $(cat "${STATE}/binder")"
grep -qx "presence handler" "${STATE}/binder" || fail "no presence handler: $(cat "${STATE}/binder")"
mkdir -p "${T}/probe"
STATE="${T}/probe" python3 - <<'PROBE' || fail "the fake ServiceManager stores an add_service_func outside its slots"
import gbinder

try:
    gbinder.ServiceManager("probe").add_service("probe", None, print)
except AttributeError:
    pass
else:
    raise SystemExit(1)
PROBE
wait_line "-m -N" "${STATE}/pw-dump.args" || fail "pw-dump is not in monitor mode: $(cat "${STATE}/pw-dump.args")"

expect "hello with no packages.list" "${refused}" "${uid}" 1 '[["i", 1], ["o", "cb1"]]'
wait_log "refused 1 from uid ${uid}" || fail "a refused hello was not logged: $(cat "${T}/log")"
expect "a oneway call with no packages.list" "0 null" "${uid}" 2 '[["i", 3], ["i", 15], ["i", 0]]' 1
wait_log "refused 2 from uid ${uid}" || fail "a refused oneway call was not logged: $(cat "${T}/log")"
packages "$(entry 10123)"
wait_log "helper uid 10123" || fail "packages.list was not read: $(cat "${T}/log")"
expect "hello from the helper" "0 [0, 0]" "${uid}" 1 '[["i", 1], ["o", "cb1"]]'
wait_log "hello from uid 10123" || fail "a hello was not logged: $(cat "${T}/log")"
expect "hello from another app" "${refused}" 10124 1 '[["i", 1], ["o", "cb1"]]'
sleep 0.15
packages "$(entry 10200)"
expect "hello from the uid of a data reset" "0 [0, 0]" 10200 1 '[["i", 1], ["o", "cb1"]]'
expect "the old uid after a data reset" "${refused}" 10123 11 '[["s", "0battery"]]'
sleep 0.15
packages "$(entry 10200)" "$(entry 10201)"
wait_log "no helper uid in ${system}/packages.list" || fail "two helper lines were not read: $(cat "${T}/log")"
expect "two helper lines" "${refused}" 10200 11 '[["s", "0battery"]]'
sleep 0.15
packages "$(entry 9999)"
expect "uid 9999" "${refused}" 9999 11 '[["s", "0battery"]]'
sleep 0.15
packages "$(entry 10200 1)"
expect "a debuggable helper" "${refused}" 10200 11 '[["s", "0battery"]]'
sleep 0.15
packages "$(entry 10200 0 platform:targetSdkVersion=33)"
expect "a helper that is not privileged" "${refused}" 10200 11 '[["s", "0battery"]]'
packages "$(entry 10123)"
wait_count 2 '^microos-android-bridge: helper uid 10123$' "${T}/log" \
    || fail "packages.list back was not read: $(cat "${T}/log")"
sleep 0.15
: > "${STATE}/files"
expect "a burst of refused calls" "${refused}" 10999 5 '[["i", 1]]' 0 net.seilent.microos.IBridge 1000
took=$(sed -n 's/^burst 1000 //p' "${STATE}/binder" | tail -n 1)
stats=$(count '^stat$' "${STATE}/files")
allowed=$(python3 -c "import sys; print(int(float(sys.argv[1]) * 10) + 1)" "${took:-0}")
(( stats <= allowed )) || fail "a burst of 1000 refusals in ${took} s made ${stats} stats, more than ${allowed}"
(( stats >= 1 )) || fail "a refused call did not stat packages.list"
burst=$(count '^microos-android-bridge: refused 5 from uid 10999$' "${T}/log")
all=$(count '^microos-android-bridge: refused [0-9]* from uid [0-9]*$' "${T}/log")
(( burst >= 1 && all <= 10 )) || fail "the refusal log is not capped at 10 lines: ${all}: $(cat "${T}/log")"

expect "hello" "0 [0, 0]" "${uid}" 1 '[["i", 1], ["o", "cb1"]]'
wait_line 'cb1 2 [-1, -1, "", ""]' "${STATE}/callbacks" || fail "no radios after hello: $(cat "${STATE}/callbacks")"
grep -qx "client cb1 net.seilent.microos.IBridgeCallback" "${STATE}/binder" \
    || fail "the callback client is not IBridgeCallback: $(cat "${STATE}/binder")"
expect "setRadio" "0 [0, 1]" "${uid}" 3 '[["i", 0], ["i", 1]]'
expect "setAirplane" "0 [0, 0]" "${uid}" 4 '[["i", 1]]'
expect "watchWifi" "0 [0, 1]" "${uid}" 5 '[["i", 1]]'
expect "connectWifi" "0 [0, 1, 0]" "${uid}" 6 \
    '[["s", "/org/freedesktop/NetworkManager/AccessPoint/1"], ["s", "password1"]]'
expect "watchBluetooth" "0 [0, 0]" "${uid}" 7 '[["i", 0]]'
expect "connectBluetooth" "0 [0, 1, 0]" "${uid}" 8 '[["s", "AA:BB:CC:DD:EE:01"], ["i", 1]]'
expect "pairBluetooth" "0 [0, 1, 0]" "${uid}" 9 '[["s", "AA:BB:CC:DD:EE:01"]]'
expect "answerPairing" "0 [0, 1]" "${uid}" 10 '[["i", 1], ["i", 1]]'
expect "power with a reason the bridge does not act on" "0 [0, 5]" "${uid}" 11 '[["s", "0battery"]]'
expect "a short setRadio" "${bad}" "${uid}" 3 '[["i", 0]]'
expect "setRadio radio 2" "${bad}" "${uid}" 3 '[["i", 2], ["i", 1]]'
expect "setRadio on 2" "${bad}" "${uid}" 3 '[["i", 0], ["i", 2]]'
expect "a null power reason" "${bad}" "${uid}" 11 '[["S"]]'
expect "an empty power reason" "${bad}" "${uid}" 11 '[["s", ""]]'
expect "a power reason that is not ASCII" "${bad}" "${uid}" 11 '[["s", "0useré"]]'
expect "a lone surrogate" "${bad}" "${uid}" 11 '[["s", "0\ud800"]]'
expect "a power reason of 65 units" "${bad}" "${uid}" 11 "[[\"s\", \"$(printf 'a%.0s' {1..65})\"]]"
expect "a null callback" "${bad}" "${uid}" 1 '[["i", 1], ["O"]]'
expect "hello fields swapped" "${bad}" "${uid}" 1 '[["o", "cb1"], ["i", 1]]'
expect "connectBluetooth fields swapped" "${bad}" "${uid}" 8 '[["i", 1], ["s", "AA:BB:CC:DD:EE:01"]]'
expect "a lowercase address" "${bad}" "${uid}" 9 '[["s", "aa:bb:cc:dd:ee:01"]]'
expect "a short address" "${bad}" "${uid}" 9 '[["s", "AA:BB:CC:DD:EE"]]'
expect "a 7 character password" "${bad}" "${uid}" 6 '[["s", "/x"], ["s", "1234567"]]'
expect "a 64 character password that is not hex" "${bad}" "${uid}" 6 \
    "[[\"s\", \"/x\"], [\"s\", \"$(printf 'g%.0s' {1..64})\"]]"
expect "a 64 character hex key" "0 [0, 1, 0]" "${uid}" 6 "[[\"s\", \"/x\"], [\"s\", \"$(printf 'a%.0s' {1..64})\"]]"
expect "an empty id" "${bad}" "${uid}" 6 '[["s", ""], ["s", ""]]'
expect "an id of 129 units" "${bad}" "${uid}" 6 "[[\"s\", \"$(printf 'a%.0s' {1..129})\"], [\"s\", \"\"]]"
expect "answerPairing accept 2" "${bad}" "${uid}" 10 '[["i", 1], ["i", 2]]'
expect "a handler fault" "${bad}" "${uid}" 3 '[["x"]]'
grep -qE '^microos-android-bridge: call 3 raised RuntimeError at line [0-9]+$' "${T}/log" \
    || fail "a handler fault was not logged: $(cat "${T}/log")"
expect "a wrong interface" "${bad}" "${uid}" 5 '[["i", 1]]' 0 net.seilent.microos.IOther
expect "a two way call sent oneway" "0 null" "${uid}" 5 '[["i", 1]]' 1
expect "reportVolume sent two way" "${bad}" "${uid}" 2 '[["i", 3], ["i", 15], ["i", 0]]'
n=$(count '^microos-android-bridge: call 2 from uid 10123: bad argument$' "${T}/log")
for values in '[["i", 16], ["i", 15], ["i", 0]]' '[["i", 0], ["i", 0], ["i", 0]]' '[["i", 3], ["i", 101], ["i", 0]]' \
    '[["i", 3], ["i", 15], ["i", 2]]' '[["i", 3], ["i", 15]]'; do
    expect "a malformed reportVolume ${values}" "0 null" "${uid}" 2 "${values}" 1
done
wait_count $((n + 5)) '^microos-android-bridge: call 2 from uid 10123: bad argument$' "${T}/log" \
    || fail "malformed oneway calls were not logged: $(cat "${T}/log")"
expect "an unknown code" "-74 null" "${uid}" 12 '[]'
expect "an unknown code again" "-74 null" "${uid}" 12 '[]'
[[ "$(count '^microos-android-bridge: unknown call 12 from uid 10123$' "${T}/log")" == 1 ]] \
    || fail "an unknown code was not logged once: $(cat "${T}/log")"
expect "hello version 2" "0 [0, 6]" "${uid}" 1 '[["i", 2], ["o", "cb9"]]'
grep -q "cb9" "${STATE}/binder" && fail "hello version 2 took its callback: $(cat "${STATE}/binder")"

mark
hello cb1
[[ "${reply}" == "0 [0, 0]" ]] || fail "hello before the volume cases: ${reply}"
report 7 15 0
wait_for "[5, 1]" pushes || fail "the first report did not push the muted host: $(pushes): $(cat "${T}/log")"
report 5 15 0
sleep 0.3
[[ "$(pushes)" == "[5, 1]" && -z "$(writes)" ]] || fail "a report inside the hold: $(pushes): $(writes)"
report 0 15 1
sleep 0.3
[[ -z "$(writes)" ]] || fail "the muted report wrote: $(writes)"
[[ "$(host)" == "Volume: 0.30 [MUTED]" ]] || fail "an Android start moved the host: $(host)"

mark
report 5 15 0
wait_for "set-mute 0" writes || fail "a guest unmute: $(writes): $(cat "${T}/log")"
[[ "$(host)" == "Volume: 0.30" ]] || fail "a guest unmute: the host $(host)"
report 6 15 0
wait_for "set-mute 0, set-volume 0.4000" writes || fail "a guest key up: $(writes)"
report 0 15 1
wait_for "set-mute 0, set-volume 0.4000, set-mute 1" writes || fail "a guest mute: $(writes)"
[[ "$(host)" == "Volume: 0.40 [MUTED]" ]] || fail "a guest mute: the host $(host)"
report 6 15 0
wait_for "set-mute 0, set-volume 0.4000, set-mute 1, set-mute 0" writes || fail "a guest unmute: $(writes)"
sleep 0.3
[[ -z "$(pushes)" ]] || fail "guest changes were pushed back: $(pushes)"

mark
sink a 20 0
wait_for "[3, 0]" pushes || fail "an external 0.20: $(pushes): $(cat "${T}/log")"
report 3 15 0
sleep 0.3
[[ -z "$(writes)" && "$(host)" == "Volume: 0.20" ]] || fail "an external 0.20: $(writes): $(host)"

mark
sink a 0 0
wait_for "[0, 0]" pushes || fail "an external 0.00: $(pushes)"
report 0 15 1
report 0 15 1
sleep 0.3
[[ -z "$(writes)" && "$(host)" == "Volume: 0.00" ]] || fail "an external 0.00: $(writes): $(host)"

mark
sink a 20 0
wait_for "[3, 0]" pushes || fail "an external 0.20 again: $(pushes)"
report 3 15 0
sleep 0.2
sink a 20 1
wait_for "[3, 0] [3, 1]" pushes || fail "an external mute: $(pushes)"
report 0 15 1
sleep 0.2
[[ -z "$(writes)" ]] || fail "an external mute wrote: $(writes)"

mark
sink a 40 1
wait_for "[6, 1]" pushes || fail "a host level change while muted: $(pushes): $(cat "${T}/log")"
report 0 15 1
report 6 15 0
for _ in {1..10}; do [[ "$(writes)" == "set-mute 0" ]] && break; sleep 0.05; done
[[ "$(writes)" == "set-mute 0" ]] || fail "the muted report did not end the hold: $(writes): $(cat "${T}/log")"
sleep 0.2
[[ "$(host)" == "Volume: 0.40" ]] || fail "a guest unmute after a muted level change: the host $(host)"

mark
sink a 40 1
wait_for "[6, 1]" pushes || fail "an external mute at 0.40: $(pushes)"
report 0 15 1
sleep 0.2
sink a 41 1
sleep 0.4
[[ "$(pushes)" == "[6, 1]" && -z "$(writes)" ]] || fail "a muted level change at the same index: $(pushes): $(writes)"

mark
sink b 50 0
sleep 0.2
printf 'b\n' > "${STATE}/sinks/default.tmp"
mv -f "${STATE}/sinks/default.tmp" "${STATE}/sinks/default"
wait_for "[8, 0]" pushes || fail "a default sink switch: $(pushes)"
report 8 15 0
sleep 0.3
[[ -z "$(writes)" ]] || fail "a default sink switch wrote: $(writes)"

mark
: > "${STATE}/wpctl-hang"
report 9 15 0
wait_line "hang set-volume @DEFAULT_AUDIO_SINK@ 0.6000" "${STATE}/wpctl" \
    || fail "no hung write: $(cat "${STATE}/wpctl")"
rm -f "${STATE}/wpctl-hang"
wait_log "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.6000 killed after 1 s" \
    || fail "a hung wpctl was not killed: $(cat "${T}/log")"
wait_for "[8, 0]" pushes || fail "the host after a killed write was not pushed: $(pushes)"
report 8 15 0
report 10 15 0
wait_for "set-volume 0.6667" writes || fail "the write after a killed one: $(writes): $(cat "${T}/log")"
grep -q '^equal ' "${STATE}/wpctl" && fail "a write equal at the guest index: $(cat "${STATE}/wpctl")"

runs() { wc -l < "${STATE}/clients"; }
settled=
for _ in {1..20}; do
    seen=$(runs)
    sleep 0.5
    [[ "$(runs)" == "${seen}" ]] && { settled=1; break; }
done
[[ -n "${settled}" ]] || fail "wpctl still runs 10 s after the last volume change: $(tail -n 5 "${T}/log")"
seen=$(runs)
host > /dev/null
sleep 2
[[ "$(runs)" == "$((seen + 1))" ]] \
    || fail "pw-dump client updates made $(($(runs) - seen - 1)) wpctl runs in 2 s with no volume change"
seen=$(runs)
rm -f "${STATE}/sinks/a"
for _ in {1..100}; do (( $(runs) > seen )) && break; sleep 0.05; done
sleep 1
(( $(runs) == seen + 1 )) || fail "a sink removal made $(($(runs) - seen)) wpctl runs in 1 s, want 1"

kill "$(cat "${STATE}/pw-dump.pid")"
wait_log "pw-dump exited -15: host volume changes no longer reach the guest" \
    || fail "pw-dump exiting was not logged: $(cat "${T}/log")"
call "${uid}" 5 '[["i", 0]]'
[[ "${reply}" =~ ^0\ \[[0-9] ]] || fail "a call after pw-dump exited: ${reply}"

nm_ap=/org/freedesktop/NetworkManager/AccessPoint
nm_settings=/org/freedesktop/NetworkManager/Settings
nm_device=/org/freedesktop/NetworkManager/Devices/3
airplane="${HOME}/.local/state/microos-android/radios.json"
long=$(printf 'L%.0s' {1..63})
keyboard='AA:BB:CC:DD:EE:02", "Keyboard fixture'
nm_starts=0
bluez_starts=0

start_nm() {
    nm_starts=$((nm_starts + 1))
    python3 "${T}/nm" "$1" >> "${T}/fakes.log" 2>&1 &
    nm_pid=$!
    pids+=("${nm_pid}")
    wait_count "${nm_starts}" '^ready$' "${STATE}/nm" || { echo "FAIL: fake NetworkManager did not start" >&2; exit 1; }
}

stop_nm() { kill "${nm_pid}"; wait "${nm_pid}" 2>/dev/null || true; }

start_bluez() {
    bluez_starts=$((bluez_starts + 1))
    python3 "${T}/bluez" >> "${T}/fakes.log" 2>&1 &
    bluez_pid=$!
    pids+=("${bluez_pid}")
    wait_count "${bluez_starts}" '^ready$' "${STATE}/bluez" || { echo "FAIL: fake BlueZ did not start" >&2; exit 1; }
}

stop_bluez() { kill "${bluez_pid}"; wait "${bluez_pid}" 2>/dev/null || true; }

nm_stub() {
    gdbus call --system -d org.freedesktop.NetworkManager -o /org/freedesktop/NetworkManager -m test.Stub.Set "$@" \
        > /dev/null
}

bt_stub() { gdbus call --system -d org.bluez -o /org/bluez -m test.Stub.Set "$@" > /dev/null; }

since() { tail -n +"$((cb_seen + 1))" "${STATE}/callbacks"; }

wait_cb() {
    for _ in {1..100}; do
        since | grep -qxF -- "$1" && return 0
        sleep 0.05
    done
    return 1
}

requested() {
    request=$(sed -nE 's/^0 \[0, 0, ([0-9]+)\]$/\1/p' <<< "${reply}")
    [[ -n "${request}" ]] || fail "$1: ${reply}: $(tail -n 5 "${T}/log")"
}

connect() {
    call "${uid}" 6 "[[\"s\", \"${nm_ap}/$2\"], [\"s\", \"$3\"]]"
    requested "$1"
}

pair() {
    call "${uid}" 9 '[["s", "AA:BB:CC:DD:EE:02"]]'
    requested "$1"
}

prompted() {
    prompt=
    for _ in {1..100}; do
        prompt=$(since | sed -nE "s/^$1 6 \\[([0-9]+), 0, \"${keyboard}\", 123456\\]$/\\1/p" | tail -n 1)
        [[ -n "${prompt}" ]] && return 0
        sleep 0.05
    done
    fail "$2: no prompt: $(since)"
}

reset_device() {
    nm_stub "${nm_device}" org.freedesktop.NetworkManager.Device.Wireless ActiveAccessPoint "<objectpath '/'>"
    nm_stub "${nm_device}" org.freedesktop.NetworkManager.Device State "<uint32 30>"
}

added() { grep "^add-activate ${nm_ap}/$1 " "${STATE}/nm" | tail -n 1; }

has_fields() {
    local what=$1 line=$2 field
    shift 2
    for field in "$@"; do
        [[ " ${line} " == *" ${field} "* ]] || fail "${what} lacks ${field}: ${line}"
    done
}

wait_grep() {
    for _ in {1..100}; do
        grep -qE -- "$1" "$2" && return 0
        sleep 0.05
    done
    return 1
}

hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

start_nm 1
start_bluez
mark
hello cb10
wait_cb 'cb10 2 [1, 0, "", ""]' || fail "radios after the caches came: $(since): $(cat "${T}/log")"
mark
expect "setRadio Wi-Fi off" "0 [0, 0]" "${uid}" 3 '[["i", 0], ["i", 0]]'
wait_cb 'cb10 2 [0, 0, "", ""]' || fail "Wi-Fi off did not reach radios: $(since): $(cat "${STATE}/nm")"
grep -qx "set WirelessEnabled false" "${STATE}/nm" || fail "Wi-Fi off was not set: $(cat "${STATE}/nm")"
mark
expect "setRadio Bluetooth on" "0 [0, 0]" "${uid}" 3 '[["i", 1], ["i", 1]]'
wait_cb 'cb10 2 [0, 1, "", ""]' || fail "Bluetooth on did not reach radios: $(since)"
grep -qx "set Powered true" "${STATE}/bluez" || fail "Bluetooth on was not set: $(cat "${STATE}/bluez")"
mark
nm_stub /org/freedesktop/NetworkManager org.freedesktop.NetworkManager WirelessEnabled "<true>"
bt_stub /org/bluez/hci0 org.bluez.Adapter1 Powered "<false>"
wait_cb 'cb10 2 [1, 0, "", ""]' || fail "host side flips did not reach radios: $(since)"

wifi_off=$(count '^set WirelessEnabled false$' "${STATE}/nm")
bt_off=$(count '^set Powered false$' "${STATE}/bluez")
mark
expect "airplane on" "0 [0, 0]" "${uid}" 4 '[["i", 1]]'
[[ "$(cat "${airplane}" 2>&1)" == '["wifi"]' ]] || fail "airplane on did not list Wi-Fi only: $(cat "${airplane}" 2>&1)"
[[ "$(stat -c %a "${airplane}")" == 600 ]] || fail "radios.json is not 0600: $(stat -c %a "${airplane}")"
wait_count $((wifi_off + 1)) '^set WirelessEnabled false$' "${STATE}/nm" || fail "airplane on did not turn Wi-Fi off"
wait_cb 'cb10 2 [0, 0, "", ""]' || fail "airplane on: radios $(since)"
[[ "$(count '^set Powered false$' "${STATE}/bluez")" == "${bt_off}" ]] || fail "airplane on turned off Bluetooth"
wifi_on=$(count '^set WirelessEnabled true$' "${STATE}/nm")
bt_on=$(count '^set Powered true$' "${STATE}/bluez")
mark
expect "airplane off" "0 [0, 0]" "${uid}" 4 '[["i", 0]]'
wait_count $((wifi_on + 1)) '^set WirelessEnabled true$' "${STATE}/nm" || fail "airplane off did not turn Wi-Fi on"
[[ ! -e "${airplane}" ]] || fail "airplane off kept radios.json"
wait_cb 'cb10 2 [1, 0, "", ""]' || fail "airplane off: radios $(since)"
[[ "$(count '^set Powered true$' "${STATE}/bluez")" == "${bt_on}" ]] || fail "airplane off turned Bluetooth on"

mark
expect "airplane on again" "0 [0, 0]" "${uid}" 4 '[["i", 1]]'
wait_cb 'cb10 2 [0, 0, "", ""]' || fail "airplane on again: radios $(since)"
expect "a second airplane on" "0 [0, 0]" "${uid}" 4 '[["i", 1]]'
[[ "$(cat "${airplane}" 2>&1)" == '["wifi"]' ]] || fail "a second airplane on lost the list: $(cat "${airplane}" 2>&1)"
nm_stub /org/freedesktop/NetworkManager org.freedesktop.NetworkManager WirelessEnabled "<true>"
for _ in {1..40}; do [[ -e "${airplane}" ]] || break; sleep 0.05; done
[[ ! -e "${airplane}" ]] || fail "Wi-Fi on inside airplane did not leave the list: $(cat "${airplane}")"

mark
expect "airplane on before a restart" "0 [0, 0]" "${uid}" 4 '[["i", 1]]'
wait_cb 'cb10 2 [0, 0, "", ""]' || fail "airplane on before a restart: radios $(since)"
printf '1\n' > "${STATE}/guest-airplane"
stop_bridge "a stop inside airplane"
grep -qx "unregister /net/seilent/MicroOs/BtAgent" "${STATE}/bluez" || fail "the stop did not unregister the agent"
start_bridge
wait_log "microosbridge added" || fail "the restart inside airplane: $(cat "${T}/log")"
wait_log "org.freedesktop.NetworkManager is on the bus" || fail "the restart did not load NetworkManager"
wait_log "org.bluez is on the bus" || fail "the restart did not load BlueZ"
sleep 0.3
[[ "$(cat "${airplane}" 2>&1)" == '["wifi"]' ]] \
    || fail "a restart inside airplane changed the file: $(cat "${airplane}" 2>&1)"
wifi_on=$(count '^set WirelessEnabled true$' "${STATE}/nm")
mark
hello cb11
expect "airplane off after a restart" "0 [0, 0]" "${uid}" 4 '[["i", 0]]'
wait_count $((wifi_on + 1)) '^set WirelessEnabled true$' "${STATE}/nm" || fail "airplane off after a restart"
[[ ! -e "${airplane}" ]] || fail "airplane off after a restart kept radios.json"
wait_cb 'cb11 2 [1, 0, "", ""]' || fail "airplane off after a restart: radios $(since)"

mark
scans=$(count '^scan$' "${STATE}/nm")
expect "watchWifi" "0 [0, 0]" "${uid}" 5 '[["i", 1]]'
wait_count $((scans + 1)) '^scan$' "${STATE}/nm" || fail "watchWifi did not scan: $(cat "${STATE}/nm")"
for _ in {1..100}; do since | grep -q '^cb11 3 ' && break; sleep 0.05; done
python3 - "${STATE}/callbacks" <<'PY' || fail "the Wi-Fi list: $(grep '^cb11 3 ' "${STATE}/callbacks" | tail -n 1)"
import json
import sys

rows = [line.split(" ", 2)[2] for line in open(sys.argv[1], encoding="utf-8") if line.startswith("cb11 3 ")]
base = "/org/freedesktop/NetworkManager/AccessPoint/"
want = [("2", "Homenet", 70, 1, 2), ("3", "Cafenet", 80, 0, 0), ("6", "Corpnet", 60, 2, 0), ("4", "Owenet", 40, 3, 0),
        ("5", "Saenet", 30, 1, 0), ("9", "Mixednet", 25, 1, 0), ("8", "Caf\ufffd", 20, 0, 0),
        ("10", "Wepnet", 15, 2, 0)]
want += [(str(11 + i), f"net{i:02d}", 1, 0, 0) for i in range(24)]
flat = [len(want)] + [field for ident, *rest in want for field in [base + ident] + rest]
sys.exit(0 if rows and json.loads(rows[-1]) == flat else 1)
PY

mark
connect "a saved network" 1 ""
wait_line "activate ${nm_settings}/1 ${nm_ap}/1" "${STATE}/nm" || fail "a saved network: $(cat "${STATE}/nm")"
wait_cb "cb11 5 [${request}, 0, \"\"]" || fail "a saved network: no result: $(since)"
wait_cb 'cb11 2 [1, 0, "Homenet", ""]' || fail "the connected network did not reach radios: $(since)"
reset_device
expect "a personal network with no password" "${bad}" "${uid}" 6 "[[\"s\", \"${nm_ap}/9\"], [\"s\", \"\"]]"
expect "an unknown access point" "0 [0, 3, 0]" "${uid}" 6 "[[\"s\", \"${nm_ap}/99\"], [\"s\", \"\"]]"
expect "a hidden access point" "0 [0, 3, 0]" "${uid}" 6 "[[\"s\", \"${nm_ap}/7\"], [\"s\", \"\"]]"
expect "an enterprise network" "0 [0, 5, 0]" "${uid}" 6 "[[\"s\", \"${nm_ap}/6\"], [\"s\", \"Password1\"]]"
expect "a WEP network" "0 [0, 5, 0]" "${uid}" 6 "[[\"s\", \"${nm_ap}/10\"], [\"s\", \"\"]]"

mark
connect "an open network" 3 ""
wait_cb "cb11 5 [${request}, 0, \"\"]" || fail "an open network: no result: $(since)"
line=$(added 3)
has_fields "an open network" "${line}" "connection.autoconnect=false" "connection.permissions=['user:micro:']" \
    "connection.type='802-11-wireless'" "connection.id='Cafenet'" "802-11-wireless.mode='infrastructure'" \
    "802-11-wireless.ssid=$(hex Cafenet)"
[[ "${line}" == *802-11-wireless-security* ]] && fail "an open network carries security: ${line}"
wait_grep "^update2 ${nm_settings}/3 1 .*connection.autoconnect=true" "${STATE}/nm" \
    || fail "an open network was not set to autoconnect: $(cat "${STATE}/nm")"
reset_device

mark
connect "an OWE network" 4 ""
wait_cb "cb11 5 [${request}, 0, \"\"]" || fail "an OWE network: no result: $(since)"
has_fields "an OWE network" "$(added 4)" "802-11-wireless-security.key-mgmt='owe'" "connection.autoconnect=false"
reset_device

mark
echo "4 9" > "${STATE}/nm-outcome"
connect "an SAE network with a wrong password" 5 "Password2"
wait_cb "cb11 5 [${request}, 11, \"\"]" || fail "a wrong password: no AUTH: $(since)"
has_fields "an SAE network" "$(added 5)" "802-11-wireless-security.key-mgmt='sae'" \
    "802-11-wireless-security.psk='Password2'" "802-11-wireless-security.psk-flags=0"
wait_line "delete ${nm_settings}/5" "${STATE}/nm" || fail "a wrong password kept its profile: $(cat "${STATE}/nm")"
echo 2 > "${STATE}/nm-outcome"
mark
connect "an SAE network" 5 "Password2"
wait_cb "cb11 5 [${request}, 0, \"\"]" || fail "an SAE network: no result: $(since)"
wait_grep "^update2 ${nm_settings}/6 1 .*connection.autoconnect=true" "${STATE}/nm" \
    || fail "an SAE network was not set to autoconnect: $(cat "${STATE}/nm")"
has_fields "an SAE network" "$(grep "^update2 ${nm_settings}/6 " "${STATE}/nm")" \
    "802-11-wireless-security.psk='Password2'"
reset_device

mark
connect "a PSK network" 9 "Password1"
wait_cb "cb11 5 [${request}, 0, \"\"]" || fail "a PSK network: no result: $(since)"
has_fields "a PSK network" "$(added 9)" "802-11-wireless-security.key-mgmt='wpa-psk'" \
    "802-11-wireless-security.psk='Password1'" "802-11-wireless.ssid=$(hex Mixednet)"
wait_grep "^update2 ${nm_settings}/7 1 .*802-11-wireless-security.psk='Password1'" "${STATE}/nm" \
    || fail "a PSK network did not keep its password: $(cat "${STATE}/nm")"
reset_device

flagged=no
for _ in {1..40}; do
    if python3 - "${STATE}/callbacks" <<'PY'
import json
import sys

rows = [line.split(" ", 2)[2] for line in open(sys.argv[1], encoding="utf-8") if line.startswith("cb11 3 ")]
values = json.loads(rows[-1])
flags = {values[2 + 5 * i]: values[5 + 5 * i] for i in range(values[0])}
sys.exit(0 if (flags.get("Homenet"), flags.get("Cafenet"), flags.get("Mixednet")) == (2, 6, 6) else 1)
PY
    then
        flagged=yes
        break
    fi
    sleep 0.05
done
[[ "${flagged}" == yes ]] || fail "wifiList flag 4: $(grep '^cb11 3 ' "${STATE}/callbacks" | tail -n 1)"

mark
updates=$(count "^update2 ${nm_settings}/7 " "${STATE}/nm")
connect "a user:micro: profile with a new password" 9 "Password3"
wait_cb "cb11 5 [${request}, 0, \"\"]" || fail "a new password on a user:micro: profile: no result: $(since)"
[[ "$(count "^update2 ${nm_settings}/7 " "${STATE}/nm")" == $((updates + 1)) ]] \
    || fail "a new password was not stored once: $(cat "${STATE}/nm")"
has_fields "a new password" "$(grep "^update2 ${nm_settings}/7 " "${STATE}/nm" | tail -n 1)" \
    "802-11-wireless-security.psk='Password3'" "connection.autoconnect=true"
stored=$(grep -n "^update2 ${nm_settings}/7 " "${STATE}/nm" | tail -n 1 | cut -d: -f1)
activated=$(grep -n "^activate ${nm_settings}/7 ${nm_ap}/9$" "${STATE}/nm" | tail -n 1 | cut -d: -f1)
(( ${activated:-0} > ${stored:-0} )) || fail "a new password was not followed by an activation: $(cat "${STATE}/nm")"
reset_device

mark
echo "4 9" > "${STATE}/nm-outcome"
activations=$(count "^activate ${nm_settings}/7 ${nm_ap}/9$" "${STATE}/nm")
connect "a user:micro: profile with a wrong stored password" 9 ""
wait_cb "cb11 5 [${request}, 11, \"\"]" || fail "a wrong stored password on a user:micro: profile: $(since)"
[[ "$(count "^activate ${nm_settings}/7 ${nm_ap}/9$" "${STATE}/nm")" == $((activations + 1)) ]] \
    || fail "a user:micro: profile with no password was not activated: $(cat "${STATE}/nm")"
grep -qx "delete ${nm_settings}/7" "${STATE}/nm" && fail "AUTH on a saved user:micro: profile deleted it"

mark
activations=$(count "^activate ${nm_settings}/1 ${nm_ap}/1$" "${STATE}/nm")
connect "a system profile with a password" 1 "Wrongpass1"
wait_cb "cb11 5 [${request}, 11, \"\"]" || fail "a system profile with a password: no AUTH: $(since)"
[[ "$(count "^activate ${nm_settings}/1 ${nm_ap}/1$" "${STATE}/nm")" == $((activations + 1)) ]] \
    || fail "a system profile with a password was not activated: $(cat "${STATE}/nm")"
grep -q "^update2 ${nm_settings}/1 " "${STATE}/nm" && fail "a password was written to a system profile"
echo 2 > "${STATE}/nm-outcome"

mark
echo none > "${STATE}/nm-outcome"
connect "a connect that never ends" 11 ""
expect "a second connect" "0 [0, 4, 0]" "${uid}" 6 "[[\"s\", \"${nm_ap}/12\"], [\"s\", \"\"]]"
wait_cb "cb11 5 [${request}, 12, \"\"]" || fail "a connect that never ends: no TIMEOUT: $(since)"
wait_line "delete ${nm_settings}/8" "${STATE}/nm" || fail "a timed out connect kept its profile: $(cat "${STATE}/nm")"

mark
connect "a connect before NetworkManager leaves" 13 ""
stop_nm
wait_cb "cb11 5 [${request}, 10, \"\"]" || fail "a NetworkManager drop did not fail the connect: $(since)"
: > "${STATE}/nm-slow-settings"
echo 2 > "${STATE}/nm-outcome"
start_nm 100
wait_line "get-settings ${nm_settings}/100" "${STATE}/nm" \
    || fail "the profiles were not read again: $(cat "${STATE}/nm")"
expect "a connect before the profiles are in" "0 [0, 1, 0]" "${uid}" 6 "[[\"s\", \"${nm_ap}/1\"], [\"s\", \"\"]]"
rm -f "${STATE}/nm-slow-settings"
mark
for _ in {1..40}; do
    call "${uid}" 6 "[[\"s\", \"${nm_ap}/1\"], [\"s\", \"\"]]"
    [[ "${reply}" == "0 [0, 1, 0]" ]] || break
    sleep 0.1
done
requested "a connect after the profiles are in"
wait_line "activate ${nm_settings}/100 ${nm_ap}/1" "${STATE}/nm" \
    || fail "the profile map was not rebuilt: $(cat "${STATE}/nm")"
wait_cb "cb11 5 [${request}, 0, \"\"]" || fail "a connect after NetworkManager came back: $(since)"

expect "Bluetooth on" "0 [0, 0]" "${uid}" 3 '[["i", 1], ["i", 1]]'
for _ in {1..40}; do grep -q '^cb11 4 ' "${STATE}/callbacks" && break; sleep 0.05; done
[[ "$(grep '^cb11 4 ' "${STATE}/callbacks" | tail -n 1)" == \
    "cb11 4 [2, \"AA:BB:CC:DD:EE:01\", \"Headset fixture\", 5, \"AA:BB:CC:DD:EE:03\", \"${long}\", 5]" ]] \
    || fail "the paired list: $(grep '^cb11 4 ' "${STATE}/callbacks" | tail -n 1)"
mark
expect "watchBluetooth" "0 [0, 0]" "${uid}" 7 '[["i", 1]]'
wait_line start-discovery "${STATE}/bluez" || fail "watchBluetooth did not start discovery: $(cat "${STATE}/bluez")"
wait_cb "cb11 4 [3, \"AA:BB:CC:DD:EE:01\", \"Headset fixture\", 5, \"AA:BB:CC:DD:EE:03\", \"${long}\", 5, \
\"AA:BB:CC:DD:EE:02\", \"Keyboard fixture\", 0]" || fail "the list while discovering: $(since | grep ' 4 ')"
mark
call "${uid}" 8 '[["s", "AA:BB:CC:DD:EE:01"], ["i", 1]]'
requested "connectBluetooth"
wait_line "connect AA:BB:CC:DD:EE:01" "${STATE}/bluez" || fail "connectBluetooth: $(cat "${STATE}/bluez")"
wait_cb "cb11 5 [${request}, 0, \"\"]" || fail "connectBluetooth: no result: $(since)"
for _ in {1..40}; do since | grep -qE '^cb11 2 \[1, 1, "[^"]*", "Headset fixture"\]$' && break; sleep 0.05; done
since | grep -qE '^cb11 2 \[1, 1, "[^"]*", "Headset fixture"\]$' || fail "the connected device in radios: $(since)"

mark
pair "a pair"
prompted cb11 "a pair"
expect "a second pair" "0 [0, 4, 0]" "${uid}" 9 '[["s", "AA:BB:CC:DD:EE:02"]]'
expect "answerPairing from another app" "${refused}" 10124 10 "[[\"i\", ${prompt}], [\"i\", 1]]"
expect "answerPairing" "0 [0, 0]" "${uid}" 10 "[[\"i\", ${prompt}], [\"i\", 1]]"
wait_cb "cb11 5 [${request}, 0, \"\"]" || fail "a pair: no result: $(since): $(cat "${STATE}/bluez")"
for want in "paired AA:BB:CC:DD:EE:02" "set Trusted true" "connect AA:BB:CC:DD:EE:02"; do
    grep -qxF "${want}" "${STATE}/bluez" || fail "a pair did not ${want}: $(cat "${STATE}/bluez")"
done

mark
pair "a pair left unanswered"
prompted cb11 "a pair left unanswered"
wait_cb "cb11 6 [${prompt}, 3, \"${keyboard}\", 0]" || fail "a prompt timeout: $(since)"
wait_cb "cb11 5 [${request}, 11, \"org.bluez.Error.AuthenticationRejected\"]" || fail "a prompt timeout: $(since)"

mark
pair "a pair answered no"
prompted cb11 "a pair answered no"
expect "answerPairing no" "0 [0, 0]" "${uid}" 10 "[[\"i\", ${prompt}], [\"i\", 0]]"
wait_cb "cb11 5 [${request}, 11, \"org.bluez.Error.AuthenticationRejected\"]" || fail "a pair answered no: $(since)"
expect "an answer to a closed prompt" "0 [0, 3]" "${uid}" 10 "[[\"i\", ${prompt}], [\"i\", 1]]"

mark
pair "a pair when the callback dies"
prompted cb11 "a pair when the callback dies"
stops=$(count '^stop-discovery$' "${STATE}/bluez")
rejected=$(count '^agent org.bluez.Error.Rejected$' "${STATE}/bluez")
: > "${STATE}/die/cb11"
wait_log "the helper callback died" || fail "the callback death mid prompt was not logged: $(cat "${T}/log")"
wait_count $((stops + 1)) '^stop-discovery$' "${STATE}/bluez" || fail "discovery did not stop on the callback death"
wait_count $((rejected + 1)) '^agent org.bluez.Error.Rejected$' "${STATE}/bluez" \
    || fail "the open prompt was not rejected on the callback death: $(cat "${STATE}/bluez")"

guest_calls() { tail -n +"$((g_seen + 1))" "${STATE}/guest" | paste -sd ' '; }
host_sets() { echo "$(count '^set ' "${STATE}/nm") $(count '^set ' "${STATE}/bluez")"; }

wait_radios() {
    for _ in {1..100}; do
        since | grep -qE "^$1 2 \[$2, " && return 0
        sleep 0.05
    done
    return 1
}

sync_mark() {
    mark
    g_seen=$(wc -l < "${STATE}/guest")
    sets=$(host_sets)
}

nm_stub /org/freedesktop/NetworkManager org.freedesktop.NetworkManager WirelessEnabled "<true>"
bt_stub /org/bluez/hci0 org.bluez.Adapter1 Powered "<true>"
printf '1\n' > "${STATE}/guest-airplane"
sync_mark
hello cb20
wait_radios cb20 "1, 1" || fail "the radios before the airplane syncs: $(since)"
wait_for "get disable" guest_calls \
    || fail "a guest in airplane with the host radios on: $(guest_calls): $(cat "${T}/log")"
[[ "$(cat "${STATE}/guest-airplane")" == 0 ]] || fail "the sync did not turn the guest airplane off"
wait_log "guest airplane set to 0" || fail "the sync off was not logged: $(cat "${T}/log")"
expect "the report of the sync off" "0 [0, 0]" "${uid}" 4 '[["i", 0]]'
wait_log "airplane 0 from the sync" || fail "the report of the sync off: $(tail -n 5 "${T}/log")"
sleep 0.3
[[ "$(host_sets)" == "${sets}" ]] || fail "the sync off switched host radios: $(host_sets), was ${sets}"
[[ ! -e "${airplane}" ]] || fail "the sync off wrote radios.json: $(cat "${airplane}")"

wifi_off=$(count '^set WirelessEnabled false$' "${STATE}/nm")
bt_off=$(count '^set Powered false$' "${STATE}/bluez")
printf '1\n' > "${STATE}/guest-airplane"
expect "airplane on after the sync" "0 [0, 0]" "${uid}" 4 '[["i", 1]]'
[[ "$(cat "${airplane}" 2>&1)" == '["wifi", "bluetooth"]' ]] \
    || fail "airplane on after the sync did not list both radios: $(cat "${airplane}" 2>&1)"
wait_count $((wifi_off + 1)) '^set WirelessEnabled false$' "${STATE}/nm" || fail "airplane on after the sync: Wi-Fi"
wait_count $((bt_off + 1)) '^set Powered false$' "${STATE}/bluez" || fail "airplane on after the sync: Bluetooth"
wait_radios cb20 "0, 0" || fail "airplane on after the sync: radios $(since)"
bt_stub /org/bluez/hci0 org.bluez.Adapter1 Powered "<true>"
for _ in {1..40}; do [[ "$(cat "${airplane}" 2>&1)" == '["wifi"]' ]] && break; sleep 0.05; done
[[ "$(cat "${airplane}" 2>&1)" == '["wifi"]' ]] || fail "Bluetooth on inside airplane: $(cat "${airplane}" 2>&1)"

printf '0\n' > "${STATE}/guest-airplane"
sync_mark
hello cb21
wait_for "get enable" guest_calls || fail "a guest out of airplane with the host in airplane: $(guest_calls)"
wait_log "guest airplane set to 1" || fail "the sync on was not logged: $(cat "${T}/log")"
expect "the report of the sync on" "0 [0, 0]" "${uid}" 4 '[["i", 1]]'
wait_log "airplane 1 from the sync" || fail "the report of the sync on: $(tail -n 5 "${T}/log")"
sleep 0.3
[[ "$(host_sets)" == "${sets}" ]] || fail "the sync on switched host radios: $(tail -n 2 "${STATE}/bluez")"
[[ "$(cat "${airplane}" 2>&1)" == '["wifi"]' ]] || fail "the sync on rewrote radios.json: $(cat "${airplane}" 2>&1)"

sync_mark
hello cb22
wait_for get guest_calls || fail "a guest and a host both in airplane: no read: $(guest_calls)"
sleep 0.3
[[ "$(guest_calls)" == get ]] || fail "a guest and a host both in airplane: $(guest_calls)"
[[ "$(host_sets)" == "${sets}" ]] || fail "a guest and a host both in airplane switched host radios"

wifi_on=$(count '^set WirelessEnabled true$' "${STATE}/nm")
printf '0\n' > "${STATE}/guest-airplane"
expect "airplane off after the syncs" "0 [0, 0]" "${uid}" 4 '[["i", 0]]'
wait_count $((wifi_on + 1)) '^set WirelessEnabled true$' "${STATE}/nm" || fail "airplane off after the syncs: Wi-Fi"
[[ ! -e "${airplane}" ]] || fail "airplane off after the syncs kept radios.json: $(cat "${airplane}")"
wait_radios cb22 "1, 1" || fail "airplane off after the syncs: radios $(since)"

sync_mark
hello cb23
wait_for get guest_calls || fail "a guest and a host both out of airplane: no read: $(guest_calls)"
sleep 0.3
[[ "$(guest_calls)" == get ]] || fail "a guest and a host both out of airplane: $(guest_calls)"
[[ "$(host_sets)" == "${sets}" ]] || fail "a guest and a host both out of airplane switched host radios"

printf '1\n' > "${STATE}/guest-airplane"
: > "${STATE}/guest-fails"
sync_mark
hello cb24
wait_log "the airplane sync to 0 exited 255: microos-android-guest: cannot connect to 192.0.2.2:5555" \
    || fail "a failed sync was not logged: $(cat "${T}/log")"
rm -f "${STATE}/guest-fails"
printf '0\n' > "${STATE}/guest-airplane"
plain=$(count '^microos-android-bridge: airplane 0$' "${T}/log")
expect "airplane off after a failed sync" "0 [0, 0]" "${uid}" 4 '[["i", 0]]'
wait_count $((plain + 1)) '^microos-android-bridge: airplane 0$' "${T}/log" \
    || fail "airplane off after a failed sync was taken as its report: $(tail -n 5 "${T}/log")"

hello cb12
mark
pair "a pair with no pairing page"
wait_log "RequestConfirmation rejected: no pairing page" || fail "an agent request with no watch: $(cat "${T}/log")"
wait_cb "cb12 5 [${request}, 11, \"org.bluez.Error.AuthenticationRejected\"]" || fail "a pair with no watch: $(since)"
owner=$(sed -nE 's|^register (:[0-9.]+) /net/seilent/MicroOs/BtAgent DisplayYesNo$|\1|p' "${STATE}/bluez" | tail -n 1)
out=$(gdbus call --system -d "${owner}" -o /net/seilent/MicroOs/BtAgent -m org.bluez.Agent1.RequestAuthorization \
    /org/bluez/hci0/dev_AA_BB_CC_DD_EE_02 2>&1) && fail "an agent call from another sender was accepted: ${out}"
[[ "${out}" == *org.bluez.Error.Rejected* ]] || fail "an agent call from another sender: ${out}"

mark
expect "watchBluetooth before a BlueZ drop" "0 [0, 0]" "${uid}" 7 '[["i", 1]]'
pair "a pair when BlueZ leaves"
prompted cb12 "a pair when BlueZ leaves"
registers=$(count '^register ' "${STATE}/bluez")
discoveries=$(count '^start-discovery$' "${STATE}/bluez")
stop_bluez
wait_cb "cb12 5 [${request}, 10, \"\"]" || fail "a BlueZ drop did not fail the pair: $(since)"
wait_cb "cb12 6 [${prompt}, 3, \"${keyboard}\", 0]" || fail "a BlueZ drop: no cancel: $(since)"
start_bluez
wait_count $((registers + 1)) '^register ' "${STATE}/bluez" || fail "the agent was not registered again"
wait_count $((discoveries + 1)) '^start-discovery$' "${STATE}/bluez" || fail "discovery did not start again"

: > "${STATE}/nm-hang"
: > "${STATE}/bluez-hang"
: > "${STATE}/times"
for values in '3 [["i", 0], ["i", 1]]' '3 [["i", 1], ["i", 1]]' '4 [["i", 1]]' '4 [["i", 0]]' '5 [["i", 1]]' \
    "6 [[\"s\", \"${nm_ap}/3\"], [\"s\", \"\"]]" '7 [["i", 1]]' '8 [["s", "AA:BB:CC:DD:EE:01"], ["i", 1]]' \
    '9 [["s", "AA:BB:CC:DD:EE:02"]]' '10 [["i", 99], ["i", 1]]' '11 [["s", "0battery"]]' \
    '1 [["i", 1], ["o", "cb13"]]'; do
    call "${uid}" "${values%% *}" "${values#* }"
    [[ "${reply}" =~ ^0\ \[[0-9] ]] || fail "call ${values} with D-Bus not answering: ${reply}"
done
slow=$(awk '$2 >= 100' "${STATE}/times")
[[ -z "${slow}" ]] || fail "calls that waited on D-Bus: ${slow}"
rm -f "${STATE}/nm-hang" "${STATE}/bluez-hang"
stop_nm
stop_bluez
for word in Homenet Homepass Cafenet Owenet Saenet Corpnet Mixednet Wepnet Caf net0 Password Wrongpass \
    "Headset fixture" "Keyboard fixture" AA:BB:CC EE_0 LLLL; do
    grep -qF -- "${word}" "${T}/log" && fail "the log holds ${word}: $(grep -F -- "${word}" "${T}/log")"
done

expect "power 0userrequested" "0 [0, 0]" "${uid}" 11 '[["s", "0userrequested"]]'
wait_log "power 0userrequested armed" || fail "power was not armed: $(cat "${T}/log")"
expect "a second power" "0 [0, 4]" "${uid}" 11 '[["s", "1userrequested"]]'
sleep 0.3
[[ "$(count '^Power' "${STATE}/logind")" == 0 ]] || fail "logind called before the guest went: $(cat "${STATE}/logind")"
n=$(registered)
: > "${STATE}/files"
: > "${STATE}/sm-down"
wait_line "PowerOff false" "${STATE}/logind" || fail "the presence loss did not power off: $(cat "${T}/log")"
wait_log "the guest service manager is gone" || fail "the presence loss was not logged: $(cat "${T}/log")"
rm -f "${STATE}/sm-down"
wait_count $((n + 1)) '^add microosbridge net.seilent.microos.IBridge$' "${STATE}/binder" \
    || fail "the service manager back did not add microosbridge again: $(cat "${STATE}/binder")"
(( $(count '^open$' "${STATE}/files") >= 1 )) || fail "the service manager back did not read packages.list"
[[ "$(count '^PowerOff' "${STATE}/logind")" == 1 ]] || fail "more than one PowerOff: $(cat "${STATE}/logind")"
expect "power after the service manager came back" "0 [0, 1]" "${uid}" 11 '[["s", "0battery"]]'

hello cb2
for r in 1 1RescueParty 0battery 0thermal,battery 1recovery; do
    expect "power ${r}" "0 [0, 5]" "${uid}" 11 "[[\"s\", \"${r}\"]]"
    wait_log "power ${r} not acted on" || fail "power ${r} was not logged: $(cat "${T}/log")"
done
expect "power 1userrequested" "0 [0, 0]" "${uid}" 11 '[["s", "1userrequested"]]'
n=$(registered)
: > "${STATE}/sm-down"
wait_line "Reboot false" "${STATE}/logind" || fail "the presence loss did not reboot: $(cat "${T}/log")"
rm -f "${STATE}/sm-down"
wait_count $((n + 1)) '^add microosbridge net.seilent.microos.IBridge$' "${STATE}/binder" \
    || fail "no add after a reboot"
[[ "$(count '^Power\|^Reboot' "${STATE}/logind")" == 2 ]] || fail "logind calls: $(cat "${STATE}/logind")"

hello cb3
expect "power before its deadline" "0 [0, 0]" "${uid}" 11 '[["s", "0userrequested"]]'
wait_log "power 0userrequested armed, the guest is still up after 2 s" \
    || fail "an armed power did not end at its deadline: $(cat "${T}/log")"
expect "power after its deadline" "0 [0, 0]" "${uid}" 11 '[["s", "0userrequested"]]'
: > "${STATE}/logind-fails"
n=$(registered)
: > "${STATE}/sm-down"
wait_log "PowerOff failed: org.freedesktop.DBus.Error.AccessDenied" \
    || fail "a logind error was not logged by name: $(cat "${T}/log")"
rm -f "${STATE}/sm-down" "${STATE}/logind-fails"
wait_count $((n + 1)) '^add microosbridge net.seilent.microos.IBridge$' "${STATE}/binder" \
    || fail "no add after a failure"
[[ "$(count '^Power\|^Reboot' "${STATE}/logind")" == 3 ]] || fail "logind calls: $(cat "${STATE}/logind")"

hello cb4
mark
hello cb5
wait_line 'cb5 2 [-1, -1, "", ""]' "${STATE}/callbacks" || fail "no radios to the second callback"
grep -qE '^remove handler cb4 [0-9]+$' "${STATE}/binder" || fail "the first callback kept its death handler"
report 4 15 0
for _ in {1..40}; do tail -n +"$((cb_seen + 1))" "${STATE}/callbacks" | grep -q '^cb5 1 ' && break; sleep 0.05; done
tail -n +"$((cb_seen + 1))" "${STATE}/callbacks" | grep -q '^cb5 1 ' \
    || fail "the first report after the second hello was not pushed to cb5: $(cat "${STATE}/callbacks")"
tail -n +"$((cb_seen + 1))" "${STATE}/callbacks" | grep -q '^cb4 ' \
    && fail "a callback after the second hello went to cb4: $(cat "${STATE}/callbacks")"
: > "${STATE}/die/cb4"
wait_line "die cb4" "${STATE}/binder" || fail "the fake did not kill cb4"
expect "power after the old callback died" "0 [0, 5]" "${uid}" 11 '[["s", "0battery"]]'
: > "${STATE}/die/cb5"
wait_line "die cb5" "${STATE}/binder" || fail "the fake did not kill cb5"
wait_count 2 '^microos-android-bridge: the helper callback died$' "${T}/log" \
    || fail "the current callback death was not logged: $(cat "${T}/log")"
expect "power after the current callback died" "0 [0, 1]" "${uid}" 11 '[["s", "0battery"]]'
expect "hello with a dead callback" "${bad}" "${uid}" 1 '[["i", 1], ["o", "cb5"]]'

hello cb6
expect "power before a presence loss and a stop" "0 [0, 0]" "${uid}" 11 '[["s", "1userrequested"]]'
calls=$(count '^Power\|^Reboot' "${STATE}/logind")
: > "${STATE}/sm-down"
wait_count $((calls + 1)) '^Power\|^Reboot' "${STATE}/logind" || fail "no logind call before the stop"
[[ "$(tail -n 1 "${STATE}/logind")" == "Reboot false" ]] \
    || fail "the presence loss did not reboot: $(cat "${STATE}/logind")"
calls=$((calls + 1))
stop_bridge "a stop after the presence loss"
[[ "$(count '^Power\|^Reboot' "${STATE}/logind")" == "${calls}" ]] \
    || fail "a stop after the presence loss called logind again: $(cat "${STATE}/logind")"
rm -f "${STATE}/sm-down"

start_bridge
wait_log "microosbridge added" || fail "the restart did not add microosbridge: $(cat "${T}/log")"
wait_log "helper uid 10123" || fail "the restart did not read packages.list: $(cat "${T}/log")"
hello cb7
expect "power before a stop" "0 [0, 0]" "${uid}" 11 '[["s", "0userrequested"]]'
calls=$(count '^PowerOff' "${STATE}/logind")
stop_bridge "a stop while armed"
[[ "$(count '^PowerOff' "${STATE}/logind")" == $((calls + 1)) ]] \
    || fail "a stop while armed did not power off: $(cat "${STATE}/logind")"

start_bridge
wait_log "microosbridge added" || fail "the second restart did not add microosbridge: $(cat "${T}/log")"
calls=$(count '^Power\|^Reboot' "${STATE}/logind")
stop_bridge "a stop"
[[ "$(count '^Power\|^Reboot' "${STATE}/logind")" == "${calls}" ]] || fail "a stop called logind"

grep -q '^bad ' "${STATE}/wpctl" && fail "a wpctl call with a wrong verb or sink: $(cat "${STATE}/wpctl")"
grep -q '^bad ' "${STATE}/guest" && fail "a guest call the fake does not know: $(grep '^bad ' "${STATE}/guest")"

[[ "${failures}" == 0 ]] || exit 1
echo "bridge-test: ok"
