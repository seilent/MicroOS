#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

shopt -s nullglob
deps=(/deps/*.{aarch64,x86_64,noarch}.rpm)
shopt -u nullglob
(( ${#deps[@]} )) || { echo "build.sh: no microset RPMs in /deps" >&2; exit 1; }
dnf -y --setopt=install_weak_deps=False install "${deps[@]}"

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

if [[ -n ${MICRODAP_SRC:-} ]]; then
  ref=local
  date=$(date -u +%Y%m%d)
  tar -C "$MICRODAP_SRC" --exclude=./.git --exclude=./build --exclude=./out --exclude=./dist \
    --transform "s,^\.,MicroDAP-$ref," -czf "$top/SOURCES/microdap-$ref.tar.gz" .
  touch "$out/dirty"
else
  [[ -n $MICRODAP_REF && -n $MICRODAP_DATE && -n $MICRODAP_SHA256 ]] \
    || { echo "build.sh: MICRODAP_REF, MICRODAP_DATE and MICRODAP_SHA256 are not pinned, set MICRODAP_SRC" >&2; exit 1; }
  ref=$MICRODAP_REF
  date=$MICRODAP_DATE
  tarball=$top/SOURCES/microdap-$ref.tar.gz
  curl -fsSL --retry 3 -o "$tarball" "$MICRODAP_URL/archive/$ref.tar.gz"
  echo "$MICRODAP_SHA256  $tarball" | sha256sum -c -
fi

rpmbuild -ba \
  --define "_topdir $top" \
  --define "commit $ref" \
  --define "snapdate $date" \
  "$src/microdap.spec"

[[ ! -d /ccache ]] || ccache -s

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
