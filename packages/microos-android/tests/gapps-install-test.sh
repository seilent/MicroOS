#!/usr/bin/bash
set -eu

export MICROOS_TEST=1

export PYTHONDONTWRITEBYTECODE=1

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
install_cmd="${repo}/data/usr/bin/microos-android"

T=$(mktemp -d)
trap 'chmod -R u+w "${T}" 2>/dev/null; rm -rf "${T}"' EXIT
mkdir -p "${T}/bin" "${T}/zip11/system/product/etc/permissions" "${T}/zip14/system/product/etc/permissions" \
    "${T}/zip11/system/system_ext/priv-app/GoogleServicesFramework" "${T}/zip14/system/product/priv-app/Phonesky"
export STATE="${T}/state"
export MICROOS_GAPPS="${T}/gapps"
export MICROOS_GAPPS_CACHE="${T}/cache"
export HOME="${T}/home"
export MICROOS_HOME="${T}/home"
mkdir -p "${HOME}"
export MICROOS_FETCH="${repo}/data/usr/libexec/microos/microos-fetch"
set_dir="${MICROOS_GAPPS}/mtg11-20230922.vending-36.6.25"

echo gsf > "${T}/zip11/system/system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk"
echo phonesky > "${T}/zip14/system/product/priv-app/Phonesky/Phonesky.apk"
cat > "${T}/zip11/system/product/etc/permissions/privapp-permissions-google-p.xml" <<'XML'
<permissions>
    <privapp-permissions package="com.google.android.gms">
        <permission name="a"/>
    </privapp-permissions>
    <privapp-permissions package="com.android.vending">
        <permission name="old"/>
    </privapp-permissions>
</permissions>
XML
cat > "${T}/zip14/system/product/etc/permissions/privapp-permissions-google-product.xml" <<'XML'
<permissions>
    <privapp-permissions package="com.android.vending">
        <permission name="old"/>
        <permission name="new"/>
    </privapp-permissions>
</permissions>
XML
(cd "${T}/zip11" && zip -q -r ../mtg11.zip system)
(cd "${T}/zip14" && zip -q -r ../mtg14.zip system)
sha() { sha256sum "$1" | cut -d' ' -f1; }
merged_sha=$(python3 - "${T}" <<'PY'
import hashlib, sys
t = sys.argv[1]
base = open(t + "/zip11/system/product/etc/permissions/privapp-permissions-google-p.xml").read()
donor = open(t + "/zip14/system/product/etc/permissions/privapp-permissions-google-product.xml").read()
start, end = base.index('    <privapp-permissions package="com.android.vending">'), base.index("</permissions>")
dstart, dend = donor.index('    <privapp-permissions package="com.android.vending">'), donor.index("</permissions>")
print(hashlib.sha256((base[:start] + donor[dstart:dend] + base[end:]).encode()).hexdigest())
PY
)
export MICROOS_GAPPS_MTG11_SIZE MICROOS_GAPPS_MTG11_SHA MICROOS_GAPPS_MTG14_SIZE MICROOS_GAPPS_MTG14_SHA
MICROOS_GAPPS_MTG11_SIZE=$(stat -c %s "${T}/mtg11.zip")
MICROOS_GAPPS_MTG11_SHA=$(sha "${T}/mtg11.zip")
MICROOS_GAPPS_MTG14_SIZE=$(stat -c %s "${T}/mtg14.zip")
MICROOS_GAPPS_MTG14_SHA=$(sha "${T}/mtg14.zip")
export MICROOS_GAPPS_DONOR_SHA MICROOS_GAPPS_MERGED_SOURCE_SHA MICROOS_GAPPS_FILES
MICROOS_GAPPS_DONOR_SHA=$(sha "${T}/zip14/system/product/etc/permissions/privapp-permissions-google-product.xml")
MICROOS_GAPPS_MERGED_SOURCE_SHA=$(sha "${T}/zip11/system/product/etc/permissions/privapp-permissions-google-p.xml")
MICROOS_GAPPS_FILES="
11 system/system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk $(sha "${T}/zip11/system/system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk")
14 system/product/priv-app/Phonesky/Phonesky.apk $(sha "${T}/zip14/system/product/priv-app/Phonesky/Phonesky.apk")
merged system/product/etc/permissions/privapp-permissions-google-p.xml ${merged_sha}
"

