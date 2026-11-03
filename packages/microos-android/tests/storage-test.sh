#!/usr/bin/bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/data/usr/libexec/microos"
lib="${libexec}/microos-lepton-lib.sh"
cli="${repo}/data/usr/bin/microos-android"
check="${libexec}/microos-android-check"

T=$(mktemp -d)
trap 'chmod -R u+w "${T}" 2>/dev/null; rm -rf "${T}"' EXIT
export STATE="${T}/state"
mkdir -p "${STATE}" "${T}/bin" "${T}/home" "${T}/content" "${T}/ctxs" "${T}/reviewed" "${T}/snaps"

export HOME="${T}/home"
export MICROOS_HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/home/.config"
export XDG_DATA_HOME="${T}/home/.local/share"
export XDG_STATE_HOME="${T}/home/.local/state"
export MICROOS_ANDROID_STATE="${T}/home/.local/state/microos-android"
export MICROOS_ANDROID_DATA="${T}/data"
export MICROOS_ANDROID_CONTEXT="${T}/ctxs/android"
export MICROOS_CONTENT="${T}/content"
export MICROOS_SYSTEM_CARD="${T}/run/system-card"
export MICROOS_LEPTON_REVIEWED="${T}/reviewed"
export MICROOS_LEPTON_SNAPSHOTS="${T}/snaps"
export MICROOS_TEST=1
export MICROOS_ANDROID_UID="$(id -u)"
run_script="${libexec}/microos-android-run"
export CONTEXT="${MICROOS_ANDROID_CONTEXT}"
mkdir -p "${MICROOS_ANDROID_STATE}" "${T}/run"

cat > "${T}/bin/findmnt" <<'STUB'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${STATE}/findmnt"
last=${!#}
row=
while IFS='|' read -r key value; do
    [[ "${key}" != "${last}" ]] || row=${value}
done < "${STATE}/mounts" 2>/dev/null
[[ -n "${row}" ]] || exit 1
case "$*" in
    *--mountpoint*) printf '%s\n' "${row}" ;;
    *) IFS=' ' read -r type uuid options <<< "${row}"; printf '%s %s %s\n' "${uuid}" "${type}" "${options}" ;;
esac
STUB
cat > "${T}/bin/lsattr" <<'STUB'
#!/usr/bin/bash
last=${!#}
flag=$(cat "${STATE}/flags" 2>/dev/null) || flag=
name=${last##*/}
value=
while IFS='|' read -r key val; do
    [[ "${key}" != "${name}" ]] || value=${val}
done <<< "${flag}"
printf '%-22s%s\n' "${value:--}" "${last}"
STUB
cat > "${T}/bin/chattr" <<'STUB'
#!/usr/bin/bash
printf 'chattr %s\n' "$*" >> "${STATE}/chattr"
last=${!#}
name=${last##*/}
[[ "${1:-}" == -F ]] || exit 1
[[ ! -f "${STATE}/flags" ]] || sed -i "\|^${name}|d" "${STATE}/flags"
STUB
cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
[[ "${1:-}" == --user ]] && shift
[[ "${1:-}" == show ]] || exit 0
cat "${STATE}/unit" 2>/dev/null || echo inactive
STUB
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
printf 'podman %s\n' "$*" >> "${STATE}/podman"
case "${1:-}" in
    unshare)
        [[ "${2:-}" != bash ]] || printf '%s\n' "${!#}" >> "${STATE}/manifests"
        shift
        exec "$@"
        ;;
    inspect)
        [[ ! -e "${STATE}/docker-fail" ]] || exit 125
        case "$*" in
            *.State.Status*) cat "${STATE}/status" 2>/dev/null || exit 125 ;;
            *) exit 125 ;;
        esac
        ;;
    ps)
        cat "${STATE}/ps" 2>/dev/null
        ;;
    container)
        exit 1
        ;;
    *) exit 99 ;;
esac
STUB
cat > "${T}/bin/stat" <<'STUB'
#!/usr/bin/bash
if [[ " $* " == *" -c %u "* ]]; then
    [[ ! -e "${STATE}/other-owner" ]] || { echo 4242; exit 0; }
fi
exec /usr/bin/stat "$@"
STUB
cat > "${T}/bin/cp" <<'STUB'
#!/usr/bin/bash
args=()
for arg in "$@"; do
    [[ "${arg}" != --reflink=always ]] || arg=--reflink=auto
    args+=("${arg}")
done
exec /usr/bin/cp "${args[@]}"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"

failures=0
case_name=
fail() { echo "FAIL ${case_name}: $*" >&2; failures=$((failures + 1)); }

mount() { printf '%s|%s\n' "$1" "$2" >> "${STATE}/mounts"; }
flag_on() { printf '%s|%s\n' "$1" "$2" >> "${STATE}/flags"; }

reset() {
    [[ ! -L "${MICROOS_CONTENT}" ]] || rm -f "${MICROOS_CONTENT}"
    chmod -R u+w "${T}/content" "${T}/ctxs" "${MICROOS_ANDROID_DATA}" 2>/dev/null
    rm -rf "${T}/content" "${T}/ctxs" "${MICROOS_ANDROID_DATA}" "${MICROOS_ANDROID_STATE}" "${MICROOS_SYSTEM_CARD}" "${T}/card"
    mkdir -p "${T}/content" "${T}/ctxs" "${MICROOS_ANDROID_DATA}" "${MICROOS_ANDROID_STATE}" "${T}/run"
    : > "${STATE}/mounts"
    : > "${STATE}/flags"
    : > "${STATE}/podman"
    : > "${STATE}/findmnt"
    : > "${STATE}/chattr"
    rm -f "${STATE}/status" "${STATE}/unit" "${STATE}/docker-fail" "${STATE}/ps"
    echo none > "${MICROOS_SYSTEM_CARD}"
    mount "${T}/content" "ext4 CARD1-0000 rw"
}

resolve() {
    rc=0
    out=$(bash -c '. "$1"; shift; storage_state "$@"' _ "${lib}" "$@" 2> "${STATE}/stderr") || rc=$?
    err=$(cat "${STATE}/stderr")
}

word() { printf '%s\n' "${out}" | sed -n 1p; }
folder() { printf '%s\n' "${out}" | sed -n 2p; }

context() {
    local id=${1:-0123456789abcdef}
    mkdir -p "${MICROOS_ANDROID_CONTEXT}"
    printf 'card=CARD1-0000\nstorage=%s\n' "${id}" > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
}

card_folder() {
    local id=${1:-0123456789abcdef}
    mkdir -p "${T}/content/MicroOS/Android/${id}"
}

word_is() {
    [[ "$(word)" == "$1" ]] || fail "expected $1, read $(word): ${err}"
}

lock_free() {
    local lock="${MICROOS_ANDROID_STATE}/storage.lock" n=0 fd
    [[ -e "${lock}" ]] || return 0
    until exec {fd}>>"${lock}" && flock -n -x "${fd}"; do
        exec {fd}>&-
        (( ++n < 100 )) || return 1
        sleep 0.05
    done
    exec {fd}>&-
}

