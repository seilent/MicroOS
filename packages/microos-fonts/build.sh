#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir> <workdir>}
work=${2:?usage: build.sh <outdir> <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"
cp -a "$work"/. "$top/SOURCES/"

rpmbuild -ba \
  --define "_topdir $top" \
  --define "snapdate $FONTS_SNAPDATE" \
  --define "gf_ref $GF_REF" \
  --define "mdi_ref $MDI_REF" \
  --define "jbm_release $JBM_RELEASE" \
  --define "jbm_ofl_ref $JBM_OFL_REF" \
  "$src/microos-fonts.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$out/"
