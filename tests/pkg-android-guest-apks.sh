#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-android-guest-apks.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"
readelf=/opt/android-ndk-$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf
tools=/opt/android-build-tools-$BUILD_TOOLS_VERSION
share=/usr/share/microos-android
overlay=$share/overlay
manifest=$share/overlay.manifest
vendorpin=$share/overlay.vendor
hal=android.hardware.lights-service.microos
bin=$overlay/system/bin/hw/$hal
initrc=$overlay/system/etc/init/$hal.rc
vintf=$overlay/system/etc/vintf/manifest/$hal.xml
helper=$overlay/system/priv-app/MicroOsHelper/MicroOsHelper.apk
rro=$overlay/system/product/overlay/MicroOsTelephony/MicroOsTelephonyOverlay.apk
display=$overlay/system/product/overlay/MicroOsDisplay/MicroOsDisplayOverlay.apk
volumes=$overlay/vendor/etc/audio_policy_volumes.xml
hwc=$overlay/vendor/lib64/hw/hwcomposer.waydroid.so
licdir=/usr/share/licenses/microos-android-guest-apks
licenses=(COPYING.wayland COPYING.wayland-protocols LICENSE.hardware-waydroid LICENSE.libffi LICENSE.libxkbcommon
  NOTICE.bionic NOTICE.hardware-waydroid NOTICE.libxkbcommon-parser)

rpm=$(find "$dir" -maxdepth 1 -name 'microos-android-guest-apks-1-*.microos.aarch64.rpm')
srpm=$(find "$dir" -maxdepth 1 -name 'microos-android-guest-apks-1-*.src.rpm')
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 || -z $srpm || $(wc -l <<<"$srpm") -ne 1 ]]; then
  echo "FAIL: expected one microos-android-guest-apks aarch64 RPM and one SRPM in $dir" >&2
  exit 1
fi
others=$(find "$dir" -maxdepth 1 -name '*.rpm' ! -samefile "$rpm" ! -samefile "$srpm")
if [[ -n $others ]]; then fail "other RPMs: $others"; fi

if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi
if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "release"; fi
if [[ $(rpm -qp --qf '%{SOURCERPM}' "$rpm") != "${srpm##*/}" ]]; then fail "SOURCERPM"; fi
license=$(rpm -qp --qf '%{LICENSE}' "$rpm")
want='GPL-2.0-or-later AND Apache-2.0 AND MIT AND BSD-2-Clause AND BSD-3-Clause AND HPND AND HPND-sell-variant'
if [[ $license != "$want AND GPL-3.0-or-later WITH Bison-exception-2.2" ]]; then fail "license tag: $license"; fi
if requires=$(rpm -qp --requires "$rpm" | grep -v '^rpmlib('); then fail "requires: $requires"; fi

sources=$(rpm -qp --qf '[%{SOURCE}\n]' "$srpm" | sort)
want=$(printf '%s\n' overlay.manifest service.c "$hal.rc" "$hal.xml" build.sh SOURCE.env \
  microos-android-guest-apks-helper.tar.gz microos-android-guest-apks-telephony.tar.gz \
  microos-android-guest-apks-display.tar.gz audio_policy_volumes.xml \
  hwcomposer.waydroid.so 0001-hwc-private-roundtrip-queue.patch hwc.env "${licenses[@]}" | sort)
if [[ $sources != "$want" ]]; then fail "SRPM sources: $(tr '\n' ' ' <<<"$sources")"; fi

files=$(rpm -qlp "$rpm" | LC_ALL=C sort)
expected=$(printf '%s\n' "$share" "$manifest" "$vendorpin" "$overlay" "$overlay/system" \
  "$overlay/system/bin" "${bin%/*}" "$bin" \
  "$overlay/system/etc" "${initrc%/*}" "$initrc" "$overlay/system/etc/vintf" "${vintf%/*}" "$vintf" \
  "$overlay/system/priv-app" "${helper%/*}" "$helper" "$overlay/system/product" "${rro%/*/*}" "${rro%/*}" "$rro" "${display%/*}" "$display" \
  "$overlay/vendor" "${volumes%/*}" "$volumes" "$overlay/vendor/lib64" "${hwc%/*}" "$hwc" \
  "$licdir" "${licenses[@]/#/$licdir/}" | LC_ALL=C sort)