reset
card_folder
context
resolve
word_is card
[[ "$(folder)" == "${T}/content/MicroOS/Android/0123456789abcdef" ]] || fail "the folder reads $(folder)"

resolve --locked
word_is card

case_name="moving"
reset
card_folder
context
bash -c 'exec 9>>"$1"; flock -x 9 && : > "$2"; while :; do sleep 0.05; done' \
    _ "${MICROOS_ANDROID_STATE}/storage.lock" "${STATE}/held" &
holder=$!
for _ in $(seq 1 100); do [[ -e "${STATE}/held" ]] && break; sleep 0.02; done
resolve
word_is moving
resolve --locked
word_is card
kill "${holder}" 2>/dev/null
wait "${holder}" 2>/dev/null
lock_free || fail "the lock was not released"

case_name="lock file absent"
reset
card_folder
context
rm -f "${MICROOS_ANDROID_STATE}/storage.lock"
resolve
word_is card
[[ ! -e "${MICROOS_ANDROID_STATE}/storage.lock" ]] || fail "the resolver made the lock file"

case_name="no card link"
reset
context
rm -rf "${T}/content"
resolve
word_is no-card
[[ -z "$(folder)" ]] || fail "no-card carried a folder"

case_name="dangling link"
reset
context
card_folder
mv "${T}/content" "${T}/card"
mount "${T}/card" "ext4 CARD1-0000 rw"
ln -s "${T}/card" "${MICROOS_CONTENT}"
resolve
word_is card
[[ "$(folder)" == "${T}/card/MicroOS/Android/0123456789abcdef" ]] || fail "the folder reads $(folder)"
rm -f "${MICROOS_CONTENT}"
ln -s "${T}/nowhere" "${MICROOS_CONTENT}"
resolve
word_is no-card
rm -f "${MICROOS_CONTENT}"
mv "${T}/card" "${T}/content"

case_name="not ext4"
reset
context
mount "${T}/content" "vfat CARD1-0000 rw"
resolve
word_is not-ext4

case_name="btrfs"
reset
context
mount "${T}/content" "btrfs CARD1-0000 rw"
resolve
word_is not-ext4

case_name="read only token"
reset
card_folder
context
mount "${T}/content" "ext4 CARD1-0000 rw,relatime,ro"
resolve
word_is read-only

case_name="emergency_ro token"
reset
card_folder
context
mount "${T}/content" "ext4 CARD1-0000 rw,emergency_ro"
resolve
word_is read-only

case_name="errors=remount-ro is not read only"
reset
card_folder
context
mount "${T}/content" "ext4 CARD1-0000 rw,errors=remount-ro,relatime"
resolve
word_is card

case_name="the row is asked for FS-OPTIONS only"
reset
card_folder
context
resolve > /dev/null
grep -q -- '-rno FSTYPE,UUID,FS-OPTIONS --mountpoint' "${STATE}/findmnt" || fail "the resolver asked for another field: $(cat "${STATE}/findmnt")"
grep -qE -- '-rno (^|,)OPTIONS' "${STATE}/findmnt" && fail "the resolver read OPTIONS: $(cat "${STATE}/findmnt")"

case_name="a card without a UUID"
reset
card_folder
context
mount "${T}/content" "ext4  ro"
resolve
word_is read-only

case_name="another card"
reset
card_folder
context
mount "${T}/content" "ext4 CARD2-0000 rw"
resolve
word_is other-card

case_name="folder missing"
reset
context
resolve
word_is folder-missing

case_name="folder is a link"
reset
card_folder
context
mkdir -p "${T}/elsewhere"
rm -rf "${T}/content/MicroOS/Android/0123456789abcdef"
ln -s "${T}/elsewhere" "${T}/content/MicroOS/Android/0123456789abcdef"
resolve
word_is folder-unusable

case_name="MicroOS is a link"
reset
card_folder
context
rm -rf "${T}/content/MicroOS"
mkdir -p "${T}/elsewhere"
ln -s "${T}/elsewhere" "${T}/content/MicroOS"
resolve
word_is folder-unusable

case_name="F flag on a component"
reset
card_folder
context
flag_on MicroOS F-------------
resolve
word_is folder-unusable

case_name="F on the id"
reset
card_folder
context
flag_on 0123456789abcdef -----F-------
resolve
word_is folder-unusable

case_name="comma in the path"
reset
card_folder
context
mv "${T}/content" "${T}/cont,ent"
mount "${T}/cont,ent" "ext4 CARD1-0000 rw"
MICROOS_CONTENT="${T}/cont,ent" resolve
word_is folder-unusable
rm -rf "${T}/cont,ent"

case_name="wrong owner"
reset
card_folder
context
: > "${STATE}/other-owner"
resolve
word_is folder-unusable
rm -f "${STATE}/other-owner"

case_name="folder is not its real path"
reset
card_folder
context
mkdir -p "${T}/content/elsewhere"
mv "${T}/content/MicroOS/Android/0123456789abcdef" "${T}/content/real-id"
ln -s "${T}/content/real-id" "${T}/content/MicroOS/Android/0123456789abcdef"
resolve
word_is folder-unusable
rm -f "${T}/content/MicroOS/Android/0123456789abcdef"
mv "${T}/content/real-id" "${T}/content/MicroOS/Android/0123456789abcdef"

case_name="good folder"
reset
card_folder
context
resolve
word_is card
[[ "$(folder)" == "${T}/content/MicroOS/Android/0123456789abcdef" ]] || fail "the folder reads $(folder)"

case_name="system card flag, on the SD install"
reset
card_folder
context
echo mmcblk0 > "${MICROOS_SYSTEM_CARD}"
resolve
word_is no-card

case_name="on-os-card"
reset
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external"
rm -f "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
echo mmcblk0 > "${MICROOS_SYSTEM_CARD}"
resolve
word_is on-os-card
[[ "$(folder)" == "${MICROOS_ANDROID_CONTEXT}/external" ]] || fail "the folder reads $(folder)"

case_name="flag none, context there"
reset
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
resolve
word_is on-internal

case_name="tie without card"
reset
card_folder
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
printf 'storage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
resolve
word_is on-internal

case_name="no context, card words"
reset
resolve
word_is card
[[ "$(folder)" == "${T}/content/MicroOS/Android" ]] || fail "the new context folder reads $(folder)"

case_name="no context, no card"
reset
rm -rf "${T}/content"
resolve
word_is no-card

case_name="no context, not ext4"
reset
mount "${T}/content" "exfat CARD1-0000 rw"
resolve
word_is not-ext4

case_name="no context, read only"
reset
mount "${T}/content" "ext4 CARD1-0000 ro"
resolve
word_is read-only

case_name="no context, unusable MicroOS"
reset
mkdir -p "${T}/content/MicroOS"
flag_on MicroOS F-------------
resolve
word_is folder-unusable

