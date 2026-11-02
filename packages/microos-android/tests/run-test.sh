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
export MICROOS_SESSION_WATCH="${T}/bin/session-watch"
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
export GAMESCOPE_WAYLAND_DISPLAY=gamescope-0

printf 'ro.odm.build.id=RQ3A\n' > "${T}/lepton/images/rootfs/vendor/odm/etc/build.prop"
echo 3.0.5 > "${T}/lepton/version.txt"
echo 3.0.3 > "${T}/lepton/images/version.txt"
real_fingerprint="lepton/lineage_lepton_arm64_only/lepton_arm64_only:11/RQ3A.211001.001/root09251955:userdebug/test-keys"
printf 'ro.build.version.sdk=30\nro.system.build.fingerprint=%s\n' "${real_fingerprint}" \
    > "${T}/lepton/images/rootfs/system/build.prop"
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
    "container exists "*)
        [[ ! -e "${STATE}/exists" ]] || exit 0
        exit 1
        ;;
    "container inspect -f {{.State.Running}} lepton-android") echo true ;;
    "exec lepton-android /system/bin/getprop sys.boot_completed") echo 1 ;;
    "exec lepton-android /system/bin/pidof logd") echo 123 ;;
    "exec lepton-android /system/bin/logcat "*) cat "${STATE}/logcat" ;;
    "exec lepton-android /system/bin/pm grant "*) ;;
    "exec lepton-android /system/bin/dumpsys activity activities")
        if [[ -e "${STATE}/activities-after" ]]; then
            n=$(( $(cat "${STATE}/reads" 2>/dev/null || echo 0) + 1 ))
            printf '%s\n' "${n}" > "${STATE}/reads"
            (( n > 1 )) && { cat "${STATE}/activities-after"; exit 0; }
        fi
        cat "${STATE}/activities" 2>/dev/null
        ;;
    "exec lepton-android /system/bin/am start -W "*) ;;
    "inspect -f {{ index .Config.Labels \"PREFIX\" }} lepton-android") cat "${STATE}/prefix" 2>/dev/null || true ;;
    "stop -t 1 lepton-android"|"rm -fi lepton-android") ;;
    *) exit 99 ;;
esac
STUB
cat > "${T}/bin/stat" <<'STUB'
#!/usr/bin/bash
if [[ " $* " == *" -c %u "* ]]; then
    [[ ! -e "${STATE}/other-owner" ]] || { echo 4242; exit 0; }
fi
exec /usr/bin/stat "$@"
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
cat > "${T}/bin/session-watch" <<STUB
#!/usr/bin/bash
echo "watch start" >> "\${STATE}/watch"
trap 'echo "watch stop" >> "\${STATE}/watch"; exit 0' TERM INT
while :; do sleep 0.05; done
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
    : > "${STATE}/watch"
    : > "${STATE}/podman"
    printf 'I ActivityManager: start\n' > "${STATE}/logcat"
    printf '/dev/input/event10\n' > "${STATE}/nodes"
    printf '  mResumedActivity: ActivityRecord{f00 u0 com.example.app/.Main t7}\n    state=RESUMED\n' \
        > "${STATE}/activities"
    rm -f "${STATE}/activities-after" "${STATE}/reads"
    printf 'on boot\n    bugreport\n    keycodes 114 115 116\non post-fs-data\n    exec -- /bin/true\n' > "${rc_file}"
    rm -f "${MICROOS_STEAM_PIPE}"
    printf 'starting\nBoot complete!\nsleep 0.2\nexit 0\n' > "${STATE}/script"
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
[[ "$(grep -c '^watch start$' "${STATE}/watch")" == 1 ]] || fail "the run did not start the session watch: $(cat "${STATE}/watch")"
[[ "$(grep -c '^watch stop$' "${STATE}/watch")" == 1 ]] || fail "the run did not stop the session watch: $(cat "${STATE}/watch")"

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
[[ "$(head -n 1 <<< "${stamp}")" == "3.0.5 3.0.3 gapps=none" ]] || fail "the first boot wrote no stamp: ${stamp}"
grep -qxF "rootfs=3.0.3 ${real_fingerprint}" <<< "${stamp}" || fail "the first boot wrote no rootfs identity from the real key: ${stamp}"
stamp_sha=$(sha256sum <<< "${stamp}")
rc=0
"${run_script}" --check > "${STATE}/check-out" 2> "${STATE}/stderr" || rc=$?
[[ "${rc}" == 0 ]] || fail "the check after the first boot exited ${rc}: $(cat "${STATE}/stderr")"
[[ "$(sha256sum <<< "$(cat "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")")" == "${stamp_sha}" ]] \
    || fail "the check rewrote the stamp: $(cat "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")"
