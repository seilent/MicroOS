#!/usr/bin/bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/data/usr/libexec/microos"
client="${libexec}/microos-android-client"
run_script="${libexec}/microos-android-run"

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
XML = """
<node>
  <interface name="org.freedesktop.systemd1.Manager">
    <method name="StartUnit">
      <arg type="s" direction="in"/>
      <arg type="s" direction="in"/>
      <arg type="o" direction="out"/>
    </method>
    <method name="StopUnit">
      <arg type="s" direction="in"/>
      <arg type="s" direction="in"/>
      <arg type="o" direction="out"/>
    </method>
    <signal name="JobRemoved">
      <arg type="u"/>
      <arg type="o"/>
      <arg type="s"/>
      <arg type="s"/>
    </signal>
  </interface>
</node>
"""
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
jobs = {"n": 0}
states = {}


def set_unit_state(unit, value):
    states[unit] = value
    with open(os.path.join(STATE, "unit-state"), "a") as handle:
        handle.write("%s %s\n" % (unit, value))


def call(conn, sender, path, interface, name, params, invocation):
    unit, mode = params.unpack()
    jobs["n"] += 1
    job = jobs["n"]
    with open(os.path.join(STATE, "calls"), "a") as handle:
        handle.write("%s %s %s\n" % ("start" if name == "StartUnit" else "stop", unit, mode))
    if name == "StopUnit" and os.path.exists(os.path.join(STATE, "stop-error")):
        invocation.return_dbus_error("org.freedesktop.systemd1.NoSuchUnit", unit)
        return
    invocation.return_value(GLib.Variant("(o)", ("/org/freedesktop/systemd1/job/%d" % job,)))
    if name == "StopUnit":
        set_unit_state(unit, "inactive")
        try:
            with open(os.path.join(STATE, "stop-result")) as handle:
                result = handle.read().strip()
        except OSError:
            result = "done"
        delay = 0
        try:
            with open(os.path.join(STATE, "stop-delay")) as handle:
                delay = int(handle.read().strip())
        except (OSError, ValueError):
            delay = 0

        def removed_stop():
            bus.emit_signal(None, "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager", "JobRemoved",
                            GLib.Variant("(uoss)", (job, "/org/freedesktop/systemd1/job/%d" % job, unit, result)))
            return False

        GLib.timeout_add(delay, removed_stop)
        return

    try:
        with open(os.path.join(STATE, "job-result")) as handle:
            result = handle.read().strip()
    except OSError:
        result = "none"
    if result == "none":
        return
    if result == "done":
        set_unit_state(unit, "active")

    def removed():
        bus.emit_signal(None, "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager", "JobRemoved",
                        GLib.Variant("(uoss)", (job, "/org/freedesktop/systemd1/job/%d" % job, unit,
                                                "done" if result == "ready" else result)))
        return False

    try:
        with open(os.path.join(STATE, "job-delay")) as handle:
            delay = int(handle.read().strip())
    except (OSError, ValueError):
        delay = 150
    GLib.timeout_add(delay, removed)


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


def get_state(unit):
    if unit in states:
        return states[unit]
    try:
        with open(os.path.join(STATE, "unit-state")) as handle:
            for line in handle:
                name, value = line.split()
                states[name] = value
    except (OSError, ValueError):
        pass
    return states.get(unit, "inactive")


def properties(conn, sender, path, interface, name, params, invocation):
    target, prop = params.unpack()
    if target != "org.freedesktop.systemd1.Unit" or prop != "ActiveState":
        invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownProperty", prop)
        return
    unit = path.rsplit("/", 1)[-1].replace("_2d", "-").replace("_40", "@").replace("_2e", ".")
    invocation.return_value(GLib.Variant("(v)", (GLib.Variant("s", get_state(unit)),)))


node = Gio.DBusNodeInfo.new_for_xml(XML)
bus.register_object("/org/freedesktop/systemd1", node.interfaces[0], call, None, None)
unit_node = Gio.DBusNodeInfo.new_for_xml(UNIT_XML)
for unit in ("microos-android.service", "gamescope-session-plus@android.service"):
    path = "/org/freedesktop/systemd1/unit/" + unit.replace("-", "_2d").replace("@", "_40").replace(".", "_2e")
    bus.register_object(path, unit_node.interfaces[0], None, None, None)
    bus.register_object(path, unit_node.interfaces[1], None, properties, None)
Gio.bus_own_name_on_connection(bus, "org.freedesktop.systemd1", Gio.BusNameOwnerFlags.NONE, None, None)
GLib.MainLoop().run()
PY
export STATE="${T}/state"
mkdir -p "${STATE}"
: > "${STATE}/unit-state"
python3 "${T}/manager.py" "${STATE}" > "${T}/manager.log" 2>&1 &
pids+=($!)
for _ in {1..100}; do
    gdbus call --session --dest org.freedesktop.DBus --object-path / --method org.freedesktop.DBus.ListNames 2>/dev/null \
        | grep -q org.freedesktop.systemd1 && break
    sleep 0.05
done

