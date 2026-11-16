#!/system/bin/sh

dev=${MICROOS_RETURN_EFI_DEV:-/dev/block/by-name/microos_efi}
dir=${MICROOS_RETURN_EFI_DIR:-}
mnt=${MICROOS_RETURN_MNT:-/mnt/microos-return}
bootb=${MICROOS_RETURN_BOOT_B:-/dev/block/by-name/boot_b}
log=${MICROOS_RETURN_LOG:-/data/adb/microos-return.log}
seen=${MICROOS_RETURN_SEEN:-/data/adb/microos-return.boot}
bootid=${MICROOS_RETURN_BOOT_ID:-/proc/sys/kernel/random/boot_id}
wait=${MICROOS_RETURN_WAIT:-300}
bootctls=${MICROOS_RETURN_BOOTCTLS:-/data/adb/microos-bootctl /system/bin/bootctl}
full=100663296

say() { echo "$(date '+%Y-%m-%d %H:%M:%S') microos-return: $*" >> "$log"; }

leave() {
  [ -n "$1" ] && say "$1"
  [ -n "$dir" ] || umount "$mnt" 2> /dev/null
  exit 0
}

size_of() {
  if [ -b "$1" ]; then
    blockdev --getsize64 "$1"
  else
    stat -c %s "$1"
  fi
}

sha_of() {
  s=$(sha256sum "$1") || return 1
  echo "${s%% *}"
}

hex() {
  case $1 in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#1}" = "$2" ]
}

held_id() {
  [ "$(dd if="$1" bs=8 count=1 2> /dev/null | tr -d '\0')" = ANDROID! ] || return 1
  case $(od -An -tu4 -j40 -N4 "$1" | tr -d ' ') in
    0|1|2) ;;
    *) return 1 ;;
  esac
  c="$(dd if="$1" bs=32 skip=2 count=16 2> /dev/null | tr -d '\0')$(dd if="$1" bs=32 skip=19 count=32 2> /dev/null | tr -d '\0')"
  set -f
  for w in $c; do
    case $w in
      microos.id=*) set +f; echo "${w#microos.id=}"; return 0 ;;
    esac
  done
  set +f
  return 1
}

write_prev() {
  dd if=/dev/zero of="$bootb" bs=4096 count=1 conv=notrunc,fsync 2> /dev/null || return 1
  dd if="$1" of="$bootb" bs=4096 skip=1 seek=1 conv=notrunc,fsync 2> /dev/null || return 1
  dd if="$1" of="$bootb" bs=4096 count=1 conv=notrunc,fsync 2> /dev/null || return 1
  sync
  [ ! -b "$bootb" ] || blockdev --flushbufs "$bootb"
  [ "$(sha_of "$bootb")" = "$2" ]
}

b=$(cat "$bootid" 2> /dev/null) || b=""
[ -n "$b" ] || exit 0
[ "$(cat "$seen" 2> /dev/null)" != "$b" ] || exit 0
echo "$b" > "$seen" || exit 0

if [ -n "$dir" ]; then
  efi=$dir
else
  mkdir -p "$mnt" || exit 0
  mount -t vfat -o ro "$dev" "$mnt" 2> /dev/null || { say "cannot mount $dev"; exit 0; }
  efi=$mnt
fi
marker=$efi/microos/testboot.id
[ -f "$marker" ] || leave ""

say "start, boot_id $b"
read -r tid pid < "$marker"
hex "$tid" 12 && hex "$pid" 12 || leave "testboot.id is not '<test id> <prev id>', nothing written"
say "testboot.id: test $tid, prev $pid"
[ "$(size_of "$bootb")" = "$full" ] || leave "$bootb is not $full bytes, nothing written"
held=$(held_id "$bootb") || held=""
[ "$held" = "$tid" ] || leave "boot_b holds ${held:-no MicroOS image}, not the test image $tid, nothing written"
img=$efi/microos/boot-prev.img
id="" sha=""
[ -f "$efi/microos/boot-prev.id" ] && read -r id sha < "$efi/microos/boot-prev.id"
[ "$id" = "$pid" ] || leave "boot-prev.id names '${id:-nothing}', not $pid, nothing written"
hex "$sha" 64 || leave "boot-prev.id has no sha256, nothing written"
[ -f "$img" ] && [ "$(size_of "$img")" = "$full" ] || leave "boot-prev.img is missing or not $full bytes, nothing written"
[ "$(sha_of "$img")" = "$sha" ] || leave "boot-prev.img does not match boot-prev.id, nothing written"
say "boot-prev.img holds $pid, sha256 matches"

n=0
until [ "$(getprop sys.boot_completed 2> /dev/null)" = 1 ] || [ "$n" -ge "$wait" ]; do
  sleep 5
  n=$((n + 5))
done

[ ! -b "$bootb" ] || blockdev --setrw "$bootb" 2> /dev/null
if write_prev "$img" "$sha"; then
  say "boot_b holds $pid, read back matches"
else
  say "boot_b read back differs from boot-prev.img, writing it again"
  write_prev "$img" "$sha" || leave "boot_b read back differs twice, stopped with Android up"
  say "boot_b holds $pid, read back matches"
fi

bc=""
for c in $bootctls; do
  if [ -x "$c" ]; then
    bc=$c
    break
  fi
done
[ -n "$bc" ] || leave "no bootctl in $bootctls, slot b not set, Android stays up"
if "$bc" set-active-boot-slot 1 >> "$log" 2>&1; then
  say "slot b active by $bc, rebooting"
  [ -n "$dir" ] || umount "$mnt" 2> /dev/null
  sync
  reboot
else
  leave "$bc set-active-boot-slot 1 failed, Android stays up"
fi
