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
grep -q '=.' "${pins}" && echo "SKIP MindTheGapps 13 pins are set, the unread pin check does not apply"
grep -q 'MTG11\|MTG14\|mtg11' "${cli}" "${root}" && fail "the old MindTheGapps 11 and 14 pins are still named"
grep -qF '"system/"' "${root}" || fail "the root helper does not take the zip's system tree"
grep -qF 'gapps.manifest' "${root}" || fail "the root helper keeps no manifest of its overlay files"

(( failures == 0 )) || { echo "${failures} failure(s)" >&2; exit 1; }
echo "gapps-install-test: pass"
