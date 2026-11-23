#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-android-guest-apks.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"
version=${AOSP_TAG:?SOURCE.env has no AOSP_TAG}
version=${version#android-}
tools=/opt/android-build-tools-$BUILD_TOOLS_VERSION
overlay=/usr/share/guestos/android/system/product/overlay
app=/usr/share/guestos/android/system/product/app
licdir=/usr/share/licenses/microos-android-guest-apks
gestural=$overlay/NavigationBarModeGestural/NavigationBarModeGesturalOverlay.apk
threebutton=$overlay/NavigationBarMode3Button/NavigationBarMode3ButtonOverlay.apk
nohintui=$overlay/NavigationBarNoHintSystemUI/NavigationBarNoHintSystemUIOverlay.apk
stub=$app/LineagePartsStub/LineagePartsStub.apk

rpm=$(find "$dir" -maxdepth 1 -name "microos-android-guest-apks-$version-*.microos.noarch.rpm")
srpm=$(find "$dir" -maxdepth 1 -name "microos-android-guest-apks-$version-*.src.rpm")
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 || -z $srpm || $(wc -l <<<"$srpm") -ne 1 ]]; then
  echo "FAIL: expected one microos-android-guest-apks noarch RPM and one SRPM in $dir" >&2
  exit 1
fi
others=$(find "$dir" -maxdepth 1 -name '*.rpm' ! -samefile "$rpm" ! -samefile "$srpm")
if [[ -n $others ]]; then fail "other RPMs: $others"; fi

if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi
if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "release"; fi
if [[ $(rpm -qp --qf '%{SOURCERPM}' "$rpm") != "${srpm##*/}" ]]; then fail "SOURCERPM"; fi
if [[ $(rpm -qp --qf '%{LICENSE}' "$rpm") != 'Apache-2.0 AND GPL-2.0-or-later' ]]; then fail "license tag: $(rpm -qp --qf '%{LICENSE}' "$rpm")"; fi
if requires=$(rpm -qp --requires "$rpm" | grep -v '^rpmlib('); then fail "requires: $requires"; fi

sources=$(rpm -qp --qf '[%{SOURCE}\n]' "$srpm" | sort)
want=$(printf '%s\n' microos-android-guest-apks-built.tar.gz microos-android-guest-apks-overlays.tar.gz \
  microos-android-guest-apks-lineageparts.tar.gz microos-android-guest-apks-nohint.tar.gz NOTICE build.sh fetch.sh SOURCE.env | sort)
if [[ $sources != "$want" ]]; then fail "SRPM sources: $(tr '\n' ' ' <<<"$sources")"; fi

files=$(rpm -qlp "$rpm" | LC_ALL=C sort)
expected=$(printf '%s\n' /usr/share/guestos /usr/share/guestos/android /usr/share/guestos/android/system \
  /usr/share/guestos/android/system/product "$overlay" "${gestural%/*}" "$gestural" "${threebutton%/*}" "$threebutton" \
  "${nohintui%/*}" "$nohintui" \
  "$app" "${stub%/*}" "$stub" "$licdir" "$licdir/NOTICE" | LC_ALL=C sort)
if [[ $files != "$expected" ]]; then fail "file list: $(diff <(echo "$expected") <(echo "$files") | grep '^[<>]' | tr '\n' ' ')"; fi
modes=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk '$1 != "drwxr-xr-x" && $1 != "-rw-r--r--"')
if [[ -n $modes ]]; then fail "modes other than 755 dirs and 644 files: $modes"; fi

tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
mkdir "$tmp/root" "$tmp/src"
rpm2cpio "$rpm" > "$tmp/rpm.cpio"
rpm2cpio "$srpm" > "$tmp/srpm.cpio"
(cd "$tmp/root" && cpio -idm --quiet < "$tmp/rpm.cpio")
(cd "$tmp/src" && cpio -idm --quiet < "$tmp/srpm.cpio")
root=$tmp/root

if ! echo "$NOTICE_SHA256  $root$licdir/NOTICE" | sha256sum -c --status -; then fail "$licdir/NOTICE is not frameworks/base NOTICE"; fi
if [[ -n $(find "$tmp/src" -name 'testkey*' -o -name '*.pk8' -o -name '*.pem' -o -name 'android.jar' -o -name '*.zip') ]]; then
  fail "the SRPM holds a key or an SDK file: $(find "$tmp/src" -name 'testkey*' -o -name '*.pk8' -o -name '*.pem' -o -name 'android.jar' -o -name '*.zip')"
fi
apks=$(tar -tzf "$tmp/src/microos-android-guest-apks-built.tar.gz" | grep -v '/$' | LC_ALL=C sort | paste -sd' ')
if [[ $apks != "system/product/app/LineagePartsStub/LineagePartsStub.apk system/product/overlay/NavigationBarMode3Button/NavigationBarMode3ButtonOverlay.apk system/product/overlay/NavigationBarModeGestural/NavigationBarModeGesturalOverlay.apk system/product/overlay/NavigationBarNoHintSystemUI/NavigationBarNoHintSystemUIOverlay.apk" ]]; then
  fail "the APK tarball holds $apks"
