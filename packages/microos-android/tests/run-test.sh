#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
units="${repo}/data/usr/lib/systemd/user"
unit="${units}/microos-android.service"

T=$(mktemp -d)
pid=
cleanup() {
    [[ -z "${pid}" ]] || kill "${pid}" 2>/dev/null || true
    rm -rf "${T:?}"
}
trap cleanup EXIT
failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

want=$'[Unit]
Description=Android session on Waydroid
Requisite=gamescope-session-plus@android.service
After=gamescope-session-plus@android.service
PartOf=gamescope-session-plus@android.service
StopPropagatedFrom=gamescope-session-plus@android.service
Wants=microos-android-brightness.service

[Service]
Type=simple
EnvironmentFile=%t/microos-android/session.env
ExecStart=/usr/bin/flock -s /run/microos-android/images.lock /usr/bin/waydroid session start
ExecStop=-/usr/libexec/microos/microos-android-guest stop
ExecStop=/usr/bin/waydroid session stop
ExecStopPost=/usr/bin/waydroid session stop
TimeoutStopSec=45'
[[ "$(< "${unit}")" == "${want}" ]] || fail "microos-android.service: $(diff <(echo "${want}") "${unit}")"
grep -qE '^(KillMode|SendSIGKILL|Restart)=' "${unit}" && fail "the session owner overrides its kill or restart"
for line in PartOf=microos-android.service After=microos-android.service; do
    grep -qxF "${line}" "${units}/microos-android-brightness.service" || fail "the bridge lacks ${line}"
done
for u in battery lsfg perf; do
    for line in BindsTo=microos-android.service After=microos-android.service; do
        grep -qxF "${line}" "${units}/microos-android-${u}.service" || fail "microos-android-${u}.service lacks ${line}"
    done
done
grep -qxF 'ExecStopPost=/usr/libexec/microos/microos-android-lsfg clear' "${units}/microos-android-lsfg.service" \
    || fail "the frame generation writer does not clear at stop"
grep -qxF 'ExecStopPost=/usr/libexec/microos/microos-android-perf off' "${units}/microos-android-perf.service" \
    || fail "the overlay writer does not turn the overlay off at stop"
for u in lsfg perf; do
    grep -qxF 'EnvironmentFile=%t/microos-android/session.env' "${units}/microos-android-${u}.service" \
        || fail "microos-android-${u}.service does not read session.env"
done

stop_s=$(sed -n 's/^TimeoutStopSec=//p' "${unit}")
guest_s=$(sed -n 's/^STOP_S="${MICROOS_GUEST_STOP_S:-\([0-9]*\)}"$/\1/p' "${repo}/data/usr/libexec/microos/microos-android-guest")
if [[ -z "${guest_s}" ]] || (( stop_s < guest_s + 20 )); then
    fail "TimeoutStopSec ${stop_s} leaves no room past the ${guest_s} s wait"
fi

line=$(sed -n 's/^ExecStart=//p' "${unit}")
read -r -a argv <<< "${line}"
[[ "${argv[0]} ${argv[1]}" == "/usr/bin/flock -s" && "${argv[2]}" == /run/microos-android/images.lock ]] \
    || fail "ExecStart does not take the images lock shared"
lock="${T}/images.lock"
: > "${lock}"
cat > "${T}/waydroid" <<'FAKE'
#!/usr/bin/bash
echo "$*" > "$(dirname "$0")/started"
echo "$$" > "$(dirname "$0")/child"
exec sleep 600
FAKE
chmod 0755 "${T}/waydroid"
flock -s "${lock}" "${T}/waydroid" session start &
pid=$!
for _ in {1..50}; do [[ -e "${T}/started" ]] && break; sleep 0.1; done
[[ "$(cat "${T}/started" 2>/dev/null)" == "session start" ]] || fail "the session did not start under the lock"
flock -x -n "${lock}" true && fail "an exclusive lock was taken while the session holds it shared"
flock -s -n "${lock}" true || fail "a second shared reader was refused"
kill "$(cat "${T}/child")" "${pid}" 2>/dev/null || true
wait "${pid}" 2>/dev/null || true
pid=
flock -x -n "${lock}" true || fail "the lock stayed held after the session ended"

(( failures == 0 )) || { echo "${failures} failure(s)" >&2; exit 1; }
echo "run-test: pass"
