#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"

ref=$HEXAGONRPC_REF
tarball=$top/SOURCES/hexagonrpc-$ref.tar.gz
curl -fsSL --retry 3 -o "$tarball" "$HEXAGONRPC_URL/archive/$ref.tar.gz"
echo "$HEXAGONRPC_SHA256  $tarball" | sha256sum -c -

rpmbuild -ba \
  --define "_topdir $top" \
  --define "commit $ref" \
  --define "snapdate $HEXAGONRPC_DATE" \
  "$src/hexagonrpc.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
