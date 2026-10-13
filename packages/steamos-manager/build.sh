#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES" "$top/vendor"

ref=$STEAMOS_MANAGER_REF
version=$(rpmspec -q --srpm --qf '%{VERSION}' --define "commit $ref" "$src/steamos-manager.spec")
[[ $version == "$STEAMOS_MANAGER_VERSION" ]] || { echo "build.sh: spec Version $version, SOURCE.env $STEAMOS_MANAGER_VERSION" >&2; exit 1; }
tarball=$top/SOURCES/steamos-manager-$ref.tar.gz
curl -fsSL --retry 3 -o "$tarball" "$STEAMOS_MANAGER_URL/-/archive/$ref/steamos-manager-$ref.tar.gz"
echo "$STEAMOS_MANAGER_SHA256  $tarball" | sha256sum -c -

tar -xzf "$tarball" -C "$top/vendor"
(
  cd "$top/vendor/steamos-manager-$ref"
  mkdir .cargo
  cargo vendor --locked vendor > .cargo/config.toml
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - .cargo vendor \
    | zstd -q -T0 -o "$top/SOURCES/steamos-manager-$ref-vendor.tar.zst"
)
rm -rf "$top/vendor"
cp "$src"/patches/*.patch "$src/com.steampowered.SteamOSManager1.conf" "$top/SOURCES/"

rpmbuild -ba \
  --define "_topdir $top" \
  --define "commit $ref" \
  "$src/steamos-manager.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$out/"
