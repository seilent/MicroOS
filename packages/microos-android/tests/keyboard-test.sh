#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
script="${repo}/data/usr/libexec/microos/microos-android-keyboard"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
export XDG_CACHE_HOME="${T}/cache"
export MICROOS_FETCH="${repo}/data/usr/libexec/microos/microos-fetch"
export MICROOS_KEYBOARD_POLL_S=0.01
apk="${T}/apk"
printf 'simple keyboard %s\n' 149 > "${apk}"
size=$(stat -c %s "${apk}")
sha=$(sha256sum "${apk}" | cut -d' ' -f1)
export MICROOS_TEST=1
export MICROOS_KEYBOARD_SIZE="${size}"
export MICROOS_KEYBOARD_SHA="${sha}"
cached="${XDG_CACHE_HOME}/microos-android/keyboard/rkr.simplekeyboard.inputmethod_149.apk"
component=rkr.simplekeyboard.inputmethod/.latin.LatinIME

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
[[ ! -e "${STATE}/curl_fail" ]] || exit 22
cp "${T_APK}" "${out}"
[[ ! -e "${STATE}/corrupt" ]] || echo x >> "${out}"
STUB
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
echo "podman $*" >> "${STATE}/podman"
[[ "${1:-}" == exec ]] || exit 99
name=$2
n=2
if [[ "${2:-}" == -i ]]; then
    name=$3
    n=3
fi
echo "exec ${name}" >> "${STATE}/container"
shift "${n}"
case "$*" in
    "/system/bin/cmd package list packages --show-versioncode")
        [[ ! -e "${STATE}/probe_fail" ]] || exit 1
        if [[ -f "${STATE}/second_read_fail" ]] && (( $(cat "${STATE}/list_calls" 2>/dev/null || echo 0) >= 1 )); then
            echo "$(( $(cat "${STATE}/list_calls") + 1 ))" > "${STATE}/list_calls"
            exit 1
        fi
        echo "$(( $(cat "${STATE}/list_calls" 2>/dev/null || echo 0) + 1 ))" > "${STATE}/list_calls"
        if [[ -f "${STATE}/late_packages" ]]; then
            reads=$(( $(cat "${STATE}/late_count" 2>/dev/null || echo 0) + 1 ))
            echo "${reads}" > "${STATE}/late_count"
            if (( reads >= $(cat "${STATE}/late_packages") )); then
                cat "${STATE}/packages"
            fi
            exit 0
        fi
        cat "${STATE}/packages"
        ;;
    "/system/bin/ime list -s")
        [[ ! -e "${STATE}/probe_fail" ]] || exit 1
        cat "${STATE}/ime_short"
        ;;
    "/system/bin/ime list -a")
        [[ ! -e "${STATE}/probe_fail" ]] || exit 1
        if [[ -f "${STATE}/ime_all_delay" ]]; then
            delay=$(cat "${STATE}/ime_all_delay")
            if (( delay > 0 )); then
                echo $(( delay - 1 )) > "${STATE}/ime_all_delay"
                cat "${STATE}/ime_all_before" 2>/dev/null
                exit 0
            fi
        fi
        cat "${STATE}/ime_all"
        ;;
    "/system/bin/settings get secure default_input_method") cat "${STATE}/default" ;;
    "/system/bin/cmd package install -r -S "*)
        cat > "${STATE}/stdin.raw"
        sha256sum < "${STATE}/stdin.raw" | cut -d' ' -f1 >> "${STATE}/stdin"
        echo "package:rkr.simplekeyboard.inputmethod versionCode:149" >> "${STATE}/packages"
        echo "  rkr.simplekeyboard.inputmethod/.latin.LatinIME:" >> "${STATE}/ime_all"
        cat "${STATE}/install_out"
        ;;
    "/system/bin/ime enable "*)
        [[ ! -e "${STATE}/enable_fail" ]] || exit 1
        echo "${3}" >> "${STATE}/ime_short"
        echo "  ${3}:" >> "${STATE}/ime_all"
        ;;
    "/system/bin/ime set "*)
        [[ ! -e "${STATE}/set_fail" ]] || exit 1
        echo "${3}" > "${STATE}/default"
        ;;
    *) echo "podman: unexpected $*" >&2; exit 99 ;;
