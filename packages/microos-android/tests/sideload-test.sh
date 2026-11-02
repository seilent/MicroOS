#!/usr/bin/bash
set -eu

export PYTHONDONTWRITEBYTECODE=1

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
sideload="${repo}/data/usr/libexec/microos/microos-android-sideload"
android="${repo}/data/usr/bin/microos-android"


T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
export MICROOS_ANDROID_CONTEXT="${T}/contexts/android"
export MICROOS_ANDROID_DATA="${T}/data"
export MICROOS_ANDROID_CACHE="${T}/cache"
export MICROOS_ANDROID_ROM="${T}/roms"
export MICROOS_APK_INFO="${T}/bin/apk-info-extractor"
xml="${MICROOS_ANDROID_CONTEXT}/baked/data_overlay/system/packages.xml"
states="${MICROOS_ANDROID_DATA}/sideload"

cat > "${T}/bin/apk-info-extractor" <<'STUB'
#!/usr/bin/bash
echo "extractor $1 $2" >> "${STATE}/extractor"
case "$1" in
    --print-app-id) sed -n 1p "$2.meta" ;;
    --print-app-version) sed -n 2p "$2.meta" ;;
    *) exit 1 ;;
esac
STUB
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
[[ "${1:-}" != container ]] || { [[ "${2:-}" == exists ]] && exit "${MICROOS_TEST_EXISTS_RC:-1}"; exit 99; }
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
    "/system/bin/cmd package install -r -g -S "*|"/system/bin/cmd package install-write -S "*)
        cat > "${STATE}/stdin.raw"
        sha256sum < "${STATE}/stdin.raw" | cut -d' ' -f1 >> "${STATE}/stdin"
        ;;
esac
echo "$*" >> "${STATE}/guest"
case "$*" in
    "/system/bin/cmd package install -r -g -S "*|"/system/bin/cmd package install-commit "*) cat "${STATE}/install_out" ;;
    "/system/bin/cmd package install-create -r -g") echo "Success: created install session [1234]" ;;
    "/system/bin/cmd package install-write -S "*) echo "Success: streamed $(stat -c %s "${STATE}/stdin.raw") bytes" ;;
    "/system/bin/cmd package uninstall "*) cat "${STATE}/uninstall_out" ;;
esac
STUB
cat > "${T}/bin/stat" <<'STUB'
#!/usr/bin/bash
for arg in "$@"; do
    [[ "${arg}" != *-statfail.apk ]] || exit 1
done
exec /usr/bin/stat "$@"
STUB
cat > "${T}/bin/logger" <<'STUB'
#!/usr/bin/bash
shift 3
echo "$*" >> "${STATE}/log"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"

failures=0
fail() { echo "FAIL ${case_name}: $*" >&2; failures=$((failures + 1)); }

make_apk() {
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" > "$1"
    printf '%s\n%s\n' "$3" "$4" > "$1.meta"
}

packages() {
    mkdir -p "$(dirname "${xml}")"
    {
        echo "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>"
        echo "<packages>"
        printf '%s\n' "$@"
        echo "</packages>"
    } > "${xml}"
}

reset() {
    rm -rf "${STATE}" "${MICROOS_ANDROID_CONTEXT}" "${MICROOS_ANDROID_DATA}" "${MICROOS_ANDROID_CACHE}" "${MICROOS_ANDROID_ROM}"
    mkdir -p "${STATE}" "${MICROOS_ANDROID_ROM}"
    : > "${STATE}/guest"
    : > "${STATE}/log"
    : > "${STATE}/extractor"
    : > "${STATE}/stdin"
    echo Success > "${STATE}/install_out"
    echo Success > "${STATE}/uninstall_out"
}

run() {
    rc=0
    out=$("${sideload}" "$@" 2> "${STATE}/stderr") || rc=$?
}

guest_count() { grep -c -- "$1" "${STATE}/guest" || true; }
logged() { grep -qF -- "$1" "${STATE}/log" || fail "missing log: $1, got $(cat "${STATE}/log")"; }
a2048="${MICROOS_ANDROID_ROM}/2048.apk"

