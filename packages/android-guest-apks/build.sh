#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

[[ $(uname -m) == x86_64 ]] ||
  { echo "build.sh: the Android NDK and aapt2 run on x86_64 only, this is $(uname -m)" >&2; exit 1; }

ndk=/opt/android-ndk-$NDK_VERSION
grep -qxF "Pkg.Revision = $NDK_REVISION" "$ndk/source.properties" ||
  { echo "build.sh: $ndk is not NDK $NDK_REVISION" >&2; exit 1; }
tools=/opt/android-build-tools-$BUILD_TOOLS_VERSION
grep -qx "Pkg.Revision=$BUILD_TOOLS_VERSION" "$tools/source.properties" ||
  { echo "build.sh: $tools is not build-tools $BUILD_TOOLS_VERSION" >&2; exit 1; }
platform=/opt/android-platform-$SDK_API
grep -qx "AndroidVersion.ApiLevel=$SDK_API" "$platform/source.properties" ||
  { echo "build.sh: $platform is not the API $SDK_API platform" >&2; exit 1; }
testkey=/opt/android-testkey
{ echo "$SIGNER_PK8_SHA256  $testkey/testkey.pk8" | sha256sum -c --status - &&
  echo "$SIGNER_X509_SHA256  $testkey/testkey.x509.pem" | sha256sum -c --status -; } ||
  { echo "build.sh: $testkey is not the pinned AOSP test key" >&2; exit 1; }

props=/keys/keystore.properties
[[ -f $props ]] || { echo "build.sh: no $props, the helper key directory is mounted at /keys" >&2; exit 1; }
prop() { sed -n "s/^$1=//p" "$props"; }
store=$(prop storeFile)
store=/keys/${store##*/}
key_alias=$(prop keyAlias)
MICROOS_HELPER_STORE_PASS=$(prop storePassword)
MICROOS_HELPER_KEY_PASS=$(prop keyPassword)
export MICROOS_HELPER_STORE_PASS MICROOS_HELPER_KEY_PASS
[[ -f $store && -n $key_alias && -n $MICROOS_HELPER_STORE_PASS && -n $MICROOS_HELPER_KEY_PASS ]] ||
  { echo "build.sh: $props does not name a keystore in /keys, its alias and both passwords" >&2; exit 1; }

top=$(mktemp -d)
trap 'rm -rf "${top:?}"' EXIT
mkdir -p "$top/SOURCES"
cp "$src/overlay.manifest" "$src/lights/service.c" "$src/lights/android.hardware.lights-service.microos.rc" \
  "$src/lights/android.hardware.lights-service.microos.xml" "$src/vibrator/vibrator.c" \
  "$src/vibrator/android.hardware.vibrator-service.microos.rc" \
  "$src/vibrator/android.hardware.vibrator-service.microos.xml" "$src/build.sh" "$src/SOURCE.env" \
  "$src/vendor-etc/audio_policy_volumes.xml" "$src/vendor-etc/vintf/manifest.xml" "$src/hwc/hwcomposer.waydroid.so" \
  "$src/hwc/0001-hwc-private-roundtrip-queue.patch" "$src/hwc/hwc.env" "$src"/hwc/licenses/* "$top/SOURCES/"
for d in helper telephony display; do
  tar -C "$src" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --mode=u=rwX,go=rX \
    -czf "$top/SOURCES/microos-android-guest-apks-$d.tar.gz" "$d"
done

rpmbuild -ba --target aarch64 --define "_topdir $top" --define "ndk $ndk" --define "android_api $ANDROID_API" \
  --define "build_tools $tools" --define "platform $platform" --define "sdk_api $SDK_API" --define "testkey $testkey" \
  --define "helper_store $store" --define "helper_alias $key_alias" --define "helper_cert $HELPER_CERT_SHA256" \
  "$src/microos-android-guest-apks.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$out/"