if [[ $files != "$expected" ]]; then
  fail "file list: $(diff <(echo "$expected") <(echo "$files") | grep '^[<>]' | tr '\n' ' ')"
fi
modes=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" \
  | awk -v bin="$bin" '$2 == bin ? $1 != "-rwxr-xr-x" : $1 != "drwxr-xr-x" && $1 != "-rw-r--r--"')
if [[ -n $modes ]]; then fail "modes other than 755 dirs, a 755 HAL and 644 files: $modes"; fi

tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
mkdir "$tmp/root" "$tmp/src"
rpm2cpio "$rpm" > "$tmp/rpm.cpio"
rpm2cpio "$srpm" > "$tmp/srpm.cpio"
(cd "$tmp/root" && cpio -idm --quiet < "$tmp/rpm.cpio")
(cd "$tmp/src" && cpio -idm --quiet < "$tmp/srpm.cpio")
root=$tmp/root

pins=$(printf '%s\n' \
  "d3b51bf93e9a626a36c288b772313367b2a3cd8220f1427d4b5e1464136495c7 0755 ${bin#"$overlay"/}" \
  "1a9f711f51b113e3e5326ef35c076e470a1c732ee667197df8effca34803c56c 0644 ${initrc#"$overlay"/}" \
  "b163a203c7ddc5c2886f6030c3c531341b68d7d0a6b6d2d2aaa46eb0cf12efd7 0644 ${vintf#"$overlay"/}" \
  "1bea3541ad971602a40620f72231d40d421ec26aea80092e8e3573ac51b1a223 0644 ${helper#"$overlay"/}" \
  "59e26f9b74cc394eee5a989d55654759dbcff651f7dd7541a90801a0ebf0a9f5 0644 ${display#"$overlay"/}" \
  "dc2810a28f07f25cb8476321007542a6b1e8c32a58c5555dce842f9e7f26229d 0644 ${rro#"$overlay"/}" \
  "4ef8bc89e575d9be09ce25975e368493ee0b04256a67ab1b584bf1717a894166 0644 ${volumes#"$overlay"/}" \
  "540608d5169c528531a0ae8754beae5fa3f12de6edc2c187f3df13a8ff1b1dfc 0644 ${hwc#"$overlay"/}")
[[ $(< "$root$manifest") == "$pins" ]] ||
  fail "$manifest is not the pinned lights HAL, helper, telephony and display overlay, volume and composer set: $(< "$root$manifest")"
while read -r sum mode path; do
  echo "$sum  $root$overlay/$path" | sha256sum -c --status - || fail "$overlay/$path does not match its manifest sha256"
  [[ $(stat -c %04a "$root$overlay/$path") == "$mode" ]] || fail "$overlay/$path is not $mode"
done < "$root$manifest"
[[ $(find "$root$overlay" -type f | wc -l) == $(wc -l < "$root$manifest") ]] ||
  fail "$overlay holds files its manifest does not list"

cmp -s "$tmp/src/$hal.rc" "$root$initrc" || fail "$initrc is not the SRPM's $hal.rc"
cmp -s "$tmp/src/$hal.xml" "$root$vintf" || fail "$vintf is not the SRPM's $hal.xml"
cmp -s "$tmp/src/audio_policy_volumes.xml" "$root$volumes" || fail "$volumes is not the SRPM's audio_policy_volumes.xml"
[[ $(< "$root$vendorpin") == "VENDOR_SHA256=$VENDOR_SHA256" ]] || fail "$vendorpin is not SOURCE.env's VENDOR_SHA256"
[[ -z $(find "$tmp/src" \( -name '*.so' ! -name hwcomposer.waydroid.so \) -o -name '*.zip' -o -name "$hal") ]] ||
  fail "the SRPM holds a binary other than the composer or an NDK file"