printf '3.0.2\n' > "${T}/lepton/images/version.txt"
rc=0
"${run_script}" --check > "${STATE}/check-out" 2> "${STATE}/stderr" || rc=$?
[[ "${rc}" == 2 && "$(cat "${STATE}/check-out")" == downgrade ]] \
    || fail "an older runtime after that start: exit ${rc} out $(cat "${STATE}/check-out"): $(cat "${STATE}/stderr")"
printf '3.0.3\n' > "${T}/lepton/images/version.txt"
: > "${STATE}/events"
run
[[ "${rc}" == 0 ]] || fail "second start exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(cat "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")" == "${stamp}" ]] || fail "the second start rewrote the stamp"
grep -q "boot bound extended" "${STATE}/stderr" && fail "the second start extended the boot bound"

case_name="rootfs identity, the fallback key"
reset
printf 'ro.build.version.sdk=30\nro.build.fingerprint=fingerprint-fallback\n' > "${T}/lepton/images/rootfs/system/build.prop"
run
[[ "${rc}" == 0 ]] || fail "a runtime with only the fallback key: exit ${rc}: $(cat "${STATE}/stderr")"
grep -qxF 'rootfs=3.0.3 fingerprint-fallback' "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp" \
    || fail "the fallback key gave no identity: $(cat "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")"
printf 'ro.build.version.sdk=30\nro.system.build.fingerprint=fingerprint-system\nro.build.fingerprint=fingerprint-fallback\n' \
    > "${T}/lepton/images/rootfs/system/build.prop"
run
grep -qxF 'rootfs=3.0.3 fingerprint-system' "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp" \
    || fail "the system key did not win over the fallback: $(cat "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")"
printf 'ro.build.version.sdk=30\nro.system.build.fingerprint=%s\n' "${real_fingerprint}" \
    > "${T}/lepton/images/rootfs/system/build.prop"

case_name="display name"
display_case() {
    local name=$1 socket=$2 expect=$3
    reset
    rm -f "${XDG_RUNTIME_DIR}/gamescope-0"
    mkdir -p "${XDG_RUNTIME_DIR}/dir"
    [[ -z "${socket}" ]] \
        || python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${socket}"
    rc=0
    GAMESCOPE_WAYLAND_DISPLAY="${name}" "${run_script}" 2> "${STATE}/stderr" || rc=$?
    rm -f "${XDG_RUNTIME_DIR}/gamescope-0" "${XDG_RUNTIME_DIR}/dir/gamescope-0"
    if [[ "${expect}" == accepted ]]; then
        [[ "${rc}" == 0 ]] || fail "display '${name}': the run refused it: exit ${rc}: $(cat "${STATE}/stderr")"
        grep -q "no gamescope display" "${STATE}/stderr" && fail "display '${name}': refused: $(cat "${STATE}/stderr")"
        grep -qx "GAMESCOPE_WAYLAND_DISPLAY=${name}" "${STATE}/env" || fail "display '${name}': not passed unchanged: $(cat "${STATE}/env")"
        grep -qx "lepton start android" "${STATE}/events" || fail "display '${name}': lepton did not start: $(cat "${STATE}/events")"
    else
        [[ "${rc}" == 1 ]] || fail "display '${name}': exit ${rc}"
        grep -q "no gamescope display at ${name}" "${STATE}/stderr" || fail "display '${name}': no reason: $(cat "${STATE}/stderr")"
        [[ ! -s "${STATE}/events" ]] || fail "display '${name}': lepton started: $(cat "${STATE}/events")"
    fi
}
display_case gamescope-0 "${XDG_RUNTIME_DIR}/gamescope-0" accepted
display_case dir/gamescope-0 "${XDG_RUNTIME_DIR}/dir/gamescope-0" accepted
display_case "${XDG_RUNTIME_DIR}/dir/gamescope-0" "${XDG_RUNTIME_DIR}/dir/gamescope-0" refused
display_case dir/../dir/gamescope-0 "${XDG_RUNTIME_DIR}/dir/gamescope-0" refused
display_case gone/gamescope-0 "" refused
rmdir "${XDG_RUNTIME_DIR}/dir"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${XDG_RUNTIME_DIR}/gamescope-0"

