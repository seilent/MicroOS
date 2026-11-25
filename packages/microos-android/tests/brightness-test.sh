#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
bridge="${repo}/data/usr/libexec/microos/microos-android-brightness"

T=$(mktemp -d)
pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "${p}" 2>/dev/null || true; done
    rm -rf "${T}"
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
sed -e 's|<type>system</type>|<type>session</type>|' -e "s|${T}/system<|${T}/session<|" "${T}/system.conf" \
    > "${T}/session.conf"
dbus-daemon --config-file="${T}/session.conf" --nofork &
pids+=($!)
for _ in {1..50}; do [[ -S "${T}/session" ]] && break; sleep 0.1; done
export DBUS_SESSION_BUS_ADDRESS="unix:path=${T}/session"

export STATE="${T}/state"
export HOME="${T}/home"
export MICROOS_BRIGHTNESS_HOLD_MS=1000
export MICROOS_BRIGHTNESS_QUIET_MS=600
export MICROOS_BRIGHTNESS_CALL_MS=1000
export MICROOS_WAYDROID_CFG="${T}/waydroid.cfg"
export MICROOS_BINDER_DIR="${T}/dev"
export PYTHONPATH="${T}/py"
export MICROOS_INPUT_SYSFS="${T}/sys"
export MICROOS_INPUT_DIR="${T}/input"
export MICROOS_ANDROID_GUEST="${T}/guest"
waydroid="${HOME}/.local/share/microos-waydroid"
guest_dir="${waydroid}/waydroid/data/microos"
mkdir -p "${STATE}" "${T}/py" "${guest_dir}" "${MICROOS_BINDER_DIR}" "${MICROOS_INPUT_DIR}"
: > "${MICROOS_BINDER_DIR}/anbox-binder"
: > "${STATE}/binder"
: > "${STATE}/microset"
: > "${STATE}/ff"
: > "${STATE}/powerkey"
: > "${STATE}/guest"
while read -r event name; do
    mkdir -p "${MICROOS_INPUT_SYSFS}/${event}/device"
    printf '%s\n' "${name}" > "${MICROOS_INPUT_SYSFS}/${event}/device/name"
    : > "${MICROOS_INPUT_DIR}/${event}"
done <<'EOF'
event0 Novatek NT36523 Touchscreen
event3 aw86927-haptics
event4 aw86927-haptics
event5 aw86927
EOF
printf '25 255\n' > "${guest_dir}/vibrator"

cat > "${MICROOS_WAYDROID_CFG}" <<'EOF'
[waydroid]
binder = anbox-binder
vndbinder = anbox-vndbinder
hwbinder = anbox-hwbinder
binder_protocol = aidl3
service_manager_protocol = aidl3
EOF

cat > "${T}/py/gbinder.py" <<'FAKE'
import os

import gi

gi.require_version("GLib", "2.0")
from gi.repository import GLib

STATE = os.environ["STATE"]
SETTING = os.path.join(STATE, "setting")


def record(line):
    with open(os.path.join(STATE, "binder"), "a") as handle:
        handle.write(line + "\n")


def flag(name):
    return os.path.exists(os.path.join(STATE, name))


class ServiceManager:
    __slots__ = ("func", "list_func", "get_service_func", "watches", "lookups", "next", "up")

    def __init__(self, device, manager=None, protocol=None):
        record(f"manager {device} {manager} {protocol}")
        self.watches = []
        self.lookups = {}
        self.next = 0
        self.up = not flag("platform-down")
        GLib.timeout_add(50, self.poll)

    def poll(self):
        up = not flag("platform-down")
        if up and not self.up:
            for name, func in self.watches:
                self.fire(name, func)
        self.up = up
        return True

    def fire(self, name, func):
        record(f"registered {name}")
        func(name.encode())
        return False

    def is_present(self):
        return not flag("platform-down")

    def add_registration_handler(self, name, func):
        self.registration_func = func
        record(f"watch {name}")
        self.watches.append((name, func))
        if not flag("platform-down"):
            GLib.idle_add(self.fire, name, func)
        return 1

    def get_service(self, name, func):
        self.get_service_func = func
        self.next += 1
        self.lookups[self.next] = GLib.idle_add(self.found, self.next, name, func)
        return self.next

    def found(self, ident, name, func):
        del self.lookups[ident]
        func(Remote(name, flag("platform-down")), 0)
        return False

    def cancel(self, ident):
        record("cancel lookup")
        GLib.source_remove(self.lookups.pop(ident))


class Remote:
    def __init__(self, name, dead):
        self.name = name
        self.dead = dead

    def is_dead(self):
        return self.dead


class Request:
    def __init__(self):
        self.values = []

    def append_int32(self, value):
        self.values.append(("i", value))

    def append_string16(self, value):
        self.values.append(("s", value))


class Reader:
    def __init__(self, values):
        self.values = list(values)

    def read_int32(self):
        if not self.values:
            return False, 0
        return True, self.values.pop(0)


class Reply:
    def __init__(self, values):
        self.values = values

    def init_reader(self):
        return Reader(self.values)


class Client:
    def __init__(self, remote, interface):
        record(f"client {remote.name} {interface}")
        self.pending = {}
        self.next = 0

    def new_request(self):
        return Request()

    def transact(self, code, flags, request, reply_func, destroy_notif):
        if flag("platform-dead"):
            record(f"refused {code}")
            return 0
        if flag("platform-stall"):
            record(f"stall {code}")
        self.next += 1
        timer = GLib.timeout_add(10, self.answer, self.next, code, flags, request.values, reply_func)
        self.pending[self.next] = (timer, code, destroy_notif)
        return self.next

    def cancel(self, ident):
        timer, code, destroy_notif = self.pending.pop(ident)
        record(f"cancel {code}")
        GLib.source_remove(timer)
        destroy_notif()

    def answer(self, ident, code, flags, values, reply_func):
        if flag("platform-stall"):
            return True
        _timer, _code, destroy_notif = self.pending.pop(ident)
        if flag("platform-down"):
            reply_func(Reply([]), -32)
            destroy_notif()
            return False
        shape = [kind for kind, _ in values]
        if flags == 0 and code == 12 and shape == ["i", "s"] and values[0][1] == 1:
            record(f"get 1 {values[1][1]}")
            with open(SETTING if values[1][1] == "screen_brightness" else os.path.join(STATE, values[1][1])) as handle:
                reply_func(Reply([0, int(handle.read())]), 0)
        elif flags == 0 and code == 11 and shape == ["i", "s", "i"] and values[0][1] == 1:
            record(f"put 1 {values[1][1]} {values[2][1]}")
            with open(SETTING, "w") as handle:
                handle.write(f"{values[2][1]}\n")
            reply_func(Reply([0]), 0)
        else:
            record(f"bad {code} {flags} {values}")
            reply_func(Reply([-1]), 0)
        destroy_notif()
        return False
