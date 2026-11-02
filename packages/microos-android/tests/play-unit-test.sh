#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/data/usr/libexec/microos"
run_script="${libexec}/microos-android-run"
stop_script="${libexec}/microos-android-stop"

T=$(mktemp -d)
prefix_dir=
trap 'rm -rf "${T}" ${prefix_dir:+"${prefix_dir}"}' EXIT
mkdir -p "${T}/bin" "${T}/lepton/images/rootfs/vendor/odm/etc"
export STATE="${T}/state"
export MICROOS_LEPTON="${T}/bin/lepton"
export MICROOS_PAD_NODES="${T}/bin/pad-nodes"
export MICROOS_KEYBOARD_INSTALL="${T}/bin/keyboard-install"
export MICROOS_DISPLAY_FILE="${repo}/data/usr/share/microos-android/display"
export MICROOS_ANDROID_CONTEXT="${T}/contexts/android"
export MICROOS_RUNTIME_DIR="${T}/run/microos-android"
export MICROOS_ANDROID_DATA="${T}/data/android"
export MICROOS_POLL_S=0.05
export MICROOS_STEAM_PIPE="${T}/steam.pipe"
export MICROOS_GAPPS="${T}/gapps"
export MICROOS_STUB_DIR="${T}/stub"
export MICROOS_OPTS="${repo}/data/usr/share/microos-android/opts"
export STATE_HOME="${T}/xdg-state"
printf 'ro.odm.build.id=RQ3A\nro.product.odm.model=lepton\n' > "${T}/lepton/images/rootfs/vendor/odm/etc/build.prop"
mkdir -p "${T}/lepton/images/rootfs/system/etc/init" "${T}/lepton/images/rootfs_overlay"
printf 'on boot\n    bugreport\n    keycodes 114 115 116\non post-fs-data\n' > "${T}/lepton/images/rootfs/system/etc/init/lineage-system.rc"
export XDG_RUNTIME_DIR="${T}/xdg"
mkdir -p "${XDG_RUNTIME_DIR}"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${XDG_RUNTIME_DIR}/gamescope-0"
export GAMESCOPE_WAYLAND_DISPLAY="${XDG_RUNTIME_DIR}/gamescope-0"
echo 3.0.5 > "${T}/lepton/version.txt"
echo 3.0.3 > "${T}/lepton/images/version.txt"
conf="${MICROOS_RUNTIME_DIR}/containers.conf"
odm="${MICROOS_RUNTIME_DIR}/odm-build.prop"
rc_override="${MICROOS_RUNTIME_DIR}/lineage-system.rc"

cat > "${T}/bin/lepton" <<STUB
#!/usr/bin/bash
if [[ "\${1:-}" == runtime ]]; then
    echo "runtime" >> "\${STATE}/runtime-cmd"
    if [[ -e "\${STATE}/no-lepton-dir" ]]; then
        echo "microos-lepton: Lepton is not installed. Install it in Steam." >&2
        exit 1
    fi
    if [[ -e "\${STATE}/unreviewed" ]]; then
        echo "microos-lepton: Lepton build 25772115 is not one MicroOS knows, refusing" >&2
        exit 1
    fi
    echo "${T}/lepton"
    exit 0
fi
echo "lepton \$*" >> "\${STATE}/events"
env > "\${STATE}/env"
[[ -d "\${MICROOS_ANDROID_CONTEXT}/internal" ]] && echo internal-present > "\${STATE}/internal"
ps -o args= -p "\${PPID}" > "\${STATE}/parent"
while IFS= read -r step; do
    case "\${step}" in
        sleep*) sleep "\${step#sleep }" ;;
        exit*) exit "\${step#exit }" ;;
        hold) sleep 6 & ;;
        steam-on) : > "\${STATE}/steam" ;;
        steam-off) rm -f "\${STATE}/steam" ;;
        rmpipe) rm -f "\${MICROOS_STEAM_PIPE}" ;;
        pipe*) timeout 2 bash -c 'printf "%s\\n" "\$1" > "\$2"' _ "\${step#pipe }" "\${MICROOS_STEAM_PIPE:-\${MICROOS_ANDROID_DATA}/home/.steam/steam.pipe}" || echo "pipe blocked" >> "\${STATE}/events" ;;
        *) echo "\${step}"; echo "out \${step}" >> "\${STATE}/events" ;;
    esac
