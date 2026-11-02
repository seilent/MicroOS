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
export MICROOS_CONTENT="${T}/content"
export MICROOS_APK_INFO="${T}/bin/apk-info-extractor"
card="${T}/card"
card_root="${MICROOS_CONTENT}/Android"
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
    rm -rf "${STATE}" "${MICROOS_ANDROID_CONTEXT}" "${MICROOS_ANDROID_DATA}" "${MICROOS_ANDROID_CACHE}" "${MICROOS_ANDROID_ROM}" "${MICROOS_CONTENT}" "${card}"
    mkdir -p "${STATE}" "${MICROOS_ANDROID_ROM}" "${card}"
    ln -sfn "${card}" "${MICROOS_CONTENT}"
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
no_card() { rm -f "${MICROOS_CONTENT}"; }
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

case_name="both roots read"
reset
make_apk "${a2048}" one com.uberspot.a2048 25
run install "${a2048}"
[[ "${rc}" == 0 && "${out}" == com.uberspot.a2048 ]] || fail "home root: exit ${rc}, out ${out}: $(cat "${STATE}/stderr")"
card_apk="${card_root}/tetris.apk"
make_apk "${card_apk}" two com.example.tetris 3
run install "${card_apk}"
[[ "${rc}" == 0 && "${out}" == com.example.tetris ]] || fail "card root: exit ${rc}, out ${out}: $(cat "${STATE}/stderr")"
mkdir -p "${card_root}/games"
mv "${card_apk}" "${card_root}/games/tetris.apk"
mv "${card_apk}.meta" "${card_root}/games/tetris.apk.meta"
run install "${a2048}"
[[ "$(sed -n 's/^path=//p' "${states}/com.example.tetris")" == "${card_root}/games/tetris.apk" ]] \
    || fail "the card root was not walked: $(cat "${states}/com.example.tetris")"
mkdir -p "${card_root}/real"
make_apk "${card_root}/real/base.apk" base com.example.split 4
make_apk "${card_root}/real/split_config.en.apk" en com.example.split 4
run install "${card_root}/real/base.apk"
[[ "${rc}" == 0 ]] || fail "card walk: exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(guest_count install-write)" == 2 ]] || fail "a card split set had $(guest_count install-write) writes: $(cat "${STATE}/guest")"

case_name="card absent"
reset
no_card
make_apk "${a2048}" one com.uberspot.a2048 25
run install "${a2048}"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"

case_name="content link dangling"
reset
rm -f "${MICROOS_CONTENT}"
ln -s "${T}/nowhere" "${MICROOS_CONTENT}"
make_apk "${a2048}" one com.uberspot.a2048 25
run install "${a2048}"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"

case_name="card Android missing"
reset
make_apk "${MICROOS_ANDROID_ROM}/home.apk" home com.example.home 1
make_apk "${card_root}/tetris.apk" two com.example.tetris 3
run install "${card_root}/tetris.apk"
[[ "${rc}" == 0 ]] || fail "setup exit ${rc}: $(cat "${STATE}/stderr")"
rm -rf "${card_root}"
run install "${MICROOS_ANDROID_ROM}/home.apk"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
grep -qx stale "${states}/com.example.tetris" && fail "the card state was marked stale with no Android folder: $(cat "${states}/com.example.tetris")"
"${android}" prune > "${STATE}/prune-out" 2>&1
grep -q "no stale package" "${STATE}/prune-out" || fail "the card was queued with no Android folder: $(cat "${STATE}/prune-out")"