export HOME="${T}/home"
export MICROOS_HOME="${T}/home"
export XDG_RUNTIME_DIR="${T}/xdg"
export MICROOS_RUNDIR="${T}/run"
export MICROOS_RUNTIME_DIR="${T}/xdg/microos-android"
export XDG_STATE_HOME="${T}/home/.local/state"
export MICROOS_ANDROID_STATE="${T}/home/.local/state/microos-android"
export MICROOS_ANDROID_DATA="${T}/home/.local/share/microos-android"
export MICROOS_GAPPS="${MICROOS_ANDROID_DATA}/gapps"
export MICROOS_ANDROID_RUN="${T}/bin/run-check"
export MICROOS_KEYBOARD_INSTALL="${T}/bin/keyboard"
export MICROOS_ANDROID_NO_UI=1
export MICROOS_REFUSE_WAIT=1
export MICROOS_SYSTEM_CARD="${T}/system-card"
: > "${MICROOS_SYSTEM_CARD}"
export DISPLAY=:0
export GAMESCOPE_WAYLAND_DISPLAY=gamescope-0
unset MANGOHUD_CONFIGFILE
mkdir -p "${T}/bin" "${MICROOS_RUNDIR}" "${MICROOS_RUNTIME_DIR}" "${MICROOS_ANDROID_STATE}" "${T}/xdg"

cat > "${T}/bin/run-check" <<STUB
#!/usr/bin/bash
echo "check \$*" >> "${STATE}/calls"
cat "${STATE}/check-out" 2>/dev/null || true
cat "${STATE}/check-err" >&2 2>/dev/null || true
exit "\$(cat "${STATE}/check-rc" 2>/dev/null || echo 0)"
STUB
cat > "${T}/bin/keyboard" <<STUB
#!/usr/bin/bash
echo "keyboard \$*" >> "${STATE}/calls"
exit 0
STUB
cat > "${T}/bin/keyboard-gapps" <<STUB
#!/usr/bin/bash
echo "keyboard \$*" >> "${STATE}/calls"
printf 'gapps\n' > "${MICROOS_RUNTIME_DIR}/first-boot"
exit 0
STUB
cat > "${T}/bin/microos-session-track" <<STUB
#!/usr/bin/bash
echo "track \$*" >> "${STATE}/calls"
cat "${STATE}/track-err" >&2 2>/dev/null || true
exit "\$(cat "${STATE}/track-rc" 2>/dev/null || echo 0)"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"
export MICROOS_TRACK="${T}/bin/microos-session-track"

reset() {
    rm -rf "${MICROOS_RUNTIME_DIR}" "${XDG_STATE_HOME}" "${MICROOS_GAPPS}" "${MICROOS_RUNDIR}"
    mkdir -p "${MICROOS_RUNTIME_DIR}" "${XDG_STATE_HOME}" "${MICROOS_RUNDIR}"
    chmod 700 "${XDG_STATE_HOME}"
    : > "${STATE}/calls"
    : > "${STATE}/check-out"
    : > "${STATE}/check-err"
    : > "${STATE}/track-err"
    echo 0 > "${STATE}/check-rc"
    echo none > "${STATE}/job-result"
    echo 1 > "${STATE}/track-rc"
    rm -f "${STATE}/stop-delay" "${STATE}/stop-result" "${STATE}/stop-error" "${STATE}/job-delay"
}

state_ok() {
    python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(1)
sys.exit(0 if eval(sys.argv[2]) else 1)' "${MICROOS_ANDROID_STATE}/state.json" "$1"
}

background() {
    "${client}" > "${T}/out" 2>&1 &
    client_pid=$!
    pids+=("${client_pid}")
}

stop_client() {
    kill "${client_pid}" 2>/dev/null || true
    wait "${client_pid}" 2>/dev/null || true
}

session_serial() {
    printf 'android gamescope-session-plus@android.service 4242 0\n' > "${MICROOS_RUNDIR}/session-current"
}

wait_for() {
    local pattern=$1 file=${2:-${STATE}/calls}
    for _ in {1..100}; do
        grep -q "${pattern}" "${file}" 2>/dev/null && return 0
        sleep 0.05
    done
    return 1
}

reset
background
for _ in {1..100}; do [[ -f "${MICROOS_RUNTIME_DIR}/session.env" ]] && break; sleep 0.05; done
grep -qx "DISPLAY=:0" "${MICROOS_RUNTIME_DIR}/session.env" || fail "session.env DISPLAY: $(cat "${MICROOS_RUNTIME_DIR}/session.env" 2>/dev/null)"
grep -qx "GAMESCOPE_WAYLAND_DISPLAY=gamescope-0" "${MICROOS_RUNTIME_DIR}/session.env" \
    || fail "session.env GAMESCOPE_WAYLAND_DISPLAY: $(cat "${MICROOS_RUNTIME_DIR}/session.env" 2>/dev/null)"
grep -q "^MANGOHUD_CONFIGFILE=" "${MICROOS_RUNTIME_DIR}/session.env" \
    && fail "session.env MANGOHUD_CONFIGFILE with none set: $(cat "${MICROOS_RUNTIME_DIR}/session.env")"
