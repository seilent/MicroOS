#!/usr/bin/bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/data/usr/libexec/microos"
watch="${libexec}/microos-android-session-watch"

T=$(mktemp -d)
pids=()
cleanup() {
    for p in "${pids[@]}"; do
        kill "${p}" 2>/dev/null || true
        wait "${p}" 2>/dev/null || true
    done
    rm -rf "${T}"
}
trap cleanup EXIT

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

for t in dbus-daemon python3; do
    command -v "$t" > /dev/null || { echo "FAIL: $t missing" >&2; exit 1; }
done

cat > "${T}/session.conf" <<EOF
<busconfig>
  <type>session</type>
  <listen>unix:path=${T}/session</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="*"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
EOF
dbus-daemon --config-file="${T}/session.conf" --nofork &
pids+=($!)
for _ in {1..50}; do [[ -S "${T}/session" ]] && break; sleep 0.1; done
export DBUS_SESSION_BUS_ADDRESS="unix:path=${T}/session"

cat > "${T}/manager.py" <<'PY'
import os
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

STATE = sys.argv[1]
MANAGER_XML = """
<node>
  <interface name="org.freedesktop.systemd1.Manager">
    <method name="Subscribe"/>
    <method name="StopUnit">
      <arg type="s" direction="in"/>
      <arg type="s" direction="in"/>
      <arg type="o" direction="out"/>
    </method>
  </interface>
</node>
"""
UNIT_XML = """
<node>
  <interface name="org.freedesktop.DBus.Properties">
    <method name="Get">
      <arg type="s" direction="in"/>
      <arg type="s" direction="in"/>
      <arg type="v" direction="out"/>
    </method>
  </interface>
  <interface name="org.freedesktop.systemd1.Unit">
    <property name="ActiveState" type="s" access="read"/>
  </interface>
</node>
"""
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
SESSION = "gamescope-session-plus@android.service"
CONTAINER = "microos-android.service"
seen = {"value": None}


def read_session():
    try:
        with open(os.path.join(STATE, "unit")) as handle:
            return handle.read().strip()
    except OSError:
        return "active"


def unit_path(unit):
    return "/org/freedesktop/systemd1/unit/" + unit.replace("-", "_2d").replace("@", "_40").replace(".", "_2e")


def name_of(path):
    return path.rsplit("/", 1)[-1].replace("_2d", "-").replace("_40", "@").replace("_2e", ".")


def container_state():
    try:
        with open(os.path.join(STATE, "container")) as handle:
            return handle.read().strip()
    except OSError:
        return "active"


def active(unit):
    if unit == CONTAINER:
        return container_state()
    return read_session()


def call(conn, sender, path, interface, name, params, invocation):
    if name == "Subscribe":
        with open(os.path.join(STATE, "calls"), "a") as handle:
            handle.write("subscribe\n")
        invocation.return_value(None)
        return
    unit, mode = params.unpack()
    with open(os.path.join(STATE, "calls"), "a") as handle:
        handle.write("stop %s %s\n" % (unit, mode))
    invocation.return_value(GLib.Variant("(o)", ("/org/freedesktop/systemd1/job/1",)))
    with open(os.path.join(STATE, "container"), "w") as handle:
        handle.write("inactive")


def get(conn, sender, path, interface, name, params, invocation):
    target, prop = params.unpack()
    if target != "org.freedesktop.systemd1.Unit" or prop != "ActiveState":
        invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownProperty", prop)
        return
    invocation.return_value(GLib.Variant("(v)", (GLib.Variant("s", active(name_of(path))),)))


def poll():
    state = read_session()
    if state != seen["value"]:
        seen["value"] = state
        bus.emit_signal(None, unit_path(SESSION), "org.freedesktop.DBus.Properties", "PropertiesChanged",
                        GLib.Variant("(sa{sv}as)", ("org.freedesktop.systemd1.Unit",
                                                    {"ActiveState": GLib.Variant("s", state)}, [])))
    return True


manager = Gio.DBusNodeInfo.new_for_xml(MANAGER_XML)
unit = Gio.DBusNodeInfo.new_for_xml(UNIT_XML)
bus.register_object("/org/freedesktop/systemd1", manager.interfaces[0], call, None, None)
for name in (SESSION, CONTAINER):
    bus.register_object(unit_path(name), unit.interfaces[0], get, None, None)
