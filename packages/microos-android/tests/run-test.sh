#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/data/usr/libexec/microos"
run_script="${libexec}/microos-android-run"
stop_script="${libexec}/microos-android-stop"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin" "${T}/lepton/images/rootfs/system/etc/init" "${T}/lepton/images/rootfs_overlay" \
    "${T}/lepton/images/rootfs/vendor/odm/etc" "${T}/lepton/sysbake" "${T}/lepton/liblepton"
export STATE="${T}/state"
export MICROOS_LEPTON="${T}/bin/lepton"
export MICROOS_PAD_NODES="${T}/bin/pad-nodes"
export MICROOS_KEYBOARD_INSTALL="${T}/bin/keyboard-install"
export MICROOS_ANDROID_CONTEXT="${T}/contexts/android"
export MICROOS_RUNTIME_DIR="${T}/run/microos-android"
export MICROOS_ANDROID_DATA="${T}/data/android"
export MICROOS_POLL_S=0.05
export MICROOS_OPTS="${T}/absent-opts"
export MICROOS_GAPPS="${T}/gapps"
export MICROOS_STUB_DIR="${T}/stub"
export MICROOS_DISPLAY_FILE="${repo}/data/usr/share/microos-android/display"
export XDG_STATE_HOME="${T}/xdg-state"
export XDG_RUNTIME_DIR="${T}/xdg"
mkdir -p "${XDG_RUNTIME_DIR}"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${XDG_RUNTIME_DIR}/gamescope-0"
export GAMESCOPE_WAYLAND_DISPLAY="${XDG_RUNTIME_DIR}/gamescope-0"

printf 'ro.odm.build.id=RQ3A\n' > "${T}/lepton/images/rootfs/vendor/odm/etc/build.prop"
echo 3.0.5 > "${T}/lepton/version.txt"
echo 3.0.3 > "${T}/lepton/images/version.txt"
rc_file="${T}/lepton/images/rootfs/system/etc/init/lineage-system.rc"
derived="${MICROOS_RUNTIME_DIR}/lineage-system.rc"
conf="${MICROOS_RUNTIME_DIR}/containers.conf"

cat > "${T}/bin/lepton" <<STUB
#!/usr/bin/bash
if [[ "\${1:-}" == runtime ]]; then
    printf '%s\n' "${T}/lepton"
    exit 0
fi
echo "lepton \$*" >> "\${STATE}/events"
env > "\${STATE}/env"
echo "Boot complete!"
sleep 0.2
exit 0
STUB
cat > "${T}/bin/pad-nodes" <<'STUB'
#!/usr/bin/bash
cat "${STATE}/nodes"
STUB
cat > "${T}/bin/keyboard-install" <<'STUB'
#!/usr/bin/bash
echo "$*" >> "${STATE}/keyboard"
STUB
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
echo "podman $*" >> "${STATE}/podman"
case "$*" in
    "container exists "*) exit 1 ;;
    "container inspect -f {{.State.Running}} lepton-android") echo true ;;
    "exec lepton-android /system/bin/getprop sys.boot_completed") echo 1 ;;
    "exec lepton-android /system/bin/pidof logd") echo 123 ;;
    "exec lepton-android /system/bin/logcat "*) cat "${STATE}/logcat" ;;
    "exec lepton-android /system/bin/pm grant "*) ;;
    "inspect -f {{ index .Config.Labels \"PREFIX\" }} lepton-android") cat "${STATE}/prefix" 2>/dev/null || true ;;
    "stop -t 1 lepton-android"|"rm -fi lepton-android") ;;
    *) exit 99 ;;
esac
STUB
cat > "${T}/bin/pgrep" <<'STUB'
#!/usr/bin/bash
[[ "$*" == "-x steam" ]] && exit 1
exit 99
STUB
cat > "${T}/bin/systemd-notify" <<'STUB'
#!/usr/bin/bash
echo "notify $*" >> "${STATE}/events"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"
export MICROOS_STEAM_PIPE="${T}/steam.pipe"

