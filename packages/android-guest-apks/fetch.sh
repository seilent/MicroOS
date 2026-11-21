#!/usr/bin/env bash
set -euo pipefail

work=${1:?usage: fetch.sh <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

fetch() {
  mkdir -p "$(dirname "$work/$4")"
  curl -fsSL --retry 3 "https://android.googlesource.com/platform/$1/+/$2?format=TEXT" | base64 -d > "$work/$4"
  echo "$3  $work/$4" | sha256sum -c -
}

overlay() {
  fetch frameworks/base "$FRAMEWORKS_BASE_REF/packages/overlays/$1" "$2" "$1"
}

fetch frameworks/base "$FRAMEWORKS_BASE_REF/NOTICE" "$NOTICE_SHA256" NOTICE
overlay NavigationBarModeGesturalOverlay/AndroidManifest.xml "$GESTURAL_MANIFEST_SHA256"
overlay NavigationBarModeGesturalOverlay/res/values/config.xml "$GESTURAL_CONFIG_SHA256"
overlay NavigationBarModeGesturalOverlay/res/values/dimens.xml "$GESTURAL_DIMENS_SHA256"
overlay NavigationBarModeGesturalOverlay/res/values/strings.xml "$GESTURAL_STRINGS_SHA256"
overlay NavigationBarMode3ButtonOverlay/AndroidManifest.xml "$THREEBUTTON_MANIFEST_SHA256"
overlay NavigationBarMode3ButtonOverlay/res/values/config.xml "$THREEBUTTON_CONFIG_SHA256"
overlay NavigationBarMode3ButtonOverlay/res/values/strings.xml "$THREEBUTTON_STRINGS_SHA256"
fetch build "$BUILD_REF/target/product/security/testkey.pk8" "$SIGNER_PK8_SHA256" testkey.pk8
fetch build "$BUILD_REF/target/product/security/testkey.x509.pem" "$SIGNER_X509_SHA256" testkey.x509.pem
