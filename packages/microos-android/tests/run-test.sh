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
export MICROOS_LSFG_WRITER="${T}/lsfg/microos-android-lsfg"
export MICROOS_ANDROID_LSFG_DIR="${T}/lsfg-layer"
export MICROOS_ANDROID_CONTEXT="${T}/contexts/android"
export MICROOS_CONTENT="${T}/content"
export MICROOS_SYSTEM_CARD="${T}/system-card"
export MICROOS_TEST=1
export MICROOS_ANDROID_UID="$(id -u)"
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
    unshare*) shift; exec "$@" ;;
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
cat > "${T}/bin/findmnt" <<STUB
#!/usr/bin/bash
printf '%s\n' "\$*" >> "\${STATE}/findmnt"
last=\${!#}
[[ "\${last}" == "${T}/content" || "\${last}" == "${T}/content/"* ]] || exit 1
row=\$(cat "\${STATE}/mount-row" 2>/dev/null) || row=
case "\$*" in
    *--mountpoint*) echo "\${row:-ext4 CARD1-0000 rw}" ;;
    *) echo "CARD1-0000 ext4 rw" ;;
esac
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
mkdir -p "${T}/lsfg"
cat > "${MICROOS_LSFG_WRITER}" <<'STUB'
#!/usr/bin/bash
trap 'cat "${MICROOS_RUNTIME_DIR}/lsfg-writer.pid" > "${STATE}/lsfg-pidfile" 2>/dev/null; echo "lsfg stop" >> "${STATE}/lsfg"; exit 0' TERM
env > "${STATE}/lsfg-env"
printf '%s\n' "$$" > "${STATE}/lsfg-self"
echo "lsfg start" >> "${STATE}/lsfg"
while :; do sleep 0.05; done
STUB
chmod 0755 "${T}/bin/"* "${MICROOS_LSFG_WRITER}"
export PATH="${T}/bin:${PATH}"
export MICROOS_STEAM_PIPE="${T}/steam.pipe"

failures=0
skipped=0
fail() { echo "FAIL ${case_name}: $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}" "${MICROOS_RUNTIME_DIR}" "${MICROOS_ANDROID_CONTEXT}" "${MICROOS_ANDROID_DATA}"
    rm -rf "${MICROOS_ANDROID_LSFG_DIR}" "${XDG_STATE_HOME}/microos-lsfg" "${T}/steam"
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
    echo mmcblk0 > "${MICROOS_SYSTEM_CARD}"
}

run() {
    rc=0
    "${run_script}" 2> "${STATE}/stderr" || rc=$?
}

reason_of() { sed -n 's/^\([a-z-]*\)$/\1/p' "${MICROOS_RUNTIME_DIR}/end-reason" 2>/dev/null; }

lock_free() {
    local lock="${XDG_STATE_HOME}/microos-android/storage.lock" n=0 fd
    [[ -e "${lock}" ]] || return 0
    until exec {fd}>>"${lock}" && flock -n -x "${fd}"; do
        exec {fd}>&-
        (( ++n < 100 )) || return 1
        sleep 0.05
    done
    exec {fd}>&-
}
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

lsfg_layer() {
    mkdir -p "${MICROOS_ANDROID_LSFG_DIR}"
    : > "${MICROOS_ANDROID_LSFG_DIR}/libVkLayer_lsfg.so"
}

lsfg_state() {
    mkdir -p "${XDG_STATE_HOME}/microos-lsfg"
    python3 -c 'import json, sys; json.dump({"install": sys.argv[2], "branch_ok": sys.argv[3] == "true", "library": sys.argv[4]}, open(sys.argv[1], "w"))' \
        "${XDG_STATE_HOME}/microos-lsfg/state.json" "$@"
}

lsfg_dll() {
    mkdir -p "$1/steamapps/common/Lossless Scaling"
    : > "$1/steamapps/common/Lossless Scaling/Lossless.dll"
}

