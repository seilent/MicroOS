#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
battery="${repo}/data/usr/libexec/microos/microos-android-battery"

T=$(mktemp -d)
pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "${p}" 2>/dev/null || true; done
    rm -rf "${T}"
}
trap cleanup EXIT

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

command -v python3 > /dev/null || { echo "FAIL: python3 missing" >&2; exit 1; }

export STATE="${T}/state"
export MICROOS_POWER_SUPPLY="${T}/power_supply"
export MICROOS_BATTERY_POLL_MS=600000
mkdir -p "${T}/bin" "${STATE}"
cat > "${T}/bin/podman" <<'FAKE'
#!/usr/bin/bash
echo "$*" >> "${STATE}/podman"
if [[ -e "${STATE}/podman-rc" ]]; then
    cat "${STATE}/podman-out" 2>/dev/null || true
    exit "$(cat "${STATE}/podman-rc")"
fi
[[ "$1 $2 $3 $4" == "exec lepton-android /system/bin/sh -c" ]] || exit 99
while read -r _ _ _ key value _; do
    [[ -n "${key}" ]] || continue
    echo "${key} ${value}" >> "${STATE}/sets"
    if [[ -e "${STATE}/fail-${key}" ]]; then
        cat "${STATE}/fail-${key}"
        echo "@${key} 255"
    else
        echo "@${key} 0"
    fi
done <<< "$5"
FAKE
cat > "${T}/bin/udevadm" <<'FAKE'
#!/usr/bin/bash
echo "$*" >> "${STATE}/udevadm"
[[ ! -e "${STATE}/udevadm-end" ]] || exit 0
echo "monitor will print the received events for:"
echo "UDEV - the event which udev sends out after rule processing"
echo
exec tail -n +1 -f "${STATE}/uevents"
FAKE
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"

supply() {
    local dir="${MICROOS_POWER_SUPPLY}/$1" pair
    mkdir -p "${dir}"
    shift
    for pair in "$@"; do
        printf '%s\n' "${pair#*=}" > "${dir}/${pair%%=*}"
    done
}

uevent() {
    echo "UDEV  [21549.603285] change   /devices/platform/pmic-glink/power_supply/$1 (power_supply)" >> "${STATE}/uevents"
}

reset() {
    rm -rf "${MICROOS_POWER_SUPPLY}" "${STATE}"
    mkdir -p "${MICROOS_POWER_SUPPLY}" "${STATE}"
    : > "${STATE}/podman"
    : > "${STATE}/sets"
    : > "${STATE}/uevents"
    supply qcom-battmgr-bat type=Battery status=Discharging capacity=92 temp=293 charge_counter=6188840 present=1
    supply qcom-battmgr-usb type=USB online=0
    supply qcom-battmgr-wls type=Wireless online=0
    supply ucsi-source-psy-pmic_glink.ucsi.01 type=USB online=0 "status=Not charging"
}

start() {
    "${battery}" > "${T}/out" 2>&1 &
    battery_pid=$!
    pids+=("${battery_pid}")
}

stop() {
    kill "${battery_pid}" 2>/dev/null || true
    wait "${battery_pid}" 2>/dev/null || true
}

sets() { cat "${STATE}/sets"; }

clear_sets() { : > "${STATE}/sets"; : > "${STATE}/podman"; }

execs() { grep -c '^exec lepton-android /system/bin/sh -c' "${STATE}/podman" || true; }

wait_sets() {
    for _ in {1..100}; do
        [[ "$(sets | wc -l)" -ge "$1" ]] && return 0
        sleep 0.05
    done
    return 1
}

wait_log() {
    for _ in {1..100}; do
        grep -qxF -- "microos-android-battery: $1" "${T}/out" && return 0
        sleep 0.05
    done
    return 1
}

reset
supply hid-0005:045E:0B13.0001-battery type=Battery scope=Device status=Discharging capacity=40 present=1
supply hid-0005:045E:0B13.0001-charger type=USB scope=Device online=1
start
wait_sets 7 || fail "the start set $(sets | wc -l) values: $(cat "${STATE}/podman")"
[[ "$(sets)" == $'ac 0\nusb 0\nwireless 0\nstatus 3\nlevel 92\ntemp 293\ncounter 6188840' ]] || fail "the start: $(sets)"
[[ "$(execs)" == 1 ]] || fail "the start ran $(execs) execs: $(cat "${STATE}/podman")"
grep -qF '/system/bin/cmd battery set level 92 2>&1; echo "@level $?"' "${STATE}/podman" \
    || fail "the start script: $(cat "${STATE}/podman")"
