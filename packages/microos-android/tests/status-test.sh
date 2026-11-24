#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
status="${repo}/data/usr/libexec/microos/microos-android-status"

T=$(mktemp -d)
pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "${p}" 2>/dev/null || true; done
    rm -rf "${T:?}"
}
trap cleanup EXIT

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

for t in dbus-daemon python3 gdbus; do
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
export XDG_RUNTIME_DIR="${T}/xdg"
export MICROOS_RUNTIME_DIR="${T}/xdg/microos-android"
export MICROOS_ANDROID_STATE="${T}/state"
export MICROOS_ANDROID_IMAGES="${T}/images"
export MICROOS_ANDROID_IMAGES_STATE="${T}/var/images.state"
export MICROOS_ANDROID_VAR="${T}/var"
export MICROOS_SYSTEM_CARD="${T}/run/system-card"
export MICROOS_ANDROID_GUEST="${T}/bin/guest"
export MICROOS_STATUS_POLL_MS=100
export STUB="${T}/stub"
mkdir -p "${HOME}" "${MICROOS_RUNTIME_DIR}" "${MICROOS_ANDROID_STATE}" "${MICROOS_ANDROID_IMAGES}" "${T}/run" \
    "${MICROOS_ANDROID_VAR}" "${T}/bin" "${STUB}"
cat > "${T}/bin/guest" <<'FAKE'
#!/usr/bin/bash
echo "$*" >> "${STUB}/guest"
[[ "$1 $2" == "sh dumpsys activity activities" ]] || exit 99
[[ ! -e "${STUB}/slow" ]] || sleep 5
cat "${STUB}/dump" 2>/dev/null
exit "$(cat "${STUB}/rc" 2>/dev/null || echo 0)"
FAKE
chmod 0755 "${T}/bin/guest"

python3 "${status}" 2> "${T}/status.err" &
pids+=($!)
for _ in {1..100}; do
    gdbus call --session --dest org.freedesktop.DBus --object-path / --method org.freedesktop.DBus.ListNames 2>/dev/null \
        | grep -q net.seilent.MicroOs.Android1 && break
    sleep 0.05
done

prop() {
    local raw
    raw=$(gdbus call --session --dest net.seilent.MicroOs.Android1 --object-path /net/seilent/MicroOs/Android \
        --method org.freedesktop.DBus.Properties.Get net.seilent.MicroOs.Android1 "$1") || return 1
    raw=${raw#(<\'}
    raw=${raw%\'>,)}
    printf '%s' "${raw}"
}

expect() {
    local i got
    for (( i = 0; i < 40; i++ )); do
        got=$(prop "$1") || got="(error)"
        [[ "${got}" == "$2" ]] && return 0
        sleep 0.1
    done
    fail "$3: $1 is '${got}', not '$2'"
}

set_state() {
    printf '%s\n' "$1" > "${MICROOS_ANDROID_STATE}/state.json.new"
    mv "${MICROOS_ANDROID_STATE}/state.json.new" "${MICROOS_ANDROID_STATE}/state.json"
}

expect Lepton not-installed "no images"
expect LeptonBuild "" "no images"
printf 'state=fetching\nset=los20av-20260927-20261022\n' > "${MICROOS_ANDROID_IMAGES_STATE}"
expect Lepton downloading "an images fetch"
printf 'state=failed\nset=los20av-20260927-20261022\n' > "${MICROOS_ANDROID_IMAGES_STATE}"
expect Lepton failed "a failed images fetch"
mkdir -p "${MICROOS_ANDROID_IMAGES}/los20av-20260927-20261022"
ln -s los20av-20260927-20261022 "${MICROOS_ANDROID_IMAGES}/current"
expect Lepton ready "a set with a failed newer fetch"
expect LeptonBuild los20av-20260927-20261022 "the set id"
printf 'state=fetching\nset=los20av-20260927-20261022\n' > "${MICROOS_ANDROID_IMAGES_STATE}"
expect Lepton downloading "a new set fetching"
expect LeptonBuild los20av-20260927-20261022 "the set id while fetching"
printf 'state=ready\nset=los20av-20260927-20261022\n' > "${MICROOS_ANDROID_IMAGES_STATE}"
expect Lepton ready "a set"

expect GooglePlay off "no Play"
echo running > "${MICROOS_RUNTIME_DIR}/gapps-install"
expect GooglePlay updating "an install running"
echo failed > "${MICROOS_RUNTIME_DIR}/gapps-install"
expect GooglePlay failed "a failed install"
rm -f "${MICROOS_RUNTIME_DIR}/gapps-install"
echo "aa system/product/priv-app/Phonesky/Phonesky.apk" > "${MICROOS_ANDROID_VAR}/gapps.manifest"
expect GooglePlay updating "installed, not booted"
set_state '{"gapps": {"play": "on", "gms": "on"}, "last": {"result": "ready", "reason": ""}}'
expect GooglePlay on "installed and booted"
expect LastResult ready "the last result"
rm -f "${MICROOS_ANDROID_VAR}/gapps.manifest"
expect GooglePlay updating "removed, not booted"
set_state '{"gapps": {"play": "off"}, "last": {"result": "refused", "reason": "no-space"}}'
expect GooglePlay off "removed and booted"
expect LastReason no-space "the last reason"

expect GsfId "" "no GSF ID"
echo 1234567890123456789 > "${MICROOS_ANDROID_VAR}/gsf-id"
expect GsfId 1234567890123456789 "the GSF ID"
echo 0x12 > "${MICROOS_ANDROID_VAR}/gsf-id"
expect GsfId "" "a GSF ID that is not digits"

expect Storage "" "no system card flag"
echo none > "${MICROOS_SYSTEM_CARD}"
expect Storage on-internal "the system on the internal disk"
echo mmcblk0 > "${MICROOS_SYSTEM_CARD}"
expect Storage on-os-card "the system on the card"
expect StorageCard "" "no card storage"

foreground() {
    gdbus call --session --dest net.seilent.MicroOs.Android1 --object-path /net/seilent/MicroOs/Android \
        --method net.seilent.MicroOs.Android1.Foreground
}
cat > "${STUB}/dump" <<'EOF'
    topResumedActivity=ActivityRecord{ba5b9ea u0 com.example.game/.Main t32}
  ResumedActivity: ActivityRecord{ba5b9ea u0 com.example.game/.Main t32}
EOF
[[ "$(foreground)" == "('com.example.game',)" ]] || fail "Foreground: $(foreground)"
grep -qx 'sh dumpsys activity activities' "${STUB}/guest" || fail "Foreground did not read through the exec path"
sed -i 's|com.example.game/.Main|com.android.launcher3/.uioverlay.UiOverlayActivity|' "${STUB}/dump"
[[ "$(foreground)" == "('',)" ]] || fail "Foreground at home: $(foreground)"
echo 1 > "${STUB}/rc"
[[ "$(foreground)" == "('',)" ]] || fail "Foreground with a failed exec: $(foreground)"
rm -f "${STUB}/rc"
touch "${STUB}/slow"
start=${SECONDS}
[[ "$(foreground)" == "('',)" ]] || fail "Foreground past its timeout"
(( SECONDS - start < 5 )) || fail "Foreground waited for a slow exec"

[[ "$(grep -c -e podman -e lepton -e REVIEWED "${status}")" == 0 ]] || fail "the status service reads Lepton"

(( failures == 0 )) || { echo "${failures} failure(s)" >&2; exit 1; }
echo "status-test: pass"
