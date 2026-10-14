#!/usr/bin/bash
storage=/usr/libexec/microos/microos-storage
for sys in "${MICROOS_SYSFS:-/sys}"/block/mmcblk[0-9]; do
  [[ -e $sys ]] || continue
  disk=${sys##*/}
  if [[ $("$storage" classify "$disk" 2>/dev/null) == data ]]; then
    exec "$storage" format "$@" --device "/dev/$disk"
  fi
done
echo "format-sdcard: no data card" >&2
exit 19
