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
  export CMAKE_C_COMPILER_LAUNCHER=ccache CMAKE_CXX_COMPILER_LAUNCHER=ccache
  ccache -z > /dev/null
fi

copy() {
  local f=$1
  [[ -f $work/$f ]] || die "fetch.sh left no $work/$f"
  cp "$work/$f" "$top/SOURCES/$f"
}
copy "hyprutils-$HYPRUTILS_COMMIT.tar.gz"
copy "hyprlang-$HYPRLANG_COMMIT.tar.gz"
copy "hyprgraphics-$HYPRGRAPHICS_COMMIT.tar.gz"
copy "hyprwire-$HYPRWIRE_COMMIT.tar.gz"
copy "hyprland-protocols-$HYPRPROTOCOLS_COMMIT.tar.gz"
copy "aquamarine-$AQUAMARINE_COMMIT.tar.gz"
copy "hyprcursor-$HYPRCURSOR_COMMIT.tar.gz"
copy "source-v$HYPRLAND_VERSION.tar.gz"
copy "glaze-$GLAZE_COMMIT.tar.gz"
copy "hyprwayland-scanner-$HYPRWSCANNER_COMMIT.tar.gz"

rpmbuild -ba \
  --define "_topdir $top" \
  --define "stack $HYPR_STACK_REPO" \
  --define "hyprutils_commit $HYPRUTILS_COMMIT" \
  --define "hyprutils_version $HYPRUTILS_VERSION" \
  --define "hyprlang_commit $HYPRLANG_COMMIT" \
  --define "hyprlang_version $HYPRLANG_VERSION" \
  --define "hyprgraphics_commit $HYPRGRAPHICS_COMMIT" \
  --define "hyprgraphics_version $HYPRGRAPHICS_VERSION" \
  --define "hyprwire_commit $HYPRWIRE_COMMIT" \
  --define "hyprwire_version $HYPRWIRE_VERSION" \
  --define "hyprprotocols_commit $HYPRPROTOCOLS_COMMIT" \
  --define "aquamarine_commit $AQUAMARINE_COMMIT" \
  --define "aquamarine_version $AQUAMARINE_VERSION" \
  --define "hyprcursor_commit $HYPRCURSOR_COMMIT" \
  --define "hyprcursor_version $HYPRCURSOR_VERSION" \
  --define "hyprland_version $HYPRLAND_VERSION" \
  --define "glaze_commit $GLAZE_COMMIT" \
  --define "hyprwscanner_commit $HYPRWSCANNER_COMMIT" \
  --define "hyprwscanner_version $HYPRWSCANNER_VERSION" \
  "$src/hyprland.spec"

[[ ! -d /ccache ]] || ccache -s

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$src/PATCHES.md" "$out/"
