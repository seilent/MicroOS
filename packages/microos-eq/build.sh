#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

top=$(mktemp -d)
trap 'rm -rf "${top:?}"' EXIT
mkdir -p "$top/SOURCES" "$top/pipewire"
tar -C "$src/src" --owner=0 --group=0 --mode=go-w --transform 's,^\.,microos-eq,' -czf "$top/SOURCES/microos-eq.tar.gz" .

rpmbuild -ba --define "_topdir $top" "$src/microos-eq.spec"

srpm=$top/pipewire-$PIPEWIRE_EVR.src.rpm
curl -fsSL --retry 3 -o "$srpm" \
  "$KOJI_URL/pipewire/${PIPEWIRE_EVR%%-*}/${PIPEWIRE_EVR#*-}/data/signed/$KOJI_KEY/src/pipewire-$PIPEWIRE_EVR.src.rpm"
echo "$PIPEWIRE_SRPM_SHA256  $srpm" | sha256sum -c -
rpm2cpio "$srpm" > "$top/pipewire.cpio"
(cd "$top/pipewire" && cpio -idm --quiet "*pipewire-${PIPEWIRE_EVR%%-*}.tar.*" < "$top/pipewire.cpio")
tar -xf "$top"/pipewire/pipewire-*.tar.* -C "$top/pipewire" --strip-components=4 \
  --wildcards '*/spa/plugins/audioconvert/biquad.c' '*/spa/plugins/audioconvert/biquad.h'

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
mkdir -p "$out/pipewire"
cp "$top/pipewire/biquad.c" "$top/pipewire/biquad.h" "$out/pipewire/"
cp "$src/SOURCE.env" "$out/"
