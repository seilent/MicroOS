#!/usr/bin/bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/data/usr/libexec/microos"
writer="${libexec}/microos-android-lsfg"
stop_script="${libexec}/microos-android-stop"
microsetd="$(dirname "$(dirname "${repo}")")/tests/audio-policy/microsetd"

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
unset MANGOHUD_CONFIGFILE

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
export MICROOS_RUNTIME_DIR="${T}/run/microos-android"
mkdir -p "${STATE}/settings" "${STATE}/props" "${GUEST}" "${T}/bin" "${MICROOS_RUNTIME_DIR}"
echo 1 > "${STATE}/debuggable"

cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
printf 'podman %s %s %s\n' "$1" "$2" "${3:-}" >> "${STATE}/podman"
if [[ "$1" == exec ]]; then
    [[ ! -e "${STATE}/gone" ]] || { echo 'Error: no container with name or ID "lepton-android" found' >&2; exit 125; }
    if [[ -e "${STATE}/fail-once" ]]; then
        rm -f "${STATE}/fail-once"
        exit 125
    fi
    if [[ "$3" == /system/bin/sh ]]; then
        printf '%s\n--\n' "$5" >> "${STATE}/scripts"
        exec sh -c "${5//\/system\/bin\//${GUEST}/}"
    fi
    exit 0
fi
[[ "$*" == "stop -t 1 lepton-android" ]] && exit 0
exit 99
STUB
cat > "${GUEST}/cmd" <<'STUB'
#!/usr/bin/bash
echo "cmd $*" >> "${STATE}/guest"
[[ ! -e "${STATE}/slow" ]] || sleep 0.2
case "$1 $2 $3" in
    "settings put global") printf '%s\n' "$5" > "${STATE}/settings/$4" ;;
    "settings delete global") rm -f "${STATE}/settings/$4" ;;
esac
STUB
cat > "${GUEST}/setprop" <<'STUB'
#!/usr/bin/bash
echo "setprop $1 $2" >> "${STATE}/guest"
[[ ! -e "${STATE}/slow" ]] || sleep 0.2
printf '%s\n' "$2" > "${STATE}/props/$1"
STUB
cat > "${GUEST}/getprop" <<'STUB'
#!/usr/bin/bash
echo "getprop $1" >> "${STATE}/guest"
cat "${STATE}/debuggable"
STUB
chmod 0755 "${T}/bin/podman" "${GUEST}/"*
export PATH="${T}/bin:${PATH}"

on_app=com.example.VkCube
layers=VK_LAYER_LSFGVK_frame_generation
cleared_log=$'cmd settings delete global enable_gpu_debug_layers\ncmd settings delete global gpu_debug_app\ncmd settings delete global gpu_debug_layers\nsetprop debug.lsfgvk.fps \nsetprop debug.lsfgvk.dll_path \nsetprop debug.lsfgvk.flow_scale \nsetprop debug.lsfgvk.performance_mode \nsetprop debug.lsfgvk.multiplier '

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
    c=$(grep -c "^microos-android-lsfg: " "${T}/out" 2>/dev/null) || true
    echo "${c:-0}"
}

alive() {
    local c
    c=$(tr -d '\0' 2>/dev/null < "/proc/$1/cmdline")
    [[ -n "${c}" ]]
}

waitout() {
    for _ in {1..60}; do grep -qxF -- "microos-android-lsfg: $1" "${T}/out" && return 0; sleep 0.1; done
    return 1
}

count() {
    local c
    c=$(grep -cxF -- "microos-android-lsfg: $1" "${T}/out" 2>/dev/null) || true
    echo "${c:-0}"
}

start_writer() {
    : > "${T}/out"
    : > "${STATE}/guest"
    MICROOS_ANDROID_LSFG_LAYER=${layer:-1} MICROOS_ANDROID_LSFG_DLL=${dll:-1} "${writer}" 2> "${T}/out" &
    writer_pid=$!
    pids+=("${writer_pid}")
}

stop_writer() {
    kill "${writer_pid}" 2>/dev/null
    wait "${writer_pid}" 2>/dev/null
}

execs() {
    local c
    c=$(grep -cx -- -- "${STATE}/scripts" 2>/dev/null) || true
    echo "${c:-0}"
}