wait_for "^start microos-android.service replace$" || fail "StartUnit was not called: $(cat "${STATE}/calls")"
stop_client

reset
MANGOHUD_CONFIGFILE=/tmp/mangohud.Ab3dE5fG background
for _ in {1..100}; do [[ -f "${MICROOS_RUNTIME_DIR}/session.env" ]] && break; sleep 0.05; done
[[ "$(cat "${MICROOS_RUNTIME_DIR}/session.env" 2>/dev/null)" == $'DISPLAY=:0\nGAMESCOPE_WAYLAND_DISPLAY=gamescope-0\nMANGOHUD_CONFIGFILE=/tmp/mangohud.Ab3dE5fG' ]] \
    || fail "session.env MANGOHUD_CONFIGFILE: $(cat "${MICROOS_RUNTIME_DIR}/session.env" 2>/dev/null)"
stop_client

reset
MANGOHUD_CONFIGFILE=$'/tmp/mangohud.Ab3dE5fG\nMICROOS_LEPTON=/tmp/x' background
for _ in {1..100}; do [[ -f "${MICROOS_RUNTIME_DIR}/session.env" ]] && break; sleep 0.05; done
[[ "$(cat "${MICROOS_RUNTIME_DIR}/session.env" 2>/dev/null)" == $'DISPLAY=:0\nGAMESCOPE_WAYLAND_DISPLAY=gamescope-0' ]] \
    || fail "session.env took a bad MANGOHUD_CONFIGFILE: $(cat "${MICROOS_RUNTIME_DIR}/session.env" 2>/dev/null)"
stop_client

reset
GAMESCOPE_WAYLAND_DISPLAY=dir/gamescope-0 background
for _ in {1..100}; do [[ -f "${MICROOS_RUNTIME_DIR}/session.env" ]] && break; sleep 0.05; done
grep -qx "GAMESCOPE_WAYLAND_DISPLAY=dir/gamescope-0" "${MICROOS_RUNTIME_DIR}/session.env" \
    || fail "session.env GAMESCOPE_WAYLAND_DISPLAY of a nested name: $(cat "${MICROOS_RUNTIME_DIR}/session.env" 2>/dev/null)"
stop_client

for form in gamescope-0 dir/gamescope-0; do
    reset
    GAMESCOPE_WAYLAND_DISPLAY="${form}" background
    for _ in {1..100}; do [[ -f "${MICROOS_RUNTIME_DIR}/session.env" ]] && break; sleep 0.05; done
    stop_client
    mkdir -p "$(dirname "${XDG_RUNTIME_DIR}/${form}")"
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${XDG_RUNTIME_DIR}/${form}"
    cat > "${T}/bin/lepton" <<STUB
#!/usr/bin/bash
exit 1
STUB
    chmod 0755 "${T}/bin/lepton"
    rc=0
    env -i PATH="${PATH}" HOME="${HOME}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
        MICROOS_RUNTIME_DIR="${MICROOS_RUNTIME_DIR}" MICROOS_ANDROID_DATA="${MICROOS_ANDROID_DATA}" \
        MICROOS_ANDROID_CONTEXT="${T}/contexts/android" MICROOS_LEPTON="${T}/bin/lepton" \
        MICROOS_PAD_NODES="${T}/bin/pad-nodes" MICROOS_POLL_S=0.05 MICROOS_OPTS="${T}/absent-opts" \
        MICROOS_GAPPS="${T}/gapps" MICROOS_STUB_DIR="${T}/stub" MICROOS_DISPLAY_FILE="${T}/absent-display" \
        MICROOS_STEAM_PIPE="${T}/no-steam.pipe" MICROOS_SESSION_WATCH="${T}/bin/no-watch" \
        "GAMESCOPE_WAYLAND_DISPLAY=$(sed -n 's/^GAMESCOPE_WAYLAND_DISPLAY=//p' "${MICROOS_RUNTIME_DIR}/session.env")" \
        bash "${run_script}" > /dev/null 2> "${T}/run-err" || rc=$?
    [[ "${rc}" == 1 ]] || fail "the run with the client's ${form} session.env exited ${rc}"
    grep -q "no gamescope display" "${T}/run-err" && fail "the run refused the client's ${form} name: $(cat "${T}/run-err")"
    grep -q "no density" "${T}/run-err" || fail "the run with ${form} did not reach the display check: $(cat "${T}/run-err")"
    rm -f "${XDG_RUNTIME_DIR}/${form}"
done
rmdir "${XDG_RUNTIME_DIR}/dir" 2>/dev/null || true