failures=0
skipped=0
fail() { echo "FAIL ${case_name}: $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}" "${MICROOS_RUNTIME_DIR}" "${MICROOS_ANDROID_CONTEXT}" "${MICROOS_ANDROID_DATA}"
    mkdir -p "${STATE}" "${T}/lepton/images/rootfs/system/etc/init"
    rm -rf "${T}/lepton/images/rootfs_overlay"
    mkdir -p "${T}/lepton/images/rootfs_overlay"
    : > "${STATE}/events"
    : > "${STATE}/podman"
    printf 'I ActivityManager: start\n' > "${STATE}/logcat"
    printf '/dev/input/event10\n' > "${STATE}/nodes"
    printf 'on boot\n    bugreport\n    keycodes 114 115 116\non post-fs-data\n    exec -- /bin/true\n' > "${rc_file}"
    rm -f "${MICROOS_STEAM_PIPE}"
}

run() {
    rc=0
    "${run_script}" 2> "${STATE}/stderr" || rc=$?
}

reason_of() { sed -n 's/^\([a-z-]*\)$/\1/p' "${MICROOS_RUNTIME_DIR}/end-reason" 2>/dev/null; }
mounted() { sed -n 's/^mounts = \[\(.*\)\]$/\1/p' "${conf}" 2>/dev/null; }

case_name="keycodes derived"
reset
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(stat -c %a "${derived}")" == 644 ]] || fail "derived file mode $(stat -c %a "${derived}")"
sed '3d' "${rc_file}" > "${STATE}/want-rc"
cmp -s "${derived}" "${STATE}/want-rc" || fail "derived file differs from the source minus line 3: $(diff "${STATE}/want-rc" "${derived}")"
[[ ! -e "${derived}.new" ]] || fail "the temp file was left"
grep -q "stripped keycodes from line 3 of ${rc_file} ($(sha256sum < "${rc_file}" | cut -d' ' -f1))" "${STATE}/stderr" \
    || fail "line number and source sha not logged: $(cat "${STATE}/stderr")"
mounted | grep -qF "type=bind,source=${derived},destination=/system/etc/init/lineage-system.rc,ro" \
    || fail "the override is not mounted: $(mounted)"
mounted | grep -qF "type=bind,source=/dev/input/event10,destination=/dev/input/event10,rw" || fail "the pad node is not mounted: $(mounted)"
[[ ! -s "${MICROOS_RUNTIME_DIR}/end-reason" ]] || fail "an end reason was written on a clean start"

case_name="whitespace tolerated"
reset
printf 'on boot\n\t  keycodes\t114  115\t116  \n' > "${rc_file}"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
printf 'on boot\n' > "${STATE}/want-rc"
cmp -s "${derived}" "${STATE}/want-rc" || fail "derived file differs: $(diff "${STATE}/want-rc" "${derived}")"

case_name="no overlay tree"
reset
rm -rf "${T}/lepton/images/rootfs_overlay"
mkdir -p "${T}/lepton/images/rootfs/vendor/etc/init"
printf 'on boot\n    keycodes 114 115 116\n' > "${rc_file}"
printf 'on boot\n    keycodes 120\n' > "${T}/lepton/images/rootfs/vendor/etc/init/vendor.rc"
run
[[ "${rc}" == 1 ]] || fail "exit ${rc}"
[[ "$(reason_of)" == rc-keycodes ]] || fail "reason $(reason_of)"
grep -q "a keycodes line outside ${rc_file}: ${T}/lepton/images/rootfs/vendor/etc/init/vendor.rc, refusing" "${STATE}/stderr" \
    || fail "a keycodes line in a rootfs rc was missed: $(cat "${STATE}/stderr")"
[[ ! -e "${derived}" && ! -e "${derived}.new" ]] || fail "a file was written on a refusal"
rm -rf "${T}/lepton/images/rootfs/vendor/etc/init"

