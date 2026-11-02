#!/usr/bin/bash
set -eu

export MICROOS_TEST=1

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
stub="${repo}/build/stub.sh"
src="${repo}/restrictions-stub"
rc_file="${src}/restrictions-stub.rc"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin" "${T}/src/android-11"
export STATE="${T}/state"

echo jar > "${T}/src/android-11/android.jar"
(cd "${T}/src" && zip -q -r platform.zip android-11)
echo r8 > "${T}/src/r8.jar"
export MICROOS_STUB_PLATFORM_URL="file://${T}/src/platform.zip"
MICROOS_STUB_PLATFORM_SHA=$(sha256sum "${T}/src/platform.zip" | cut -d' ' -f1)
export MICROOS_STUB_PLATFORM_SHA
export MICROOS_STUB_R8_URL="file://${T}/src/r8.jar"
MICROOS_STUB_R8_SHA=$(sha256sum "${T}/src/r8.jar" | cut -d' ' -f1)
export MICROOS_STUB_R8_SHA

cat > "${T}/bin/javac" <<'STUB'
#!/usr/bin/bash
echo "javac $*" >> "${STATE}/calls"
while (( $# )); do
    [[ "$1" == -d ]] && { mkdir -p "$2"; echo class > "$2/RestrictionsStub.class"; }
    shift
done
STUB
cat > "${T}/bin/java" <<'STUB'
#!/usr/bin/bash
echo "java $*" >> "${STATE}/calls"
while (( $# )); do
    if [[ "$1" == --output ]]; then
        dir=$(mktemp -d)
        printf 'dex\n%s\n' "$(cat "${STATE}/dex")" > "${dir}/classes.dex"
        [[ ! -e "${STATE}/extra" ]] || echo x > "${dir}/extra.txt"
        (cd "${dir}" && zip -q "$2" ./*)
        rm -rf "${dir}"
    fi
    shift
done
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}" "${T}/cache" "${T}/dist"
    mkdir -p "${STATE}"
    : > "${STATE}/calls"
    echo "LRestrictionsStub;" > "${STATE}/dex"
}

run() {
    rc=0
    out=$(bash "${stub}" "${T}/cache" "${T}/dist" "${src}" 2> "${T}/err") || rc=$?
    err=$(cat "${T}/err")
}

dest="${T}/dist/usr/share/microos-android"

reset
run
[[ "${rc}" == 0 ]] || fail "build exit ${rc}: ${err}"
[[ -f "${dest}/restrictions-stub.jar" && -f "${dest}/restrictions-stub.rc" ]] || fail "jar or rc not installed"
[[ "${out}" == *"STUB_SHA256=$(sha256sum "${dest}/restrictions-stub.jar" | cut -d' ' -f1)"* ]] || fail "no jar sha line: ${out}"
[[ "${out}" == *"STUB_RC_SHA256="* ]] || fail "no rc sha line"
grep -q -- "--release 11" "${STATE}/calls" || fail "javac not run with --release 11"
grep -q -- "com.android.tools.r8.D8 --release --min-api 30" "${STATE}/calls" || fail "d8 not run for api 30"
[[ -z "$(find "${T}/dist" -maxdepth 1 -name '.stub.*')" ]] || fail "work directory left"

reset
MICROOS_STUB_R8_SHA=0000000000000000000000000000000000000000000000000000000000000000 run
[[ "${rc}" == 1 && "${err}" == *"sha256 mismatch for r8-8.5.35.jar"* ]] || fail "bad r8 sha: exit ${rc}: ${err}"
[[ ! -e "${dest}/restrictions-stub.jar" ]] || fail "jar installed after a bad sha"
grep -q javac "${STATE}/calls" && fail "compiled after a bad sha"

reset
MICROOS_STUB_PLATFORM_SHA=0000000000000000000000000000000000000000000000000000000000000000 run
[[ "${rc}" == 1 && "${err}" == *"sha256 mismatch for platform-30_r03.zip"* ]] || fail "bad platform sha: exit ${rc}: ${err}"

reset
: > "${STATE}/extra"
run
[[ "${rc}" == 1 && "${err}" == *"expected one classes.dex"* ]] || fail "extra jar entry: exit ${rc}: ${err}"
[[ ! -e "${dest}/restrictions-stub.jar" ]] || fail "jar with an extra entry installed"

reset
echo "LOther;" > "${STATE}/dex"
run
[[ "${rc}" == 1 && "${err}" == *"does not name RestrictionsStub"* ]] || fail "dex without the class: exit ${rc}: ${err}"

reset
cat > "${T}/bin/curl" <<'STUB'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${STATE}/curl"
exit 22
STUB
chmod 0755 "${T}/bin/curl"
MICROOS_TEST='' run
rm -f "${T}/bin/curl"
[[ "${rc}" == 1 ]] || fail "overrides without MICROOS_TEST: exit ${rc}"
grep -q "https://dl.google.com/android/repository/platform-30_r03.zip" "${STATE}/curl" || fail "overrides honored without MICROOS_TEST: $(cat "${STATE}/curl")"

grep -q '/system/framework/restrictions-stub.jar' "${rc_file}" || fail "rc does not name the jar path"
grep -qx 'service microos_restrictions_stub /system/bin/app_process -Djava.class.path=/system/framework/restrictions-stub.jar /system/bin RestrictionsStub' "${rc_file}" \
    || fail "rc service line"
grep -q '#' "${rc_file}" && fail "rc carries a comment"
grep -qE '//|/\*' "${src}/RestrictionsStub.java" && fail "java source carries a comment"

if (( failures )); then
    echo "stub-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "stub-test: ok"