FAKE

cat > "${T}/ff.py" <<'FAKE'
import errno
import fcntl
import os
import runpy
import struct
import sys

STATE = os.environ["STATE"]
DEV = os.environ["MICROOS_INPUT_DIR"]
EVIOCSFF = (1 << 30) | (48 << 16) | (0x45 << 8) | 0x80
EV_FF = 0x15
FF_RUMBLE = 0x50
real_ioctl = fcntl.ioctl
real_write = os.write
ids = {}


def record(line):
    with open(os.path.join(STATE, "ff"), "a") as handle:
        handle.write(line + "\n")


def node(fd):
    try:
        path = os.readlink(f"/proc/self/fd/{fd}")
    except OSError:
        return None
    return os.path.basename(path) if os.path.dirname(path) == DEV else None


def ioctl(fd, request, arg=0, mutate=True):
    name = node(fd) if isinstance(fd, int) else None
    if name is None or request != EVIOCSFF:
        return real_ioctl(fd, request, arg, mutate)
    if os.path.exists(os.path.join(STATE, f"gone-{name}")):
        raise OSError(errno.ENODEV, os.strerror(errno.ENODEV))
    kind, eid = struct.unpack_from("<Hh", arg)
    length, = struct.unpack_from("<H", arg, 10)
    strong, weak = struct.unpack_from("<HH", arg, 16)
    if kind != FF_RUMBLE or len(arg) != 48 or weak:
        record(f"bad upload {name} {bytes(arg).hex()}")
        raise OSError(errno.EINVAL, os.strerror(errno.EINVAL))
    if eid == -1:
        eid = ids[name] = ids.get(name, -1) + 1
        struct.pack_into("<h", arg, 2, eid)
    record(f"upload {name} {eid} {length} {strong}")
    return 0


def write(fd, data):
    name = node(fd)
    if name is None:
        return real_write(fd, data)
    _sec, _usec, kind, code, value = struct.unpack("<qqHHi", data)
    record(f"play {name} {code} {value}" if kind == EV_FF else f"bad write {name} {bytes(data).hex()}")
    return len(data)


fcntl.ioctl = ioctl
os.write = write
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
FAKE

cat > "${T}/guest" <<'FAKE'
#!/usr/bin/bash
printf '%s\n' "$2" >> "${STATE}/guest"
if [[ $2 == *dumpsys* && -e ${STATE}/guest-fails ]]; then
    rm -f "${STATE}/guest-fails"
    echo "error: closed"
    exit 1
fi
[[ $2 == *dumpsys* ]] && cat "${STATE}/policy"
exit 0
FAKE
chmod +x "${T}/guest"

cat > "${T}/powerkey" <<'FAKE'
import os

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

NAME = "net.seilent.MicroOS.PowerKey"
PATH = "/net/seilent/MicroOS/PowerKey"
IFACE = "net.seilent.MicroOS.PowerKey1"
XML = f"""
<node>
  <interface name="{IFACE}">
    <method name="Blank"/>
    <method name="Restore"/>
    <signal name="ScreenChanged"><arg type="b"/></signal>
  </interface>
  <interface name="test.Stub">
    <method name="Wake"/>
  </interface>
</node>
"""
STATE = os.environ["STATE"]


def record(line):
    with open(os.path.join(STATE, "powerkey"), "a") as handle:
        handle.write(line + "\n")


def method(conn, _sender, _path, _iface, name, _params, invocation):
    if name != "Wake":
        record(name)
    conn.emit_signal(None, PATH, IFACE, "ScreenChanged", GLib.Variant("(b)", (name != "Blank",)))
    invocation.return_value(None)


bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
for info in Gio.DBusNodeInfo.new_for_xml(XML).interfaces:
    bus.register_object(PATH, info, method, None, None)
Gio.bus_own_name_on_connection(bus, NAME, Gio.BusNameOwnerFlags.NONE, lambda *_: record("ready"), None)
GLib.MainLoop().run()
FAKE

cat > "${T}/microsetd" <<'FAKE'
import os

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

NAME = "net.seilent.MicroSet"
PATH = "/net/seilent/MicroSet"
IFACE = "net.seilent.MicroSet1"
KEY = "display.brightness"
DEFAULT = 2442
XML = f"""
<node>
  <interface name="{IFACE}">
    <method name="Get"><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
    <method name="Stored"><arg type="s" direction="in"/><arg type="a{{sv}}" direction="out"/></method>
    <method name="Set"><arg type="s" direction="in"/><arg type="v" direction="in"/></method>
    <method name="Override"><arg type="s" direction="in"/><arg type="v" direction="in"/></method>
    <method name="ClearOverride"><arg type="s" direction="in"/></method>
    <signal name="Changed"><arg type="s"/><arg type="v"/></signal>
  </interface>
  <interface name="test.Stub">
    <method name="Poke"><arg type="u" direction="in"/></method>
    <method name="Emit"><arg type="v" direction="in"/></method>
  </interface>
</node>
"""
STATE = os.environ["STATE"]
STORED = os.path.join(STATE, "stored")
ECHO = os.path.join(STATE, "echo")
FAILED = "net.seilent.MicroSet1.Error.Failed"
overrides = []


def record(line):
    with open(os.path.join(STATE, "microset"), "a") as handle:
        handle.write(line + "\n")


def flag(name):
    return os.path.exists(os.path.join(STATE, name))


def stored():
    try:
        with open(STORED) as handle:
            return int(handle.read())
    except OSError:
        return None


def store(value):
    with open(STORED, "w") as handle:
        handle.write(f"{value}\n")


def value():
    if overrides:
        return overrides[-1][1]
    found = stored()
    return DEFAULT if found is None else found


def emit(conn, variant):
    conn.emit_signal(None, PATH, IFACE, "Changed", GLib.Variant("(sv)", (KEY, variant)))