mkdir "$tmp/helper"
tar -xzf "$tmp/src/microos-android-guest-apks-helper.tar.gz" -C "$tmp/helper"
tar -xzf "$tmp/src/microos-android-guest-apks-telephony.tar.gz" -C "$tmp/helper"
tar -xzf "$tmp/src/microos-android-guest-apks-display.tar.gz" -C "$tmp/helper"
keys=$(find "$tmp/src" "$tmp/helper" -name '*.keystore' -o -name '*.jks' -o -name '*.p12' -o -name '*.pk8' \
  -o -name '*.pem' -o -name 'keystore.properties' -o -name '*.apk' -o -name '*.dex' -o -name '*.jar')
[[ -z $keys ]] || fail "the SRPM holds a key or a built file: $keys"
[[ -z $(find "$root$overlay" -path '*/etc/permissions/*' -o -path '*/etc/sysconfig/*') ]] ||
  fail "$overlay holds a privapp-permissions or sysconfig file"

out=$("$readelf" -l -S "$root$bin") || fail "llvm-readelf cannot read $bin"
grep -qF '[Requesting program interpreter: /system/bin/linker64]' <<<"$out" ||
  fail "$bin is not an Android arm64 executable"
if grep -qF .symtab <<<"$out"; then fail "$bin is not stripped"; fi

cmp -s "$tmp/src/hwcomposer.waydroid.so" "$root$hwc" || fail "$hwc is not the SRPM's hwcomposer.waydroid.so"
pin() { sed -n "s/^$1=//p" "$tmp/src/hwc.env"; }
[[ $(sha256sum < "$root$hwc") == "$(pin HWC_SHA256)  -" ]] || fail "$hwc is not the library hwc.env pins"
[[ $(sha256sum < "$tmp/src/0001-hwc-private-roundtrip-queue.patch") == "$(pin HWC_PATCH_SHA256)  -" ]] ||
  fail "0001-hwc-private-roundtrip-queue.patch is not the patch hwc.env pins"
