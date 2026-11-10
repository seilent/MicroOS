#!/system/bin/sh
set -eu

block=${ABL_BLOCK_DIR:-/dev/block/by-name}
out=${ABL_BACKUP:-$(dirname "$0")}

fail() { printf '%s\n' "FAILED: $*" >&2; exit 1; }
hash_file() { sha256sum "$1" | cut -d' ' -f1; }
hash_dev() { dd if="$1" bs=4096 2>/dev/null | sha256sum | cut -d' ' -f1; }

mkdir -p "$out"
for slot in a b; do
  [ -b "$block/abl_$slot" ] || fail "no block device $block/abl_$slot"
done

for slot in a b; do
  dev=$block/abl_$slot
  tmp=$out/.abl-$slot.tmp
  dd if="$dev" of="$tmp" bs=4096 2>/dev/null || fail "cannot read $dev"
  from_file=$(hash_file "$tmp")
  from_dev=$(hash_dev "$dev")
  [ "$from_file" = "$from_dev" ] || fail "abl_$slot changed while reading"
  img=$out/abl-$from_file.img
  if [ -e "$img" ]; then
    [ "$(hash_file "$img")" = "$from_file" ] || fail "$img holds other content"
    rm -f "$tmp"
  else
    mv "$tmp" "$img"
  fi
  printf '%s  %s\n' "$from_file" "${img##*/}" > "$img.sha256"
  printf '%s\n' "abl_$slot $from_file $img"
done