reset
echo ready > "${STATE}/job-result"
background
for _ in {1..100}; do [[ -f "${MICROOS_RUNTIME_DIR}/ready" ]] && break; sleep 0.05; done
[[ -f "${MICROOS_RUNTIME_DIR}/ready" ]] || fail "ready: the client did not write it: $(cat "${T}/out")"
for _ in {1..100}; do [[ -f "${MICROOS_RUNTIME_DIR}/start-done" ]] && break; sleep 0.05; done
[[ -f "${MICROOS_RUNTIME_DIR}/start-done" ]] || fail "ready: start-done not written: $(cat "${T}/out")"
grep -qx "keyboard lepton-android" "${STATE}/calls" || fail "ready: the keyboard did not run: $(cat "${STATE}/calls")"
grep -q "start microos-android-gapps-setup.service" "${STATE}/calls" && fail "ready: the setup unit ran with no first boot"
state_ok 'd["last"]["result"] == "ready"' || fail "ready: state not ready: $(cat "${MICROOS_ANDROID_STATE}/state.json" 2>/dev/null)"
[[ "$(stat -c %a "${MICROOS_ANDROID_STATE}")" == 700 ]] \
    || fail "ready: the state dir is $(stat -c %a "${MICROOS_ANDROID_STATE}")"
stop_client

reset
echo ready > "${STATE}/job-result"
MICROOS_KEYBOARD_INSTALL="${T}/bin/keyboard-gapps" background
for _ in {1..100}; do grep -q "start microos-android-gapps-setup.service" "${STATE}/calls" && break; sleep 0.05; done
grep -q "start microos-android-gapps-setup.service" "${STATE}/calls" \
    || fail "a first GApps boot: the setup unit did not run: $(cat "${STATE}/calls")"
stop_client

reset
echo ready > "${STATE}/job-result"
printf 'gapps\n' > "${MICROOS_RUNTIME_DIR}/first-boot"
background
wait_for "^start " || true
stop_client
[[ ! -e "${MICROOS_RUNTIME_DIR}/first-boot" ]] || fail "the first-boot marker survived a start: $(cat "${MICROOS_RUNTIME_DIR}/first-boot")"

reset
echo 2 > "${STATE}/check-rc"
echo "no-card" > "${STATE}/check-out"
rc=0
"${client}" > "${T}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 ]] || fail "a refused check: exit ${rc}"
grep -q "^start " "${STATE}/calls" && fail "a refused check: the unit was started: $(cat "${STATE}/calls")"
grep -q "refusing: no-card" "${T}/out" || fail "a refused check: no log: $(cat "${T}/out")"
state_ok 'd["last"]["result"] == "refused" and d["last"]["reason"] == "no-card"' \
    || fail "a refused check: state not refused: $(cat "${MICROOS_ANDROID_STATE}/state.json" 2>/dev/null)"
[[ "$(grep -c '^track refuse android 4242 no-card$' "${STATE}/calls")" == 0 ]] \
    || fail "a refused check: the refusal was recorded with no session serial: $(cat "${STATE}/calls")"
[[ "$(grep -c 'refusing: no-card' "${T}/out")" == 1 ]] || fail "a refused check refused twice: $(cat "${T}/out")"

reset
echo 2 > "${STATE}/check-rc"
echo "Not A Word" > "${STATE}/check-out"
rc=0
"${client}" > "${T}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 ]] || fail "a refusal with no word: exit ${rc}"
grep -q "refusing: check-refused" "${T}/out" || fail "a refusal with no word: $(cat "${T}/out")"

reset
echo 3 > "${STATE}/check-rc"
background
wait_for "^start " || true
grep -q "the start check exited 3, taking it as can run" "${T}/out" || fail "a failing check is not open: $(cat "${T}/out")"
grep -qx "start microos-android.service replace" "${STATE}/calls" || fail "a failing check did not start: $(cat "${STATE}/calls")"
stop_client

reset
rm -rf "${MICROOS_RUNTIME_DIR}" "${MICROOS_RUNDIR}"
mkdir -p "${MICROOS_RUNTIME_DIR}"
: > "${STATE}/calls"
echo failed > "${STATE}/job-result"
rc=0
timeout 20 "${client}" > "${T}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 ]] || fail "a failed job: exit ${rc}"
grep -q "refusing: failed" "${T}/out" || fail "a failed job: $(cat "${T}/out")"

reset
echo dependency > "${STATE}/job-result"
rc=0
timeout 20 "${client}" > "${T}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 ]] || fail "a dependency failure: exit ${rc}"
grep -q "refusing: dependency" "${T}/out" || fail "a dependency failure: $(cat "${T}/out")"

reset
echo canceled > "${STATE}/job-result"
rc=0
timeout 20 "${client}" > "${T}/out" 2>&1 || rc=$?
[[ "${rc}" == 0 ]] || fail "a canceled start: exit ${rc}"
grep -q "no refusal" "${T}/out" || fail "a canceled start: not logged: $(cat "${T}/out")"
[[ ! -e "${MICROOS_ANDROID_STATE}/state.json" || "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("last", {}).get("result", ""))' "${MICROOS_ANDROID_STATE}/state.json" 2>/dev/null)" != refused ]] \
    || fail "a canceled start: a refusal was recorded"

