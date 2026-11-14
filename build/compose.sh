#!/usr/bin/env bash
set -euo pipefail

usage="usage: compose.sh <device> <out>"
d=${1:?$usage}
out=${2:?$usage}
fail() { echo "compose: $*" >&2; exit 1; }
export LC_ALL=C

root=$(cd "$(dirname "$0")/.." && pwd)
[[ $d =~ ^[a-z0-9]+$ && -f $root/devices/$d/device.env ]] || fail "unknown device $d"
mkdir -p "$out"
out=$(cd "$out" && pwd)
[[ -z $(ls -A "$out") ]] || fail "$out is not empty"
cd "$root"

areas=(system_files:system_files build/steps:steps tests:tests)
devs=()
for e in devices/*/device.env; do
  devs+=("$(basename "$(dirname "$e")")")
done

bad=$(find devices/*/tests -maxdepth 1 -name 'pkg-*' 2>/dev/null || true)
[[ -z $bad ]] || fail "package tests stay at the root: $bad"

list() { [[ ! -d $1 ]] || find "$1" -mindepth 1 "${@:2}" -printf '%P\n'; }
for a in "${areas[@]}"; do
  r=${a%%:*}
  o=${a#*:}
  trees=("$r")
  for e in "${devs[@]}"; do
    trees+=("devices/$e/$o")
    both=$(comm -12 <(list "$r" ! -type d | sort) <(list "devices/$e/$o" ! -type d | sort))
    [[ -z $both ]] || fail "both in $r and devices/$e/$o: $both"
  done
  dirs=$(for t in "${trees[@]}"; do list "$t" -type d; done | sort -u)
  files=$(for t in "${trees[@]}"; do list "$t" ! -type d; done | sort -u)
  clash=$(comm -12 <(echo "$dirs") <(echo "$files"))
  [[ -z $clash ]] || fail "a dir in one $r tree is a file or link in another: $clash"
done

for e in "${devs[@]}"; do
  steps=build/steps/30-packages.sh
  [[ ! -f devices/$e/steps/30-packages.sh ]] || steps=devices/$e/steps/30-packages.sh
  [[ -f devices/$e/packages ]] || fail "devices/$e/packages is missing"
  own=$(sed -n '/^own=(/,/^)/{/^own=(/d;/^)/d;s/^[[:space:]]*//;s/\/.*//;p}' "$steps" | sort -u)
  [[ -n $own ]] || fail "no own list in $steps"
  for p in $own; do
    grep -qxF "$p" "devices/$e/packages" || fail "$p from the own list of $steps is not in devices/$e/packages"
  done
done

cp -a Containerfile build packages "$out/"
for a in "${areas[@]}"; do
  r=${a%%:*}
  o=${a#*:}
  mkdir -p "$out/$r"
  [[ $r == build/steps ]] || cp -a "$r/." "$out/$r/"
  [[ ! -d devices/$d/$o ]] || cp -a "devices/$d/$o/." "$out/$r/"
done
