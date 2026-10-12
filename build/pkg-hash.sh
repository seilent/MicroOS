#!/usr/bin/env bash
set -euo pipefail

list=0
if [[ ${1:-} == --inputs ]]; then
  list=1
  shift
fi
name=${1:?usage: pkg-hash.sh [--inputs] <name>}
[[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "pkg-hash: bad name $name" >&2; exit 1; }
cd "$(dirname "$0")/.."
dir=packages/$name
[[ -n $(git ls-files -- "$dir") ]] || { echo "pkg-hash: no tracked files in $dir" >&2; exit 1; }

inputs=("$dir" build/pkg.Containerfile build/pkg-wrap.Containerfile "tests/pkg-$name.sh" "tests/pkg-$name")
if (( list )); then
  printf '%s\n' "${inputs[@]}"
  exit 0
fi
git ls-files -s -- "${inputs[@]}" | LC_ALL=C sort -k4 | sha256sum | cut -c1-16