[[ $(pin VENDOR_SHA256) == "$VENDOR_SHA256" ]] || fail "hwc.env's VENDOR_SHA256 is not SOURCE.env's"
out=$("$readelf" -h -n "$root$hwc") || fail "llvm-readelf cannot read $hwc"
grep -qE '^ +Machine: +AArch64$' <<<"$out" || fail "$hwc is not aarch64"
grep -qE '^ +Build ID: f36942bb37ab1cbcec5bec174529ec05$' <<<"$out" || fail "$hwc BuildId"
[[ $(pin HWC_BUILD_ID) == f36942bb37ab1cbcec5bec174529ec05 ]] || fail "hwc.env's HWC_BUILD_ID"
licfiles=$(rpm -qp --licensefiles "$rpm" | LC_ALL=C sort)
[[ $licfiles == "$(printf '%s\n' "${licenses[@]/#/$licdir/}" | LC_ALL=C sort)" ]] ||
  fail "license files: $(tr '\n' ' ' <<<"$licfiles")"
for f in "${licenses[@]}"; do
  cmp -s "$tmp/src/$f" "$root$licdir/$f" || fail "$licdir/$f is not the SRPM's $f"
done

check_signed() {
  local apk=$root$1 cert=$2 out
  "$tools/zipalign" -c -p 4 "$apk" > /dev/null || fail "$1 is not 4 byte aligned"
  [[ $(unzip -Z "$apk" resources.arsc | awk '{ print $6 }') == stor ]] || fail "$1 stores resources.arsc compressed"
  out=$(java --enable-native-access=ALL-UNNAMED -jar "$tools/lib/apksigner.jar" verify -v --print-certs \
    --min-sdk-version 24 "$apk") || { fail "$1 signature"; return; }
  grep -qx 'Verified using v1 scheme (JAR signing): false' <<<"$out" || fail "$1 has a v1 signature"
  grep -qx 'Verified using v2 scheme (APK Signature Scheme v2): true' <<<"$out" || fail "$1 has no v2 signature"
  grep -qx 'Verified using v3 scheme (APK Signature Scheme v3): true' <<<"$out" || fail "$1 has no v3 signature"
  grep -qx 'Number of signers: 1' <<<"$out" || fail "$1 signers"
  grep -qx "Signer #1 certificate SHA-256 digest: $cert" <<<"$out" || fail "$1 is not signed with $cert"
}

check_helper() {
  local apk=$root$helper pkg=net.seilent.microos.helper perm=android.permission.BIND_QUICK_SETTINGS_TILE out want
  out=$("$tools/aapt2" dump badging "$apk") || { fail "aapt2 cannot read $helper"; return; }
  grep -q "^package: name='$pkg' versionCode='1' versionName='1.0' " <<<"$out" ||
    fail "$helper package line: $(head -n 1 <<<"$out")"
  grep -qx "minSdkVersion:'$SDK_API'" <<<"$out" || fail "$helper minSdkVersion"
  grep -qx "targetSdkVersion:'$SDK_API'" <<<"$out" || fail "$helper targetSdkVersion"
  [[ $(grep '^uses-permission:' <<<"$out") == "uses-permission: name='android.permission.MODIFY_AUDIO_SETTINGS'" ]] ||
    fail "$helper permissions: $(grep '^uses-permission:' <<<"$out" | tr '\n' ' ')"
  if grep -q '^launchable-activity:' <<<"$out"; then fail "$helper has a launcher activity"; fi
  out=$("$tools/aapt2" dump xmltree --file AndroidManifest.xml "$apk") || { fail "aapt2 cannot dump $helper"; return; }
  grep -qF ':persistent(0x0101000d)=true' <<<"$out" || fail "$helper is not persistent"
  grep -qF ':allowBackup(0x01010280)=false' <<<"$out" || fail "$helper allows backup"
  if grep -qF ':sharedUserId(' <<<"$out"; then fail "$helper sets a sharedUserId"; fi
  if grep -qE '^ *E: (receiver|provider) ' <<<"$out"; then fail "$helper declares a receiver or a provider"; fi
  out=$(awk '
    /^ *E: / {
      if (kind != "" && exported == "true") print kind, name, permission
      kind = $2 ~ /^(activity|activity-alias|service|receiver|provider)$/ ? $2 : ""
      name = "-"; exported = "false"; permission = "-"
      next
    }
    kind != "" && /:name\(0x01010003\)="/ { split($0, v, "\""); name = v[2] }
    kind != "" && /:exported\(0x01010010\)=true/ { exported = "true" }
    kind != "" && /:permission\(0x01010006\)="/ { split($0, v, "\""); permission = v[2] }
    END { if (kind != "" && exported == "true") print kind, name, permission }
  ' <<<"$out" | LC_ALL=C sort)
  want=$(printf '%s\n' "activity $pkg.TilePrefsActivity $perm" "service $pkg.BluetoothTile $perm" \
    "service $pkg.InternetTile $perm" | LC_ALL=C sort)
  [[ $out == "$want" ]] || fail "$helper exported components: $(tr '\n' ' ' <<<"$out")"
  [[ $(unzip -Z "$apk" classes.dex | awk '{ print $6 }') == stor ]] || fail "$helper stores classes.dex compressed"
  check_signed "$helper" "$HELPER_CERT_SHA256"
}