done < "\${STATE}/script"
STUB
cat > "${T}/bin/pad-nodes" <<'STUB'
#!/usr/bin/bash
cat "${STATE}/nodes"
STUB
cat > "${T}/bin/keyboard-install" <<'STUB'
#!/usr/bin/bash
echo "$*" >> "${STATE}/keyboard"
[[ ! -e "${STATE}/keyboard-hold" ]] || sleep "$(cat "${STATE}/keyboard-hold")"
STUB
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
echo "podman $*" >> "${STATE}/podman"
case "$*" in
    "container inspect -f {{.State.Running}} lepton-android") cat "${STATE}/running" ;;
    "exec lepton-android /system/bin/getprop sys.boot_completed") cat "${STATE}/booted" ;;
    "exec lepton-android /system/bin/pidof logd") echo 123 ;;
    "exec lepton-android /system/bin/logcat -b main -b system -b crash -v threadtime") cat "${STATE}/logcat" ;;
    "exec lepton-android /system/bin/pm grant "*) [[ ! -e "${STATE}/grant_fail" ]] ;;
    "exec lepton-android /system/bin/cmd_real package compile "*) ;;
    "exec lepton-android /system/bin/sh -c "*)
        echo opts >> "${STATE}/events"
        n=$(( $(ls "${STATE}" | grep -c '^opts-script') + 1 ))
        printf '%s\n' "$5" > "${STATE}/opts-script-${n}"
        [[ ! -e "${STATE}/opts-sleep" ]] || sleep "$(cat "${STATE}/opts-sleep")"
        if [[ -e "${STATE}/opts-reply" ]]; then
            cat "${STATE}/opts-reply"
            exit 0
        fi
        printf '%s\n' "$5" | while read -r kind id pkg _; do
            id=${id//\'/}
            pkg=${pkg//\'/}
            case "${kind}" in
                s) echo "ok ${id}" ;;
                u) echo "undone ${id}" ;;
                p) if grep -qxF "${pkg}" "${STATE}/pkgs" 2>/dev/null; then echo "ok ${id}"; else echo "absent ${id}"; fi ;;
            esac
        done
        ;;
    "inspect -f {{ index .Config.Labels \"PREFIX\" }} lepton-android") cat "${STATE}/prefix" ;;
    "stop -t 1 lepton-android"|"rm -fi lepton-android") ;;
    "container exists "*) [[ "$3" == "$(cat "${STATE}/other" 2>/dev/null)" ]] && exit 0; exit "$(cat "${STATE}/other_rc" 2>/dev/null || echo 1)" ;;
    "unshare rm -rf "*) [[ ! -e "${STATE}/unshare-fail" ]] || exit 1; rm -rf "${3}" ;;
    *) echo "podman: unexpected $*" >&2; exit 99 ;;
esac
STUB
cat > "${T}/bin/pgrep" <<'STUB'
#!/usr/bin/bash
[[ "$*" == "-x steam" ]] || exit 99
[[ -e "${STATE}/steam" ]]
STUB
cat > "${T}/bin/systemd-notify" <<'STUB'
#!/usr/bin/bash
echo "notify $*" >> "${STATE}/events"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}" "${MICROOS_RUNTIME_DIR}" "${STATE_HOME}"
    mkdir -p "${STATE}"
    : > "${STATE}/events"
    : > "${STATE}/podman"
    echo true > "${STATE}/running"
    echo 1 > "${STATE}/booted"
    printf 'I ActivityManager: start\n' > "${STATE}/logcat"
    printf '/dev/input/event10\n/dev/input/event12\n' > "${STATE}/nodes"
    printf '%s\n' "$1" | tr ';' '\n' > "${STATE}/script"
    : > "${STATE}/keyboard"
    rm -f "${MICROOS_STEAM_PIPE}" "${STATE}/keyboard-hold"
    mkfifo "${MICROOS_STEAM_PIPE}"
}

run() {
    rc=0
    XDG_STATE_HOME="${STATE_HOME}" SteamAppId=1234 LD_LIBRARY_PATH=/appimage/lib "${run_script}" 2> "${STATE}/stderr" || rc=$?
}

events() { cat "${STATE}/events"; }

reset "starting;Boot complete!;sleep 0.5;logcat after boot;exit 3"
run
[[ "${rc}" == 3 ]] || fail "exit code ${rc}, expected lepton's 3: $(cat "${STATE}/stderr")"
for var in TERM=dumb APP_WANTS_FLATSCREEN=true "GAMESCOPE_WAYLAND_DISPLAY=${XDG_RUNTIME_DIR}/gamescope-0" \
    "STEAM_COMPAT_DATA_PATH=${MICROOS_ANDROID_CONTEXT}" LEPTON_NO_CLEANUP=true LEPTON_KEEP_CONTEXT=1 \
    "CONTAINERS_CONF_OVERRIDE=${conf}" "MICROOS_LEPTON_RUNTIME=${T}/lepton"; do
    grep -qx "${var}" "${STATE}/env" || fail "environment lacks ${var}"
