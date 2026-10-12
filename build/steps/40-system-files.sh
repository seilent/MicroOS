#!/usr/bin/env bash
set -euo pipefail

cp -a /ctx/system_files/. /

while read -r t u g; do
  if [[ $t == m && $u == micro ]] && ! grep -q "^$g:" /etc/group; then
    grep "^$g:" /usr/lib/group >> /etc/group
  fi
done < /usr/lib/sysusers.d/microos.conf

units=()
for u in /usr/lib/systemd/system/microos-*; do
  if [[ -f $u ]] && grep -q '^\[Install\]' "$u"; then
    units+=("${u##*/}")
  fi
done
if (( ${#units[@]} )); then
  systemctl preset "${units[@]}"
fi

systemctl mask \
  bootloader-update.service \
  systemd-backlight@.service \
  systemd-hibernate.service \
  systemd-hybrid-sleep.service \
  systemd-suspend-then-hibernate.service \
  bootc-fetch-apply-updates.timer