def moved(conn, before):
    if value() != before:
        emit(conn, GLib.Variant("u", value()))


def drop(owner):
    overrides[:] = [entry for entry in overrides if entry[0] != owner]


def method(conn, sender, _path, iface, name, params, invocation):
    before = value()
    reply = None
    if name == "Poke":
        record(f"poke {params.get_child_value(0).get_uint32()}")
        store(params.get_child_value(0).get_uint32())
    elif name == "Emit":
        emit(conn, params.get_child_value(0).get_variant())
    elif name == "Get":
        record("get")
        reply = GLib.Variant("(v)", (GLib.Variant("u", value()),))
    elif name == "Stored":
        record("stored")
        found = stored()
        reply = GLib.Variant("(a{sv})", ({} if found is None else {KEY: GLib.Variant("u", found)},))
    elif name == "ClearOverride":
        if flag("clear-fails"):
            record("clear failed")
            invocation.return_dbus_error(FAILED, "clear fails in the stub")
            return
        record("clear")
        drop(sender)
    else:
        requested = params.get_child_value(1).get_variant()
        if requested.get_type_string() != "u":
            record(f"{name.lower()} {requested.print_(True)} refused")
            invocation.return_dbus_error("net.seilent.MicroSet1.Error.InvalidValue", f"not a valid {KEY}")
            return
        if name == "Set" and flag("set-fails"):
            record(f"set {requested.get_uint32()} failed")
            invocation.return_dbus_error(FAILED, "set fails in the stub")
            return
        record(f"{name.lower()} {requested.get_uint32()}")
        if name == "Set":
            store(requested.get_uint32())
        else:
            drop(sender)
            overrides.append((sender, requested.get_uint32()))
    moved(conn, before)
    if iface == IFACE and os.path.exists(ECHO):
        with open(ECHO) as handle:
            emit(conn, GLib.Variant("u", int(handle.read())))
        os.remove(ECHO)
    invocation.return_value(reply)


def owner_changed(conn, _sender, _path, _iface, _signal, params):
    owner, _old, new = params.unpack()
    if new or not any(entry[0] == owner for entry in overrides):
        return
    before = value()
    drop(owner)
    moved(conn, before)


bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
for info in Gio.DBusNodeInfo.new_for_xml(XML).interfaces:
    bus.register_object(PATH, info, method, None, None)
bus.signal_subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus",
                     None, Gio.DBusSignalFlags.NONE, owner_changed)
Gio.bus_own_name_on_connection(bus, NAME, Gio.BusNameOwnerFlags.NONE, lambda *_: record("ready"), None)
GLib.MainLoop().run()
FAKE

count() {
    local c
    c=$(grep -c -- "$1" "$2") || true
    echo "${c:-0}"
}

readies() { count '^ready$' "${STATE}/microset"; }

start_microsetd() {
    local ready
    ready=$(readies)
    python3 "${T}/microsetd" &
    msd=$!
    pids+=("${msd}")
    for _ in {1..50}; do (( $(readies) > ready )) && return 0; sleep 0.1; done
    echo "FAIL: fake microsetd did not start" >&2
    exit 1
}

start_powerkey() {
    local ready
    ready=$(count '^ready$' "${STATE}/powerkey")
    python3 "${T}/powerkey" &
    pk=$!
    pids+=("${pk}")
    for _ in {1..50}; do (( $(count '^ready$' "${STATE}/powerkey") > ready )) && return 0; sleep 0.1; done
    echo "FAIL: fake microos-powerkey did not start" >&2
    exit 1
}

stop_microsetd() {
    kill "${msd}" 2>/dev/null || true
    wait "${msd}" 2>/dev/null || true
}

start() {
    python3 "${T}/ff.py" "${bridge}" > "${T}/out" 2>&1 &
    bridge_pid=$!
    pids+=("${bridge_pid}")
}

stop_bridge() {
    local rc=0
    kill -TERM "${bridge_pid}"
    for _ in {1..40}; do kill -0 "${bridge_pid}" 2>/dev/null || break; sleep 0.05; done
    kill -0 "${bridge_pid}" 2>/dev/null && fail "$1: the bridge did not stop within 2 s"
    wait "${bridge_pid}" || rc=$?
    [[ "${rc}" == 0 ]] || fail "$1: exit ${rc}: $(cat "${T}/out")"
    grep -q "Traceback" "${T}/out" && fail "$1: a traceback: $(cat "${T}/out")"
    return 0
}

setting() { printf '%s\n' "$1" > "${STATE}/setting"; }

guest() {
    printf '%s\n' "$1" > "${guest_dir}/backlight.tmp"
    mv -f "${guest_dir}/backlight.tmp" "${guest_dir}/backlight"
}

poke() {
    gdbus call --system -d net.seilent.MicroSet -o /net/seilent/MicroSet -m test.Stub.Poke "$1" > /dev/null
}

emit() {
    gdbus call --system -d net.seilent.MicroSet -o /net/seilent/MicroSet -m test.Stub.Emit "$1" > /dev/null
}

host() {
    gdbus call --system -d net.seilent.MicroSet -o /net/seilent/MicroSet -m net.seilent.MicroSet1.Get \
        "'display.brightness'"
}

mark() { seen=$(wc -l < "${STATE}/microset"); }

acts() {
    tail -n +"$((seen + 1))" "${STATE}/microset" | grep -E '^(set|override|clear)( |$)' | paste -sd ',' | sed 's/,/, /g'
}

puts() { sed -n 's/^put 1 screen_brightness //p' "${STATE}/binder" | paste -sd ' '; }

vibrate() {
    printf '%s\n' "$1" > "${guest_dir}/vibrator.tmp"
    mv -f "${guest_dir}/vibrator.tmp" "${guest_dir}/vibrator"
}

ffmark() { ffseen=$(wc -l < "${STATE}/ff"); }

ffacts() { tail -n +"$((ffseen + 1))" "${STATE}/ff" | paste -sd ',' | sed 's/,/, /g'; }

pkmark() { pkseen=$(wc -l < "${STATE}/powerkey"); }

pkacts() { tail -n +"$((pkseen + 1))" "${STATE}/powerkey" | grep -vx ready | paste -sd ',' | sed 's/,/, /g'; }

gmark() { gseen=$(wc -l < "${STATE}/guest"); }

gacts() { tail -n +"$((gseen + 1))" "${STATE}/guest" | paste -sd ',' | sed 's/,/, /g'; }