reset
echo canceled > "${STATE}/job-result"
session_serial
background
wait_for "^start " || true
printf 'card-lost\n' > "${MICROOS_RUNTIME_DIR}/end-reason.new"
mv -T "${MICROOS_RUNTIME_DIR}/end-reason.new" "${MICROOS_RUNTIME_DIR}/end-reason"
rc=0
wait "${client_pid}" 2>/dev/null || rc=$?
[[ "${rc}" == 1 ]] || fail "a canceled start with an end reason: exit ${rc}: $(cat "${T}/out")"
grep -q "refusing: card-lost" "${T}/out" || fail "a canceled start with an end reason: $(cat "${T}/out")"
grep -q "no refusal" "${T}/out" && fail "a canceled start with an end reason: no refusal was logged as none"
[[ "$(grep -c '^track refuse android 4242 card-lost$' "${STATE}/calls")" == 1 ]] \
    || fail "a canceled start with an end reason: not recorded: $(cat "${STATE}/calls")"

reset
echo done > "${STATE}/job-result"
printf '500\n' > "${STATE}/stop-delay"
printf '900\n' > "${STATE}/job-delay"
printf 'phone-in-use\n' > "${MICROOS_RUNTIME_DIR}/end-reason"
session_serial
background
for _ in {1..100}; do [[ -f "${MICROOS_RUNTIME_DIR}/ready" ]] && break; sleep 0.05; done
[[ -f "${MICROOS_RUNTIME_DIR}/ready" ]] || fail "a stop job after a restart: not ready: $(cat "${T}/out")"
mkdir -p "${MICROOS_GAPPS}/mtg13" "${XDG_STATE_HOME}/microos-android"
echo mtg13 > "${XDG_STATE_HOME}/microos-android/activate"
for _ in {1..100}; do [[ "$(grep -c '^stop microos-android.service' "${STATE}/calls")" -ge 1 ]] && break; sleep 0.05; done
sleep 0.7
[[ "$(grep -c 'android ready' "${T}/out")" == 1 ]] \
    || fail "the stop job's JobRemoved was read as the start's: $(cat "${T}/out")"
for _ in {1..200}; do [[ "$(grep -c '^start microos-android.service' "${STATE}/calls")" -ge 2 ]] && break; sleep 0.05; done
[[ "$(grep -c '^start microos-android.service' "${STATE}/calls")" -ge 2 ]] \
    || fail "a stop job after a restart: the unit was not started again: $(cat "${STATE}/calls")"
for _ in {1..200}; do [[ "$(grep -c 'android ready' "${T}/out")" -ge 2 ]] && break; sleep 0.05; done
[[ "$(grep -c 'android ready' "${T}/out")" -ge 2 ]] || fail "a stop job after a restart: not ready again: $(cat "${T}/out")"
grep -q "phone-in-use" "${T}/out" && fail "a late stop job's end reason was read as a refusal: $(cat "${T}/out")"
grep -q "refusing:" "${T}/out" && fail "a stop job after a restart: a refusal: $(cat "${T}/out")"
stop_client

reset
echo none > "${STATE}/job-result"
echo 0 > "${STATE}/job-delay"
session_serial
stdbuf -oL "${client}" > "${T}/out" 2>&1 &
client_pid=$!
pids+=("${client_pid}")
wait_for "^start " || true
printf 'card-lost\n' > "${MICROOS_RUNTIME_DIR}/end-reason.new"
mv -T "${MICROOS_RUNTIME_DIR}/end-reason.new" "${MICROOS_RUNTIME_DIR}/end-reason"
echo canceled > "${STATE}/job-result"
for _ in {1..100}; do grep -q "refusing:" "${T}/out" 2>/dev/null && break; sleep 0.05; done
sleep 0.1
[[ "$(grep -c 'refusing: card-lost' "${T}/out")" == 1 ]] \
    || fail "a refusal and a job result together: $(cat "${T}/out")"
[[ "$(grep -c '^track refuse android 4242 card-lost$' "${STATE}/calls")" == 1 ]] \
    || fail "a refusal and a job result together: recorded $(grep -c '^track refuse' "${STATE}/calls") times: $(cat "${STATE}/calls")"
for _ in {1..100}; do kill -0 "${client_pid}" 2>/dev/null || break; sleep 0.05; done
rc=0
wait "${client_pid}" 2>/dev/null || rc=$?
[[ "${rc}" == 1 ]] || fail "a refusal and a job result together: exit ${rc}"
[[ "$(grep -c 'refusing:' "${T}/out")" == 1 ]] || fail "a refusal and a job result together: refused again: $(cat "${T}/out")"

reset
echo none > "${STATE}/job-result"
background
wait_for "^start " || true
printf 'card-lost\n' > "${MICROOS_RUNTIME_DIR}/end-reason.new"
mv "${MICROOS_RUNTIME_DIR}/end-reason.new" "${MICROOS_RUNTIME_DIR}/end-reason"
for _ in {1..100}; do grep -q "refusing:" "${T}/out" 2>/dev/null && break; sleep 0.05; done
grep -q "refusing: card-lost" "${T}/out" || fail "the end reason marker: $(cat "${T}/out")"
stop_client

