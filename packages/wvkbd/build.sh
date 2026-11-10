#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir> <workdir>}
work=${2:?usage: build.sh <outdir> <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

die() { echo "build.sh: $*" >&2; exit 1; }

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"

sources=$(rpmspec -P \
  --define "wvkbd_version $WVKBD_VERSION" \
  --define "wvkbd_commit $WVKBD_COMMIT" \
  --define "wvkbd_layout $WVKBD_LAYOUT" \
  "$src/wvkbd.spec" | awk '/^Source[0-9]*:/ { sub(/^Source[0-9]*:[[:space:]]*/, ""); sub(/#.*/, ""); print }')
want=$(printf '%s\n' \
  "$WVKBD_URL/archive/$WVKBD_COMMIT.tar.gz" \
  "$WVKBD_LICENSE_URL" "$WVKBD_COPYING_URL" "$WVKBD_WESTON_URL")
[[ $sources == "$want" ]] || die "spec sources
$sources
SOURCE.env
$want"

patches=$(rpmspec -P \
  --define "wvkbd_version $WVKBD_VERSION" \
  --define "wvkbd_commit $WVKBD_COMMIT" \
  --define "wvkbd_layout $WVKBD_LAYOUT" \
  "$src/wvkbd.spec" | awk '/^Patch[0-9]*:/ { print $2 }')
want=$(cd "$src/patches" && printf '%s\n' *.patch)
[[ $patches == "$want" ]] || die "spec patches
$patches
patches/
$want"

copy() {
  [[ -f $work/$1 ]] || die "fetch.sh left no $work/$1"
  cp "$work/$1" "$top/SOURCES/$1"
}
copy "wvkbd-$WVKBD_COMMIT.tar.gz"
copy LICENSE
copy COPYING
copy COPYING_WESTON
cp "$src/patches"/*.patch "$top/SOURCES/"

rpmbuild -ba \
  --define "_topdir $top" \
  --define "wvkbd_version $WVKBD_VERSION" \
  --define "wvkbd_commit $WVKBD_COMMIT" \
  --define "wvkbd_layout $WVKBD_LAYOUT" \
  "$src/wvkbd.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$src/PATCHES.md" "$out/"
