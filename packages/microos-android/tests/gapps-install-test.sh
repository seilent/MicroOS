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
export MICROOS_ANDROID_STATE="${T}/android-state"
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
out= url= resume=0
while (( $# )); do
    case "$1" in
        -o) out=$2; shift ;;
        -C) resume=1; shift ;;
        https://*) url=$1 ;;
    esac
    shift
done
[[ -e "${STATE}/curl_fail" ]] && exit 22
[[ ! -e "${STATE}/unit_during" ]] || cp "${STATE}/unit_during" "${STATE}/unit"
case "${url}" in
    *11.0.0*) src=${T_ZIP11} ;;
    *14.0.0*) src=${T_ZIP14} ;;
esac
offset=0
if (( resume )) && [[ -f "${out}" ]]; then
    offset=$(stat -c %s "${out}")
else
    : > "${out}"
fi
if [[ -e "${STATE}/curl_cut" ]]; then
    tail -c +$((offset + 1)) "${src}" | head -c 100 >> "${out}"
    exit 18
fi
(( ! offset )) || [[ ! -e "${STATE}/curl_norange" ]] || exit 33
tail -c +$((offset + 1)) "${src}" >> "${out}"
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
    rm -rf "${STATE}" "${MICROOS_GAPPS}" "${MICROOS_GAPPS_CACHE}" "${MICROOS_ANDROID_ROMS:-${T}/roms}" "${MICROOS_ANDROID_STATE}"
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

activate="${MICROOS_ANDROID_STATE}/activate"

reset
run
[[ "${rc}" == 0 ]] || fail "install exit ${rc}: $(cat "${STATE}/out")"
[[ "$(cat "${activate}" 2>/dev/null)" == mtg11-20230922.vending-36.6.25 ]] || fail "no activation request: $(cat "${activate}" 2>/dev/null)"
[[ ! -e "${MICROOS_GAPPS}/current" ]] || fail "the install flipped current"
[[ "$(head -n 1 "${set_dir}/STAMP")" == "set=mtg11-20230922.vending-36.6.25" ]] || fail "STAMP header"
[[ "$(grep -c . "${set_dir}/STAMP")" == 4 ]] || fail "STAMP lines: $(cat "${set_dir}/STAMP")"
grep -qx "$(sha "${set_dir}/system/product/priv-app/Phonesky/Phonesky.apk") 9 system/product/priv-app/Phonesky/Phonesky.apk" "${set_dir}/STAMP" \
    || fail "STAMP Phonesky line: $(cat "${set_dir}/STAMP")"
grep -q 'name="new"' "${set_dir}/system/product/etc/permissions/privapp-permissions-google-p.xml" || fail "vending block not merged"
grep -q 'com.google.android.gms' "${set_dir}/system/product/etc/permissions/privapp-permissions-google-p.xml" || fail "merge lost other blocks"
[[ ! -w "${set_dir}/system/product/priv-app/Phonesky/Phonesky.apk" && ! -w "${set_dir}" ]] || fail "set is writable"
[[ ! -e "${MICROOS_GAPPS}/mtg11-20230922.vending-36.6.25.tmp" ]] || fail ".tmp left"
[[ -z "$(ls -A "${MICROOS_GAPPS_CACHE}")" ]] || fail "zips not deleted: $(ls -A "${MICROOS_GAPPS_CACHE}")"
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

staged() {
    [[ "$(head -n 1 "${set_dir}/STAMP" 2>/dev/null)" == "set=mtg11-20230922.vending-36.6.25" ]]
}
requested() {
    [[ "${rc}" == 0 ]] || { fail "$1: exit ${rc}: $(cat "${STATE}/out")"; return; }
    [[ "$(tail -n 1 "${STATE}/out")" == "microos-android gapps install: $2" ]] || fail "$1: printed: $(cat "${STATE}/out")"
    staged || fail "$1: the set is not staged"
    [[ "$(cat "${activate}" 2>/dev/null)" == mtg11-20230922.vending-36.6.25 ]] || fail "$1: the request: $(cat "${activate}" 2>/dev/null)"
    [[ ! -e "${activate}.new" ]] || fail "$1: the request temp file was left"
    [[ ! -e "${MICROOS_GAPPS}/current" ]] || fail "$1: the install flipped current"
}

