#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
cases=34

command -v python3 > /dev/null || { echo "FAIL: python3 missing" >&2; exit 1; }
root=()
if ((EUID == 0)) && [[ -e /dev/loop-control ]] && command -v losetup > /dev/null; then
  root=(--loop "$here/abl-loop.sh")
  cases=35
fi
out=$(python3 "$here/abl/harness.py" "$tree" "${root[@]}") || { printf '%s\n' "$out" >&2; exit 1; }
printf '%s\n' "$out"
total=$(sed -n 's/^abl: \([0-9]\+\) cases$/\1/p' <<< "$out" | tail -n 1)
[[ $total == "$cases" ]] || { echo "FAIL: abl ran ${total:-no} cases, expected $cases" >&2; exit 1; }
echo "abl: $cases cases"
