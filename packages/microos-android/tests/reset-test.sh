#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
cli="${repo}/data/usr/bin/microos-android"

T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

export STATE="${T}/stub"
export HOME="${T}/home"
export MICROOS_ANDROID_STATE="${T}/state"
export MICROOS_ANDROID_VAR="${T}/var"
export MICROOS_SYSTEM_CARD="${T}/system-card"
export MICROOS_SYSTEMCTL="${T}/systemctl"
mkdir -p "${STATE}" "${HOME}" "${MICROOS_ANDROID_STATE}" "${MICROOS_ANDROID_VAR}"
cat > "${T}/systemctl" <<'STUB'
#!/usr/bin/bash
echo "$*" >> "${STATE}/systemctl"
exit "$(cat "${STATE}/rc" 2>/dev/null || echo 0)"
STUB
chmod 0755 "${T}/systemctl"

state='{"gapps": {"gms": "on", "play": "on"}, "last": {"boottime": 12, "reason": "", "result": "ready"}, "touch": {"result": "set"}}'
printf '%s\n' "${state}" > "${MICROOS_ANDROID_STATE}/state.json"
rc=0
"${cli}" reset > "${T}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 && ! -e "${STATE}/systemctl" ]] || fail "reset without --yes: ${rc}"
grep -q 'refusing without --yes' "${T}/out" || fail "no refusal text: $(cat "${T}/out")"
rc=0
"${cli}" reset --yes extra > /dev/null 2>&1 || rc=$?
[[ "${rc}" == 1 && ! -e "${STATE}/systemctl" ]] || fail "reset with an extra word: ${rc}"
echo 1 > "${STATE}/rc"
rc=0
"${cli}" reset --yes > "${T}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 ]] || fail "a failed reset unit exited ${rc}"
grep -qx 'start microos-android-reset.service' "${STATE}/systemctl" || fail "reset unit: $(cat "${STATE}/systemctl")"
[[ "$(< "${MICROOS_ANDROID_STATE}/state.json")" == "${state}" ]] || fail "a failed reset changed the state"
rm -f "${STATE}/rc"
"${cli}" reset --yes > "${T}/out" 2>&1 || fail "reset --yes: $(cat "${T}/out")"
[[ "$(< "${MICROOS_ANDROID_STATE}/state.json")" == '{"gapps": {}, "last": {"boottime": 12}, "touch": {"result": "set"}}' ]] \
    || fail "state after the reset: $(cat "${MICROOS_ANDROID_STATE}/state.json")"
[[ "$(stat -c %a "${MICROOS_ANDROID_STATE}/state.json")" == 600 ]] || fail "state mode"
grep -q 'fresh guest' "${T}/out" || fail "no reset text: $(cat "${T}/out")"
rm -f "${MICROOS_ANDROID_STATE}/state.json"
"${cli}" reset --yes > /dev/null 2>&1 || fail "reset with no state file"
[[ ! -e "${MICROOS_ANDROID_STATE}/state.json" ]] || fail "reset made a state file"

(( failures == 0 )) || { echo "${failures} failure(s)" >&2; exit 1; }
echo "reset-test: pass"