case_name="no context, unusable Android dir"
reset
mkdir -p "${T}/content/MicroOS/Android"
flag_on Android F-------------
resolve
word_is folder-unusable

case_name="flag absent, immediate"
reset
rm -f "${MICROOS_SYSTEM_CARD}"
start=$(date +%s%N)
resolve
word_is card
[[ -z "${err}" ]] || fail "the immediate read logged: ${err}"
end=$(date +%s%N)
(( (end - start) / 1000000 < 400 )) || fail "the immediate read waited $(( (end - start) / 1000000 )) ms"

case_name="flag absent, --wait"
reset
rm -f "${MICROOS_SYSTEM_CARD}"
start=$(date +%s%N)
resolve --wait
word_is card
grep -q "system card flag not decided" "${STATE}/stderr" || fail "no log line: ${err}"
end=$(date +%s%N)
ms=$(( (end - start) / 1000000 ))
(( ms >= 400 && ms < 2000 )) || fail "the wait took ${ms} ms"

case_name="flag arrives during --wait"
reset
rm -f "${MICROOS_SYSTEM_CARD}"
( sleep 0.15; echo mmcblk0 > "${MICROOS_SYSTEM_CARD}" ) &
waiter=$!
resolve --wait
wait "${waiter}"
word_is on-os-card

case_name="flag other content"
reset
echo CARD1-0000 > "${MICROOS_SYSTEM_CARD}"
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
resolve
word_is on-internal
grep -q "system card flag reads CARD1-0000" "${STATE}/stderr" || fail "no log line: ${err}"

case_name="flag empty"
reset
: > "${MICROOS_SYSTEM_CARD}"
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
resolve
word_is on-internal
grep -q "system card flag is empty" "${STATE}/stderr" || fail "no log line: ${err}"

case_name="flag is a link"
reset
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
echo mmcblk0 > "${T}/run/real-card"
rm -f "${MICROOS_SYSTEM_CARD}"
ln -s "${T}/run/real-card" "${MICROOS_SYSTEM_CARD}"
resolve
word_is on-internal
grep -q "system card flag is a link" "${STATE}/stderr" || fail "no log line: ${err}"

case_name="first match wins, other-card before folder"
reset
context
mount "${T}/content" "ext4 CARD2-0000 rw"
mkdir -p "${T}/content/MicroOS/Android/0123456789abcdef"
flag_on 0123456789abcdef F-------------
resolve
word_is other-card

case_name="first match wins, read only before other-card"
reset
context
mount "${T}/content" "ext4 CARD2-0000 ro"
resolve
word_is read-only

case_name="the check carries the word"
reset
printf 'x\n' > "${T}/reviewed/25772114"
mkdir -p "${T}/lib/steamapps/common/Lepton/images/rootfs/system" "${T}/lib/steamapps/common/Lepton/sysbake/system"
printf 'ro.build.version.sdk=30\n' > "${T}/lib/steamapps/common/Lepton/images/rootfs/system/build.prop"
mkdir -p "${T}/bin/o"
cat > "${T}/bin/o/lepton-dir" <<STUB
#!/usr/bin/bash
printf '%s\n' "${T}/lib/steamapps/common/Lepton"
STUB
chmod 0755 "${T}/bin/o/lepton-dir"
printf '"AppState"\n{\n\t"buildid"\t\t"25772114"\n\t"StateFlags"\t\t"4"\n}\n' > "${T}/lib/steamapps/appmanifest_3029110.acf"
context
mount "${T}/content" "ext4 CARD2-0000 rw"
mkdir -p "${T}/content/MicroOS/Android/0123456789abcdef"
rc=0
out=$(MICROOS_LEPTON_STEAM_DIR_CMD="${T}/bin/o/lepton-dir" "${check}" 2> "${STATE}/stderr") || rc=$?
[[ "${rc}" == 2 && "${out}" == other-card ]] || fail "the check: exit ${rc}, out ${out}: $(cat "${STATE}/stderr")"
mount "${T}/content" "ext4 CARD1-0000 rw"
echo mmcblk0 > "${MICROOS_SYSTEM_CARD}"
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external"
rm -f "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
rc=0
out=$(MICROOS_LEPTON_STEAM_DIR_CMD="${T}/bin/o/lepton-dir" "${check}" 2> "${STATE}/stderr") || rc=$?
[[ "${rc}" == 0 && -z "${out}" ]] || fail "the check on an SD install: exit ${rc}, out ${out}: $(cat "${STATE}/stderr")"

cli() {
    rc=0
    out=$("${cli}" "$@" 2> "${STATE}/stderr") || rc=$?
    err=$(cat "${STATE}/stderr")
}

tie() {
    cat "${MICROOS_ANDROID_CONTEXT}/microos-android-storage" 2>/dev/null
}

seed_stub() {
    mkdir -p "${MICROOS_ANDROID_CONTEXT}/external/sub"
    printf 'one\n' > "${MICROOS_ANDROID_CONTEXT}/external/a"
    printf 'two\n' > "${MICROOS_ANDROID_CONTEXT}/external/sub/b"
    ln -s a "${MICROOS_ANDROID_CONTEXT}/external/link"
}

on_internal() {
    mkdir -p "${MICROOS_ANDROID_CONTEXT}"
    printf 'storage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
}

case_name="verb guard, another uid"
reset
on_internal
seed_stub
MICROOS_ANDROID_UID=4242 cli storage move card
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "run as micro only" "${STATE}/stderr" || fail "no refusal: ${err}"
[[ "$(tie)" == "storage=0123456789abcdef" ]] || fail "the tie changed: $(tie)"

case_name="verb guard, the prepare unit active"
reset
on_internal
seed_stub
echo active > "${STATE}/unit"
cli storage move card
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "microos-lepton-prepare.service is running" "${STATE}/stderr" || fail "no refusal: ${err}"

case_name="verb guard, a live container"
reset
on_internal
seed_stub
echo running > "${STATE}/status"
cli storage move card
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "container lepton-android is running" "${STATE}/stderr" || fail "no refusal: ${err}"

case_name="verb guard, a run holds the lock"
reset
on_internal
seed_stub
bash -c 'exec 9>>"$1"; flock -s 9 && : > "$2"; while :; do sleep 0.05; done' \
    _ "${MICROOS_ANDROID_STATE}/storage.lock" "${STATE}/held" &
holder=$!
for _ in $(seq 1 100); do [[ -e "${STATE}/held" ]] && break; sleep 0.02; done
cli storage move card
kill "${holder}" 2>/dev/null
wait "${holder}" 2>/dev/null
lock_free || fail "the lock was not released"
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "another storage run holds" "${STATE}/stderr" || fail "no refusal: ${err}"

case_name="move card refuses on-os-card"
reset
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
printf 'storage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
echo mmcblk0 > "${MICROOS_SYSTEM_CARD}"
seed_stub
cli storage move card
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "storage reads on-os-card" "${STATE}/stderr" || fail "no refusal: ${err}"

