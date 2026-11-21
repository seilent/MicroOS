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
copy "hyprtoolkit-$HYPRTOOLKIT_COMMIT.tar.gz"
copy "hyprland-guiutils-$GUIUTILS_COMMIT.tar.gz"
copy "hyprwayland-scanner-$HYPRWSCANNER_COMMIT.tar.gz"

dnf -y --disablerepo='*' install /deps/hyprutils-*.rpm /deps/hyprlang-*.rpm /deps/hyprgraphics-*.rpm /deps/aquamarine-*.rpm

rpmbuild -ba \
  --define "_topdir $top" \
  --define "hyprtoolkit_version $HYPRTOOLKIT_VERSION" \
  --define "hyprtoolkit_commit $HYPRTOOLKIT_COMMIT" \
  --define "hyprwscanner_version $HYPRWSCANNER_VERSION" \
  --define "hyprwscanner_commit $HYPRWSCANNER_COMMIT" \
  "$src/hyprtoolkit.spec"
dnf -y --disablerepo='*' install "$top"/RPMS/*/hyprtoolkit-*.rpm

rpmbuild -ba \
  --define "_topdir $top" \
  --define "guiutils_version $GUIUTILS_VERSION" \
  --define "guiutils_commit $GUIUTILS_COMMIT" \
  "$src/hyprland-guiutils.spec"

[[ ! -d /ccache ]] || ccache -s

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$out/"
