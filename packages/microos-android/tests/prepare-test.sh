#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/data/usr/libexec/microos"
prepare="${libexec}/microos-lepton-prepare"

T=$(mktemp -d)
trap 'chmod -R u+w "${T}" 2>/dev/null || :; rm -rf "${T}"' EXIT
export STATE="${T}/state"
mkdir -p "${STATE}/bin" "${T}/bin" "${T}/home" "${T}/reviewed" "${T}/snaps"

export HOME="${T}/home"
export MICROOS_HOME="${T}/home"
export MICROOS_HOME="${T}/home"
export MICROOS_LEPTON_REVIEWED="${T}/reviewed"
export MICROOS_LEPTON_SNAPSHOTS="${T}/snaps"
export MICROOS_LEPTON_STEAM_DIR_CMD="${T}/bin/lepton-dir"
export MICROOS_ANDROID_DATA="${T}/data"
export MICROOS_ANDROID_CONTEXT="${T}/data/home/.local/share/lepton/contexts/android"
export MICROOS_ANDROID_STATE="${T}/state-dir"
export MICROOS_PODMAN="${T}/bin/podman"
ORIG_PATH=${PATH}
export PATH="${T}/bin:${PATH}"

cat > "${T}/bin/lepton-dir" <<STUB
#!/usr/bin/bash
[[ ! -e "${STATE}/no-steam" ]] || exit 1
printf '%s\n' "${T}/lib/steamapps/common/Lepton"
STUB
cat > "${T}/bin/podman" <<STUB
#!/usr/bin/bash
echo "podman \$*" >> "${STATE}/podman"
case "\$1" in
    inspect)
        [[ -e "${STATE}/container" ]] || exit 125
        cat "${STATE}/status"
        ;;
    rm)
        rm -f "${STATE}/container"
        ;;
    unshare)
        shift
        exec "\$@"
        ;;
    *) exit 99 ;;
esac
STUB
chmod 0755 "${T}/bin/lepton-dir" "${T}/bin/podman"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

runtime() {
    local dir=$1 build=$2 version=${3:-3.0.3}
    mkdir -p "${dir}/images/rootfs/system/etc" "${dir}/images/rootfs/vendor/odm/etc" "${dir}/sysbake/system" \
        "${dir}/liblepton"
    printf 'ro.build.version.sdk=30\nro.system.build.fingerprint=fp-%s\n' "${version}" > "${dir}/images/rootfs/system/build.prop"
    printf 'ro.build.version.release=11\n' > "${dir}/images/rootfs/system/etc/prop.default"
    printf 'ro.odm.build.id=RQ3A\n' > "${dir}/images/rootfs/vendor/odm/etc/build.prop"
    printf 'packages\n' > "${dir}/sysbake/system/packages.xml"
    printf 'x\n' > "${dir}/liblepton/liblepton.sh"
    printf '%s\n' "${version}" > "${dir}/images/version.txt"
    printf 'tool\n' > "${dir}/version.txt"
}

steam_tree() {
    local build=$1 flags=${2:-4}
    rm -rf "${T}/lib"
    runtime "${T}/lib/steamapps/common/Lepton" "${build}"
    printf '"AppState"\n{\n\t"appid"\t\t"3029110"\n\t"buildid"\t\t"%s"\n\t"StateFlags"\t\t"%s"\n}\n' \
        "${build}" "${flags}" > "${T}/lib/steamapps/appmanifest_3029110.acf"
}

checked() {
    local dir=$1
    (
        eval "$(sed -n '/^paths()/,/^}/p;/^entry()/,/^}/p' "${libexec}/microos-lepton-lib.sh")"
        cd "${dir}" || exit 1
        paths | LC_ALL=C sort | while IFS= read -r path; do entry "${dir}" "${path}"; done
    )
}

reviewed() { checked "$1" > "${T}/reviewed/${2:-25772114}"; }

context() {
    mkdir -p "${MICROOS_ANDROID_CONTEXT}/baked/data_overlay/system"
    printf 'packages\n' > "${MICROOS_ANDROID_CONTEXT}/baked/data_overlay/system/packages.xml"
}