fi
parts=$(tar -tzf "$tmp/src/microos-android-guest-apks-lineageparts.tar.gz" | grep -v '/$' | LC_ALL=C sort | paste -sd' ')
if [[ $parts != 'lineageparts/AndroidManifest.xml lineageparts/res/xml/parts_catalog.xml' ]]; then
  fail "the LineageParts tarball holds $parts"
fi
hint=$(tar -tzf "$tmp/src/microos-android-guest-apks-nohint.tar.gz" | grep -v '/$' | LC_ALL=C sort | paste -sd' ')
if [[ $hint != 'gestural-nohint/res/values/dimens.xml nohint-systemui/AndroidManifest.xml nohint-systemui/res/values/config.xml' ]]; then
  fail "the no hint tarball holds $hint"
fi
mkdir "$tmp/overlays"
tar -xzf "$tmp/src/microos-android-guest-apks-overlays.tar.gz" -C "$tmp/overlays"
pins=(
  "$GESTURAL_MANIFEST_SHA256 NavigationBarModeGesturalOverlay/AndroidManifest.xml"
  "$GESTURAL_CONFIG_SHA256 NavigationBarModeGesturalOverlay/res/values/config.xml"
  "$GESTURAL_DIMENS_SHA256 NavigationBarModeGesturalOverlay/res/values/dimens.xml"
  "$GESTURAL_STRINGS_SHA256 NavigationBarModeGesturalOverlay/res/values/strings.xml"
  "$THREEBUTTON_MANIFEST_SHA256 NavigationBarMode3ButtonOverlay/AndroidManifest.xml"
  "$THREEBUTTON_CONFIG_SHA256 NavigationBarMode3ButtonOverlay/res/values/config.xml"
  "$THREEBUTTON_STRINGS_SHA256 NavigationBarMode3ButtonOverlay/res/values/strings.xml"
)
for p in "${pins[@]}"; do
  echo "${p%% *}  $tmp/overlays/${p#* }" | sha256sum -c --status - || fail "${p#* } in the SRPM is not the pinned AOSP file"
done
if [[ $(find "$tmp/overlays" -type f | wc -l) != "${#pins[@]}" ]]; then fail "the overlay tarball holds more than the pinned files"; fi

check_signed() {
  local apk=$root$1 out
  "$tools/zipalign" -c -p 4 "$apk" > /dev/null || fail "$1 is not 4 byte aligned"
  [[ $(unzip -Z "$apk" resources.arsc | awk '{ print $6 }') == stor ]] || fail "$1 stores resources.arsc compressed"
  out=$(java --enable-native-access=ALL-UNNAMED -jar "$tools/lib/apksigner.jar" verify -v --print-certs --min-sdk-version "$ANDROID_API" "$apk") || { fail "$1 signature"; return; }
  grep -qx 'Verified using v3 scheme (APK Signature Scheme v3): true' <<<"$out" || fail "$1 has no v3 signature"
  grep -qx 'Number of signers: 1' <<<"$out" || fail "$1 signers"
  grep -qx "Signer #1 certificate SHA-256 digest: $SIGNER_CERT_SHA256" <<<"$out" || fail "$1 is not signed with the AOSP test key"
}

check_badging() {
  local apk=$root$1 pkg=$2
  badging=$("$tools/aapt2" dump badging "$apk") || { fail "aapt2 cannot read $1"; return 1; }
  grep -q "^package: name='$pkg' versionCode='1' versionName='1.0' " <<<"$badging" || fail "$1 package line: $(head -n 1 <<<"$badging")"
  grep -qx "sdkVersion:'30'" <<<"$badging" || fail "$1 minSdkVersion"
  grep -qx "targetSdkVersion:'30'" <<<"$badging" || fail "$1 targetSdkVersion"
}

check_overlay() {
  local apk=$root$1 pkg=$2 mode=$3 out
  if [[ $(unzip -Z1 "$apk" | sort | paste -sd' ') != 'AndroidManifest.xml resources.arsc' ]]; then fail "$1 entries: $(unzip -Z1 "$apk" | paste -sd' ')"; fi
  check_badging "$1" "$pkg" || return 0
  grep -qx "overlay: targetPackage='android' priority='1' isStatic='false'" <<<"$badging" || fail "$1 overlay line"
  out=$("$tools/aapt2" dump xmltree --file AndroidManifest.xml "$apk") || { fail "aapt2 cannot dump the manifest of $1"; return; }
  grep -qF ':category(0x010103e8)="com.android.internal.navigation_bar_mode"' <<<"$out" || fail "$1 overlay category"
  out=$("$tools/aapt2" dump resources "$apk" | awk '$3 == "integer/config_navBarInteractionMode" { getline; print $2 }') \
    || { fail "aapt2 cannot dump the resources of $1"; return; }
  [[ $out == "$mode" ]] || fail "$1 config_navBarInteractionMode is $out, not $mode"
  check_signed "$1"
}