reset
echo none > "${STATE}/job-result"
background
wait_for "^start " || true
echo "android exited during boot, see the boot log" > "${MICROOS_RUNTIME_DIR}/start-failed"
for _ in {1..100}; do grep -q "refusing:" "${T}/out" 2>/dev/null && break; sleep 0.05; done
grep -q "refusing: start-failed" "${T}/out" || fail "a sentence in start-failed is not a reason word: $(cat "${T}/out")"
grep -q "android exited during boot, see the boot log" "${T}/out" || fail "the run's sentence did not reach the log: $(cat "${T}/out")"
grep -q "refusing: android exited during boot" "${T}/out" \
    && fail "the run's sentence was passed as a reason: $(cat "${T}/out")"
stop_client

reset
echo none > "${STATE}/job-result"
background
wait_for "^start " || true
printf 'rc-keycodes\n' > "${MICROOS_RUNTIME_DIR}/start-failed"
for _ in {1..100}; do grep -q "refusing:" "${T}/out" 2>/dev/null && break; sleep 0.05; done
grep -q "refusing: rc-keycodes" "${T}/out" || fail "a reason word in start-failed: $(cat "${T}/out")"
stop_client

reset
mkdir -p "${MICROOS_GAPPS}/mtg11" "${XDG_STATE_HOME}/microos-android"
echo mtg11 > "${XDG_STATE_HOME}/microos-android/activate"
background
for _ in {1..100}; do [[ -e "${MICROOS_GAPPS}/current" ]] && break; sleep 0.05; done
[[ "$(readlink "${MICROOS_GAPPS}/current" 2>/dev/null)" == mtg11 ]] || fail "the activation request: not applied"
[[ ! -e "${XDG_STATE_HOME}/microos-android/activate" ]] || fail "the activation request: kept"
stop_client

reset
mkdir -p "${XDG_STATE_HOME}/microos-android"
echo mtg99 > "${XDG_STATE_HOME}/microos-android/activate"
background
wait_for "^start " || true
grep -q "which is not staged" "${T}/out" || fail "an unknown activation set: $(cat "${T}/out")"
[[ -e "${XDG_STATE_HOME}/microos-android/activate" ]] || fail "an unknown activation set: the request was dropped"
stop_client

reset
mkdir -p "${MICROOS_GAPPS}/mtg11" "${XDG_STATE_HOME}/microos-android"
echo "../../etc" > "${XDG_STATE_HOME}/microos-android/activate"
background
wait_for "^start " || true
grep -q "not a set name" "${T}/out" || fail "a path as an activation set: $(cat "${T}/out")"
[[ ! -e "${MICROOS_GAPPS}/current" ]] || fail "a path as an activation set was applied: $(readlink "${MICROOS_GAPPS}/current")"
stop_client

reset
echo ready > "${STATE}/job-result"
background
for _ in {1..100}; do [[ -f "${MICROOS_RUNTIME_DIR}/ready" ]] && break; sleep 0.05; done
mkdir -p "${MICROOS_GAPPS}/mtg12" "${XDG_STATE_HOME}/microos-android"
echo mtg12 > "${XDG_STATE_HOME}/microos-android/activate"
for _ in {1..100}; do grep -q "^stop microos-android.service replace$" "${STATE}/calls" && break; sleep 0.05; done
grep -q "^stop microos-android.service" "${STATE}/calls" || fail "a GApps activation while ready: no stop: $(cat "${STATE}/calls")"
for _ in {1..100}; do [[ "$(readlink "${MICROOS_GAPPS}/current" 2>/dev/null)" == mtg12 ]] && break; sleep 0.05; done
[[ "$(readlink "${MICROOS_GAPPS}/current" 2>/dev/null)" == mtg12 ]] || fail "a GApps activation while ready: not applied"
for _ in {1..200}; do [[ "$(grep -c '^start microos-android.service' "${STATE}/calls")" -ge 2 ]] && break; sleep 0.05; done
[[ "$(grep -c '^start microos-android.service' "${STATE}/calls")" -ge 2 ]] \
    || fail "a GApps activation while ready: the unit was not started again: $(cat "${STATE}/calls")"
[[ -f "${MICROOS_RUNTIME_DIR}/session.env" ]] || fail "a GApps activation while ready: session.env lost"
stop_client

reset
echo none > "${STATE}/job-result"
background
wait_for "^start " || true
printf 'android gamescope-session-plus@android.service 4242 0\n' > "${MICROOS_RUNDIR}/session-current"
printf 'rc-keycodes\n' > "${MICROOS_RUNTIME_DIR}/end-reason.new"
mv "${MICROOS_RUNTIME_DIR}/end-reason.new" "${MICROOS_RUNTIME_DIR}/end-reason"
for _ in {1..100}; do grep -q "refusing:" "${T}/out" 2>/dev/null && break; sleep 0.05; done
[[ "$(grep -c '^track refuse android 4242 rc-keycodes$' "${STATE}/calls")" == 1 ]] \
    || fail "a run's end reason: not routed to the tracker once: $(cat "${STATE}/calls")"
[[ "$(grep -c 'refusing: rc-keycodes' "${T}/out")" == 1 ]] || fail "a run's end reason refused twice: $(cat "${T}/out")"
stop_client