esac
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"
export T_APK="${apk}"

failures=0
fail() { echo "FAIL ${case_name}: $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}" "${XDG_CACHE_HOME}/microos-android"
    mkdir -p "${STATE}"
    : > "${STATE}/packages"
    : > "${STATE}/ime_short"
    : > "${STATE}/ime_all"
    : > "${STATE}/podman"
    : > "${STATE}/curl"
    : > "${STATE}/stdin"
    echo Success > "${STATE}/install_out"
    echo null > "${STATE}/default"
    rm -f "${STATE}/late_packages" "${STATE}/late_count" "${STATE}/second_read_fail" "${STATE}/list_calls"
}

run() {
    rc=0
    "${script}" lepton-android 2> "${STATE}/stderr" || rc=$?
}

installs() { grep -c '^podman exec -i .* /system/bin/cmd package install' "${STATE}/podman" || true; }
guest_calls() { grep -v '^podman exec .* /system/bin/\(cmd package list\|ime list\|settings get\)' "${STATE}/podman" || true; }
logged() { grep -qF -- "$1" "${STATE}/stderr" || fail "missing log: $1, got $(cat "${STATE}/stderr")"; }

case_name="absent installs"
reset
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(installs)" == 1 ]] || fail "install calls $(installs): $(cat "${STATE}/podman")"
grep -qx "podman exec -i lepton-android /system/bin/cmd package install -r -S ${size}" "${STATE}/podman" \
    || fail "install arguments: $(cat "${STATE}/podman")"
grep -q -- ' -g' "${STATE}/podman" && fail "install granted permissions: $(cat "${STATE}/podman")"
[[ "$(cat "${STATE}/stdin")" == "$(sha256sum < "${apk}" | cut -d' ' -f1)" ]] || fail "the bytes streamed are not the pinned apk"
[[ -f "${cached}" ]] || fail "the apk is not cached"
grep -qx "podman exec lepton-android /system/bin/ime enable ${component}" "${STATE}/podman" || fail "ime enable: $(cat "${STATE}/podman")"
grep -qx "podman exec lepton-android /system/bin/ime set ${component}" "${STATE}/podman" || fail "ime set: $(cat "${STATE}/podman")"
grep -q -- '--proto =https --proto-redir =https' "${STATE}/curl" || fail "curl not https only: $(cat "${STATE}/curl")"
grep -q 'rkr.simplekeyboard.inputmethod_149.apk' "${STATE}/curl" || fail "curl without the pinned url: $(cat "${STATE}/curl")"
[[ "$(sort -u "${STATE}/container")" == "exec lepton-android" ]] || fail "containers: $(sort -u "${STATE}/container")"

case_name="listed late"
reset
echo "package:rkr.simplekeyboard.inputmethod versionCode:149" > "${STATE}/packages"
echo "  ${component}:" > "${STATE}/ime_all"
echo "${component}" > "${STATE}/ime_short"
echo "${component}" > "${STATE}/default"
echo 3 > "${STATE}/late_packages"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(installs)" == 0 ]] || fail "installed while the package list lagged: $(cat "${STATE}/podman")"
[[ -z "$(guest_calls)" ]] || fail "guest changed: $(guest_calls)"
logged "the keyboard is on"
[[ "$(cat "${STATE}/late_count")" == 3 ]] || fail "package list read $(cat "${STATE}/late_count") times, not three"

case_name="already on"
: > "${STATE}/podman"
: > "${STATE}/curl"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ ! -s "${STATE}/curl" ]] || fail "downloaded again: $(cat "${STATE}/curl")"
[[ -z "$(guest_calls)" ]] || fail "guest changed: $(guest_calls)"
logged "the keyboard is on"

case_name="absent with another ime"
reset
echo com.example.other/.OtherIme > "${STATE}/ime_short"
echo com.example.other/.OtherIme > "${STATE}/default"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ "$(installs)" == 0 ]] || fail "installed with another IME enabled: $(cat "${STATE}/podman")"
[[ ! -s "${STATE}/curl" ]] || fail "downloaded with another IME enabled"
[[ -z "$(guest_calls)" ]] || fail "guest changed: $(guest_calls)"