done
grep -q '^SteamAppId=' "${STATE}/env" && fail "SteamAppId reached lepton"
grep -q '^LD_LIBRARY_PATH=' "${STATE}/env" && fail "LD_LIBRARY_PATH reached lepton"
[[ -s "${STATE}/internal" ]] || fail "internal/ not created before lepton start"
[[ "$(cat "${STATE}/parent")" == *"/microos-android-run"* ]] || fail "lepton is not a child of microos-android-run: $(cat "${STATE}/parent")"
grep -qx "lepton start android" "${STATE}/events" || fail "lepton not run as start android"
[[ "$(sed -n '1p' "${conf}")" == "[containers]" ]] || fail "conf header"
grep -qx 'annotations = \["run.oci.systemd.subgroup=app-steam-app1-1.scope"\]' "${conf}" || fail "annotation missing: $(cat "${conf}")"
expected_mounts="mounts = [\"type=bind,source=/dev/input/event10,destination=/dev/input/event10,rw\",\"type=bind,source=/dev/input/event12,destination=/dev/input/event12,rw\",\"type=bind,source=${rc_override},destination=/system/etc/init/lineage-system.rc,ro\",\"type=bind,source=${odm},destination=/vendor/odm/etc/build.prop,ro\",\"type=bind,source=/dev/net/tun,destination=/dev/tun,rw\"]"
grep -qxF "${expected_mounts}" "${conf}" || fail "mounts: $(cat "${conf}")"
[[ "$(cat "${odm}")" == $'ro.odm.build.id=RQ3A\nro.product.odm.model=lepton\nro.sf.lcd_density=213\nqemu.hw.mainkeys=1\npm.dexopt.install=speed\nro.adb.secure=1' ]] || fail "odm prop: $(cat "${odm}")"
expected_events="notify EXTEND_TIMEOUT_USEC=120000000
lepton start android
out starting
out Boot complete!
opts
notify --ready
out logcat after boot"
[[ "$(events)" == "${expected_events}" ]] || fail "events: $(events)"
grep -qx "starting" "${STATE}/stderr" || fail "boot output not in the journal"
grep -q "logcat after boot" "${STATE}/stderr" && fail "post boot output reached the journal"
[[ "$(cat "${MICROOS_ANDROID_DATA}/lepton.log")" == $'logcat after boot\nmicroos-android-run: lepton start exited with 3' ]] || fail "lepton.log: $(cat "${MICROOS_ANDROID_DATA}/lepton.log")"
[[ "$(cat "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")" == "3.0.5 3.0.3 gapps=none" ]] || fail "stamp not written"
[[ "$(wc -l < "${STATE}/runtime-cmd")" == 1 ]] || fail "microos-lepton runtime ran $(wc -l < "${STATE}/runtime-cmd") times, not once"
[[ "$(cat "${MICROOS_ANDROID_DATA}/boot.log")" == "I ActivityManager: start" ]] || fail "boot log: $(cat "${MICROOS_ANDROID_DATA}/boot.log" 2>/dev/null)"
grep -q "lepton start exited with 3" "${STATE}/stderr" || fail "exit not logged"
for _ in $(seq 1 40); do [[ -s "${STATE}/keyboard" ]] && break; sleep 0.05; done
[[ "$(cat "${STATE}/keyboard")" == "lepton-android" ]] || fail "keyboard install not started as lepton-android: $(cat "${STATE}/keyboard" 2>/dev/null)"
opts="${MICROOS_ANDROID_CONTEXT}/microos-android-opts"
script="${STATE}/opts-script-1"
for line in "s 'wifi-scan' 'settings' 'put' 'global' 'wifi_scan_always_enabled' '0'" \
    "s 'captive-portal' 'settings' 'put' 'global' 'captive_portal_mode' '0'" \
    "s 'idle-alarms' 'settings' 'put' 'global' 'alarm_manager_constants' 'allow_while_idle_short_time=10000,allow_while_idle_long_time=20000'" \
    "s 'adb-dialog' 'package' 'disable' '--user' '0' 'com.android.systemui/.usb.UsbDebuggingActivity'" \
    "s 'adb-expiry' 'settings' 'put' 'global' 'adb_allowed_connection_time' '0'" \
    "p 'printspooler' 'com.android.printspooler'" "p 'stk' 'com.android.stk'"; do
    grep -qxF "${line}" "${script}" || fail "opts: missing ${line}: $(cat "${script}")"
done
grep -qE "appops|set-standby-bucket|com\.google\.android\.gms|com\.android\.vending|trim-caches|use_freezer|use_fifo_ui|sensor_privacy|job_scheduler" "${script}" \
    && fail "opts: an excluded command was sent: $(cat "${script}")"
[[ "$(grep -c '^[spu] ' "${script}")" == 13 ]] || fail "opts: $(grep -c '^[spu] ' "${script}") commands, expected 13"
[[ "$(wc -l < "${opts}")" == 13 ]] || fail "opts stamp: $(cat "${opts}")"
grep -q "guest settings: 13 applied, 0 failed" "${STATE}/stderr" || fail "opts: no summary: $(cat "${STATE}/stderr")"

reset "Boot complete!;sleep 0.2;exit 0"
run
[[ ! -e "${STATE}/opts-script-1" ]] || fail "opts: sent again with every id applied: $(cat "${STATE}/opts-script-1")"