case_name="move card refuses an empty stub"
reset
on_internal
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external"
cli storage move card
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "is empty, nothing to move" "${STATE}/stderr" || fail "no refusal: ${err}"

case_name="move card"
reset
on_internal
seed_stub
cli storage move card
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ "$(tie)" == $'card=CARD1-0000\nstorage=0123456789abcdef' ]] || fail "the tie: $(tie)"
folder="${T}/content/MicroOS/Android/0123456789abcdef"
[[ -f "${folder}/a" && -f "${folder}/sub/b" && -L "${folder}/link" ]] || fail "the copy: $(ls -A "${folder}")"
[[ "$(cat "${folder}/a")" == one ]] || fail "a's content"
[[ -z "$(ls -A "${MICROOS_ANDROID_CONTEXT}/external")" ]] || fail "the stub is not empty"
[[ "$(stat -c %a "${MICROOS_ANDROID_CONTEXT}/external")" == 555 ]] \
    || fail "the stub is $(stat -c %a "${MICROOS_ANDROID_CONTEXT}/external")"
[[ ! -e "${MICROOS_ANDROID_STATE}/storage-move" ]] || fail "the step file is left"
[[ ! -e "${folder}.tmp" ]] || fail "the temp folder is left"

case_name="move card, cut at copy"
reset
on_internal
seed_stub
mkdir -p "${T}/content/MicroOS/Android/0123456789abcdef.tmp"
printf 'junk\n' > "${T}/content/MicroOS/Android/0123456789abcdef.tmp/junk"
mkdir -p "${T}/content/MicroOS/Android/0123456789abcdef"
printf 'old\n' > "${T}/content/MicroOS/Android/0123456789abcdef/old"
printf 'verb=move-card\nid=0123456789abcdef\ncard=CARD1-0000\nstep=copy\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
cli storage move card
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
folder="${T}/content/MicroOS/Android/0123456789abcdef"
[[ ! -e "${folder}/old" && ! -e "${folder}/junk" ]] || fail "a leftover was kept: $(ls -A "${folder}")"
[[ -f "${folder}/a" ]] || fail "the copy is not there: $(ls -A "${folder}")"

case_name="move card, cut at renamed with the tie written"
reset
on_internal
seed_stub
folder="${T}/content/MicroOS/Android/0123456789abcdef"
mkdir -p "${folder}"
printf 'kept\n' > "${folder}/kept"
printf 'card=CARD1-0000\nstorage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
printf 'verb=move-card\nid=0123456789abcdef\ncard=CARD1-0000\nstep=renamed\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
cli storage move card
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ -f "${folder}/kept" ]] || fail "the folder was copied again: $(ls -A "${folder}")"
[[ -z "$(ls -A "${MICROOS_ANDROID_CONTEXT}/external")" ]] || fail "the stub is not emptied"

case_name="move card, cut at emptying"
reset
on_internal
seed_stub
folder="${T}/content/MicroOS/Android/0123456789abcdef"
mkdir -p "${folder}"
mkdir -p "${folder}.tmp"
printf 'kept\n' > "${folder}/kept"
rm -rf "${folder}.tmp"
podman unshare bash -c '. "$1"; shift; storage_manifest "$@"' _ "${lib}" "${folder}" \
    > "${MICROOS_ANDROID_STATE}/storage-move.manifest"
printf 'card=CARD1-0000\nstorage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
printf 'verb=move-card\nid=0123456789abcdef\ncard=CARD1-0000\nstep=emptying\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
rm -f "${MICROOS_ANDROID_CONTEXT}/external/a"
cli storage move card
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ -f "${folder}/kept" && ! -e "${folder}/a" ]] || fail "the emptying copied: $(ls -A "${folder}")"
[[ -z "$(ls -A "${MICROOS_ANDROID_CONTEXT}/external")" ]] || fail "the stub is not emptied"

case_name="move card, cut at emptying with an empty stub"
reset
on_internal
seed_stub
folder="${T}/content/MicroOS/Android/0123456789abcdef"
mkdir -p "${folder}"
printf 'kept\n' > "${folder}/kept"
podman unshare bash -c '. "$1"; shift; storage_manifest "$@"' _ "${lib}" "${folder}" \
    > "${MICROOS_ANDROID_STATE}/storage-move.manifest"
printf 'card=CARD1-0000\nstorage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
printf 'verb=move-card\nid=0123456789abcdef\ncard=CARD1-0000\nstep=emptying\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
find "${MICROOS_ANDROID_CONTEXT}/external" -mindepth 1 -delete
chmod 0755 "${MICROOS_ANDROID_CONTEXT}/external"
cli storage move card
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ -f "${folder}/kept" ]] || fail "the emptying copied: $(ls -A "${folder}")"
[[ "$(stat -c %a "${MICROOS_ANDROID_CONTEXT}/external")" == 555 ]] \
    || fail "the stub is $(stat -c %a "${MICROOS_ANDROID_CONTEXT}/external"), not 0555"

case_name="move card, the card folder deleted at tie"
reset
on_internal
seed_stub
folder="${T}/content/MicroOS/Android/0123456789abcdef"
podman unshare bash -c '. "$1"; shift; storage_manifest "$@"' _ "${lib}" "${folder}" 2>/dev/null \
    > "${MICROOS_ANDROID_STATE}/storage-move.manifest"
printf 'storage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
printf 'verb=move-card\nid=0123456789abcdef\ncard=CARD1-0000\nstep=tie\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
cli storage move card
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "is missing or fails its check" "${STATE}/stderr" || fail "no refusal: ${err}"
[[ ! -e "${folder}" ]] || fail "an empty card folder was made"
[[ -f "${MICROOS_ANDROID_CONTEXT}/external/a" ]] || fail "the stub was emptied"
[[ "$(sed -n 's/^step=//p' "${MICROOS_ANDROID_STATE}/storage-move")" == tie ]] || fail "the step was cleared"

case_name="move card, an existing folder on a fresh start"
reset
on_internal
seed_stub
folder="${T}/content/MicroOS/Android/0123456789abcdef"
mkdir -p "${folder}"
printf 'kept\n' > "${folder}/kept"
cli storage move card
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ -f "${folder}/a" && ! -e "${folder}/kept" ]] || fail "the copy: $(ls -A "${folder}")"
grep -q "removed the existing ${folder}" <<< "${out}" || fail "the removal was not printed: ${out}"

