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

if [[ -d /ccache ]]; then
  export CCACHE_DIR=/ccache CCACHE_BASEDIR=$top CCACHE_NOHASHDIR=1 CCACHE_MAXSIZE=3G CCACHE_COMPRESS=1
  export CCACHE_SLOPPINESS=include_file_mtime,include_file_ctime
  ccache -z > /dev/null
fi

copy() {
  local f=$1
  [[ -f $work/$f ]] || die "fetch.sh left no $work/$f"
  cp "$work/$f" "$top/SOURCES/$f"
}
copy "hyprgrass-$HYPRGRASS_COMMIT.tar.gz"
copy "wf-touch-$WFTOUCH_COMMIT.tar.gz"
copy "hyprpm.toml"

mapfile -t deps < <(find /deps -maxdepth 1 -name '*.rpm' ! -name '*.src.rpm')
dnf -y --disablerepo='*' install "${deps[@]}"
hyprland_evr=$(rpm -q --qf '%{VERSION}-%{RELEASE}' hyprland)

rpmbuild -ba \
  --define "_topdir $top" \
  --define "hyprgrass_version $HYPRGRASS_VERSION" \
  --define "hyprgrass_commit $HYPRGRASS_COMMIT" \
  --define "hyprgrass_pins_ref $HYPRGRASS_PINS_REF" \
  --define "wftouch_commit $WFTOUCH_COMMIT" \
  --define "hyprland_evr $hyprland_evr" \
  "$src/hyprgrass.spec"

[[ ! -d /ccache ]] || ccache -s

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$out/"
