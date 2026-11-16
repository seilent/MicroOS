#!/usr/bin/bash
storage=/usr/libexec/microos/microos-storage
for sys in "${MICROOS_SYSFS:-/sys}"/block/mmcblk[0-9]; do
  [[ -e $sys ]] || continue
  disk=${sys##*/}
  case $("$storage" classify "$disk" 2>/dev/null) in
    data | os-image) exec "$storage" format "$@" --device "/dev/$disk" ;;
  esac
done
echo "format-sdcard: no card to format" >&2
exit 19