custom="${T}/opts"
{
    grep -v '^set ble-scan ' "${MICROOS_OPTS}"
    echo "unset ble-scan settings delete global ble_scan_always_enabled"
    echo "set new-one settings put global microos_test 1"
} > "${custom}"
reset "Boot complete!;sleep 0.2;exit 0"
MICROOS_OPTS="${custom}" run
[[ "$(grep '^[spu] ' "${STATE}/opts-script-1")" == $'u \'ble-scan\' \'settings\' \'delete\' \'global\' \'ble_scan_always_enabled\'\ns \'new-one\' \'settings\' \'put\' \'global\' \'microos_test\' \'1\'' ]] \
    || fail "opts change: $(grep '^[spu] ' "${STATE}/opts-script-1")"
grep -qx "ble-scan" "${opts}" && fail "opts change: undone id kept in the stamp"
grep -qx "new-one" "${opts}" || fail "opts change: new id not stamped"
reset "Boot complete!;sleep 0.2;exit 0"
MICROOS_OPTS="${custom}" run
[[ ! -e "${STATE}/opts-script-1" ]] || fail "opts change: undo or new id run twice: $(cat "${STATE}/opts-script-1")"

rm -f "${opts}"
reset "Boot complete!;sleep 0.2;exit 0"
printf 'ok wifi-scan\nfail ble-scan\nabsent stk\n' > "${STATE}/opts-reply"
run
grep -q "guest setting ble-scan failed" "${STATE}/stderr" || fail "opts fail: not logged"
grep -qx "ble-scan" "${opts}" && fail "opts fail: failed id stamped"
grep -qx "stk" "${opts}" || fail "opts fail: absent package not stamped"
grep -q "android ready" "${STATE}/stderr" || fail "opts fail: not ready"
reset "Boot complete!;sleep 0.2;exit 0"
run
grep -qxF "s 'ble-scan' 'settings' 'put' 'global' 'ble_scan_always_enabled' '0'" "${STATE}/opts-script-1" || fail "opts fail: not retried"
grep -q "'wifi-scan'\|'stk'" "${STATE}/opts-script-1" && fail "opts fail: done ids retried"

rm -f "${opts}"
reset "Boot complete!;sleep 0.2;exit 0"
echo 5 > "${STATE}/opts-sleep"
start_ms=$(date +%s%3N)
MICROOS_OPTS_TIMEOUT_S=1 run
(( $(date +%s%3N) - start_ms < 4000 )) || fail "opts timeout: the start waited for the guest"
grep -q "guest settings timed out after 1 s, the next start retries the rest" "${STATE}/stderr" || fail "opts timeout: not logged: $(cat "${STATE}/stderr")"
grep -q "android ready" "${STATE}/stderr" || fail "opts timeout: not ready"
[[ ! -s "${opts}" ]] || fail "opts timeout: ids stamped: $(cat "${opts}")"
grep -q "notify --ready" "${STATE}/events" || fail "opts timeout: no ready notify"

reset "Boot complete!;sleep 0.2;exit 0"
MICROOS_OPTS="${T}/absent-opts" run
grep -q "absent-opts missing, no guest settings applied" "${STATE}/stderr" || fail "opts missing: no log"
grep -q "android ready" "${STATE}/stderr" || fail "opts missing: not ready"

glob=$(sed -n 's/^GAMESCOPE_WAYLAND_DISPLAY=//p' "${STATE}/env")
[[ "${glob}" == "${XDG_RUNTIME_DIR}/gamescope-0" ]] || fail "display: $(cat "${STATE}/stderr")"

for display in "" relative/gamescope-0 "${T}/gone-0"; do
    reset "exit 0"
    rc=0
    XDG_STATE_HOME="${STATE_HOME}" GAMESCOPE_WAYLAND_DISPLAY="${display}" "${run_script}" 2> "${STATE}/stderr" || rc=$?
    [[ "${rc}" == 1 ]] || fail "display '${display}': exit ${rc}"
    grep -q "no gamescope display at ${display:-unset}" "${STATE}/stderr" || fail "display '${display}': no reason: $(cat "${STATE}/stderr")"
    grep -q "lepton start" "${STATE}/events" && fail "display '${display}': lepton started"
done

printf 'width=960\nheight=640\n' > "${T}/display"
reset "Boot complete!;exit 0"
MICROOS_DISPLAY_FILE="${T}/display" run
[[ "${rc}" == 1 ]] && grep -q "no density in ${T}/display" "${STATE}/stderr" || fail "display file without a density: exit ${rc}: $(cat "${STATE}/stderr")"
grep -q "lepton start" "${STATE}/events" && fail "display file without a density: lepton started"

printf 'density=240\n' > "${T}/display"
reset "Boot complete!;exit 0"
MICROOS_DISPLAY_FILE="${T}/display" run
[[ "${rc}" == 0 ]] || fail "density: exit ${rc}: $(cat "${STATE}/stderr")"
grep -qx "ro.sf.lcd_density=240" "${odm}" || fail "density not taken from the display file: $(cat "${odm}")"

reset "Boot complete!;exit 0"
echo 125 > "${STATE}/other_rc"
run
[[ "${rc}" == 1 ]] && grep -q "podman container exists failed (rc=125), refusing" "${STATE}/stderr" || fail "podman error: exit ${rc}"