no_dll() {
    mounted | grep -q 'destination=/vendor/etc/lsfg/Lossless.dll' && fail "$1: Lossless.dll bound: $(mounted)"
    grep -qx MICROOS_ANDROID_LSFG_DLL=0 "${STATE}/lsfg-env" || fail "$1: the writer was not told 0: $(grep LSFG "${STATE}/lsfg-env")"
    grep -qF "$2, no Lossless.dll bind" "${STATE}/stderr" || fail "$1: no log: $(cat "${STATE}/stderr")"
}

case_name="lsfg layer bound"
reset
lsfg_layer
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
mounted | grep -qF "\"type=bind,source=${MICROOS_ANDROID_LSFG_DIR},destination=/data/local/debug/vulkan,ro\"" \
    || fail "the layer dir is not bound: $(mounted)"
grep -qx MICROOS_ANDROID_LSFG_LAYER=1 "${STATE}/lsfg-env" || fail "the writer was not told 1: $(grep LSFG "${STATE}/lsfg-env")"
grep -qF "frame generation layer from ${MICROOS_ANDROID_LSFG_DIR}" "${STATE}/stderr" || fail "no log: $(cat "${STATE}/stderr")"
[[ "$(cat "${STATE}/lsfg")" == $'lsfg start\nlsfg stop' ]] || fail "the writer did not start and stop once: $(cat "${STATE}/lsfg")"
[[ -s "${STATE}/lsfg-pidfile" && "$(cat "${STATE}/lsfg-pidfile")" == "$(cat "${STATE}/lsfg-self")" ]] \
    || fail "the pid file named $(cat "${STATE}/lsfg-pidfile" 2>/dev/null), the writer is $(cat "${STATE}/lsfg-self")"
[[ ! -e "${MICROOS_RUNTIME_DIR}/lsfg-writer.pid" ]] || fail "the run left the pid file"
no_dll "no state.json" "cannot read ${XDG_STATE_HOME}/microos-lsfg/state.json"

case_name="lsfg layer absent"
reset
mkdir -p "${MICROOS_ANDROID_LSFG_DIR}"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
mounted | grep -q 'destination=/data/local/debug/vulkan' && fail "an empty layer dir was bound: $(mounted)"
grep -qx MICROOS_ANDROID_LSFG_LAYER=0 "${STATE}/lsfg-env" || fail "the writer was not told 0: $(grep LSFG "${STATE}/lsfg-env")"
grep -qF "no ${MICROOS_ANDROID_LSFG_DIR}/libVkLayer_lsfg.so, no frame generation layer" "${STATE}/stderr" \
    || fail "no log: $(cat "${STATE}/stderr")"

