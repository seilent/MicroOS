#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/data/usr/libexec/microos"
lib="${libexec}/microos-lepton-lib.sh"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
export STATE="${T}/state"
mkdir -p "${T}/home" "${STATE}"

export HOME="${T}/home"
export MICROOS_HOME="${T}/home"
export MICROOS_HOME="${T}/home"
export XDG_STATE_HOME="${T}/home/.local/state"
export MICROOS_ANDROID_STATE="${T}/home/.local/state/microos-android"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

work="${T}/work"
mkdir -p "${work}"
cat > "${T}/run.sh" <<'STUB'
set -u
. "${LIB}"
"$@"
STUB

export LIB="${lib}"
call() {
    rc=0
    out=$(bash "${T}/run.sh" "$@" 2> "${T}/stderr") || rc=$?
    err=$(cat "${T}/stderr")
}

reset() {
    rm -rf "${MICROOS_ANDROID_STATE}"
    mkdir -p "${MICROOS_ANDROID_STATE}"
}

reset
call state_init
[[ -f "${MICROOS_ANDROID_STATE}/state.json" ]] || fail "state_init: no file"
[[ "$(stat -c %a "${MICROOS_ANDROID_STATE}/state.json")" == 600 ]] || fail "state_init: mode $(stat -c %a "${MICROOS_ANDROID_STATE}/state.json")"
[[ "$(stat -c %a "${MICROOS_ANDROID_STATE}")" == 700 ]] || fail "state_init: dir mode $(stat -c %a "${MICROOS_ANDROID_STATE}")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["lepton"]["build"]=="" and d["last"]["boottime"]==0 else 1)' \
    "${MICROOS_ANDROID_STATE}/state.json" || fail "state_init: fields: $(cat "${MICROOS_ANDROID_STATE}/state.json")"

call state_init
[[ -f "${MICROOS_ANDROID_STATE}/state.json" ]] || fail "state_init twice: no file"

reset
call state_write "lepton.build=25772114" "lepton.source=steam" "last.boottime=7" "last.result=ready"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["lepton"]["build"]=="25772114" and d["lepton"]["source"]=="steam" and d["last"]["result"]=="ready" else 1)' \
    "${MICROOS_ANDROID_STATE}/state.json" || fail "state_write: $(cat "${MICROOS_ANDROID_STATE}/state.json")"

reset
printf '{"other": "kept"}\n' > "${MICROOS_ANDROID_STATE}/state.json"
call state_write "gapps.set=mtg11"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("other")=="kept" and d["gapps"]["set"]=="mtg11" else 1)' \
    "${MICROOS_ANDROID_STATE}/state.json" || fail "state_write clobbered another key: $(cat "${MICROOS_ANDROID_STATE}/state.json")"

reset
printf 'not json\n' > "${MICROOS_ANDROID_STATE}/state.json"
call state_write "gapps.set=mtg11"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["gapps"]["set"]=="mtg11" else 1)' \
    "${MICROOS_ANDROID_STATE}/state.json" || fail "state_write over junk: $(cat "${MICROOS_ANDROID_STATE}/state.json")"

reset
call state_write "last.boottime=12345"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["last"]["boottime"]==12345 else 1)' \
    "${MICROOS_ANDROID_STATE}/state.json" || fail "state_write boottime is not a number: $(cat "${MICROOS_ANDROID_STATE}/state.json")"
call state_write "last.boottime=nope"
[[ "${rc}" == 1 ]] || fail "a non numeric boottime: exit ${rc}"
grep -q "not a number" "${T}/stderr" || fail "a non numeric boottime: no message: ${err}"

reset
call state_init
[[ -z "$(find "${MICROOS_ANDROID_STATE}" -name '.state.*')" ]] || fail "state_write left a temp file: $(ls -A "${MICROOS_ANDROID_STATE}")"
before=$(stat -c %i "${MICROOS_ANDROID_STATE}/state.json")
call state_write "keyboard=149"
after=$(stat -c %i "${MICROOS_ANDROID_STATE}/state.json")
[[ "${before}" != "${after}" ]] || fail "state_write replaced the file in place"

reset
call state_write "lepton.build=25772114" "lepton.source=steam" "last.boottime=7"
call state_get "lepton.build"
[[ "${rc}" == 0 && "${out}" == 25772114 ]] || fail "state_get: exit ${rc} out ${out}"
call state_get "lepton.source"
[[ "${rc}" == 0 && "${out}" == steam ]] || fail "state_get source: exit ${rc} out ${out}"
call state_get "lepton.absent"
[[ "${rc}" == 1 && -z "${out}" ]] || fail "state_get of an absent key: exit ${rc} out ${out}"
call state_get "last.boottime"
[[ "${rc}" == 0 && "${out}" == 7 ]] || fail "state_get of a number: exit ${rc} out ${out}"