reset "Boot complete!;sleep 0.3;exit 0"
rc=0
env -u MICROOS_ANDROID_CONTEXT HOME="${T}/home" "${run_script}" 2> "${STATE}/stderr" || rc=$?
fixed="${MICROOS_ANDROID_DATA}/home/.local/share/lepton/contexts/android"
[[ "${rc}" == 0 ]] || fail "default context: exit ${rc}: $(cat "${STATE}/stderr")"
grep -qx "STEAM_COMPAT_DATA_PATH=${fixed}" "${STATE}/env" || fail "default context: $(grep STEAM_COMPAT_DATA_PATH "${STATE}/env")"
[[ -d "${fixed}/internal" && ! -e "${T}/home/.local/share/lepton/contexts/android" ]] || fail "default context: the private HOME was not used"
rm -rf "${T:?}/home" "${MICROOS_ANDROID_DATA:?}/home"
reset "Boot complete!;exit 0"
rc=0
MICROOS_ANDROID_CONTEXT="${T}/contexts/probe-lh-copy" "${run_script}" 2> "${STATE}/stderr" || rc=$?
[[ "${rc}" == 1 ]] && grep -qx "microos-android-run: ${T}/contexts/probe-lh-copy is not a android context, refusing" "${STATE}/stderr" \
    || fail "another context: exit ${rc}: $(cat "${STATE}/stderr")"
[[ ! -s "${STATE}/podman" && ! -s "${STATE}/events" ]] || fail "another context: podman or lepton ran"
reset "Boot complete!;sleep 0.3;exit 0"
run
[[ "${rc}" == 0 ]] || fail "android context: exit ${rc}: $(cat "${STATE}/stderr")"
grep -qx "lepton start android" "${STATE}/events" || fail "android context: lepton not run as start android: $(events)"
grep -qx "podman container exists lepton-android" "${STATE}/podman" || fail "android context: container not checked"
reset "exit 0"
"${stop_script}"
[[ "$(cat "${STATE}/podman")" == "podman stop -t 1 lepton-android" ]] || fail "stop: $(cat "${STATE}/podman")"
reset "exit 0"
: > "${STATE}/prefix"
"${stop_script}" --post 2> "${STATE}/stderr"
[[ "$(sed 's/^podman //' "${STATE}/podman")" == $'inspect -f {{ index .Config.Labels "PREFIX" }} lepton-android\nstop -t 1 lepton-android\nrm -fi lepton-android' ]] \
    || fail "post: $(cat "${STATE}/podman")"
reset "exit 0"
rc=0
"${stop_script}" --headless 2>/dev/null || rc=$?
[[ "${rc}" == 1 ]] || fail "stop with --headless: exit ${rc}"

reset "Boot complete!;exit 0"
run
grep -q EXTEND_TIMEOUT_USEC "${STATE}/events" && fail "same stamp extended the timeout"
grep -qx "notify --ready" "${STATE}/events" || fail "same stamp: no ready"

reset "Boot complete!;sleep 0.5;exit 0"
echo 5 > "${STATE}/keyboard-hold"
start_ms=$(date +%s%3N)
run
(( $(date +%s%3N) - start_ms < 4000 )) || fail "the keyboard install delayed the launch"
grep -q "android ready" "${STATE}/stderr" || fail "keyboard hold: not ready"
grep -qx "lepton start android" "${STATE}/events" || fail "keyboard hold: lepton not started"

reset "Boot complete!;exit 0"
echo false > "${STATE}/running"
mkdir -p "${MICROOS_ANDROID_DATA}"
echo "old boot" > "${MICROOS_ANDROID_DATA}/boot.log"
run
[[ "${rc}" == 1 ]] || fail "dead container exit ${rc}"
grep -q "android exited during boot, see ${MICROOS_ANDROID_DATA}/boot.log" "${STATE}/stderr" || fail "early exit not logged"
[[ ! -s "${MICROOS_ANDROID_DATA}/boot.log" ]] || fail "boot.log not truncated: $(cat "${MICROOS_ANDROID_DATA}/boot.log")"
grep -q "notify --ready" "${STATE}/events" && fail "ready sent for a dead container"
grep -q "Boot complete! but the container is not running or not booted" "${STATE}/stderr" || fail "dead container not logged"

reset "Boot complete!;exit 1"
echo 0 > "${STATE}/booted"
run
grep -q "notify --ready" "${STATE}/events" && fail "ready sent before sys.boot_completed"

reset "exit 0"
: > "${STATE}/nodes"
run
grep -qxF "mounts = [\"type=bind,source=${rc_override},destination=/system/etc/init/lineage-system.rc,ro\",\"type=bind,source=${odm},destination=/vendor/odm/etc/build.prop,ro\",\"type=bind,source=/dev/net/tun,destination=/dev/tun,rw\"]" "${conf}" || fail "no pad: mounts $(cat "${conf}")"

