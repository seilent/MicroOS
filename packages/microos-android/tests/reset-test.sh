#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
reset_cmd="${repo}/data/usr/bin/microos-android"

T=$(mktemp -d)
trap 'chmod -R u+w "${T}" 2>/dev/null; rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
export MICROOS_ANDROID_CONTEXT="${T}/contexts/android"
export MICROOS_ANDROID_DATA="${T}/data"
export MICROOS_GAPPS="${T}/gapps"

cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
case "$*" in
    *ActiveState*prepare*) cat "${STATE}/update_unit" ;;
    *) cat "${STATE}/unit" ;;
esac
STUB
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
echo "podman $*" >> "${STATE}/calls"
case "$1 $2" in
    "container exists") [[ -e "${STATE}/exists_rc" ]] && exit "$(cat "${STATE}/exists_rc")"; [[ -e "${STATE}/container-$3" ]] ;;
    "unshare chmod") shift 2; chmod "$@" ;;
    "unshare rm") shift 2; rm "$@" ;;
    "ps -a")
        case "$*" in
            *label=lepton=true*) [[ "$(cat "${STATE}/ps_fail" 2>/dev/null)" != leptons ]] || exit 125 ;;
            *) [[ "$(cat "${STATE}/ps_fail" 2>/dev/null)" != users ]] || exit 125 ;;
        esac
        for f in "${STATE}"/container-*; do
            [[ -e "${f}" ]] || continue
            case "$*" in
                *label=lepton=true*) grep -qx lepton=true "${f}" && echo "${f##*/container-}" ;;
                *STEAM_COMPAT_DATA_PATH*) echo "${f##*/container-} $(sed -n 's/^STEAM_COMPAT_DATA_PATH=//p' "${f}")" ;;
            esac
        done
        exit 0
        ;;
    *) exit 99 ;;
esac
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    [[ ! -d "${T}/contexts" ]] || chmod -R u+w "${T}/contexts"
    rm -rf "${STATE}" "${T}/contexts" "${MICROOS_ANDROID_DATA}"
    mkdir -p "${STATE}" "${MICROOS_ANDROID_CONTEXT}/baked/data_overlay/system" "${MICROOS_ANDROID_DATA}/sideload"
    : > "${STATE}/calls"
    echo "$1" > "${STATE}/unit"
    echo "${2:-inactive}" > "${STATE}/update_unit"
    echo xml > "${MICROOS_ANDROID_CONTEXT}/baked/data_overlay/system/packages.xml"
    chmod 0500 "${MICROOS_ANDROID_CONTEXT}/baked/data_overlay/system"
    echo state > "${MICROOS_ANDROID_DATA}/sideload/com.example"
    echo com.example > "${MICROOS_ANDROID_DATA}/prune"
    echo log > "${MICROOS_ANDROID_DATA}/boot.log"
    [[ ! -d "${MICROOS_GAPPS}" ]] || chmod -R u+w "${MICROOS_GAPPS}"
    rm -rf "${MICROOS_GAPPS}"
    mkdir -p "${MICROOS_GAPPS}/set/system"
    echo apk > "${MICROOS_GAPPS}/set/system/Phonesky.apk"
    ln -s set "${MICROOS_GAPPS}/current"
    chmod -R a-w "${MICROOS_GAPPS}/set"
}

run() {
    rc=0
    "${reset_cmd}" reset "$@" > "${STATE}/out" 2>&1 || rc=$?
}

for state in active activating deactivating; do
    reset "${state}"
    run --yes
    [[ "${rc}" == 1 ]] || fail "unit ${state}: exit ${rc}"
    [[ -d "${MICROOS_ANDROID_CONTEXT}" && -d "${MICROOS_ANDROID_DATA}/sideload" ]] || fail "unit ${state}: something removed"
done

for state in active activating deactivating; do
    reset inactive "${state}"
    run --yes
    [[ "${rc}" == 1 ]] && grep -q "microos-lepton-prepare.service is running, refusing" "${STATE}/out" || fail "update ${state}: exit ${rc}"
    [[ -d "${MICROOS_ANDROID_CONTEXT}" ]] || fail "update ${state}: context removed"
done

for container in lepton-android; do
    reset inactive
    : > "${STATE}/container-${container}"
    run --yes
    [[ "${rc}" == 1 ]] && grep -q "container ${container} exists" "${STATE}/out" || fail "${container} present: exit ${rc}"
    [[ -d "${MICROOS_ANDROID_CONTEXT}" ]] || fail "${container} present: context removed"
done