case_name="present with another ime"
reset
echo "package:rkr.simplekeyboard.inputmethod versionCode:149" > "${STATE}/packages"
echo "  ${component}:" > "${STATE}/ime_all"
echo com.example.other/.OtherIme > "${STATE}/ime_short"
echo com.example.other/.OtherIme > "${STATE}/default"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ "$(installs)" == 0 ]] || fail "installed: $(cat "${STATE}/podman")"
[[ -z "$(guest_calls)" ]] || fail "guest changed: $(guest_calls)"

case_name="above 149 without an ime"
reset
echo "package:rkr.simplekeyboard.inputmethod versionCode:150" > "${STATE}/packages"
echo "  ${component}:" > "${STATE}/ime_all"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ "$(installs)" == 0 ]] || fail "installed at 150: $(cat "${STATE}/podman")"
grep -qx "podman exec lepton-android /system/bin/ime enable ${component}" "${STATE}/podman" || fail "not enabled: $(cat "${STATE}/podman")"
grep -qx "podman exec lepton-android /system/bin/ime set ${component}" "${STATE}/podman" || fail "not set: $(cat "${STATE}/podman")"

case_name="at 149 without an ime"
reset
echo "package:rkr.simplekeyboard.inputmethod versionCode:149" > "${STATE}/packages"
echo "  ${component}:" > "${STATE}/ime_all"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ "$(installs)" == 0 ]] || fail "installed at 149: $(cat "${STATE}/podman")"
[[ "$(cat "${STATE}/default")" == "${component}" ]] || fail "not set: $(cat "${STATE}/default")"

case_name="enabled but not the default"
reset
echo "package:rkr.simplekeyboard.inputmethod versionCode:149" > "${STATE}/packages"
echo "  ${component}:" > "${STATE}/ime_all"
echo "${component}" > "${STATE}/ime_short"
echo com.example.other/.OtherIme > "${STATE}/default"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ "$(installs)" == 0 ]] || fail "installed: $(cat "${STATE}/podman")"
grep -qx "podman exec lepton-android /system/bin/ime set ${component}" "${STATE}/podman" || fail "not set: $(cat "${STATE}/podman")"

case_name="older upgrades without a set"
reset
echo "package:rkr.simplekeyboard.inputmethod versionCode:140" > "${STATE}/packages"
echo "  ${component}:" > "${STATE}/ime_all"
echo "${component}" > "${STATE}/ime_short"
echo com.example.other/.OtherIme > "${STATE}/default"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ "$(installs)" == 1 ]] || fail "not installed: $(cat "${STATE}/podman")"
grep -qx "podman exec lepton-android /system/bin/ime enable ${component}" "${STATE}/podman" || fail "not enabled: $(cat "${STATE}/podman")"
grep -qx "podman exec lepton-android /system/bin/ime set ${component}" "${STATE}/podman" && fail "set over another default: $(cat "${STATE}/podman")"
logged "ime set skipped, the default is com.example.other/.OtherIme"

case_name="upgrade polls for the new component"
reset
echo "package:rkr.simplekeyboard.inputmethod versionCode:140" > "${STATE}/packages"
echo "  ${component}:" > "${STATE}/ime_all"
: > "${STATE}/ime_all_before"
echo 2 > "${STATE}/ime_all_delay"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ "$(installs)" == 1 ]] || fail "not installed: $(cat "${STATE}/podman")"
grep -qx "podman exec lepton-android /system/bin/ime set ${component}" "${STATE}/podman" || fail "not set after the upgrade: $(cat "${STATE}/podman")"
[[ "$(grep -c '/system/bin/ime list -a' "${STATE}/podman")" -gt 2 ]] || fail "not polled after the install: $(cat "${STATE}/podman")"

case_name="older upgrades with an unset default"
reset
echo "package:rkr.simplekeyboard.inputmethod versionCode:140" > "${STATE}/packages"
echo "  ${component}:" > "${STATE}/ime_all"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ "$(installs)" == 1 ]] || fail "not installed: $(cat "${STATE}/podman")"
grep -qx "podman exec lepton-android /system/bin/ime set ${component}" "${STATE}/podman" || fail "not set: $(cat "${STATE}/podman")"

