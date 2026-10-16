#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"

version=$(rpmspec -q --srpm --qf '%{VERSION}' --define "commit $ESDE_REF" "$src/es-de.spec")
[[ $version == "$ESDE_VERSION" ]] || { echo "build.sh: spec Version $version, SOURCE.env $ESDE_VERSION" >&2; exit 1; }

tarball=$top/SOURCES/emulationstation-de-$ESDE_REF.tar.gz
curl -fsSL --retry 3 -o "$tarball" "$ESDE_URL/-/archive/$ESDE_REF/emulationstation-de-$ESDE_REF.tar.gz"
echo "$ESDE_SHA256  $tarball" | sha256sum -c -
cp "$src"/patches/*.patch "$src/escape-test.cpp" "$src/rocknix-test.cpp" "$top/SOURCES/"

launcher=()
if [[ -n ${CCACHE_DIR:-} ]] && command -v ccache >/dev/null; then
  launcher=(--define "ccache_launcher -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache")
  export CCACHE_BASEDIR=$top CCACHE_NOHASHDIR=true
fi

rpmbuild -ba --define "_topdir $top" --define "commit $ESDE_REF" "${launcher[@]}" "$src/es-de.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$src/PATCHES.md" "$out/"