case_name="pad wait"
reset
: > "${STATE}/nodes"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
mounted | grep -qF "/dev/input/" && fail "a pad node was mounted with none present: $(mounted)"

case_name="stop"
reset
: > "${STATE}/podman"
rc=0
timeout 5 "${stop_script}" 2> "${STATE}/stderr" || rc=$?
[[ "${rc}" == 0 ]] || fail "a resumed activity that stays resumed: exit ${rc}: $(cat "${STATE}/stderr")"
reads=$(grep -c 'dumpsys activity activities' "${STATE}/podman")
(( reads >= 9 && reads <= 12 )) || fail "a resumed activity that stays resumed: ${reads} reads: $(cat "${STATE}/podman")"
[[ "$(tail -n 1 "${STATE}/podman")" == "podman stop -t 1 lepton-android" ]] \
    || fail "a resumed activity that stays resumed: no stop: $(cat "${STATE}/podman")"
grep -q "did not report com.example.app/.Main stopped" "${STATE}/stderr" \
    || fail "a resumed activity that stays resumed: no log: $(cat "${STATE}/stderr")"

reset
printf '  mResumedActivity: ActivityRecord{f00 u0 com.example.app/.Main t7}\n    state=RESUMED\n' \
    > "${STATE}/activities"
printf '  mResumedActivity: ActivityRecord{f00 u0 com.android.launcher3/.uioverrides.QuickstepLauncher t7}\n    state=RESUMED\n' \
    > "${STATE}/activities-after"
: > "${STATE}/podman"
"${stop_script}" 2> "${STATE}/stderr"
[[ "$(grep -c 'dumpsys activity activities' "${STATE}/podman")" == 2 ]] \
    || fail "a stopped activity: the second read did not settle it: $(cat "${STATE}/podman")"
grep -q "did not report" "${STATE}/stderr" && fail "a stopped activity: a false complaint: $(cat "${STATE}/stderr")"

reset
printf '  mResumedActivity: ActivityRecord{f00 u0 com.example.app/.Main t7}\n    state=RESUMED\n' \
    > "${STATE}/activities"
printf '  mResumedActivity: ActivityRecord{f00 u0 com.example.app/.Main t7}\n    state=RESUMED\n  ActivityRecord{f00 u0 com.example.app/.Main t7}\n    state=STOPPED\n' \
    > "${STATE}/activities-after"
: > "${STATE}/podman"
"${stop_script}" 2> "${STATE}/stderr"
[[ "$(grep -c 'dumpsys activity activities' "${STATE}/podman")" == 2 ]] \
    || fail "a record that reads STOPPED: $(cat "${STATE}/podman")"
grep -q "did not report" "${STATE}/stderr" && fail "a record that reads STOPPED: a false complaint: $(cat "${STATE}/stderr")"

reset
printf '  mResumedActivity: ActivityRecord{f00 u0 com.example.app/Main$Inner t7}\n    state=RESUMED\n' \
    > "${STATE}/activities"
printf '  mResumedActivity: ActivityRecord{f00 u0 com.example.app/Main$Inner t7}\n    state=RESUMED\n  ActivityRecord{f00 u0 com.example.app/Main$Inner t7}\n    state=STOPPED\n' \
    > "${STATE}/activities-after"
: > "${STATE}/podman"
"${stop_script}" 2> "${STATE}/stderr"
[[ "$(grep -c 'dumpsys activity activities' "${STATE}/podman")" == 2 ]] \
    || fail "an activity name with a regex character: $(cat "${STATE}/podman")"
grep -q "did not report com.example.app/Main\$Inner stopped" "${STATE}/stderr" \
    && fail "an activity name with a regex character: the name was read as a regex: $(cat "${STATE}/stderr")"

reset
printf '  mResumedActivity: ActivityRecord{f00 u0 com.android.launcher3/.uioverrides.QuickstepLauncher t7}\n    state=RESUMED\n' \
    > "${STATE}/activities"
: > "${STATE}/podman"
"${stop_script}" 2> "${STATE}/stderr"
[[ "$(grep -c 'dumpsys activity activities' "${STATE}/podman")" == 1 ]] \
    || fail "the launcher resumed: the stop waited: $(cat "${STATE}/podman")"
