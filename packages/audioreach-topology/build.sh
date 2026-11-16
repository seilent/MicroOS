#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"

ref=$AUDIOREACH_TOPOLOGY_REF
tarball=$top/SOURCES/audioreach-topology-$ref.tar.gz
curl -fsSL --retry 3 -o "$tarball" "$AUDIOREACH_TOPOLOGY_URL/-/archive/$ref/audioreach-topology-$ref.tar.gz"
echo "$AUDIOREACH_TOPOLOGY_SHA256  $tarball" | sha256sum -c -
cp "$src"/patches/*.patch "$src/LICENSE.audioreach-topology" "$top/SOURCES/"
rpmbuild -ba \
  --define "_topdir $top" \
  --define "commit $ref" \
  --define "snapdate $AUDIOREACH_TOPOLOGY_DATE" \
  "$src/audioreach-topology.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
