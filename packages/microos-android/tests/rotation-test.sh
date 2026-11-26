#!/usr/bin/bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/data/usr/libexec/microos"
writer="${libexec}/microos-android-rotation"
root=$(cd "${repo}/../.." && pwd)
microsetd="${root}/devices/pm2/tests/audio-policy/microsetd"
[[ -f "${microsetd}" ]] || microsetd="${root}/tests/audio-policy/microsetd"

T=$(mktemp -d)
pids=()
cleanup() {
    for p in "${pids[@]}"; do
        kill "${p}" 2>/dev/null || true
        wait "${p}" 2>/dev/null || true
    done
    rm -rf "${T}"
}
trap cleanup EXIT

failures=0
fail() { echo "FAIL ${case_name}: $*" >&2; failures=$((failures + 1)); }

for t in dbus-daemon python3 gdbus; do
    command -v "$t" > /dev/null || { echo "FAIL: $t missing" >&2; exit 1; }
done

cat > "${T}/system.conf" <<EOF
<busconfig>
  <type>system</type>
  <listen>unix:path=${T}/system</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="*"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
EOF
dbus-daemon --config-file="${T}/system.conf" --nofork &
pids+=($!)
for _ in {1..50}; do [[ -S "${T}/system" ]] && break; sleep 0.1; done
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=${T}/system"

export STATE="${T}/state" GUEST="${T}/guest"
export MICROOS_DISPLAY_FILE="${T}/display"
printf 'width=2560\nheight=1600\ndensity=400\nhz=120\nlight_sensor=1\norientation=%s\n' \
    landscape:0,landscape-flipped:2,portrait:3,portrait-flipped:1 > "${MICROOS_DISPLAY_FILE}"
mkdir -p "${STATE}" "${GUEST}" "${T}/bin"
echo default > "${STATE}/mode"