[[ "$(tail -n 1 "${STATE}/podman")" == "podman stop -t 1 lepton-android" ]] \
    || fail "the launcher resumed: no stop: $(cat "${STATE}/podman")"
grep -q "did not report" "${STATE}/stderr" && fail "the launcher resumed: a complaint: $(cat "${STATE}/stderr")"

reset
printf '  mResumedActivity: ActivityRecord{f00 u0 com.example.app/.Main t7}\n    state=RESUMED\n' \
    > "${STATE}/activities"
printf '  mResumedActivity: ActivityRecord{f00 u0 com.example.app/.Main t7}\n    state=RESUMED\n' \
    > "${STATE}/activities-after"
: > "${STATE}/podman"
rc=0
MICROOS_STOP_S=0.5 timeout 5 "${stop_script}" 2> "${STATE}/stderr" || rc=$?
[[ "${rc}" == 0 ]] || fail "a slow guest: exit ${rc} after the 1 s deadline: $(cat "${STATE}/stderr")"
reads=$(grep -c 'dumpsys activity activities' "${STATE}/podman")
(( reads >= 2 && reads <= 4 )) || fail "a slow guest: ${reads} reads: $(cat "${STATE}/podman")"
[[ "$(tail -n 1 "${STATE}/podman")" == "podman stop -t 1 lepton-android" ]] \
    || fail "a slow guest: no stop after the wait: $(cat "${STATE}/podman")"
grep -q "did not report com.example.app/.Main stopped" "${STATE}/stderr" \
    || fail "a slow guest: no log: $(cat "${STATE}/stderr")"

reset
: > "${STATE}/activities"
: > "${STATE}/podman"
"${stop_script}" 2> "${STATE}/stderr"
grep -q "am start -W -a android.intent.action.MAIN" "${STATE}/podman" \
    || fail "stop with no resumed activity: the HOME intent did not run: $(cat "${STATE}/podman")"
grep -q "did not report" "${STATE}/stderr" && fail "stop with no resumed activity: a false complaint: $(cat "${STATE}/stderr")"

reset
: > "${STATE}/podman"
"${stop_script}" --post 2> "${STATE}/stderr"
[[ "$(sed 's/^podman //' "${STATE}/podman")" == $'inspect -f {{ index .Config.Labels "PREFIX" }} lepton-android\nstop -t 1 lepton-android\nrm -fi lepton-android' ]] \
    || fail "post calls: $(cat "${STATE}/podman")"
mkdir -p "${MICROOS_RUNTIME_DIR}"
for marker in ready start-done start-failed session.env first-boot; do
    printf 'x\n' > "${MICROOS_RUNTIME_DIR}/${marker}"
done
printf 'card-lost\n' > "${MICROOS_RUNTIME_DIR}/end-reason"
"${stop_script}" --post 2> "${STATE}/stderr"
for marker in ready start-done start-failed session.env first-boot; do
    [[ ! -e "${MICROOS_RUNTIME_DIR}/${marker}" ]] || fail "post kept the marker ${marker}: $(ls -A "${MICROOS_RUNTIME_DIR}")"
