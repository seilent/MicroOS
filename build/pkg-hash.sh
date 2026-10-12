#!/usr/bin/env bash
set -euo pipefail

name=${1:?usage: pkg-hash.sh <name>}
[[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "pkg-hash: bad name $name" >&2; exit 1; }
cd "$(dirname "$0")/.."
dir=packages/$name
[[ -d $dir ]] || { echo "pkg-hash: no $dir" >&2; exit 1; }

inputs=("$dir" build/pkg.Containerfile)
[[ -f tests/pkg-$name.sh ]] && inputs+=("tests/pkg-$name.sh")

find "${inputs[@]}" -type f -print0 | LC_ALL=C sort -z |
  while IFS= read -r -d '' f; do
    mode=-
    [[ -x $f ]] && mode=x
    printf '%s %s %s\n' "$mode" "$(sha256sum < "$f" | cut -d' ' -f1)" "$f"
  done | sha256sum | cut -c1-16