case_name="set failure retried"
reset
echo "package:rkr.simplekeyboard.inputmethod versionCode:149" > "${STATE}/packages"
echo "  ${component}:" > "${STATE}/ime_all"
: > "${STATE}/set_fail"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
logged "ime set failed, the next start retries"
: > "${STATE}/podman"
rm -f "${STATE}/set_fail"
run
[[ "${rc}" == 0 ]] || fail "rerun exit ${rc}"
grep -qx "podman exec lepton-android /system/bin/ime set ${component}" "${STATE}/podman" || fail "not retried: $(cat "${STATE}/podman")"
[[ "$(cat "${STATE}/default")" == "${component}" ]] || fail "not set on the rerun"

case_name="enable failure retried"
reset
echo "package:rkr.simplekeyboard.inputmethod versionCode:149" > "${STATE}/packages"
echo "  ${component}:" > "${STATE}/ime_all"
: > "${STATE}/enable_fail"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
logged "ime enable failed, the next start retries"
: > "${STATE}/podman"
rm -f "${STATE}/enable_fail"
run
grep -qx "podman exec lepton-android /system/bin/ime enable ${component}" "${STATE}/podman" || fail "not retried: $(cat "${STATE}/podman")"

case_name="polls for the component"
reset
echo 2 > "${STATE}/ime_all_delay"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ "$(grep -c '/system/bin/ime list -a' "${STATE}/podman")" -gt 2 ]] || fail "not polled: $(cat "${STATE}/podman")"
[[ "$(cat "${STATE}/default")" == "${component}" ]] || fail "not set after the polls"

case_name="re-read failure"
reset
echo 2 > "${STATE}/late_packages"
: > "${STATE}/second_read_fail"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
logged "package list failed, nothing this start"
[[ "$(installs)" == 0 ]] || fail "installed after a failed re-read: $(cat "${STATE}/podman")"
[[ ! -s "${STATE}/curl" ]] || fail "downloaded after a failed re-read"

case_name="probe failure"
reset
: > "${STATE}/probe_fail"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
logged "package list failed, nothing this start"
[[ "$(grep -c . "${STATE}/podman")" == 1 ]] || fail "more than the failing probe ran: $(cat "${STATE}/podman")"
[[ ! -s "${STATE}/curl" ]] || fail "downloaded after a failed probe"

case_name="size mismatch"
reset
: > "${STATE}/corrupt"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ "$(installs)" == 0 ]] || fail "installed a short download: $(cat "${STATE}/podman")"
logged "no keyboard download, the next start retries"
[[ ! -e "${cached}" ]] || fail "a short download stayed cached"

case_name="sha mismatch"
reset
export MICROOS_KEYBOARD_SHA=0000000000000000000000000000000000000000000000000000000000000000
run
export MICROOS_KEYBOARD_SHA="${sha}"
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ "$(installs)" == 0 ]] || fail "installed a wrong sha: $(cat "${STATE}/podman")"
logged "no keyboard download, the next start retries"
[[ ! -e "${cached}" ]] || fail "a wrong sha stayed cached"

case_name="offline"
reset
: > "${STATE}/curl_fail"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ "$(installs)" == 0 ]] || fail "installed while offline: $(cat "${STATE}/podman")"
logged "no keyboard download, the next start retries"

case_name="install failure"
reset
echo "Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]" > "${STATE}/install_out"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
logged "install failed: Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]"
grep -q "/system/bin/ime enable" "${STATE}/podman" && fail "enabled after a failed install: $(cat "${STATE}/podman")"

case_name="exact package name"
reset
echo "package:rkr.simplekeyboard.inputmethod.other versionCode:100" > "${STATE}/packages"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ "$(installs)" == 1 ]] || fail "a lookalike package counted as ours: $(cat "${STATE}/podman")"

case_name="overrides without MICROOS_TEST"
reset
MICROOS_TEST='' run
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ "$(installs)" == 0 ]] || fail "installed with the real pin: $(cat "${STATE}/podman")"
logged "no keyboard download, the next start retries"
grep -q "size differs from 666818" "${STATE}/stderr" || fail "the pin is not 666818: $(cat "${STATE}/stderr")"

case_name="usage"
rc=0
"${script}" 2>/dev/null || rc=$?
[[ "${rc}" == 1 ]] || fail "no argument exit ${rc}"

if (( failures )); then
    echo "keyboard-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "keyboard-test: ok"