done
[[ -f "${MICROOS_RUNTIME_DIR}/end-reason" ]] || fail "post removed the end reason: $(ls -A "${MICROOS_RUNTIME_DIR}")"
recorded=$(mktemp -d /tmp/lepton-context.XXXXXXXX)
printf '%s\n' "${recorded}" > "${MICROOS_RUNTIME_DIR}/lepton-prefix"
: > "${STATE}/podman"
"${stop_script}" --post 2> "${STATE}/stderr"
[[ ! -e "${recorded}" ]] || fail "post kept the prefix the run recorded: ${recorded}"
[[ ! -e "${MICROOS_RUNTIME_DIR}/lepton-prefix" ]] || fail "post kept the prefix record: $(ls -A "${MICROOS_RUNTIME_DIR}")"
grep -qF "removed the leftover ${recorded}" "${STATE}/stderr" || fail "post did not log the recorded prefix: $(cat "${STATE}/stderr")"
kept=$(mktemp -d /tmp/lepton-context.XXXXXXXX)
printf '%s\n' "${kept}" > "${MICROOS_RUNTIME_DIR}/lepton-prefix"
: > "${STATE}/exists"
"${stop_script}" --post 2> "${STATE}/stderr"
rm -f "${STATE}/exists"
[[ -d "${kept}" ]] || fail "post removed a prefix while the container exists"
[[ -f "${MICROOS_RUNTIME_DIR}/lepton-prefix" ]] || fail "post dropped the record while the container exists"
grep -qF "lepton-android exists, kept ${kept}" "${STATE}/stderr" || fail "post did not log the kept prefix: $(cat "${STATE}/stderr")"
rm -rf "${kept:?}"
outside=$(mktemp -d "${T}/lepton-context.XXXXXXXX")
printf '%s\n' "${outside}" > "${MICROOS_RUNTIME_DIR}/lepton-prefix"
: > "${STATE}/podman"
"${stop_script}" --post 2> "${STATE}/stderr"
[[ -d "${outside}" ]] || fail "post removed a path outside /tmp/lepton-context.*"
grep -q "removed the leftover" "${STATE}/stderr" && fail "post logged a removal it did not do"
[[ -f "${MICROOS_RUNTIME_DIR}/lepton-prefix" ]] || fail "post dropped a record it did not remove"
rm -rf "${outside:?}"
mismatch=$(mktemp -d /tmp/lepton-context.XXXXXXXX)
held=$(mktemp -d /tmp/lepton-context.XXXXXXXX)
printf '%s\n' "${held}" > "${STATE}/prefix"
printf '%s\n' "${mismatch}" > "${MICROOS_RUNTIME_DIR}/lepton-prefix"
: > "${STATE}/podman"
"${stop_script}" --post 2> "${STATE}/stderr"
[[ -d "${mismatch}" ]] || fail "post removed the recorded prefix while the label named another"
[[ -d "${held}" ]] || fail "post removed the labelled prefix when the record disagreed"
[[ -f "${MICROOS_RUNTIME_DIR}/lepton-prefix" ]] || fail "post dropped a record it did not remove"
grep -qF "the run recorded ${mismatch}, the container holds ${held}, removing neither" "${STATE}/stderr" \
    || fail "post did not log the mismatch: $(cat "${STATE}/stderr")"
rm -rf "${mismatch:?}" "${held:?}" "${STATE}/prefix"
symlinked=$(mktemp -d /tmp/lepton-context.XXXXXXXX)
rmdir "${symlinked}"
ln -s "${T}/outside" "${symlinked}"
mkdir -p "${T}/outside"
printf 'kept\n' > "${T}/outside/file"
printf '%s\n' "${symlinked}" > "${MICROOS_RUNTIME_DIR}/lepton-prefix"
: > "${STATE}/podman"
"${stop_script}" --post 2> "${STATE}/stderr"
[[ "$(cat "${T}/outside/file" 2>/dev/null)" == kept ]] || fail "post followed the prefix link"
[[ -L "${symlinked}" ]] || fail "post removed the prefix link"
[[ -f "${MICROOS_RUNTIME_DIR}/lepton-prefix" ]] || fail "post dropped the record of a prefix link it kept"
rm -rf "${symlinked:?}" "${T}/outside"
owned=$(mktemp -d /tmp/lepton-context.XXXXXXXX)
printf '%s\n' "${owned}" > "${MICROOS_RUNTIME_DIR}/lepton-prefix"
printf 'root\n' > "${STATE}/other-owner"
: > "${STATE}/podman"
"${stop_script}" --post 2> "${STATE}/stderr"
rm -f "${STATE}/other-owner"
[[ -d "${owned}" ]] || fail "post removed a prefix owned by another uid"
[[ -f "${MICROOS_RUNTIME_DIR}/lepton-prefix" ]] || fail "post dropped the record of a prefix it kept"
rm -rf "${owned:?}"
gone=$(mktemp -d /tmp/lepton-context.XXXXXXXX)
printf '%s\n' "${gone}" > "${MICROOS_RUNTIME_DIR}/lepton-prefix"
rmdir "${gone}"
: > "${STATE}/podman"
"${stop_script}" --post 2> "${STATE}/stderr"
[[ ! -e "${MICROOS_RUNTIME_DIR}/lepton-prefix" ]] || fail "post kept the record of a gone prefix: $(cat "${MICROOS_RUNTIME_DIR}/lepton-prefix")"
grep -qF "removed the record of the gone ${gone}" "${STATE}/stderr" || fail "post did not log the gone prefix: $(cat "${STATE}/stderr")"
race=$(mktemp -d /tmp/lepton-context.XXXXXXXX)
late=$(mktemp -d /tmp/lepton-context.XXXXXXXX)
printf '%s\n' "${race}" > "${MICROOS_RUNTIME_DIR}/lepton-prefix"
printf '%s\n' "${late}" > "${STATE}/late"
: > "${STATE}/replace-record"
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
echo "podman $*" >> "${STATE}/podman"
case "$*" in
    "container exists "*)
        if [[ -e "${STATE}/replace-record" ]]; then
            rm -f "${STATE}/replace-record"
            cat "${STATE}/late" > "${MICROOS_RUNTIME_DIR}/lepton-prefix"
        fi
        [[ ! -e "${STATE}/exists" ]] || exit 0
        exit 1
        ;;
    "container inspect -f {{.State.Running}} lepton-android") echo true ;;
    "exec lepton-android /system/bin/getprop sys.boot_completed") echo 1 ;;
    "exec lepton-android /system/bin/pidof logd") echo 123 ;;
    "exec lepton-android /system/bin/logcat "*) cat "${STATE}/logcat" ;;
    "exec lepton-android /system/bin/pm grant "*) ;;
    "exec lepton-android /system/bin/dumpsys activity activities")
        if [[ -e "${STATE}/activities-after" ]]; then
            n=$(( $(cat "${STATE}/reads" 2>/dev/null || echo 0) + 1 ))
            printf '%s\n' "${n}" > "${STATE}/reads"
            (( n > 1 )) && { cat "${STATE}/activities-after"; exit 0; }
        fi
        cat "${STATE}/activities" 2>/dev/null
        ;;
    "exec lepton-android /system/bin/am start -W "*) ;;
    "inspect -f {{ index .Config.Labels \"PREFIX\" }} lepton-android") cat "${STATE}/prefix" 2>/dev/null || true ;;
    "stop -t 1 lepton-android"|"rm -fi lepton-android") ;;
    *) exit 99 ;;
