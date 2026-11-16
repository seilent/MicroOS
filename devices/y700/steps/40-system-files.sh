#!/usr/bin/env bash
set -euo pipefail

cp -a /ctx/system_files/. /
chmod 600 /usr/lib/NetworkManager/system-connections/microos-usb0.nmconnection

/usr/libexec/microos/microos-groups
systemd-sysusers /usr/lib/sysusers.d/microos.conf
mkdir -p /etc/systemd/system-generators
ln -sfn /dev/null /etc/systemd/system-generators/systemd-gpt-auto-generator

units=()
for u in /usr/lib/systemd/system/microos-*; do
  if [[ -f $u ]] && grep -q '^\[Install\]' "$u"; then
    units+=("${u##*/}")
  fi
done
if (( ${#units[@]} )); then
  systemctl preset "${units[@]}"
fi

shopt -s nullglob
for kind in system user; do
  files=("/usr/lib/systemd/$kind-preset/"*microos*.preset)
  (( ${#files[@]} )) || continue
  mapfile -t named < <(awk '($1 == "enable" || $1 == "disable") && $2 !~ /[*?[]/ { print $2 }' "${files[@]}" | sort -u)
  (( ${#named[@]} )) || continue
  if [[ $kind == user ]]; then
    systemctl --global preset "${named[@]}"
  else
    systemctl preset "${named[@]}"
  fi
done

systemctl mask \
  bootloader-update.service \
  systemd-repart.service \
  systemd-backlight@.service \
  systemd-hibernate.service \
  systemd-hybrid-sleep.service \
  systemd-suspend-then-hibernate.service \
  bootc-fetch-apply-updates.timer \
  bootc-generic-growpart.service
systemctl --global mask mpris-proxy.service
