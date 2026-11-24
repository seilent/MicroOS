#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
guest="${repo}/data/usr/libexec/microos/microos-android-guest"

T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

export STATE="${T}/state"
export HOME="${T}/home"
export MICROOS_WAYDROID_DATA="${T}/wd"
export MICROOS_WAYDROID_LEASES="${T}/leases"
export MICROOS_OPTS="${T}/opts"
export MICROOS_GUEST_STOP_S=3
mkdir -p "${T}/bin" "${STATE}/dumps" "${HOME}"
cat > "${T}/bin/adb" <<'FAKE'
#!/usr/bin/bash
echo "$*" >> "${STATE}/adb"
case "$1" in
    devices)
        echo "List of devices attached"
        cat "${STATE}/devices" 2>/dev/null
        exit 0
        ;;
    connect)
        [[ ! -e "${STATE}/refuse" ]] || { echo "failed to connect to $2"; exit 1; }
        printf '%s\tdevice\n' "$2" > "${STATE}/devices"
        echo "connected to $2"
        exit 0
        ;;
    disconnect) rm -f "${STATE}/devices"; exit 0 ;;
    keygen) echo private > "$2"; echo "QAAAAkey micro@host" > "$2.pub"; exit 0 ;;
esac
[[ "$1" == -s ]] || exit 99
shift 2
case "$1" in
    wait-for-device) exit 0 ;;
    shell) ;;
    *) exit 98 ;;