wake() {
    gdbus call --session -d net.seilent.MicroOS.PowerKey -o /net/seilent/MicroOS/PowerKey -m test.Stub.Wake > /dev/null
}

gets() { count '^get 1 screen_brightness$' "${STATE}/binder"; }

failed() { count '^microos-android-brightness: IPlatform .* failed: ' "${T}/out"; }

wait_for() {
    for _ in {1..100}; do
        [[ "$("$2")" == "$1" ]] && return 0
        sleep 0.05
    done
    return 1
}

wait_gets() {
    for _ in {1..100}; do
        (( $(gets) >= $1 )) && { sleep 0.1; return 0; }
        sleep 0.05
    done
    return 1
}

wait_log() {
    for _ in {1..100}; do
        grep -qxF -- "microos-android-brightness: $1" "${T}/out" && return 0
        sleep 0.05
    done
    return 1
}

setting 100
guest 90
echo 5000 > "${STATE}/stored"
start_microsetd
start_powerkey
mark
start
wait_for "128" puts || fail "the start push: $(puts): $(cat "${T}/out")"
wait_log "display.brightness 5000 put screen_brightness 128" || fail "the start push was not logged: $(cat "${T}/out")"
grep -qx "manager ${MICROOS_BINDER_DIR}/anbox-binder aidl3 aidl3" "${STATE}/binder" \
    || fail "the service manager is not the one waydroid.cfg names: $(cat "${STATE}/binder")"
grep -qx "watch waydroidplatform" "${STATE}/binder" || fail "no registration watch: $(cat "${STATE}/binder")"
for _ in {1..40}; do grep -qx "registered waydroidplatform" "${STATE}/binder" && break; sleep 0.05; done
grep -qx "registered waydroidplatform" "${STATE}/binder" \
    || fail "the fake did not report the registered service at once: $(cat "${STATE}/binder")"
grep -qx "client waydroidplatform lineageos.waydroid.IPlatform" "${STATE}/binder" \
    || fail "the client is not IPlatform on waydroidplatform: $(cat "${STATE}/binder")"
grep -qx get "${STATE}/microset" || fail "the start did not Get: $(cat "${STATE}/microset")"
grep -qx stored "${STATE}/microset" || fail "the start did not read Stored: $(cat "${STATE}/microset")"
mkdir -p "${T}/probe"
STATE="${T}/probe" python3 - <<'PROBE' || fail "the fake ServiceManager stores a registration_func outside its slots"
import gbinder

try:
    gbinder.ServiceManager("probe").add_registration_handler("probe", print)
except AttributeError:
    pass
else:
    raise SystemExit(1)
PROBE
setting 110
guest 110
wait_for "set 4314" acts \
    || fail "a guest change during the start hold: $(acts): $(cat "${T}/out")"
[[ "$(puts)" == 128 ]] || fail "the registration at the start pushed again over a guest change: $(puts)"

mark
setting 60
guest 60
wait_for "set 2353" acts || fail "a user change: $(acts): $(cat "${T}/out")"
wait_log "guest level 60 set display.brightness 2353" || fail "a user change was not logged: $(cat "${T}/out")"
[[ "$(host)" == "(<uint32 2353>,)" ]] || fail "a user change: the host value: $(host)"
n=$(gets)
guest 60
wait_gets $((n + 1)) || fail "a repeated user level was not read"
[[ "$(acts)" == "set 2353" ]] || fail "a user level the host stores was set again: $(acts)"
[[ "$(puts)" == 128 ]] || fail "the Changed echo of a user change was put back: $(puts)"

mark
guest 20
wait_for "override 784" acts || fail "a dim: $(acts): $(cat "${T}/out")"
wait_log "guest level 20 overrides display.brightness with 784" || fail "a dim was not logged: $(cat "${T}/out")"
[[ "$(host)" == "(<uint32 784>,)" ]] || fail "a dim: the host value: $(host)"
emit "<uint32 784>"
sleep 0.3
[[ "$(puts)" == 128 ]] || fail "a Changed carrying the held override was put: $(puts)"
guest 60
wait_for "override 784, clear" acts || fail "an undim: $(acts): $(cat "${T}/out")"
wait_log "guest level 60 cleared the display.brightness override" || fail "an undim was not logged: $(cat "${T}/out")"
[[ "$(host)" == "(<uint32 2353>,)" ]] || fail "an undim: the host value: $(host)"
[[ "$(cat "${STATE}/stored")" == 2353 ]] || fail "a dim was stored: $(cat "${STATE}/stored")"
[[ "$(puts)" == 128 ]] || fail "a dim or undim was put back: $(puts)"

mark
want=""
for pair in "70 2745" "80 3137" "90 3529"; do
    guest "${pair% *}"
    want="${want:+${want}, }override ${pair#* }"
    wait_for "${want}" acts || fail "a drag to ${pair% *}: $(acts)"
done
[[ "$(cat "${STATE}/stored")" == 2353 ]] || fail "a drag value was stored: $(cat "${STATE}/stored")"
setting 90
guest 90
wait_for "${want}, set 3529, clear" acts || fail "a release: $(acts): $(cat "${T}/out")"
[[ "$(host)" == "(<uint32 3529>,)" ]] || fail "a release: the host value: $(host)"
[[ "$(cat "${STATE}/stored")" == 3529 ]] || fail "a release: the stored value: $(cat "${STATE}/stored")"

mark
guest 100
wait_for "override 3922" acts || fail "a drag before a quiet release: $(acts)"
setting 100
wait_for "override 3922, set 3922, clear" acts || fail "a release with no new guest level: $(acts): $(cat "${T}/out")"
[[ "$(host)" == "(<uint32 3922>,)" ]] || fail "a release with no new guest level: the host value: $(host)"

mark
guest 120
wait_for "override 4706" acts || fail "a drag held still: $(acts)"
n=$(gets)
wait_gets $((n + 2)) || fail "a held override was not decided again"
[[ "$(acts)" == "override 4706" ]] || fail "a drag held still past the quiet window: $(acts)"
setting 120
wait_for "override 4706, set 4706, clear" acts \
    || fail "a release after a still hold with no new guest level: $(acts): $(cat "${T}/out")"
[[ "$(puts)" == 128 ]] || fail "a drag was put back: $(puts)"