reset
rm -f "${MICROOS_ANDROID_STATE}/state.json"
call state_get "lepton.build"
[[ "${rc}" == 1 ]] || fail "state_get with no file: exit ${rc}"

reset
printf '{"lepton": "not an object"}\n' > "${MICROOS_ANDROID_STATE}/state.json"
call state_get "lepton.build"
[[ "${rc}" == 1 ]] || fail "state_get through a string: exit ${rc}"

reset
call boottime_ms
[[ "${rc}" == 0 && "${out}" =~ ^[0-9]+$ ]] || fail "boottime_ms: exit ${rc} out ${out}"

reset
call write_reason "${T}/run" "card-lost"
[[ "${rc}" == 0 && "$(cat "${T}/run/end-reason" 2>/dev/null)" == card-lost ]] || fail "write_reason: exit ${rc}"
call write_reason "${T}/run" "Not A Word"
[[ "${rc}" == 1 ]] || fail "write_reason of a bad word: exit ${rc}"
[[ "$(cat "${T}/run/end-reason")" == card-lost ]] || fail "write_reason of a bad word changed the marker"
[[ -z "$(find "${T}/run" -name 'end-reason.new')" ]] || fail "write_reason left a temp file"

reset
mkdir -p "${T}/rootfs/img/images"
call rootfs_identity "${T}/rootfs/img"
[[ "${rc}" == 1 ]] || fail "rootfs_identity without a version: exit ${rc}"
printf 'v3.0.3\n' > "${T}/rootfs/img/images/version.txt"
mkdir -p "${T}/rootfs/img/images/rootfs/system"
printf 'ro.build.fingerprint=fp\n' > "${T}/rootfs/img/images/rootfs/system/build.prop"
call rootfs_identity "${T}/rootfs/img"
[[ "${rc}" == 0 && "${out}" == "v3.0.3 fp" ]] || fail "rootfs_identity with the fallback key: exit ${rc} out ${out}"
printf 'ro.system.build.fingerprint=real-fp\nro.build.fingerprint=fp\n' \
    > "${T}/rootfs/img/images/rootfs/system/build.prop"
call rootfs_identity "${T}/rootfs/img"
[[ "${rc}" == 0 && "${out}" == "v3.0.3 real-fp" ]] || fail "rootfs_identity with the system key: exit ${rc} out ${out}"

call identity_older "3.0.4 fp-new" "3.0.3 fp-old"
[[ "${rc}" == 0 ]] || fail "identity_older: a newer stamp is not older"
call identity_older "3.0.3 fp-old" "3.0.4 fp-new"
[[ "${rc}" == 1 ]] || fail "identity_older: an older stamp counted"
call identity_older "" "3.0.4 fp-new"
[[ "${rc}" == 1 ]] || fail "identity_older: an empty stamp counted"
call identity_older "3.0.3 fp-a" "3.0.3 fp-b"
[[ "${rc}" == 1 ]] || fail "identity_older: a tool only change counted"

reset
(
    exec 9>>"${MICROOS_ANDROID_STATE}/state.json.lock"
    flock -x 9
    : > "${T}/held"
    exec sleep 20
) &
holder=$!
for _ in {1..100}; do [[ -e "${T}/held" ]] && break; sleep 0.05; done
[[ -e "${T}/held" ]] || fail "the state lock: the holder never locked"
call boottime_ms
start_ms=${out}
rc=0
out=$(bash "${T}/run.sh" state_write "gapps.set=mtg11" 2> "${T}/held-stderr") || rc=$?
held_err=$(cat "${T}/held-stderr")
call boottime_ms
waited=$(( out - start_ms ))
(( waited >= 9000 )) || fail "a held state lock: state_write waited ${waited} ms"
grep -q "state.json.lock is held, writing anyway" <<< "${held_err}" || fail "a held state lock: not logged: ${held_err}"
[[ "${rc}" == 0 ]] || fail "a held state lock: exit ${rc}"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["gapps"]["set"]=="mtg11" else 1)' \
    "${MICROOS_ANDROID_STATE}/state.json" || fail "a held state lock: the write was lost: $(cat "${MICROOS_ANDROID_STATE}/state.json")"
kill "${holder}"
wait "${holder}" 2>/dev/null || true
unset holder

[[ "${failures}" == 0 ]] || exit 1
echo "state-test: ok"