reset "sleep 0.5;exit 1"
printf 'I x: ok\nE SystemServer: Signature|privileged permissions not in privapp-permissions whitelist: {x}\n' > "${STATE}/logcat"
run
grep -q "not in privapp-permissions whitelist" "${MICROOS_ANDROID_DATA}/privapp-log" || fail "privapp flag not set"
grep -q "whitelist" "${MICROOS_ANDROID_DATA}/boot.log" || fail "boot log lacks the whitelist line"
reset "exit 0"
run
grep -qx "ro.control_privapp_permissions=log" "${odm}" || fail "privapp flag not applied"
grep -q "privapp log mode" "${STATE}/stderr" || fail "privapp log mode not logged"
rm -f "${MICROOS_ANDROID_DATA}/privapp-log"

reset "exit 0"
rm -f "${MICROOS_LEPTON}.off"
mv "${MICROOS_LEPTON}" "${MICROOS_LEPTON}.off"
run
mv "${MICROOS_LEPTON}.off" "${MICROOS_LEPTON}"
[[ "${rc}" == 1 ]] || fail "microos-lepton missing exit ${rc}"
[[ "$(cat "${MICROOS_RUNTIME_DIR}/start-failed")" == "${MICROOS_LEPTON} missing" ]] || fail "refusal reason not written"
reset "Boot complete!;exit 0"
mkdir -p "${MICROOS_RUNTIME_DIR}"
echo old > "${MICROOS_RUNTIME_DIR}/start-failed"
run
[[ ! -e "${MICROOS_RUNTIME_DIR}/start-failed" ]] || fail "refusal reason kept after a start"
reset "exit 0"
run
[[ "$(cat "${MICROOS_RUNTIME_DIR}/start-failed")" == "android exited during boot, see ${MICROOS_ANDROID_DATA}/boot.log" ]] || fail "early exit reason not written"
[[ ! -e "${STATE_HOME}/microos-lepton/lepton-install-requested" ]] || fail "a boot failure asked for a Lepton install"
reset "exit 0"
: > "${STATE}/no-lepton-dir"
run
[[ "${rc}" == 1 ]] && grep -qx "microos-android-run: Lepton is not installed. Install it in Steam." "${STATE}/stderr" \
    || fail "no Lepton install: exit ${rc}: $(cat "${STATE}/stderr")"
[[ -f "${STATE_HOME}/microos-lepton/lepton-install-requested" ]] || fail "no Lepton install: the install request not written"
[[ ! -s "${STATE_HOME}/microos-lepton/lepton-install-requested" ]] || fail "no Lepton install: the install request holds content"
[[ "$(cat "${MICROOS_RUNTIME_DIR}/start-failed")" == "Lepton is not installed. Install it in Steam." ]] \
    || fail "no Lepton install: the refusal text not written for ES-DE: $(cat "${MICROOS_RUNTIME_DIR}/start-failed")"
[[ "$(grep -c '^runtime$' "${STATE}/runtime-cmd")" == 1 ]] || fail "no Lepton install: runtime not called once: $(cat "${STATE}/runtime-cmd")"
reset "exit 0"
: > "${STATE}/unreviewed"
run
[[ "${rc}" == 1 ]] && grep -qx "microos-android-run: Lepton build 25772115 is not one MicroOS knows, refusing" "${STATE}/stderr" \
    || fail "unreviewed build: exit ${rc}: $(cat "${STATE}/stderr")"
[[ ! -e "${STATE_HOME}/microos-lepton/lepton-install-requested" ]] || fail "unreviewed build asked for a Lepton install"
reset "exit 0"
mv "${T}/lepton/images/rootfs/vendor/odm/etc/build.prop" "${T}/odm.off"
run
mv "${T}/odm.off" "${T}/lepton/images/rootfs/vendor/odm/etc/build.prop"
[[ "${rc}" == 1 ]] && grep -q "build.prop missing" "${STATE}/stderr" || fail "odm build.prop missing: exit ${rc}"

reset "pipe steam://open/games;Boot complete!;sleep 0.3;pipe steam://install/3029110;sleep 1.5;exit 0"
run
grep -qx "microos-android-run: android asked to open steam://open/games" "${STATE}/stderr" || fail "pipe before boot not read: $(cat "${STATE}/stderr")"
grep -qx "microos-android-run: android asked to open steam://install/3029110" "${STATE}/stderr" || fail "pipe after boot not read"
grep -q "pipe blocked" "${STATE}/events" && fail "a pipe write blocked"
timeout 1 bash -c 'echo late > "$1"' _ "${MICROOS_STEAM_PIPE}" && fail "the pipe reader outlived microos-android-run"

reset "pipe steam://open/games;exit 0"
: > "${STATE}/steam"
run
grep -q "android asked to open" "${STATE}/stderr" && fail "pipe read while Steam runs"
grep -q "pipe blocked" "${STATE}/events" || fail "the pipe had a reader while Steam runs"

reset "Boot complete!;exit 0"
rm -f "${MICROOS_STEAM_PIPE}"
mkdir -p "${MICROOS_STEAM_PIPE%/*}"
mkfifo "${MICROOS_STEAM_PIPE}"
run
[[ "${rc}" == 0 ]] || fail "configured pipe: exit ${rc}: $(cat "${STATE}/stderr")"

