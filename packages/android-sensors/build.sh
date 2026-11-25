#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)

top=$(mktemp -d)
trap 'rm -rf "${top:?}"' EXIT
mkdir -p "$top/SOURCES"
tar -C "$src/src" --owner=0 --group=0 --mode=go-w --transform 's,^\.,microos-android-sensors,' \
  -czf "$top/SOURCES/microos-android-sensors.tar.gz" .

rpmbuild -ba --define "_topdir $top" "$src/microos-android-sensors.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
