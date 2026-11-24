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

storage() {
    rc=0
    out=$("${cli}" storage state 2> "${T}/err") || rc=$?
}
storage
if [[ "${rc}" != 1 || -n "${out}" ]] || ! grep -q "not decided" "${T}/err"; then fail "no flag: ${rc} ${out}"; fi
for pair in none=on-internal internal=on-os-card mmcblk0=on-os-card mmcblk12=on-os-card; do
    echo "${pair%%=*}" > "${MICROOS_SYSTEM_CARD}"
    storage
    [[ "${rc}" == 0 && "${out}" == "${pair#*=}" ]] || fail "flag ${pair%%=*}: ${rc} '${out}'"
done
for flag in mmcblk mmcblkx sda1 ""; do
    printf '%s\n' "${flag}" > "${MICROOS_SYSTEM_CARD}"
    storage
    [[ "${rc}" == 1 && -z "${out}" ]] || fail "flag '${flag}': ${rc} '${out}'"
done
echo none > "${T}/flag"
rm -f "${MICROOS_SYSTEM_CARD}"
ln -s "${T}/flag" "${MICROOS_SYSTEM_CARD}"
storage
[[ "${rc}" == 1 ]] || fail "a linked flag was read: ${rc} '${out}'"
for verb in "move card" "move internal" "new --yes" "prune 1 --yes"; do
    rc=0
    "${cli}" storage ${verb} > /dev/null 2>&1 || rc=$?
    [[ "${rc}" == 1 ]] || fail "storage ${verb} exited ${rc}, Waydroid's data stays on /var"
done
[[ ! -e "${STATE}/systemctl" ]] || fail "a storage verb started a unit"

(( failures == 0 )) || { echo "${failures} failure(s)" >&2; exit 1; }
echo "storage-test: pass"