cat > "${T}/bin/curl" <<'STUB'
#!/usr/bin/bash
echo "curl $*" >> "${STATE}/curl"
out= url=
while (( $# )); do
    case "$1" in
        -o) out=$2; shift ;;
        https://*) url=$1 ;;
    esac
    shift
done
[[ -e "${STATE}/curl_fail" ]] && exit 22
case "${url}" in
    *11.0.0*) cp "${T_ZIP11}" "${out}" ;;
    *14.0.0*) cp "${T_ZIP14}" "${out}" ;;
esac
[[ ! -e "${STATE}/corrupt" ]] || echo x >> "${out}"
STUB
cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
case "$*" in
    *ActiveState*microos-lepton-prepare*) cat "${STATE}/prepare_unit" ;;
    *) cat "${STATE}/unit" ;;
esac
STUB
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
echo "podman $*" >> "${STATE}/podman"
case "$*" in
    "ps -a --filter label=lepton=true --format {{.Names}}") [[ ! -e "${STATE}/ps_fail" ]] || exit 125; cat "${STATE}/leptons" 2>/dev/null; exit 0 ;;
    *) exit "$(cat "${STATE}/exists_rc")" ;;
esac
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"
export T_ZIP11="${T}/mtg11.zip" T_ZIP14="${T}/mtg14.zip"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    [[ ! -d "${MICROOS_GAPPS}" ]] || chmod -R u+w "${MICROOS_GAPPS}"
    rm -rf "${STATE}" "${MICROOS_GAPPS}" "${MICROOS_GAPPS_CACHE}" "${MICROOS_ANDROID_ROMS:-${T}/roms}"
    mkdir -p "${STATE}"
    : > "${STATE}/curl"
    echo inactive > "${STATE}/unit"
    echo inactive > "${STATE}/prepare_unit"
    echo 1 > "${STATE}/exists_rc"
}

run() {
    rc=0
    "${install_cmd}" gapps install > "${STATE}/out" 2>&1 || rc=$?
}

reset
run
[[ "${rc}" == 0 ]] || fail "install exit ${rc}: $(cat "${STATE}/out")"
[[ "$(readlink "${MICROOS_GAPPS}/current")" == mtg11-20230922.vending-36.6.25 ]] || fail "current not switched"
[[ "$(head -n 1 "${set_dir}/STAMP")" == "set=mtg11-20230922.vending-36.6.25" ]] || fail "STAMP header"
[[ "$(grep -c . "${set_dir}/STAMP")" == 4 ]] || fail "STAMP lines: $(cat "${set_dir}/STAMP")"
grep -qx "$(sha "${set_dir}/system/product/priv-app/Phonesky/Phonesky.apk") 9 system/product/priv-app/Phonesky/Phonesky.apk" "${set_dir}/STAMP" \
    || fail "STAMP Phonesky line: $(cat "${set_dir}/STAMP")"
grep -q 'name="new"' "${set_dir}/system/product/etc/permissions/privapp-permissions-google-p.xml" || fail "vending block not merged"
grep -q 'com.google.android.gms' "${set_dir}/system/product/etc/permissions/privapp-permissions-google-p.xml" || fail "merge lost other blocks"
[[ ! -w "${set_dir}/system/product/priv-app/Phonesky/Phonesky.apk" && ! -w "${set_dir}" ]] || fail "set is writable"
[[ ! -e "${MICROOS_GAPPS}/mtg11-20230922.vending-36.6.25.tmp" ]] || fail ".tmp left"
[[ -z "$(ls -A "${MICROOS_GAPPS_CACHE}")" ]] || fail "zips not deleted: $(ls -A "${MICROOS_GAPPS_CACHE}")"
[[ "$(readlink "${MICROOS_GAPPS}/current")" == mtg11-20230922.vending-36.6.25 ]] || fail "current not switched"
[[ "$(grep -c -- '--proto =https --proto-redir =https' "${STATE}/curl")" == 2 ]] || fail "curl not https only: $(cat "${STATE}/curl")"
stamp_mtime=$(stat -c %Y "${set_dir}/STAMP")
newest=$(find "${set_dir}" -type f -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2)
[[ "${newest}" == "${set_dir}/STAMP" ]] || fail "STAMP is not the last file written: ${newest}"