check_nohint() {
  local apk=$root$1 pkg=$2 overlay=$3 want=$4 out
  if [[ $(unzip -Z1 "$apk" | sort | paste -sd' ') != 'AndroidManifest.xml resources.arsc' ]]; then fail "$1 entries: $(unzip -Z1 "$apk" | paste -sd' ')"; fi
  check_badging "$1" "$pkg" || return 0
  grep -qx "$overlay" <<<"$badging" || fail "$1 overlay line"
  out=$("$tools/aapt2" dump xmltree --file AndroidManifest.xml "$apk") || { fail "aapt2 cannot dump the manifest of $1"; return; }
  grep -qF ':hasCode(0x0101000c)=false' <<<"$out" || fail "$1 does not set hasCode false"
  if grep -qF ':category(' <<<"$out"; then fail "$1 has an overlay category"; fi
  out=$("$tools/aapt2" dump resources "$apk" | awk '$1 == "resource" { name = $3; getline; print name "=" $2 }' | LC_ALL=C sort | paste -sd' ') \
    || { fail "aapt2 cannot dump the resources of $1"; return; }
  [[ $out == "$want" ]] || fail "$1 resources: $out"
  check_signed "$1"
}

check_stub() {
  local apk=$root$1 out keys
  if [[ $(unzip -Z1 "$apk" | sort | paste -sd' ') != 'AndroidManifest.xml res/xml/parts_catalog.xml resources.arsc' ]]; then
    fail "$1 entries: $(unzip -Z1 "$apk" | paste -sd' ')"
  fi
  check_badging "$1" org.lineageos.lineageparts || return 0
  if grep -qE '^(launchable-activity|uses-permission|overlay):' <<<"$badging"; then fail "$1 declares an activity, a permission or an overlay"; fi
  out=$("$tools/aapt2" dump xmltree --file AndroidManifest.xml "$apk") || { fail "aapt2 cannot dump the manifest of $1"; return; }
  grep -qF ':hasCode(0x0101000c)=false' <<<"$out" || fail "$1 does not set hasCode false"
  if grep -qE '^ *E: (activity|activity-alias|service|receiver|provider|uses-permission|instrumentation) ' <<<"$out"; then
    fail "$1 declares a component or a permission"
  fi
  if grep -q sharedUserId <<<"$out"; then fail "$1 sets a sharedUserId"; fi
  out=$("$tools/aapt2" dump resources "$apk" | awk '$1 == "resource" { print $3 }') || { fail "aapt2 cannot dump the resources of $1"; return; }
  [[ $out == xml/parts_catalog ]] || fail "$1 resources: ${out//$'\n'/ }"
  out=$("$tools/aapt2" dump xmltree --file res/xml/parts_catalog.xml "$apk") || { fail "aapt2 cannot dump the catalog of $1"; return; }
  grep -qE '^ *E: parts-catalog ' <<<"$out" || fail "$1 catalog root is not parts-catalog"
  [[ $(grep -cE '^ *E: part ' <<<"$out") == 8 ]] || fail "$1 catalog does not hold 8 parts"
  keys=$(sed -n 's/.*:key(0x010101e8)="\([^"]*\)".*/\1/p' <<<"$out" | LC_ALL=C sort | paste -sd' ')
  [[ $keys == 'battery_lights charging_sounds_settings livedisplay long_screen_settings notification_lights perf_profile_settings rotation touchscreen_gesture_settings' ]] \
    || fail "$1 catalog keys: $keys"
  check_signed "$1"
}

check_overlay "$gestural" com.android.internal.systemui.navbar.gestural 2
check_overlay "$threebutton" com.android.internal.systemui.navbar.threebutton 0
dimens() { "$tools/aapt2" dump resources "$root$1" | awk '$1 == "resource" && $3 ~ /^dimen\// { name = $3; getline; print name "=" $2 }' | LC_ALL=C sort | paste -sd' '; }
out=$(dimens "$gestural")
[[ $out == 'dimen/config_backGestureInset=24.000000dp dimen/navigation_bar_frame_height=48.000000dp dimen/navigation_bar_gesture_height=32.000000dp dimen/navigation_bar_height=0.000000dp dimen/navigation_bar_height_landscape=0.000000dp dimen/navigation_bar_width=0.000000dp' ]] \
  || fail "$gestural dimens: $out"
out=$(dimens "$threebutton")
[[ -z $out ]] || fail "$threebutton dimens: $out"
check_nohint "$nohintui" net.seilent.microos.overlay.navbar.nohint.systemui \
  "overlay: targetPackage='com.android.systemui' priority='1' isStatic='true'" 'string/config_navBarLayoutHandle="back[40AC];;ime_switcher[40AC]"'
check_stub "$stub"

exit "$rc"