run() {
    rc=0
    out=$(env PATH="${T}/bin:${ORIG_PATH}" "${prepare}" 2> "${T}/stderr") || rc=$?
    err=$(cat "${T}/stderr")
}

reset() {
    rm -rf "${T}/lib" "${T}/snaps" "${T}/reviewed" "${T}/data" "${T}/state-dir" "${STATE}/container" "${STATE}/no-steam"
    mkdir -p "${T}/reviewed" "${T}/snaps" "${T}/data"
    : > "${STATE}/podman"
}

reset
steam_tree 25772114
reviewed "${T}/lib/steamapps/common/Lepton"
run
[[ "${rc}" == 0 ]] || fail "a clean start: exit ${rc}: ${err}"
[[ -d "${T}/snaps/25772114" ]] || fail "a clean start: no snapshot: $(ls -A "${T}/snaps")"
[[ -f "${T}/snaps/.verified.25772114" && ! -e "${T}/snaps/.verified.25772114.new" ]] \
    || fail "a clean start: the marker is not beside the snapshot: $(ls -A "${T}/snaps")"
grep -qx 'rootfs=3.0.3 fp-3.0.3' "${T}/snaps/.verified.25772114" \
    || fail "a clean start: the marker: $(cat "${T}/snaps/.verified.25772114")"
[[ "$(cat "${T}/state-dir/state.json" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["lepton"]["build"])')" == 25772114 ]] \
    || fail "a clean start: state.json not written: $(cat "${T}/state-dir/state.json" 2>/dev/null)"
[[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["lepton"]["source"])' "${T}/state-dir/state.json")" == steam ]] \
    || fail "a clean start: the source is not steam"

reset
steam_tree 25772114
reviewed "${T}/lib/steamapps/common/Lepton"
mkdir -p "${T}/snaps/25772114"
cp -a "${T}/lib/steamapps/common/Lepton/." "${T}/snaps/25772114/"
printf 'rootfs=3.0.3 fp-3.0.3\n' > "${T}/snaps/.verified.25772114"
touch "${T}/snaps/.take.999" "${T}/snaps/.prepare.999"
mkdir -p "${T}/snaps/.take.1000"
flock -x "${T}/snaps/.lock" sleep 3 &
holder=$!
sleep 0.2
run
wait "${holder}" 2>/dev/null || :
[[ -e "${T}/snaps/.take.999" ]] || fail "a held snapshot lock: the temp was removed anyway"
grep -q "a snapshot is being taken, no temp removed" "${T}/stderr" \
    || fail "a held snapshot lock: not logged: ${err}"
run
[[ "${rc}" == 0 ]] || fail "stale temps: exit ${rc}: ${err}"
[[ ! -e "${T}/snaps/.take.999" && ! -e "${T}/snaps/.prepare.999" && ! -e "${T}/snaps/.take.1000" ]] \
    || fail "stale temps kept: $(ls -A "${T}/snaps")"

reset
steam_tree 25772114
reviewed "${T}/lib/steamapps/common/Lepton"
mkdir -p "${STATE}" && echo running > "${STATE}/status"
: > "${STATE}/container"
run
[[ "${rc}" == 1 ]] || fail "a running container: exit ${rc}"
grep -qx "microos-lepton-prepare: lepton-android runs, refusing" "${T}/stderr" \
    || fail "a running container: no refusal: ${err}"
[[ ! -e "${T}/snaps/25772114" ]] || fail "a running container: a snapshot was still taken"
grep -q "^podman rm" "${STATE}/podman" && fail "a running container: it was removed: $(cat "${STATE}/podman")"

reset
steam_tree 25772114
reviewed "${T}/lib/steamapps/common/Lepton"
echo exited > "${STATE}/status"
: > "${STATE}/container"
run
[[ "${rc}" == 0 ]] || fail "an exited container: exit ${rc}: ${err}"
grep -q "^podman rm -fi lepton-android" "${STATE}/podman" || fail "an exited container: not removed: $(cat "${STATE}/podman")"
[[ -d "${T}/snaps/25772114" ]] || fail "an exited container: no snapshot"

reset
steam_tree 25772114
reviewed "${T}/lib/steamapps/common/Lepton" 6
run
[[ "${rc}" == 1 ]] || fail "an install Steam has not finished: exit ${rc}"
grep -q "not fully installed\|not installed\|refusing" "${T}/stderr" || fail "an unfinished install: no refusal: ${err}"

reset
steam_tree 25772115
reviewed "${T}/lib/steamapps/common/Lepton"
run
[[ "${rc}" == 1 ]] || fail "an unreviewed build: exit ${rc}"
grep -q "not one MicroOS knows" "${T}/stderr" || fail "an unreviewed build: no refusal: ${err}"

reset
steam_tree 25772114
reviewed "${T}/lib/steamapps/common/Lepton"
context
mkdir -p "${T}/state-dir"
printf '{"gapps": {"set": "mtg11"}}\n' > "${T}/state-dir/state.json"
run
[[ "${rc}" == 0 ]] || fail "the context backup: exit ${rc}: ${err}"
[[ -d "${T}/data/backups/android.pre-25772114.bak" ]] || fail "the context backup: not made from ${MICROOS_ANDROID_CONTEXT}: $(ls -A "${T}/data" 2>/dev/null)"
[[ -f "${T}/state-dir/state.json" ]] || fail "the state file was removed"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("gapps",{}).get("set")=="mtg11" else 1)' \
    "${T}/state-dir/state.json" || fail "the state file lost another tool's keys"

