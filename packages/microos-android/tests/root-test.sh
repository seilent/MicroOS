#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
root="${repo}/data/usr/libexec/microos/microos-android-root"

T=$(mktemp -d)
holder=
cleanup() {
    [[ -z "${holder}" ]] || kill "${holder}" 2>/dev/null || true
    chmod -R u+rwX "${T}" 2>/dev/null || true
    rm -rf "${T:?}"
}
trap cleanup EXIT
failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

command -v python3 > /dev/null || { echo "FAIL: python3 missing" >&2; exit 1; }

export MICROOS_ANDROID_USER
MICROOS_ANDROID_USER=$(id -un)
export MICROOS_ANDROID_HOME="${T}/home"
export MICROOS_ANDROID_IMAGES_LOCK="${T}/images.lock"
export MICROOS_ANDROID_VAR="${T}/var"
export MICROOS_ANDROID_GAPPS_CACHE="${T}/cache"
export MICROOS_WAYDROID_OVERLAY="${T}/overlay"
export MICROOS_ANDROID_GAPPS_PINS="${T}/gapps.env"
export MICROOS_ANDROID_LSFG_DIR="${T}/lsfg"
export MICROOS_FETCH="${T}/bin/fetch"
export MICROOS_LXC_INFO="${T}/bin/lxc-info"
export STATE="${T}/state"
data="${MICROOS_ANDROID_HOME}/.local/share/microos-waydroid/waydroid/data"
mkdir -p "${T}/bin" "${STATE}" "${MICROOS_ANDROID_HOME}" "${MICROOS_ANDROID_VAR}" "${MICROOS_WAYDROID_OVERLAY}"
: > "${MICROOS_ANDROID_IMAGES_LOCK}"
cat > "${T}/bin/lxc-info" <<'FAKE'
#!/usr/bin/bash
echo "$*" >> "${STATE}/lxc"
printf 'State:          %s\n' "$(cat "${STATE}/container" 2>/dev/null || echo STOPPED)"
FAKE
cat > "${T}/bin/fetch" <<'FAKE'
#!/usr/bin/bash
echo "$*" >> "${STATE}/fetch"
[[ ! -e "${STATE}/fetch-fail" ]] || exit 1
cp "${STATE}/zip" "$4"
FAKE
chmod 0755 "${T}/bin/"*

run() {
    rc=0
    "${root}" "$@" > "${T}/out" 2> "${T}/err" || rc=$?
}

db() {
    python3 - "$1" "$2" <<'PY'
import os
import sqlite3
import sys

path, value = sys.argv[1:3]
os.makedirs(os.path.dirname(path), exist_ok=True)
connection = sqlite3.connect(path)
connection.execute("PRAGMA journal_mode=WAL")
connection.execute("CREATE TABLE IF NOT EXISTS main (name TEXT PRIMARY KEY, value TEXT)")
connection.execute("INSERT OR REPLACE INTO main VALUES ('android_id', ?)", (value,))
connection.commit()
PY
}

zip_of() {
    python3 - "$@" <<'PY'
import sys
import zipfile

out = sys.argv[1]
with zipfile.ZipFile(out, "w") as bundle:
    for name in sys.argv[2:]:
        bundle.writestr(name, f"bytes of {name}\n")
PY
}

run nothing
[[ "${rc}" == 2 ]] || fail "an unknown verb exited ${rc}"

run gsf
[[ "${rc}" == 0 && ! -e "${MICROOS_ANDROID_VAR}/gsf-id" ]] || fail "gsf with no database: ${rc} $(cat "${T}/err")"
gsfdb="${data}/data/com.google.android.gsf/databases/gservices.db"
db "${gsfdb}" 1234567890123456789
run gsf
[[ "${rc}" == 0 && "$(cat "${MICROOS_ANDROID_VAR}/gsf-id" 2>/dev/null)" == 1234567890123456789 ]] \
    || fail "gsf read: ${rc} $(cat "${MICROOS_ANDROID_VAR}/gsf-id" 2>/dev/null) $(cat "${T}/err")"
rm -f "${MICROOS_ANDROID_VAR}/gsf-id"
db "${gsfdb}" 0x12
run gsf
[[ "${rc}" == 0 && ! -e "${MICROOS_ANDROID_VAR}/gsf-id" ]] || fail "gsf took a value that is not digits"
mv "${data}/data/com.google.android.gsf/databases" "${T}/databases"
ln -s "${T}/databases" "${data}/data/com.google.android.gsf/databases"
run gsf
[[ "${rc}" == 1 && ! -e "${MICROOS_ANDROID_VAR}/gsf-id" ]] || fail "gsf followed a linked databases dir: ${rc}"
rm "${data}/data/com.google.android.gsf/databases"
mv "${T}/databases" "${data}/data/com.google.android.gsf/databases"