case_name="no overlay tree, clean"
reset
rm -rf "${T}/lepton/images/rootfs_overlay"
run
[[ "${rc}" == 0 ]] || fail "a runtime without images/rootfs_overlay: exit ${rc}: $(cat "${STATE}/stderr")"
sed '3d' "${rc_file}" > "${STATE}/want-rc"
cmp -s "${derived}" "${STATE}/want-rc" || fail "derived file differs"

case_name="unreadable rc"
if (( EUID == 0 )); then
    skipped=$((skipped + 1))
    echo "SKIP unreadable rc: root reads a 000 file" >&2
else
    reset
    mkdir -p "${T}/lepton/images/rootfs/vendor/etc/init"
    printf 'on boot\n' > "${T}/lepton/images/rootfs/vendor/etc/init/locked.rc"
    chmod 000 "${T}/lepton/images/rootfs/vendor/etc/init/locked.rc"
    run
    chmod 644 "${T}/lepton/images/rootfs/vendor/etc/init/locked.rc" 2>/dev/null || true
    [[ "${rc}" == 1 ]] || fail "an unreadable rc: exit ${rc}: $(cat "${STATE}/stderr")"
    [[ "$(reason_of)" == rc-keycodes ]] || fail "reason $(reason_of)"
    grep -q "cannot read ${T}/lepton/images/rootfs/vendor/etc/init/locked.rc, refusing" "${STATE}/stderr" \
        || fail "no log: $(cat "${STATE}/stderr")"
    [[ ! -e "${derived}" && ! -e "${derived}.new" ]] || fail "a file was written on a refusal"
    rm -rf "${T}/lepton/images/rootfs/vendor/etc/init"
fi

case_name="symlinked rc"
reset
mkdir -p "${T}/lepton/images/rootfs/vendor/etc/init"
printf 'on boot\n    keycodes 114 115 116\n' > "${T}/outside.rc"
ln -s "${T}/outside.rc" "${T}/lepton/images/rootfs/vendor/etc/init/linked.rc"
run
[[ "${rc}" == 1 ]] || fail "a symlinked rc: exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(reason_of)" == rc-keycodes ]] || fail "reason $(reason_of)"
grep -q "linked.rc is a link, refusing" "${STATE}/stderr" || fail "no log: $(cat "${STATE}/stderr")"
[[ "$(cat "${T}/outside.rc")" == $'on boot\n    keycodes 114 115 116' ]] || fail "the symlink target was read or changed"
[[ ! -e "${derived}" && ! -e "${derived}.new" ]] || fail "a file was written on a refusal"
rm -rf "${T}/outside.rc" "${T}/lepton/images/rootfs/vendor/etc/init"

case_name="missing final newline"
reset
printf 'on boot\n    keycodes 114 115 116' > "${rc_file}"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
sed '2d' "${rc_file}" > "${STATE}/want-rc"
cmp -s "${derived}" "${STATE}/want-rc" || fail "a missing final newline was added or lost: $(cat -A "${derived}")"

case_name="no match"
reset
printf 'on boot\n    keycodes 114 115\n' > "${rc_file}"
run
[[ "${rc}" == 1 ]] || fail "exit ${rc}"
[[ "$(reason_of)" == rc-keycodes ]] || fail "reason $(reason_of)"
grep -q "has no keycodes 114 115 116 line" "${STATE}/stderr" || fail "no log: $(cat "${STATE}/stderr")"
[[ ! -e "${derived}" && ! -e "${derived}.new" ]] || fail "a file was written on a refusal"
[[ ! -s "${STATE}/events" ]] || fail "lepton ran on a refusal: $(cat "${STATE}/events")"

case_name="two matching lines"
reset
printf 'on boot\n    keycodes 114 115 116\n    keycodes 114 115 116\n' > "${rc_file}"
run
[[ "${rc}" == 1 ]] || fail "exit ${rc}"
[[ "$(reason_of)" == rc-keycodes ]] || fail "reason $(reason_of)"
grep -q "has 2 keycodes lines, not one" "${STATE}/stderr" || fail "no log: $(cat "${STATE}/stderr")"
[[ ! -e "${derived}" && ! -e "${derived}.new" ]] || fail "a file was written on a refusal"

