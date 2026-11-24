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
hal=android.hardware.lights-service.microos
bin=$overlay/system/bin/hw/$hal
initrc=$overlay/system/etc/init/$hal.rc
vintf=$overlay/system/etc/vintf/manifest/$hal.xml
helper=$overlay/system/priv-app/MicroOsHelper/MicroOsHelper.apk

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
if [[ $license != 'GPL-2.0-or-later AND Apache-2.0' ]]; then fail "license tag: $license"; fi
if requires=$(rpm -qp --requires "$rpm" | grep -v '^rpmlib('); then fail "requires: $requires"; fi

sources=$(rpm -qp --qf '[%{SOURCE}\n]' "$srpm" | sort)
want=$(printf '%s\n' overlay.manifest service.c "$hal.rc" "$hal.xml" build.sh SOURCE.env \
  microos-android-guest-apks-helper.tar.gz | sort)
if [[ $sources != "$want" ]]; then fail "SRPM sources: $(tr '\n' ' ' <<<"$sources")"; fi

files=$(rpm -qlp "$rpm" | LC_ALL=C sort)
expected=$(printf '%s\n' "$share" "$manifest" "$overlay" "$overlay/system" "$overlay/system/bin" "${bin%/*}" "$bin" \
  "$overlay/system/etc" "${initrc%/*}" "$initrc" "$overlay/system/etc/vintf" "${vintf%/*}" "$vintf" \
  "$overlay/system/priv-app" "${helper%/*}" "$helper" | LC_ALL=C sort)
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
  "1bea3541ad971602a40620f72231d40d421ec26aea80092e8e3573ac51b1a223 0644 ${helper#"$overlay"/}")
[[ $(< "$root$manifest") == "$pins" ]] ||
  fail "$manifest is not the pinned lights HAL and helper set: $(< "$root$manifest")"
while read -r sum mode path; do
  echo "$sum  $root$overlay/$path" | sha256sum -c --status - || fail "$overlay/$path does not match its manifest sha256"
  [[ $(stat -c %04a "$root$overlay/$path") == "$mode" ]] || fail "$overlay/$path is not $mode"
done < "$root$manifest"
[[ $(find "$root$overlay" -type f | wc -l) == $(wc -l < "$root$manifest") ]] ||
  fail "$overlay holds files its manifest does not list"

cmp -s "$tmp/src/$hal.rc" "$root$initrc" || fail "$initrc is not the SRPM's $hal.rc"
cmp -s "$tmp/src/$hal.xml" "$root$vintf" || fail "$vintf is not the SRPM's $hal.xml"
[[ -z $(find "$tmp/src" -name '*.so' -o -name '*.zip' -o -name "$hal") ]] ||
  fail "the SRPM holds a binary or an NDK file"
mkdir "$tmp/helper"
tar -xzf "$tmp/src/microos-android-guest-apks-helper.tar.gz" -C "$tmp/helper"
keys=$(find "$tmp/src" "$tmp/helper" -name '*.keystore' -o -name '*.jks' -o -name '*.p12' -o -name '*.pk8' \
  -o -name '*.pem' -o -name 'keystore.properties' -o -name '*.apk' -o -name '*.dex' -o -name '*.jar')
[[ -z $keys ]] || fail "the SRPM holds a key or a built file: $keys"
[[ -z $(find "$root$overlay" -path '*/etc/permissions/*' -o -path '*/etc/sysconfig/*') ]] ||
  fail "$overlay holds a privapp-permissions or sysconfig file"

out=$("$readelf" -l -S "$root$bin") || fail "llvm-readelf cannot read $bin"
grep -qF '[Requesting program interpreter: /system/bin/linker64]' <<<"$out" ||
  fail "$bin is not an Android arm64 executable"
if grep -qF .symtab <<<"$out"; then fail "$bin is not stripped"; fi

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

check_helper

exit "$rc"