step() {
    local n e
    n=$(logged)
    e=$(execs)
    : > "${STATE}/guest"
    poke "$1" "$2"
    for _ in {1..60}; do
        if (( $(logged) > n )); then
            (( $(execs) == e + 1 )) || fail "not one guest exec for $1 $2: $(cat "${STATE}/scripts")"
            return 0
        fi
        sleep 0.1
    done
    fail "no reconcile after $1 $2: $(cat "${T}/out")"
}

setting() { cat "${STATE}/settings/$1" 2>/dev/null; }
prop() { cat "${STATE}/props/debug.lsfgvk.$1" 2>/dev/null; }

props_are() {
    local pair bad=""
    for pair in "$@"; do
        [[ "$(prop "${pair%%=*}")" == "${pair#*=}" ]] || bad+=" ${pair%%=*}=$(prop "${pair%%=*}")"
    done
    [[ -z "${bad}" ]] || { printf '%s\n' "${bad}"; return 1; }
}

is_on() {
    [[ "$(setting enable_gpu_debug_layers)" == 1 && "$(setting gpu_debug_app)" == "$1" \
        && "$(setting gpu_debug_layers)" == "${layers}" ]]
}

is_cleared() {
    [[ -z "$(ls -A "${STATE}/settings")" ]] && props_are fps= dll_path= flow_scale= performance_mode= multiplier= > /dev/null
}

no_put() { ! grep -q "^cmd settings put" "${STATE}/guest"; }

case_name="microsetd absent then appearing"
printf 'old.app\n' > "${STATE}/settings/gpu_debug_app"
printf '2\n' > "${STATE}/props/debug.lsfgvk.multiplier"
start_writer
for _ in {1..60}; do is_cleared && break; sleep 0.1; done
is_cleared || fail "no clear at start: $(ls -A "${STATE}/settings") $(cat "${T}/out")"
[[ "$(cat "${STATE}/guest")" == "getprop ro.debuggable"$'\n'"${cleared_log}" ]] \
    || fail "the clear at start is not the deletes then the props: $(cat "${STATE}/guest")"
sleep 0.5
[[ "$(execs)" == 1 ]] || fail "more than the clear at start without microsetd: $(cat "${STATE}/scripts")"
[[ "$(logged)" == 0 ]] || fail "logged without microsetd: $(cat "${T}/out")"
: > "${STATE}/guest"
start_microsetd
waitout "cleared, no app chosen" || fail "no reconcile when microsetd appeared: $(cat "${T}/out")"
[[ "$(cat "${STATE}/guest")" == "${cleared_log}" ]] || fail "the clear is not the deletes then the props: $(cat "${STATE}/guest")"
step lsfg.android_app "<'${on_app}'>"
step lsfg.android_state "<true>"
waitout "frame generation 2x for ${on_app}, base cap 30" || fail "no generation after the keys: $(cat "${T}/out")"
is_on "${on_app}" || fail "the settings are not on: $(ls -A "${STATE}/settings")"
stop_writer

case_name="on"
poke lsfg.flow_scale "<uint32 50>"
start_writer
waitout "frame generation 2x for ${on_app}, base cap 30" || fail "no generation at start: $(cat "${T}/out")"
on_log=$'setprop debug.lsfgvk.fps 30\nsetprop debug.lsfgvk.dll_path /vendor/etc/lsfg/Lossless.dll\nsetprop debug.lsfgvk.flow_scale 0.5\nsetprop debug.lsfgvk.performance_mode 1\nsetprop debug.lsfgvk.multiplier 2\ncmd settings put global enable_gpu_debug_layers 1\ncmd settings put global gpu_debug_app com.example.VkCube\ncmd settings put global gpu_debug_layers VK_LAYER_LSFGVK_frame_generation'
[[ "$(cat "${STATE}/guest")" == "getprop ro.debuggable"$'\n'"${cleared_log}"$'\n'"${on_log}" ]] \
    || fail "not the clear, then the props, then the settings: $(cat "${STATE}/guest")"
is_on "${on_app}" || fail "the settings are not on: $(ls -A "${STATE}/settings")"
grep -qxF "/system/bin/cmd settings put global gpu_debug_app '${on_app}' >/dev/null 2>&1 || r=1" "${STATE}/scripts" \
    || fail "the package is not passed quoted: $(cat "${STATE}/scripts")"