case_name="another keycodes line"
reset
printf 'on boot\n    keycodes 114 115 116\n    keycodes 120\n' > "${rc_file}"
run
[[ "${rc}" == 1 ]] || fail "exit ${rc}"
[[ "$(reason_of)" == rc-keycodes ]] || fail "reason $(reason_of)"
grep -q "has 2 keycodes lines, not one" "${STATE}/stderr" || fail "no log: $(cat "${STATE}/stderr")"
[[ ! -e "${derived}" && ! -e "${derived}.new" ]] || fail "a file was written on a refusal"

case_name="keycodes in another rc"
reset
printf 'on boot\n    keycodes 114 115 116\n' > "${rc_file}"
mkdir -p "${T}/lepton/images/rootfs/vendor/etc/init"
printf 'on boot\n    keycodes 114 115 116\n' > "${T}/lepton/images/rootfs/vendor/etc/init/vendor.rc"
run
[[ "${rc}" == 1 ]] || fail "exit ${rc}"
[[ "$(reason_of)" == rc-keycodes ]] || fail "reason $(reason_of)"
grep -q "a keycodes line outside ${rc_file}: ${T}/lepton/images/rootfs/vendor/etc/init/vendor.rc, refusing" "${STATE}/stderr" \
    || fail "no log: $(cat "${STATE}/stderr")"
[[ ! -e "${derived}" && ! -e "${derived}.new" ]] || fail "a file was written on a refusal"
rm -rf "${T}/lepton/images/rootfs/vendor/etc/init"

case_name="keycodes in the overlay"
reset
printf 'on boot\n    keycodes 114 115 116\n' > "${rc_file}"
mkdir -p "${T}/lepton/images/rootfs_overlay/vendor/etc/init"
printf 'on boot\n    keycodes 114 115 116\n' > "${T}/lepton/images/rootfs_overlay/vendor/etc/init/vendor.rc"
run
[[ "${rc}" == 1 ]] || fail "exit ${rc}"
[[ "$(reason_of)" == rc-keycodes ]] || fail "reason $(reason_of)"
grep -q "a keycodes line outside" "${STATE}/stderr" || fail "no log: $(cat "${STATE}/stderr")"
[[ ! -e "${derived}" ]] || fail "a file was written on a refusal"

case_name="overlay ships the file"
reset
printf 'on boot\n    keycodes 114 115 116\n' > "${rc_file}"
mkdir -p "${T}/lepton/images/rootfs_overlay/system/etc/init"
printf 'on boot\n' > "${T}/lepton/images/rootfs_overlay/system/etc/init/lineage-system.rc"
run
[[ "${rc}" == 1 ]] || fail "exit ${rc}"
[[ "$(reason_of)" == rc-keycodes ]] || fail "reason $(reason_of)"
grep -q "ships system/etc/init/lineage-system.rc in images/rootfs_overlay" "${STATE}/stderr" || fail "no log: $(cat "${STATE}/stderr")"
[[ ! -e "${derived}" ]] || fail "a file was written on a refusal"

case_name="second start keeps the stamp"
reset
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
stamp=$(cat "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")
[[ "${stamp}" == "3.0.5 3.0.3 gapps=none" ]] || fail "the first boot wrote no stamp: ${stamp}"
: > "${STATE}/events"
run
[[ "${rc}" == 0 ]] || fail "second start exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(cat "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")" == "${stamp}" ]] || fail "the second start rewrote the stamp"
grep -q "boot bound extended" "${STATE}/stderr" && fail "the second start extended the boot bound"

case_name="pad wait"
reset
: > "${STATE}/nodes"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
mounted | grep -qF "/dev/input/" && fail "a pad node was mounted with none present: $(mounted)"

