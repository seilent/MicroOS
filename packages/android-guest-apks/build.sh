#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir> <workdir>}
work=${2:?usage: build.sh <outdir> <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

[[ $(uname -m) == x86_64 ]] || { echo "build.sh: Google's aapt2 runs on x86_64 only, this is $(uname -m)" >&2; exit 1; }

tools=/opt/android-build-tools-$BUILD_TOOLS_VERSION
jar=/opt/android-platform-$ANDROID_API/android.jar
grep -qx "Pkg.Revision=$BUILD_TOOLS_VERSION" "$tools/source.properties" || { echo "build.sh: $tools is not build-tools $BUILD_TOOLS_VERSION" >&2; exit 1; }
[[ -f $jar ]] || { echo "build.sh: no $jar" >&2; exit 1; }
version=$(rpmspec -q --srpm --qf '%{VERSION}' "$src/microos-android-guest-apks.spec")
[[ $version == "${AOSP_TAG#android-}" ]] || { echo "build.sh: spec Version $version, SOURCE.env $AOSP_TAG" >&2; exit 1; }

sources=(
  "$NOTICE_SHA256 NOTICE"
  "$GESTURAL_MANIFEST_SHA256 NavigationBarModeGesturalOverlay/AndroidManifest.xml"
  "$GESTURAL_CONFIG_SHA256 NavigationBarModeGesturalOverlay/res/values/config.xml"
  "$GESTURAL_DIMENS_SHA256 NavigationBarModeGesturalOverlay/res/values/dimens.xml"
  "$GESTURAL_STRINGS_SHA256 NavigationBarModeGesturalOverlay/res/values/strings.xml"
  "$THREEBUTTON_MANIFEST_SHA256 NavigationBarMode3ButtonOverlay/AndroidManifest.xml"
  "$THREEBUTTON_CONFIG_SHA256 NavigationBarMode3ButtonOverlay/res/values/config.xml"
  "$THREEBUTTON_STRINGS_SHA256 NavigationBarMode3ButtonOverlay/res/values/strings.xml"
  "$SIGNER_PK8_SHA256 testkey.pk8"
  "$SIGNER_X509_SHA256 testkey.x509.pem"
)
for s in "${sources[@]}"; do
  echo "${s%% *}  $work/${s#* }" | sha256sum -c -
done

top=$(mktemp -d)
trap 'rm -rf "${top:?}"' EXIT
mkdir -p "$top/SOURCES"
product=$top/root/system/product

build_apk() {
  local manifest=$1 res=$2 apk=$3 obj=$top/obj/${3##*/}
  shift 3
  mkdir -p "$obj" "${apk%/*}"
  "$tools/aapt2" compile --dir "$res" -o "$obj/res.zip"
  "$tools/aapt2" link --manifest "$manifest" -I "$jar" \
    --min-sdk-version "$ANDROID_API" --target-sdk-version "$ANDROID_API" "$@" \
    -o "$obj/unsigned.apk" "$obj/res.zip"
  "$tools/zipalign" -c -p 4 "$obj/unsigned.apk"
  java --enable-native-access=ALL-UNNAMED -jar "$tools/lib/apksigner.jar" sign --key "$work/testkey.pk8" --cert "$work/testkey.x509.pem" \
    --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true --v4-signing-enabled false \
    --out "$apk" "$obj/unsigned.apk"
  java --enable-native-access=ALL-UNNAMED -jar "$tools/lib/apksigner.jar" verify --min-sdk-version "$ANDROID_API" "$apk"
}

mkdir -p "$top/obj"
"$tools/aapt2" compile --dir "$src/gestural-nohint/res" -o "$top/obj/gestural-nohint.zip"
build_apk "$work/NavigationBarModeGesturalOverlay/AndroidManifest.xml" "$work/NavigationBarModeGesturalOverlay/res" \
  "$product/overlay/NavigationBarModeGestural/NavigationBarModeGesturalOverlay.apk" --no-resource-deduping --no-resource-removal \
  -R "$top/obj/gestural-nohint.zip"
build_apk "$work/NavigationBarMode3ButtonOverlay/AndroidManifest.xml" "$work/NavigationBarMode3ButtonOverlay/res" \
  "$product/overlay/NavigationBarMode3Button/NavigationBarMode3ButtonOverlay.apk" --no-resource-deduping --no-resource-removal
build_apk "$src/nohint-systemui/AndroidManifest.xml" "$src/nohint-systemui/res" \
  "$product/overlay/NavigationBarNoHintSystemUI/NavigationBarNoHintSystemUIOverlay.apk" --no-resource-deduping --no-resource-removal
build_apk "$src/lineageparts/AndroidManifest.xml" "$src/lineageparts/res" "$product/app/LineagePartsStub/LineagePartsStub.apk"

tar -C "$top/root" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --mode=u=rwX,go=rX \
  -czf "$top/SOURCES/microos-android-guest-apks-built.tar.gz" system
tar -C "$work" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --mode=u=rwX,go=rX \
  -czf "$top/SOURCES/microos-android-guest-apks-overlays.tar.gz" NavigationBarModeGesturalOverlay NavigationBarMode3ButtonOverlay
tar -C "$src" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --mode=u=rwX,go=rX \
  -czf "$top/SOURCES/microos-android-guest-apks-lineageparts.tar.gz" lineageparts
tar -C "$src" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --mode=u=rwX,go=rX \
  -czf "$top/SOURCES/microos-android-guest-apks-nohint.tar.gz" gestural-nohint nohint-systemui
cp "$work/NOTICE" "$src/build.sh" "$src/fetch.sh" "$src/SOURCE.env" "$top/SOURCES/"

rpmbuild -ba --define "_topdir $top" "$src/microos-android-guest-apks.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$out/"
