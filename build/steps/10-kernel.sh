#!/usr/bin/env bash
set -euo pipefail

mapfile -t old < <(rpm -qa --qf '%{NAME}\n' 'kernel*' | sort -u)
if (( ${#old[@]} )); then
  dnf -y remove "${old[@]}"
fi
rm -rf /usr/lib/modules/*

rpms=(/rpms/microos-kernel-*.rpm)
[[ ${#rpms[@]} -eq 1 && -f ${rpms[0]} ]] || { echo "10-kernel: expected one microos-kernel rpm in /rpms" >&2; exit 1; }
dnf -y install "${rpms[0]}"

kver=$(rpm -qlp "${rpms[0]}" | sed -n 's|^/usr/lib/modules/\([^/]*\)$|\1|p')
mods=(/usr/lib/modules/*)
[[ ${#mods[@]} -eq 1 && ${mods[0]} == "/usr/lib/modules/$kver" && -n $kver ]] || { echo "10-kernel: modules dirs ${mods[*]}, rpm kver $kver" >&2; exit 1; }
