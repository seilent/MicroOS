#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/data/usr/libexec/microos"
check="${libexec}/microos-android-check"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
export STATE="${T}/state"
mkdir -p "${STATE}/bin" "${T}/bin" "${T}/home" "${T}/reviewed" "${T}/snaps"

export HOME="${T}/home"
export MICROOS_HOME="${T}/home"
export MICROOS_HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/home/.config"
export XDG_DATA_HOME="${T}/home/.local/share"
export XDG_STATE_HOME="${T}/home/.local/state"
export MICROOS_LEPTON_REVIEWED="${T}/reviewed"
export MICROOS_LEPTON_SNAPSHOTS="${T}/snaps"
export MICROOS_LEPTON_STEAM_DIR_CMD="${T}/bin/lepton-dir"
export MICROOS_ANDROID_CONTEXT="${T}/home/data/home/.local/share/lepton/contexts/android"
export MICROOS_ANDROID_DATA="${T}/home/data"
export MICROOS_LEPTON_HOME="${T}/home"
export MICROOS_SYSTEM_CARD="${T}/run/microos/system-card"

cat > "${T}/bin/lepton-dir" <<STUB
#!/usr/bin/bash
[[ ! -e "${STATE}/no-steam" ]] || exit 1
printf '%s\n' "${T}/lib/steamapps/common/Lepton"
STUB
chmod 0755 "${T}/bin/lepton-dir"
export PATH="${T}/bin:${PATH}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

runtime() {
    local dir=$1 build=$2 version=$3
    mkdir -p "${dir}/images/rootfs/system" "${dir}/images/rootfs/vendor/odm/etc" "${dir}/sysbake/system" "${dir}/liblepton"
    printf 'ro.build.version.sdk=30\nro.system.build.fingerprint=%s\n' "${4:-fingerprint-${version}}" \
        > "${dir}/images/rootfs/system/build.prop"
    printf 'ro.build.version.release=11\n' > "${dir}/images/rootfs/system/prop.default"
    printf 'ro.odm.build.id=RQ3A\n' > "${dir}/images/rootfs/vendor/odm/etc/build.prop"
    printf 'packages\n' > "${dir}/sysbake/system/packages.xml"
    printf 'x\n' > "${dir}/liblepton/liblepton.sh"
    printf '%s\n' "${version}" > "${dir}/images/version.txt"
    printf '%s\n' "tool-${build}" > "${dir}/version.txt"
}

steam_tree() {
    local build=$1 flags=${2:-4} version=${3:-3.0.3}
    rm -rf "${T}/lib"
    runtime "${T}/lib/steamapps/common/Lepton" "${build}" "${version}"
    printf '"AppState"\n{\n\t"appid"\t\t"3029110"\n\t"buildid"\t\t"%s"\n\t"StateFlags"\t\t"%s"\n}\n' \
        "${build}" "${flags}" > "${T}/lib/steamapps/appmanifest_3029110.acf"
}

run() {
    rc=0
    out=$("${check}" 2> "${T}/stderr") || rc=$?
    err=$(cat "${T}/stderr")
}

reset() {
    rm -rf "${T}/lib" "${T}/snaps" "${MICROOS_ANDROID_CONTEXT}" "${T}/reviewed" "${T}/run" \
        "${T}/home/.local/share/lepton" "${T}/home/.local/share/microemu"
    mkdir -p "${T}/reviewed" "${T}/snaps" "${T}/run/microos"
    rm -f "${STATE}/no-steam"
}

stamp() {
    mkdir -p "${MICROOS_ANDROID_CONTEXT}"
    printf '%s\n' "$@" > "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp"
}

reset
printf '25772114\n' > "${T}/reviewed/25772114"
steam_tree 25772114
run
[[ "${rc}" == 0 && -z "${out}" ]] || fail "installed and reviewed: exit ${rc} out ${out}"

reset
printf '25772114\n' > "${T}/reviewed/25772114"
steam_tree 25772114
stamp "rootfs=3.0.3 fingerprint-3.0.3 gapps=none"
run
[[ "${rc}" == 0 && -z "${out}" ]] || fail "the same identity booted: exit ${rc} out ${out}"

reset
printf '25772114\n' > "${T}/reviewed/25772114"
steam_tree 25772114
stamp "rootfs=3.0.4 fingerprint-3.0.4 gapps=none"
run
[[ "${rc}" == 2 && "${out}" == downgrade ]] || fail "older rootfs: exit ${rc} out ${out}"

reset
printf '25772114\n' > "${T}/reviewed/25772114"
steam_tree 25772114
stamp "rootfs=3.0.2 fingerprint-newer gapps=none"
run
[[ "${rc}" == 0 ]] || fail "a newer rootfs than the stamp: exit ${rc} out ${out}"

reset
printf '25772114\n' > "${T}/reviewed/25772114"
steam_tree 25772114
printf 'ro.build.version.sdk=30\nro.build.fingerprint=fingerprint-fallback\n' > "${T}/lib/steamapps/common/Lepton/images/rootfs/system/build.prop"
stamp "rootfs=3.0.4 fingerprint-fallback gapps=none"
run
[[ "${rc}" == 2 && "${out}" == downgrade ]] || fail "an older runtime with only the fallback key: exit ${rc} out ${out}"