cat > "${T}/bin/guest" <<'STUB'
#!/usr/bin/bash
printf 'guest %s\n' "$1" >> "${STATE}/execs"
[[ "$1" == sh && $# == 2 ]] || exit 99
[[ ! -e "${STATE}/gone" ]] || { echo 'microos-android-guest: cannot connect to 192.168.240.112:5555' >&2; exit 255; }
printf '%s\n--\n' "$2" >> "${STATE}/scripts"
exec sh -c "${2//\/system\/bin\//${GUEST}/}"
STUB
cat > "${GUEST}/wm" <<'STUB'
#!/usr/bin/bash
echo "wm $*" >> "${STATE}/guest"
[[ "$1" == fixed-to-user-rotation && $# -le 2 ]] || exit 99
if [[ $# == 1 ]]; then
    cat "${STATE}/mode"
else
    printf '%s\n' "$2" > "${STATE}/mode"
fi
STUB
cat > "${GUEST}/cmd" <<'STUB'
#!/usr/bin/bash
echo "cmd $*" >> "${STATE}/guest"
[[ "$1 $2 $3 $4" == "settings put system user_rotation" && $# == 5 ]] || exit 99
printf '%s\n' "$5" > "${STATE}/user_rotation"
STUB
chmod 0755 "${T}/bin/guest" "${GUEST}/"*
export MICROOS_ANDROID_GUEST="${T}/bin/guest"

released_log=$'wm fixed-to-user-rotation\nwm fixed-to-user-rotation default\ncmd settings put system user_rotation 0'

poke() {
    gdbus call --system -d net.seilent.MicroSet -o /net/seilent/MicroSet -m test.Stub.Poke "'$1'" "$2" > /dev/null
}

readies() {
    local c
    c=$(grep -cx ready "${T}/microset.log" 2>/dev/null) || true
    echo "${c:-0}"
}

start_microsetd() {
    local ready
    ready=$(readies)
    python3 "${microsetd}" "${T}/microset.log" speaker &
    msd=$!
    pids+=("${msd}")
    for _ in {1..50}; do (( $(readies) > ready )) && return 0; sleep 0.1; done
    echo "FAIL: fake microsetd did not start" >&2
    exit 1
}

stop_microsetd() {
    kill "${msd}" 2>/dev/null
    wait "${msd}" 2>/dev/null
}

logged() {
    local c
    c=$(grep -c "^microos-android-rotation: " "${T}/out" 2>/dev/null) || true
    echo "${c:-0}"
}

count() {
    local c
    c=$(grep -cxF -- "microos-android-rotation: $1" "${T}/out" 2>/dev/null) || true
    echo "${c:-0}"
}

waitout() {
    for _ in {1..60}; do (( $(count "$1") > $2 )) && return 0; sleep 0.1; done
    return 1
}

execs() {
    local c
    c=$(grep -c . "${STATE}/execs" 2>/dev/null) || true
    echo "${c:-0}"
}

start_writer() {
    : > "${T}/out"
    : > "${STATE}/guest"
    "${writer}" 2> "${T}/out" &
    writer_pid=$!
    pids+=("${writer_pid}")
}

stop_writer() {
    kill "${writer_pid}" 2>/dev/null
    wait "${writer_pid}" 2>/dev/null
}

step() {
    local n
    n=$(count "$3")
    : > "${STATE}/guest"
    poke "$1" "$2"
    waitout "$3" "${n}" || fail "no '$3' after $1 $2: $(cat "${T}/out")"
}

mode() { cat "${STATE}/mode"; }
rotation() { cat "${STATE}/user_rotation" 2>/dev/null; }

guest_is() {
    [[ "$(cat "${STATE}/guest")" == "$1" ]] || fail "the guest ran: $(tr '\n' ';' < "${STATE}/guest") not: ${1//$'\n'/;}"
}

forced_is() {
    guest_is $'wm fixed-to-user-rotation enabled\ncmd settings put system user_rotation '"$1"
    [[ "$(mode)" == enabled && "$(rotation)" == "$1" ]] || fail "mode $(mode), user_rotation $(rotation), not enabled and $1"
}

released_is() {
    guest_is "${released_log}"
    [[ "$(mode)" == default && "$(rotation)" == 0 ]] || fail "mode $(mode), user_rotation $(rotation), not default and 0"
}

held_is() {
    guest_is ""
    [[ "$(mode)" == enabled && "$(rotation)" == "$1" ]] || fail "mode $(mode), user_rotation $(rotation), not enabled and $1"
}

case_name="no orientation map"
printf 'width=960\nheight=640\ndensity=213\nubwc=0\n' > "${T}/display-none"
rc=0
MICROOS_DISPLAY_FILE="${T}/display-none" timeout 10 "${writer}" 2> "${T}/out" || rc=$?
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${T}/out")"
[[ "$(cat "${T}/out")" == "microos-android-rotation: ${T}/display-none has no orientation map, no forced orientation" ]] \
    || fail "not logged once: $(cat "${T}/out")"
[[ ! -e "${STATE}/execs" ]] || fail "the guest was called: $(cat "${STATE}/execs")"

case_name="a malformed orientation map"
for value in "landscape:0,portrait:3" "landscape:0,landscape-flipped:2,portrait:3,portrait-flipped:4" \
    "landscape:0,landscape-flipped:2,portrait:3,portrait:1" "landscape=0,landscape-flipped:2,portrait:3,portrait-flipped:1" \
    "landscape:0,landscape-flipped:2,portrait:3,portrait-flipped:1,sideways:1" ""; do
    printf 'density=400\norientation=%s\n' "${value}" > "${T}/display-bad"
    rc=0
    MICROOS_DISPLAY_FILE="${T}/display-bad" timeout 10 "${writer}" 2> "${T}/out" || rc=$?
    [[ "${rc}" == 1 ]] || fail "'${value}': exit ${rc}: $(cat "${T}/out")"
    want="cannot read the orientation map: orientation=${value} in ${T}/display-bad is not a rotation map"
    [[ "$(count "${want}")" == 1 ]] || fail "'${value}': not logged: $(cat "${T}/out")"
done
rc=0
MICROOS_DISPLAY_FILE="${T}/absent-display" timeout 10 "${writer}" 2> "${T}/out" || rc=$?
[[ "${rc}" == 1 ]] && grep -q "^microos-android-rotation: cannot read the orientation map: " "${T}/out" \
    || fail "no display file: exit ${rc}: $(cat "${T}/out")"
[[ ! -e "${STATE}/execs" ]] || fail "the guest was called: $(cat "${STATE}/execs")"

case_name="no system bus"
rc=0
DBUS_SYSTEM_BUS_ADDRESS="unix:path=${T}/nobus" timeout 10 "${writer}" 2> "${T}/out" || rc=$?
[[ "${rc}" == 1 ]] && grep -q "^microos-android-rotation: no system bus, no forced orientation: " "${T}/out" \
    || fail "exit ${rc}: $(cat "${T}/out")"
[[ ! -e "${STATE}/execs" ]] || fail "the guest was called: $(cat "${STATE}/execs")"

case_name="microsetd absent then appearing with auto rotate on"
start_writer
sleep 0.5
[[ "$(logged)" == 0 ]] || fail "logged without microsetd: $(cat "${T}/out")"
[[ ! -e "${STATE}/execs" ]] || fail "the guest was called without microsetd: $(cat "${STATE}/execs")"
start_microsetd
waitout auto 0 || fail "no reconcile when microsetd appeared: $(cat "${T}/out")"
guest_is "wm fixed-to-user-rotation"
[[ "$(mode)" == default && ! -e "${STATE}/user_rotation" ]] \
    || fail "a start with auto rotate on wrote: mode $(mode), user_rotation $(rotation)"

case_name="forced portrait"
step display.auto_rotate "<false>" "forced portrait, rotation 3"
forced_is 3
grep -qxF "/system/bin/cmd settings put system user_rotation '3' >/dev/null 2>&1 || r=1" "${STATE}/scripts" \
    || fail "the rotation is not passed quoted: $(cat "${STATE}/scripts")"

case_name="Changed to landscape-flipped"
step display.orientation "<'landscape-flipped'>" "forced landscape-flipped, rotation 2"
forced_is 2

case_name="landscape and portrait-flipped"
step display.orientation "<'landscape'>" "forced landscape, rotation 0"
forced_is 0
step display.orientation "<'portrait-flipped'>" "forced portrait-flipped, rotation 1"
forced_is 1

case_name="a bad orientation"
step display.orientation "<'sideways'>" "display.orientation 'sideways' not valid, the guest is left as it is"
held_is 1
step display.orientation "<uint32 1>" "display.orientation 1 not valid, the guest is left as it is"
held_is 1
poke display.orientation "<'sideways'>"
step display.orientation "<'landscape-flipped'>" "forced landscape-flipped, rotation 2"
forced_is 2
[[ "$(count "display.orientation 'sideways' not valid, the guest is left as it is")" == 1 ]] \
    || fail "the bad orientation was not logged once: $(cat "${T}/out")"

case_name="a bad auto rotate"
step display.auto_rotate "<'off'>" "display.auto_rotate 'off' not valid, the guest is left as it is"
held_is 2
step display.auto_rotate "<false>" "forced landscape-flipped, rotation 2"
forced_is 2

case_name="auto rotate back on"
step display.auto_rotate "<true>" released
released_is
step display.orientation "<'portrait'>" auto
guest_is "wm fixed-to-user-rotation"
[[ "$(mode)" == default && "$(rotation)" == 0 ]] \
    || fail "an orientation change with auto rotate on wrote: mode $(mode), user_rotation $(rotation)"

case_name="a failed guest call"
: > "${STATE}/gone"
step display.auto_rotate "<false>" "forced portrait, rotation 3: failed (rc=255)"
e=$(execs)
step display.auto_rotate "<true>" "the rotation mode read failed (rc=255)"
rm -f "${STATE}/gone"
[[ "$(execs)" == $((e + 1)) ]] || fail "more than the read after a failed read: $(tail -n 3 "${STATE}/execs")"
[[ ! -s "${STATE}/guest" && "$(mode)" == default && "$(rotation)" == 0 ]] \
    || fail "the guest changed while gone: $(cat "${STATE}/guest"), mode $(mode), user_rotation $(rotation)"

case_name="microsetd vanishes"
step display.auto_rotate "<false>" "forced portrait, rotation 3"
forced_is 3
n=$(count released)
: > "${STATE}/guest"
stop_microsetd
waitout released "${n}" || fail "no release on the vanish: $(cat "${T}/out")"
released_is
n=$(count auto)
start_microsetd
waitout auto "${n}" || fail "no reconcile on the return: $(cat "${T}/out")"
stop_writer

case_name="a start with the guest still forced"
echo enabled > "${STATE}/mode"
echo 2 > "${STATE}/user_rotation"
start_writer
waitout released 0 || fail "no release at start: $(cat "${T}/out")"
released_is
stop_writer

case_name="a start with auto rotate off"
poke display.auto_rotate "<false>"
poke display.orientation "<'landscape-flipped'>"
start_writer
waitout "forced landscape-flipped, rotation 2" 0 || fail "the stored keys were not applied: $(cat "${T}/out")"
forced_is 2
kill -TERM "${writer_pid}"
rc=0
wait "${writer_pid}" 2>/dev/null || rc=$?
[[ "${rc}" == 0 ]] || fail "exit ${rc} on TERM"
[[ "$(mode)" == enabled && "$(rotation)" == 2 ]] || fail "the stop changed the guest: mode $(mode), user_rotation $(rotation)"

[[ "${failures}" == 0 ]] || exit 1
echo "rotation-test: ok"
