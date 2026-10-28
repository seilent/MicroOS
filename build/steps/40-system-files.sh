#!/usr/bin/env bash
set -euo pipefail

cp -a /ctx/system_files/. /
python3 -m compileall -q --invalidation-mode checked-hash /usr/share/microos/python

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
  systemd-backlight@.service \
  systemd-hibernate.service \
  systemd-hybrid-sleep.service \
  systemd-suspend-then-hibernate.service \
  bootc-fetch-apply-updates.timer
systemctl --global mask mpris-proxy.service
