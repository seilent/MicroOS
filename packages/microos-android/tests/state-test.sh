#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
client="${repo}/data/usr/libexec/microos/microos-android-client"

T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

command -v python3 > /dev/null || { echo "FAIL: python3 missing" >&2; exit 1; }
export MICROOS_ANDROID_STATE="${T}/state"
export MICROOS_STATE_LOCK_WAIT=1

update() {
    python3 - "${client}" "$1" <<'PY'
import importlib.machinery
import importlib.util
import json
import sys

sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("client", sys.argv[1])
spec = importlib.util.spec_from_loader("client", loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
module.update_state(json.loads(sys.argv[2]))
PY
}

update '{"last.result": "ready", "last.reason": "", "last.boottime": 5}'
[[ "$(< "${MICROOS_ANDROID_STATE}/state.json")" == '{"last": {"boottime": 5, "reason": "", "result": "ready"}}' ]] \
    || fail "first write: $(cat "${MICROOS_ANDROID_STATE}/state.json")"
[[ "$(stat -c %a "${MICROOS_ANDROID_STATE}/state.json")" == 600 && "$(stat -c %a "${MICROOS_ANDROID_STATE}")" == 700 ]] \
    || fail "state modes"
update '{"gapps.play": "on", "gapps.gms": "off"}'
[[ "$(< "${MICROOS_ANDROID_STATE}/state.json")" == '{"gapps": {"gms": "off", "play": "on"}, "last": {"boottime": 5, "reason": "", "result": "ready"}}' ]] \
    || fail "merge: $(cat "${MICROOS_ANDROID_STATE}/state.json")"
echo '{"last": "flat"}' > "${MICROOS_ANDROID_STATE}/state.json"
update '{"last.result": "refused"}'
[[ "$(< "${MICROOS_ANDROID_STATE}/state.json")" == '{"last": {"result": "refused"}}' ]] \
    || fail "a flat key under a nested write: $(cat "${MICROOS_ANDROID_STATE}/state.json")"
echo 'not json' > "${MICROOS_ANDROID_STATE}/state.json"
update '{"touch.result": "set"}'
[[ "$(< "${MICROOS_ANDROID_STATE}/state.json")" == '{"touch": {"result": "set"}}' ]] \
    || fail "a broken state file: $(cat "${MICROOS_ANDROID_STATE}/state.json")"
flock -x "${MICROOS_ANDROID_STATE}/state.json.lock" sleep 3 &
holder=$!
sleep 0.3
update '{"touch.reason": ""}' 2> "${T}/err"
grep -q 'is held, writing anyway' "${T}/err" || fail "no held lock log: $(cat "${T}/err")"
kill "${holder}" 2>/dev/null || true
wait "${holder}" 2>/dev/null || true
[[ -z "$(find "${MICROOS_ANDROID_STATE}" -name '*.new')" ]] || fail "a temp file is left"

(( failures == 0 )) || { echo "${failures} failure(s)" >&2; exit 1; }
echo "state-test: pass"
