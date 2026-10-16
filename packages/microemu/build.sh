#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

top=$(mktemp -d)
chmod 755 "$top"
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"

if [[ -n ${MICROEMU_SRC:-} ]]; then
  ref=local
  date=$(date -u +%Y%m%d)
  tar -C "$MICROEMU_SRC" --exclude=./.git --exclude=./build/cache --exclude=./dist --exclude=./out \
    --transform "s,^\.,MicroEMU-$ref," -czf "$top/SOURCES/microemu-$ref.tar.gz" .
  touch "$out/dirty"
else
  if [[ -z $MICROEMU_REF || -z $MICROEMU_DATE || -z $MICROEMU_SHA256 ]]; then
    echo "build.sh: MICROEMU_REF, MICROEMU_DATE or MICROEMU_SHA256 is empty in SOURCE.env; set MICROEMU_SRC to build a local tree" >&2
    exit 1
  fi
  ref=$MICROEMU_REF
  date=$MICROEMU_DATE
  tarball=$top/SOURCES/microemu-$ref.tar.gz
  curl -fsSL --retry 3 -o "$tarball" "$MICROEMU_URL/archive/$ref.tar.gz"
  echo "$MICROEMU_SHA256  $tarball" | sha256sum -c -
fi

mkdir "$top/assets" "$top/tree"
tar -xzf "$top/SOURCES/microemu-$ref.tar.gz" -C "$top/tree"
MICROEMU_CACHE=$top/assets/cache "$top/tree/MicroEMU-$ref/build/install.sh" "$top/assets/root" >/dev/null
tar -C "$top/assets" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
  -czf "$top/SOURCES/microemu-assets-$ref.tar.gz" cache

rpmbuild -ba \
  --define "_topdir $top" \
  --define "commit $ref" \
  --define "snapdate $date" \
  "$src/microemu.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
