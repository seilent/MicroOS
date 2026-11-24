#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
data="${repo}/data"
desktop="${data}/usr/share/wayland-sessions/microos-android.desktop"
client="${data}/usr/share/gamescope-session-plus/sessions.d/android"
root=$(cd "${repo}/../.." && pwd)
pm2="${root}/devices/pm2/system_files"
[[ -d "${pm2}" ]] || pm2="${root}/system_files"
pm2_units="${pm2}/usr/lib/systemd/user"
conf="${pm2}/usr/lib/microos/sessions.d/android.conf"
pad="${pm2_units}/gamescope-session-plus@android.service.d/20-microos-android-pad.conf"
plain="${data}/usr/libexec/microos/microos-gamescope-plain"
units="${data}/usr/lib/systemd/user"
system="${data}/usr/lib/systemd/system"
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
cat > "${T}/gamescope" <<'STUB'
#!/usr/bin/bash
printf '%s\n' "$*"
STUB
chmod 0755 "${T}/gamescope"
printf 'width=2560\nheight=1600\ndensity=400\nhz=165\n' > "${T}/display-hz"
printf 'width=960\nheight=640\ndensity=213\n' > "${T}/display"
got=$(MICROOS_GAMESCOPE="${T}/gamescope" MICROOS_DISPLAY_FILE="${T}/display-hz" bash "${plain}" --prefer-output '*,DSI-1' --steam -R x)
[[ "${got}" == "-r 165 --prefer-output *,DSI-1 -R x" ]] || fail "the plain wrapper with hz=165 ran gamescope ${got}"
got=$(MICROOS_GAMESCOPE="${T}/gamescope" MICROOS_DISPLAY_FILE="${T}/display" bash "${plain}" --prefer-output '*,DSI-1' --steam -R x)
[[ "${got}" == "--prefer-output *,DSI-1 -R x" ]] || fail "the plain wrapper with no hz ran gamescope ${got}"
for value in 0 fast; do
    printf 'density=400\nhz=%s\n' "${value}" > "${T}/display-bad"
    rc=0
    got=$(MICROOS_GAMESCOPE="${T}/gamescope" MICROOS_DISPLAY_FILE="${T}/display-bad" bash "${plain}" -R x 2>&1) || rc=$?
    [[ "${rc}" == 1 && "${got}" == "microos-gamescope-plain: hz=${value} in ${T}/display-bad is not a rate" ]] \
        || fail "the plain wrapper with hz=${value}: exit ${rc}: ${got}"
done
rc=0
got=$(MICROOS_GAMESCOPE="${T}/gamescope" MICROOS_DISPLAY_FILE="${T}/absent-display" bash "${plain}" -R x 2>&1) || rc=$?
[[ "${rc}" == 1 && "${got}" == "microos-gamescope-plain: ${T}/absent-display missing" ]] \
    || fail "the plain wrapper with no display file: exit ${rc}: ${got}"

[[ ! -e "${units}/gamescope-session-plus@android.service.d/20-microos-android-pad.conf" \
    && ! -e "${units}/microos-android-pad.service" ]] || fail "the package ships the PM2 pad target units"

