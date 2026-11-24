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
exit "$(cat "${STATE}/rc" 2>/dev/null || echo 0)"
STUB
chmod 0755 "${T}/systemctl"

[[ "$(sed -n 's/^ExecStart=//p' "${unit}")" == "/usr/bin/microos-android gapps install" ]] || fail "the user unit ExecStart"
grep -qE '^(Nice|IOSchedulingClass|CPUWeight)=' "${unit}" && fail "the user unit sets a priority the root unit owns"
"${cli}" gapps install > "${T}/out" 2>&1 || fail "gapps install: $(cat "${T}/out")"
[[ "$(cat "${STATE}/systemctl")" == "start microos-android-gapps@install.service" ]] \
    || fail "gapps install does not wait on the root unit: $(cat "${STATE}/systemctl")"

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