esac
STUB
chmod 0755 "${T}/bin/podman"
: > "${STATE}/podman"
"${stop_script}" --post 2> "${STATE}/stderr"
[[ -f "${MICROOS_RUNTIME_DIR}/lepton-prefix" ]] || fail "post removed a record a start replaced meanwhile"
[[ "$(cat "${MICROOS_RUNTIME_DIR}/lepton-prefix")" == "${late}" ]] \
    || fail "post left $(cat "${MICROOS_RUNTIME_DIR}/lepton-prefix") in the record"
[[ -d "${late}" ]] || fail "post removed the prefix a start recorded meanwhile"
[[ ! -d "${race}" ]] || fail "post kept the prefix its own read named"
grep -qF "removed the leftover ${race}" "${STATE}/stderr" || fail "post did not remove the prefix it read: $(cat "${STATE}/stderr")"
grep -qF "kept the record ${MICROOS_RUNTIME_DIR}/lepton-prefix, it names another prefix now" "${STATE}/stderr" \
    || fail "post did not log the record it kept: $(cat "${STATE}/stderr")"
rm -rf "${race:?}" "${late:?}"
rm -f "${STATE}/late" "${STATE}/replace-record"
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
echo "podman $*" >> "${STATE}/podman"
case "$*" in
    "container exists "*)
        [[ ! -e "${STATE}/exists" ]] || exit 0
        exit 1
        ;;
    "container inspect -f {{.State.Running}} lepton-android") echo true ;;
    "exec lepton-android /system/bin/getprop sys.boot_completed") echo 1 ;;
    "exec lepton-android /system/bin/pidof logd") echo 123 ;;
    "exec lepton-android /system/bin/logcat "*) cat "${STATE}/logcat" ;;
    "exec lepton-android /system/bin/pm grant "*) ;;
    "exec lepton-android /system/bin/dumpsys activity activities")
        if [[ -e "${STATE}/activities-after" ]]; then
            n=$(( $(cat "${STATE}/reads" 2>/dev/null || echo 0) + 1 ))
            printf '%s\n' "${n}" > "${STATE}/reads"
            (( n > 1 )) && { cat "${STATE}/activities-after"; exit 0; }
        fi
        cat "${STATE}/activities" 2>/dev/null
        ;;
    "exec lepton-android /system/bin/am start -W "*) ;;
    "inspect -f {{ index .Config.Labels \"PREFIX\" }} lepton-android") cat "${STATE}/prefix" 2>/dev/null || true ;;
    "stop -t 1 lepton-android"|"rm -fi lepton-android") ;;
    *) exit 99 ;;