reset
run
requested "nothing live" "the next Android start binds mtg11-20230922.vending-36.6.25"
[[ "$(stat -c %a "${MICROOS_ANDROID_STATE}")" == 700 ]] || fail "the state dir is $(stat -c %a "${MICROOS_ANDROID_STATE}")"
reset
echo active > "${STATE}/unit"
run
requested "unit running" "Android restarts with mtg11-20230922.vending-36.6.25"
reset
echo activating > "${STATE}/prepare_unit"
run
requested "prepare running" "Android restarts with mtg11-20230922.vending-36.6.25"
reset
echo 0 > "${STATE}/exists_rc"
run
requested "a container left from an ended session" "the next Android start binds mtg11-20230922.vending-36.6.25"
reset
echo lepton-steam-2357 > "${STATE}/leptons"
run
requested "another Lepton container" "the next Android start binds mtg11-20230922.vending-36.6.25"
reset
echo active > "${STATE}/unit_during"
run
requested "Android started during the download" "Android restarts with mtg11-20230922.vending-36.6.25"
[[ ! -s "${STATE}/podman" ]] || fail "the install called podman: $(cat "${STATE}/podman")"

reset
run
ln -s mtg11-20230922.vending-36.6.25 "${MICROOS_GAPPS}/current"
rm -f "${activate}"
echo active > "${STATE}/unit"
run
[[ "${rc}" == 0 ]] && grep -qx "microos-android gapps install: mtg11-20230922.vending-36.6.25 is already the current set" "${STATE}/out" \
    || fail "the current set with Android live: exit ${rc}: $(cat "${STATE}/out")"
[[ ! -e "${activate}" ]] || fail "the current set with Android live: a request was written"

reset
mkdir -p "${MICROOS_GAPPS}"
exec {held}> "${MICROOS_GAPPS}/.install.lock"
flock -n "${held}"
run
exec {held}>&-
[[ "${rc}" == 1 ]] && grep -qx "microos-android gapps install: another gapps install holds ${MICROOS_GAPPS}/.install.lock, refusing" "${STATE}/out" \
    || fail "a held install lock: exit ${rc}: $(cat "${STATE}/out")"
[[ ! -s "${STATE}/curl" && ! -e "${activate}" ]] || fail "a held install lock: downloaded or requested"
run
requested "the lock released" "the next Android start binds mtg11-20230922.vending-36.6.25"

zip11_part="${MICROOS_GAPPS_CACHE}/MindTheGapps-11.0.0-arm64-20230922_081122.zip.part"
reset
: > "${STATE}/curl_cut"
run
[[ "${rc}" == 1 ]] && grep -q "download failed" "${STATE}/out" || fail "a cut download: exit ${rc}: $(cat "${STATE}/out")"
[[ "$(stat -c %s "${zip11_part}" 2>/dev/null)" == 100 ]] || fail "a cut download: the part is $(stat -c %s "${zip11_part}" 2>&1)"
rm -f "${STATE}/curl_cut"
: > "${STATE}/curl"
run
requested "a resumed download" "the next Android start binds mtg11-20230922.vending-36.6.25"
grep -q -- "-C - -o ${zip11_part} " "${STATE}/curl" || fail "a resumed download: curl ran $(cat "${STATE}/curl")"
reset
: > "${STATE}/curl_cut"
run
rm -f "${STATE}/curl_cut"
: > "${STATE}/curl_norange"
run
[[ "${rc}" == 1 ]] && grep -qx "microos-fetch: MindTheGapps-11.0.0-arm64-20230922_081122.zip: the server refuses to resume, the next try starts over" "${STATE}/out" \
    || fail "a server that refuses ranges: exit ${rc}: $(cat "${STATE}/out")"
[[ ! -e "${zip11_part}" ]] || fail "a server that refuses ranges: the part was kept"
run
requested "the try after a refused resume" "the next Android start binds mtg11-20230922.vending-36.6.25"
reset
mkdir -p "${MICROOS_GAPPS_CACHE}"
head -c "$((MICROOS_GAPPS_MTG11_SIZE + 10))" /dev/zero > "${zip11_part}"
run
requested "a part longer than the file" "the next Android start binds mtg11-20230922.vending-36.6.25"
reset
mkdir -p "${MICROOS_GAPPS_CACHE}"
cp "${T_ZIP11}" "${zip11_part}"
run
requested "a complete part" "the next Android start binds mtg11-20230922.vending-36.6.25"
grep -q "11.0.0" "${STATE}/curl" && fail "a complete part was downloaded again: $(cat "${STATE}/curl")"

reset
MICROOS_TEST='' run
[[ "${rc}" == 1 ]] || fail "overrides without MICROOS_TEST: exit ${rc}"
grep -q "size differs from 194494611" "${STATE}/out" || fail "overrides honored without MICROOS_TEST: $(cat "${STATE}/out")"

if (( failures )); then
    echo "gapps-install-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "gapps-install-test: ok"
