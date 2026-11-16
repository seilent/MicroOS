#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

ps=${MICROOS_POWER_SUPPLY:-/sys/class/power_supply}
bat=$ps/qcom-battmgr-bat
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

status=$(< "$bat/status")
cur=$(< "$bat/current_now")
cap=$(< "$bat/capacity")
pd=0
for u in "$ps"/ucsi-source-psy-*; do
  [[ $(< "$u/online") == 1 && $(< "$u/usb_type") == *"[PD"* ]] && pd=1
done

want=
if [[ $status == Charging ]] && (( pd && cap < 95 )); then
  (( cur > 0 )) || fail "charging from PD at $cap% with current_now $cur"
  want=1
elif [[ $status == Discharging ]]; then
  (( cur <= 0 )) || fail "discharging with current_now $cur"
  want=2
fi

if [[ -n $want ]]; then
  for _ in $(seq 12); do
    state=$(busctl get-property org.freedesktop.UPower /org/freedesktop/UPower/devices/DisplayDevice \
      org.freedesktop.UPower.Device State)
    [[ $state == "u $want" ]] && break
    sleep 5
  done
  [[ $state == "u $want" ]] || fail "UPower DisplayDevice State is $state, not $want, with $status and current_now $cur"
fi

echo "battery: $status $cap% current_now $cur pd $pd UPower ${state:-unchecked}"
exit $rc