reset
steam_tree 25772114
reviewed "${T}/lib/steamapps/common/Lepton"
mkdir -p "${T}/snaps"
mkdir -p "${T}/snaps/.take.$$"
echo stale > "${T}/snaps/.take.$$/stale"
mkdir -p "${T}/bin-noxattr"
cat > "${T}/bin-noxattr/setfattr" <<'STUB'
#!/usr/bin/bash
exit 1
STUB
chmod 0755 "${T}/bin-noxattr/setfattr"
rc=0
PATH="${T}/bin-noxattr:${PATH}" out=$("${prepare}" 2> "${T}/stderr") || rc=$?
err=$(cat "${T}/stderr")
[[ "${rc}" == 1 ]] || fail "an xattr refusal: exit ${rc}: ${err}"
grep -q "keeps no xattrs" "${T}/stderr" || fail "an xattr refusal: no message: ${err}"
[[ -z "$(find "${T}/snaps" -maxdepth 1 -name '.take.*' -o -maxdepth 1 -name '.prepare.*')" ]] \
    || fail "an xattr refusal: a temp dir left: $(ls -A "${T}/snaps")"

reset
steam_tree 25772114
reviewed "${T}/lib/steamapps/common/Lepton"
mkdir -p "${T}/snaps/25772114"
cp -a "${T}/lib/steamapps/common/Lepton/." "${T}/snaps/25772114/"
printf 'rootfs=3.0.3 fp-3.0.3\n' > "${T}/snaps/.verified.25772114"
printf 'extra\n' > "${T}/snaps/25772114/liblepton/extra.sh"
run
[[ "${rc}" == 0 ]] || fail "a bad snapshot: exit ${rc}: ${err}"
grep -q "Lepton in ${T}/snaps/25772114 is not the build in ${T}/reviewed/25772114, refusing" "${T}/stderr" \
    || fail "a bad snapshot: no reason: ${err}"
[[ -e "${T}/snaps/25772114/liblepton/extra.sh" ]] && fail "a bad snapshot: it was kept: $(ls -A "${T}/snaps")"
[[ -e "${T}/snaps/.verified.25772114" ]] || fail "a bad snapshot: Steam's reviewed copy was not taken"
grep -q "took the snapshot ${T}/snaps/25772114" "${T}/stderr" \
    || fail "a bad snapshot: Steam's reviewed copy did not replace it: ${err}"