reset
echo done > "${STATE}/job-result"
background
for _ in {1..100}; do [[ -f "${MICROOS_RUNTIME_DIR}/ready" ]] && break; sleep 0.05; done
mkdir -p "${MICROOS_GAPPS}/mtg14" "${XDG_STATE_HOME}/microos-android"
echo mtg14 > "${XDG_STATE_HOME}/microos-android/activate"
: > "${STATE}/stop-error"
for _ in {1..100}; do grep -q "^stop microos-android.service" "${STATE}/calls" && break; sleep 0.05; done
grep -q "^stop microos-android.service" "${STATE}/calls" || fail "a failed stop: no stop: $(cat "${STATE}/calls")"
grep -q "StopUnit failed" "${T}/out" || fail "a failed stop: not logged: $(cat "${T}/out")"
sleep 0.6
[[ "$(grep -c '^stop microos-android.service' "${STATE}/calls")" == 1 ]] \
    || fail "a failed stop: the stop was retried: $(cat "${STATE}/calls")"
[[ "$(grep -c '^start microos-android.service' "${STATE}/calls")" == 1 ]] \
    || fail "a failed stop: Android was started again: $(cat "${STATE}/calls")"
grep -q "cannot stop microos-android.service for mtg14, Android keeps running" "${T}/out" \
    || fail "a failed stop: not reported: $(cat "${T}/out")"
printf 'card-lost\n' > "${MICROOS_RUNTIME_DIR}/end-reason.new"
mv -T "${MICROOS_RUNTIME_DIR}/end-reason.new" "${MICROOS_RUNTIME_DIR}/end-reason"
for _ in {1..100}; do grep -q "refusing:" "${T}/out" 2>/dev/null && break; sleep 0.05; done
grep -q "refusing:" "${T}/out" && fail "a failed stop: Android was not left ready: $(cat "${T}/out")"
state_ok 'd["last"]["result"] == "ready"' \
    || fail "a failed stop: state not ready: $(cat "${MICROOS_ANDROID_STATE}/state.json" 2>/dev/null)"
stop_client
rm -f "${STATE}/stop-error"
[[ -e "${XDG_STATE_HOME}/microos-android/activate" ]] || fail "a failed stop: the request was dropped"
rm -f "${XDG_STATE_HOME}/microos-android/activate"

reset
echo done > "${STATE}/job-result"
background
for _ in {1..100}; do [[ -f "${MICROOS_RUNTIME_DIR}/ready" ]] && break; sleep 0.05; done
mkdir -p "${MICROOS_GAPPS}/mtg15" "${XDG_STATE_HOME}/microos-android"
echo mtg15 > "${XDG_STATE_HOME}/microos-android/activate"
chmod 0500 "${MICROOS_GAPPS}"
for _ in {1..100}; do [[ "$(grep -c '^stop microos-android.service' "${STATE}/calls")" -ge 1 ]] && break; sleep 0.05; done
for _ in {1..200}; do [[ "$(grep -c '^start microos-android.service' "${STATE}/calls")" -ge 2 ]] && break; sleep 0.05; done
sleep 0.6
chmod 0755 "${MICROOS_GAPPS}"
grep -q "cannot activate mtg15" "${T}/out" || fail "a failed activation: not logged: $(cat "${T}/out")"
[[ "$(grep -c '^stop microos-android.service' "${STATE}/calls")" == 1 ]] \
    || fail "a failed activation: the restart looped: $(cat "${STATE}/calls")"
[[ "$(grep -c '^start microos-android.service' "${STATE}/calls")" == 2 ]] \
    || fail "a failed activation: Android was not restarted once: $(cat "${STATE}/calls")"
[[ -e "${XDG_STATE_HOME}/microos-android/activate" ]] || fail "a failed activation: the request was dropped"
stop_client

reset
mkdir -p "${MICROOS_ANDROID_STATE}"
: > "${STATE}/calls"
session_serial
cat > "${T}/refuse.py" <<'PY'
import importlib.machinery
import importlib.util
import sys

loader = importlib.machinery.SourceFileLoader("client", sys.argv[1])
spec = importlib.util.spec_from_loader("client", loader)
client = importlib.util.module_from_spec(spec)
loader.exec_module(client)


class Bus:
    def call_sync(self, *args, **kwargs):
        raise client.GLib.Error("org.freedesktop.DBus.Error.UnknownMethod", "no unit object")


class Loop:
    def __init__(self):
        self.quits = 0

    def quit(self):
        self.quits += 1


loop = Loop()
handle = client.Client(bus=Bus(), loop=loop)
handle.refuse("no-card")
handle.refuse("no-card")
print(handle.exit_code, loop.quits)
PY
rc=0
out=$(MICROOS_STATE_LOCK_WAIT=1 python3 -I "${T}/refuse.py" "${libexec}/microos-android-client" 2> "${T}/refuse-err") || rc=$?
[[ "${rc}" == 0 ]] || fail "a refused twice: exit ${rc}: $(cat "${T}/refuse-err")"
[[ "${out}" == "1 1" ]] || fail "a refused twice: exit ${out}: $(cat "${T}/refuse-err")"
[[ "$(grep -c 'refusing: no-card' "${T}/refuse-err")" == 1 ]] \
    || fail "a refused twice: refused twice: $(cat "${T}/refuse-err")"