[[ "$(cat "${STATE}/udevadm")" == "monitor --udev --subsystem-match=power_supply" ]] \
    || fail "udevadm ran with: $(cat "${STATE}/udevadm")"
wait_log "set ac 0, usb 0, wireless 0, status 3, level 92, temp 293, counter 6188840" \
    || fail "the start was not logged: $(cat "${T}/out")"

clear_sets
supply ucsi-source-psy-pmic_glink.ucsi.01 online=1 status=Charging
supply qcom-battmgr-bat status=Charging
uevent ucsi-source-psy-pmic_glink.ucsi.01
uevent qcom-battmgr-bat
wait_sets 2 || fail "a plug set nothing: $(cat "${T}/out")"
sleep 0.3
[[ "$(sets)" == $'usb 1\nstatus 2' ]] || fail "a plug: $(sets)"
[[ "$(execs)" == 1 ]] || fail "a plug ran $(execs) execs"

clear_sets
uevent qcom-battmgr-bat
sleep 0.3
[[ -z "$(sets)" && "$(execs)" == 0 ]] || fail "a uevent with nothing changed: $(sets)"

echo "monitor will print the received events for:" >> "${STATE}/uevents"
supply qcom-battmgr-bat capacity=91
sleep 0.3
[[ -z "$(sets)" ]] || fail "a line that is not a power_supply event: $(sets)"
uevent qcom-battmgr-bat
wait_sets 1 || fail "a capacity uevent set nothing"
[[ "$(sets)" == "level 91" ]] || fail "a capacity uevent: $(sets)"

clear_sets
supply qcom-battmgr-bat temp=301
uevent qcom-battmgr-bat
sleep 0.3
[[ -z "$(sets)" ]] || fail "a temp move under a degree was sent: $(sets)"
supply qcom-battmgr-bat temp=303
uevent qcom-battmgr-bat
wait_sets 1 || fail "a temp move of a degree was not sent"
[[ "$(sets)" == "temp 303" ]] || fail "a temp move of a degree: $(sets)"

clear_sets
echo "Bad value: 90" > "${STATE}/fail-level"
supply qcom-battmgr-bat capacity=90 status=Full charge_counter=6100000
uevent qcom-battmgr-bat
wait_sets 3 || fail "a batch with a failing key was not tried"
wait_log "battery set level 90 exited 255: Bad value: 90" || fail "a failed key was not logged with its output: $(cat "${T}/out")"
wait_log "set status 5, counter 6100000" || fail "the key next to a failed one was not set: $(cat "${T}/out")"
[[ "$(execs)" == 1 ]] || fail "a batch with a failing key ran $(execs) execs"
rm -f "${STATE}/fail-level"
clear_sets
uevent qcom-battmgr-bat
wait_sets 1 || fail "a failed key was not retried at the next uevent"
sleep 0.3
[[ "$(sets)" == "level 90" ]] || fail "the retry at the next uevent: $(sets)"
clear_sets
uevent qcom-battmgr-bat
sleep 0.3
[[ -z "$(sets)" ]] || fail "a set value was sent again: $(sets)"

clear_sets
echo 125 > "${STATE}/podman-rc"
echo "Error: no container with name or ID lepton-android found" > "${STATE}/podman-out"
supply qcom-battmgr-bat capacity=88
uevent qcom-battmgr-bat
wait_log "battery set level 88: podman exec exited 125: Error: no container with name or ID lepton-android found" \
    || fail "a failed exec was not logged: $(cat "${T}/out")"
rm -f "${STATE}/podman-rc" "${STATE}/podman-out"
uevent qcom-battmgr-bat
wait_sets 1 || fail "a failed exec was not retried at the next uevent"
[[ "$(sets)" == "level 88" ]] || fail "the retry after a failed exec: $(sets)"
stop
for _ in {1..20}; do pgrep -f "tail -n \+1 -f ${STATE}/uevents" > /dev/null || break; sleep 0.05; done
pgrep -f "tail -n \+1 -f ${STATE}/uevents" > /dev/null && fail "udevadm outlived the mirror"