case_name="key change"
step lsfg.multiplier "<uint32 3>"
bad=$(props_are multiplier=3 fps=20) || fail "3x with auto: ${bad}"
grep -qxF "microos-android-lsfg: frame generation 3x for ${on_app}, base cap 20" "${T}/out" || fail "3x not logged: $(cat "${T}/out")"
step lsfg.fps_cap "<'off'>"
bad=$(props_are multiplier=3 fps=0) || fail "cap off: ${bad}"
step lsfg.fps_cap "<'20'>"
bad=$(props_are fps=20) || fail "cap 20: ${bad}"
step lsfg.multiplier "<uint32 2>"
step lsfg.fps_cap "<'auto'>"
bad=$(props_are multiplier=2 fps=30) || fail "back to auto: ${bad}"
step lsfg.performance_mode "<false>"
bad=$(props_are performance_mode=0) || fail "performance off: ${bad}"
is_on "${on_app}" || fail "a key change dropped the settings: $(ls -A "${STATE}/settings")"

case_name="multiplier under 2"
for m in 0 1; do
    step lsfg.multiplier "<uint32 ${m}>"
    grep -qxF "microos-android-lsfg: frame limit 0 for ${on_app}" "${T}/out" || fail "${m}: not the limit: $(cat "${T}/out")"
    bad=$(props_are multiplier=1 fps=0 dll_path= flow_scale= performance_mode=) || fail "${m}: ${bad}"
    is_on "${on_app}" || fail "${m}: the layer is not on for the limit: $(ls -A "${STATE}/settings")"
done
step lsfg.multiplier "<uint32 2>"
bad=$(props_are multiplier=2 fps=30) || fail "back to 2x: ${bad}"

case_name="unknown cap word"
warning="lsfg.fps_cap 'fast' unknown, using auto"
n=$(count "frame generation 2x for ${on_app}, base cap 30")
poke lsfg.fps_cap "<'fast'>"
for _ in {1..60}; do (( $(count "frame generation 2x for ${on_app}, base cap 30") > n )) && break; sleep 0.1; done
(( $(count "frame generation 2x for ${on_app}, base cap 30") > n )) || fail "no auto cap for fast: $(cat "${T}/out")"
bad=$(props_are multiplier=2 fps=30) || fail "fast: ${bad}"
n=$(count "frame generation 3x for ${on_app}, base cap 20")
poke lsfg.multiplier "<uint32 3>"
for _ in {1..60}; do (( $(count "frame generation 3x for ${on_app}, base cap 20") > n )) && break; sleep 0.1; done
bad=$(props_are multiplier=3 fps=20) || fail "fast at 3x: ${bad}"
[[ "$(count "${warning}")" == 1 ]] || fail "the unknown cap was not logged once: $(cat "${T}/out")"
step lsfg.multiplier "<uint32 2>"
step lsfg.fps_cap "<'auto'>"

case_name="flow_scale 25 to 0.25"
step lsfg.flow_scale "<uint32 25>"
bad=$(props_are flow_scale=0.25) || fail "${bad}"
step lsfg.flow_scale "<uint32 100>"
bad=$(props_are flow_scale=1.0) || fail "${bad}"

case_name="off"
step lsfg.android_app "<''>"
grep -qxF "microos-android-lsfg: cleared, no app chosen" "${T}/out" || fail "not logged: $(cat "${T}/out")"
[[ "$(cat "${STATE}/guest")" == "${cleared_log}" ]] || fail "not the deletes then the props: $(cat "${STATE}/guest")"
is_cleared || fail "not cleared: $(ls -A "${STATE}/settings")"