mark
n=$(gets)
poke 7500
wait_for "128 191" puts || fail "a foreign value: $(puts): $(cat "${T}/out")"
wait_log "display.brightness 7500 put screen_brightness 191" || fail "a foreign value was not logged: $(cat "${T}/out")"
guest 150
sleep 0.15
guest 191
wait_gets $((n + 2)) || fail "the end of a hold did not read the guest: $(cat "${STATE}/binder")"
[[ -z "$(acts)" ]] || fail "a foreign value came back to microsetd: $(acts)"
[[ "$(puts)" == "128 191" ]] || fail "a foreign value was put more than once: $(puts)"

poke 3000
wait_for "128 191 77" puts || fail "a foreign value: $(puts)"
poke 4000
sleep 0.3
[[ "$(puts)" == "128 191 77" ]] || fail "a foreign value during the hold was put at once: $(puts)"
guest 77
wait_for "128 191 77 102" puts || fail "a foreign value during the hold was not put once the guest reported: $(puts)"
guest 102
poke 6000
wait_for "128 191 77 102 153" puts || fail "a foreign value: $(puts)"
poke 6500
sleep 0.3
[[ "$(puts)" == "128 191 77 102 153" ]] || fail "a foreign value during the hold was put at once: $(puts)"
for _ in {1..40}; do [[ "$(puts)" == "128 191 77 102 153 166" ]] && break; sleep 0.05; done
[[ "$(puts)" == "128 191 77 102 153 166" ]] || fail "a foreign value during the hold was not put at its end: $(puts)"
n=$(gets)
guest 166
wait_gets $((n + 1)) || fail "the end of a hold did not read the guest"
n=$(gets)
poke 6510
wait_gets $((n + 1)) || fail "a foreign value at the guest level was not read"
[[ "$(puts)" == "128 191 77 102 153 166" ]] || fail "a foreign value at the guest level was put: $(puts)"
[[ -z "$(acts)" ]] || fail "foreign values came back to microsetd: $(acts)"

mark
poke 7500
wait_for "128 191 77 102 153 166 191" puts || fail "a foreign value before a guest change: $(puts)"
setting 120
guest 120
wait_for "set 4706" acts || fail "a guest change during the hold was lost: $(acts): $(cat "${T}/out")"
[[ "$(host)" == "(<uint32 4706>,)" ]] || fail "a guest change during the hold: the host value: $(host)"

mark
echo 9000 > "${STATE}/echo"
guest 50
wait_for "override 1961" acts || fail "a dim with an echo: $(acts): $(cat "${T}/out")"
sleep 0.3
[[ ! -e "${STATE}/echo" ]] || fail "the fake did not send the echo"
[[ "$(puts)" == "128 191 77 102 153 166 191" ]] || fail "a Changed before the reply of an own call was put: $(puts)"
guest 120
wait_for "override 1961, clear" acts || fail "an undim after an echo: $(acts)"

mark
guest 30
wait_for "override 1176" acts || fail "a dim before a host Set: $(acts)"
poke 6000
guest 120
wait_for "override 1176, clear" acts || fail "an undim after a host Set: $(acts)"
wait_for "128 191 77 102 153 166 191 153" puts \
    || fail "a host Set seen in the ClearOverride window was not put: $(puts)"
guest 153
[[ "$(host)" == "(<uint32 6000>,)" ]] || fail "a host Set while the override was held: the host value: $(host)"

mark
pkmark
gmark
n=$(wc -l < "${T}/out")
guest 0
wait_for "Blank" pkacts || fail "a guest 0 did not blank the panel: $(pkacts): $(cat "${T}/out")"
sleep 0.2
[[ -z "$(acts)" ]] || fail "a guest 0 reached microsetd: $(acts)"
off="microos-android-brightness: the guest screen is off, blanked the panel"
[[ "$(tail -n +"$((n + 1))" "${T}/out")" == "${off}" ]] \
    || fail "a guest 0 was not logged as the blank alone: $(cat "${T}/out")"
[[ -z "$(gacts)" ]] || fail "a guest 0 ran a guest command: $(gacts)"
for value in abc 256 12.5 -3; do
    guest "${value}"
    wait_log "guest level '${value}' in ${guest_dir}/backlight is not 1..255, ignored" \
        || fail "a guest ${value} was not logged: $(cat "${T}/out")"
done
guest 9²
wait_log "guest level '9²' in ${guest_dir}/backlight is not 1..255, ignored" \
    || fail "a guest level that is not a number was not logged: $(cat "${T}/out")"
[[ -z "$(acts)" ]] || fail "a guest level that is not a number reached microsetd: $(acts)"
grep -q "Traceback" "${T}/out" && fail "a guest level that is not a number left a traceback: $(cat "${T}/out")"

mark
: > "${STATE}/platform-stall"
guest 40
wait_for "Blank, Restore" pkacts || fail "the guest back from 0 did not restore the panel: $(pkacts)"
wait_log "the guest screen is on, restored the panel" || fail "the restore was not logged: $(cat "${T}/out")"
for _ in {1..100}; do grep -qx "stall 12" "${STATE}/binder" && break; sleep 0.05; done
grep -qx "stall 12" "${STATE}/binder" || fail "a stalled IPlatform call was not made: $(cat "${STATE}/binder")"
guest xyz
wait_log "guest level 'xyz' in ${guest_dir}/backlight is not 1..255, ignored" \
    || fail "a stalled IPlatform call blocked the loop: $(cat "${T}/out")"
wait_log "IPlatform settingsGetInt screen_brightness failed: transaction 12 timed out" \
    || fail "a stalled IPlatform call was not given up: $(cat "${T}/out")"
grep -qx "cancel 12" "${STATE}/binder" || fail "a stalled IPlatform call was not cancelled: $(cat "${STATE}/binder")"
clients=$(count '^client ' "${STATE}/binder")
rm -f "${STATE}/platform-stall"
n=$(gets)
guest 153
wait_gets $((n + 1)) || fail "a guest level after a timed out call was not read"
wait_log "IPlatform answers again" || fail "IPlatform back after a timeout was not logged: $(cat "${T}/out")"
[[ "$(count '^client ' "${STATE}/binder")" == $((clients + 1)) ]] \
    || fail "the client of a timed out call was used again: $(cat "${STATE}/binder")"
[[ -z "$(acts)" ]] || fail "a timed out call left a decision on a stale level: $(acts)"

