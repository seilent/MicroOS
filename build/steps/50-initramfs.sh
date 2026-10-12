#!/usr/bin/env bash
set -euo pipefail

mods=(/usr/lib/modules/*)
[[ ${#mods[@]} -eq 1 ]] || { echo "50-initramfs: expected one modules dir" >&2; exit 1; }
kver=${mods[0]##*/}
img=/usr/lib/modules/$kver/initramfs.img

mkdir -p /var/roothome
dracut --no-hostonly --reproducible --add "ostree microos-ostree-remap" --force "$img" "$kver"

list=$(lsinitrd "$img")
builtin=$(cat "/usr/lib/modules/$kver/modules.builtin")
for m in erofs overlay btrfs sdhci-msm ufs-qcom; do
  grep -qE "/$m\.ko" <<< "$list" || grep -qE "/$m\.ko$" <<< "$builtin" || { echo "50-initramfs: $m missing" >&2; exit 1; }
done
for f in usr/lib/ostree/ostree-prepare-root usr/libexec/microos/prepare-root usr/bin/sh usr/bin/realpath usr/bin/mkdir \
  usr/lib/systemd/system/ostree-prepare-root.service.d/10-microos-remap.conf; do
  grep -qE " $f( |$)" <<< "$list" || { echo "50-initramfs: $f missing" >&2; exit 1; }
done
lsinitrd -f usr/lib/systemd/system/ostree-prepare-root.service.d/10-microos-remap.conf "$img" | grep -qx 'ExecStart=' \
  || { echo "50-initramfs: drop-in has no ExecStart= reset" >&2; exit 1; }
