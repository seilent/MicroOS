#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
cli="${repo}/data/usr/bin/microos-android"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
export STATE="${T}/state"
mkdir -p "${STATE}/bin" "${T}/bin" "${T}/home"

export HOME="${T}/home"
export MICROOS_HOME="${T}/home"
export XDG_STATE_HOME="${T}/home/.local/state"
export XDG_DATA_HOME="${T}/home/.local/share"
export MICROOS_ANDROID_STATE="${T}/home/.local/state/microos-android"
export MICROOS_ANDROID_DATA="${T}/home/.local/share/microos-android"
export MICROOS_ANDROID_CONTEXT="${T}/home/.local/share/microos-android/home/.local/share/lepton/contexts/android"
export MICROOS_LEPTON_REVIEWED="${T}/reviewed"
export MICROOS_GAPPS="${MICROOS_ANDROID_DATA}/gapps"
export PATH="${T}/bin:${PATH}"
mkdir -p "${MICROOS_ANDROID_STATE}" "${MICROOS_GAPPS}" "${MICROOS_LEPTON_REVIEWED}" "${MICROOS_ANDROID_CONTEXT}"

cat > "${T}/bin/podman" <<STUB
#!/usr/bin/bash
echo "podman \$*" >> "${STATE}/podman"
case "\$1 \$2" in
    "container exists") exit 1 ;;
    "ps -a") ;;
    "ps "*) exit 0 ;;
    "exec lepton-android")
        shift 2
        case "\$*" in
            "/system/bin/dumpsys package com.google.android.gms") echo '    versionCode=241234567 minSdk=24' ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 99 ;;
esac
STUB
cat > "${T}/bin/systemctl" <<STUB
#!/usr/bin/bash
echo "systemctl \$*" >> "${STATE}/calls"
[[ "\$*" == *ActiveState* ]] || exit 99
cat "${STATE}/unit" 2>/dev/null || echo inactive
STUB
chmod 0755 "${T}/bin/"*

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

write_state() {
    python3 - "${MICROOS_ANDROID_STATE}/state.json" "$@" <<'PY'
import json
import os
import sys

path = sys.argv[1]
data = {}
for item in sys.argv[2:]:
    key, value = item.split("=", 1)
    node = data
    parts = key.split(".")
    for part in parts[:-1]:
        node = node.setdefault(part, {})
    node[parts[-1]] = value
with open(path + ".new", "w") as handle:
    json.dump(data, handle)
os.replace(path + ".new", path)
PY
}

reset() {
    rm -rf "${MICROOS_ANDROID_STATE}" "${MICROOS_GAPPS}" "${STATE}/podman" "${STATE}/calls"
    mkdir -p "${MICROOS_ANDROID_STATE}" "${MICROOS_GAPPS}"
    : > "${STATE}/podman"
    : > "${STATE}/calls"
}

run() {
    rc=0
    out=$("${cli}" "$@" 2> "${STATE}/stderr") || rc=$?
    err=$(cat "${STATE}/stderr")
}

reset
write_state "lepton.build=25772114" "lepton.source=steam" "last.result=ready" "gapps.set=mtg11"
printf 'x\n' > "${MICROOS_LEPTON_REVIEWED}/25772114"
mkdir -p "${MICROOS_GAPPS}/mtg11"
ln -sfn mtg11 "${MICROOS_GAPPS}/current"
run status
[[ "${rc}" == 0 ]] || fail "status: exit ${rc}: ${err}"
grep -qx $'lepton.build\t25772114' <<< "${out}" || fail "status: lepton.build: ${out}"
grep -qx $'lepton.source\tsteam' <<< "${out}" || fail "status: lepton.source: ${out}"
grep -qx $'last.result\tready' <<< "${out}" || fail "status: last.result: ${out}"
grep -qx $'gapps.current\tmtg11' <<< "${out}" || fail "status: gapps.current: ${out}"
grep -qx $'lepton.reviewed\treviewed' <<< "${out}" || fail "status: lepton.reviewed: ${out}"

