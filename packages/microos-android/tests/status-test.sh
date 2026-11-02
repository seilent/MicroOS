#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/data/usr/libexec/microos"
status="${libexec}/microos-android-status"

T=$(mktemp -d)
pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "${p}" 2>/dev/null || true; done
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

export HOME="${T}/home"
export MICROOS_HOME="${T}/home"
export MICROOS_HOME="${T}/home"
export XDG_STATE_HOME="${T}/home/.local/state"
export MICROOS_ANDROID_STATE="${T}/home/.local/state/microos-android"
export MICROOS_ANDROID_DATA="${T}/home/.local/share/microos-android"
export MICROOS_LEPTON_REVIEWED="${T}/reviewed"
export MICROOS_LEPTON_SNAPSHOTS="${T}/snaps"
mkdir -p "${MICROOS_ANDROID_STATE}" "${MICROOS_ANDROID_DATA}" "${MICROOS_LEPTON_REVIEWED}" "${MICROOS_LEPTON_SNAPSHOTS}"

set_state() {
    python3 - "${MICROOS_ANDROID_STATE}/state.json" "$@" <<'PY'
import json
import os
import sys

path = sys.argv[1]
data = {}
for item in sys.argv[2:]:
    key, value = item.split("=", 1)
    parts = key.split(".")
    node = data
    for part in parts[:-1]:
        node = node.setdefault(part, {})
    node[parts[-1]] = value
temp = path + ".new"
with open(temp, "w") as handle:
    json.dump(data, handle)
os.replace(temp, path)
PY
}

start() {
    "${status}" > "${T}/out" 2>&1 &
    pids+=($!)
    for _ in {1..100}; do
        gdbus introspect --session --dest net.seilent.MicroOs.Android1 --object-path /net/seilent/MicroOs/Android > /dev/null 2>&1 && return 0
        sleep 0.05
    done
    return 1
}

