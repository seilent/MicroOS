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
export MICROOS_BRIDGE_HOLD_MS=1000
export MICROOS_BRIDGE_POWER_S=2
export MICROOS_BRIDGE_WPCTL_S=1
export PYTHONPATH="${T}/py"
system="${HOME}/.local/share/microos-waydroid/waydroid/data/system"
mkdir -p "${STATE}/in" "${STATE}/out" "${STATE}/die" "${STATE}/sinks" "${T}/py" "${T}/bin" "${system}" \
    "${MICROOS_BINDER_DIR}"
: > "${MICROOS_BINDER_DIR}/anbox-binder"
for f in binder callbacks wpctl logind files; do : > "${STATE}/${f}"; done
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
last = None
while True:
    seen = []
    for name in sorted(os.listdir(SINKS)):
        if not name.endswith(".tmp"):
            try:
                with open(os.path.join(SINKS, name)) as handle:
                    seen.append((name, handle.read()))
            except OSError:
                pass
    if seen != last:
        last = seen
        print('[\n  { "id": 30, "type": "PipeWire:Interface:Node" }\n]', flush=True)
    time.sleep(0.02)
FAKE
chmod 0755 "${T}/bin/wpctl" "${T}/bin/pw-dump"

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
expect "setAirplane" "0 [0, 1]" "${uid}" 4 '[["i", 1]]'
expect "watchWifi" "0 [0, 1]" "${uid}" 5 '[["i", 1]]'
expect "connectWifi" "0 [0, 1, 0]" "${uid}" 6 \
    '[["s", "/org/freedesktop/NetworkManager/AccessPoint/1"], ["s", "password1"]]'
expect "watchBluetooth" "0 [0, 1]" "${uid}" 7 '[["i", 0]]'
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

kill "$(cat "${STATE}/pw-dump.pid")"
wait_log "pw-dump exited -15: host volume changes no longer reach the guest" \
    || fail "pw-dump exiting was not logged: $(cat "${T}/log")"
call "${uid}" 5 '[["i", 0]]'
[[ "${reply}" =~ ^0\ \[[0-9] ]] || fail "a call after pw-dump exited: ${reply}"

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
wait_log "the helper callback died" || fail "the current callback death was not logged: $(cat "${T}/log")"
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

[[ "${failures}" == 0 ]] || exit 1
echo "bridge-test: ok"