echo RUNNING > "${STATE}/container"
run reset
[[ "${rc}" == 1 && -d "${data}" ]] || fail "reset with the container running: ${rc}"
grep -q "the Waydroid container is running" "${T}/err" || fail "no container refusal: $(cat "${T}/err")"
rm -f "${STATE}/container"
(exec 9< "${MICROOS_ANDROID_IMAGES_LOCK}" && flock -s 9 && exec sleep 600) &
holder=$!
sleep 0.3
run reset
[[ "${rc}" == 1 && -d "${data}" ]] || fail "reset with the session lock held: ${rc}"
grep -q "is held, Android is running" "${T}/err" || fail "no lock refusal: $(cat "${T}/err")"
kill "${holder}"
wait "${holder}" 2>/dev/null || true
holder=
echo 1 > "${MICROOS_ANDROID_VAR}/gsf-id"
mkdir -p "${data}/media/0"
run reset
[[ "${rc}" == 0 && ! -e "${data}" && ! -e "${MICROOS_ANDROID_VAR}/gsf-id" ]] || fail "reset: ${rc} $(cat "${T}/err")"
[[ -d "${MICROOS_ANDROID_HOME}/.local/share/microos-waydroid/waydroid" ]] || fail "reset removed more than the data"
run reset
[[ "${rc}" == 0 ]] || fail "reset with no data: ${rc}"
mkdir -p "${T}/elsewhere/data/keep"
rm -rf "${MICROOS_ANDROID_HOME}/.local/share/microos-waydroid/waydroid"
ln -s "${T}/elsewhere" "${MICROOS_ANDROID_HOME}/.local/share/microos-waydroid/waydroid"
run reset
[[ "${rc}" == 1 && -d "${T}/elsewhere/data/keep" ]] || fail "reset followed a linked waydroid dir: ${rc}"
rm "${MICROOS_ANDROID_HOME}/.local/share/microos-waydroid/waydroid"

mkdir -p "${MICROOS_ANDROID_LSFG_DIR}"
echo layer > "${MICROOS_ANDROID_LSFG_DIR}/libVkLayer_lsfg.so"
echo json > "${MICROOS_ANDROID_LSFG_DIR}/VkLayer_LSFGVK_frame_generation.json"
run layer
vulkan="${data}/local/debug/vulkan"
[[ "${rc}" == 0 ]] || fail "layer: ${rc} $(cat "${T}/err")"
[[ "$(LC_ALL=C ls "${vulkan}" | tr '\n' ' ')" == "VkLayer_LSFGVK_frame_generation.json libVkLayer_lsfg.so " ]] \
    || fail "layer files: $(ls -A "${vulkan}" | tr '\n' ' ')"
[[ "$(stat -c %a "${vulkan}/libVkLayer_lsfg.so")" == 644 && "$(stat -c %a "${vulkan}")" == 755 ]] || fail "layer modes"
[[ "$(stat -c %U "${MICROOS_ANDROID_HOME}/.local/share/microos-waydroid")" == "${MICROOS_ANDROID_USER}" ]] \
    || fail "layer made the data path for another owner"
echo stale > "${vulkan}/old.so"
echo layer2 > "${MICROOS_ANDROID_LSFG_DIR}/libVkLayer_lsfg.so"
run layer
[[ "${rc}" == 0 && ! -e "${vulkan}/old.so" && "$(cat "${vulkan}/libVkLayer_lsfg.so")" == layer2 ]] \
    || fail "layer update: ${rc} $(ls -A "${vulkan}" | tr '\n' ' ')"
mv "${data}/local" "${T}/local"
ln -s "${T}/local" "${data}/local"
run layer
[[ "${rc}" == 1 ]] || fail "layer followed a linked local dir: ${rc}"
rm "${data}/local"

printf 'MTG13_URL=\nMTG13_SIZE=\nMTG13_SHA256=\n' > "${MICROOS_ANDROID_GAPPS_PINS}"
run gapps-install
if [[ "${rc}" != 1 ]] || ! grep -q "pins in ${MICROOS_ANDROID_GAPPS_PINS} are not set" "${T}/err"; then
    fail "gapps-install with empty pins: ${rc} $(cat "${T}/err")"
fi
[[ ! -e "${STATE}/fetch" ]] || fail "gapps-install fetched with empty pins"
run gapps-fetch
if [[ "${rc}" != 1 ]] || ! grep -q "pins in ${MICROOS_ANDROID_GAPPS_PINS} are not set" "${T}/err"; then
    fail "gapps-fetch with empty pins: ${rc} $(cat "${T}/err")"
fi
[[ ! -e "${STATE}/fetch" ]] || fail "gapps-fetch fetched with empty pins"
sha=$(printf '%064d' 0 | tr 0 a)
printf 'MTG13_URL=https://example.invalid/MindTheGapps-13.0.0-arm64.zip\nMTG13_SIZE=10\nMTG13_SHA256=%s\n' "${sha}" \
    > "${MICROOS_ANDROID_GAPPS_PINS}"