reset
steam_tree 25772114
reviewed "${T}/lib/steamapps/common/Lepton"
mkdir -p "${T}/snaps/.verified.25772113.new"
printf 'garbage\n' > "${T}/snaps/.verified.25772113.new/left"
run
[[ "${rc}" == 0 ]] || fail "a stale marker temp: exit ${rc}: ${err}"
[[ ! -e "${T}/snaps/.verified.25772113.new" ]] || fail "a stale marker temp was kept: $(ls -A "${T}/snaps")"

reset
steam_tree 25772114
reviewed "${T}/lib/steamapps/common/Lepton"
mkdir -p "${T}/data/backups/android.pre-25772113.bak.part"
printf 'x\n' > "${T}/data/backups/android.pre-25772113.bak.part/stale"
run
[[ "${rc}" == 0 ]] || fail "a stale .part: exit ${rc}: ${err}"
[[ ! -e "${T}/data/backups/android.pre-25772113.bak.part" ]] || fail "a stale .part was kept: $(ls -A "${T}/data/backups")"

reset
steam_tree 25772114
reviewed "${T}/lib/steamapps/common/Lepton"
for b in 25772113 25772112; do
    rm -rf "${T}/snaps/${b}"
    cp -a "${T}/lib/steamapps/common/Lepton/." "${T}/snaps/${b}/"
    printf 'rootfs=3.0.3 fp-3.0.3\n' > "${T}/snaps/.verified.${b}"
    reviewed "${T}/snaps/${b}" "${b}"
done
mkdir -p "${T}/bin-ostree"
cat > "${T}/bin-ostree/ostree" <<'STUB'
#!/usr/bin/bash
case "$1 $2" in
    "admin status") exit 1 ;;
    "ls "*) exit 1 ;;
esac
exit 1
STUB
chmod 0755 "${T}/bin-ostree/ostree"
rc=0
out=$(env PATH="${T}/bin-ostree:${T}/bin:${ORIG_PATH}" "${prepare}" 2> "${T}/stderr") || rc=$?
err=$(cat "${T}/stderr")
[[ "${rc}" == 0 ]] || fail "ostree down: exit ${rc}: ${err}"
grep -q "cannot list the deployments, judging snapshots by the booted one" "${T}/stderr" \
    || fail "ostree down: not logged: ${err}"
[[ -d "${T}/snaps/25772114" ]] || fail "ostree down: the new snapshot was not taken: $(ls -A "${T}/snaps")"
[[ -d "${T}/snaps/25772112" ]] || fail "ostree down: a snapshot was pruned on an unreadable list: $(ls -A "${T}/snaps")"
grep -q "a deployment's reviewed list is unreadable, no snapshot pruned" "${T}/stderr" \
    || fail "ostree down: the skip was not logged: ${err}"
rm -rf "${T}/bin-ostree"

reset
steam_tree 25772114
reviewed "${T}/lib/steamapps/common/Lepton"
mkdir -p "${T}/bin-ostree"
cat > "${T}/bin-ostree/ostree" <<'STUB'
#!/usr/bin/bash
case "$1 $2" in
    "admin status")
        printf '{"deployments": [{"checksum": "%s"}]}\n' "$(printf 'a%.0s' {1..64})"
        ;;
    "ls "*) exit 1 ;;
esac
STUB
chmod 0755 "${T}/bin-ostree/ostree"
rc=0
out=$(env PATH="${T}/bin-ostree:${T}/bin:${ORIG_PATH}" "${prepare}" 2> "${T}/stderr") || rc=$?
err=$(cat "${T}/stderr")
[[ "${rc}" == 0 ]] || fail "a failed ostree ls: exit ${rc}: ${err}"
grep -q "cannot list $(printf 'a%.0s' {1..64}), judging snapshots by the booted one" "${T}/stderr" \
    || fail "a failed ostree ls: not logged: ${err}"
grep -q "a deployment's reviewed list is unreadable, no snapshot pruned" "${T}/stderr" \
    || fail "a failed ostree ls: the prune was not skipped: ${err}"
rm -rf "${T}/bin-ostree"

reset
steam_tree 25772114
reviewed "${T}/lib/steamapps/common/Lepton"
mkdir -p "${T}/bin-mv"
cat > "${T}/bin-mv/mv" <<STUB
#!/usr/bin/bash
if [[ "\$1" == -T && "\$3" == "${T}/snaps/25772114" ]]; then
    printf 'marker=%s\n' "\$([[ -f "${T}/snaps/.verified.25772114" ]] && echo yes || echo no)" >> "${T}/mv-order"