mark
guest 30
wait_for "override 1176" acts || fail "a dim before the guest goes: $(acts)"
: > "${STATE}/platform-down"
guest 31
wait_log "IPlatform settingsGetInt screen_brightness failed: transaction 12 returned -32" \
    || fail "a failed IPlatform call was not logged: $(cat "${T}/out")"
wait_for "override 1176, clear" acts || fail "the guest going away left the override held: $(acts)"
wait_log "the guest is gone, cleared the display.brightness override" \
    || fail "the guest going away was not logged: $(cat "${T}/out")"
poke 8000
poke 8200
guest 40
sleep 0.3
[[ "$(failed)" == 2 ]] || fail "a failed IPlatform was logged more than once: $(cat "${T}/out")"
[[ "$(acts)" == "override 1176, clear" ]] || fail "a guest level with IPlatform down reached microsetd: $(acts)"
[[ "$(puts)" == "128 191 77 102 153 166 191 153" ]] || fail "a put with IPlatform down: $(puts)"
rm -f "${STATE}/platform-down"
wait_for "128 191 77 102 153 166 191 153 209" puts \
    || fail "the registration of waydroidplatform did not push the host value: $(puts): $(cat "${T}/out")"
back='^microos-android-brightness: IPlatform answers again$'
for _ in {1..100}; do [[ "$(count "${back}" "${T}/out")" == 2 ]] && break; sleep 0.05; done
[[ "$(count "${back}" "${T}/out")" == 2 ]] || fail "IPlatform back was not logged: $(cat "${T}/out")"
wait_log "display.brightness 8200 put screen_brightness 209" \
    || fail "IPlatform back: the put was not logged: $(cat "${T}/out")"
n=$(gets)
guest 209
wait_gets $((n + 1)) || fail "IPlatform back: the end of the hold did not read the guest"
[[ "$(acts)" == "override 1176, clear" ]] || fail "IPlatform back: a guest level reached microsetd: $(acts)"
[[ "$(failed)" == 2 ]] || fail "IPlatform back logged a failure again: $(cat "${T}/out")"

mark
guest 30
wait_for "override 1176" acts || fail "a dim before the remote dies: $(acts)"
: > "${STATE}/platform-down"
: > "${STATE}/platform-dead"
guest 31
wait_log "IPlatform settingsGetInt screen_brightness failed: transaction 12 did not start" \
    || fail "a refused transaction was not logged: $(cat "${T}/out")"
grep -qx "refused 12" "${STATE}/binder" || fail "the client did not refuse the call: $(cat "${STATE}/binder")"
wait_for "override 1176, clear" acts || fail "a dead remote left the override held: $(acts)"
guest 32
sleep 0.3
[[ "$(acts)" == "override 1176, clear" ]] || fail "a dead remote cleared more than once: $(acts)"
gone='^microos-android-brightness: the guest is gone, cleared the display.brightness override$'
[[ "$(count "${gone}" "${T}/out")" == 2 ]] \
    || fail "a dead remote was not logged as the guest gone: $(cat "${T}/out")"
[[ "$(failed)" == 3 ]] || fail "a dead remote logged more than one failure: $(cat "${T}/out")"
rm -f "${STATE}/platform-dead" "${STATE}/platform-down"
for _ in {1..100}; do [[ "$(count "${back}" "${T}/out")" == 3 ]] && break; sleep 0.05; done
[[ "$(count "${back}" "${T}/out")" == 3 ]] \
    || fail "IPlatform back after a dead remote was not logged: $(cat "${T}/out")"
guest 209

mark
guest 30
wait_for "override 1176" acts || fail "a dim before a microsetd restart: $(acts)"
stop_microsetd
wait_log "net.seilent.MicroSet is not on the bus" || fail "microsetd leaving the bus was not logged: $(cat "${T}/out")"
guest 35
wait_log "guest level 35 dropped: net.seilent.MicroSet is not on the bus" \
    || fail "a guest change while microsetd is away was not logged: $(cat "${T}/out")"
guest 30
sleep 0.3
[[ "$(count ' dropped: net.seilent.MicroSet is not on the bus$' "${T}/out")" == 1 ]] \
    || fail "more than one dropped guest change was logged for one absence: $(cat "${T}/out")"
mark
start_microsetd
wait_for "override 1176" acts \
    || fail "a microsetd restart did not get the held override again: $(acts): $(cat "${T}/out")"
wait_log "display.brightness override 1176 applied again" || fail "the override again was not logged: $(cat "${T}/out")"
[[ "$(host)" == "(<uint32 1176>,)" ]] || fail "a microsetd restart: the host value: $(host)"
[[ "$(puts)" == "128 191 77 102 153 166 191 153 209" ]] || fail "a microsetd restart put a level the guest has: $(puts)"
guest 209
wait_for "override 1176, clear" acts || fail "an undim after a microsetd restart: $(acts)"
[[ "$(host)" == "(<uint32 8200>,)" ]] || fail "an undim after a microsetd restart: the host value: $(host)"

mark
guest 30
wait_for "override 1176" acts || fail "a dim before a failed Set: $(acts)"
: > "${STATE}/set-fails"
setting 100
guest 100
wait_for "override 1176, set 3922 failed, clear" acts \
    || fail "a failed Set kept the override: $(acts): $(cat "${T}/out")"
grep -q '^microos-android-brightness: Set display.brightness failed: ' "${T}/out" \
    || fail "a failed Set was not logged: $(cat "${T}/out")"
rm -f "${STATE}/set-fails"
guest 100
wait_for "override 1176, set 3922 failed, clear, set 3922" acts || fail "a Set after a failed one: $(acts)"

mark
guest 30
wait_for "override 1176" acts || fail "a dim before a failed ClearOverride: $(acts)"
: > "${STATE}/clear-fails"
guest 100
wait_for "override 1176, clear failed" acts || fail "an undim with a failing ClearOverride: $(acts)"
rm -f "${STATE}/clear-fails"
for _ in {1..100}; do [[ "$(acts)" == "override 1176, clear failed"*", clear" ]] && break; sleep 0.05; done
[[ "$(acts)" == "override 1176, clear failed"*", clear" ]] \
    || fail "a failed ClearOverride was not tried again: $(acts): $(cat "${T}/out")"
[[ "$(host)" == "(<uint32 3922>,)" ]] || fail "a ClearOverride tried again: the host value: $(host)"

python3 - "${bridge}" <<'PROBE' || fail "the dim levels are not DisplayPowerController's"
import runpy
import sys