reset
steam_tree 25772114
run
[[ "${rc}" == 2 && "${out}" == not-reviewed ]] || fail "not reviewed: exit ${rc} out ${out}"

reset
: > "${STATE}/no-steam"
run
[[ "${rc}" == 1 && -z "${out}" ]] || fail "no Lepton at all: exit ${rc} out ${out}"
rm -f "${STATE}/no-steam"

reset
: > "${STATE}/no-steam"
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
steam_tree 25772113
printf '25772113\n' > "${T}/reviewed/25772113"
mkdir -p "${T}/snaps/25772113"
cp -a "${T}/lib/steamapps/common/Lepton/." "${T}/snaps/25772113/"
printf 'rootfs=3.0.3 fingerprint-3.0.3\n' > "${T}/snaps/.verified.25772113"
run
[[ "${rc}" == 0 ]] || fail "a reviewed snapshot with Steam gone: exit ${rc} out ${out}"

reset
steam_tree 25772114
printf '25772114\n' > "${T}/reviewed/25772114"
mkdir -p "${T}/home/.local/share/lepton/contexts/microemu-play"
run
[[ "${rc}" == 2 && "${out}" == old-path ]] || fail "the old context path: exit ${rc} out ${out}"

reset
steam_tree 25772114
printf '25772114\n' > "${T}/reviewed/25772114"
mkdir -p "${T}/home/.local/share/microemu/android/home/.local/share/lepton/contexts/microemu-play"
run
[[ "${rc}" == 2 && "${out}" == old-path ]] || fail "MicroEMU's context path: exit ${rc} out ${out}"

reset
steam_tree 25772114
mkdir -p "${T}/reviewed"
chmod 000 "${T}/reviewed"
run
chmod 755 "${T}/reviewed"
[[ "${rc}" == 3 && -z "${out}" ]] || fail "an unreadable reviewed dir fails open: exit ${rc} out ${out} err ${err}"

reset
run
[[ "${rc}" == 1 && -z "${out}" ]] || fail "no Lepton and no snapshot: exit ${rc} out ${out}"

reset
steam_tree 25772114 6
run
[[ "${rc}" == 2 && "${out}" == not-reviewed ]] || fail "an install Steam has not finished: exit ${rc} out ${out}"

reset
printf '25772114\n' > "${T}/reviewed/25772114"
steam_tree 25772114
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
chmod 000 "${MICROOS_ANDROID_CONTEXT}"
run
chmod 755 "${MICROOS_ANDROID_CONTEXT}"
[[ "${rc}" == 0 ]] || fail "an unreadable stamp: exit ${rc} out ${out}"

reset
printf '25772114\n' > "${T}/reviewed/25772114"
steam_tree 25772114
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
mkdir -p "${T}/home/.local/share/lepton/contexts/microemu-play"
run
[[ "${rc}" == 0 && -z "${out}" ]] || fail "the old path with the new context: exit ${rc} out ${out}"

reset
printf '25772114\n' > "${T}/reviewed/25772114"
steam_tree 25772114
mkdir -p "${T}/home/.local/share/lepton/contexts/microemu-play"
chmod 000 "${T}/home/.local/share/lepton"
run
chmod 755 "${T}/home/.local/share/lepton"
[[ "${rc}" == 0 && -z "${out}" ]] || fail "an unreadable old context dir fails open: exit ${rc} out ${out} err ${err}"

reset
printf '25772114\n' > "${T}/reviewed/25772114"
steam_tree 25772114
chmod 000 "${T}/lib/steamapps/common/Lepton"
run
chmod 755 "${T}/lib/steamapps/common/Lepton"
[[ "${rc}" == 3 ]] || fail "an unreadable Steam tree fails open: exit ${rc} out ${out} err ${err}"

reset
printf '25772114\n' > "${T}/reviewed/25772114"
steam_tree 25772114
mkdir -p "${T}/snaps"
cp -a "${T}/lib/steamapps/common/Lepton" "${T}/snaps/25772114"
printf 'rootfs=3.0.3 fingerprint-3.0.3\n' > "${T}/snaps/.verified.25772114"
rm -rf "${T}/lib"
: > "${STATE}/no-steam"
run
[[ "${rc}" == 0 && -z "${out}" ]] || fail "a verified snapshot: exit ${rc} out ${out} err ${err}"

reset
printf '25772114\n' > "${T}/reviewed/25772114"
steam_tree 25772114
mkdir -p "${T}/snaps"
cp -a "${T}/lib/steamapps/common/Lepton" "${T}/snaps/25772114"
printf 'rootfs=3.0.4 fingerprint-3.0.4\n' > "${T}/snaps/.verified.25772114"
rm -rf "${T}/lib"
: > "${STATE}/no-steam"
run
[[ "${rc}" == 1 ]] || fail "a marker for another rootfs: exit ${rc} out ${out} err ${err}"

reset
printf '25772114\n' > "${T}/reviewed/25772114"
steam_tree 25772114
start=$SECONDS
run
(( SECONDS - start < 5 )) || fail "the check took $(( SECONDS - start )) s"

[[ "${failures}" == 0 ]] || exit 1
echo "check-test: ok"