reset
write_state "lepton.build=1" "lepton.source=snapshot"
run status
grep -qx $'lepton.reviewed\tnot-reviewed' <<< "${out}" || fail "status of an unknown build: ${out}"

reset
run status
[[ "${rc}" == 0 ]] || fail "status with no state: exit ${rc}"
grep -qx $'lepton.build\t' <<< "${out}" || fail "status with no state: ${out}"

reset
run gapps remove
[[ "${rc}" == 1 ]] || fail "gapps remove without --yes: exit ${rc}"
grep -q "refusing without --yes" "${STATE}/stderr" || fail "gapps remove without --yes: ${err}"

reset
printf 'tool 3.0.3 gapps=mtg11\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp"
run gapps remove --yes
[[ "${rc}" == 0 ]] || fail "gapps remove: exit ${rc}: ${err}"
grep -qx 'tool 3.0.3 gapps=none' "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp" \
    || fail "gapps remove: the stamp: $(cat "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")"

reset
printf 'tool 3.0.3\nrootfs=3.0.3 fp\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp"
run gapps remove --yes
[[ "${rc}" == 0 ]] || fail "gapps remove on a two line stamp: exit ${rc}: ${err}"
[[ "$(sed -n 1p "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")" == 'tool 3.0.3 gapps=none' ]] \
    || fail "gapps remove on a two line stamp: the first line: $(cat "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")"
[[ "$(sed -n 2p "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")" == 'rootfs=3.0.3 fp' ]] \
    || fail "gapps remove on a two line stamp: the rootfs line: $(cat "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")"
[[ "$(wc -l < "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")" == 2 ]] \
    || fail "gapps remove on a two line stamp: $(cat "${MICROOS_ANDROID_CONTEXT}/microos-android-stamp")"

reset
mkdir -p "${MICROOS_GAPPS}/mtg11/system/product/priv-app/Phonesky"
printf 'set=mtg11\n' > "${MICROOS_GAPPS}/mtg11/STAMP"
ln -sfn mtg11 "${MICROOS_GAPPS}/current"
run gapps setup
[[ "${rc}" == 1 ]] || fail "gapps setup outside the session: exit ${rc}"
grep -q "Android is not running, refusing" "${STATE}/stderr" || fail "gapps setup outside the session: ${err}"

reset
mkdir -p "${MICROOS_GAPPS}/mtg11/system/product/priv-app/Phonesky"
printf 'set=mtg11\n' > "${MICROOS_GAPPS}/mtg11/STAMP"
ln -sfn mtg11 "${MICROOS_GAPPS}/current"
echo active > "${STATE}/unit"
run gapps setup
[[ "${rc}" == 0 ]] || fail "gapps setup: exit ${rc}: ${err}"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["gapps"]["gms"]=="241234567" and d["gapps"]["play"]=="on" and d["gapps"]["setup"]=="done" else 1)' \
    "${MICROOS_ANDROID_STATE}/state.json" || fail "gapps setup: the state: $(cat "${MICROOS_ANDROID_STATE}/state.json" 2>/dev/null)"
grep -qx "systemctl --user show -P ActiveState microos-android.service" "${STATE}/calls" \
    || fail "gapps setup: the unit was not checked: $(cat "${STATE}/calls")"

reset
run gapps setup
[[ "${rc}" == 1 ]] || fail "gapps setup with no set: exit ${rc}"
grep -q "no Google apps set is installed" "${STATE}/stderr" || fail "gapps setup with no set: ${err}"

reset
echo active > "${STATE}/unit"
run gapps setup
[[ "${rc}" == 1 ]] || fail "gapps setup with no set and Android up: exit ${rc}"

reset
rc=0
"${cli}" bogus > /dev/null 2> "${STATE}/stderr" || rc=$?
[[ "${rc}" == 1 ]] || fail "an unknown verb: exit ${rc}"
grep -q "usage:" "${STATE}/stderr" || fail "an unknown verb: ${err}"

[[ "${failures}" == 0 ]] || exit 1
echo "cli-test: ok"