dim = runpy.run_path(sys.argv[1], run_name="probe")["dim_level"]
want = {255: 14, 127: 14, 100: 14, 24: 14, 20: 10, 12: 2, 11: 1, 2: 1, 1: 1}
sys.exit(0 if all(dim(user) == level for user, level in want.items()) else 1)
PROBE

echo 10000 > "${STATE}/screen_off_timeout"
echo "mPowerRequest=policy=DIM, useProximitySensor=false" > "${STATE}/policy"
mark
pkmark
gmark
guest 14
wait_for "override 549" acts || fail "the guest dim: $(acts): $(cat "${T}/out")"
sleep 1
[[ -z "$(pkacts)" && -z "$(gacts)" ]] || fail "the panel was blanked before the 2 s dim: $(pkacts) $(gacts)"
wait_for "Blank" pkacts || fail "the end of the guest timeout did not blank the panel: $(pkacts): $(cat "${T}/out")"
[[ "$(gacts)" == "dumpsys display | grep -m1 mPowerRequest=" ]] || fail "the dim policy was not read: $(gacts)"
grep -qx "get 1 screen_off_timeout" "${STATE}/binder" || fail "the guest timeout was not read: $(cat "${STATE}/binder")"
wait_log "the guest screen timed out, blanked the panel" || fail "the blank was not logged: $(cat "${T}/out")"
pkmark
gmark
wake
wait_for "input keyevent KEYCODE_WAKEUP 0" gacts || fail "a host wake did not wake the guest screen: $(gacts)"
wait_log "the host woke the panel, waking the guest screen" || fail "the guest wake was not logged: $(cat "${T}/out")"
guest 100
wait_for "override 549, clear" acts || fail "the undim after a host wake: $(acts)"
sleep 0.3
[[ -z "$(pkacts)" ]] || fail "the undim after a host wake called microos-powerkey: $(pkacts)"
wake
sleep 0.3
[[ "$(gacts)" == "input keyevent KEYCODE_WAKEUP 0" ]] \
    || fail "a host wake the bridge did not blank woke the guest: $(gacts)"

mark
pkmark
gmark
guest 14
sleep 1
guest 100
sleep 1.6
[[ -z "$(pkacts)" && -z "$(gacts)" ]] || fail "an undim before the end of the timeout: $(pkacts) $(gacts)"
wait_for "override 549, clear" acts || fail "an undim before the end of the timeout: $(acts)"

echo "mPowerRequest=policy=BRIGHT, useProximitySensor=false" > "${STATE}/policy"
mark
pkmark
gmark
guest 14
wait_for "dumpsys display | grep -m1 mPowerRequest=" gacts || fail "a held dim level: $(gacts)"
sleep 3.5
[[ -z "$(pkacts)" ]] || fail "a dim level the guest holds bright blanked the panel: $(pkacts)"
[[ "$(gacts)" == "dumpsys display | grep -m1 mPowerRequest=" ]] \
    || fail "a dim level the guest holds bright was read again: $(gacts)"
guest 100
wait_for "override 549, clear" acts || fail "an undim after a held dim level: $(acts)"

echo "mPowerRequest=policy=DIM, useProximitySensor=false" > "${STATE}/policy"
pkmark
gmark
: > "${STATE}/guest-fails"
guest 14
for _ in {1..200}; do [[ "$(pkacts)" == Blank ]] && break; sleep 0.05; done
[[ "$(pkacts)" == Blank ]] || fail "a timeout after a failed policy read: $(pkacts): $(cat "${T}/out")"
[[ "$(gacts)" == "dumpsys display | grep -m1 mPowerRequest=, dumpsys display | grep -m1 mPowerRequest=" ]] \
    || fail "a failed policy read was not read again: $(gacts)"
policy_failed="^microos-android-brightness: 'dumpsys display | grep -m1 mPowerRequest=' in the guest"
policy_failed+=" exited 1: error: closed$"
[[ $(count "${policy_failed}" "${T}/out") == 1 ]] || fail "a failed policy read was not logged once: $(cat "${T}/out")"
gmark
guest 100
wait_for "Blank, Restore" pkacts || fail "the guest awake while blank did not restore the panel: $(pkacts)"
restored='^microos-android-brightness: the guest screen is on, restored the panel$'
for _ in {1..100}; do [[ $(count "${restored}" "${T}/out") == 2 ]] && break; sleep 0.05; done
[[ $(count "${restored}" "${T}/out") == 2 ]] || fail "the restore was not logged: $(cat "${T}/out")"
sleep 0.3
[[ -z "$(gacts)" ]] || fail "the guest awake while blank ran $(gacts)"

for node in event3 event4; do
    grep -qx "upload ${node} 0 0 0" "${STATE}/ff" \
        || fail "the start did not upload an effect to ${node}: $(cat "${STATE}/ff")"
done
grep -qE 'event(0|5)' "${STATE}/ff" && fail "a node that is not aw86927-haptics was used: $(cat "${STATE}/ff")"
grep -q '^play ' "${STATE}/ff" && fail "the vibration in the file at the start was played: $(cat "${STATE}/ff")"
wait_log "vibrations play on ${MICROOS_INPUT_DIR}/event3 ${MICROOS_INPUT_DIR}/event4" \
    || fail "the haptics nodes were not logged: $(cat "${T}/out")"

mark
ffmark
vibrate "25 255"
wait_for "upload event3 0 25 65535, play event3 0 1, upload event4 0 25 65535, play event4 0 1" ffacts \
    || fail "a vibration: $(ffacts): $(cat "${T}/out")"
ffmark
vibrate "40 128"
wait_for "upload event3 0 40 32896, play event3 0 1, upload event4 0 40 32896, play event4 0 1" ffacts \
    || fail "a vibration at amplitude 128: $(ffacts)"
ffmark
vibrate "0 0"
wait_for "play event3 0 0, play event4 0 0" ffacts || fail "a vibration off: $(ffacts)"
ffmark
vibrate "100000 255"
wait_for "upload event3 0 65535 65535, play event3 0 1, upload event4 0 65535 65535, play event4 0 1" ffacts \
    || fail "a vibration longer than the replay field: $(ffacts)"
