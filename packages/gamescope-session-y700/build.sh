#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"

build() {
  local name=$1 url=$2 ref=$3 date=$4 sha256=$5
  local tarball=$top/SOURCES/$name-$ref.tar.gz
  curl -fsSL --retry 3 -o "$tarball" "$url/archive/$ref.tar.gz"
  echo "$sha256  $tarball" | sha256sum -c -
  rpmbuild -ba \
    --define "_topdir $top" \
    --define "commit $ref" \
    --define "snapdate $date" \
    "$src/$name.spec"
}

cp "$src"/patches/*.patch "$top/SOURCES/"
build gamescope-session "$GAMESCOPE_SESSION_URL" "$GAMESCOPE_SESSION_REF" \
  "$GAMESCOPE_SESSION_DATE" "$GAMESCOPE_SESSION_SHA256"
build gamescope-session-steam "$GAMESCOPE_SESSION_STEAM_URL" "$GAMESCOPE_SESSION_STEAM_REF" \
  "$GAMESCOPE_SESSION_STEAM_DATE" "$GAMESCOPE_SESSION_STEAM_SHA256"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