case_name="new apk"
reset
make_apk "${a2048}" one com.uberspot.a2048 25
run install "${a2048}"
[[ "${rc}" == 0 && "${out}" == com.uberspot.a2048 ]] || fail "exit ${rc}, out ${out}: $(cat "${STATE}/stderr")"
expected="/system/bin/cmd package install -r -g -S $(stat -c %s "${a2048}")
/system/bin/cmd appops set com.uberspot.a2048 MANAGE_EXTERNAL_STORAGE allow
/system/bin/cmd package compile -m speed com.uberspot.a2048"
[[ "$(cat "${STATE}/guest")" == "${expected}" ]] || fail "guest calls $(cat "${STATE}/guest")"
[[ "$(cat "${STATE}/stdin")" == "$(sha256sum < "${a2048}" | cut -d' ' -f1)" ]] || fail "the apk did not stream to the guest"
[[ "$(sed -n 's/^path=//p' "${states}/com.uberspot.a2048")" == "${a2048}" ]] || fail "state path"
[[ "$(sed -n 's/^version=//p' "${states}/com.uberspot.a2048")" == 25 ]] || fail "state version"
[[ -n "$(sed -n 's/^sha256=//p' "${states}/com.uberspot.a2048")" ]] || fail "state sha"

case_name="same apk"
: > "${STATE}/guest"
packages '<package name="com.uberspot.a2048" codePath="/data/app/x" version="25" userId="10018">' '</package>'
run install "${a2048}"
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ ! -s "${STATE}/guest" ]] || fail "reinstalled: $(cat "${STATE}/guest")"

case_name="apkinfo cache"
[[ "$(grep -c -- "--print-app-id ${a2048}" "${STATE}/extractor")" == 1 ]] || fail "extractor ran again for an unchanged file: $(cat "${STATE}/extractor")"

case_name="changed apk"
: > "${STATE}/guest"
make_apk "${a2048}" two com.uberspot.a2048 26
touch -d '+1 min' "${a2048}"
run install "${a2048}"
[[ "${rc}" == 0 ]] || fail "exit ${rc}"
[[ "$(guest_count "install -r -g -S $(stat -c %s "${a2048}")")" == 1 ]] || fail "not reinstalled: $(cat "${STATE}/guest")"
[[ "$(sed -n 's/^version=//p' "${states}/com.uberspot.a2048")" == 26 ]] || fail "state version not updated"

case_name="older apk"
reset
make_apk "${a2048}" old com.uberspot.a2048 20
packages '<package name="com.uberspot.a2048" version="25" userId="10018">' '</package>'
run install "${a2048}"
[[ "${rc}" == 1 ]] || fail "exit ${rc}"
logged "com.uberspot.a2048 20 is older than installed 25, not installing"
[[ "$(guest_count install)" == 0 ]] || fail "installed anyway"

case_name="play copy"
reset
make_apk "${a2048}" one com.uberspot.a2048 25
packages '<package name="com.uberspot.a2048" version="25" installer="com.android.vending" userId="10018">' '</package>'
run install "${a2048}"
[[ "${rc}" == 1 ]] || fail "exit ${rc}"
logged "com.uberspot.a2048 is installed from Play, not replacing it"
[[ "$(guest_count install)" == 0 ]] || fail "installed over a Play copy"

case_name="incompatible update"
reset
make_apk "${a2048}" one com.uberspot.a2048 25
echo "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]" > "${STATE}/install_out"
run install "${a2048}"
[[ "${rc}" == 1 ]] || fail "exit ${rc}"
logged "com.uberspot.a2048 is installed from Play, not replacing it"
[[ ! -e "${states}/com.uberspot.a2048" ]] || fail "state written after a failed install"

case_name="install failure"
reset
make_apk "${a2048}" one com.uberspot.a2048 25
echo "Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]" > "${STATE}/install_out"
run install "${a2048}"
[[ "${rc}" == 1 ]] || fail "exit ${rc}"
logged "com.uberspot.a2048: install failed: Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]"
[[ "$(guest_count appops)" == 0 ]] || fail "appops after a failed install"

case_name="split set"
reset
split="${MICROOS_ANDROID_ROM}/game/base.apk"
make_apk "${split}" base com.example.game 7
printf 'cfg\n' > "${MICROOS_ANDROID_ROM}/game/split_config.arm64_v8a.apk"
make_apk "${MICROOS_ANDROID_ROM}/game/split_config.en.apk" de com.example.game 7
run install "${split}"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
expected="/system/bin/cmd package install-create -r -g
/system/bin/cmd package install-write -S 5 1234 base.apk -
/system/bin/cmd package install-write -S 4 1234 split_config.arm64_v8a.apk -
/system/bin/cmd package install-write -S 3 1234 split_config.en.apk -
/system/bin/cmd package install-commit 1234
/system/bin/cmd appops set com.example.game MANAGE_EXTERNAL_STORAGE allow
/system/bin/cmd package compile -m speed com.example.game"
[[ "$(cat "${STATE}/guest")" == "${expected}" ]] || fail "guest calls $(cat "${STATE}/guest")"
[[ "$(tail -n 1 "${STATE}/stdin")" == "$(sha256sum < "${MICROOS_ANDROID_ROM}/game/split_config.en.apk" | cut -d' ' -f1)" ]] \
    || fail "the last split did not stream to the guest"