case_name="stop"
reset
: > "${STATE}/podman"
"${stop_script}"
[[ "$(sed 's/^podman //' "${STATE}/podman")" == "stop -t 1 lepton-android" ]] || fail "stop calls: $(cat "${STATE}/podman")"
reset
: > "${STATE}/podman"
"${stop_script}" --post 2> "${STATE}/stderr"
[[ "$(sed 's/^podman //' "${STATE}/podman")" == $'inspect -f {{ index .Config.Labels "PREFIX" }} lepton-android\nstop -t 1 lepton-android\nrm -fi lepton-android' ]] \
    || fail "post calls: $(cat "${STATE}/podman")"
rc=0
"${stop_script}" --bogus 2>/dev/null || rc=$?
[[ "${rc}" == 1 ]] || fail "unknown verb exit ${rc}"

case_name="stop during boot"
reset
cat > "${T}/bin/lepton" <<STUB
#!/usr/bin/bash
if [[ "\${1:-}" == runtime ]]; then
    printf '%s\n' "${T}/lepton"
    exit 0
fi
echo "lepton \$*" >> "\${STATE}/events"
env > "\${STATE}/env"
while IFS= read -r step; do
    case "\${step}" in
        sleep*) sleep "\${step#sleep }" ;;
        exit*) exit "\${step#exit }" ;;
        *) echo "\${step}" ;;
    esac
done < "\${STATE}/script"
STUB
chmod 0755 "${T}/bin/lepton"
printf 'starting\nsleep 3\nexit 0\n' > "${STATE}/script"
rm -f "${MICROOS_LEPTON_STEAM_PIPE:-${MICROOS_STEAM_PIPE}}"
mkfifo "${MICROOS_STEAM_PIPE}"
rc=0
"${run_script}" 2> "${STATE}/stderr" &
pid=$!
for _ in $(seq 1 100); do grep -q "starting" "${STATE}/stderr" 2>/dev/null && break; sleep 0.05; done
kill -TERM "${pid}"
wait "${pid}" || rc=$?
[[ "${rc}" == 143 ]] || fail "a stop during the boot exited ${rc}, not 143: $(cat "${STATE}/stderr")"
[[ ! -e "${MICROOS_RUNTIME_DIR}/start-failed" ]] || fail "a stop during the boot wrote a failure: $(cat "${MICROOS_RUNTIME_DIR}/start-failed")"
grep -q "stop requested, waiting for lepton start" "${STATE}/stderr" || fail "the stop was not noted: $(cat "${STATE}/stderr")"

case_name="stop after ready"
reset
printf 'starting\nBoot complete!\nsleep 3\nexit 0\n' > "${STATE}/script"
: > "${STATE}/logcat"
rm -f "${MICROOS_STEAM_PIPE}"
mkfifo "${MICROOS_STEAM_PIPE}"
rc=0
"${run_script}" 2> "${STATE}/stderr" &
pid=$!
for _ in $(seq 1 100); do grep -q "android ready" "${STATE}/stderr" 2>/dev/null && break; sleep 0.05; done
kill -TERM "${pid}"
wait "${pid}" || rc=$?
[[ "${rc}" == 143 ]] || fail "a stop after ready exited ${rc}, not 143: $(cat "${STATE}/stderr")"

case_name="unit stop status"
unit="${repo}/data/usr/lib/systemd/user/microos-android.service"
grep -qx SuccessExitStatus=143 "${unit}" || fail "the unit does not treat 143 as a success: $(cat "${unit}")"
grep -qE '^SuccessExitStatus=.*\b137\b' "${unit}" && fail "the unit hides a 137: $(cat "${unit}")"
grep -qx TimeoutStopSec=20 "${unit}" || fail "the stop bound is not 20 s"
grep -qx 'ExecStop=/usr/libexec/microos/microos-android-stop' "${unit}" || fail "the unit has no single stop owner"
grep -qx 'ExecStopPost=/usr/libexec/microos/microos-android-stop --post' "${unit}" || fail "the unit has no post stop"

if (( failures )); then
    echo "run-test: ${failures} failure(s), ${skipped} skipped" >&2
    exit 1
fi
echo "run-test: ok, ${skipped} skipped"
