#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir> <workdir>}
work=${2:?usage: build.sh <outdir> <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

[[ $(uname -m) == x86_64 ]] || { echo "build.sh: the Android NDK runs on x86_64 only, this is $(uname -m)" >&2; exit 1; }

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"

ndk=/opt/android-ndk-$NDK_VERSION
grep -qxF "Pkg.Revision = $NDK_REVISION" "$ndk/source.properties" || { echo "build.sh: $ndk is not NDK $NDK_REVISION" >&2; exit 1; }
defs=(
  --define "ndk $ndk"
  --define "android_api $ANDROID_API"
  --define "libdrm_version $LIBDRM_VERSION"
  --define "fossilize_ref $FOSSILIZE_REF"
  --define "rapidjson_ref $RAPIDJSON_REF"
  --define "angle_ref $ANGLE_REF"
)
version=$(rpmspec -q --srpm --qf '%{VERSION}' "${defs[@]}" "$src/microos-android-guestos.spec")
[[ $version == "$MESA_VERSION" ]] || { echo "build.sh: spec Version $version, SOURCE.env $MESA_VERSION" >&2; exit 1; }

sources=(
  "$MESA_SHA256 mesa-$MESA_VERSION.tar.xz"
  "$LIBDRM_SHA256 libdrm-$LIBDRM_VERSION.tar.xz"
  "$FOSSILIZE_SHA256 Fossilize-$FOSSILIZE_REF.tar.gz"
  "$RAPIDJSON_SHA256 rapidjson-$RAPIDJSON_REF.tar.gz"
  "$ANGLE_LICENSE_SHA256 angle-$ANGLE_REF-LICENSE"
)
for s in "${sources[@]}"; do
  echo "${s%% *}  $work/${s#* }" | sha256sum -c -
  cp "$work/${s#* }" "$top/SOURCES/"
done
cp "$src/microos-noubwc.rc" "$src/build.sh" "$src/fetch.sh" "$src/licenses.py" "$src/SOURCE.env" "$top/SOURCES/"

if [[ -n ${CCACHE_DIR:-} ]] && command -v ccache >/dev/null; then
  defs+=(--define "ccache 1")
  export CCACHE_BASEDIR=$top CCACHE_NOHASHDIR=true
fi

rpmbuild -ba --target aarch64 --define "_topdir $top" "${defs[@]}" "$src/microos-android-guestos.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$out/"