case_name="limit only"
step lsfg.android_fps "<uint32 45>"
step lsfg.android_app "<'${on_app}'>"
step lsfg.android_state "<false>"
grep -qxF "microos-android-lsfg: frame limit 45 for ${on_app}" "${T}/out" || fail "not logged: $(cat "${T}/out")"
bad=$(props_are fps=45 multiplier=1 dll_path= flow_scale= performance_mode=) || fail "${bad}"
is_on "${on_app}" || fail "the layer is not on for the limit: $(ls -A "${STATE}/settings")"
step lsfg.android_state "<true>"
step lsfg.enabled "<false>"
bad=$(props_are fps=45 multiplier=1 dll_path=) || fail "lsfg.enabled false: ${bad}"
step lsfg.enabled "<true>"
bad=$(props_are fps=30 multiplier=2) || fail "lsfg.enabled true: ${bad}"
stop_writer

case_name="DLL missing"
dll=0 start_writer
waitout "no Lossless.dll bind, frame limit 45 for ${on_app}" || fail "not logged: $(cat "${T}/out")"
bad=$(props_are fps=45 multiplier=1 dll_path=) || fail "${bad}"
is_on "${on_app}" || fail "the layer is not on for the limit: $(ls -A "${STATE}/settings")"
stop_writer

case_name="layer missing"
layer=0 start_writer
waitout "cleared, no layer bind" || fail "not logged: $(cat "${T}/out")"
is_cleared || fail "not cleared: $(ls -A "${STATE}/settings")"
no_put || fail "settings put without the layer: $(cat "${STATE}/guest")"
stop_writer

case_name="ro.debuggable read fails at start"
: > "${STATE}/fail-once"
start_writer
waitout "frame generation 2x for ${on_app}, base cap 30" || fail "no generation after the read again: $(cat "${T}/out")"
grep -qxF "microos-android-lsfg: the clear at start failed (rc=125)" "${T}/out" || fail "the failed start not logged: $(cat "${T}/out")"
grep -qxF "microos-android-lsfg: ro.debuggable unknown, read again at the next reconcile" "${T}/out" \
    || fail "the unknown read not logged: $(cat "${T}/out")"
[[ "$(grep -c '^getprop ro.debuggable$' "${STATE}/guest")" == 1 ]] || fail "not one read again: $(cat "${STATE}/guest")"
is_on "${on_app}" || fail "the settings are not on: $(ls -A "${STATE}/settings")"
stop_writer

case_name="ro.debuggable 0"
echo 0 > "${STATE}/debuggable"
start_writer
waitout "cleared, ro.debuggable is not 1" || fail "not logged: $(cat "${T}/out")"
grep -qxF "microos-android-lsfg: ro.debuggable is not 1, clear only" "${T}/out" || fail "the read not logged: $(cat "${T}/out")"
step lsfg.multiplier "<uint32 3>"
is_cleared || fail "not cleared: $(ls -A "${STATE}/settings")"
no_put || fail "settings put on a user build: $(cat "${STATE}/guest")"
step lsfg.multiplier "<uint32 2>"
stop_writer
echo 1 > "${STATE}/debuggable"

case_name="bad package name"
start_writer
waitout "frame generation 2x for ${on_app}, base cap 30" || fail "no generation at start: $(cat "${T}/out")"
for bad_app in "com.example.VkCube;reboot" "1com.example" "vkcube" "com.example.VkCube'x" "com..example"; do
    : > "${STATE}/scripts"
    step lsfg.android_app "<\"${bad_app}\">"
    want=$(python3 -c 'import sys; print(repr(sys.argv[1]))' "${bad_app}")
    grep -qxF "microos-android-lsfg: cleared, ${want} is not a package name" "${T}/out" \
        || fail "${bad_app}: not logged: $(cat "${T}/out")"
    is_cleared || fail "${bad_app}: not cleared: $(ls -A "${STATE}/settings")"
    no_put || fail "${bad_app}: settings put: $(cat "${STATE}/guest")"
    grep -qF "${bad_app}" "${STATE}/scripts" && fail "${bad_app}: the name reached the guest: $(cat "${STATE}/scripts")"
done
step lsfg.android_app "<'${on_app}'>"

case_name="microsetd vanishes"
n=$(logged)
stop_microsetd
for _ in {1..60}; do (( $(logged) > n )) && break; sleep 0.1; done
grep -qxF "microos-android-lsfg: cleared, no microsetd" "${T}/out" || fail "not logged: $(cat "${T}/out")"
is_cleared || fail "not cleared: $(ls -A "${STATE}/settings")"
start_microsetd
waitout "cleared, no app chosen" || fail "no reconcile on the return: $(cat "${T}/out")"
stop_writer

