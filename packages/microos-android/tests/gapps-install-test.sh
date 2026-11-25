#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
data="${repo}/data/usr"
cli="${data}/bin/microos-android"
root="${data}/libexec/microos/microos-android-root"
unit="${data}/lib/systemd/user/microos-android-gapps.service"

T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

export STATE="${T}/stub"
export MICROOS_SYSTEMCTL="${T}/systemctl"
mkdir -p "${STATE}"
cat > "${T}/systemctl" <<'STUB'
#!/usr/bin/bash
echo "$*" >> "${STATE}/systemctl"
[[ "$1 $2" != "--user is-active" ]] || exec grep -qxF -- "${@: -1}" "${STATE}/active" 2>/dev/null
! grep -qxF -- "$*" "${STATE}/fails" 2>/dev/null
STUB
chmod 0755 "${T}/systemctl"

run() {
    rc=0
    rm -f "${STATE}/systemctl"
    "${cli}" gapps install > "${T}/out" 2>&1 || rc=$?
}

calls() {
    [[ "$(cat "${STATE}/systemctl")" == "$(printf '%s\n' "$@")" ]]
}

[[ "$(sed -n 's/^ExecStart=//p' "${unit}")" == "/usr/bin/microos-android gapps install" ]] || fail "the user unit ExecStart"
grep -qE '^(Nice|IOSchedulingClass|CPUWeight)=' "${unit}" && fail "the user unit sets a priority the root unit owns"
run
[[ "${rc}" == 0 ]] || fail "gapps install: $(cat "${T}/out")"
calls "--user is-active -q microos-android.service" "start microos-android-gapps@install.service" \
    || fail "gapps install with Android stopped does not wait on the root unit: $(cat "${STATE}/systemctl")"
grep -q 'next start' "${T}/out" || fail "gapps install with Android stopped: $(cat "${T}/out")"

in_session=("--user is-active -q microos-android.service" "start microos-android-gapps@fetch.service"
    "--user stop microos-android.service" "start microos-android-gapps@install.service"
    "--user is-active -q gamescope-session-plus@android.service" "--user start microos-android.service")
printf '%s\n' microos-android.service gamescope-session-plus@android.service > "${STATE}/active"
run
[[ "${rc}" == 0 ]] || fail "gapps install in the Android session: $(cat "${T}/out")"
calls "${in_session[@]}" \
    || fail "gapps install in the Android session does not fetch, stop, install and start: $(cat "${STATE}/systemctl")"
grep -q 'starts again' "${T}/out" || fail "gapps install in the Android session: $(cat "${T}/out")"
echo "start microos-android-gapps@fetch.service" > "${STATE}/fails"
run
{ [[ "${rc}" == 1 ]] && calls "${in_session[@]:0:2}"; } \
    || fail "a failed fetch stopped Android: ${rc} $(cat "${STATE}/systemctl")"
grep -qF "journalctl -u microos-android-gapps@fetch.service" "${T}/out" || fail "a failed fetch: $(cat "${T}/out")"
echo "start microos-android-gapps@install.service" > "${STATE}/fails"
run
{ [[ "${rc}" == 1 ]] && calls "${in_session[@]}"; } \
    || fail "a failed install left Android stopped: ${rc} $(cat "${STATE}/systemctl")"
grep -qF "journalctl -u microos-android-gapps@install.service" "${T}/out" || fail "a failed install: $(cat "${T}/out")"
rm -f "${STATE}/fails"
echo microos-android.service > "${STATE}/active"
run
{ [[ "${rc}" == 0 ]] && calls "${in_session[@]:0:5}"; } \
    || fail "Android started with its session gone: ${rc} $(cat "${STATE}/systemctl")"
grep -q 'next start' "${T}/out" || fail "an install with the session gone: $(cat "${T}/out")"
echo "--user start microos-android.service" > "${STATE}/fails"
printf '%s\n' microos-android.service gamescope-session-plus@android.service > "${STATE}/active"
run
{ [[ "${rc}" == 1 ]] && calls "${in_session[@]}"; } || fail "a failed start of microos-android.service: ${rc}"
grep -qF "start of microos-android.service failed, journalctl --user -u microos-android.service" "${T}/out" \
    || fail "a failed start: $(cat "${T}/out")"
rm -f "${STATE}/fails" "${STATE}/active"

fetch="${data}/libexec/microos/microos-fetch"
mkdir -p "${T}/bin"
cat > "${T}/bin/curl" <<'STUB'
#!/usr/bin/bash
echo "$*" >> "${STATE}/curl"
exit 1
STUB
chmod 0755 "${T}/bin/curl"
echo "zip bytes" > "${T}/cached.zip"
size=$(stat -c %s "${T}/cached.zip")
sum=$(sha256sum < "${T}/cached.zip" | cut -d' ' -f1)
PATH="${T}/bin:${PATH}" "${fetch}" https://example.invalid/cached.zip "${size}" "${sum}" "${T}/cached.zip" \
    > "${T}/out" 2>&1 || fail "microos-fetch refused a cached zip that verifies: $(cat "${T}/out")"
[[ ! -e "${STATE}/curl" ]] || fail "microos-fetch downloaded again a cached zip that verifies"
rc=0
PATH="${T}/bin:${PATH}" "${fetch}" https://example.invalid/cached.zip "$((size + 1))" "${sum}" "${T}/cached.zip" \
    > "${T}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 && -e "${STATE}/curl" ]] || fail "microos-fetch took a cached zip of another size: ${rc}"

pins="${data}/share/microos-android/gapps.env"
[[ "$(cut -d= -f1 "${pins}" | tr '\n' ' ')" == "MTG13_URL MTG13_SIZE MTG13_SHA256 " ]] || fail "pins keys: $(cat "${pins}")"
. "${pins}"
release='MindTheGapps-13\.0\.0-arm64-[0-9_]+'
[[ "${MTG13_URL}" =~ ^https://github\.com/MindTheGapps/13\.0\.0-arm64/releases/download/${release}/${release}\.zip$ ]] \
    || fail "MTG13_URL is not a MindTheGapps 13 arm64 release: ${MTG13_URL}"
[[ "${MTG13_SIZE}" =~ ^[1-9][0-9]+$ && "${MTG13_SHA256}" =~ ^[0-9a-f]{64}$ ]] \
    || fail "MTG13_SIZE or MTG13_SHA256: $(cat "${pins}")"
grep -q 'MTG11\|MTG14\|mtg11' "${cli}" "${root}" && fail "the old MindTheGapps 11 and 14 pins are still named"
grep -qF '"system/"' "${root}" || fail "the root helper does not take the zip's system tree"
grep -qF 'gapps.manifest' "${root}" || fail "the root helper keeps no manifest of its overlay files"

(( failures == 0 )) || { echo "${failures} failure(s)" >&2; exit 1; }
echo "gapps-install-test: pass"
