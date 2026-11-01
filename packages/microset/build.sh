#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

top=$(mktemp -d)
chmod 755 "$top"
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"

if [[ -d /ccache ]]; then
  export CCACHE_DIR=/ccache CCACHE_BASEDIR=$top CCACHE_NOHASHDIR=1 CCACHE_MAXSIZE=1G CCACHE_COMPRESS=1
  export CCACHE_SLOPPINESS=include_file_mtime,include_file_ctime
  export CMAKE_C_COMPILER_LAUNCHER=ccache CMAKE_CXX_COMPILER_LAUNCHER=ccache
  ccache -z > /dev/null
fi

if [[ -n ${MICROSET_SRC:-} ]]; then
  ref=local
  date=$(date -u +%Y%m%d)
  tar -C "$MICROSET_SRC" --exclude=./.git --exclude=./build --exclude=./out \
    --transform "s,^\.,MicroSET-$ref," -czf "$top/SOURCES/microset-$ref.tar.gz" .
  touch "$out/dirty"
else
  ref=$MICROSET_REF
  date=$MICROSET_DATE
  tarball=$top/SOURCES/microset-$ref.tar.gz
  curl -fsSL --retry 3 -o "$tarball" "$MICROSET_URL/archive/$ref.tar.gz"
  echo "$MICROSET_SHA256  $tarball" | sha256sum -c -
fi

curl -fsSL --retry 3 -o "$top/SOURCES/Selawik_Release.zip" "$SELAWIK_URL"
echo "$SELAWIK_SHA256  $top/SOURCES/Selawik_Release.zip" | sha256sum -c -
curl -fsSL --retry 3 -o "$top/SOURCES/LICENSE.txt" "$SELAWIK_LICENSE_URL"
echo "$SELAWIK_LICENSE_SHA256  $top/SOURCES/LICENSE.txt" | sha256sum -c -

rpmbuild -ba \
  --define "_topdir $top" \
  --define "commit $ref" \
  --define "snapdate $date" \
  "$src/microset.spec"

[[ ! -d /ccache ]] || ccache -s

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
