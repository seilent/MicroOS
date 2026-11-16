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
  export CCACHE_DIR=/ccache CCACHE_BASEDIR=$top CCACHE_NOHASHDIR=1 CCACHE_MAXSIZE=1G CCACHE_COMPRESS=1
  export CCACHE_SLOPPINESS=include_file_mtime,include_file_ctime
  export CMAKE_C_COMPILER_LAUNCHER=ccache CMAKE_CXX_COMPILER_LAUNCHER=ccache
  ccache -z > /dev/null
fi

copy() {
  local f=$1
  [[ -f $work/$f ]] || die "fetch.sh left no $work/$f"
  cp "$work/$f" "$top/SOURCES/$f"
}
copy "hyprsunset-$HYPRSUNSET_COMMIT.tar.gz"

dnf -y --disablerepo='*' install /deps/hyprutils-*.rpm /deps/hyprlang-*.rpm /deps/hyprland-protocols-devel-*.rpm

rpmbuild -ba \
  --define "_topdir $top" \
  --define "hyprsunset_version $HYPRSUNSET_VERSION" \
  --define "hyprsunset_commit $HYPRSUNSET_COMMIT" \
  "$src/hyprsunset.spec"

[[ ! -d /ccache ]] || ccache -s

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$out/"