case_name="move card, manifest mismatch"
reset
on_internal
seed_stub
cat > "${T}/bin/rsync" <<'STUB'
#!/usr/bin/bash
dest=${!#}
/usr/bin/rsync "$@"
printf 'changed\n' > "${dest%/}/changed"
STUB
chmod 0755 "${T}/bin/rsync"
cli storage move card
rm -f "${T}/bin/rsync"
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "is not the recorded source" <<< "${out}" || fail "no refusal: ${out}"
[[ "$(sed -n 's/^step=//p' "${MICROOS_ANDROID_STATE}/storage-move")" == copy ]] \
    || fail "the step: $(cat "${MICROOS_ANDROID_STATE}/storage-move")"
[[ "$(tie)" == "storage=0123456789abcdef" ]] || fail "the tie changed: $(tie)"
folder="${T}/content/MicroOS/Android/0123456789abcdef"
[[ ! -e "${folder}" ]] || fail "the folder was renamed in"
[[ -f "${MICROOS_ANDROID_CONTEXT}/external/a" ]] || fail "the stub lost its files"

case_name="context creation, the tie names the folder"
reset
rm -rf "${MICROOS_ANDROID_CONTEXT}"
card_folder
mkdir -p "${MICROOS_ANDROID_CONTEXT}.tmp"
printf 'card=CARD1-0000\nstorage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}.tmp/microos-android-storage"
run_create() {
    rc=0
    out=$(bash -c '
        . "$1"
        reason() { fail "$*"; }
        eval "$(sed -n "/^context_create()/,/^}/p" "$2")"
        context_create' _ "${lib}" "${run_script}" 2> "${STATE}/stderr") || rc=$?
    err=$(cat "${STATE}/stderr")
}
run_create
[[ "${rc}" == 0 ]] || fail "the creation: exit ${rc}: ${err}"
new_id=$(sed -n 's/^storage=//p' "${MICROOS_ANDROID_CONTEXT}/microos-android-storage")
[[ "$(stat -c %a "${MICROOS_ANDROID_CONTEXT}/external")" == 555 ]] \
    || fail "the stub is $(stat -c %a "${MICROOS_ANDROID_CONTEXT}/external" 2>/dev/null)"
[[ "$(stat -c %a "${T}/content/MicroOS/Android/${new_id}")" == 770 ]] \
    || fail "the card folder is $(stat -c %a "${T}/content/MicroOS/Android/${new_id}" 2>/dev/null)"
[[ ! -e "${MICROOS_ANDROID_CONTEXT}.tmp" ]] || fail "the temp dir is left"
[[ ! -e "${T}/content/MicroOS/Android/0123456789abcdef" ]] || fail "the stale card folder is left"

case_name="context creation, a stale id that is not hex"
reset
rm -rf "${MICROOS_ANDROID_CONTEXT}"
card_folder
mkdir -p "${T}/content/victim" "${MICROOS_ANDROID_CONTEXT}.tmp"
printf 'card=CARD1-0000\nstorage=../../victim\n' > "${MICROOS_ANDROID_CONTEXT}.tmp/microos-android-storage"
run_create
[[ "${rc}" == 0 ]] || fail "the creation: exit ${rc}: ${err}"
[[ -d "${T}/content/victim" ]] || fail "the stale id removed ${T}/content/victim"
[[ ! -e "${MICROOS_ANDROID_CONTEXT}.tmp" ]] || fail "the temp dir is left"

case_name="move card, the step file holds the failed step"
reset
on_internal
seed_stub
cat > "${T}/bin/rsync" <<'STUB'
#!/usr/bin/bash
exit 1
STUB
chmod 0755 "${T}/bin/rsync"
cli storage move card
rm -f "${T}/bin/rsync"
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
[[ "$(sed -n 's/^step=//p' "${MICROOS_ANDROID_STATE}/storage-move")" == copy ]] \
    || fail "the step: $(cat "${MICROOS_ANDROID_STATE}/storage-move")"
grep -qx "verb=move-card" "${MICROOS_ANDROID_STATE}/storage-move" || fail "the verb: $(cat "${MICROOS_ANDROID_STATE}/storage-move")"

grep -q "^manifest=" "${MICROOS_ANDROID_STATE}/storage-move" || fail "the manifest path: $(cat "${MICROOS_ANDROID_STATE}/storage-move")"
case_name="move card, the renamed step is written before the rename"
reset
on_internal
seed_stub
: > "${STATE}/moved"
cat > "${T}/bin/mv" <<STUB
#!/usr/bin/bash
dest=\${!#}
case "\${dest}" in
    */MicroOS/Android/*)
        case "\${dest}" in
            *.tmp) ;;
            *)
                grep -qx "step=renamed" "${MICROOS_ANDROID_STATE}/storage-move" \
                    || { echo "the step is not renamed" >&2; exit 1; }
                : > "${STATE}/moved"
                ;;
        esac
        ;;
esac
exec /usr/bin/mv "\$@"
STUB
chmod 0755 "${T}/bin/mv"
cli storage move card
rm -f "${T}/bin/mv"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ -e "${STATE}/moved" ]] || fail "mv did not run"

case_name="move card, no space"
reset
on_internal
seed_stub
MICROOS_STORAGE_MARGIN=99999999999999 cli storage move card
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "do not fit" "${STATE}/stderr" || fail "no refusal: ${err}"

case_name="move internal"
reset
card_folder
context
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external"
chmod 0555 "${MICROOS_ANDROID_CONTEXT}/external"
printf 'inner\n' > "${T}/content/MicroOS/Android/0123456789abcdef/inner"
cli storage move internal
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ "$(tie)" == "storage=0123456789abcdef" ]] || fail "the tie: $(tie)"
[[ "$(cat "${MICROOS_ANDROID_CONTEXT}/external/inner")" == inner ]] \
    || fail "the copy: $(ls -A "${MICROOS_ANDROID_CONTEXT}/external")"
[[ ! -e "${T}/content/MicroOS/Android/0123456789abcdef" ]] || fail "the card folder is left"
[[ ! -e "${MICROOS_ANDROID_STATE}/storage-move" ]] || fail "the step file is left"

case_name="move internal, keep card"
reset
card_folder
context
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external"
printf 'inner\n' > "${T}/content/MicroOS/Android/0123456789abcdef/inner"
cli storage move internal --keep-card
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ -f "${T}/content/MicroOS/Android/0123456789abcdef/inner" ]] || fail "the card folder was removed"

case_name="move internal, seed"
reset
card_folder
context
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external" "${T}/seed"
printf 'inner\n' > "${T}/content/MicroOS/Android/0123456789abcdef/inner"
printf 'seeded\n' > "${T}/seed/seeded"
: > "${STATE}/seed"
cat > "${T}/bin/cp" <<STUB
#!/usr/bin/bash
printf 'cp %s\n' "\$*" >> "${STATE}/seed"
args=()
for arg in "\$@"; do
    [[ "\${arg}" != --reflink=always ]] || arg=--reflink=auto
    args+=("\${arg}")
done
exec /usr/bin/cp "\${args[@]}"
STUB
chmod 0755 "${T}/bin/cp"
cli storage move internal --seed "${T}/seed"
rm -f "${T}/bin/cp"
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
grep -q -- "--reflink=always" "${STATE}/seed" || fail "no reflink: $(cat "${STATE}/seed")"
[[ -f "${MICROOS_ANDROID_CONTEXT}/external/inner" ]] \
    || fail "the copy: $(ls -A "${MICROOS_ANDROID_CONTEXT}/external")"
[[ ! -e "${MICROOS_ANDROID_CONTEXT}/external/seeded" ]] || fail "the seed's extra file survived --delete"

case_name="move internal, cut at copy"
reset
card_folder
context
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external"
printf 'inner\n' > "${T}/content/MicroOS/Android/0123456789abcdef/inner"
podman unshare bash -c '. "$1"; shift; storage_manifest "$@"' _ "${lib}" \
    "${T}/content/MicroOS/Android/0123456789abcdef" > "${MICROOS_ANDROID_STATE}/storage-move.manifest"
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external.tmp"
printf 'junk\n' > "${MICROOS_ANDROID_CONTEXT}/external.tmp/junk"
printf 'verb=move-internal\nid=0123456789abcdef\ncard=CARD1-0000\nkeep-card=0\nstep=copy\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
cli storage move internal
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ ! -e "${MICROOS_ANDROID_CONTEXT}/external/junk" ]] || fail "the junk was kept"
[[ -f "${MICROOS_ANDROID_CONTEXT}/external/inner" ]] || fail "the copy"

case_name="move internal, cut at swapped"
reset
card_folder
context
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external" "${MICROOS_ANDROID_CONTEXT}/external.tmp"
printf 'copied\n' > "${MICROOS_ANDROID_CONTEXT}/external.tmp/copied"
podman unshare bash -c '. "$1"; shift; storage_manifest "$@"' _ "${lib}" \
    "${T}/content/MicroOS/Android/0123456789abcdef" > "${MICROOS_ANDROID_STATE}/storage-move.manifest"
printf 'verb=move-internal\nid=0123456789abcdef\ncard=CARD1-0000\nkeep-card=0\nstep=swapped\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
cli storage move internal
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ -f "${MICROOS_ANDROID_CONTEXT}/external/copied" ]] \
    || fail "the swapped copy: $(ls -A "${MICROOS_ANDROID_CONTEXT}/external")"
[[ "$(tie)" == "storage=0123456789abcdef" ]] || fail "the tie: $(tie)"
[[ ! -e "${T}/content/MicroOS/Android/0123456789abcdef" ]] || fail "the card folder is left"

case_name="move internal, cut at removing-card"
reset
card_folder
context
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external"
printf 'inner\n' > "${T}/content/MicroOS/Android/0123456789abcdef/inner"
printf 'storage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
printf 'verb=move-internal\nid=0123456789abcdef\ncard=CARD1-0000\nkeep-card=0\nstep=removing-card\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
cli storage move internal
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ ! -e "${T}/content/MicroOS/Android/0123456789abcdef" ]] || fail "the removal did not run"
[[ -z "$(ls -A "${MICROOS_ANDROID_CONTEXT}/external")" ]] || fail "it copied on a removal rerun"

case_name="move internal, cut at tie"
reset
card_folder
context
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external"
printf 'inner\n' > "${T}/content/MicroOS/Android/0123456789abcdef/inner"
podman unshare bash -c '. "$1"; shift; storage_manifest "$@"' _ "${lib}" \
    "${T}/content/MicroOS/Android/0123456789abcdef" > "${MICROOS_ANDROID_STATE}/storage-move.manifest"
printf 'storage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
printf 'verb=move-internal\nid=0123456789abcdef\ncard=CARD1-0000\nkeep-card=0\nstep=tie\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
MICROOS_STORAGE_MARGIN=99999999999999 cli storage move internal
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ "$(tie)" == "storage=0123456789abcdef" ]] || fail "the tie: $(tie)"
[[ ! -e "${T}/content/MicroOS/Android/0123456789abcdef" ]] || fail "the card folder is left"

case_name="move internal, the temp gone at swapped"
reset
card_folder
context
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external"
printf 'copied\n' > "${MICROOS_ANDROID_CONTEXT}/external/copied"
podman unshare bash -c '. "$1"; shift; storage_manifest "$@"' _ "${lib}" \
    "${T}/content/MicroOS/Android/0123456789abcdef" > "${MICROOS_ANDROID_STATE}/storage-move.manifest"
printf 'verb=move-internal\nid=0123456789abcdef\ncard=CARD1-0000\nkeep-card=0\nstep=swapped\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
MICROOS_STORAGE_MARGIN=99999999999999 cli storage move internal
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ -f "${MICROOS_ANDROID_CONTEXT}/external/copied" ]] \
    || fail "the swapped copy: $(ls -A "${MICROOS_ANDROID_CONTEXT}/external")"
[[ "$(tie)" == "storage=0123456789abcdef" ]] || fail "the tie: $(tie)"
[[ ! -e "${T}/content/MicroOS/Android/0123456789abcdef" ]] || fail "the card folder is left"

case_name="move internal, a non-hex tie id"
reset
card_folder
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external"
printf 'x\n' > "${MICROOS_ANDROID_CONTEXT}/external/x"
printf 'card=CARD1-0000\nstorage=../../etc\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
cli storage move internal
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "16 lowercase hex digits" "${STATE}/stderr" || fail "no refusal: ${err}"
[[ -d "${T}/content/MicroOS/Android/0123456789abcdef" ]] || fail "the card folder was touched"

case_name="move card, a non-hex tie id"
reset
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external"
printf 'x\n' > "${MICROOS_ANDROID_CONTEXT}/external/x"
printf 'storage=../../etc\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
cli storage move card
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "16 lowercase hex digits" "${STATE}/stderr" || fail "no refusal: ${err}"

case_name="move card, the rerun at tie with no space"
reset
on_internal
seed_stub
folder="${T}/content/MicroOS/Android/0123456789abcdef"
mkdir -p "${folder}"
printf 'kept\n' > "${folder}/kept"
podman unshare bash -c '. "$1"; shift; storage_manifest "$@"' _ "${lib}" "${folder}" \
    > "${MICROOS_ANDROID_STATE}/storage-move.manifest"
printf 'verb=move-card\nid=0123456789abcdef\ncard=CARD1-0000\nstep=tie\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
MICROOS_STORAGE_MARGIN=99999999999999 cli storage move card
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ -z "$(ls -A "${MICROOS_ANDROID_CONTEXT}/external")" ]] || fail "the stub is not emptied"

case_name="move card, the temp gone at renamed"
reset
on_internal
seed_stub
folder="${T}/content/MicroOS/Android/0123456789abcdef"
mkdir -p "${folder}"
podman unshare cp -a "${MICROOS_ANDROID_CONTEXT}/external/." "${folder}/"
podman unshare bash -c '. "$1"; shift; storage_manifest "$@"' _ "${lib}" \
    "${MICROOS_ANDROID_CONTEXT}/external" > "${MICROOS_ANDROID_STATE}/storage-move.manifest"
printf 'verb=move-card\nid=0123456789abcdef\ncard=CARD1-0000\nstep=renamed\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
cli storage move card
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ -f "${folder}/a" && -L "${folder}/link" ]] || fail "the folder was copied again: $(ls -A "${folder}")"
[[ -z "$(ls -A "${MICROOS_ANDROID_CONTEXT}/external")" ]] || fail "the stub is not emptied"

case_name="move card, the temp gone at renamed, the target differs"
reset
on_internal
seed_stub
folder="${T}/content/MicroOS/Android/0123456789abcdef"
mkdir -p "${folder}"
printf 'other\n' > "${folder}/other"
podman unshare bash -c '. "$1"; shift; storage_manifest "$@"' _ "${lib}" \
    "${MICROOS_ANDROID_CONTEXT}/external" > "${MICROOS_ANDROID_STATE}/storage-move.manifest"
printf 'verb=move-card\nid=0123456789abcdef\ncard=CARD1-0000\nstep=renamed\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
cli storage move card
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ -f "${folder}/a" && ! -e "${folder}/other" ]] || fail "the copy: $(ls -A "${folder}")"
[[ -z "$(ls -A "${MICROOS_ANDROID_CONTEXT}/external")" ]] || fail "the stub is not emptied"

case_name="move card, a tie-less rerun at tie reuses the step id"
reset
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
seed_stub
folder="${T}/content/MicroOS/Android/0123456789abcdef"
mkdir -p "${folder}"
printf 'kept\n' > "${folder}/kept"
podman unshare bash -c '. "$1"; shift; storage_manifest "$@"' _ "${lib}" "${folder}" \
    > "${MICROOS_ANDROID_STATE}/storage-move.manifest"
printf 'verb=move-card\nid=0123456789abcdef\ncard=CARD1-0000\nstep=tie\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
cli storage move card
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ "$(tie)" == $'card=CARD1-0000\nstorage=0123456789abcdef' ]] || fail "the tie: $(tie)"
[[ "$(ls -A "${T}/content/MicroOS/Android")" == 0123456789abcdef ]] \
    || fail "the folders: $(ls -A "${T}/content/MicroOS/Android")"
[[ "$(find "${folder}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)" == kept ]] \
    || fail "the copy: $(ls -A "${folder}")"
[[ -z "$(ls -A "${MICROOS_ANDROID_CONTEXT}/external")" ]] || fail "the stub is not emptied"

case_name="move card, a tie-less cut at tie with the folder changed"
reset
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
seed_stub
folder="${T}/content/MicroOS/Android/0123456789abcdef"
podman unshare bash -c '. "$1"; shift; storage_manifest "$@"' _ "${lib}" \
    "${MICROOS_ANDROID_CONTEXT}/external" > "${MICROOS_ANDROID_STATE}/storage-move.manifest"
mkdir -p "${folder}"
printf 'added later\n' > "${folder}/added"
printf 'verb=move-card\nid=0123456789abcdef\ncard=CARD1-0000\nstep=tie\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
cli storage move card
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ -f "${folder}/a" && ! -e "${folder}/added" ]] || fail "the copy: $(ls -A "${folder}")"
[[ "$(ls -A "${T}/content/MicroOS/Android")" == 0123456789abcdef ]] \
    || fail "the folders: $(ls -A "${T}/content/MicroOS/Android")"
[[ -z "$(ls -A "${MICROOS_ANDROID_CONTEXT}/external")" ]] || fail "the stub is not emptied"

case_name="move card, the folder changed after the tie names it"
reset
on_internal
seed_stub
folder="${T}/content/MicroOS/Android/0123456789abcdef"
mkdir -p "${folder}"
printf 'kept\n' > "${folder}/kept"
podman unshare bash -c '. "$1"; shift; storage_manifest "$@"' _ "${lib}" "${folder}" \
    > "${MICROOS_ANDROID_STATE}/storage-move.manifest"
printf 'added later\n' > "${folder}/added"
printf 'card=CARD1-0000\nstorage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
printf 'verb=move-card\nid=0123456789abcdef\ncard=CARD1-0000\nstep=tie\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
cli storage move card
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "changed after the tie was written" "${STATE}/stderr" || fail "no refusal: ${err}"
grep -q "storage move internal" "${STATE}/stderr" || fail "no way out named: ${err}"
[[ -f "${folder}/added" ]] || fail "the folder was removed"
[[ "$(sed -n 's/^step=//p' "${MICROOS_ANDROID_STATE}/storage-move")" == tie ]] || fail "the step was cleared"
[[ -n "$(ls -A "${MICROOS_ANDROID_CONTEXT}/external")" ]] || fail "the stub was emptied"
cli storage move internal
[[ "${rc}" == 0 ]] || fail "move internal: exit ${rc}: ${err}"
cli storage move card
[[ "${rc}" == 0 ]] || fail "move card: exit ${rc}: ${err}"
[[ -f "${folder}/added" ]] || fail "the added file was lost: $(ls -A "${folder}")"

case_name="move card, a move-internal step file"
reset
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
seed_stub
printf 'verb=move-internal\nid=0123456789abcdef\ncard=CARD1-0000\nkeep-card=0\nstep=manifest\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
cli storage move card
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ "$(sed -n 's/^storage=//p' "${MICROOS_ANDROID_CONTEXT}/microos-android-storage")" != 0123456789abcdef ]] \
    || fail "the move internal step file's id was taken"

case_name="move card, a step file id that is not hex"
reset
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
seed_stub
printf 'verb=move-card\nid=../../etc\ncard=CARD1-0000\nstep=tie\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
cli storage move card
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
new_id=$(sed -n 's/^storage=//p' "${MICROOS_ANDROID_CONTEXT}/microos-android-storage")
[[ "${new_id}" =~ ^[0-9a-f]{16}$ ]] || fail "the id: ${new_id}"
[[ "$(ls -A "${T}/content/MicroOS/Android")" == "${new_id}" ]] \
    || fail "the folders: $(ls -A "${T}/content/MicroOS/Android")"

case_name="move card, a stale card in the step file"
reset
on_internal
seed_stub
mkdir -p "${T}/content/MicroOS/Android/deadbeefdeadbeef"
printf 'verb=move-card\nid=deadbeefdeadbeef\ncard=CARD2-0000\nstep=tie\nmanifest=%s\n' \
    "${MICROOS_ANDROID_STATE}/storage-move.manifest" > "${MICROOS_ANDROID_STATE}/storage-move"
cli storage move card
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
new_id=$(sed -n 's/^storage=//p' "${MICROOS_ANDROID_CONTEXT}/microos-android-storage")
[[ "${new_id}" =~ ^[0-9a-f]{16}$ ]] || fail "the id: ${new_id}"
[[ "${new_id}" != deadbeefdeadbeef ]] || fail "the step file's id was taken on another card"
[[ -d "${T}/content/MicroOS/Android/${new_id}" ]] || fail "the new folder: $(ls -A "${T}/content/MicroOS/Android")"
[[ -d "${T}/content/MicroOS/Android/deadbeefdeadbeef" ]] || fail "the other folder was removed"

case_name="move internal, a fresh start records the manifest once"
reset
card_folder
context
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external"
printf 'inner\n' > "${T}/content/MicroOS/Android/0123456789abcdef/inner"
: > "${STATE}/manifests"
cli storage move internal
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ "$(grep -cxF "${T}/content/MicroOS/Android/0123456789abcdef" "${STATE}/manifests")" == 1 ]] \
    || fail "the card folder's manifest: $(cat "${STATE}/manifests")"
[[ -f "${MICROOS_ANDROID_CONTEXT}/external/inner" ]] || fail "the copy: $(ls -A "${MICROOS_ANDROID_CONTEXT}/external")"

case_name="the space check counts blocks"
reset
on_internal
seed_stub
out=$(bash -c '. "$1"; shift; storage_du "$@"' _ "${lib}" "${MICROOS_ANDROID_CONTEXT}/external" 2> "${STATE}/stderr") || out=
[[ "${out}" =~ ^[0-9]+$ ]] || fail "storage_du read ${out}: $(cat "${STATE}/stderr")"
[[ "${out}" -ge "$(du -s --block-size=1 "${MICROOS_ANDROID_CONTEXT}/external" | cut -f1)" ]] \
    || fail "storage_du read ${out} for $(du -s --block-size=1 "${MICROOS_ANDROID_CONTEXT}/external" | cut -f1) blocks"

case_name="new, without --yes"
reset
context
mount "${T}/content" "ext4 CARD2-0000 rw"
cli storage new
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "refusing without --yes" "${STATE}/stderr" || fail "no refusal: ${err}"

case_name="new, on card"
reset
card_folder
context
cli storage new --yes
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "storage reads card" "${STATE}/stderr" || fail "no refusal: ${err}"

case_name="new, on internal"
reset
on_internal
cli storage new --yes
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "storage reads on-internal" "${STATE}/stderr" || fail "no refusal: ${err}"

case_name="new, on the system card"
reset
mkdir -p "${MICROOS_ANDROID_CONTEXT}"
printf 'storage=0123456789abcdef\n' > "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
echo mmcblk0 > "${MICROOS_SYSTEM_CARD}"
cli storage new --yes
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "storage reads on-os-card" "${STATE}/stderr" || fail "no refusal: ${err}"

case_name="new, another card"
reset
context
mount "${T}/content" "ext4 CARD2-0000 rw"
cli storage new --yes
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
grep -qx 'card=CARD2-0000' "${MICROOS_ANDROID_CONTEXT}/microos-android-storage" || fail "the tie: $(tie)"
new_id=$(sed -n 's/^storage=//p' "${MICROOS_ANDROID_CONTEXT}/microos-android-storage")
[[ "${new_id}" =~ ^[0-9a-f]{16}$ && "${new_id}" != 0123456789abcdef ]] || fail "the new id: ${new_id}"
[[ -d "${T}/content/MicroOS/Android/${new_id}" ]] || fail "the new folder: $(ls -A "${T}/content/MicroOS/Android")"
[[ "$(printf '%s\n' "${out}" | sed -n '$p')" == "CARD1-0000:MicroOS/Android/0123456789abcdef" ]] \
    || fail "the printed folder: ${out}"

case_name="new, folder missing"
reset
context
cli storage new --yes
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ "$(sed -n 's/^storage=//p' "${MICROOS_ANDROID_CONTEXT}/microos-android-storage")" != 0123456789abcdef ]] \
    || fail "the id was kept"

case_name="prune, without --yes"
reset
card_folder
context
cli storage prune deadbeefdeadbeef
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "refusing without --yes" "${STATE}/stderr" || fail "no refusal: ${err}"

case_name="prune, the tie's own id"
reset
card_folder
context
cli storage prune 0123456789abcdef --yes
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "is this context's own shared storage" "${STATE}/stderr" || fail "no refusal: ${err}"
[[ -d "${T}/content/MicroOS/Android/0123456789abcdef" ]] || fail "it removed the tie's folder"

case_name="prune, on the system card"
reset
mkdir -p "${MICROOS_ANDROID_CONTEXT}/external"
rm -f "${MICROOS_ANDROID_CONTEXT}/microos-android-storage"
echo mmcblk0 > "${MICROOS_SYSTEM_CARD}"
cli storage prune deadbeefdeadbeef --yes
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "storage reads on-os-card" "${STATE}/stderr" || fail "no refusal: ${err}"

case_name="prune, a bad id"
reset
card_folder
context
cli storage prune ../etc --yes
[[ "${rc}" == 1 ]] || fail "exit ${rc}: ${err}"
grep -q "16 lowercase hex digits" "${STATE}/stderr" || fail "no refusal: ${err}"

case_name="prune"
reset
card_folder
context
mkdir -p "${T}/content/MicroOS/Android/deadbeefdeadbeef/inner"
printf 'x\n' > "${T}/content/MicroOS/Android/deadbeefdeadbeef/inner/f"
cli storage prune deadbeefdeadbeef --yes
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ ! -e "${T}/content/MicroOS/Android/deadbeefdeadbeef" ]] || fail "it was not removed"
[[ -d "${T}/content/MicroOS/Android/0123456789abcdef" ]] || fail "it removed another folder"

case_name="status lists another id"
reset
card_folder
context
mount "${T}/content" "ext4 CARD1-0000 rw"
mkdir -p "${T}/content/MicroOS/Android/deadbeefdeadbeef"
out=$("${cli}" status 2>/dev/null) || :
grep -qx $'storage\tcard' <<< "${out}" || fail "storage: ${out}"
grep -qx 'other deadbeefdeadbeef' <<< "${out}" || fail "the other folder: ${out}"
grep -q "other 0123456789abcdef" <<< "${out}" && fail "the tie's own id is listed: ${out}"

case_name="the tie is written by the verbs and creation only"
reset
on_internal
seed_stub
before=$(sha256sum "${MICROOS_ANDROID_CONTEXT}/microos-android-storage" | cut -d' ' -f1)
"${check}" > /dev/null 2>&1 || :
"${cli}" status > /dev/null 2>&1 || :
"${cli}" storage state > /dev/null 2>&1 || :
after=$(sha256sum "${MICROOS_ANDROID_CONTEXT}/microos-android-storage" | cut -d' ' -f1)
[[ "${before}" == "${after}" ]] || fail "the check, status or storage state rewrote the tie"
for file in microos-android-keyboard microos-android-sideload microos-android-stop \
    microos-android-client microos-android-session-watch microos-android-install microos-lepton microos-android-check; do
    grep -q "microos-android-storage" "${libexec}/${file}" && fail "${file} touches the tie"
done
grep -q "storage_tie_write" "${cli}" || fail "the verbs do not write the tie"


if (( failures )); then
    echo "storage-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "storage-test: ok"
