#!/usr/bin/bash
set -euo pipefail

PLATFORM_ZIP=platform-30_r03.zip
PLATFORM_URL="https://dl.google.com/android/repository/${PLATFORM_ZIP}"
PLATFORM_SHA=f3f5b75744dbf6ee6ed3e8174a71e513bfee502d0bc3463ea97e517bff68d84e
R8_VERSION=8.5.35
R8_URL="https://dl.google.com/android/maven2/com/android/tools/r8/${R8_VERSION}/r8-${R8_VERSION}.jar"
R8_SHA=4733945987ee0a840fafc34080b135259e01678412e07212b23f706334290294
API=30

if [[ "${MICROOS_TEST:-}" == 1 ]]; then
    PLATFORM_URL="${MICROOS_STUB_PLATFORM_URL:-${PLATFORM_URL}}"
    PLATFORM_SHA="${MICROOS_STUB_PLATFORM_SHA:-${PLATFORM_SHA}}"
    R8_URL="${MICROOS_STUB_R8_URL:-${R8_URL}}"
    R8_SHA="${MICROOS_STUB_R8_SHA:-${R8_SHA}}"
fi

cache=$1
dist=$2
src=$3
dest="${dist}/usr/share/microos-android"

fail() { echo "stub.sh: $*" >&2; exit 1; }

fetch() {
    local url=$1 sha=$2 file=$3
    if echo "${sha}  ${file}" | sha256sum -c --status 2>/dev/null; then
        return 0
    fi
    curl -fsSL --retry 3 --connect-timeout 30 -o "${file}.part" "${url}" || { rm -f "${file}.part"; fail "download failed: ${url}"; }
    echo "${sha}  ${file}.part" | sha256sum -c --status || { rm -f "${file}.part"; fail "sha256 mismatch for $(basename "${file}")"; }
    mv "${file}.part" "${file}"
}

[[ -f "${src}/RestrictionsStub.java" && -f "${src}/restrictions-stub.rc" ]] || fail "stub source missing in ${src}"
mkdir -p "${cache}" "${dist}"
fetch "${PLATFORM_URL}" "${PLATFORM_SHA}" "${cache}/${PLATFORM_ZIP}"
fetch "${R8_URL}" "${R8_SHA}" "${cache}/r8-${R8_VERSION}.jar"

work=$(mktemp -d "${dist}/.stub.XXXXXX")
trap 'rm -rf "${work}"' EXIT

unzip -q -j -d "${work}" "${cache}/${PLATFORM_ZIP}" '*/android.jar' || fail "android.jar missing in ${PLATFORM_ZIP}"
javac --release 11 -cp "${work}/android.jar" -d "${work}/classes" "${src}/RestrictionsStub.java" || fail "javac failed"
java -cp "${cache}/r8-${R8_VERSION}.jar" com.android.tools.r8.D8 --release --min-api "${API}" \
    --lib "${work}/android.jar" --output "${work}/restrictions-stub.jar" "${work}"/classes/*.class || fail "d8 failed"

entries=$(unzip -Z1 "${work}/restrictions-stub.jar")
[[ "${entries}" == classes.dex ]] || fail "the stub jar holds ${entries//$'\n'/ }, expected one classes.dex"
unzip -p "${work}/restrictions-stub.jar" classes.dex | grep -qa RestrictionsStub || fail "classes.dex does not name RestrictionsStub"

mkdir -p "${dest}"
install -m 0644 "${work}/restrictions-stub.jar" "${dest}/restrictions-stub.jar"
install -m 0644 "${src}/restrictions-stub.rc" "${dest}/restrictions-stub.rc"

echo "STUB_SHA256=$(sha256sum "${dest}/restrictions-stub.jar" | cut -d' ' -f1)"
echo "STUB_RC_SHA256=$(sha256sum "${dest}/restrictions-stub.rc" | cut -d' ' -f1)"