fi
exec $(command -v mv) "\$@"
STUB
chmod 0755 "${T}/bin-mv/mv"
: > "${T}/mv-order"
rc=0
out=$(env PATH="${T}/bin-mv:${T}/bin:${ORIG_PATH}" "${prepare}" 2> "${T}/stderr") || rc=$?
err=$(cat "${T}/stderr")
[[ "${rc}" == 0 ]] || fail "the marker before the rename: exit ${rc}: ${err}"
grep -qx marker=yes "${T}/mv-order" \
    || fail "the marker was written after the rename: $(cat "${T}/mv-order") ${err}"
grep -qx 'rootfs=3.0.3 fp-3.0.3' "${T}/snaps/.verified.25772114" \
    || fail "the marker before the rename: the marker: $(cat "${T}/snaps/.verified.25772114" 2>/dev/null)"
rm -rf "${T}/bin-mv"

reset
steam_tree 25772114
reviewed "${T}/lib/steamapps/common/Lepton"
mkdir -p "${T}/bin-cp"
cat > "${T}/bin-cp/cp" <<STUB
#!/usr/bin/bash
$(command -v cp) "\$@" || exit \$?
if [[ "\${@: -1}" == "${T}/snaps/.take."* ]]; then
    printf '"AppState"\n{\n\t"appid"\t\t"3029110"\n\t"buildid"\t\t"25772115"\n\t"StateFlags"\t\t"4"\n}\n' \
        > "${T}/lib/steamapps/appmanifest_3029110.acf"
fi
STUB
chmod 0755 "${T}/bin-cp/cp"
rc=0
out=$(env PATH="${T}/bin-cp:${T}/bin:${ORIG_PATH}" "${prepare}" 2> "${T}/stderr") || rc=$?
err=$(cat "${T}/stderr")
[[ "${rc}" == 1 ]] || fail "a buildid change during the copy: exit ${rc}: ${err}"
grep -q "changed while it was copied, refusing" "${T}/stderr" \
    || fail "a buildid change during the copy: no refusal: ${err}"
[[ ! -e "${T}/snaps/25772114" ]] || fail "a buildid change during the copy: the snapshot was kept: $(ls -A "${T}/snaps")"
[[ -z "$(find "${T}/snaps" -maxdepth 1 -name '.take.*')" ]] \
    || fail "a buildid change during the copy: a temp dir left: $(ls -A "${T}/snaps")"
rm -rf "${T}/bin-cp"

reset
steam_tree 25772114
reviewed "${T}/lib/steamapps/common/Lepton"
mkdir -p "${T}/bin-cp"
cat > "${T}/bin-cp/cp" <<STUB
#!/usr/bin/bash
$(command -v cp) "\$@" || exit \$?
if [[ "\${@: -1}" == "${T}/snaps/.take."* ]]; then
    printf '"AppState"\n{\n\t"appid"\t\t"3029110"\n\t"buildid"\t\t"25772114"\n\t"StateFlags"\t\t"6"\n}\n' \
        > "${T}/lib/steamapps/appmanifest_3029110.acf"
fi
STUB
chmod 0755 "${T}/bin-cp/cp"
rc=0
out=$(env PATH="${T}/bin-cp:${T}/bin:${ORIG_PATH}" "${prepare}" 2> "${T}/stderr") || rc=$?
err=$(cat "${T}/stderr")
[[ "${rc}" == 1 ]] || fail "a StateFlags change during the copy: exit ${rc}: ${err}"
grep -q "changed while it was copied, refusing" "${T}/stderr" \
    || fail "a StateFlags change during the copy: no refusal: ${err}"
[[ ! -e "${T}/snaps/25772114" ]] || fail "a StateFlags change during the copy: the snapshot was kept"
rm -rf "${T}/bin-cp"

[[ "${failures}" == 0 ]] || exit 1
echo "prepare-test: ok"