esac
STUB
chmod 0755 "${T}/bin/podman"
named=$(mktemp -d /tmp/lepton-context.XXXXXXXX)
printf '%s\n' "${named}" > "${STATE}/prefix"
unset MICROOS_RUNTIME_DIR XDG_RUNTIME_DIR
"${stop_script}" --post 2> "${STATE}/stderr"
export MICROOS_RUNTIME_DIR="${T}/run/microos-android" XDG_RUNTIME_DIR="${T}/xdg"
[[ ! -e "${named}" ]] || fail "post with no runtime dir kept the label prefix"
grep -qF "removed the leftover ${named}" "${STATE}/stderr" \
    || fail "post with no runtime dir did not clean the label prefix: $(cat "${STATE}/stderr")"
rm -f "${STATE}/prefix"
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

case_name="check, no Lepton"
reset
mv "${T}/bin/lepton" "${T}/bin/lepton.off"
rc=0
"${run_script}" --check > "${STATE}/check-out" 2> "${STATE}/stderr" || rc=$?
mv "${T}/bin/lepton.off" "${T}/bin/lepton"
[[ "${rc}" == 1 ]] || fail "an absent Lepton exited ${rc}, not 1"
[[ -z "$(cat "${STATE}/check-out")" ]] || fail "an absent Lepton printed $(cat "${STATE}/check-out")"

case_name="check, the old context path"
reset
mkdir -p "${HOME}/.local/share/lepton/contexts/microemu-play"
rc=0
"${run_script}" --check > "${STATE}/check-out" 2> "${STATE}/stderr" || rc=$?
rm -rf "${HOME}/.local/share/lepton/contexts/microemu-play"
[[ "${rc}" == 2 ]] || fail "the old context path exited ${rc}, not 2: $(cat "${STATE}/stderr")"
[[ "$(cat "${STATE}/check-out")" == old-path ]] || fail "the old context path printed $(cat "${STATE}/check-out")"

case_name="check, a downgrade"
reset
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
printf 'tool 3.0.9 gapps=none\nrootfs=3.0.9 fingerprint-old\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp"
printf 'ro.system.build.fingerprint=fingerprint-new\nro.build.version.sdk=30\n' > "${T}/lepton/images/rootfs/system/build.prop"
printf '3.0.3\n' > "${T}/lepton/images/version.txt"
rc=0
"${run_script}" --check > "${STATE}/check-out" 2> "${STATE}/stderr" || rc=$?
[[ "${rc}" == 2 ]] || fail "an older runtime exited ${rc}, not 2: $(cat "${STATE}/stderr")"
[[ "$(cat "${STATE}/check-out")" == downgrade ]] || fail "an older runtime printed $(cat "${STATE}/check-out")"

case_name="check, no snapshot taken"
reset
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
printf 'tool 3.0.3 gapps=none\nrootfs=3.0.3 fingerprint-base\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp"
mkdir -p "${T}/snaps-check"
export MICROOS_LEPTON_SNAPSHOTS="${T}/snaps-check"
cp "${T}/bin/lepton" "${T}/lepton.saved"
cat > "${T}/bin/lepton" <<STUB
#!/usr/bin/bash
if [[ "\${1:-}" == runtime ]]; then
    printf '%s\n' "${T}/lepton"
    printf 'runtime\n' >> "\${STATE}/lepton-calls"
    exit 0
fi
exit 1
STUB
chmod 0755 "${T}/bin/lepton"
rc=0
"${run_script}" --check > "${STATE}/check-out" 2> "${STATE}/stderr" || rc=$?
[[ "${rc}" == 0 ]] || fail "a read only check exited ${rc}: $(cat "${STATE}/stderr")"
[[ -z "$(find "${MICROOS_LEPTON_SNAPSHOTS}" -mindepth 1 2>/dev/null)" ]] \
    || fail "the check wrote to the snapshot dir: $(ls -A "${MICROOS_LEPTON_SNAPSHOTS}")"
mv -f "${T}/lepton.saved" "${T}/bin/lepton"
chmod 0755 "${T}/bin/lepton"
unset MICROOS_LEPTON_SNAPSHOTS