reset "pipe steam://open/games;Boot complete!;sleep 0.3;exit 0"
default_pipe="${MICROOS_ANDROID_DATA}/home/.steam/steam.pipe"
rm -rf "${MICROOS_ANDROID_DATA:?}/home" "${MICROOS_STEAM_PIPE}"
rc=0
env -u MICROOS_STEAM_PIPE XDG_STATE_HOME="${STATE_HOME}" "${run_script}" 2> "${STATE}/stderr" || rc=$?
[[ "${rc}" == 0 ]] || fail "pipe default: exit ${rc}: $(cat "${STATE}/stderr")"
[[ -p "${default_pipe}" ]] || fail "pipe default: the FIFO was not made on the first start"
grep -qx "microos-android-run: android asked to open steam://open/games" "${STATE}/stderr" \
    || fail "pipe default: not read from the Valve HOME: $(cat "${STATE}/stderr")"
rm -rf "${MICROOS_ANDROID_DATA:?}/home"

gapps_tree() {
    local set="${MICROOS_GAPPS}/mtg11-20230922.vending-36.6.25" file
    rm -rf "${MICROOS_GAPPS}" "${MICROOS_STUB_DIR}"
    mkdir -p "${set}/system/product/priv-app/Phonesky" "${set}/system/system_ext/etc/permissions" "${MICROOS_STUB_DIR}"
    echo apk > "${set}/system/product/priv-app/Phonesky/Phonesky.apk"
    echo xml > "${set}/system/system_ext/etc/permissions/privapp-permissions-google-se.xml"
    {
        echo "set=mtg11-20230922.vending-36.6.25"
        for file in system/product/priv-app/Phonesky/Phonesky.apk system/system_ext/etc/permissions/privapp-permissions-google-se.xml; do
            echo "$(sha256sum "${set}/${file}" | cut -d' ' -f1) $(stat -c %s "${set}/${file}") ${file}"
        done
    } > "${set}/STAMP"
    ln -s mtg11-20230922.vending-36.6.25 "${MICROOS_GAPPS}/current"
    echo jar > "${MICROOS_STUB_DIR}/restrictions-stub.jar"
    echo rc > "${MICROOS_STUB_DIR}/restrictions-stub.rc"
}
gset="${MICROOS_GAPPS}/mtg11-20230922.vending-36.6.25"

reset "Boot complete!;sleep 0.5;exit 0"
gapps_tree
rm -f "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp"
run
[[ "${rc}" == 0 ]] || fail "gapps on exit ${rc}: $(cat "${STATE}/stderr")"
for mount in "type=bind,source=${gset}/system/product/priv-app/Phonesky/Phonesky.apk,destination=/system/product/priv-app/Phonesky/Phonesky.apk,ro" \
    "type=bind,source=${gset}/system/system_ext/etc/permissions/privapp-permissions-google-se.xml,destination=/system/system_ext/etc/permissions/privapp-permissions-google-se.xml,ro" \
    "type=bind,source=${MICROOS_STUB_DIR}/restrictions-stub.jar,destination=/system/framework/restrictions-stub.jar,ro" \
    "type=bind,source=${MICROOS_STUB_DIR}/restrictions-stub.rc,destination=/system/etc/init/restrictions-stub.rc,ro"; do
    grep -qF "\"${mount}\"" "${conf}" || fail "gapps mount missing: ${mount}"
done
for _ in $(seq 1 40); do grep -q "gapps=mtg11" "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp" 2>/dev/null && break; sleep 0.05; done
grep -q "gapps=mtg11-20230922.vending-36.6.25" "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp" || fail "stamp lacks the gapps set"
grep -q "pm grant com.google.android.gms android.permission.ACCESS_FINE_LOCATION" "${STATE}/podman" || fail "first boot grants missing"
grep -q "cmd_real package compile" "${STATE}/podman" && fail "first boot compiles during a launch"

reset "Boot complete!;sleep 0.3;exit 0"
run
grep -q "pm grant" "${STATE}/podman" && fail "grants repeated with an unchanged stamp"

reset "Boot complete!;sleep 0.8;exit 0"
gapps_tree
rm -f "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp"
: > "${STATE}/grant_fail"
run
grep -q "a grant failed, the stamp stays unchanged" "${STATE}/stderr" || fail "failed grant not logged: $(cat "${STATE}/stderr")"
[[ ! -e "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp" ]] || fail "stamp written after a failed grant"

