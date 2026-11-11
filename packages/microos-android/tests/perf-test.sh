#!/usr/bin/bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/data/usr/libexec/microos"
writer="${libexec}/microos-android-perf"
stop_script="${libexec}/microos-android-stop"
microsetd="$(dirname "$(dirname "${repo}")")/tests/audio-policy/microsetd"

T=$(mktemp -d)
cfg=$(mktemp /tmp/mangohud.XXXXXXXX)
pids=()
cleanup() {
    for p in "${pids[@]}"; do
        kill "${p}" 2>/dev/null || true
        wait "${p}" 2>/dev/null || true
    done
    rm -f "${cfg:?}"
    rm -rf "${T}"
}
trap cleanup EXIT

failures=0
skipped=0
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

export STATE="${T}/state"
export MICROOS_RUNTIME_DIR="${T}/run/microos-android"
mkdir -p "${STATE}" "${T}/bin" "${MICROOS_RUNTIME_DIR}"
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
printf 'podman %s\n' "$*" >> "${STATE}/podman"
exit 0
STUB
chmod 0755 "${T}/bin/podman"
export PATH="${T}/bin:${PATH}"
printf 'no_display\n' > "${cfg}"

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
    c=$(grep -c "^microos-android-perf: " "${T}/out" 2>/dev/null) || true
    echo "${c:-0}"
}

count() {
    local c
    c=$(grep -cxF -- "microos-android-perf: $1" "${T}/out" 2>/dev/null) || true
    echo "${c:-0}"
}

waitout() {
    for _ in {1..60}; do (( $(count "$1") > ${2:-0} )) && return 0; sleep 0.1; done
    return 1
}

step() {
    local n
    n=$(count "$3")
    poke perf.android_overlay "$1"
    waitout "$3" "${n}" || fail "no $3 after $1: $(cat "${T}/out")"
    [[ "$(cat "${cfg}")" == "$2" ]] || fail "the config holds $(cat "${cfg}") after $1, not $2"
}

start_writer() {
    : > "${T}/out"
    MANGOHUD_CONFIGFILE="${cfg}" "${writer}" 2> "${T}/out" &
    writer_pid=$!
    pids+=("${writer_pid}")
}

stop_writer() {
    kill "${writer_pid}" 2>/dev/null
    wait "${writer_pid}" 2>/dev/null
}