ffmark
vibrate "30 255"
vibrate "0 0"
for _ in {1..100}; do [[ $(ffacts) == *"play event3 0 0, play event4 0 0" ]] && break; sleep 0.05; done
[[ $(ffacts) == *"play event3 0 0, play event4 0 0" ]] \
    || fail "an off right after a vibration did not stop it: $(ffacts)"
ffmark
for value in abc "25 256" 25 "-5 10"; do
    vibrate "${value}"
    wait_log "vibration '${value}' in ${guest_dir}/vibrator is not <ms> <0..255>, ignored" \
        || fail "a vibration ${value} was not logged: $(cat "${T}/out")"
done
[[ -z $(ffacts) ]] || fail "a vibration that is not <ms> <amplitude> was played: $(ffacts)"
: > "${STATE}/gone-event4"
vibrate "25 255"
wait_for "upload event3 0 25 65535, play event3 0 1" ffacts || fail "a vibration with a node gone: $(ffacts)"
grep -q 'event4: ' "${T}/out" && fail "a node gone was logged: $(cat "${T}/out")"
rm -f "${STATE}/gone-event4"
ffmark
vibrate "25 255"
wait_for "upload event4 1 0 0, upload event3 0 25 65535, play event3 0 1, upload event4 1 25 65535, play event4 1 1" \
    ffacts || fail "a node back after it was gone: $(ffacts): $(cat "${T}/out")"
[[ $(count "^microos-android-brightness: vibrations play on " "${T}/out") == 2 ]] \
    || fail "a node back was not logged: $(cat "${T}/out")"
[[ -z "$(acts)" ]] || fail "a vibration reached microsetd: $(acts)"

pkmark
guest 0
wait_for "Blank" pkacts || fail "a guest 0 before a stop: $(pkacts)"
stop_bridge "a stop"
[[ "$(pkacts)" == "Blank, Restore" ]] || fail "a stop while blank did not restore the panel: $(pkacts)"
grep -qx "microos-android-brightness: stopping, restored the panel" "${T}/out" \
    || fail "the restore at the stop was not logged: $(cat "${T}/out")"

grep -q '^bad ' "${STATE}/binder" && fail "a transaction with a wrong code or shape: $(cat "${STATE}/binder")"
rm -rf "${waydroid:?}"
rm -f "${MICROOS_BINDER_DIR}/anbox-binder"
: > "${STATE}/platform-down"
: > "${STATE}/binder"
setting 60
mark
start
wait_log "IPlatform settingsGetInt screen_brightness failed: no ${MICROOS_BINDER_DIR}/anbox-binder" \
    || fail "a start with no binder device was not logged: $(cat "${T}/out")"
[[ ! -e "${waydroid}" ]] || fail "the bridge made $(find "${waydroid}")"
: > "${MICROOS_BINDER_DIR}/anbox-binder"
[[ "$(count '^manager ' "${STATE}/binder")" == 0 ]] || fail "a missing binder device made a service manager"
poke 5000
for _ in {1..100}; do grep -q '^manager ' "${STATE}/binder" && break; sleep 0.05; done
[[ "$(count '^manager ' "${STATE}/binder")" == 1 ]] \
    || fail "the binder device made later was not used: $(cat "${STATE}/binder")"
rm -f "${STATE}/platform-down"
wait_for 128 puts || fail "the guest coming up did not get the host value: $(puts): $(cat "${T}/out")"
[[ ! -e "${waydroid}" ]] || fail "the bridge made $(find "${waydroid}")"
mkdir -p "${guest_dir}"
guest 128
sleep 0.2
guest 20
for _ in {1..60}; do [[ "$(acts)" == "override 784" ]] && break; sleep 0.05; done
[[ "$(acts)" == "override 784" ]] || fail "a directory made after the start is not watched: $(acts): $(cat "${T}/out")"

rm -rf "${guest_dir:?}"
sleep 0.3
mkdir -p "${guest_dir}"
guest 30
for _ in {1..60}; do [[ "$(acts)" == "override 784, override 1176" ]] && break; sleep 0.05; done
[[ "$(acts)" == "override 784, override 1176" ]] \
    || fail "a directory made again is not watched: $(acts): $(cat "${T}/out")"

: > "${STATE}/platform-stall"
guest 40
for _ in {1..100}; do grep -q "^stall " "${STATE}/binder" && break; sleep 0.05; done
grep -q "^stall " "${STATE}/binder" || fail "no stalled IPlatform call before the stop: $(cat "${STATE}/binder")"
stop_bridge "a stop during a stalled IPlatform call"

grep -q '^bad ' "${STATE}/binder" && fail "a transaction with a wrong code or shape: $(cat "${STATE}/binder")"
grep -q ' refused$' "${STATE}/microset" && fail "a microsetd call with a wrong type: $(cat "${STATE}/microset")"

rm -f "${STATE}/platform-stall"
kill "${pk}"
wait "${pk}" 2>/dev/null || true
export MICROOS_INPUT_SYSFS="${T}/nosys"
mkdir -p "${MICROOS_INPUT_SYSFS}"
ffmark
start
wait_log "no aw86927-haptics input node in ${MICROOS_INPUT_SYSFS}" \
    || fail "a start with no haptics node was not logged: $(cat "${T}/out")"
vibrate "25 255"
vibrate "0 0"
sleep 0.3
[[ -z $(ffacts) ]] || fail "a vibration with no haptics node: $(ffacts)"
[[ $(count '^microos-android-brightness: no aw86927-haptics input node' "${T}/out") == 1 ]] \
    || fail "no haptics node was logged more than once: $(cat "${T}/out")"
wait_log "net.seilent.MicroOS.PowerKey is not on the user bus, the guest screen timeout leaves the panel on" \
    || fail "a start with no microos-powerkey was not logged: $(cat "${T}/out")"
guest 0
sleep 0.3
grep -q 'Blank' "${T}/out" && fail "a guest 0 with no microos-powerkey tried to blank: $(cat "${T}/out")"
pkmark
start_powerkey
wait_for "Blank" pkacts || fail "a guest 0 was not blanked once microos-powerkey came: $(pkacts): $(cat "${T}/out")"
guest 60
wait_for "Blank, Restore" pkacts || fail "the guest back after a late blank: $(pkacts)"
stop_bridge "a stop with no haptics node"
grep -q '^bad ' "${STATE}/ff" && fail "an effect or event with a wrong shape: $(cat "${STATE}/ff")"

[[ "${failures}" == 0 ]] || exit 1
echo "brightness-test: ok"
