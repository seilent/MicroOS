#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

[[ $(uname -m) == x86_64 ]] ||
  { echo "build.sh: the Android NDK runs on x86_64 only, this is $(uname -m)" >&2; exit 1; }

ndk=/opt/android-ndk-$NDK_VERSION
grep -qxF "Pkg.Revision = $NDK_REVISION" "$ndk/source.properties" ||
  { echo "build.sh: $ndk is not NDK $NDK_REVISION" >&2; exit 1; }

top=$(mktemp -d)
trap 'rm -rf "${top:?}"' EXIT
mkdir -p "$top/SOURCES"
cp "$src/overlay.manifest" "$src/lights/service.c" "$src/lights/android.hardware.lights-service.microos.rc" \
  "$src/lights/android.hardware.lights-service.microos.xml" "$src/build.sh" "$src/SOURCE.env" "$top/SOURCES/"

rpmbuild -ba --target aarch64 --define "_topdir $top" --define "ndk $ndk" --define "android_api $ANDROID_API" \
  "$src/microos-android-guest-apks.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$out/"