refused() {
    local rc=0
    : > "${T}/out"
    timeout 5 "$@" 2> "${T}/out" || rc=$?
    [[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${T}/out")"
}

alive() {
    local c
    c=$(tr -d '\0' 2>/dev/null < "/proc/$1/cmdline")
    [[ -n "${c}" ]]
}

case_name="microsetd absent then appearing"
printf 'preset=2\n' > "${cfg}"
start_writer
sleep 0.5
[[ "$(logged)" == 0 ]] || fail "logged without microsetd: $(cat "${T}/out")"
[[ "$(cat "${cfg}")" == preset=2 ]] || fail "written without microsetd: $(cat "${cfg}")"
start_microsetd
waitout "overlay off" || fail "the default was not applied at appear: $(cat "${T}/out")"
[[ "$(cat "${cfg}")" == no_display ]] || fail "the config holds $(cat "${cfg}")"

case_name="on and off in place"
inode=$(stat -c %i "${cfg}")
step "<true>" preset=2 "overlay on"
step "<false>" no_display "overlay off"
step "<true>" preset=2 "overlay on"
[[ "$(stat -c %i "${cfg}")" == "${inode}" ]] || fail "the config was replaced, not rewritten"
[[ "$(stat -c %s "${cfg}")" == 9 ]] || fail "the config is $(stat -c %s "${cfg}") bytes, not preset=2 and a newline"
stop_writer

case_name="apply at appear"
printf 'no_display\n' > "${cfg}"
start_writer
waitout "overlay on" || fail "the stored true was not applied: $(cat "${T}/out")"
[[ "$(cat "${cfg}")" == preset=2 ]] || fail "the config holds $(cat "${cfg}")"

case_name="keep on vanish"
n=$(logged)
stop_microsetd
sleep 0.5
[[ "$(logged)" == "${n}" ]] || fail "logged on the vanish: $(cat "${T}/out")"
[[ "$(cat "${cfg}")" == preset=2 ]] || fail "the vanish changed the config: $(cat "${cfg}")"
alive "${writer_pid}" || fail "the writer exited on the vanish"
start_microsetd
waitout "overlay off" || fail "no apply on the return: $(cat "${T}/out")"
step "<true>" preset=2 "overlay on"
stop_writer

case_name="a link swapped in"
printf 'kept\n' > "${T}/target"
poke perf.android_overlay "<true>"
start_writer
waitout "overlay on" || fail "no apply at start: $(cat "${T}/out")"
rm -f "${cfg:?}"
ln -s "${T}/target" "${cfg}"
want="${cfg} is not a regular file owned by $(id -u), not written"
poke perf.android_overlay "<false>"
waitout "${want}" || fail "the link was not refused: $(cat "${T}/out")"
poke perf.android_overlay "<true>"
sleep 0.3
[[ "$(count "${want}")" == 1 ]] || fail "the refusal was not logged once: $(cat "${T}/out")"
[[ "$(cat "${T}/target")" == kept ]] || fail "the link target was written: $(cat "${T}/target")"
rm -f "${cfg:?}"
printf 'no_display\n' > "${cfg}"
stop_writer

case_name="missing variable"
refused env -u MANGOHUD_CONFIGFILE "${writer}"
grep -qxF "microos-android-perf: no MANGOHUD_CONFIGFILE, no overlay control" "${T}/out" || fail "not logged: $(cat "${T}/out")"

case_name="bad path"
for path in "${T}/mangohud.Ab3dE5fG" /tmp/mangohud.Ab3dE5f /tmp/mangohud.Ab3dE5fGh "/tmp/mangohud.Ab3d/5fG" \
    "${cfg}"$'\n'; do
    refused env MANGOHUD_CONFIGFILE="${path}" "${writer}"
    want=$(python3 -c 'import sys; print(repr(sys.argv[1]))' "${path}")
    grep -qxF "microos-android-perf: ${want} is not a mangohud config path, no overlay control" "${T}/out" \
        || fail "${path}: not logged: $(cat "${T}/out")"
done
[[ "$(cat "${cfg}")" == no_display ]] || fail "the config changed: $(cat "${cfg}")"

case_name="a link"
link=$(mktemp -u /tmp/mangohud.XXXXXXXX)
ln -s "${T}/target" "${link}"
refused env MANGOHUD_CONFIGFILE="${link}" "${writer}"
rm -f "${link:?}"
grep -qxF "microos-android-perf: ${link} is not a regular file owned by $(id -u), no overlay control" "${T}/out" \
    || fail "not logged: $(cat "${T}/out")"
[[ "$(cat "${T}/target")" == kept ]] || fail "the link target was written: $(cat "${T}/target")"

case_name="missing file"
gone=$(mktemp -u /tmp/mangohud.XXXXXXXX)
refused env MANGOHUD_CONFIGFILE="${gone}" "${writer}"
grep -qxF "microos-android-perf: cannot read ${gone}: No such file or directory, no overlay control" "${T}/out" \
    || fail "not logged: $(cat "${T}/out")"
[[ ! -e "${gone}" ]] || fail "the file was created"

case_name="wrong owner"
real_unshare=$(PATH=/usr/bin:/bin command -v unshare) || real_unshare=
if [[ -n "${real_unshare}" ]] && "${real_unshare}" -rm true 2>/dev/null; then
    refused "${real_unshare}" -rm sh -c 'mount --bind /etc/passwd "$1" && MANGOHUD_CONFIGFILE="$1" exec "$2"' _ "${cfg}" "${writer}"
    grep -qxF "microos-android-perf: ${cfg} is not a regular file owned by 0, no overlay control" "${T}/out" \
        || fail "not logged: $(cat "${T}/out")"
    [[ "$(cat "${cfg}")" == no_display ]] || fail "the config changed: $(cat "${cfg}")"
    case_name="stop, wrong owner"
    rc=0
    timeout 15 "${real_unshare}" -rm sh -c 'mount --bind /etc/passwd "$1" && MANGOHUD_CONFIGFILE="$1" exec "$2"' \
        _ "${cfg}" "${stop_script}" 2> "${T}/stop.err" || rc=$?
    [[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${T}/stop.err")"
    grep -qxF "microos-android-stop: cannot write no_display to ${cfg}" "${T}/stop.err" \
        || fail "no log: $(cat "${T}/stop.err")"
    [[ "$(cat "${cfg}")" == no_display ]] || fail "the config changed: $(cat "${cfg}")"
else
    skipped=$((skipped + 1))
    echo "SKIP wrong owner: unshare -rm cannot run" >&2
fi

on() {
    poke perf.android_overlay "<true>"
    start_writer
    waitout "overlay on" || fail "no apply at start: $(cat "${T}/out")"
    printf '%s\n' "${writer_pid}" > "${MICROOS_RUNTIME_DIR}/perf-writer.pid"
}

stop_run() {
    rc=0
    : > "${STATE}/podman"
    timeout 15 "$@" "${stop_script}" ${verb:+"${verb}"} 2> "${T}/stop.err" || rc=$?
    [[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${T}/stop.err")"
    [[ ! -e "${MICROOS_RUNTIME_DIR}/perf-writer.pid" ]] || fail "the pid file is left"
}

verb=
case_name="stop after a KILL"
on
kill -KILL "${writer_pid}"
wait "${writer_pid}" 2>/dev/null
[[ "$(cat "${cfg}")" == preset=2 ]] || fail "not on before the stop: $(cat "${cfg}")"
inode=$(stat -c %i "${cfg}")
stop_run env MANGOHUD_CONFIGFILE="${cfg}"
[[ "$(cat "${cfg}")" == no_display ]] || fail "the stop did not write no_display: $(cat "${cfg}")"
[[ "$(stat -c %i "${cfg}")" == "${inode}" ]] || fail "the config was replaced, not rewritten"
grep -q "performance overlay" "${T}/stop.err" && fail "a dead writer was signalled: $(cat "${T}/stop.err")"
grep -q "^podman stop" "${STATE}/podman" || fail "no container stop: $(cat "${STATE}/podman")"

case_name="stop with the writer running"
on
stop_run env MANGOHUD_CONFIGFILE="${cfg}"
alive "${writer_pid}" && fail "the writer still runs"
grep -qxF "microos-android-stop: sent TERM to the performance overlay writer ${writer_pid}" "${T}/stop.err" \
    || fail "no log: $(cat "${T}/stop.err")"
[[ "$(cat "${cfg}")" == no_display ]] || fail "the stop did not write no_display: $(cat "${cfg}")"
wait "${writer_pid}" 2>/dev/null

case_name="stop, the pid file names another process"
sleep 30 &
other=$!
pids+=("${other}")
printf '%s\n' "${other}" > "${MICROOS_RUNTIME_DIR}/perf-writer.pid"
printf 'preset=2\n' > "${cfg}"
stop_run env MANGOHUD_CONFIGFILE="${cfg}"
alive "${other}" || fail "the stop killed a process that is not the writer"
[[ "$(cat "${cfg}")" == no_display ]] || fail "the stop did not write no_display: $(cat "${cfg}")"
kill "${other}" 2>/dev/null

case_name="stop with no variable"
printf 'preset=2\n' > "${cfg}"
stop_run env -u MANGOHUD_CONFIGFILE
[[ ! -s "${T}/stop.err" ]] || fail "logged: $(cat "${T}/stop.err")"
[[ "$(cat "${cfg}")" == preset=2 ]] || fail "the config changed: $(cat "${cfg}")"

case_name="stop refuses a link and a bad path"
rm -f "${cfg:?}"
ln -s "${T}/target" "${cfg}"
for path in "${cfg}" "${T}/target"; do
    stop_run env MANGOHUD_CONFIGFILE="${path}"
    grep -qxF "microos-android-stop: cannot write no_display to ${path}" "${T}/stop.err" \
        || fail "${path}: no log: $(cat "${T}/stop.err")"
    [[ "$(cat "${T}/target")" == kept ]] || fail "${path}: the target was written: $(cat "${T}/target")"
done
rm -f "${cfg:?}"
stop_run env MANGOHUD_CONFIGFILE="${cfg}"
grep -qxF "microos-android-stop: cannot write no_display to ${cfg}" "${T}/stop.err" || fail "missing: no log: $(cat "${T}/stop.err")"
[[ ! -e "${cfg}" ]] || fail "the stop created the config"

case_name="post after a failed start"
printf 'preset=2\n' > "${cfg}"
inode=$(stat -c %i "${cfg}")
verb=--post stop_run env MANGOHUD_CONFIGFILE="${cfg}"
[[ "$(cat "${cfg}")" == no_display ]] || fail "the post did not write no_display: $(cat "${cfg}")"
[[ "$(stat -c %i "${cfg}")" == "${inode}" ]] || fail "the config was replaced, not rewritten"

case_name="stop kills a writer that ignores TERM"
mkdir -p "${T}/stub"
cat > "${T}/stub/microos-android-perf" <<'STUB'
#!/usr/bin/bash
trap '' TERM
while :; do sleep 0.05; done
STUB
chmod 0755 "${T}/stub/microos-android-perf"
"${T}/stub/microos-android-perf" &
stubborn=$!
pids+=("${stubborn}")
printf '%s\n' "${stubborn}" > "${MICROOS_RUNTIME_DIR}/perf-writer.pid"
printf 'preset=2\n' > "${cfg}"
stop_run env MICROOS_LSFG_TIMEOUT_S=0 MANGOHUD_CONFIGFILE="${cfg}"
grep -qxF "microos-android-stop: the performance overlay writer ${stubborn} did not stop, killing it" "${T}/stop.err" \
    || fail "no kill log: $(cat "${T}/stop.err")"
wait "${stubborn}" 2>/dev/null
alive "${stubborn}" && fail "the writer still runs"
[[ "$(cat "${cfg}")" == no_display ]] || fail "the stop did not write no_display: $(cat "${cfg}")"

case_name="one config path pattern"
pattern=$(sed -n 's/^CONFIG = re.compile(r"\(.*\)")$/\1/p' "${writer}")
[[ -n "${pattern}" ]] || fail "no pattern in the writer"
grep -qF "=~ ^${pattern}\$ " "${stop_script}" || fail "the stop's pattern is not ${pattern}"
grep -qF "MANGOHUD_CONFIG = re.compile(r\"${pattern}\")" "${libexec}/microos-android-client" \
    || fail "the client's pattern is not ${pattern}"

if (( failures )); then
    echo "perf-test: ${failures} failure(s), ${skipped} skipped" >&2
    exit 1
fi
echo "perf-test: ok, ${skipped} skipped"