case_name="lsfg layer dir refused"
for dir in "${T}/lsfg,layer" "${T}/lsfg"$'\t'"layer" /run/media/micro/CARD1/layer; do
    reset
    mkdir -p "${dir}" 2>/dev/null && : > "${dir}/libVkLayer_lsfg.so"
    MICROOS_ANDROID_LSFG_DIR="${dir}" run
    [[ "${rc}" == 0 ]] || fail "${dir}: exit ${rc}: $(cat "${STATE}/stderr")"
    mounted | grep -q 'destination=/data/local/debug/vulkan' && fail "${dir}: bound: $(mounted)"
    grep -qx MICROOS_ANDROID_LSFG_LAYER=0 "${STATE}/lsfg-env" || fail "${dir}: the writer was not told 0"
    case "${dir}" in
        /run/media/*) want="${dir} is on a card, no frame generation layer" ;;
        *) want="${dir} holds a comma, quote, apostrophe, backslash or control character, no frame generation layer" ;;
    esac
    grep -qF "${want}" "${STATE}/stderr" || fail "${dir}: no log: $(cat "${STATE}/stderr")"
    [[ "${dir}" == /run/media/* ]] || rm -rf "${dir:?}"
done

case_name="lsfg writer missing"
reset
MICROOS_LSFG_WRITER="${T}/absent-writer" run
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
grep -qF "${T}/absent-writer missing, no frame generation writer" "${STATE}/stderr" || fail "no log: $(cat "${STATE}/stderr")"

case_name="lsfg dll present"
reset
lsfg_layer
lsfg_state installed true "${T}/steam"
lsfg_dll "${T}/steam"
dll="$(readlink -m "${T}/steam/steamapps/common/Lossless Scaling/Lossless.dll")"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
mounted | grep -qF "\"type=bind,source=${dll},destination=/vendor/etc/lsfg/Lossless.dll,ro\"" || fail "no DLL bind: $(mounted)"
grep -qx MICROOS_ANDROID_LSFG_DLL=1 "${STATE}/lsfg-env" || fail "the writer was not told 1: $(grep LSFG "${STATE}/lsfg-env")"
grep -qF "Lossless.dll from ${dll}" "${STATE}/stderr" || fail "no log: $(cat "${STATE}/stderr")"

case_name="lsfg dll absent"
reset
lsfg_layer
lsfg_state installed true "${T}/steam"
run
no_dll "absent" "${T}/steam/steamapps/common/Lossless Scaling/Lossless.dll is not a regular file"

case_name="lsfg dll a link"
reset
lsfg_layer
lsfg_dll "${T}/steam-real"
mkdir -p "${T}/steam/steamapps/common/Lossless Scaling"
ln -s "${T}/steam-real/steamapps/common/Lossless Scaling/Lossless.dll" "${T}/steam/steamapps/common/Lossless Scaling/Lossless.dll"
lsfg_state installed true "${T}/steam"
run
rm -rf "${T}/steam-real"
no_dll "a link" "${T}/steam/steamapps/common/Lossless Scaling/Lossless.dll is not a regular file"

case_name="lsfg dll on a card"
reset
lsfg_layer
lsfg_state installed true /run/media/micro/CARD1/SteamLibrary
run
no_dll "a card library" "/run/media/micro/CARD1/SteamLibrary/steamapps/common/Lossless Scaling/Lossless.dll is on a card"
reset
lsfg_layer
ln -s /run/media/micro/CARD1/SteamLibrary "${T}/steam"
lsfg_state installed true "${T}/steam"
run
no_dll "a link to a card library" "/run/media/micro/CARD1/SteamLibrary/steamapps/common/Lossless Scaling/Lossless.dll is on a card"

case_name="lsfg dll with a quote"
for c in , '"' "'" '\' $'\t' $'\x1b'; do
    reset
    lsfg_layer
    lib="${T}/steam/lib${c}rary"
    lsfg_state installed true "${lib}"
    lsfg_dll "${lib}"
    run
    [[ "${rc}" == 0 ]] || fail "${c}: exit ${rc}: $(cat "${STATE}/stderr")"
    no_dll "${c}" "${lib}/steamapps/common/Lossless Scaling/Lossless.dll holds a comma, quote, apostrophe, backslash or control character"
done

case_name="lsfg dll not on a working branch"
reset
lsfg_layer
lsfg_state installed false "${T}/steam"
lsfg_dll "${T}/steam"
run
no_dll "branch_ok false" "Lossless Scaling is not on a working branch"
reset
lsfg_layer
lsfg_state installing true "${T}/steam"
lsfg_dll "${T}/steam"
run
no_dll "installing" "Lossless Scaling is not installed"

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
    unshare*) shift; exec "$@" ;;
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
stop_default() { sed -n 's/^[A-Z_]*="${'"$1"':-\([0-9]*\)}"$/\1/p' "${stop_script}"; }
guest_ms=$(( $(stop_default MICROOS_GUEST_TIMEOUT) * 1000 ))
writer_ms=$(( $(stop_default MICROOS_LSFG_TIMEOUT_S) * 1000 + 1000 ))
clear_ms=$(( $(stop_default MICROOS_LSFG_CLEAR_TIMEOUT_S) * 1000 ))
home_ms=$(( 2 * guest_ms + $(stop_default MICROOS_STOP_WAIT_MS) + guest_ms ))
budget_ms=$(( writer_ms + clear_ms + home_ms + 1000 ))
(( guest_ms == 1000 && writer_ms == 6000 && clear_ms == 3000 && budget_ms == 14000 )) \
    || fail "the stop budget is writer ${writer_ms} + clear ${clear_ms} + activity, HOME and wait ${home_ms} + podman stop 1000 = ${budget_ms} ms, not 14000"
(( budget_ms <= 15000 )) || fail "the stop's worst case ${budget_ms} ms is not well under the 20 s bound"
grep -qF "TIMEOUT_S = float(os.environ.get(\"MICROOS_LSFG_TIMEOUT_S\") or $(stop_default MICROOS_LSFG_TIMEOUT_S))" \
    "${libexec}/microos-android-lsfg" || fail "the writer and the stop read different MICROOS_LSFG_TIMEOUT_S defaults"
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
    mkdir -p "${MICROOS_ANDROID_CONTEXT}/baked/data_overlay/system" "${MICROOS_ANDROID_CONTEXT}/external"
    printf 'storage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
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
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external"
printf 'storage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
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
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external"
printf 'storage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
mkdir -p "${MICROOS_ANDROID_CONTEXT}/baked/data_overlay/system" "${T}/gapps/mtg11"
printf 'packages\n' > "${MICROOS_ANDROID_CONTEXT}/baked/data_overlay/system/packages.xml"
printf 'ro.build.version.sdk=30\nro.system.build.fingerprint=fingerprint-base\n' > "${T}/lepton/images/rootfs/system/build.prop"
printf '3.0.5 3.0.3 gapps=none\nrootfs=3.0.3 fingerprint-base\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp"
run
[[ "${rc}" == 0 ]] || fail "a multi-line stamp with gapps=none exited ${rc}: $(cat "${STATE}/stderr")"
mounted | grep -q "gapps" && fail "a multi-line stamp with gapps=none bound a GApps set: $(mounted)"
grep -qx 'rootfs=3.0.3 fingerprint-base' "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp" \
    || fail "the rootfs line was lost: $(cat "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")"

case_name="storage, a card stub not empty"
reset
echo none > "${MICROOS_SYSTEM_CARD}"
mkdir -p "${MICROOS_CONTENT}/MicroOS/Android/0123456789abcdef" "${MICROOS_ANDROID_CONTEXT}/external"
printf 'card=CARD1-0000\nstorage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
printf 'x\n' > "${MICROOS_ANDROID_CONTEXT}/external/x"
run
[[ "${rc}" == 1 ]] || fail "a filled stub exited ${rc}: $(cat "${STATE}/stderr")"
grep -q "is not empty, refusing" "${STATE}/stderr" || fail "a filled stub: no log: $(cat "${STATE}/stderr")"

case_name="storage, a card stub at another mode"
reset
echo none > "${MICROOS_SYSTEM_CARD}"
mkdir -p "${MICROOS_CONTENT}/MicroOS/Android/0123456789abcdef" "${MICROOS_ANDROID_CONTEXT}/external"
printf 'card=CARD1-0000\nstorage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
chmod 0770 "${MICROOS_ANDROID_CONTEXT}/external"
run
[[ "${rc}" == 1 ]] || fail "a 0770 stub exited ${rc}: $(cat "${STATE}/stderr")"
grep -q "not 0555, refusing" "${STATE}/stderr" || fail "a 0770 stub: no log: $(cat "${STATE}/stderr")"

case_name="storage, the private HOME holds Documents"
reset
mkdir -p "${MICROOS_ANDROID_DATA}/home/Documents"
run
rm -rf "${MICROOS_ANDROID_DATA}/home/Documents"
[[ "${rc}" == 1 ]] || fail "Documents in the private HOME exited ${rc}: $(cat "${STATE}/stderr")"
[[ "$(reason_of)" == folder-unusable ]] || fail "Documents in the private HOME wrote $(reason_of)"
grep -q "Documents is in the private HOME" "${STATE}/stderr" || fail "Documents: no log: $(cat "${STATE}/stderr")"

case_name="storage, the source from the card"
reset
echo none > "${MICROOS_SYSTEM_CARD}"
mkdir -p "${MICROOS_CONTENT}/MicroOS/Android/0123456789abcdef" "${MICROOS_ANDROID_CONTEXT}/external"
printf 'card=CARD1-0000\nstorage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
chmod 0555 "${MICROOS_ANDROID_CONTEXT}/external"
run
grep -qx "MICROOS_ANDROID_EXTERNAL=${T}/content/MicroOS/Android/0123456789abcdef" "${STATE}/env" \
    || fail "the card folder is not the override: $(grep MICROOS_ANDROID_EXTERNAL "${STATE}/env" 2>/dev/null)"

case_name="storage, every word but card and on-os-card"
for word in on-internal no-card not-ext4 read-only other-card folder-missing folder-unusable; do
    reset
    rm -rf "${MICROOS_ANDROID_CONTEXT}"
    echo none > "${MICROOS_SYSTEM_CARD}"
    mkdir -p "${MICROOS_CONTENT}" "${MICROOS_ANDROID_CONTEXT}/external"
    printf 'card=CARD1-0000\nstorage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
    case "${word}" in
        on-internal) printf 'storage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage" ;;
        no-card) rm -rf "${MICROOS_CONTENT:?}" ;;
        not-ext4) printf 'vfat CARD1-0000 rw\n' > "${STATE}/mount-row" ;;
        read-only) printf 'ext4 CARD1-0000 ro\n' > "${STATE}/mount-row" ;;
        other-card) printf 'ext4 CARD2-0000 rw\n' > "${STATE}/mount-row" ;;
        folder-missing) mkdir -p "${MICROOS_CONTENT}/MicroOS/Android" ;;
        folder-unusable)
            mkdir -p "${MICROOS_CONTENT}/MicroOS/Android"
            ln -s "${T}/elsewhere" "${MICROOS_CONTENT}/MicroOS/Android/0123456789abcdef"
            ;;
    esac
    run
    rm -f "${STATE}/mount-row"
    [[ "${rc}" == 1 ]] || fail "${word} exited ${rc}: $(cat "${STATE}/stderr")"
    [[ "$(cat "${MICROOS_RUNTIME_DIR}/end-reason" 2>/dev/null)" == "${word}" ]] \
        || fail "${word} wrote $(cat "${MICROOS_RUNTIME_DIR}/end-reason" 2>/dev/null): $(cat "${STATE}/stderr")"
    grep -q "shared storage reads ${word}" "${STATE}/stderr" || fail "${word}: no log: $(cat "${STATE}/stderr")"
    [[ ! -s "${STATE}/events" ]] || fail "${word}: lepton started: $(cat "${STATE}/events")"
    rm -rf "${MICROOS_CONTENT:?}"
done

case_name="storage, an empty stub at emptying"
reset
echo none > "${MICROOS_SYSTEM_CARD}"
mkdir -p "${MICROOS_CONTENT}/MicroOS/Android/0123456789abcdef" "${MICROOS_ANDROID_CONTEXT}/external"
printf 'card=CARD1-0000\nstorage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
rmdir "${MICROOS_ANDROID_CONTEXT}/external"
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external"
chmod 0770 "${MICROOS_ANDROID_CONTEXT}/external"
mkdir -p "${XDG_STATE_HOME}/microos-android"
printf 'verb=move-card\nid=0123456789abcdef\ncard=CARD1-0000\nkeep-card=0\nstep=emptying\nmanifest=%s\n' \
    "${XDG_STATE_HOME}/microos-android/storage-move.manifest" > "${XDG_STATE_HOME}/microos-android/storage-move"
run
[[ "${rc}" == 0 ]] || fail "an empty stub at emptying exited ${rc}: $(cat "${STATE}/stderr")"
grep -q "not 0555" "${STATE}/stderr" && fail "an empty stub at emptying was refused: $(cat "${STATE}/stderr")"
rm -f "${XDG_STATE_HOME}/microos-android/storage-move"

case_name="storage, the write probe reads the C locale"
reset
echo none > "${MICROOS_SYSTEM_CARD}"
mkdir -p "${MICROOS_CONTENT}/MicroOS/Android/0123456789abcdef" "${MICROOS_ANDROID_CONTEXT}/external"
printf 'card=CARD1-0000\nstorage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
chmod 0555 "${MICROOS_ANDROID_CONTEXT}/external"
cat > "${T}/bin/mktemp" <<'STUB'
#!/usr/bin/bash
[[ "${1:-}" == -p ]] || exec /usr/bin/mktemp "$@"
if [[ "${LC_ALL:-}" == C ]]; then
    echo "mktemp: failed to create file via template: Read-only file system" >&2
else
    echo "mktemp: Vorlage konnte nicht angelegt werden: Dateisystem ist schreibgeschützt" >&2
fi
exit 1
STUB
chmod 0755 "${T}/bin/mktemp"
run
rm -f "${T}/bin/mktemp"
[[ "${rc}" == 1 ]] || fail "a read only probe exited ${rc}: $(cat "${STATE}/stderr")"
[[ "$(reason_of)" == read-only ]] || fail "a read only probe wrote $(reason_of)"
grep -q "is read only, refusing" "${STATE}/stderr" || fail "a read only probe: no log: $(cat "${STATE}/stderr")"

case_name="storage, the run holds the lock"
reset
holder="${STATE}/held"
bash -c 'exec 9>>"$1"; flock -x 9 && : > "$2"; while :; do sleep 0.05; done' \
    _ "${XDG_STATE_HOME}/microos-android/storage.lock" "${holder}" &
locker=$!
for _ in $(seq 1 100); do [[ -e "${holder}" ]] && break; sleep 0.02; done
run
kill "${locker}" 2>/dev/null
wait "${locker}" 2>/dev/null || :
lock_free || fail "the lock was not released"
[[ "${rc}" == 1 ]] || fail "a held lock exited ${rc}: $(cat "${STATE}/stderr")"
[[ "$(reason_of)" == moving ]] || fail "a held lock wrote $(reason_of)"

case_name="context creation on a card"
reset
echo none > "${MICROOS_SYSTEM_CARD}"
rm -rf "${MICROOS_ANDROID_CONTEXT}"
mkdir -p "${T}/content/MicroOS/Android" "${T}/content/MicroOS/Android/0123456789abcdef"
mkdir -p "${MICROOS_ANDROID_CONTEXT}.tmp"
printf 'card=CARD1-0000\nstorage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}.tmp/microos-android-storage"
run
new_id=$(sed -n 's/^storage=//p' "${MICROOS_ANDROID_CONTEXT}/microos-android-storage" 2>/dev/null || :)
[[ "${new_id}" =~ ^[0-9a-f]{16}$ ]] || fail "the creation: no id, exit ${rc}: $(cat "${STATE}/stderr")"
grep -qx 'card=CARD1-0000' "${MICROOS_ANDROID_CONTEXT}/microos-android-storage" || fail "the creation: no card line"
[[ "$(stat -c %a "${MICROOS_ANDROID_CONTEXT}/external")" == 555 ]] || fail "the creation: the stub is $(stat -c %a "${MICROOS_ANDROID_CONTEXT}/external" 2>/dev/null)"
[[ "$(stat -c %a "${T}/content/MicroOS/Android/${new_id}")" == 770 ]] || fail "the creation: the card folder is $(stat -c %a "${T}/content/MicroOS/Android/${new_id}" 2>/dev/null)"
[[ ! -e "${MICROOS_ANDROID_CONTEXT}.tmp" ]] || fail "the creation: the temp dir is left"
[[ ! -e "${T}/content/MicroOS/Android/0123456789abcdef" ]] || fail "the creation: the stale card folder is left"

case_name="context creation on the system card"
reset
rm -rf "${MICROOS_ANDROID_CONTEXT}"
run
grep -q '^storage=[0-9a-f]\{16\}$' "${MICROOS_ANDROID_CONTEXT}/microos-android-storage" || fail "the SD tie: $(cat "${MICROOS_ANDROID_CONTEXT}/microos-android-storage" 2>/dev/null)"
grep -q '^card=' "${MICROOS_ANDROID_CONTEXT}/microos-android-storage" && fail "the SD tie holds a card line"
[[ "$(stat -c %a "${MICROOS_ANDROID_CONTEXT}/external")" == 770 ]] || fail "the SD external is $(stat -c %a "${MICROOS_ANDROID_CONTEXT}/external" 2>/dev/null)"

case_name="context creation, a stale id that is not hex"
reset
echo none > "${MICROOS_SYSTEM_CARD}"
rm -rf "${MICROOS_ANDROID_CONTEXT}"
mkdir -p "${MICROOS_CONTENT}/victim" "${MICROOS_ANDROID_CONTEXT}.tmp"
printf 'card=CARD1-0000\nstorage=../../victim\n' > "${MICROOS_ANDROID_CONTEXT}.tmp/microos-android-storage"
run
[[ "${rc}" == 0 ]] || fail "the creation: exit ${rc}: $(cat "${STATE}/stderr")"
[[ -d "${MICROOS_CONTENT}/victim" ]] || fail "the stale id removed ${MICROOS_CONTENT}/victim"

case_name="storage, the lock is closed for every child"
reset
echo none > "${MICROOS_SYSTEM_CARD}"
mkdir -p "${MICROOS_CONTENT}/MicroOS/Android/0123456789abcdef" "${MICROOS_ANDROID_CONTEXT}/external"
printf 'card=CARD1-0000\nstorage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
chmod 0555 "${MICROOS_ANDROID_CONTEXT}/external"
probe_go="${STATE}/probe-go.$$"
export probe_go
rm -f "${probe_go}" "${probe_go}.2" "${STATE}/child-lock-"*
cat > "${T}/bin/spawn-probe" <<STUB
#!/usr/bin/bash
name=\$1
rm -f "\${STATE}/child-lock-\${name}"
setsid bash -c '
    name=\$1 go=\$2 next=\$3 lock=\$4 out=\$5
    gate=\${go}
    [[ "\${name}" == podman ]] && gate="\${next}"
    for _ in \$(seq 1 400); do [[ -e "\${gate}" ]] && break; sleep 0.05; done
    [[ -e "\${gate}" ]] || exit 0
    if flock -n -x "\${lock}" -c true 2>/dev/null; then
        echo free > "\${out}"
    else
        echo held > "\${out}"
    fi
    : > "\${next}"' _ "\${name}" "\${probe_go}" "\${probe_go}.2" "\${XDG_STATE_HOME}/microos-android/storage.lock" \
    "\${STATE}/child-lock-\${name}" > /dev/null 2>&1 &
STUB
chmod 0755 "${T}/bin/spawn-probe"
cat > "${T}/bin/lepton-probe" <<STUB
#!/usr/bin/bash
if [[ "\${1:-}" == runtime ]]; then
    printf '%s\n' "${T}/lepton"
    exit 0
fi
echo "lepton \$*" >> "\${STATE}/events"
"${T}/bin/spawn-probe" lepton
echo "Boot complete!"
sleep 0.2
exit 0
STUB
mv "${T}/bin/podman" "${T}/bin/podman-real"
cat > "${T}/bin/podman" <<STUB
#!/usr/bin/bash
if [[ ! -e "\${STATE}/probe-podman" ]]; then
    : > "\${STATE}/probe-podman"
    "${T}/bin/spawn-probe" podman
fi
exec "${T}/bin/podman-real" "\$@"
STUB
chmod 0755 "${T}/bin/lepton-probe" "${T}/bin/podman"
MICROOS_LEPTON="${T}/bin/lepton-probe" run
mv -f "${T}/bin/podman-real" "${T}/bin/podman"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
: > "${probe_go}"
for _ in $(seq 1 100); do
    [[ -e "${STATE}/child-lock-lepton" && -e "${STATE}/child-lock-podman" ]] && break
    sleep 0.05
done
[[ "$(cat "${STATE}/child-lock-lepton" 2>/dev/null)" == free ]] \
    || fail "lepton start kept the lock fd: $(cat "${STATE}/child-lock-lepton" 2>/dev/null)"
[[ "$(cat "${STATE}/child-lock-podman" 2>/dev/null)" == free ]] \
    || fail "a podman child kept the lock fd: $(cat "${STATE}/child-lock-podman" 2>/dev/null)"
lock_free || fail "the lock was not released"

if (( failures )); then
    echo "run-test: ${failures} failure(s), ${skipped} skipped" >&2
    exit 1
fi
echo "run-test: ok, ${skipped} skipped"