: > "${STATE}/curl"
run
[[ "${rc}" == 0 ]] || fail "rerun exit ${rc}"
[[ ! -s "${STATE}/curl" ]] || fail "rerun downloaded again"
grep -q "already installed" "${STATE}/out" || fail "rerun message"
: > "${STATE}/curl"
[[ "$(stat -c %Y "${set_dir}/STAMP")" == "${stamp_mtime}" ]] || fail "rerun rewrote the set"

reset
mkdir -p "${MICROOS_GAPPS}/mtg11-20230922.vending-36.6.25.tmp/system"
echo partial > "${MICROOS_GAPPS}/mtg11-20230922.vending-36.6.25.tmp/system/half.apk"
chmod -R a-w "${MICROOS_GAPPS}/mtg11-20230922.vending-36.6.25.tmp"
run
[[ "${rc}" == 0 ]] || fail "interrupted rerun exit ${rc}: $(cat "${STATE}/out")"
[[ ! -e "${set_dir}/system/half.apk" ]] || fail "interrupted .tmp content carried over"

reset
: > "${STATE}/corrupt"
run
[[ "${rc}" == 1 ]] || fail "corrupt zip exit ${rc}"
grep -q "size differs" "${STATE}/out" || fail "corrupt zip message: $(cat "${STATE}/out")"
[[ ! -e "${MICROOS_GAPPS}/current" && -z "$(ls -A "${MICROOS_GAPPS_CACHE}")" ]] || fail "corrupt zip left state"

reset
MICROOS_GAPPS_MTG11_SHA=0000000000000000000000000000000000000000000000000000000000000000 run
[[ "${rc}" == 1 ]] && grep -q "sha256 mismatch" "${STATE}/out" || fail "bad zip sha: exit ${rc}: $(cat "${STATE}/out")"

reset
MICROOS_GAPPS_FILES="${MICROOS_GAPPS_FILES/$(sha "${T}/zip14/system/product/priv-app/Phonesky/Phonesky.apk")/1111111111111111111111111111111111111111111111111111111111111111}" run
[[ "${rc}" == 1 ]] && grep -q "Phonesky.apk from MindTheGapps-14.0.0-arm64-20250203_200051.zip: sha256 mismatch" "${STATE}/out" || fail "bad file sha: exit ${rc}: $(cat "${STATE}/out")"
[[ ! -e "${MICROOS_GAPPS}/current" && ! -e "${set_dir}" ]] || fail "bad file sha installed something"

reset
: > "${STATE}/curl_fail"
run
[[ "${rc}" == 1 ]] && grep -q "download failed" "${STATE}/out" || fail "download failure: exit ${rc}"

reset
echo active > "${STATE}/unit"
run
[[ "${rc}" == 1 ]] && grep -q "running, refusing" "${STATE}/out" || fail "unit running: exit ${rc}"
reset
echo activating > "${STATE}/prepare_unit"
run
[[ "${rc}" == 1 ]] && grep -q "microos-lepton-prepare.service is running, refusing" "${STATE}/out" || fail "prepare running: exit ${rc}"
reset
echo 0 > "${STATE}/exists_rc"
run
[[ "${rc}" == 1 ]] && grep -q "exists, refusing" "${STATE}/out" || fail "container present: exit ${rc}"
[[ ! -s "${STATE}/curl" ]] || fail "downloaded with the container present"
reset
: > "${STATE}/ps_fail"
run
[[ "${rc}" == 1 ]] && grep -qx "microos-android gapps install: podman ps failed, refusing" "${STATE}/out" || fail "podman ps error: exit ${rc}"
[[ ! -s "${STATE}/curl" ]] || fail "podman ps error: downloaded"

reset
MICROOS_TEST='' run
[[ "${rc}" == 1 ]] || fail "overrides without MICROOS_TEST: exit ${rc}"
grep -q "size differs from 194494611" "${STATE}/out" || fail "overrides honored without MICROOS_TEST: $(cat "${STATE}/out")"

if (( failures )); then
    echo "gapps-install-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "gapps-install-test: ok"