for u in microos-android.service microos-android-status.service microos-android-battery.service \
    microos-android-brightness.service microos-android-gapps.service microos-android-lsfg.service \
    microos-android-perf.service "${pm2_units}/microos-android-pad.service" "${system}/microos-android-gsf.service" \
    "${system}/microos-android-reset.service" "${system}/microos-android-layer.service" \
    "${system}/microos-android-gapps@.service"; do
    [[ "${u}" == /* ]] || u="${units}/${u}"
    [[ -f "${u}" ]] || { fail "${u##*/} missing"; continue; }
    grep -qx '\[Unit\]' "${u}" || fail "${u##*/} has no [Unit]"
    grep -qx '\[Service\]' "${u}" || fail "${u##*/} has no [Service]"
    if grep -q '^#' "${u}"; then fail "${u##*/} carries a comment"; fi
done
for u in microos-lepton-prepare.service microos-android-gapps-setup.service; do
    [[ ! -e "${units}/${u}" ]] || fail "${u} is still shipped"
done
grep -q 'microos-waydroid' "${libexec}/microos-android-client" || fail "the client does not keep Waydroid's data apart"
grep -qx 'BindsTo=gamescope-session-plus@android.service' "${pm2_units}/microos-android-pad.service" \
    || fail "pad BindsTo"
battery="${units}/microos-android-battery.service"
grep -qx 'BindsTo=microos-android.service' "${battery}" || fail "battery BindsTo"
grep -qx 'After=microos-android.service' "${battery}" || fail "battery After"
grep -qx 'ExecStart=/usr/libexec/microos/microos-android-battery' "${battery}" || fail "battery ExecStart"
grep -q '^WantedBy=' "${battery}" && fail "the battery mirror is enabled"
brightness="${units}/microos-android-brightness.service"
grep -qx 'PartOf=microos-android.service' "${brightness}" || fail "brightness PartOf"
grep -qx 'After=microos-android.service' "${brightness}" || fail "brightness After"
grep -q '^BindsTo=' "${brightness}" && fail "the brightness bridge is bound"
grep -qx 'TimeoutStopSec=5' "${brightness}" || fail "brightness TimeoutStopSec"
grep -qx 'ExecStart=/usr/libexec/microos/microos-android-brightness' "${brightness}" || fail "brightness ExecStart"
grep -q '^WantedBy=' "${brightness}" && fail "the brightness bridge is enabled"
gapps="${units}/microos-android-gapps.service"
grep -qx 'Type=oneshot' "${gapps}" || fail "gapps Type"
grep -qx 'ExecStart=/usr/bin/microos-android gapps install' "${gapps}" || fail "gapps ExecStart"
grep -qx TimeoutStartSec=30min "${gapps}" || fail "gapps TimeoutStartSec"
for line in TimeoutStartSec=30min Nice=19 IOSchedulingClass=idle 'ExecStart=/usr/libexec/microos/microos-android-root gapps-%i'; do
    grep -qxF "${line}" "${system}/microos-android-gapps@.service" || fail "the root gapps unit lacks ${line}"
done
marker="${T}/xdg/microos-android/gapps-install"
unit_run() {
    local line
    line=$(sed -n "s/^$1=//p" "${gapps}" | sed -e 's/\$\$/$/g' -e "s|%t|${T}/xdg|g")
    [[ -n "${line}" ]] || { fail "gapps has no $1"; return; }
    SERVICE_RESULT=$2 bash -c "${line}" || fail "gapps $1 with ${2:-no result} exited $?"
}
unit_run ExecStartPre ""
[[ "$(cat "${marker}" 2>/dev/null)" == running && ! -e "${marker}.new" ]] || fail "gapps ExecStartPre: $(cat "${marker}" 2>&1)"
unit_run ExecStopPost success
[[ ! -e "${marker}" ]] || fail "gapps ExecStopPost on success left $(cat "${marker}")"
for result in exit-code signal timeout; do
    unit_run ExecStartPre ""
    unit_run ExecStopPost "${result}"
    [[ "$(cat "${marker}" 2>/dev/null)" == failed ]] || fail "gapps ExecStopPost on ${result}: $(cat "${marker}" 2>&1)"
done
unit_run ExecStartPre ""
unit_run ExecStopPost success
[[ ! -e "${marker}" ]] || fail "a successful run after a failed one left $(cat "${marker}")"
grep -qE '^(Requisite|BindsTo|Requires|WantedBy)=' "${gapps}" && fail "the gapps unit is tied to a session or enabled"
grep -qx 'ExecStart=/usr/libexec/microos/microos-pad-target xb360 keyboard' "${pm2_units}/microos-android-pad.service" \
    || fail "pad ExecStart"
[[ -f "${pm2}/usr/libexec/microos/microos-pad-target" ]] || fail "the pad watcher is not in the image"

if grep -q '^WantedBy=' "${units}/microos-android-status.service"; then
    grep -qx 'WantedBy=default.target' "${units}/microos-android-status.service" || fail "status WantedBy"
else
    fail "the status service is not enabled"
fi

preset="${pm2}/usr/lib/systemd/user-preset/50-microos.preset"
[[ -f "${preset}" ]] || fail "the user preset ${preset} is missing"
grep -qx 'enable microos-android-status.service' "${preset}" || fail "the user preset does not enable the status service"
grep -qx 'enable game.slice' "${preset}" || fail "the user preset lost game.slice"

[[ ! -e "${libexec}/microos-android-session-watch" ]] || fail "the Lepton session watch is still shipped"

[[ "${failures}" == 0 ]] || exit 1
echo "session-test: ok"
