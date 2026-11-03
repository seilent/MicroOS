#!/system/bin/sh
set -eu

here=$(dirname "$0")
payload=${ABL_PAYLOAD:-$here}
backup=${ABL_BACKUP:-$here}
block=${ABL_BLOCK_DIR:-/dev/block/by-name}
elf=$payload/abl_signed-SM8250.elf
catalog=$payload/releases.tsv

fail() { printf '%s\n' "FAILED: $*" >&2; exit 1; }

[ -f "$elf" ] || fail "no $elf"
[ -f "$elf.sha256" ] || fail "no $elf.sha256"
[ -f "$catalog" ] || fail "no $catalog"
( cd "$payload" && sha256sum -c "${elf##*/}.sha256" > /dev/null 2>&1 ) || fail "$elf fails its sha256"
phash=$(sha256sum "$elf" | cut -d' ' -f1)

le32() { od -An -tu4 -j"$2" -N4 "$1" | tr -d ' \n'; }
le16() { od -An -tu2 -j"$2" -N2 "$1" | tr -d ' \n'; }

extent() {
  phoff=$(le32 "$1" 28)
  phentsize=$(le16 "$1" 42)
  phnum=$(le16 "$1" 44)
  shoff=$(le32 "$1" 32)
  shentsize=$(le16 "$1" 46)
  shnum=$(le16 "$1" 48)
  [ -n "$phoff" ] && [ -n "$phentsize" ] && [ -n "$phnum" ] || return 1
  l=$((shoff + shnum * shentsize))
  i=0
  while [ "$i" -lt "$phnum" ]; do
    o=$((phoff + i * phentsize))
    e=$(( $(le32 "$1" $((o + 4))) + $(le32 "$1" $((o + 16))) ))
    [ "$e" -le "$l" ] || l=$e
    i=$((i + 1))
  done
  printf '%s\n' "$l"
}

prefix_hash() {
  sectors=$(( ($2 + 4095) / 4096 ))
  dd if="$1" bs=4096 count="$sectors" 2>/dev/null | head -c "$2" | sha256sum | cut -d' ' -f1
}

order_of() {
  awk -F'\t' -v l="$1" -v h="$2" '$1 ~ /^[0-9]+$/ && $3 == "SM8250" && $4 == l && $5 == h { print $1 }' "$catalog"
}

is_elf() { [ "$(od -An -tx1 -N4 "$1" | tr -d ' \n')" = 7f454c46 ]; }

plen=$(extent "$elf") || fail "$elf has no readable ELF header"
porder=$(order_of "$plen" "$phash")
[ -n "$porder" ] || fail "$elf $plen $phash is not in $catalog"

hash_dev() { dd if="$1" bs=4096 2>/dev/null | sha256sum | cut -d' ' -f1; }

check() {
  slot=$1
  dev=$block/abl_$slot
  [ -b "$dev" ] || fail "no block device $dev"
  is_elf "$dev" || fail "abl_$slot has no ELF header"
  slen=$(extent "$dev") || fail "abl_$slot has no readable ELF header"
  shash=$(prefix_hash "$dev" "$slen")
  full=$(hash_dev "$dev")
  sorder=$(order_of "$slen" "$shash")
  if [ -n "$sorder" ]; then
    [ "$sorder" -lt "$porder" ] || fail "abl_$slot is at order $sorder, the payload is $porder"
  else
    printf '%s\n' "WARNING: abl_$slot $slen $shash is not in $catalog" >&2
  fi
  img=$backup/abl-$full.img
  [ -f "$img" ] || fail "no backup $img for abl_$slot"
  [ -f "$img.sha256" ] || fail "no $img.sha256"
  ( cd "$backup" && sha256sum -c "abl-$full.img.sha256" > /dev/null 2>&1 ) || fail "$img fails its sha256"
  [ "$(prefix_hash "$img" "$slen")" = "$shash" ] || fail "$img does not hold abl_$slot"
  printf '%s\n' "$full"
}

a_hash=$(check a)
b_hash=$(check b)

suffix=$(getprop ro.boot.slot_suffix)
[ -n "$suffix" ] || fail "ro.boot.slot_suffix is empty"
active=${suffix#_}
case $active in
  a) inactive=b ;;
  b) inactive=a ;;
  *) fail "ro.boot.slot_suffix is $suffix" ;;
esac

for slot in "$inactive" "$active"; do
  dev=$block/abl_$slot
  eval "want=\${${slot}_hash}"
  [ "$(hash_dev "$dev")" = "$want" ] || fail "abl_$slot changed since its backup"
  dd if="$elf" of="$dev" bs=4096 conv=notrunc,fsync 2>/dev/null || fail "cannot write $dev"
  got=$(prefix_hash "$dev" "$plen")
  [ "$got" = "$phash" ] || fail "readback of abl_$slot is $got, not $phash"
  printf '%s\n' "abl_$slot $phash"
done
