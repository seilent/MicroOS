#!/usr/bin/env bash
set -euo pipefail

mods=(/usr/lib/modules/*)
[[ ${#mods[@]} -eq 1 ]] || { echo "50-initramfs: expected one modules dir" >&2; exit 1; }
kver=${mods[0]##*/}
img=/usr/lib/modules/$kver/initramfs.img

mkdir -p /var/roothome
dracut --no-hostonly --reproducible \
  -m "systemd systemd-initrd dracut-systemd base fs-lib rootfs-block udev-rules shutdown ostree microos-ostree-remap microos-y700-guard microos-y700-usbcon microos-selinux-label" \
  -o "kernel-modules bootc virtiofs lvm crypt fips tpm2-tss clevis clevis-pin-tpm2 nss-softokn" \
  --drivers "btrfs nvmem-qcom-spmi-sdam" --compress "zstd -19" --force "$img" "$kver"

want="base dracut-systemd fs-lib microos-ostree-remap microos-selinux-label microos-y700-guard microos-y700-usbcon ostree rootfs-block shutdown systemd \
systemd-ask-password systemd-initrd systemd-journald systemd-modules-load systemd-sysctl systemd-sysusers systemd-tmpfiles \
systemd-udevd udev-rules"
got=$(lsinitrd -m "$img" | sed '1,/^dracut modules:$/d;/^=/,$d' | LC_ALL=C sort | xargs)
[[ $got == "$want" ]] || { echo "50-initramfs: dracut modules $got" >&2; exit 1; }
list=$(lsinitrd "$img")
builtin=$(cat "/usr/lib/modules/$kver/modules.builtin")
for m in erofs overlay btrfs ufs-qcom vfat nvmem_qcom-spmi-sdam; do
  grep -qE "/$m\.ko" <<< "$list" || grep -qE "/$m\.ko$" <<< "$builtin" || { echo "50-initramfs: $m missing" >&2; exit 1; }
done
for f in usr/lib/ostree/ostree-prepare-root usr/libexec/microos/prepare-root usr/bin/sh usr/bin/realpath usr/bin/mkdir \
  usr/lib/systemd/system/ostree-prepare-root.service.d/10-microos-remap.conf; do
  grep -qE " $f( |$)" <<< "$list" || { echo "50-initramfs: $f missing" >&2; exit 1; }
done
lsinitrd -f usr/lib/systemd/system/ostree-prepare-root.service.d/10-microos-remap.conf "$img" | grep -qx 'ExecStart=' \
  || { echo "50-initramfs: drop-in has no ExecStart= reset" >&2; exit 1; }
for f in usr/libexec/microos/microos-guard usr/libexec/microos/microos-initrd-log usr/libexec/microos/microos-sdam \
  usr/libexec/microos/microos-bootb usr/lib/microos/slot.conf usr/bin/sha256sum usr/bin/stat usr/bin/readlink "usr/s?bin/blockdev" \
  usr/lib/systemd/system/microos-guard.service etc/microos-initrd-id; do
  grep -qE " $f( |$)" <<< "$list" || { echo "50-initramfs: $f missing" >&2; exit 1; }
done
grep -qE "/initrd\.target\.wants/microos-guard\.service( |$)" <<< "$list" || { echo "50-initramfs: microos-guard.service not enabled" >&2; exit 1; }
for f in usr/libexec/microos/microos-usb-console usr/libexec/microos/microos-initrd-usbcon usr/lib/systemd/system/microos-initrd-usbcon.service \
  usr/bin/bash usr/bin/stty; do
  grep -qE " $f( |$)" <<< "$list" || { echo "50-initramfs: $f missing" >&2; exit 1; }
done
grep -qE "/sysinit\.target\.wants/microos-initrd-usbcon\.service( |$)" <<< "$list" || { echo "50-initramfs: microos-initrd-usbcon.service not enabled" >&2; exit 1; }
[[ $(lsinitrd -f etc/cmdline.d/90-microos.conf "$img") == 'rd.shell=0 rd.emergency=reboot rd.timeout=90' ]] \
  || { echo "50-initramfs: cmdline.d/90-microos.conf" >&2; exit 1; }
[[ $(lsinitrd -f usr/lib/systemd/system/initrd-switch-root.service.d/10-microos.conf "$img") == \
  $'[Service]\nExecStart=\nExecStart=systemctl --no-block switch-root /sysroot /usr/lib/systemd/systemd' ]] \
  || { echo "50-initramfs: initrd-switch-root drop-in" >&2; exit 1; }
if grep -qE " usr/(s?bin)/(vi|fsck\.[a-z0-9]+|xfs_repair)( |$)" <<< "$list"; then
  echo "50-initramfs: vi or fsck tools in the initramfs" >&2
  exit 1
fi
if grep -qE "/kernel/drivers/gpu/" <<< "$list"; then
  echo "50-initramfs: GPU module in the initramfs" >&2
  exit 1
fi

max=15728640
size=$(stat -c %s "$img")
echo "50-initramfs: $img $size bytes, limit $max"
(( size <= max )) || { echo "50-initramfs: initramfs is $size bytes, over $max" >&2; exit 1; }