case_name="check, a matching stamp"
reset
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
printf 'tool 3.0.3 gapps=none\nrootfs=3.0.3 fingerprint-new\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp"
printf 'ro.system.build.fingerprint=fingerprint-new\nro.build.version.sdk=30\n' > "${T}/lepton/images/rootfs/system/build.prop"
printf '3.0.3\n' > "${T}/lepton/images/version.txt"
rc=0
"${run_script}" --check > "${STATE}/check-out" 2> "${STATE}/stderr" || rc=$?
[[ "${rc}" == 0 ]] || fail "a matching stamp exited ${rc}: $(cat "${STATE}/stderr")"
[[ ! -e "${MICROOS_RUNTIME_DIR}/start-failed" ]] || fail "the check wrote a refusal marker"

private_gms() {
    mkdir -p "${MICROOS_ANDROID_CONTEXT}/baked/data_overlay/system"
    printf '<packages>\n<package name="com.google.android.gms" codePath="/system/priv-app/PrebuiltGmsCore" version="231234567" userId="10123">\n</package>\n</packages>\n' \
        > "${MICROOS_ANDROID_CONTEXT}/baked/data_overlay/system/packages.xml"
}

case_name="GMS guard"
reset
private_gms
printf 'tool 3.0.3 gapps=mtg11\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp"
run
[[ "${rc}" == 1 ]] || fail "the GMS guard exited ${rc}: $(cat "${STATE}/stderr")"
[[ "$(reason_of)" == gapps-missing ]] || fail "the GMS guard wrote $(reason_of)"
grep -q "gapps install" "${STATE}/stderr" || fail "the GMS guard: no message: $(cat "${STATE}/stderr")"

case_name="GMS guard, no stamp"
reset
private_gms
run
[[ "${rc}" == 1 ]] || fail "the GMS guard with no stamp exited ${rc}: $(cat "${STATE}/stderr")"
[[ "$(reason_of)" == gapps-missing ]] || fail "the GMS guard with no stamp wrote $(reason_of)"

case_name="GMS guard, a removed set boots"
reset
private_gms
printf 'tool 3.0.3 gapps=none\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp"
run
[[ "${rc}" == 0 ]] || fail "gapps=none exited ${rc}: $(cat "${STATE}/stderr")"
[[ ! -e "${MICROOS_RUNTIME_DIR}/end-reason" ]] || fail "gapps=none wrote $(reason_of)"

case_name="GMS guard, GMS outside priv-app boots"
reset
mkdir -p "${MICROOS_ANDROID_CONTEXT}/baked/data_overlay/system"
printf '<packages>\n<package name="com.google.android.gms" codePath="/data/app/com.google.android.gms" version="1">\n</package>\n</packages>\n' \
    > "${MICROOS_ANDROID_CONTEXT}/baked/data_overlay/system/packages.xml"
printf 'tool 3.0.3 gapps=mtg11\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp"
run
[[ "${rc}" == 1 ]] || fail "an updated GMS outside priv-app exited ${rc}: $(cat "${STATE}/stderr")"
[[ -z "$(reason_of)" ]] || fail "an updated GMS outside priv-app wrote the GMS reason $(reason_of)"
grep -q "gapps tree incomplete" "${STATE}/stderr" || fail "an updated GMS outside priv-app: $(cat "${STATE}/stderr")"

case_name="GMS guard, a multi-line stamp keeps its set"
reset
mkdir -p "${MICROOS_ANDROID_CONTEXT}/baked/data_overlay/system" "${T}/gapps/mtg11"
printf 'packages\n' > "${MICROOS_ANDROID_CONTEXT}/baked/data_overlay/system/packages.xml"
printf 'ro.build.version.sdk=30\nro.system.build.fingerprint=fingerprint-base\n' > "${T}/lepton/images/rootfs/system/build.prop"
printf '3.0.5 3.0.3 gapps=none\nrootfs=3.0.3 fingerprint-base\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp"
run
[[ "${rc}" == 0 ]] || fail "a multi-line stamp with gapps=none exited ${rc}: $(cat "${STATE}/stderr")"
mounted | grep -q "gapps" && fail "a multi-line stamp with gapps=none bound a GApps set: $(mounted)"
grep -qx 'rootfs=3.0.3 fingerprint-base' "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp" \
    || fail "the rootfs line was lost: $(cat "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")"

if (( failures )); then
    echo "run-test: ${failures} failure(s), ${skipped} skipped" >&2
    exit 1
fi
echo "run-test: ok, ${skipped} skipped"