prop() {
    local raw
    raw=$(gdbus call --session --dest net.seilent.MicroOs.Android1 --object-path /net/seilent/MicroOs/Android \
        --method org.freedesktop.DBus.Properties.Get net.seilent.MicroOs.Android1 "$1") || return 1
    raw=${raw#(<\'}
    raw=${raw%\'>,)}
    printf '%s' "${raw}"
}

set_state "lepton.build=25772114" "lepton.source=steam"
printf 'x\n' > "${MICROOS_LEPTON_REVIEWED}/25772114"
start || { echo "FAIL: the service did not own its name: $(cat "${T}/out")" >&2; exit 1; }
[[ "$(prop Lepton)" == ready ]] || fail "Lepton: $(prop Lepton)"
[[ "$(prop LeptonBuild)" == 25772114 ]] || fail "LeptonBuild: $(prop LeptonBuild)"
[[ "$(prop GooglePlay)" == off ]] || fail "GooglePlay: $(prop GooglePlay)"
[[ "$(prop GsfId)" == "" ]] || fail "GsfId: $(prop GsfId)"

set_state "lepton.build=25772115" "lepton.source=steam"
sleep 0.3
[[ "$(prop Lepton)" == not-reviewed ]] || fail "not-reviewed: $(prop Lepton)"

set_state "lepton.build=1" "lepton.source=snapshot"
sleep 0.3
[[ "$(prop Lepton)" == not-installed ]] || fail "not-installed: $(prop Lepton)"

set_state "gapps.set=mtg11" "gapps.setup=done"
mkdir -p "${MICROOS_ANDROID_DATA}/gapps/mtg11"
ln -sfn mtg11 "${MICROOS_ANDROID_DATA}/gapps/current"
sleep 0.3
[[ "$(prop GooglePlay)" == on ]] || fail "GooglePlay on: $(prop GooglePlay)"

set_state "gapps.set=mtg11" "gapps.setup=running"
sleep 0.3
[[ "$(prop GooglePlay)" == updating ]] || fail "GooglePlay updating: $(prop GooglePlay)"

set_state "last.result=refused" "last.reason=no-card"
sleep 0.3
[[ "$(prop LastResult)" == refused ]] || fail "LastResult: $(prop LastResult)"
[[ "$(prop LastReason)" == no-card ]] || fail "LastReason: $(prop LastReason)"

if ! gdbus introspect --session --dest net.seilent.MicroOs.Android1 --object-path /net/seilent/MicroOs/Android \
    | grep -q "interface net.seilent.MicroOs.Android1"; then
    fail "the interface is not net.seilent.MicroOs.Android1"
fi

if ! gdbus call --session --dest net.seilent.MicroOs.Android1 --object-path /net/seilent/MicroOs/Android \
    --method org.freedesktop.DBus.Properties.Get net.seilent.MicroOs.Android1 Lepton > /dev/null 2>&1; then
    fail "the properties are not readable"
fi

rm -f "${MICROOS_ANDROID_STATE}/state.json"
sleep 0.3
[[ "$(prop Lepton)" == not-installed ]] || fail "a missing state file: $(prop Lepton)"

monitor() {
    gdbus monitor --session --dest net.seilent.MicroOs.Android1 --object-path /net/seilent/MicroOs/Android \
        > "${T}/monitor" 2>&1 &
    monitor_pid=$!
    pids+=("${monitor_pid}")
    for _ in {1..100}; do grep -q "Monitoring signals" "${T}/monitor" 2>/dev/null && return 0; sleep 0.05; done
    return 1
}

reset_monitor() { : > "${T}/monitor"; }

monitor || fail "the monitor did not start"
set_state "last.result=ready" "last.reason="
sleep 0.5
grep -q "PropertiesChanged" "${T}/monitor" || fail "a state change emitted no PropertiesChanged: $(cat "${T}/monitor")"
grep -q "LastResult" "${T}/monitor" || fail "a state change did not name LastResult: $(cat "${T}/monitor")"
[[ "$(grep -c "PropertiesChanged" "${T}/monitor")" == 1 ]] || fail "a state change emitted more than one signal: $(cat "${T}/monitor")"

reset_monitor
touch "${MICROOS_ANDROID_STATE}/.state.tmp"
sleep 0.5
grep -q "PropertiesChanged" "${T}/monitor" && fail "a .state temp file emitted a signal: $(cat "${T}/monitor")"

reset_monitor
printf 'x\n' > "${MICROOS_LEPTON_REVIEWED}/25772114"
printf 'x\n' > "${MICROOS_LEPTON_REVIEWED}/25772116"
set_state "lepton.build=25772116" "lepton.source=steam"
sleep 0.5
grep -q "PropertiesChanged" "${T}/monitor" || fail "a reviewed build emitted no signal: $(cat "${T}/monitor")"
grep -q "LeptonBuild" "${T}/monitor" || fail "a reviewed build did not name LeptonBuild: $(cat "${T}/monitor")"

reset_monitor
rm -f "${MICROOS_ANDROID_DATA}/gapps/current"
set_state "gapps.set=" "gapps.setup=done"
sleep 0.5
[[ "$(prop GooglePlay)" == off ]] || fail "no GApps set after a removal: $(prop GooglePlay)"
reset_monitor
ln -sfn mtg11 "${MICROOS_ANDROID_DATA}/gapps/current"
sleep 0.5
grep -q "GooglePlay" "${T}/monitor" || fail "a linked GApps set did not name GooglePlay: $(cat "${T}/monitor")"
[[ "$(prop GooglePlay)" == updating ]] || fail "a linked set the state does not name: $(prop GooglePlay)"
set_state "gapps.set=mtg11"
sleep 0.5
[[ "$(prop GooglePlay)" == on ]] || fail "a linked set the state names: $(prop GooglePlay)"

rm -rf "${MICROOS_LEPTON_SNAPSHOTS}"
set_state "lepton.build=1" "lepton.source=snapshot"
sleep 0.5
[[ "$(prop Lepton)" == not-installed ]] || fail "a snapshot build with no snapshot: $(prop Lepton)"
mkdir -p "${MICROOS_LEPTON_SNAPSHOTS}/1"
sleep 0.5
[[ "$(prop Lepton)" == not-reviewed ]] || fail "a snapshot build with a snapshot: $(prop Lepton)"

big="${T}/late"
export MICROOS_ANDROID_DATA="${big}"
ok=0
"${status}" > "${T}/late-out" 2>&1 &
pids+=($!)
for _ in {1..100}; do
    gdbus introspect --session --dest net.seilent.MicroOs.Android1 \
        --object-path /net/seilent/MicroOs/Android > /dev/null 2>&1 && { ok=1; break; }
    sleep 0.05
done
[[ "${ok}" == 1 ]] || fail "the service did not own its name with a missing data dir: $(cat "${T}/late-out")"
mkdir -p "${big}/gapps"
set_state "lepton.build=25772114" "lepton.source=steam"
printf 'x\n' > "${MICROOS_LEPTON_REVIEWED}/25772114"
ln -sfn mtg11 "${big}/gapps/current"
sleep 1.2
raw=$(gdbus call --session --dest net.seilent.MicroOs.Android1 --object-path /net/seilent/MicroOs/Android \
    --method org.freedesktop.DBus.Properties.Get net.seilent.MicroOs.Android1 GooglePlay) || true
[[ "${raw}" == *updating* ]] || fail "a gapps dir made after the start is not read: ${raw}"

rc=0
"${status}" > "${T}/second" 2>&1 || rc=$?
[[ "${rc}" == 0 ]] || fail "a second instance: exit ${rc}: $(cat "${T}/second")"
grep -q "is taken by another process, exiting" "${T}/second" \
    || fail "a second instance: not logged: $(cat "${T}/second")"
grep -q "Traceback" "${T}/second" && fail "a second instance left a traceback: $(cat "${T}/second")"
export MICROOS_ANDROID_DATA="${T}/home/.local/share/microos-android"

[[ "${failures}" == 0 ]] || exit 1
echo "status-test: ok"