Gio.bus_own_name_on_connection(bus, "org.freedesktop.systemd1", Gio.BusNameOwnerFlags.NONE, None, None)
GLib.timeout_add(50, poll)
GLib.MainLoop().run()
PY
export STATE="${T}/state"
mkdir -p "${STATE}"
echo active > "${STATE}/unit"
echo active > "${STATE}/container"
python3 "${T}/manager.py" "${STATE}" > "${T}/manager.log" 2>&1 &
pids+=($!)
for _ in {1..100}; do
    gdbus call --session --dest org.freedesktop.DBus --object-path / --method org.freedesktop.DBus.ListNames 2>/dev/null \
        | grep -q org.freedesktop.systemd1 && break
    sleep 0.05
done

export XDG_RUNTIME_DIR="${T}/xdg"
mkdir -p "${XDG_RUNTIME_DIR}"
export MICROOS_WATCH_POLL_S=0.1

run_watch() {
    "${watch}" > "${T}/out" 2>&1 &
    watch_pid=$!
    pids+=("${watch_pid}")
    sleep 0.3
}

stop_watch() {
    kill "${watch_pid}" 2>/dev/null || true
    wait "${watch_pid}" 2>/dev/null || true
}

: > "${STATE}/calls"
run_watch
for _ in {1..100}; do grep -q subscribe "${STATE}/calls" && break; sleep 0.05; done
grep -qx subscribe "${STATE}/calls" || fail "the watch does not Subscribe: $(cat "${T}/out")"
sleep 0.3
grep -q "^stop " "${STATE}/calls" && fail "the watch stopped the container while the session is active: $(cat "${STATE}/calls")"
printf 'inactive\n' > "${STATE}/unit"
for _ in {1..100}; do grep -q "^stop microos-android.service replace$" "${STATE}/calls" && break; sleep 0.05; done
grep -qx "stop microos-android.service replace" "${STATE}/calls" \
    || fail "the session left active: no stop: $(cat "${STATE}/calls") $(cat "${T}/out")"
stop_watch

: > "${STATE}/calls"
echo active > "${STATE}/unit"
echo active > "${STATE}/container"
run_watch
for _ in {1..100}; do grep -q subscribe "${STATE}/calls" && break; sleep 0.05; done
printf 'failed\n' > "${STATE}/unit"
for _ in {1..100}; do grep -q "^stop " "${STATE}/calls" && break; sleep 0.05; done
grep -qx "stop microos-android.service replace" "${STATE}/calls" || fail "a failed session: no stop: $(cat "${STATE}/calls")"
stop_watch

: > "${STATE}/calls"
echo inactive > "${STATE}/unit"
echo active > "${STATE}/container"
run_watch
for _ in {1..100}; do grep -q "^stop " "${STATE}/calls" && break; sleep 0.05; done
grep -qx "stop microos-android.service replace" "${STATE}/calls" \
    || fail "a session already inactive at the start: no stop: $(cat "${STATE}/calls")"
stop_watch

: > "${STATE}/calls"
echo inactive > "${STATE}/unit"
echo active > "${STATE}/container"
mkdir -p "${T}/bin"
cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${STATE}/systemctl"
printf 'stopping\n'
STUB
chmod 0755 "${T}/bin/systemctl"
PATH="${T}/bin:${PATH}" run_watch
sleep 0.5
grep -q "^stop " "${STATE}/calls" && fail "a stopping system: a stop was requested: $(cat "${STATE}/calls") $(cat "${T}/out")"
grep -q "the system is stopping" "${T}/out" || fail "a stopping system: not logged: $(cat "${T}/out")"
grep -qx -- "--user is-system-running" "${STATE}/systemctl" || fail "a stopping system: no user manager read: $(cat "${STATE}/systemctl")"
stop_watch
rm -rf "${T}/bin"

: > "${STATE}/calls"
echo inactive > "${STATE}/unit"
echo active > "${STATE}/container"
mkdir -p "${T}/bin"
cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${STATE}/systemctl"
[[ "$1" == --user ]] || printf 'stopping\n'
STUB
chmod 0755 "${T}/bin/systemctl"
: > "${STATE}/systemctl"
PATH="${T}/bin:${PATH}" run_watch
sleep 0.5
grep -q "^stop " "${STATE}/calls" && fail "a stopping system manager: a stop was requested: $(cat "${STATE}/calls") $(cat "${T}/out")"
grep -qx -- "--user is-system-running" "${STATE}/systemctl" || fail "a stopping system manager: no user manager read: $(cat "${STATE}/systemctl")"
[[ "$(grep -c '^is-system-running$' "${STATE}/systemctl")" == 1 ]] \
    || fail "a stopping system manager: the system manager was not read: $(cat "${STATE}/systemctl")"
grep -q "the system is stopping" "${T}/out" || fail "a stopping system manager: not logged: $(cat "${T}/out")"
stop_watch
rm -rf "${T}/bin"

[[ "${failures}" == 0 ]] || exit 1
echo "session-watch-test: ok"
