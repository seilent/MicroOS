#!/usr/bin/bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
client="${repo}/data/usr/libexec/microos/microos-android-client"

T=$(mktemp -d)
pids=()
cleanup() {
    for p in "${pids[@]}"; do
        kill "${p}" 2>/dev/null || true
        wait "${p}" 2>/dev/null || true
    done
    rm -rf "${T:?}"
}
trap cleanup EXIT

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

for t in dbus-daemon python3 gdbus; do
    command -v "$t" > /dev/null || { echo "FAIL: $t missing" >&2; exit 1; }
done

cat > "${T}/bus.conf" <<EOF
<busconfig>
  <type>session</type>
  <listen>unix:path=${T}/bus</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="*"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
EOF
dbus-daemon --config-file="${T}/bus.conf" --nofork &
pids+=($!)
for _ in {1..50}; do [[ -S "${T}/bus" ]] && break; sleep 0.1; done
export DBUS_SESSION_BUS_ADDRESS="unix:path=${T}/bus"
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=${T}/bus"

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
    <signal name="JobRemoved">
      <arg type="u"/>
      <arg type="o"/>
      <arg type="s"/>
      <arg type="s"/>
    </signal>
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
</node>
"""
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
jobs = {"n": 0}


def read(name, fallback):
    try:
        with open(os.path.join(STATE, name)) as handle:
            return handle.read().strip()
    except OSError:
        return fallback


def call(conn, sender, path, interface, name, params, invocation):
    unit, mode = params.unpack()
    jobs["n"] += 1
    job = "/org/freedesktop/systemd1/job/%d" % jobs["n"]
    with open(os.path.join(STATE, "calls"), "a") as handle:
        handle.write("start %s %s\n" % (unit, mode))
    invocation.return_value(GLib.Variant("(o)", (job,)))
    if unit != "microos-android.service":
        return
    result = read("job-result", "done")
    if result == "done":
        with open(os.path.join(STATE, "unit-state"), "w") as handle:
            handle.write("active\n")
        Gio.bus_own_name_on_connection(bus, "id.waydro.Session", Gio.BusNameOwnerFlags.NONE, None, None)

    def removed():
        bus.emit_signal(None, "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager", "JobRemoved",
                        GLib.Variant("(uoss)", (jobs["n"], job, unit, result)))
        return False

    GLib.timeout_add(100, removed)


def properties(conn, sender, path, interface, name, params, invocation):
    unit = path.rsplit("/", 1)[-1].replace("_2d", "-").replace("_40", "@").replace("_2e", ".")
    value = read("unit-state", "inactive") if unit == "microos-android.service" else read("session-state", "active")
    invocation.return_value(GLib.Variant("(v)", (GLib.Variant("s", value),)))


node = Gio.DBusNodeInfo.new_for_xml(XML)
bus.register_object("/org/freedesktop/systemd1", node.interfaces[0], call, None, None)
unit_node = Gio.DBusNodeInfo.new_for_xml(UNIT_XML)
for unit in ("microos-android.service", "gamescope-session-plus@android.service"):
    path = "/org/freedesktop/systemd1/unit/" + unit.replace("-", "_2d").replace("@", "_40").replace(".", "_2e")
    bus.register_object(path, unit_node.interfaces[0], properties, None, None)
Gio.bus_own_name_on_connection(bus, "org.freedesktop.systemd1", Gio.BusNameOwnerFlags.NONE, None, None)
GLib.MainLoop().run()
PY

export STATE="${T}/state"
export HOME="${T}/home"
export XDG_RUNTIME_DIR="${T}/xdg"
export MICROOS_RUNDIR="${T}/run"
export MICROOS_RUNTIME_DIR="${T}/xdg/microos-android"
export MICROOS_ANDROID_STATE="${T}/home/.local/state/microos-android"
export MICROOS_WAYDROID_DATA="${T}/home/.local/share/microos-waydroid"
export MICROOS_ANDROID_CHECK="${T}/bin/check"
export MICROOS_ANDROID_GUEST="${T}/bin/guest"
export MICROOS_WAYDROID="${T}/bin/waydroid"
export MICROOS_TRACK="${T}/bin/track"
export MICROOS_ANDROID_GSF_ID="${T}/gsf-id"
export MICROOS_ANDROID_NO_UI=1
export MICROOS_REFUSE_WAIT=1
export DISPLAY=:0
export GAMESCOPE_WAYLAND_DISPLAY=gamescope-0
export MICROOS_DISPLAY_FILE="${T}/display"
printf 'width=2560\nheight=1600\ndensity=400\nhz=165\ntouch_mode=4\n' > "${MICROOS_DISPLAY_FILE}"
unset MANGOHUD_CONFIGFILE
mkdir -p "${T}/bin" "${STATE}" "${MICROOS_RUNDIR}" "${MICROOS_RUNTIME_DIR}" "${HOME}"
echo "android 1 7" > "${MICROOS_RUNDIR}/session-current"

cat > "${T}/bin/check" <<'STUB'
#!/usr/bin/bash
cat "${STATE}/check-out" 2>/dev/null
exit "$(cat "${STATE}/check-rc" 2>/dev/null || echo 0)"
STUB
cat > "${T}/bin/guest" <<'STUB'
#!/usr/bin/bash
echo "$*" >> "${STATE}/guest"
case "$1" in
    boot) [[ -e "${STATE}/booted" ]] ;;
    opts) exit 0 ;;
    sh) [[ "$2" == "pm list packages" ]] && cat "${STATE}/packages" ;;
esac
STUB
cat > "${T}/bin/waydroid" <<'STUB'
#!/usr/bin/bash
echo "$* XDG_DATA_HOME=${XDG_DATA_HOME} WAYLAND_DISPLAY=${WAYLAND_DISPLAY}" >> "${STATE}/waydroid"
STUB
cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
echo "$*" >> "${STATE}/systemctl"
exit "$(cat "${STATE}/layer-rc" 2>/dev/null || echo 0)"
STUB
cat > "${T}/bin/track" <<'STUB'
#!/usr/bin/bash
echo "$*" >> "${STATE}/track"
STUB
cat > "${T}/bin/xprop" <<'STUB'
#!/usr/bin/bash
echo "$*" >> "${STATE}/xprop"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"

manager=
start_manager() {
    [[ -z "${manager}" ]] || { kill "${manager}" 2>/dev/null; wait "${manager}" 2>/dev/null; }
    python3 "${T}/manager.py" "${STATE}" > "${T}/manager.log" 2>&1 &
    manager=$!
    pids+=("${manager}")
    for _ in {1..100}; do
        gdbus call --session --dest org.freedesktop.DBus --object-path / --method org.freedesktop.DBus.ListNames \
            2>/dev/null | grep -q org.freedesktop.systemd1 && break
        sleep 0.05
    done
}

reset() {
    rm -rf "${STATE}" "${MICROOS_ANDROID_STATE}" "${MICROOS_RUNTIME_DIR}" "${MICROOS_ANDROID_GSF_ID}"
    mkdir -p "${STATE}" "${MICROOS_RUNTIME_DIR}"
    start_manager
}

state_of() {
    python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
for p in sys.argv[2].split("."):
    d = d.get(p, {}) if isinstance(d, dict) else {}
print(d if isinstance(d, str) else "")' "${MICROOS_ANDROID_STATE}/state.json" "$1" 2>/dev/null
}

wait_for() {
    local i
    for (( i = 0; i < 100; i++ )); do
        eval "$1" && return 0
        sleep 0.1
    done
    return 1
}

refused() {
    local want=$1 rc=0
    timeout 20 python3 "${client}" 2> "${T}/err" || rc=$?
    [[ "${rc}" == 1 ]] || fail "$2: exit ${rc}, $(tail -n 3 "${T}/err")"
    [[ "$(state_of last.result)" == refused && "$(state_of last.reason)" == "${want}" ]] \
        || fail "$2: state $(state_of last.result) $(state_of last.reason)"
    grep -qx "refuse android 7 ${want}" "${STATE}/track" || fail "$2: no refusal recorded: $(cat "${STATE}/track" 2>/dev/null)"
}

reset
echo downloading > "${STATE}/check-out"
echo 2 > "${STATE}/check-rc"
refused downloading "a refused check"
grep -q 'microos-android.service' "${STATE}/calls" 2>/dev/null && fail "a refused check started the session"

reset
echo 1 > "${STATE}/check-rc"
refused not-installed "no images"

reset
echo failed > "${STATE}/job-result"
refused failed "a failed start job"

reset
(sleep 1; echo failed > "${STATE}/unit-state") &
refused start-failed "the session exits before boot"

reset
MICROOS_BOOT_TIMEOUT=2 refused boot-timeout "no boot"
grep -q '^boot$' "${STATE}/guest" || fail "the boot was never polled"

reset
touch "${STATE}/booted"
printf 'package:com.android.vending\npackage:com.google.android.gms\npackage:com.google.android.gsf\n' > "${STATE}/packages"
MANGOHUD_CONFIGFILE=/tmp/mangohud.AbCd1234 python3 "${client}" 2> "${T}/err" &
cpid=$!
pids+=("${cpid}")
wait_for '[[ -e "${MICROOS_RUNTIME_DIR}/start-done" ]]' || fail "no start-done: $(tail -n 5 "${T}/err")"
[[ -e "${MICROOS_RUNTIME_DIR}/ready" && "$(state_of last.result)" == ready ]] || fail "not ready"
env_file="${MICROOS_RUNTIME_DIR}/session.env"
for line in DISPLAY=:0 GAMESCOPE_WAYLAND_DISPLAY=gamescope-0 WAYLAND_DISPLAY=gamescope-0 \
    "XDG_DATA_HOME=${MICROOS_WAYDROID_DATA}" "PULSE_RUNTIME_PATH=${XDG_RUNTIME_DIR}/pulse" MICROOS_ANDROID_LSFG_LAYER=1 \
    MANGOHUD_CONFIGFILE=/tmp/mangohud.AbCd1234; do
    grep -qxF -- "${line}" "${env_file}" || fail "session.env lacks ${line}: $(cat "${env_file}")"
done
grep -qx 'start microos-android-layer.service' "${STATE}/systemctl" || fail "no layer start: $(cat "${STATE}/systemctl")"
for unit in microos-android-battery.service microos-android-lsfg.service microos-android-perf.service; do
    grep -qx "start ${unit} fail" "${STATE}/calls" || fail "${unit} not started: $(cat "${STATE}/calls")"
done
grep -qx 'start microos-android.service replace' "${STATE}/calls" || fail "the session owner was not started"
wait_for 'grep -qx "start microos-android-gsf.service replace" "${STATE}/calls"' || fail "the GSF read was not started"
grep -qxF "show-full-ui XDG_DATA_HOME=${MICROOS_WAYDROID_DATA} WAYLAND_DISPLAY=gamescope-0" "${STATE}/waydroid" \
    || fail "show-full-ui: $(cat "${STATE}/waydroid" 2>/dev/null)"
grep -qx opts "${STATE}/guest" || fail "the guest settings did not run"
[[ "$(state_of gapps.play)" == on && "$(state_of gapps.gms)" == on ]] || fail "gapps state"
grep -qx 'STEAM_TOUCH_CLICK_MODE' <(tr ' ' '\n' < "${STATE}/xprop") || fail "no touch mode"
sleep 1
kill -0 "${cpid}" 2>/dev/null || fail "the client exited after ready"
kill -TERM "${cpid}"
rc=0
wait "${cpid}" || rc=$?
[[ "${rc}" == 0 ]] || fail "the client exited ${rc} on TERM"
grep -q 'microos-android.service' <(grep -v '^start' "${STATE}/calls") && fail "the client stopped the session"

reset
touch "${STATE}/booted"
echo 1 > "${STATE}/layer-rc"
echo 'package:com.android.settings' > "${STATE}/packages"
echo 1234 > "${MICROOS_ANDROID_GSF_ID}"
python3 "${client}" 2> "${T}/err" &
cpid=$!
pids+=("${cpid}")
wait_for '[[ -e "${MICROOS_RUNTIME_DIR}/start-done" ]]' || fail "no start-done with no layer"
grep -qx MICROOS_ANDROID_LSFG_LAYER=0 "${MICROOS_RUNTIME_DIR}/session.env" || fail "a failed layer was taken as placed"
grep -q 'microos-android-layer.service failed' "${T}/err" || fail "no layer failure log"
[[ "$(state_of gapps.play)" == off ]] || fail "gapps.play with no Play"
grep -q 'microos-android-gsf.service' "${STATE}/calls" && fail "the GSF read started with no GSF"
kill -TERM "${cpid}"
wait "${cpid}" 2>/dev/null

(( failures == 0 )) || { echo "${failures} failure(s)" >&2; exit 1; }
echo "client-test: pass"
