#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"

defs=(
  --define "commit $GAMESCOPE_REF"
  --define "reshade_commit $RESHADE_REF"
  --define "vkroots_commit $VKROOTS_REF"
)
version=$(rpmspec -q --srpm --qf '%{VERSION}' "${defs[@]}" "$src/gamescope.spec")
[[ $version == "$GAMESCOPE_VERSION" ]] || { echo "build.sh: spec Version $version, SOURCE.env $GAMESCOPE_VERSION" >&2; exit 1; }

fetch() {
  local name=$1 url=$2 ref=$3 sha256=$4
  local tarball=$top/SOURCES/$name-$ref.tar.gz
  curl -fsSL --retry 3 -o "$tarball" "$url/archive/$ref.tar.gz"
  echo "$sha256  $tarball" | sha256sum -c -
}
fetch gamescope "$GAMESCOPE_URL" "$GAMESCOPE_REF" "$GAMESCOPE_SHA256"
fetch reshade "$RESHADE_URL" "$RESHADE_REF" "$RESHADE_SHA256"
fetch vkroots "$VKROOTS_URL" "$VKROOTS_REF" "$VKROOTS_SHA256"
cp "$src/stb.pc" "$src"/patches/*.patch "$top/SOURCES/"

rpmbuild -ba --define "_topdir $top" "${defs[@]}" "$src/gamescope.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$out/"
