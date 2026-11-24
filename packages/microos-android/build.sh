#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)

top=$(mktemp -d)
chmod 755 "$top"
trap 'rm -rf "${top:?}"' EXIT
mkdir -p "$top/SOURCES"

tar -C "$src/data" --owner=0 --group=0 --mode=go-w --transform 's,^\.,microos-android-data,S' \
  -czf "$top/SOURCES/microos-android-data.tar.gz" .

rpmbuild -ba \
  --define "_topdir $top" \
  "$src/microos-android.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