[[ "$(grep -c '^track refuse android 4242 no-card$' "${STATE}/calls")" == 1 ]] \
    || fail "a refused twice: recorded $(grep -c '^track refuse' "${STATE}/calls") times: $(cat "${STATE}/calls")"
state_ok 'd["last"]["result"] == "refused" and d["last"]["reason"] == "no-card"' \
    || fail "a refused twice: state not refused: $(cat "${MICROOS_ANDROID_STATE}/state.json" 2>/dev/null)"

cat > "${T}/lock.py" <<'PY'
import importlib.machinery
import importlib.util
import sys
import time

loader = importlib.machinery.SourceFileLoader("client", sys.argv[1])
spec = importlib.util.spec_from_loader("client", loader)
client = importlib.util.module_from_spec(spec)
loader.exec_module(client)

start = time.monotonic()
client.update_state({"gapps.set": "mtg11"})
print(int((time.monotonic() - start) * 1000))
PY
(
    exec 9>>"${MICROOS_ANDROID_STATE}/state.json.lock"
    flock -x 9
    : > "${T}/held"
    exec sleep 20
) &
holder=$!
for _ in {1..100}; do [[ -e "${T}/held" ]] && break; sleep 0.05; done
[[ -e "${T}/held" ]] || fail "a held state lock: the holder never locked"
rc=0
out=$(MICROOS_STATE_LOCK_WAIT=1 python3 -I "${T}/lock.py" "${libexec}/microos-android-client" 2> "${T}/lock-err") || rc=$?
[[ "${rc}" == 0 ]] || fail "a held state lock: exit ${rc}: $(cat "${T}/lock-err")"
(( out >= 1000 )) || fail "a held state lock: waited ${out} ms"
grep -q "state.json.lock is held, writing anyway" "${T}/lock-err" \
    || fail "a held state lock: not logged: $(cat "${T}/lock-err")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["gapps"]["set"]=="mtg11" else 1)' \
    "${MICROOS_ANDROID_STATE}/state.json" || fail "a held state lock: the write was lost: $(cat "${MICROOS_ANDROID_STATE}/state.json")"
kill "${holder}"
wait "${holder}" 2>/dev/null || true
unset holder

cat > "${T}/track-default.py" <<'PY'
import importlib.machinery
import importlib.util
import sys

loader = importlib.machinery.SourceFileLoader("client", sys.argv[1])
spec = importlib.util.spec_from_loader("client", loader)
client = importlib.util.module_from_spec(spec)
loader.exec_module(client)

seen = []


class Result:
    returncode = 0
    stderr = b""


def run(argv, **kwargs):
    seen.append(argv)
    return Result()


client.subprocess.run = run


class Bus:
    def call_sync(self, *args, **kwargs):
        raise client.GLib.Error("org.freedesktop.DBus.Error.UnknownMethod", "no unit object")


class Loop:
    def quit(self):
        pass


handle = client.Client(bus=Bus(), loop=Loop())
handle.refuse("no-card")
print(client.TRACK)
print(repr(seen[0] if seen else []))
PY
rc=0
printf 'android gamescope-session-plus@android.service 4242 0\n' > "${MICROOS_RUNDIR}/session-current"
out=$(env -u MICROOS_TRACK python3 -I "${T}/track-default.py" "${libexec}/microos-android-client" 2> "${T}/track-default-err") || rc=$?
[[ "${rc}" == 0 ]] || fail "the default tracker path: exit ${rc}: $(cat "${T}/track-default-err")"
mapfile -t lines <<< "${out}"
[[ "${lines[0]}" == "/usr/libexec/microos/microos-session-track" ]] \
    || fail "the default tracker path is not the image's absolute path: ${lines[0]}"
[[ "${lines[1]}" == "['/usr/libexec/microos/microos-session-track', 'refuse', 'android', '4242', 'no-card']" ]] \
    || fail "a refusal with no override did not reach the tracker path: ${lines[1]}"
[[ -x "${repo}/data/usr/libexec/microos/microos-android-client" ]] || fail "the client is not executable"
grep -qx 'ExecStopPost=/usr/libexec/microos/microos-session-track stop %i' \
    "${repo}/../../system_files/usr/lib/systemd/user/gamescope-session-plus@.service.d/10-microos-track.conf" \
    || fail "the tracker is not the path under /usr/libexec/microos"
tracker="${repo}/../../system_files/usr/libexec/microos/microos-session-track"
[[ -f "${tracker}" && -x "${tracker}" ]] || fail "the default tracker path has no program in the image"

if [[ "${failures}" != 0 ]]; then
    echo "$(cat "${T}/out" 2>/dev/null | tail -20)" >&2
    exit 1
fi
echo "client-test: ok"
