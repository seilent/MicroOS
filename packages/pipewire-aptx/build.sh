#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"

version=$(rpmspec -q --srpm --qf '%{VERSION}' --define "commit $LIBFREEAPTX_REF" "$src/libfreeaptx.spec")
[[ $version == "$LIBFREEAPTX_VERSION" ]] || { echo "build.sh: libfreeaptx spec Version $version, SOURCE.env $LIBFREEAPTX_VERSION" >&2; exit 1; }

fetch() {
  local file=$top/SOURCES/$1 url=$2 sha256=$3
  curl -fsSL --retry 3 -o "$file" "$url"
  echo "$sha256  $file" | sha256sum -c -
}
fetch "libfreeaptx-$LIBFREEAPTX_REF.tar.gz" "$LIBFREEAPTX_URL/archive/$LIBFREEAPTX_REF.tar.gz" "$LIBFREEAPTX_SHA256"
fetch "pipewire-$PIPEWIRE_EVR.src.rpm" \
  "$KOJI_URL/pipewire/${PIPEWIRE_EVR%%-*}/${PIPEWIRE_EVR#*-}/data/signed/$KOJI_KEY/src/pipewire-$PIPEWIRE_EVR.src.rpm" "$PIPEWIRE_SRPM_SHA256"

rpmbuild -ba --define "_topdir $top" --define "commit $LIBFREEAPTX_REF" "$src/libfreeaptx.spec"
dnf -y --setopt=install_weak_deps=False install "$top"/RPMS/*/libfreeaptx-*.rpm
rpmbuild -ba --define "_topdir $top" --define "pipewire_evr $PIPEWIRE_EVR" --define "koji_key $KOJI_KEY" \
  "$src/pipewire-codec-aptx.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$out/"