check_rro() {
  local path=$1 pkg=$2 line=$3 want=$4 apk=$root$1 out cert
  [[ $(unzip -Z1 "$apk" | sort | paste -sd' ') == 'AndroidManifest.xml resources.arsc' ]] ||
    fail "$path entries: $(unzip -Z1 "$apk" | paste -sd' ')"
  out=$("$tools/aapt2" dump badging "$apk") || { fail "aapt2 cannot read $path"; return; }
  grep -q "^package: name='$pkg' versionCode='1' versionName='1.0' " <<<"$out" ||
    fail "$path package line: $(head -n 1 <<<"$out")"
  grep -qxF "overlay: targetPackage='android' $line" <<<"$out" || fail "$path overlay line: $(grep '^overlay:' <<<"$out")"
  if grep -qE '^(launchable-activity|uses-permission):' <<<"$out"; then
    fail "$path declares an activity or a permission"
  fi
  out=$("$tools/aapt2" dump xmltree --file AndroidManifest.xml "$apk") || { fail "aapt2 cannot dump $path"; return; }
  grep -qF ':hasCode(0x0101000c)=false' <<<"$out" || fail "$path does not set hasCode false"
  if grep -qE '^ *E: (activity|activity-alias|service|receiver|provider|uses-permission) ' <<<"$out"; then
    fail "$path declares a component or a permission"
  fi
  out=$("$tools/aapt2" dump resources "$apk" | awk '
    function flush() { if (name != "") print name "=" value; name = "" }
    $1 == "resource" { flush(); name = $3; value = ""; next }
    $1 == "type" || $1 == "Package" || $1 == "Binary" { flush(); next }
    name != "" { line = $0; gsub(/^ +| +$/, "", line); sub(/^\(\) /, "", line); value = value (value == "" ? "" : " ") line }
    END { flush() }' | LC_ALL=C sort | paste -sd'|') ||
    { fail "aapt2 cannot dump the resources of $path"; return; }
  [[ $out == "$want" ]] || fail "$path resources: $out"
  cert=$(openssl x509 -in /opt/android-testkey/testkey.x509.pem -outform DER | sha256sum | cut -d' ' -f1)
  check_signed "$path" "$cert"
}

check_volumes() {
  local file=$root$volumes
  python3 - "$file" << 'PY' || fail "$volumes music entries are not the five flat curves"
import sys
import xml.etree.ElementTree as ET

music = [v for v in ET.parse(sys.argv[1]).getroot().iter("volume") if v.get("stream") == "AUDIO_STREAM_MUSIC"]
want = ["HEADSET", "SPEAKER", "EARPIECE", "EXT_MEDIA", "HEARING_AID"]
ok = [v.get("deviceCategory") for v in music] == ["DEVICE_CATEGORY_" + c for c in want]
ok = ok and all(v.get("ref") is None and [p.text for p in v] == ["1,0", "100,0"] for v in music)
sys.exit(0 if ok else 1)
PY
  [[ $(python3 - "$file" << 'PY' | sha256sum
import re
import sys

refs = {
    b"HEADSET": b"DEFAULT_MEDIA_VOLUME_CURVE",
    b"SPEAKER": b"DEFAULT_DEVICE_CATEGORY_SPEAKER_VOLUME_CURVE",
    b"EARPIECE": b"DEFAULT_MEDIA_VOLUME_CURVE",
    b"EXT_MEDIA": b"DEFAULT_MEDIA_VOLUME_CURVE",
    b"HEARING_AID": b"DEFAULT_HEARING_AID_VOLUME_CURVE",
}
flat = re.compile(b'    <volume stream="AUDIO_STREAM_MUSIC" deviceCategory="DEVICE_CATEGORY_([A-Z_]+)">\n'
                  b'        <point>1,0</point>\n        <point>100,0</point>\n    </volume>\n')
ref = b'    <volume stream="AUDIO_STREAM_MUSIC" deviceCategory="DEVICE_CATEGORY_%s"\n' + b' ' * 40 + b'ref="%s"/>\n'
with open(sys.argv[1], "rb") as f:
    sys.stdout.buffer.write(flat.sub(lambda m: ref % (m.group(1), refs[m.group(1)]), f.read()))
PY
  ) == "$VOLUMES_SHA256  -" ]] || fail "$volumes with its music curves put back is not the vendor's file"
}

check_helper
check_rro "$rro" net.seilent.microos.overlay.telephony "priority='1' isStatic='true'" \
  'bool/config_sms_capable=false|bool/config_voice_capable=false'
check_rro "$display" net.seilent.microos.overlay.display \
  "priority='2' isStatic='true' requiredPropertyName='ro.vendor.microos.light_sensor' requiredPropertyValue='1'" \
  'array/config_autoBrightnessLcdBacklightValues=(array) size=15 [11, 11, 26, 42, 50, 56, 64, 70, 76, 86, 95, 105, 111, 118, 130]|array/config_autoBrightnessLevels=(array) size=14 [5, 15, 40, 100, 180, 400, 550, 1000, 1500, 2000, 2500, 3000, 4000, 5000]|bool/config_automatic_brightness_available=true'
check_volumes

exit "$rc"