for kind in dangling link; do
    case_name="card out ${kind}"
    reset
    make_apk "${MICROOS_ANDROID_ROM}/home.apk" home com.example.home 1
    make_apk "${card_root}/tetris.apk" two com.example.tetris 3
    run install "${card_root}/tetris.apk"
    [[ "${rc}" == 0 ]] || fail "setup exit ${rc}: $(cat "${STATE}/stderr")"
    case "${kind}" in
        dangling) rm -f "${MICROOS_CONTENT}"; ln -s "${T}/nowhere" "${MICROOS_CONTENT}" ;;
        link)
            rm -rf "${card_root}"
            mkdir -p "${T}/loose"
            ln -s "${T}/loose" "${card_root}"
            ;;
    esac
    run install "${MICROOS_ANDROID_ROM}/home.apk"
    [[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
    grep -qx stale "${states}/com.example.tetris" && fail "the card state was marked stale with the card ${kind}: $(cat "${states}/com.example.tetris")"
    "${android}" prune > "${STATE}/prune-out" 2>&1
    grep -q "no stale package" "${STATE}/prune-out" || fail "the card was queued with the card ${kind}: $(cat "${STATE}/prune-out")"
    [[ "${kind}" != link ]] || logged "${card_root}: a link, not reading the card"
done

case_name="card back marks stale"
reset
make_apk "${MICROOS_ANDROID_ROM}/home.apk" home com.example.home 1
make_apk "${card_root}/tetris.apk" two com.example.tetris 3
run install "${card_root}/tetris.apk"
[[ "${rc}" == 0 ]] || fail "setup exit ${rc}: $(cat "${STATE}/stderr")"
mv "${card_root}" "${T}/card-away"
run install "${MICROOS_ANDROID_ROM}/home.apk"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
grep -qx stale "${states}/com.example.tetris" && fail "the card state was marked stale with the card away"
mv "${T}/card-away" "${card_root}"
rm -f "${card_root}/tetris.apk" "${card_root}/tetris.apk.meta"
run install "${MICROOS_ANDROID_ROM}/home.apk"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
grep -qx stale "${states}/com.example.tetris" || fail "a card package back without its file was not marked stale"
logged "com.example.tetris: ${card_root}/tetris.apk is gone, marked stale"

case_name="card root link refused"
reset
mkdir -p "${T}/loose"
make_apk "${T}/loose/loose.apk" loose com.example.loose 1
rm -rf "${card_root}"
ln -s "${T}/loose" "${card_root}"
make_apk "${MICROOS_ANDROID_ROM}/home.apk" home com.example.home 1
run install "${MICROOS_ANDROID_ROM}/home.apk"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
logged "${card_root}: a link, not reading the card"
grep -q "com.example.loose" "${STATE}/guest" && fail "an apk behind the card root link was installed: $(cat "${STATE}/guest")"

case_name="home root link walked once"
reset
rm -rf "${MICROOS_ANDROID_ROM}"
ln -s "${card_root}" "${MICROOS_ANDROID_ROM}"
make_apk "${card_root}/h.apk" h com.example.h 1
make_apk "${card_root}/game.apk" game com.example.game 1
ln -s "${card_root}/h.apk" "${card_root}/link.apk"
run install "${card_root}/h.apk"
[[ "${rc}" == 0 && "${out}" == com.example.h ]] || fail "exit ${rc}, out ${out}: $(cat "${STATE}/stderr")"
[[ "$(grep -cF -- 'link.apk: a link, skipped' "${STATE}/log")" == 1 ]] || fail "a root walked twice: $(cat "${STATE}/log")"
[[ "$(guest_count 'install -r -g')" == 1 ]] || fail "installed twice: $(cat "${STATE}/guest")"

case_name="linked base apk in a card folder"
reset
make_apk "${card_root}/x.apk" x com.example.x 1
make_apk "${MICROOS_ANDROID_ROM}/elsewhere.apk" e com.example.e 1
make_apk "${MICROOS_ANDROID_ROM}/anchor.apk" a com.example.anchor 1
mkdir -p "${card_root}/folder"
ln -s "${MICROOS_ANDROID_ROM}/elsewhere.apk" "${card_root}/folder/base.apk"
run install "${card_root}/x.apk"
[[ "${rc}" == 0 && "${out}" == com.example.x ]] || fail "exit ${rc}, out ${out}: $(cat "${STATE}/stderr")"
logged "${card_root}/folder/base.apk: a link, skipped"
mv "${card_root}/x.apk" "${card_root}/folder/x.apk"
mv "${card_root}/x.apk.meta" "${card_root}/folder/x.apk.meta"
run install "${MICROOS_ANDROID_ROM}/anchor.apk"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
grep -qx stale "${states}/com.example.x" && fail "a linked base.apk hid x.apk: $(cat "${states}/com.example.x")"
[[ "$(sed -n 's/^path=//p' "${states}/com.example.x")" == "${card_root}/folder/x.apk" ]] || fail "path not updated: $(cat "${states}/com.example.x")"

case_name="card path with glob characters"
reset
globby="${T}/cont[1]"
ln -sfn "${card}" "${globby}"
export MICROOS_CONTENT="${globby}"
make_apk "${MICROOS_ANDROID_ROM}/home.apk" home com.example.home 1
make_apk "${globby}/Android/data/x.apk" skipped com.example.skipped 1
make_apk "${globby}/Android/tetris.apk" two com.example.tetris 3
run install "${globby}/Android/tetris.apk"
[[ "${rc}" == 0 && "${out}" == com.example.tetris ]] || fail "exit ${rc}, out ${out}: $(cat "${STATE}/stderr")"
: > "${STATE}/extractor"
run install "${MICROOS_ANDROID_ROM}/home.apk"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
grep -qF -- "--print-app-id ${globby}/Android/data/x.apk" "${STATE}/extractor" && fail "the card data folder was walked: $(cat "${STATE}/extractor")"
no_card
run install "${MICROOS_ANDROID_ROM}/home.apk"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
grep -qx stale "${states}/com.example.tetris" && fail "a glob path card state was marked stale with the card out"
ln -sfn "${card}" "${globby}"
rm -f "${globby}/Android/tetris.apk" "${globby}/Android/tetris.apk.meta"
run install "${MICROOS_ANDROID_ROM}/home.apk"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
grep -qx stale "${states}/com.example.tetris" || fail "a glob path card state was not marked stale with the card back"
export MICROOS_CONTENT="${T}/content"

case_name="card phone folders skipped"
reset
make_apk "${MICROOS_ANDROID_ROM}/other.apk" other com.example.other 1
for name in data obb media; do
    top="${card_root}/${name}/x.apk"
    nested="${card_root}/foo/${name}/x.apk"
    make_apk "${nested}" nested com.example.nested 1
    run install "${nested}"
    [[ "${rc}" == 0 ]] || fail "${name}: exit ${rc}: $(cat "${STATE}/stderr")"
    mkdir -p "$(dirname "${top}")"
    mv "${nested}" "${top}"
    mv "${nested}.meta" "${top}.meta"
    run install "${MICROOS_ANDROID_ROM}/other.apk"
    grep -qx stale "${states}/com.example.nested" || fail "the card ${name} folder was read: $(cat "${states}/com.example.nested")"
    rm -f "${top}" "${top}.meta" "${states}/com.example.nested"
done

case_name="symlink skipped"
reset
make_apk "${MICROOS_ANDROID_ROM}/real/one.apk" real com.example.real 1
mkdir -p "${card_root}"
ln -s "${MICROOS_ANDROID_ROM}/real/one.apk" "${card_root}/link.apk"
mkdir -p "${card_root}/dir"
make_apk "${card_root}/dir/two.apk" two com.example.two 2
ln -s "${card_root}/dir" "${card_root}/linked-dir"
make_apk "${MICROOS_ANDROID_ROM}/anchor.apk" anchor com.example.anchor 1
run install "${MICROOS_ANDROID_ROM}/anchor.apk"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
logged "${card_root}/link.apk: a link, skipped"
logged "${card_root}/linked-dir: a link, skipped"
[[ "$(cat "${STATE}/guest")" == "/system/bin/cmd package install -r -g -S $(stat -c %s "${MICROOS_ANDROID_ROM}/anchor.apk")
/system/bin/cmd appops set com.example.anchor MANAGE_EXTERNAL_STORAGE allow
/system/bin/cmd package compile -m speed com.example.anchor" ]] || fail "a link was installed: $(cat "${STATE}/guest")"
"${android}" prune > "${STATE}/prune-out" 2>&1
grep -q "no stale package" "${STATE}/prune-out" || fail "a link was queued: $(cat "${STATE}/prune-out")"

case_name="card split set"
reset
make_apk "${card_root}/games/base.apk" base com.example.game 7
printf 'cfg\n' > "${card_root}/games/split_config.arm64_v8a.apk"
make_apk "${card_root}/games/split_config.en.apk" de com.example.game 7
ln -s "${card_root}/games/split_config.en.apk" "${card_root}/games/zz-link.apk"
run install "${card_root}/games/base.apk"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(guest_count install-write)" == 3 ]] || fail "a card split set had $(guest_count install-write) writes: $(cat "${STATE}/guest")"
logged "${card_root}/games/zz-link.apk: a link, skipped"

case_name="card base at the top"
reset
make_apk "${card_root}/base.apk" one com.example.one 1
make_apk "${card_root}/other.apk" two com.example.two 2
run install "${card_root}/base.apk"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(grep -c 'install -r -g' "${STATE}/guest")" == 1 ]] || fail "a base in the card root bundled its neighbours: $(cat "${STATE}/guest")"
run install "${card_root}/other.apk"
[[ "${rc}" == 0 && "$(grep -c 'install -r -g' "${STATE}/guest")" == 2 ]] || fail "a base in the card root hid its neighbours: $(cat "${STATE}/guest")"

case_name="home base at the top"
reset
make_apk "${MICROOS_ANDROID_ROM}/base.apk" one com.example.one 1
make_apk "${MICROOS_ANDROID_ROM}/other.apk" two com.example.two 2
run install "${MICROOS_ANDROID_ROM}/base.apk"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(grep -c 'install -r -g' "${STATE}/guest")" == 1 ]] || fail "a base in the home root bundled its neighbours: $(cat "${STATE}/guest")"

case_name="same names in both roots"
reset
make_apk "${MICROOS_ANDROID_ROM}/same.apk" home com.example.same.home 1
make_apk "${card_root}/same.apk" card com.example.same.card 1
run install "${MICROOS_ANDROID_ROM}/same.apk"
[[ "${rc}" == 0 && "${out}" == com.example.same.home ]] || fail "home: exit ${rc}, out ${out}: $(cat "${STATE}/stderr")"
run install "${card_root}/same.apk"
[[ "${rc}" == 0 && "${out}" == com.example.same.card ]] || fail "card: exit ${rc}, out ${out}: $(cat "${STATE}/stderr")"
[[ "$(sed -n 's/^path=//p' "${states}/com.example.same.home")" == "${MICROOS_ANDROID_ROM}/same.apk" ]] || fail "the home root entry took the card path"
[[ "$(sed -n 's/^path=//p' "${states}/com.example.same.card")" == "${card_root}/same.apk" ]] || fail "the card root entry took the home path"

for kind in Android obb pkg; do
    case_name="obb link at ${kind}"
    reset
    make_apk "${a2048}" one com.uberspot.a2048 25
    mkdir -p "${MICROOS_ANDROID_ROM}/obb"
    echo data > "${MICROOS_ANDROID_ROM}/obb/main.25.com.uberspot.a2048.obb"
    external="${MICROOS_ANDROID_CONTEXT}/external"
    mkdir -p "${external}/Android/obb" "${T}/elsewhere"
    case "${kind}" in
        Android) rm -rf "${external}/Android"; ln -s "${T}/elsewhere" "${external}/Android" ;;
        obb) rm -rf "${external}/Android/obb"; ln -s "${T}/elsewhere" "${external}/Android/obb" ;;
        pkg) ln -s "${T}/elsewhere" "${external}/Android/obb/com.uberspot.a2048" ;;
    esac
    run prepare "${a2048}"
    [[ "${rc}" == 1 ]] || fail "exit ${rc}, out ${out}"
    logged "com.uberspot.a2048: ${external}/"
    logged "is a link, not copying its obb files"
    [[ -z "$(ls -A "${T}/elsewhere")" ]] || fail "obb written through the link at ${kind}: $(ls -A "${T}/elsewhere")"
done

case_name="obb link with no obb"
reset
make_apk "${a2048}" one com.uberspot.a2048 25
external="${MICROOS_ANDROID_CONTEXT}/external"
mkdir -p "${external}/Android/obb" "${T}/elsewhere"
ln -s "${T}/elsewhere" "${external}/Android/obb/com.uberspot.a2048"
run prepare "${a2048}"
[[ "${rc}" == 0 && "${out}" == com.uberspot.a2048 ]] || fail "exit ${rc}, out ${out}: $(cat "${STATE}/stderr")"
[[ -z "$(ls -A "${T}/elsewhere")" ]] || fail "obb written through the link: $(ls -A "${T}/elsewhere")"

case_name="obb source link skipped"
reset
make_apk "${a2048}" one com.uberspot.a2048 25
mkdir -p "${MICROOS_ANDROID_ROM}/obb" "${T}/outside"
echo secret > "${T}/outside/big.obb"
echo data > "${MICROOS_ANDROID_ROM}/obb/main.25.com.uberspot.a2048.obb"
ln -s "${T}/outside/big.obb" "${MICROOS_ANDROID_ROM}/obb/patch.25.com.uberspot.a2048.obb"
run prepare "${a2048}"
[[ "${rc}" == 0 && "${out}" == com.uberspot.a2048 ]] || fail "exit ${rc}, out ${out}: $(cat "${STATE}/stderr")"
dest="${MICROOS_ANDROID_CONTEXT}/external/Android/obb/com.uberspot.a2048"
[[ ! -e "${dest}/patch.25.com.uberspot.a2048.obb" ]] || fail "a linked obb source was copied"
[[ "$(cat "${dest}/main.25.com.uberspot.a2048.obb")" == data ]] || fail "the real obb was not copied"
logged "${MICROOS_ANDROID_ROM}/obb/patch.25.com.uberspot.a2048.obb: a link, skipped"

case_name="obb folder link skipped"
reset
make_apk "${a2048}" one com.uberspot.a2048 25
mkdir -p "${T}/outside"
echo secret > "${T}/outside/main.25.com.uberspot.a2048.obb"
ln -s "${T}/outside" "${MICROOS_ANDROID_ROM}/obb"
run prepare "${a2048}"
[[ "${rc}" == 0 && "${out}" == com.uberspot.a2048 ]] || fail "exit ${rc}, out ${out}: $(cat "${STATE}/stderr")"
[[ ! -e "${MICROOS_ANDROID_CONTEXT}/external/Android/obb/com.uberspot.a2048/main.25.com.uberspot.a2048.obb" ]] \
    || fail "an obb was copied through the linked obb folder"
logged "${MICROOS_ANDROID_ROM}/obb is a link, not copying its obb files"

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
[[ "${named}" == "${repo}/data/usr/libexec/microos/microos-android-check ${repo}/data/usr/libexec/microos/microos-lepton-lib.sh ${repo}/data/usr/libexec/microos/microos-lepton-steam " ]] \
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
