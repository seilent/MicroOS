#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"

ref=$LSFGVK_REF
sources=$(rpmspec -P --define "commit $ref" --define "snapdate $LSFGVK_DATE" "$src/lsfg-vk.spec" | awk '/^Source[0-9]*:/ { print $2 }')
want=$(printf '%s\n' "$LSFGVK_URL/archive/$ref/lsfg-vk-arm64-$ref.tar.gz" "$LSFGVK_MIT_URL#/LICENSE-MIT.md" "$TOMLPP_LICENSE_URL#/LICENSE-tomlplusplus")
[[ $sources == "$want" ]] || { printf 'build.sh: spec sources\n%s\nSOURCE.env\n%s\n' "$sources" "$want" >&2; exit 1; }
tarball=$top/SOURCES/lsfg-vk-arm64-$ref.tar.gz
curl -fsSL --retry 3 -o "$tarball" "$LSFGVK_URL/archive/$ref.tar.gz"
echo "$LSFGVK_SHA256  $tarball" | sha256sum -c -
curl -fsSL --retry 3 -o "$top/SOURCES/LICENSE-MIT.md" "$LSFGVK_MIT_URL"
echo "$LSFGVK_MIT_SHA256  $top/SOURCES/LICENSE-MIT.md" | sha256sum -c -
curl -fsSL --retry 3 -o "$top/SOURCES/LICENSE-tomlplusplus" "$TOMLPP_LICENSE_URL"
echo "$TOMLPP_LICENSE_SHA256  $top/SOURCES/LICENSE-tomlplusplus" | sha256sum -c -

rpmbuild -ba \
  --define "_topdir $top" \
  --define "commit $ref" \
  --define "snapdate $LSFGVK_DATE" \
  "$src/lsfg-vk.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$out/"