case_name="split entered alone"
: > "${STATE}/guest"
rm -f "${states}/com.example.game"
run install "${MICROOS_ANDROID_ROM}/game/split_config.en.apk"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(cat "${STATE}/guest")" == "/system/bin/cmd package install -r -g -S $(stat -c %s "${MICROOS_ANDROID_ROM}/game/split_config.en.apk")
/system/bin/cmd appops set com.example.game MANAGE_EXTERNAL_STORAGE allow
/system/bin/cmd package compile -m speed com.example.game" ]] || fail "a non base file installed more than itself: $(cat "${STATE}/guest")"

case_name="dash names skipped"
reset
make_apk "${MICROOS_ANDROID_ROM}/game/base.apk" base com.example.game 7
make_apk "${MICROOS_ANDROID_ROM}/game/-dash.apk" dash com.example.dash 1
run install "${MICROOS_ANDROID_ROM}/game/base.apk"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(cat "${STATE}/guest")" == "/system/bin/cmd package install -r -g -S $(stat -c %s "${MICROOS_ANDROID_ROM}/game/base.apk")
/system/bin/cmd appops set com.example.game MANAGE_EXTERNAL_STORAGE allow
/system/bin/cmd package compile -m speed com.example.game" ]] || fail "a dash named file joined the set: $(cat "${STATE}/guest")"
make_apk "${MICROOS_ANDROID_ROM}/other.apk" other com.example.other 1
make_apk "${MICROOS_ANDROID_ROM}/-root.apk" root com.example.root 1
run install "${MICROOS_ANDROID_ROM}/other.apk"
[[ "${rc}" == 0 ]] || fail "root exit ${rc}: $(cat "${STATE}/stderr")"
"${android}" prune > "${STATE}/prune-out" 2>&1
[[ "$(grep -c . "${STATE}/prune-out")" == 1 ]] || fail "a dash named file was listed: $(cat "${STATE}/prune-out")"
rm -f "${MICROOS_ANDROID_ROM}/game/-dash.apk" "${MICROOS_ANDROID_ROM}/-root.apk" "${MICROOS_ANDROID_ROM}/other.apk"

case_name="stat failure abandons the session"
reset
split="${MICROOS_ANDROID_ROM}/game/base.apk"
make_apk "${split}" base com.example.game 7
make_apk "${MICROOS_ANDROID_ROM}/game/split-statfail.apk" de com.example.game 7
run install "${split}"
[[ "${rc}" == 1 ]] || fail "stat failure: exit ${rc}: $(cat "${STATE}/stderr")"
grep -qx "/system/bin/cmd package install-abandon 1234" "${STATE}/guest" || fail "stat failure: the session was not abandoned: $(cat "${STATE}/guest")"
grep -q "install-commit" "${STATE}/guest" && fail "stat failure: the session was committed: $(cat "${STATE}/guest")"

case_name="base in the roms root"
reset
make_apk "${MICROOS_ANDROID_ROM}/base.apk" one com.example.one 1
make_apk "${MICROOS_ANDROID_ROM}/other.apk" two com.example.two 2
run install "${MICROOS_ANDROID_ROM}/base.apk"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(cat "${STATE}/guest")" == "/system/bin/cmd package install -r -g -S $(stat -c %s "${MICROOS_ANDROID_ROM}/base.apk")
/system/bin/cmd appops set com.example.one MANAGE_EXTERNAL_STORAGE allow
/system/bin/cmd package compile -m speed com.example.one" ]] || fail "a base in the ROMs root bundled its neighbours: $(cat "${STATE}/guest")"
: > "${STATE}/guest"
rm -f "${states}/com.example.one"
run install "${MICROOS_ANDROID_ROM}/other.apk"
[[ "${rc}" == 0 && "$(grep -c 'install -r -g' "${STATE}/guest")" == 1 ]] || fail "a base in the ROMs root hid its neighbours: $(cat "${STATE}/guest")"
rm -f "${MICROOS_ANDROID_ROM}/base.apk" "${MICROOS_ANDROID_ROM}/other.apk"

