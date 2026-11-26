#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir> <workdir>}
work=${2:?usage: build.sh <outdir> <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

fail() { echo "build.sh: $*" >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || fail "zipalign runs on x86_64 only, this is $(uname -m)"

tools=/opt/android-build-tools-$BUILD_TOOLS_VERSION
grep -qx "Pkg.Revision=$BUILD_TOOLS_VERSION" "$tools/source.properties" || fail "$tools is not build-tools $BUILD_TOOLS_VERSION"
key=/opt/android-platform-key
{ echo "$PLATFORM_PK8_SHA256  $key/platform.pk8" | sha256sum -c --status - &&
  echo "$PLATFORM_X509_SHA256  $key/platform.x509.pem" | sha256sum -c --status -; } ||
  fail "$key is not the pinned AOSP platform key"
smali=/opt/smali-$SMALI_VERSION
jars=0
while read -r sum url; do
  echo "$sum  $smali/${url##*/}" | sha256sum -c --status - || fail "$smali/${url##*/} is not the pinned jar"
  jars=$((jars + 1))
done <<< "$SMALI_JARS"
[[ $(find "$smali" -type f | wc -l) == "$jars" ]] || fail "$smali holds jars SOURCE.env does not pin"

for s in "$SYSTEMUI_SHA256 SystemUI.apk" "$FRAMEWORK_RES_SHA256 framework-res.apk" \
  "$SYSTEMUI_NOTICE_SHA256 NOTICE.SystemUI"; do
  echo "${s%% *}  $work/${s#* }" | sha256sum -c - || fail "$work/${s#* } is not the file SOURCE.env pins"
done

top=$(mktemp -d)
trap 'rm -rf "${top:?}"' EXIT
mkdir -p "$top/SOURCES"
cp "$src/SOURCE.env" "$src/build.sh" "$src/fetch.sh" "$src/0001-navbar-right-in-landscape.patch" \
  "$src/navbar-check.py" "$src/NOTICE" "$src/systemui.manifest" "$work/NOTICE.SystemUI" "$top/SOURCES/"

rpmbuild -ba --define "_topdir $top" --define "systemui_stock $work/SystemUI.apk" --define "build_tools $tools" \
  --define "framework_res $work/framework-res.apk" --define "platform_key $key" --define "smali $smali" \
  --define "sdk_api $SDK_API" --define "platform_cert $PLATFORM_CERT_SHA256" "$src/microos-android-guest-systemui.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$out/"
