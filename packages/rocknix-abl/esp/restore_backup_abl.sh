#!/system/bin/sh
set -eu

fail() { printf '%s\n' "FAILED: $*" >&2; exit 1; }

[ $# -eq 2 ] || { printf '%s\n' "usage: restore_backup_abl.sh <a|b> <backup.img>" >&2; exit 2; }
slot=$1
img=$2
block=${ABL_BLOCK_DIR:-/dev/block/by-name}
dev=$block/abl_$slot

case $slot in
  a | b) ;;
  *) fail "slot is a or b, not $slot" ;;
esac
[ -b "$dev" ] || fail "no block device $dev"
[ -f "$img" ] || fail "no $img"
[ -f "$img.sha256" ] || fail "no $img.sha256"
( cd "$(dirname "$img")" && sha256sum -c "${img##*/}.sha256" > /dev/null 2>&1 ) || fail "$img fails its sha256"
want=$(sha256sum "$img" | cut -d' ' -f1)
[ "$(cut -d' ' -f1 < "$img.sha256")" = "$want" ] || fail "$img.sha256 names another hash"

dd if="$img" of="$dev" bs=4096 conv=notrunc,fsync 2>/dev/null || fail "cannot write $dev"
got=$(dd if="$dev" bs=4096 2>/dev/null | sha256sum | cut -d' ' -f1)
[ "$got" = "$want" ] || fail "readback of abl_$slot is $got, not $want"
printf '%s\n' "abl_$slot $want"