zip_of "${STATE}/zip" system/product/priv-app/Phonesky/Phonesky.apk system/system_ext/etc/permissions/a.xml META-INF/x
echo RUNNING > "${STATE}/container"
(exec 9< "${MICROOS_ANDROID_IMAGES_LOCK}" && flock -s 9 && exec sleep 600) &
holder=$!
sleep 0.3
run gapps-fetch
[[ "${rc}" == 0 && -f "${MICROOS_ANDROID_GAPPS_CACHE}/MindTheGapps-13.0.0-arm64.zip" ]] \
    || fail "gapps-fetch with Android running: ${rc} $(cat "${T}/err")"
[[ ! -e "${MICROOS_ANDROID_VAR}/gapps.manifest" && -z "$(ls -A "${MICROOS_WAYDROID_OVERLAY}")" ]] \
    || fail "gapps-fetch wrote into the overlay"
kill "${holder}"
wait "${holder}" 2>/dev/null || true
holder=
rm -f "${STATE}/container"
run gapps-install
[[ "${rc}" == 0 ]] || fail "gapps-install: ${rc} $(cat "${T}/err")"
grep -qxF "https://example.invalid/MindTheGapps-13.0.0-arm64.zip 10 ${sha} ${MICROOS_ANDROID_GAPPS_CACHE}/MindTheGapps-13.0.0-arm64.zip" \
    "${STATE}/fetch" || fail "fetch call: $(cat "${STATE}/fetch")"
apk="${MICROOS_WAYDROID_OVERLAY}/system/product/priv-app/Phonesky/Phonesky.apk"
[[ "$(cat "${apk}")" == "bytes of system/product/priv-app/Phonesky/Phonesky.apk" && "$(stat -c %a "${apk}")" == 644 ]] \
    || fail "the overlay apk"
[[ ! -e "${MICROOS_WAYDROID_OVERLAY}/META-INF" ]] || fail "a file outside system/ reached the overlay"
manifest="${MICROOS_ANDROID_VAR}/gapps.manifest"
[[ "$(cut -d' ' -f2 "${manifest}" | tr '\n' ' ')" == "system/product/priv-app/Phonesky/Phonesky.apk system/system_ext/etc/permissions/a.xml " ]] \
    || fail "manifest: $(cat "${manifest}")"
[[ "$(sed -n 1p "${manifest}" | cut -d' ' -f1)" == "$(sha256sum < "${apk}" | cut -d' ' -f1)" ]] || fail "manifest sha256"
[[ ! -e "${MICROOS_ANDROID_GAPPS_CACHE}/MindTheGapps-13.0.0-arm64.zip" ]] || fail "the zip was kept"
mkdir -p "${MICROOS_WAYDROID_OVERLAY}/system/vendor/lib64/hw"
echo ours > "${MICROOS_WAYDROID_OVERLAY}/system/vendor/lib64/hw/hwcomposer.waydroid.so"
zip_of "${STATE}/zip" system/product/priv-app/Phonesky/Phonesky.apk
run gapps-install
[[ "${rc}" == 0 && ! -e "${MICROOS_WAYDROID_OVERLAY}/system/system_ext" ]] || fail "a dropped file stayed: ${rc}"
[[ -f "${MICROOS_WAYDROID_OVERLAY}/system/vendor/lib64/hw/hwcomposer.waydroid.so" ]] || fail "gapps touched another overlay file"
zip_of "${STATE}/zip" system/../evil
run gapps-install
[[ "${rc}" == 1 && ! -e "${MICROOS_WAYDROID_OVERLAY}/evil" ]] || fail "a dot dot member: ${rc}"
touch "${STATE}/fetch-fail"
run gapps-install
if [[ "${rc}" != 1 ]] || ! grep -q "cannot fetch" "${T}/err"; then fail "a failed fetch: ${rc}"; fi
run gapps-fetch
if [[ "${rc}" != 1 ]] || ! grep -q "cannot fetch" "${T}/err"; then fail "a failed gapps-fetch: ${rc}"; fi
rm -f "${STATE}/fetch-fail"
echo FROZEN > "${STATE}/container"
run gapps-remove
[[ "${rc}" == 1 && -f "${apk}" ]] || fail "gapps-remove with the container frozen: ${rc}"
rm -f "${STATE}/container"
echo 1 > "${MICROOS_ANDROID_VAR}/gsf-id"
run gapps-remove
[[ "${rc}" == 0 && ! -e "${MICROOS_WAYDROID_OVERLAY}/system/product" && ! -e "${manifest}" ]] || fail "gapps-remove: ${rc}"
[[ ! -e "${MICROOS_ANDROID_VAR}/gsf-id" ]] || fail "gapps-remove kept the GSF ID"
[[ -f "${MICROOS_WAYDROID_OVERLAY}/system/vendor/lib64/hw/hwcomposer.waydroid.so" ]] || fail "gapps-remove touched another file"

(( failures == 0 )) || { echo "${failures} failure(s)" >&2; exit 1; }
echo "root-test: pass"
