#!/usr/bin/env bash
set -euo pipefail

dtb=${1:?usage: gpu-opp.sh <dtb>}
max=587000000
declare -A want=([305000000]=64 [400000000]=128 [441600000]=128 [490000000]=128 [525000000]=144 [587000000]=192)

walk() {
  local n=$1 c
  echo "$n"
  for c in $(fdtget -l "$dtb" "$n"); do
    walk "${n%/}/$c"
  done
}

nodes=$(walk /)
tables=()
for n in $nodes; do
  compat=$(fdtget -t s "$dtb" "$n" compatible 2>/dev/null | tr '\0' ' ') || continue
  if [[ " $compat " == *" qcom,adreno-gmu "* ]] && fdtget "$dtb" "$n" qcom,qmp >/dev/null 2>&1; then
    echo "gpu-opp: $n has qcom,qmp" >&2
    exit 1
  fi
  [[ " $compat " == *" qcom,adreno "* ]] || continue
  ph=$(fdtget -t u "$dtb" "$n" operating-points-v2)
  for t in $nodes; do
    [[ $(fdtget -t u "$dtb" "$t" phandle 2>/dev/null) == "$ph" ]] && tables+=("$t")
  done
done

if [[ ${#tables[@]} -eq 0 ]]; then
  echo "gpu-opp: no GPU OPP table found" >&2
  exit 1
fi

bad=0
for t in "${tables[@]}"; do
  if [[ " $(fdtget -t s "$dtb" "$t" compatible | tr '\0' ' ') " == *" operating-points-v2-adreno "* ]]; then
    echo "gpu-opp: $t is operating-points-v2-adreno" >&2
    bad=1
  fi
  for o in $(fdtget -l "$dtb" "$t"); do
    read -r hi lo < <(fdtget -t u "$dtb" "$t/$o" opp-hz)
    hz=$(( (hi << 32) + lo ))
    lvl=$(fdtget -t u "$dtb" "$t/$o" opp-level)
    echo "$t/$o $hz $lvl"
    if fdtget "$dtb" "$t/$o" qcom,opp-acd-level >/dev/null 2>&1; then
      echo "gpu-opp: $t/$o has qcom,opp-acd-level" >&2
      bad=1
    fi
    if [[ -n ${want[$hz]:-} && $lvl != "${want[$hz]}" ]]; then
      echo "gpu-opp: $t/$o level $lvl, want ${want[$hz]}" >&2
      bad=1
    fi
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