on() {
    poke lsfg.android_app "<'${on_app}'>"
    poke lsfg.android_state "<true>"
    start_writer
    waitout "frame generation 2x for ${on_app}, base cap 30" || fail "no generation at start: $(cat "${T}/out")"
    printf '%s\n' "${writer_pid}" > "${MICROOS_RUNTIME_DIR}/lsfg-writer.pid"
}

case_name="stop with the container gone"
on
: > "${STATE}/podman"
: > "${STATE}/gone"
rc=0
timeout 15 "${stop_script}" 2> "${T}/stop.err" || rc=$?
rm -f "${STATE}/gone"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${T}/stop.err")"
alive "${writer_pid}" && fail "the writer still runs"
[[ ! -e "${MICROOS_RUNTIME_DIR}/lsfg-writer.pid" ]] || fail "the pid file is left"
grep -qxF "microos-android-stop: the frame generation clear failed" "${T}/stop.err" || fail "no log: $(cat "${T}/stop.err")"
[[ "$(head -n 1 "${STATE}/podman")" == "podman exec lepton-android /system/bin/sh" ]] \
    || fail "the clear is not the first guest call: $(cat "${STATE}/podman")"
grep -n "" "${STATE}/podman" | grep -q "^[2-9]:podman exec lepton-android /system/bin/am" \
    || fail "no HOME intent after the clear: $(cat "${STATE}/podman")"
[[ "$(tail -n 1 "${STATE}/podman")" == "podman stop -t 1" ]] || fail "no stop: $(cat "${STATE}/podman")"
wait "${writer_pid}" 2>/dev/null

case_name="stop, the pid file names another process"
sleep 30 &
other=$!
pids+=("${other}")
printf '%s\n' "${other}" > "${MICROOS_RUNTIME_DIR}/lsfg-writer.pid"
"${stop_script}" 2> "${T}/stop.err"
alive "${other}" || fail "the stop killed a process that is not the writer"
[[ ! -e "${MICROOS_RUNTIME_DIR}/lsfg-writer.pid" ]] || fail "the pid file is left"
is_cleared || fail "not cleared: $(ls -A "${STATE}/settings")"
kill "${other}" 2>/dev/null

case_name="Changed during the stop"
on
: > "${STATE}/slow"
n=$(logged)
: > "${STATE}/guest"
poke lsfg.multiplier "<uint32 3>"
for _ in {1..40}; do [[ -s "${STATE}/guest" ]] && break; sleep 0.05; done
[[ "$(head -n 1 "${STATE}/guest")" == "setprop debug.lsfgvk.fps 20" ]] || fail "the 3x reconcile did not start: $(cat "${STATE}/guest")"
"${stop_script}" 2> "${T}/stop.err" &
stopper=$!
for _ in {1..40}; do grep -qxF "microos-android-stop: sent TERM to the frame generation writer ${writer_pid}" "${T}/stop.err" && break; sleep 0.05; done
grep -qxF "microos-android-stop: sent TERM to the frame generation writer ${writer_pid}" "${T}/stop.err" \
    || fail "the stop did not TERM the writer: $(cat "${T}/stop.err")"
poke lsfg.multiplier "<uint32 2>"
poke lsfg.android_state "<false>"
rc=0
wait "${stopper}" || rc=$?
rm -f "${STATE}/slow"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${T}/stop.err")"
alive "${writer_pid}" && fail "the writer still runs"
wait "${writer_pid}" 2>/dev/null
grep -qxF "microos-android-lsfg: frame generation 3x for ${on_app}, base cap 20" "${T}/out" \
    || fail "the reconcile running at the stop did not finish: $(cat "${T}/out")"
(( $(logged) == n + 1 )) || fail "a reconcile after the stop: $(cat "${T}/out")"
is_cleared || fail "the stop clear did not run last: $(ls -A "${STATE}/settings") $(cat "${STATE}/guest")"
[[ "$(tail -n 8 "${STATE}/guest")" == "${cleared_log}" ]] || fail "the last guest calls are not the clear: $(cat "${STATE}/guest")"

[[ "${failures}" == 0 ]] || exit 1
echo "lsfg-test: ok"
