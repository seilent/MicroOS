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

export STATE="${T}/state"
export HOME="${T}/home"
export MICROOS_BRIGHTNESS_HOLD_MS=1000
export MICROOS_BRIGHTNESS_QUIET_MS=600
export MICROOS_BRIGHTNESS_CALL_MS=1000
export MICROOS_WAYDROID_CFG="${T}/waydroid.cfg"
export MICROOS_BINDER_DIR="${T}/dev"
export PYTHONPATH="${T}/py"
waydroid="${HOME}/.local/share/microos-waydroid"
guest_dir="${waydroid}/waydroid/data/microos"
mkdir -p "${STATE}" "${T}/py" "${guest_dir}" "${MICROOS_BINDER_DIR}"
: > "${MICROOS_BINDER_DIR}/anbox-binder"
: > "${STATE}/binder"
: > "${STATE}/microset"

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
        record(f"watch {name}")
        self.watches.append((name, func))
        if not flag("platform-down"):
            GLib.idle_add(self.fire, name, func)
        return 1

    def get_service(self, name, func):
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
            with open(SETTING) as handle:
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

stop_microsetd() {
    kill "${msd}" 2>/dev/null || true
    wait "${msd}" 2>/dev/null || true
}

start() {
    "${bridge}" > "${T}/out" 2>&1 &
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
n=$(wc -l < "${T}/out")
guest 0
sleep 0.3
[[ -z "$(acts)" ]] || fail "a guest 0 reached microsetd: $(acts)"
[[ "$(wc -l < "${T}/out")" == "${n}" ]] || fail "a guest 0 was logged: $(cat "${T}/out")"
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

stop_bridge "a stop"

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

[[ "${failures}" == 0 ]] || exit 1
echo "brightness-test: ok"
