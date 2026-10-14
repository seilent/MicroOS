#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

top=$(mktemp -d)
chmod 755 "$top"
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"

if [[ -n ${MICROSET_SRC:-} ]]; then
  ref=local
  date=$(date -u +%Y%m%d)
  tar -C "$MICROSET_SRC" --exclude=./.git --exclude=./build --exclude=./out \
    --transform "s,^\.,MicroSET-$ref," -czf "$top/SOURCES/microset-$ref.tar.gz" .
  touch "$out/dirty"
else
  ref=$MICROSET_REF
  date=$MICROSET_DATE
  tarball=$top/SOURCES/microset-$ref.tar.gz
  curl -fsSL --retry 3 -o "$tarball" "$MICROSET_URL/archive/$ref.tar.gz"
  echo "$MICROSET_SHA256  $tarball" | sha256sum -c -
fi

curl -fsSL --retry 3 -o "$top/SOURCES/Selawik_Release.zip" "$SELAWIK_URL"
echo "$SELAWIK_SHA256  $top/SOURCES/Selawik_Release.zip" | sha256sum -c -
curl -fsSL --retry 3 -o "$top/SOURCES/LICENSE.txt" "$SELAWIK_LICENSE_URL"
echo "$SELAWIK_LICENSE_SHA256  $top/SOURCES/LICENSE.txt" | sha256sum -c -

rpmbuild -ba \
  --define "_topdir $top" \
  --define "commit $ref" \
  --define "snapdate $date" \
  "$src/microset.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
