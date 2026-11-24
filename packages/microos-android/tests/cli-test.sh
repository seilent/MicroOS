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
export MICROOS_ANDROID_IMAGES="${T}/images"
export MICROOS_ANDROID_IMAGES_STATE="${T}/var/images.state"
export MICROOS_ANDROID_VAR="${T}/var"
export MICROOS_SYSTEM_CARD="${T}/system-card"
export MICROOS_SYSTEMCTL="${T}/systemctl"
mkdir -p "${STATE}" "${HOME}" "${MICROOS_ANDROID_STATE}" "${MICROOS_ANDROID_IMAGES}" "${MICROOS_ANDROID_VAR}"
cat > "${T}/systemctl" <<'STUB'
#!/usr/bin/bash
echo "$*" >> "${STATE}/systemctl"
exit "$(cat "${STATE}/rc" 2>/dev/null || echo 0)"
STUB
chmod 0755 "${T}/systemctl"

field() { sed -n "s/^$1\t//p" <<< "${out}"; }

out=$("${cli}" status)
[[ "$(cut -f1 <<< "${out}" | tr '\n' ' ')" == "last.result last.reason gapps.play gapps.gms image.set image.state gapps.installed gsf_id storage " ]] \
    || fail "status keys: $(cut -f1 <<< "${out}" | tr '\n' ' ')"
[[ "$(field image.set)" == "" && "$(field gapps.installed)" == no && "$(field storage)" == "" ]] || fail "empty status: ${out}"
printf '{"last": {"result": "ready", "reason": ""}, "gapps": {"play": "on", "gms": "on"}}\n' > "${MICROOS_ANDROID_STATE}/state.json"
mkdir -p "${MICROOS_ANDROID_IMAGES}/los20av-20260927-20261022"
ln -s los20av-20260927-20261022 "${MICROOS_ANDROID_IMAGES}/current"
printf 'state=fetching\nset=los20av-20260927-20261022\n' > "${MICROOS_ANDROID_IMAGES_STATE}"
echo "aa system/x" > "${MICROOS_ANDROID_VAR}/gapps.manifest"
echo 1234567890123456789 > "${MICROOS_ANDROID_VAR}/gsf-id"
echo none > "${MICROOS_SYSTEM_CARD}"
out=$("${cli}" status)
for pair in last.result=ready gapps.play=on gapps.gms=on image.set=los20av-20260927-20261022 image.state=fetching \
    gapps.installed=yes gsf_id=1234567890123456789 storage=on-internal; do
    [[ "$(field "${pair%%=*}")" == "${pair#*=}" ]] || fail "status ${pair%%=*}: '$(field "${pair%%=*}")'"
done
echo 0x12 > "${MICROOS_ANDROID_VAR}/gsf-id"
out=$("${cli}" status)
[[ "$(field gsf_id)" == "" ]] || fail "status took a GSF ID that is not digits"

"${cli}" gapps install > "${T}/out" 2>&1 || fail "gapps install: $(cat "${T}/out")"
grep -qx 'start microos-android-gapps@install.service' "${STATE}/systemctl" || fail "gapps install unit: $(cat "${STATE}/systemctl")"
grep -q 'next start' "${T}/out" || fail "gapps install says nothing about the restart"
echo 1 > "${STATE}/rc"
rc=0
"${cli}" gapps install > "${T}/out" 2>&1 || rc=$?
if [[ "${rc}" != 1 ]] || ! grep -qF "journalctl -u microos-android-gapps@install.service" "${T}/out"; then
    fail "a failed gapps install: ${rc} $(cat "${T}/out")"
fi
rm -f "${STATE}/rc" "${STATE}/systemctl"
rc=0
"${cli}" gapps remove > "${T}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 && ! -e "${STATE}/systemctl" ]] || fail "gapps remove without --yes: ${rc}"
"${cli}" gapps remove --yes > "${T}/out" 2>&1 || fail "gapps remove --yes: $(cat "${T}/out")"
grep -qx 'start microos-android-gapps@remove.service' "${STATE}/systemctl" || fail "gapps remove unit"

for args in "" "nothing" "gapps" "gapps setup" "prune" "storage move card" "status extra" "gapps install now"; do
    rc=0
    "${cli}" ${args} > /dev/null 2>&1 || rc=$?
    [[ "${rc}" == 1 ]] || fail "'${args}' exited ${rc}"
done
[[ "$(grep -c -e podman -e lepton "${cli}")" == 0 ]] || fail "the CLI names podman or Lepton"

(( failures == 0 )) || { echo "${failures} failure(s)" >&2; exit 1; }
echo "cli-test: pass"
