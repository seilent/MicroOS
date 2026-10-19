#!/usr/bin/env bash
set -euo pipefail

dtb=${1:?usage: gpu-opp.sh <dtb>}
max=587000000

walk() {
  local n=$1 c
  echo "$n"
  for c in $(fdtget -l "$dtb" "$n"); do
    walk "${n%/}/$c"
  done
}

nodes=$(walk /)
tables=()
gmus=0
for n in $nodes; do
  compat=$(fdtget -t s "$dtb" "$n" compatible 2>/dev/null | tr '\0' ' ') || continue
  if [[ " $compat " == *" qcom,adreno-gmu "* ]]; then
    gmus=$((gmus + 1))
    fdtget -t u "$dtb" "$n" qcom,qmp >/dev/null 2>&1 || { echo "gpu-opp: $n has no qcom,qmp" >&2; exit 1; }
  fi
  [[ " $compat " == *" qcom,adreno "* ]] || continue
  ph=$(fdtget -t u "$dtb" "$n" operating-points-v2)
  for t in $nodes; do
    [[ $(fdtget -t u "$dtb" "$t" phandle 2>/dev/null) == "$ph" ]] && tables+=("$t")
  done
done

if [[ $gmus -eq 0 ]]; then
  echo "gpu-opp: no GMU found" >&2
  exit 1
fi

if [[ ${#tables[@]} -eq 0 ]]; then
  echo "gpu-opp: no GPU OPP table found" >&2
  exit 1
fi

bad=0
for t in "${tables[@]}"; do
  for o in $(fdtget -l "$dtb" "$t"); do
    read -r hi lo < <(fdtget -t u "$dtb" "$t/$o" opp-hz)
    hz=$(( (hi << 32) + lo ))
    acd=$(fdtget -t x "$dtb" "$t/$o" qcom,opp-acd-level 2>/dev/null) || {
      echo "gpu-opp: $t/$o has no qcom,opp-acd-level" >&2
      bad=1
    }
    echo "$t/$o $hz $(fdtget -t u "$dtb" "$t/$o" opp-level) ${acd:-}"
    if [[ $o == opp-670000000 ]]; then
      echo "gpu-opp: $t/$o present" >&2
      bad=1
    fi
    if (( hz > max )); then
      echo "gpu-opp: $t/$o at $hz Hz is above $max" >&2
      bad=1
    fi
  done
done
exit "$bad"