for broken in current stamp file size jar rc; do
    reset "exit 0"
    gapps_tree
    case "${broken}" in
        current) rm "${MICROOS_GAPPS}/current"; echo "3.0.5 3.0.3 gapps=mtg11-20230922.vending-36.6.25" > "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp" ;;
        stamp) rm "${gset}/STAMP" ;;
        file) chmod u+w "${gset}/system/product/priv-app/Phonesky"; rm "${gset}/system/product/priv-app/Phonesky/Phonesky.apk" ;;
        size) echo longer >> "${gset}/system/product/priv-app/Phonesky/Phonesky.apk" ;;
        jar) rm "${MICROOS_STUB_DIR}/restrictions-stub.jar" ;;
        rc) rm "${MICROOS_STUB_DIR}/restrictions-stub.rc" ;;
    esac
    run
    [[ "${rc}" == 1 ]] || fail "gapps ${broken} broken: exit ${rc}"
    grep -q "gapps tree incomplete, run microos-android gapps install" "${STATE}/stderr" || fail "gapps ${broken} broken: no refusal line"
    grep -q "lepton start" "${STATE}/events" && fail "gapps ${broken} broken: container started"
done
rm -rf "${MICROOS_GAPPS}" "${MICROOS_STUB_DIR}" "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp"

reset "Boot complete!;hold;exit 4"
start=$(date +%s%3N)
run
took=$(( $(date +%s%3N) - start ))
[[ "${rc}" == 4 ]] || fail "descendant holding the output: exit ${rc}"
(( took < 4000 )) || fail "descendant holding the output: took ${took} ms"
grep -q "lepton start exited with 4" "${STATE}/stderr" || fail "exit line not in the journal with a descendant holding the output"

reset "Boot complete!;sleep 1.5;exit 0"
SteamAppId=1234 "${run_script}" 2> "${STATE}/stderr" &
pid=$!
sleep 0.7
kill -TERM "${pid}"
rc=0
wait "${pid}" || rc=$?
grep -q "stop requested, waiting for lepton start" "${STATE}/stderr" || fail "TERM not noted"
grep -q "lepton start exited with 0" "${STATE}/stderr" || fail "exit line lost on TERM: $(cat "${STATE}/stderr")"

reset "steam-on;sleep 1.2;rmpipe;sleep 0.3;steam-off;sleep 2.5;exit 0"
run
[[ ! -e "${MICROOS_STEAM_PIPE}" ]] || fail "a file was created at the pipe path: $(ls -la "${MICROOS_STEAM_PIPE}")"

reset "sleep 0.4;rmpipe;exit 0"
run
[[ ! -e "${MICROOS_STEAM_PIPE}" ]] || fail "pipe removed under the reader: a file was created"

prefix_dir=$(mktemp -d /tmp/lepton-context.XXXXXXXX)
reset "exit 0"
echo "${prefix_dir}" > "${STATE}/prefix"
"${stop_script}" --post 2> "${STATE}/stderr"
[[ "$(sed 's/^podman //' "${STATE}/podman")" == $'inspect -f {{ index .Config.Labels "PREFIX" }} lepton-android\nstop -t 1 lepton-android\nrm -fi lepton-android' ]] \
    || fail "post calls: $(cat "${STATE}/podman")"
[[ ! -e "${prefix_dir}" ]] || fail "post: lepton prefix left"
reset "exit 0"
mkdir -p "${T}/keep"
echo "${T}/keep" > "${STATE}/prefix"
"${stop_script}" --post 2> "${STATE}/stderr"
[[ -d "${T}/keep" ]] || fail "post removed a prefix outside /tmp/lepton-context.*"
grep -q removed "${STATE}/stderr" && fail "post logged a removal it did not do"
stuck_dir=$(mktemp -d /tmp/lepton-context.XXXXXXXX)
mkdir -p "${stuck_dir}/sub"
: > "${stuck_dir}/sub/file"
chmod 0500 "${stuck_dir}/sub"
reset "exit 0"
echo "${stuck_dir}" > "${STATE}/prefix"
: > "${STATE}/unshare-fail"
"${stop_script}" --post 2> "${STATE}/stderr"
chmod 0700 "${stuck_dir}/sub"
rm -rf "${stuck_dir}"
grep -q "cannot remove ${stuck_dir}" "${STATE}/stderr" || fail "failed removal not logged: $(cat "${STATE}/stderr")"
grep -q "removed the leftover" "${STATE}/stderr" && fail "failed removal logged as removed"
unit="${repo}/data/usr/lib/systemd/user/microos-android.service"
for line in StopPropagatedFrom=gamescope-session-plus@android.service Type=notify NotifyAccess=all \
    TimeoutStartSec=120 TimeoutStopSec=20 SuccessExitStatus=143 \
    ExecStartPre=/usr/bin/podman\ rm\ -fi\ lepton-android \
    ExecStart=/usr/libexec/microos/microos-android-run \
    ExecStop=/usr/libexec/microos/microos-android-stop \
    ExecStopPost=/usr/libexec/microos/microos-android-stop\ --post; do
    grep -qF "${line}" "${unit}" || fail "unit lacks ${line}: $(cat "${unit}")"
done
grep -qE '^(BindsTo|Wants)=' "${unit}" && fail "the unit pulls a start"
grep -q SuccessExitStatus=137 "${unit}" && fail "the unit hides a 137"

if (( failures )); then
    echo "play-unit-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "play-unit-test: ok"