esac
printf '%s\n' "$2" >> "${STATE}/shell"
case "$2" in
    'getprop sys.boot_completed') cat "${STATE}/boot" 2>/dev/null ;;
    'dumpsys activity activities')
        n=$(cat "${STATE}/dump-n" 2>/dev/null || echo 0)
        f="${STATE}/dumps/${n}"
        [[ -e "${f}" ]] || f=$(ls "${STATE}/dumps"/* | sort -V | tail -n 1)
        cat "${f}"
        echo $((n + 1)) > "${STATE}/dump-n"
        ;;
    'am start'*) ;;
    'exit '*) exit "${2#exit }" ;;
    *) PATH="${STATE}/guestbin:${PATH}" bash -c "$2" ;;
esac
FAKE
mkdir -p "${STATE}/guestbin"
for c in cmd settings content; do
    cat > "${STATE}/guestbin/${c}" <<FAKE
#!/usr/bin/bash
echo "${c} \$*" >> "\${STATE}/guest-cmds"
[[ "${c} \$*" != *"\$(cat "\${STATE}/fail-word" 2>/dev/null || echo NONE)"* ]]
FAKE
done
chmod 0755 "${T}/bin/adb" "${STATE}/guestbin/"*
export PATH="${T}/bin:${PATH}"

dump() {
    local n=$1 top=$2 st=$3
    cat > "${STATE}/dumps/${n}" <<EOF
ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)
  * Task{c6231df #32 type=standard A=1000:com.android.settings.root U=0 visible=true}
    topResumedActivity=ActivityRecord{ba5b9ea u0 ${top} t32}
    * Hist  #0: ActivityRecord{ba5b9ea u0 ${top} t32}
      packageName=${top%%/*} processName=${top%%/*}
      state=${st} stopped=false delayedResume=false finishing=false
  ResumedActivity: ActivityRecord{ba5b9ea u0 ${top} t32}
EOF
}

reset() {
    rm -rf "${STATE}/dumps" "${STATE}/adb" "${STATE}/shell" "${STATE}/devices" "${STATE}/dump-n" "${STATE}/guest-cmds" \
        "${STATE}/refuse" "${STATE}/fail-word"
    mkdir -p "${STATE}/dumps"
}

"${guest}" boot 2> "${T}/err" && fail "boot passed with no lease file"
[[ ! -s "${T}/err" ]] || fail "the boot poll logged: $(cat "${T}/err")"
rc=0
"${guest}" sh true 2> "${T}/err" || rc=$?
[[ "${rc}" == 255 ]] || fail "sh with no lease file exited ${rc}"
grep -q "no guest address" "${T}/err" || fail "no lease message: $(cat "${T}/err")"

echo '1795504613 00:16:3e:f9:d3:03 192.168.240.112 waydroid 01:00:16:3e:f9:d3:03' > "${MICROOS_WAYDROID_LEASES}"
rc=0
"${guest}" sh true 2> "${T}/err" || rc=$?
[[ "${rc}" == 255 ]] || fail "sh with no guest adb dir exited ${rc}"
grep -q "cannot add the adb key" "${T}/err" || fail "no key message: $(cat "${T}/err")"

mkdir -p "${MICROOS_WAYDROID_DATA}/waydroid/data/misc/adb"
echo 1 > "${STATE}/boot"
"${guest}" boot || fail "boot did not pass with sys.boot_completed 1"
"${guest}" boot || fail "the second boot read did not pass"
keys="${MICROOS_WAYDROID_DATA}/waydroid/data/misc/adb/adb_keys"
[[ "$(cat "${keys}")" == "QAAAAkey micro@host" ]] || fail "adb_keys: $(cat "${keys}")"
[[ "$(grep -c '^connect 192.168.240.112:5555$' "${STATE}/adb")" == 1 ]] || fail "connects: $(cat "${STATE}/adb")"
grep -q '^keygen ' "${STATE}/adb" || fail "no keygen"
echo 0 > "${STATE}/boot"
"${guest}" boot && fail "boot passed with sys.boot_completed 0"

reset
rc=0
"${guest}" sh 'exit 7' || rc=$?
[[ "${rc}" == 7 ]] || fail "sh did not pass the guest exit code through: ${rc}"
printf '%s\t%s\n' 192.168.240.112:5555 offline > "${STATE}/devices"
"${guest}" sh true || fail "sh did not reconnect an offline device"
grep -q '^disconnect 192.168.240.112:5555$' "${STATE}/adb" || fail "no disconnect of the offline device"
reset
touch "${STATE}/refuse"
rc=0
"${guest}" sh true 2> "${T}/err" || rc=$?
if [[ "${rc}" != 255 ]] || ! grep -q "cannot connect" "${T}/err"; then fail "a refused connect: ${rc} $(cat "${T}/err")"; fi

reset
dump 0 'com.android.settings/.Settings$NetworkDashboardActivity' RESUMED
dump 1 'com.android.settings/.Settings$NetworkDashboardActivity' PAUSED
dump 2 'com.android.settings/.Settings$NetworkDashboardActivity' STOPPED
"${guest}" stop 2> "${T}/err" || fail "stop exited non zero"
grep -qx 'am start -W -a android.intent.action.MAIN -c android.intent.category.HOME' "${STATE}/shell" || fail "no HOME intent"
[[ "$(cat "${STATE}/dump-n")" == 3 ]] || fail "stop read $(cat "${STATE}/dump-n") dumps, not 3"
[[ ! -s "${T}/err" ]] || fail "stop logged: $(cat "${T}/err")"

reset
dump 0 'com.android.launcher3/.uioverlay.UiOverlayActivity' RESUMED
"${guest}" stop || fail "stop at home exited non zero"
[[ "$(cat "${STATE}/dump-n")" == 1 ]] || fail "stop at home waited"

reset
dump 0 'com.example.game/.Main' RESUMED
printf 'ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)\n' > "${STATE}/dumps/1"
"${guest}" stop 2> "${T}/err" || fail "stop with the record gone exited non zero"
[[ "$(cat "${STATE}/dump-n")" == 2 ]] || fail "a gone record was not taken as stopped"

reset
dump 0 'com.example.game/.Main' RESUMED
start=${SECONDS}
"${guest}" stop 2> "${T}/err" || fail "stop past the deadline exited non zero"
(( SECONDS - start >= 2 )) || fail "stop did not wait for the deadline"
grep -qF 'com.example.game/.Main is RESUMED after 3 s' "${T}/err" || fail "no deadline log: $(cat "${T}/err")"

reset
cat > "${MICROOS_OPTS}" <<'EOF'
set gestural cmd overlay enable-exclusive --category com.android.internal.systemui.navbar.gestural
set user-setup settings put secure user_setup_complete 1
set hint content insert --uri content://lineagesettings/system --bind name:s:navigation_bar_hint --bind value:s:0
pkg stk com.android.stk
EOF
echo user_setup_complete > "${STATE}/fail-word"
"${guest}" opts 2> "${T}/err" || fail "opts exited non zero"
stamp="${MICROOS_WAYDROID_DATA}/waydroid/data/.microos-opts"
[[ "$(sort "${stamp}" | tr '\n' ' ')" == "gestural hint stk " ]] || fail "stamp after a failure: $(tr '\n' ' ' < "${stamp}")"
grep -qF 'guest setting user-setup failed' "${T}/err" || fail "no failure log: $(cat "${T}/err")"
grep -qF 'content insert --uri content://lineagesettings/system --bind name:s:navigation_bar_hint --bind value:s:0' \
    "${STATE}/guest-cmds" || fail "the hint insert did not run as written"
grep -qF 'cmd package list packages com.android.stk' "${STATE}/guest-cmds" || fail "no package probe"
rm -f "${STATE}/fail-word" "${STATE}/guest-cmds"
"${guest}" opts 2> "${T}/err" || fail "the second opts exited non zero"
[[ "$(sort "${stamp}" | tr '\n' ' ')" == "gestural hint stk user-setup " ]] || fail "stamp: $(tr '\n' ' ' < "${stamp}")"
grep -q 'overlay enable-exclusive' "${STATE}/guest-cmds" && fail "an applied setting ran again"
rm -f "${STATE}/guest-cmds"
"${guest}" opts || fail "the third opts exited non zero"
[[ ! -e "${STATE}/guest-cmds" ]] || fail "opts ran guest commands with every id applied"

rc=0
"${guest}" nothing 2> /dev/null || rc=$?
[[ "${rc}" == 2 ]] || fail "an unknown verb exited ${rc}"

shipped="${repo}/data/usr/share/microos-android/opts"
tiles=$(sed -n 's/^set qs-tiles settings put secure sysui_qs_tiles //p' "${shipped}")
helper=net.seilent.microos.helper
[[ ",${tiles}," == *",custom(${helper}/.InternetTile),"* && ",${tiles}," == *",custom(${helper}/.BluetoothTile),"* ]] \
    || fail "the shipped tiles lack the helper's Internet and Bluetooth tiles: ${tiles}"
[[ ",${tiles}," != *",wifi,"* && ",${tiles}," != *",bt,"* && ${tiles} != *" "* ]] \
    || fail "the shipped tiles keep a stock radio tile or a space: ${tiles}"

(( failures == 0 )) || { echo "${failures} failure(s)" >&2; exit 1; }
echo "guest-test: pass"