case_name="obb"
reset
make_apk "${a2048}" one com.uberspot.a2048 25
mkdir -p "${MICROOS_ANDROID_ROM}/obb"
echo data > "${MICROOS_ANDROID_ROM}/obb/main.25.com.uberspot.a2048.obb"
echo patch > "${MICROOS_ANDROID_ROM}/patch.25.com.uberspot.a2048.obb"
run prepare "${a2048}"
[[ "${rc}" == 0 && "${out}" == com.uberspot.a2048 ]] || fail "prepare exit ${rc}, out ${out}"
dest="${MICROOS_ANDROID_CONTEXT}/external/Android/obb/com.uberspot.a2048"
[[ "$(cat "${dest}/main.25.com.uberspot.a2048.obb")" == data && "$(cat "${dest}/patch.25.com.uberspot.a2048.obb")" == patch ]] \
    || fail "obb not copied"
printf 'xxxx\n' > "${dest}/main.25.com.uberspot.a2048.obb"
touch -r "${MICROOS_ANDROID_ROM}/obb/main.25.com.uberspot.a2048.obb" "${dest}/main.25.com.uberspot.a2048.obb"
run prepare "${a2048}"
[[ "$(cat "${dest}/main.25.com.uberspot.a2048.obb")" == xxxx ]] || fail "unchanged obb copied again"
echo newer > "${MICROOS_ANDROID_ROM}/obb/main.25.com.uberspot.a2048.obb"
touch -d '+1 min' "${MICROOS_ANDROID_ROM}/obb/main.25.com.uberspot.a2048.obb"
run prepare "${a2048}"
[[ "$(cat "${dest}/main.25.com.uberspot.a2048.obb")" == newer ]] || fail "changed obb not copied"

case_name="deleted apk"
reset
make_apk "${a2048}" one com.uberspot.a2048 25
other="${MICROOS_ANDROID_ROM}/other.apk"
make_apk "${other}" other com.example.other 1
run install "${a2048}"
run install "${other}"
rm -f "${a2048}" "${a2048}.meta"
: > "${STATE}/guest"
run install "${other}"
grep -qx stale "${states}/com.uberspot.a2048" || fail "not marked stale"
logged "com.uberspot.a2048: ${a2048} is gone, marked stale"
[[ "$(guest_count uninstall)" == 0 ]] || fail "uninstalled without a prune"

case_name="prune"
"${android}" prune > "${STATE}/prune-out"
grep -q "^com.uberspot.a2048 ${a2048}$" "${STATE}/prune-out" || fail "prune did not list: $(cat "${STATE}/prune-out")"
[[ "$(cat "${MICROOS_ANDROID_DATA}/prune")" == com.uberspot.a2048 ]] || fail "not queued"
run install "${other}"
[[ "$(guest_count "/system/bin/cmd package uninstall com.uberspot.a2048")" == 1 ]] || fail "queued package not uninstalled"
[[ ! -e "${states}/com.uberspot.a2048" && ! -e "${MICROOS_ANDROID_DATA}/prune" ]] || fail "state or queue left after the uninstall"
[[ -e "${states}/com.example.other" ]] || fail "other state removed"

case_name="prune failure"
reset
make_apk "${a2048}" one com.uberspot.a2048 25
make_apk "${other}" other com.example.other 1
run install "${a2048}"
rm -f "${a2048}" "${a2048}.meta"
run install "${other}"
"${android}" prune > /dev/null
echo "Failure [DELETE_FAILED_INTERNAL_ERROR]" > "${STATE}/uninstall_out"
run install "${other}"
[[ -e "${states}/com.uberspot.a2048" ]] || fail "state removed after a failed uninstall"
[[ "$(cat "${MICROOS_ANDROID_DATA}/prune")" == com.uberspot.a2048 ]] || fail "failed uninstall not kept queued"
logged "com.uberspot.a2048: uninstall failed, kept queued: Failure [DELETE_FAILED_INTERNAL_ERROR]"

