#!/usr/bin/env bash
set -euo pipefail

dtb=${1:?usage: fan-trips.sh <dtb>}
levels="0 77 83 121 159 255"
temps=(55000 77500 80000 82500 85000)
zones=(cluster0-thermal cluster1-thermal gpu-top-thermal gpu-bottom-thermal)

fan=$(fdtget -t s "$dtb" /__symbols__ fan 2>/dev/null) || fan=/pwm-fan
[[ $(fdtget -t u "$dtb" "$fan" cooling-levels) == "$levels" ]] || {
  echo "fan-trips: $fan cooling-levels is not $levels" >&2
  exit 1
}
fanph=$(fdtget -t u "$dtb" "$fan" phandle)

for z in "${zones[@]}"; do
  n=/thermal-zones/$z
  [[ $(fdtget -t u "$dtb" "$n" polling-delay) == 1000 ]] || { echo "fan-trips: $n polling-delay" >&2; exit 1; }
  for k in "${!temps[@]}"; do
    t=$n/trips/fan-$k
    [[ $(fdtget -t u "$dtb" "$t" temperature) == "${temps[k]}" ]] || { echo "fan-trips: $t temperature" >&2; exit 1; }
    [[ $(fdtget -t s "$dtb" "$t" type) == active ]] || { echo "fan-trips: $t type" >&2; exit 1; }
    m=$n/cooling-maps/map-fan$k
    [[ $(fdtget -t u "$dtb" "$m" trip) == "$(fdtget -t u "$dtb" "$t" phandle)" ]] || { echo "fan-trips: $m trip" >&2; exit 1; }
    [[ $(fdtget -t u "$dtb" "$m" cooling-device) == "$fanph $((k + 1)) $((k + 1))" ]] || { echo "fan-trips: $m cooling-device" >&2; exit 1; }
  done
done
