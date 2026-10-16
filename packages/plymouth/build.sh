#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"

version=$(rpmspec -q --srpm --qf '%{VERSION}' "$src/plymouth.spec")
[[ $version == "$PLYMOUTH_VERSION" ]] || { echo "build.sh: spec Version $version, SOURCE.env $PLYMOUTH_VERSION" >&2; exit 1; }

fetch() {
  local name=$1 sha512=$2
  local file=$top/SOURCES/$name
  curl -fsSL --retry 3 -o "$file" "$LOOKASIDE_URL/$name/sha512/$sha512/$name"
  echo "$sha512  $file" | sha512sum -c -
}
fetch "$PLYMOUTH_FILE" "$PLYMOUTH_SHA512"
fetch "$SPINNER_FILE" "$SPINNER_SHA512"
cp "$src/charge.plymouth" "$src"/patches/*.patch "$top/SOURCES/"

rpmbuild -ba --define "_topdir $top" "$src/plymouth.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$out/"
