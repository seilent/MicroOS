#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
slot=$tree/usr/libexec/microos/microos-slot
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

ss=4096
A=2
B=3
img=$tmp/lun4.img
conf=$tmp/slot.conf

mk() {
  truncate -s 64M "$1"
  {
    echo "label: gpt"
    echo "size=1MiB, name=xbl_a"
    echo "size=1MiB, name=xbl_config_a"
    echo 'size=8MiB, name=boot_a, attrs="RequiredPartition,GUID:48,49,50,51,52,53,54,60"'
    echo 'size=8MiB, name=boot_b, attrs="LegacyBIOSBootable,GUID:48,51,52,55,57"'
    echo "size=1MiB, name=dtbo_a"
    echo "size=1MiB, name=dtbo_b"
    echo "size=4MiB, name=vendor_boot_a"
    echo "size=4MiB, name=vendor_boot_b"
    [[ -z ${2:-} ]] || echo "$2"
  } | sfdisk -q --sector-size "$ss" "$1"
}
u64() { od -An -tu8 -j "$2" -N8 "$1" | tr -d ' '; }
last() { echo $(($(stat -c %s "$1") / ss - 1)); }
hdr() { if [[ $2 == primary ]]; then echo "$ss"; else echo $(($(last "$1") * ss)); fi; }
attr() {
  local h
  h=$(hdr "$1" "$2")
  od -An -tx1 -j $(($(u64 "$1" $((h + 72))) * ss + $3 * 128 + 54)) -N1 "$1" | tr -d ' '
}
state() { echo "$(attr "$1" primary $A) $(attr "$1" backup $A) $(attr "$1" primary $B) $(attr "$1" backup $B)"; }
valid() {
  sfdisk --sector-size "$ss" --verify "$1" > /dev/null 2>&1 && [[ -z $(sfdisk --sector-size "$ss" --dump "$1" 2>&1 > /dev/null) ]]
}
flip() {
  local b
  b=$(od -An -tu1 -j "$2" -N1 "$1" | tr -d ' ')
  printf "\\x$(printf %02x $((b ^ 255)))" | dd of="$1" bs=1 seek="$2" conv=notrunc status=none
}
allowed() {
  local h e
  for c in primary backup; do
    h=$(hdr "$1" $c)
    e=$(($(u64 "$1" $((h + 72))) * ss))
    seq $((h + 16)) $((h + 19))
    seq $((h + 88)) $((h + 91))
    echo $((e + A * 128 + 54))
    echo $((e + B * 128 + 54))
  done > "$tmp/allowed"
}
outside() {
  python3 - "$1" "$2" "$tmp/allowed" << 'EOF'
import sys
a, b = (open(p, "rb").read() for p in sys.argv[1:3])
allowed = {int(x) for x in open(sys.argv[3]).read().split()}
n = abs(len(a) - len(b))
for o in range(0, min(len(a), len(b)), 65536):
    if a[o:o + 65536] != b[o:o + 65536]:
        n += sum(1 for i in range(o, min(o + 65536, len(a), len(b))) if a[i] != b[i] and i not in allowed)
print(n)
EOF
}
same() { [[ $(sha256sum < "$1") == $(sha256sum < "$2") ]]; }
run() {
  env MICROOS_SLOT_TEST=1 MICROOS_SLOT_DISKS="${DISKS:-boot_a=$img boot_b=$img}" MICROOS_SLOT_BLOCK_SIZE="${BS:-$ss}" \
    MICROOS_SLOT_CONF="$conf" MICROOS_SLOT_STATE="${STATE:-$tmp/gpt}" "$slot" "$@" > "$tmp/out" 2> "$tmp/err"
}
latest() { ls -d "$tmp"/gpt/pre-* 2> /dev/null | sort -V | tail -n 1 || true; }
saved_ok() {
  local f off
  [[ -n $1 && $(wc -l < "$1/offsets") == 4 ]] || return 1
  while read -r f off; do
    [[ $(sha256sum < "$1/$f") == $(tail -c +$((off + 1)) "$2" | head -c "$(stat -c %s "$1/$f")" | sha256sum) ]] || return 1
  done < "$1/offsets"
}
poke() {
  python3 - "$1" "$ss" "$2" "$3" "$4" << 'EOF'
import struct, sys, zlib
path, ss, copy, index, value = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), int(sys.argv[5], 16)
with open(path, "r+b") as f:
    f.seek(0, 2)
    h = ss if copy == "primary" else (f.tell() // ss - 1) * ss
    f.seek(h)
    hdr = bytearray(f.read(ss))
    elba, n, es = struct.unpack_from("<QII", hdr, 72)
    f.seek(elba * ss)
    e = bytearray(f.read(n * es))
    e[index * es + 54] = value
    struct.pack_into("<I", hdr, 88, zlib.crc32(e))
    hdr[16:20] = bytes(4)
    struct.pack_into("<I", hdr, 16, zlib.crc32(hdr[:struct.unpack_from("<I", hdr, 12)[0]]))
    f.seek(elba * ss)
    f.write(e)
    f.seek(h)
    f.write(hdr)
EOF
}
writes() { printf 'MICROOS_SLOT_WRITE=%s\nMICROOS_BOOT_TRIES=3\n' "$1" > "$conf"; }
has() { grep -qxF "$1" "$tmp/out" || fail "$2: no line '$1' in: $(cat "$tmp/out")"; }
step() {
  local want=$1 r=0 pre
  shift
  cp "$img" "$tmp/before.img"
  pre=$(latest)
  run "$@" || r=$?
  [[ $r == 0 ]] || fail "$*: exit $r: $(cat "$tmp/err")"
  [[ $(state "$img") == "$want" ]] || fail "$*: bytes $(state "$img"), want $want"
  [[ $(latest) != "$pre" ]] && saved_ok "$(latest)" "$tmp/before.img" || fail "$*: copies before the write not saved"
  [[ $(outside "$tmp/before.img" "$img") == 0 ]] || fail "$*: bytes changed outside the slot attributes and CRCs"
  valid "$img" || fail "$*: sfdisk sees a bad GPT"
  run status || fail "$*: status after: $(cat "$tmp/err")"
  has "gpt: ok" "$*"
}
sums() { sha256sum "$tmp"/*.img; }
refuse() {
  local name=$1 r=0 before
  shift
  before=$(sums)
  run "$@" || r=$?
  [[ $r == 1 ]] || fail "$name: exit $r"
  [[ $(sums) == "$before" ]] || fail "$name: an image changed"
  [[ $(cat "$tmp/err") == *"${WHY:-}"* ]] || fail "$name: $(cat "$tmp/err")"
}

mk "$img"
valid "$img" || fail "synthetic GPT is bad"
[[ $(state "$img") == "7f 7f 99 99" ]] || fail "initial bytes $(state "$img")"
allowed "$img"
cp "$img" "$tmp/start.img"

writes 0
run status || fail "status: exit $?: $(cat "$tmp/err")"
has "disk $(realpath "$img") block 4096" status
has "gpt: ok" status
has "a boot_a: active 1 priority 3 retry 7 successful 1 unbootable 0 (0x7f)" status
has "b boot_b: active 0 priority 1 retry 3 successful 0 unbootable 1 (0x99)" status

for w in 0 2 missing; do
  if [[ $w == missing ]]; then rm -f "$conf"; else writes "$w"; fi
  r=0
  run arm || r=$?
  [[ $r == 3 ]] || fail "arm with MICROOS_SLOT_WRITE=$w: exit $r"
  same "$img" "$tmp/start.img" || fail "arm with MICROOS_SLOT_WRITE=$w changed the disk"
done

writes 1
for a in "" "set" "set a" "set b" "mark-good" "arm b" "status x" "reset"; do
  r=0
  run $a || r=$?
  [[ $r == 2 ]] || fail "usage '$a': exit $r"
done
same "$img" "$tmp/start.img" || fail "usage errors changed the disk"

WHY="boot_b is not active" refuse "arm on an inactive boot_b" arm
for c in primary backup; do
  poke "$img" "$c" $A 78
  poke "$img" "$c" $B 37
done
[[ $(state "$img") == "78 78 37 37" ]] || fail "slot b active: bytes $(state "$img")"
cp "$img" "$tmp/onb.img"
step "78 78 3f 3f" arm
has "b boot_b: active 1 priority 3 retry 7 successful 0 unbootable 0 (0x3f)" "arm"
cp "$img" "$tmp/before.img"
pre=$(latest)
run arm || fail "arm again: $(cat "$tmp/err")"
same "$img" "$tmp/before.img" || fail "arm again wrote"
has "microos-slot: unchanged" "arm again"
[[ $(latest) == "$pre" ]] || fail "arm again saved the copies"
for c in primary backup; do
  poke "$img" "$c" $B ff
done
step "78 78 3f 3f" arm
[[ $(outside "$tmp/start.img" "$img") == 0 ]] || fail "bytes changed outside the slot attributes and CRCs since the start"

poke "$img" primary $B 37
[[ $(state "$img") == "78 78 37 3f" ]] || fail "ABL write: bytes $(state "$img")"
valid "$img" || fail "ABL write: sfdisk sees a bad GPT"
run status || fail "status after an ABL write: $(cat "$tmp/err")"
has "gpt: the backup differs in the slot attributes, the primary is current; arm rewrites both" "ABL write status"
has "b boot_b: active 1 priority 3 retry 6 successful 0 unbootable 0 (0x37)" "ABL write status"
has "b boot_b backup: active 1 priority 3 retry 7 successful 0 unbootable 0 (0x3f)" "ABL write status"
cp "$img" "$tmp/abl.img"
step "78 78 3f 3f" arm
cp "$tmp/abl.img" "$img"
poke "$img" backup $B 78
step "78 78 3f 3f" arm
cp "$tmp/onb.img" "$img"
poke "$img" primary $B 78
WHY="boot_b is not active" refuse "arm with boot_b inactive in the primary" arm

mk "$tmp/other.img"
mk "$tmp/lun0.img" "size=4MiB, name=microos"
DISKS="boot_a=$tmp/other.img boot_b=$img" WHY="not on one disk" refuse "boot_a on another disk" arm
DISKS="boot_a=$img boot_b=$img microos=$img" WHY="holds microos" refuse "microos on the disk" arm
DISKS="boot_a=$tmp/lun0.img boot_b=$tmp/lun0.img" WHY="disk holds microos" refuse "microos in the GPT" arm
DISKS="boot_a=$img" WHY="no boot_b" refuse "no boot_b" arm
DISKS="boot_a=$tmp/none boot_b=$tmp/none" refuse "missing disk" status
DISKS="boot_a $img" WHY="label=path" refuse "bad hook" status
BS=512 WHY="no header at LBA 1" refuse "512 byte blocks" status

cp "$tmp/onb.img" "$img"
bad=$tmp/bad.img
cp "$img" "$bad"
flip "$bad" $((2 * ss + 56))
[[ $(outside "$img" "$bad") == 1 ]] || fail "the outside check missed a flipped byte"
for c in "primary entries $((2 * ss + 56)) entry array CRC mismatch" \
  "primary header $((ss + 40)) header CRC mismatch" \
  "backup header $(($(last "$img") * ss + 16)) header CRC mismatch" \
  "backup entries $(($(u64 "$img" $(($(last "$img") * ss + 72))) * ss + A * 128 + 54)) entry array CRC mismatch"; do
  read -r copy part off why <<< "$c"
  cp "$img" "$bad"
  flip "$bad" "$off"
  same "$img" "$bad" && fail "corrupt $copy $part did not change the image"
  for a in status arm; do
    DISKS="boot_a=$bad boot_b=$bad" WHY="$copy GPT: $why" refuse "corrupt $copy $part, $a" $a
  done
done
cp "$img" "$bad"
python3 - "$bad" "$ss" << 'EOF'
import struct, sys, zlib
path, ss = sys.argv[1], int(sys.argv[2])
with open(path, "r+b") as f:
    f.seek(0, 2)
    h = (f.tell() // ss - 1) * ss
    f.seek(h)
    hdr = bytearray(f.read(ss))
    elba, n, es = struct.unpack_from("<QII", hdr, 72)
    f.seek(elba * ss)
    e = bytearray(f.read(n * es))
    e[56] ^= 1
    struct.pack_into("<I", hdr, 88, zlib.crc32(e))
    hdr[16:20] = bytes(4)
    struct.pack_into("<I", hdr, 16, zlib.crc32(hdr[:struct.unpack_from("<I", hdr, 12)[0]]))
    f.seek(elba * ss)
    f.write(e)
    f.seek(h)
    f.write(hdr)
EOF
valid "$bad" || fail "renamed backup entry: sfdisk sees a bad GPT"
DISKS="boot_a=$bad boot_b=$bad" WHY="differ outside the slot attributes" refuse "backup differs outside the attributes" arm
cp "$img" "$bad"
python3 - "$bad" "$ss" << 'EOF'
import struct, sys, zlib
path, ss = sys.argv[1], int(sys.argv[2])
with open(path, "r+b") as f:
    f.seek(0, 2)
    h = (f.tell() // ss - 1) * ss
    f.seek(h)
    hdr = bytearray(f.read(ss))
    hdr[10] ^= 1
    hdr[16:20] = bytes(4)
    struct.pack_into("<I", hdr, 16, zlib.crc32(hdr[:struct.unpack_from("<I", hdr, 12)[0]]))
    f.seek(h)
    f.write(hdr)
EOF
for a in status arm; do
  DISKS="boot_a=$bad boot_b=$bad" WHY="primary and backup GPT headers differ" refuse "backup header revision differs, $a" $a
done

cp "$tmp/onb.img" "$tmp/torn.img"
cp "$tmp/torn.img" "$img"
r=0
MICROOS_SLOT_FAIL=after-backup run arm || r=$?
[[ $r == 1 && $(cat "$tmp/err") == *"fail point"* ]] || fail "torn arm: exit $r: $(cat "$tmp/err")"
[[ $(state "$img") == "78 78 37 3f" ]] || fail "torn arm: bytes $(state "$img")"
valid "$img" || fail "torn arm: sfdisk sees a bad GPT"
run status || fail "status of a torn write: exit $?: $(cat "$tmp/err")"
has "gpt: the backup differs in the slot attributes, the primary is current; arm rewrites both" "torn status"
has "b boot_b: active 1 priority 3 retry 6 successful 0 unbootable 0 (0x37)" "torn status"
has "b boot_b backup: active 1 priority 3 retry 7 successful 0 unbootable 0 (0x3f)" "torn status"
step "78 78 3f 3f" arm
[[ $(outside "$tmp/torn.img" "$img") == 0 ]] || fail "repair by arm: bytes changed outside the slot attributes and CRCs"

for c in backup primary; do
  cp "$tmp/onb.img" "$img"
  r=0
  MICROOS_SLOT_FAIL=corrupt-$c run arm || r=$?
  [[ $r == 1 && $(cat "$tmp/err") == *"$c read back differs from the write, both copies restored"* ]] \
    || fail "corrupt $c write: exit $r: $(cat "$tmp/err")"
  same "$img" "$tmp/onb.img" || fail "corrupt $c write: saved copies not restored, bytes $(state "$img")"
  saved_ok "$(latest)" "$tmp/onb.img" || fail "corrupt $c write: saved copies differ from the disk before"
done

rm -rf "$tmp/gpt"
mkdir -p "$tmp/gpt/live-202611120000"
for n in $(seq 1 12); do mkdir "$tmp/gpt/pre-$n"; done
cp "$tmp/onb.img" "$img"
run arm || fail "arm with 12 saved copies: $(cat "$tmp/err")"
[[ $(ls "$tmp/gpt" | sort -V | paste -sd' ') == "live-202611120000 pre-6 pre-7 pre-8 pre-9 pre-10 pre-11 pre-12 pre-13" ]] \
  || fail "prune kept: $(ls "$tmp/gpt" | sort -V | paste -sd' ')"
saved_ok "$tmp/gpt/pre-13" "$tmp/onb.img" || fail "prune: newest saved copies differ from the disk before"
cp "$tmp/onb.img" "$img"
r=0
MICROOS_SLOT_FAIL=corrupt-primary run arm || r=$?
[[ $r == 1 && -d $tmp/gpt/pre-6 && -d $tmp/gpt/pre-14 ]] || fail "failed write pruned: exit $r, $(ls "$tmp/gpt" | sort -V | paste -sd' ')"

: > "$tmp/notadir"
cp "$tmp/onb.img" "$img"
r=0
STATE=$tmp/notadir/gpt run arm || r=$?
[[ $r == 1 && $(cat "$tmp/err") == *"copies not saved under $tmp/notadir/gpt, nothing written"* ]] \
  || fail "arm with no save dir: exit $r: $(cat "$tmp/err")"
same "$img" "$tmp/onb.img" || fail "arm with no save dir wrote"

own=$tmp/own
mkdir -p "$own/usr/libexec/microos" "$own/usr/lib/microos"
cp "$slot" "$own/usr/libexec/microos/microos-slot"
cp "$tmp/onb.img" "$img"
for w in 0 1; do
  printf 'MICROOS_SLOT_WRITE=%s\nMICROOS_BOOT_TRIES=3\n' "$w" > "$own/usr/lib/microos/slot.conf"
  r=0
  env MICROOS_SLOT_TEST=1 MICROOS_SLOT_DISKS="boot_a=$img boot_b=$img" MICROOS_SLOT_BLOCK_SIZE="$ss" \
    MICROOS_SLOT_STATE="$tmp/gpt" "$own/usr/libexec/microos/microos-slot" arm > /dev/null 2> "$tmp/err" || r=$?
  if [[ $w == 0 ]]; then
    [[ $r == 3 && $(cat "$tmp/err") == *"($own/usr/lib/microos/slot.conf)"* ]] || fail "own tree conf, writes off: exit $r: $(cat "$tmp/err")"
    same "$img" "$tmp/onb.img" || fail "own tree conf, writes off: the disk changed"
  else
    [[ $r == 0 && $(state "$img") == "78 78 3f 3f" ]] || fail "own tree conf, writes on: exit $r, bytes $(state "$img"): $(cat "$tmp/err")"
  fi
done

r=0
env MICROOS_SLOT_DISKS="boot_a=$img boot_b=$img" MICROOS_SLOT_BLOCK_SIZE="$ss" MICROOS_SLOT_CONF="$conf" "$slot" status > /dev/null 2> "$tmp/err" || r=$?
err=$(cat "$tmp/err")
[[ $r == 1 && ($err == *"needs root"* || $err == *"no boot_b partition"*) ]] || fail "status without the hook: exit $r: $err"

if (( rc == 0 )); then
  echo "slot: ok"
fi
exit "$rc"