case_name="queued package back before the prune"
reset
make_apk "${a2048}" one com.uberspot.a2048 25
make_apk "${other}" other com.example.other 1
run install "${a2048}"
mv "${a2048}" "${T}/away.apk"
mv "${a2048}.meta" "${T}/away.apk.meta"
run install "${other}"
"${android}" prune > /dev/null
mv "${T}/away.apk" "${a2048}"
mv "${T}/away.apk.meta" "${a2048}.meta"
: > "${STATE}/guest"
run install "${other}"
[[ "$(guest_count uninstall)" == 0 ]] || fail "a package whose file came back was uninstalled"
[[ ! -e "${MICROOS_ANDROID_DATA}/prune" ]] || fail "queue entry kept for a package that is back"
grep -qx stale "${states}/com.uberspot.a2048" && fail "still stale after the file came back"

case_name="moved apk"
reset
make_apk "${a2048}" one com.uberspot.a2048 25
make_apk "${other}" other com.example.other 1
run install "${a2048}"
moved="${MICROOS_ANDROID_ROM}/R&D #1/2048 & co.apk"
mkdir -p "$(dirname "${moved}")"
mv "${a2048}" "${moved}"
mv "${a2048}.meta" "${moved}.meta"
run install "${other}"
grep -qx stale "${states}/com.uberspot.a2048" && fail "moved apk marked stale"
[[ "$(sed -n 's/^path=//p' "${states}/com.uberspot.a2048")" == "${moved}" ]] || fail "path not updated: $(cat "${states}/com.uberspot.a2048")"
[[ "$(sed -n 's/^version=//p' "${states}/com.uberspot.a2048")" == 25 ]] || fail "version lost on the move"

for kind in missing empty dangling; do
    case_name="rom dir ${kind}"
    reset
    make_apk "${a2048}" one com.uberspot.a2048 25
    run install "${a2048}"
    cp "${states}/com.uberspot.a2048" "${T}/state.before"
    outside="${T}/outside.apk"
    make_apk "${outside}" out com.example.outside 1
    case "${kind}" in
        missing) rm -rf "${MICROOS_ANDROID_ROM}" ;;
        empty) rm -rf "${MICROOS_ANDROID_ROM:?}"/* ;;
        dangling) rm -rf "${MICROOS_ANDROID_ROM}"; ln -s "${T}/sdcard/androidgames" "${MICROOS_ANDROID_ROM}" ;;
    esac
    run install "${outside}"
    cmp -s "${states}/com.uberspot.a2048" "${T}/state.before" || fail "state touched: $(cat "${states}/com.uberspot.a2048")"
    rm -rf "${MICROOS_ANDROID_ROM}"
done

case_name="extractor from the runtime"
reset
extractor="${T}/runtime/liblepton/apk_extractor/bin/apk-info-extractor"
mkdir -p "${extractor%/*}"
cp "${T}/bin/apk-info-extractor" "${extractor}"
chmod 0755 "${extractor}"
printf '#!/usr/bin/bash\nprintf "%%s\\n" "%s"\n' "${T}/runtime" > "${T}/bin/lepton-runtime"
chmod 0755 "${T}/bin/lepton-runtime"
make_apk "${a2048}" one com.uberspot.a2048 25
rc=0
out=$(MICROOS_APK_INFO="" MICROOS_LEPTON="${T}/bin/lepton-runtime" "${sideload}" install "${a2048}" 2> "${STATE}/stderr") || rc=$?
[[ "${rc}" == 0 && "${out}" == com.uberspot.a2048 ]] || fail "exit ${rc}, out ${out}: $(cat "${STATE}/stderr")"
grep -qxF "extractor --print-app-id ${a2048}" "${STATE}/extractor" || fail "the runtime's extractor did not run: $(cat "${STATE}/extractor")"
rm -rf "${T}/runtime"

case_name="steamapps common Lepton named twice"
named=$(grep -rl 'steamapps/common/Lepton' "${repo}/data" "${repo}/build" | sort | tr '\n' ' ')
[[ "${named}" == "${repo}/data/usr/libexec/microos/microos-lepton ${repo}/data/usr/libexec/microos/microos-lepton-steam " ]] \
    || fail "steamapps/common/Lepton is named by: ${named}"

case_name="no armada names"
named=$(grep -rIl -i armada "${repo}/data" | sort | tr '\n' ' ')
[[ -z "${named}" ]] || fail "armada named by: ${named}"

case_name="prune with nothing stale"
reset
rc=0
"${android}" prune > "${STATE}/prune-out" || rc=$?
[[ "${rc}" == 0 ]] && grep -q "no stale package" "${STATE}/prune-out" || fail "exit ${rc}: $(cat "${STATE}/prune-out")"

if (( failures )); then
    echo "sideload-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "sideload-test: ok"