reset
export MICROOS_BATTERY_POLL_MS=200
echo 125 > "${STATE}/podman-rc"
start
for _ in {1..100}; do grep -q "podman exec exited 125" "${T}/out" && break; sleep 0.05; done
grep -q "podman exec exited 125" "${T}/out" || fail "a failed first exec was not logged: $(cat "${T}/out")"
rm -f "${STATE}/podman-rc"
wait_log "set ac 0, usb 0, wireless 0, status 3, level 92, temp 293, counter 6188840" \
    || fail "a failed first exec was not sent again at the next poll: $(cat "${T}/out")"
clear_sets
supply qcom-battmgr-bat capacity=89
wait_sets 1 || fail "the poll did not read a capacity change"
[[ "$(sets)" == "level 89" ]] || fail "the poll: $(sets)"
stop
export MICROOS_BATTERY_POLL_MS=600000

for pair in "Full 5" "Not charging 4" "Unknown 1" "Bogus 1"; do
    reset
    supply qcom-battmgr-bat "status=${pair% *}"
    start
    wait_sets 7 || fail "status ${pair% *}: $(cat "${T}/out")"
    sets | grep -qx "status ${pair##* }" || fail "status ${pair% *}: $(sets)"
    stop
done

for how in empty missing; do
    reset
    if [[ "${how}" == empty ]]; then
        : > "${MICROOS_POWER_SUPPLY}/qcom-battmgr-bat/status"
    else
        rm -f "${MICROOS_POWER_SUPPLY}/qcom-battmgr-bat/status"
    fi
    start
    wait_sets 6 || fail "a status read ${how}: $(cat "${T}/out")"
    sleep 0.3
    [[ "$(sets)" == $'ac 0\nusb 0\nwireless 0\nlevel 92\ntemp 293\ncounter 6188840' ]] || fail "a status read ${how}: $(sets)"
    stop
done

reset
supply qcom-battmgr-bat capacity=9² temp=29³ charge_counter=-12
start
wait_sets 5 || fail "values that are not numbers: $(cat "${T}/out")"
sleep 0.3
[[ "$(sets)" == $'ac 0\nusb 0\nwireless 0\nstatus 3\ncounter -12' ]] || fail "values that are not numbers: $(sets)"
grep -q "Traceback" "${T}/out" && fail "values that are not numbers left a traceback: $(cat "${T}/out")"
stop

reset
rm -rf "${MICROOS_POWER_SUPPLY:?}"/*
supply ac type=Mains online=1
supply pd type=USB_PD online=2
supply wls type=Wireless online=1
supply bat type=Battery scope=System status=Charging capacity=50 present=1
start
wait_sets 5 || fail "the charger kinds: $(cat "${T}/out")"
[[ "$(sets)" == $'ac 1\nusb 1\nwireless 1\nstatus 2\nlevel 50' ]] || fail "the charger kinds: $(sets)"
stop

reset
rm -rf "${MICROOS_POWER_SUPPLY:?}"/qcom-battmgr-bat
supply gone type=Battery present=0 capacity=10 status=Discharging
start
wait_sets 3 || fail "no battery: $(cat "${T}/out")"
sleep 0.3
[[ "$(sets)" == $'ac 0\nusb 0\nwireless 0' ]] || fail "no battery: $(sets)"
stop

reset
: > "${STATE}/udevadm-end"
rc=0
timeout 10 "${battery}" > "${T}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 ]] || fail "udevadm ended: exit ${rc}"
grep -qx "microos-android-battery: udevadm monitor --udev --subsystem-match=power_supply ended" "${T}/out" \
    || fail "udevadm ended: not logged: $(cat "${T}/out")"

reset
start
wait_sets 7 || fail "the stop run did not start"
rc=0
kill -TERM "${battery_pid}"
wait "${battery_pid}" || rc=$?
[[ "${rc}" == 0 ]] || fail "a stop: exit ${rc}: $(cat "${T}/out")"
grep -q "Traceback" "${T}/out" && fail "a stop left a traceback: $(cat "${T}/out")"

[[ "${failures}" == 0 ]] || exit 1
echo "battery-test: ok"