reset inactive
mkdir -p "${T}/contexts/probe-lh-copy/keep"
rc=0
MICROOS_ANDROID_CONTEXT="${T}/contexts/probe-lh-copy" "${reset_cmd}" reset --yes > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 1 ]] && grep -qx "microos-android reset: ${T}/contexts/probe-lh-copy is not the android context, refusing" "${STATE}/out" \
    || fail "another context: exit ${rc}: $(cat "${STATE}/out")"
[[ -d "${T}/contexts/probe-lh-copy/keep" && ! -s "${STATE}/calls" ]] || fail "another context: something removed or podman called"
rm -rf "${T:?}/contexts/probe-lh-copy"

for spelling in "${MICROOS_ANDROID_CONTEXT}" "${T}/contexts//android/"; do
    reset inactive
    printf 'STEAM_COMPAT_DATA_PATH=%s\n' "${spelling}" > "${STATE}/container-lepton-other"
    run --yes
    [[ "${rc}" == 1 ]] && grep -qx "microos-android reset: container lepton-other uses ${MICROOS_ANDROID_CONTEXT}, refusing" "${STATE}/out" \
        || fail "another container on the context (${spelling}): exit ${rc}: $(cat "${STATE}/out")"
    [[ -d "${MICROOS_ANDROID_CONTEXT}" ]] || fail "another container on the context (${spelling}): context removed"
done
reset inactive
echo lepton=true > "${STATE}/container-lepton-steamlaunch-1"
run --yes
[[ "${rc}" == 1 ]] && grep -q "microos-android reset: Lepton containers exist (lepton-steamlaunch-1)" "${STATE}/out" \
    || fail "another Lepton container: exit ${rc}: $(cat "${STATE}/out")"
[[ -d "${MICROOS_ANDROID_CONTEXT}" && -d "${MICROOS_ANDROID_DATA}/sideload" ]] || fail "another Lepton container: something removed"
for which in users leptons; do
    reset inactive
    echo "${which}" > "${STATE}/ps_fail"
    run --yes
    [[ "${rc}" == 1 ]] && grep -qx "microos-android reset: podman ps failed, refusing" "${STATE}/out" || fail "podman ps error (${which}): exit ${rc}"
    [[ -d "${MICROOS_ANDROID_CONTEXT}" && -d "${MICROOS_ANDROID_DATA}/sideload" ]] || fail "podman ps error (${which}): something removed"
done

reset inactive
echo 125 > "${STATE}/exists_rc"
run --yes
[[ "${rc}" == 1 ]] && grep -q "podman container exists failed (rc=125)" "${STATE}/out" || fail "podman error: exit ${rc}: $(cat "${STATE}/out")"
[[ -d "${MICROOS_ANDROID_CONTEXT}" ]] || fail "podman error: context removed"

reset inactive
run --yes
[[ "${rc}" == 0 ]] || fail "reset exit ${rc}: $(cat "${STATE}/out")"
[[ ! -e "${MICROOS_ANDROID_CONTEXT}" ]] || fail "context left"
[[ -d "${T}/contexts" ]] || fail "contexts directory removed"
[[ ! -e "${MICROOS_ANDROID_DATA}/sideload" && ! -e "${MICROOS_ANDROID_DATA}/prune" ]] || fail "sideload state left"
[[ -f "${MICROOS_ANDROID_DATA}/boot.log" ]] || fail "boot log removed"
[[ -e "${MICROOS_GAPPS}/current" && -f "${MICROOS_GAPPS}/set/system/Phonesky.apk" ]] || fail "reset touched the gapps tree"

[[ "$(grep -n 'unshare chmod -R 700' "${STATE}/calls" | cut -d: -f1)" -lt "$(grep -n 'unshare rm -rf' "${STATE}/calls" | cut -d: -f1)" ]] \
    || fail "chmod not before rm: $(cat "${STATE}/calls")"

reset inactive
run --bogus
[[ "${rc}" == 1 ]] || fail "unknown option exit ${rc}"
[[ -e "${MICROOS_ANDROID_CONTEXT}" ]] || fail "an unknown option removed the context"
reset inactive
run
[[ "${rc}" == 1 ]] && grep -q "refusing without --yes" "${STATE}/out" || fail "no --yes: exit ${rc}"
[[ -d "${MICROOS_ANDROID_CONTEXT}" ]] || fail "no --yes: context removed"

reset failed
chmod -R u+w "${T}/contexts"
rm -rf "${T}/contexts"
run --yes
[[ "${rc}" == 0 ]] || fail "no context exit ${rc}: $(cat "${STATE}/out")"
grep -q unshare "${STATE}/calls" && fail "no context: unshare called"

if (( failures )); then
    echo "reset-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "reset-test: ok"
