#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES" "$top/vendor"

ref=$INPUTPLUMBER_REF
version=$(rpmspec -q --srpm --qf '%{VERSION}' --define "commit $ref" "$src/inputplumber.spec")
[[ $version == "$INPUTPLUMBER_VERSION" ]] || { echo "build.sh: spec Version $version, SOURCE.env $INPUTPLUMBER_VERSION" >&2; exit 1; }
tarball=$top/SOURCES/inputplumber-$ref.tar.gz
curl -fsSL --retry 3 -o "$tarball" "$INPUTPLUMBER_URL/archive/$ref.tar.gz"
echo "$INPUTPLUMBER_SHA256  $tarball" | sha256sum -c -

tar -xzf "$tarball" -C "$top/vendor"
(
  cd "$top/vendor/InputPlumber-$ref"
  mkdir .cargo
  cargo vendor --locked vendor > .cargo/config.toml
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - .cargo vendor \
    | zstd -q -T0 -o "$top/SOURCES/inputplumber-$INPUTPLUMBER_VERSION-vendor.tar.zst"
)
rm -rf "$top/vendor"

rpmbuild -ba \
  --define "_topdir $top" \
  --define "commit $ref" \
  "$src/inputplumber.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$out/"
