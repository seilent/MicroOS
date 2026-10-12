#!/usr/bin/env bash
set -euo pipefail

raw=${1:?usage: finalize-disk.sh <raw> <image ref>}
ref=${2:?usage: finalize-disk.sh <raw> <image ref>}

die() { echo "finalize-disk: $*" >&2; exit 1; }

(( EUID == 0 )) || die "run as root"
[[ -f $raw ]] || die "no raw image at $raw"

work=$(mktemp -d)
loop=
cleanup() {
  local m
  for m in "$work"/mnt/*; do
    if mountpoint -q "$m"; then
      umount "$m" || return 0
    fi
  done
  if [[ -n $loop ]]; then
    losetup -d "$loop" || true
  fi
  rm -rf --one-file-system "$work"
}
trap cleanup EXIT

esp=$work/mnt/esp
boot=$work/mnt/boot
root=$work/mnt/root
mkdir -p "$esp" "$boot" "$root" "$work/bake"

loop=$(losetup -fP --show "$raw")
for _ in $(seq 50); do
  [[ -b ${loop}p3 ]] && break
  sleep 0.1
done

table=$(sfdisk -J "$loop")
[[ $(jq -r '.partitiontable.label' <<< "$table") == gpt ]] || die "partition table is not GPT"
[[ $(jq '.partitiontable.partitions | length' <<< "$table") == 3 ]] || die "expected 3 partitions"
for want in 1:vfat 2:ext4 3:btrfs; do
  type=$(blkid -o value -s TYPE "${loop}p${want%%:*}" || true)
  [[ $type == "${want#*:}" ]] || die "p${want%%:*} is ${type:-empty}, expected ${want#*:}"
done

mount "${loop}p2" "$boot"
entries=("$boot"/loader/entries/*.conf)
[[ ${#entries[@]} == 1 && -f ${entries[0]} ]] || die "expected one BLS entry"
bls() { sed -n "s/^$1[[:space:]]\+//p" "${entries[0]}"; }
bootpath() {
  if [[ $1 == /boot/* && -e $boot${1#/boot} ]]; then
    printf '%s\n' "${1#/boot}"
  else
    printf '%s\n' "$1"
  fi
}

options=$(bls options)
ostree=
subvol=
set -f
for w in $options; do
  case $w in
    ostree=*) ostree=${w#ostree=} ;;
    rootflags=*)
      IFS=, read -ra flags <<< "${w#rootflags=}"
      for f in "${flags[@]}"; do
        [[ $f != subvol=* ]] || subvol=${f#subvol=}
      done
      ;;
  esac
done
set +f
[[ -n $ostree ]] || die "no ostree= in the BLS options"
[[ -n $subvol ]] || die "no rootflags subvol= in the BLS options"

mount -o "subvol=$subvol" "${loop}p3" "$root"
mount "${loop}p1" "$esp"

deploy=$(realpath -e "$root$ostree") || die "$ostree does not resolve on p3"
[[ $deploy == "$root"/ostree/deploy/*/deploy/* ]] || die "$ostree does not resolve to a deployment"

rm -rf "$esp/EFI"
rm -f "$boot/bootupd-state.json"

kernel=$(bootpath "$(bls linux)")
initrd=$(bootpath "$(bls initrd)")
fdtdir=$(bootpath "$(bls fdtdir)")
dtb=$(sed -n 's/^MICROOS_DTB=//p' "$deploy/usr/lib/microos/bootimg.conf") || die "the deployment has no bootimg.conf"
[[ -n $dtb ]] || die "no MICROOS_DTB in the deployment's bootimg.conf"

id=$(podman run --rm --pull=never --net=none --security-opt label=disable \
  -v "$boot:/run/disk/boot:ro" \
  -v "$root:/run/disk/root:ro" \
  -v "$work/bake:/run/disk/out" \
  --entrypoint /usr/libexec/microos/microos-bootimg-build \
  "$ref" \
  --root "/run/disk/root${deploy#"$root"}" \
  --kernel "/run/disk/boot$kernel" \
  --initrd "/run/disk/boot$initrd" \
  --dtb "/run/disk/boot$fdtdir/$dtb" \
  --options "$options" \
  --sysroot /run/disk/root \
  --out /run/disk/out/KERNEL)
[[ $id =~ ^[0-9a-f]{64}$ ]] || die "bake printed no id"

cp "$work/bake/KERNEL" "$esp/KERNEL"
printf '%s\n' "$id" > "$esp/.microos-bootimg.id"
sync
umount "$esp"
fatlabel "${loop}p1" MICROOS

esp_uuid=$(blkid -o value -s UUID "${loop}p1")
boot_uuid=$(blkid -o value -s UUID "${loop}p2")
fstab=$deploy/etc/fstab
[[ -f $fstab ]] || die "the deployment has no /etc/fstab"
echo "finalize-disk: deployment /etc/fstab:"
cat "$fstab"
! grep -q PARTUUID= "$fstab" || die "/etc/fstab uses PARTUUID="
awk -v u="UUID=$boot_uuid" '$1 == u && $2 == "/boot" { f = 1 } END { exit !f }' "$fstab" \
  || die "/etc/fstab does not mount /boot by UUID=$boot_uuid"
if ! awk '$1 !~ /^#/ && $2 == "/boot/efi" { f = 1 } END { exit !f }' "$fstab"; then
  echo "finalize-disk: adding /boot/efi to /etc/fstab"
  [[ ! -s $fstab || -z $(tail -c1 "$fstab") ]] || echo >> "$fstab"
  printf 'UUID=%s /boot/efi vfat umask=0077,shortname=winnt 0 2\n' "$esp_uuid" >> "$fstab"
fi
awk -v u="UUID=$esp_uuid" '$1 == u && $2 == "/boot/efi" { f = 1 } END { exit !f }' "$fstab" \
  || die "/etc/fstab does not mount /boot/efi by UUID=$esp_uuid"

repo=$root/ostree/repo
bootloader=$(awk -F' *= *' '/^\[/ { s = $0 } s == "[sysroot]" && $1 == "bootloader" { print $2 }' "$repo/config")
if [[ $bootloader != none ]]; then
  echo "finalize-disk: sysroot.bootloader is ${bootloader:-unset}, setting none"
  podman run --rm --pull=never --net=none --security-opt label=disable -v "$repo:/run/disk/repo" \
    --entrypoint ostree "$ref" config --repo /run/disk/repo set sysroot.bootloader none
fi

sync
umount "$root"
umount "$boot"

mapfile -t layout < <(sfdisk --dump "$loop" | sed -n 's/^[^ ]* : start= *\([0-9]\+\), size= *\([0-9]\+\),.*/\1,\2/p')
(( ${#layout[@]} == 3 )) || die "cannot read the GPT layout"
printf '%s\n' "${layout[0]},c,*" "${layout[1]},da" "${layout[2]},da" | sfdisk -q --wipe always --wipe-partitions never --label dos "$loop"
mapfile -t got < <(sfdisk --dump "$loop" | sed -n 's/^[^ ]* : start= *\([0-9]\+\), size= *\([0-9]\+\), type=\([0-9a-f]\+\)\(, bootable\)\?$/\1,\2,\3\4/p')
[[ ${got[*]} == "${layout[0]},c, bootable ${layout[1]},da ${layout[2]},da" ]] || die "MBR does not match the GPT layout: ${got[*]}"
sectors=$(blockdev --getsz "$loop")
for lba in 1 $(( sectors - 1 )); do
  [[ $(dd if="$loop" bs=512 skip="$lba" count=1 status=none | head -c 8 | tr -d '\0') != "EFI PART" ]] \
    || die "GPT header left at sector $lba"
done

sync
losetup -d "$loop"
loop=
