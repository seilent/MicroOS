#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
data="${repo}/data"
conf="${data}/usr/lib/microos/sessions.d/android.conf"
desktop="${data}/usr/share/wayland-sessions/microos-android.desktop"
client="${data}/usr/share/gamescope-session-plus/sessions.d/android"
pad="${data}/usr/lib/systemd/user/gamescope-session-plus@android.service.d/20-microos-android-pad.conf"
plain="${data}/usr/libexec/microos/microos-gamescope-plain"
units="${data}/usr/lib/systemd/user"
libexec="${data}/usr/libexec/microos"

T=$(mktemp -d)
mkdir -p "${T}/xdg/systemd"
trap 'rm -rf "${T}"' EXIT
failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

for f in "${conf}" "${desktop}" "${client}" "${pad}" "${plain}"; do
    [[ -f "${f}" ]] || { echo "FAIL: ${f} missing" >&2; exit 1; }
done

get() { sed -n "s/^$1=//p" "${conf}"; }
[[ "$(get LABEL)" == Android ]] || fail "LABEL: $(get LABEL)"
[[ "$(get DESKTOP)" == microos-android.desktop ]] || fail "DESKTOP: $(get DESKTOP)"
[[ "$(get UNIT)" == gamescope-session-plus@android.service ]] || fail "UNIT: $(get UNIT)"
[[ "$(get STOP)" == unit ]] || fail "STOP: $(get STOP)"
[[ "$(get DEFAULT)" == yes ]] || fail "DEFAULT: $(get DEFAULT)"
[[ "$(get CHECK)" == /usr/libexec/microos/microos-android-check ]] || fail "CHECK: $(get CHECK)"
[[ "$(get INSTALL)" == /usr/libexec/microos/microos-android-install ]] || fail "INSTALL: $(get INSTALL)"
for key in GAME_SCOPE INPUT_PROFILE; do
    grep -q "^${key}=" "${conf}" && fail "android.conf carries ${key}="
done

grep -qx 'Exec=gamescope-session-plus android' "${desktop}" || fail "desktop Exec"
grep -qx 'Type=Application' "${desktop}" || fail "desktop Type"
grep -qx 'DesktopNames=android' "${desktop}" || fail "desktop DesktopNames"
grep -qx 'NoDisplay=true' "${desktop}" || fail "desktop NoDisplay"
grep -q '^Icon=' "${desktop}" && fail "desktop carries an Icon="
grep -qx 'export GAMESCOPE_BIN=/usr/libexec/microos/microos-gamescope-plain' "${client}" || fail "client GAMESCOPE_BIN"
grep -qx 'export CLIENTCMD=/usr/libexec/microos/microos-android-client' "${client}" || fail "client CLIENTCMD"
grep -qx 'Wants=microos-android-pad.service' "${pad}" || fail "pad drop-in Wants"

bash "${plain}" --help > /dev/null 2>&1 || true
grep -q -- '--steam' "${plain}" || fail "the plain wrapper does not strip --steam"

unit="${units}/gamescope-session-plus@android.service.d/20-microos-android-pad.conf"
[[ -f "${unit}" ]] || fail "the pad drop-in is not under the session's unit dir"

for u in microos-android.service microos-lepton-prepare.service microos-android-gapps-setup.service \
    microos-android-status.service microos-android-pad.service; do
    [[ -f "${units}/${u}" ]] || { fail "${u} missing"; continue; }
    grep -qx '\[Unit\]' "${units}/${u}" || fail "${u} has no [Unit]"
    grep -qx '\[Service\]' "${units}/${u}" || fail "${u} has no [Service]"
    if grep -q '^#' "${units}/${u}"; then fail "${u} carries a comment"; fi
done

[[ -f "${units}/microos-android.service" ]] && {
    grep -qx 'Requisite=gamescope-session-plus@android.service' "${units}/microos-android.service" \
        || fail "Requisite= on the container unit"
    grep -qx 'Requires=microos-lepton-prepare.service' "${units}/microos-android.service" \
        || fail "Requires= on the container unit"
    grep -qx 'EnvironmentFile=-%t/microos-android/session.env' "${units}/microos-android.service" \
        || fail "EnvironmentFile= on the container unit"
}
grep -qx 'Requisite=gamescope-session-plus@android.service' "${units}/microos-lepton-prepare.service" \
    || fail "Requisite= on the prepare unit"
grep -qx 'TimeoutStartSec=30min' "${units}/microos-lepton-prepare.service" || fail "prepare TimeoutStartSec"
grep -qx 'StopPropagatedFrom=gamescope-session-plus@android.service' "${units}/microos-lepton-prepare.service" \
    || fail "prepare StopPropagatedFrom"
grep -qx 'BindsTo=gamescope-session-plus@android.service' "${units}/microos-android-pad.service" \
    || fail "pad BindsTo"
grep -qx 'ExecStart=/usr/libexec/microos/microos-pad-target xb360 keyboard' "${units}/microos-android-pad.service" \
    || fail "pad ExecStart"
[[ -f "${repo}/../../system_files/usr/libexec/microos/microos-pad-target" ]] || fail "the pad watcher is not in the image"

if grep -q '^WantedBy=' "${units}/microos-android-status.service"; then
    grep -qx 'WantedBy=default.target' "${units}/microos-android-status.service" || fail "status WantedBy"
else
    fail "the status service is not enabled"
fi

preset="${repo}/../../system_files/usr/lib/systemd/user-preset/50-microos.preset"
[[ -f "${preset}" ]] || fail "the user preset ${preset} is missing"
grep -qx 'enable microos-android-status.service' "${preset}" || fail "the user preset does not enable the status service"
grep -qx 'enable game.slice' "${preset}" || fail "the user preset lost game.slice"

watch="${libexec}/microos-android-session-watch"
[[ -f "${watch}" && -x "${watch}" ]] || fail "the session watch is not an executable"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "${watch}" || fail "the session watch does not parse"
grep -q 'microos-android-session-watch' "${libexec}/microos-android-run" || fail "the run does not start the session watch"
grep -q 'subscribe' "${watch}" || fail "the session watch does not subscribe"
grep -q 'is-system-running' "${watch}" || fail "the session watch does not skip a stopping system"
grep -q 'ActiveState' "${watch}" || fail "the session watch does not read ActiveState"


[[ "${failures}" == 0 ]] || exit 1
echo "session-test: ok"
