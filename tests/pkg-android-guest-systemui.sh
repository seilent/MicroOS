#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-android-guest-systemui.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"
tools=/opt/android-build-tools-$BUILD_TOOLS_VERSION
share=/usr/share/microos-android
sets=$share/overlay.d
apkpath=system/system_ext/priv-app/SystemUI/SystemUI.apk
apk=$sets/systemui/$apkpath
licdir=/usr/share/licenses/microos-android-guest-systemui

rpm=$(find "$dir" -maxdepth 1 -name 'microos-android-guest-systemui-1-*.microos.noarch.rpm')
srpm=$(find "$dir" -maxdepth 1 -name 'microos-android-guest-systemui-1-*.src.rpm')
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 || -z $srpm || $(wc -l <<<"$srpm") -ne 1 ]]; then
  echo "FAIL: expected one microos-android-guest-systemui noarch RPM and one SRPM in $dir" >&2
  exit 1
fi
others=$(find "$dir" -maxdepth 1 -name '*.rpm' ! -samefile "$rpm" ! -samefile "$srpm")
if [[ -n $others ]]; then fail "other RPMs: $others"; fi

if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi
if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "release"; fi
if [[ $(rpm -qp --qf '%{SOURCERPM}' "$rpm") != "${srpm##*/}" ]]; then fail "SOURCERPM"; fi
license=$(rpm -qp --qf '%{LICENSE}' "$rpm")
if [[ $license != Apache-2.0 ]]; then fail "license tag: $license"; fi
if requires=$(rpm -qp --requires "$rpm" | grep -v '^rpmlib('); then fail "requires: $requires"; fi

sources=$(rpm -qp --qf '[%{SOURCE}\n]' "$srpm" | LC_ALL=C sort)
want=$(printf '%s\n' SOURCE.env build.sh fetch.sh 0001-navbar-right-in-landscape.patch navbar-check.py NOTICE \
  systemui.manifest NOTICE.SystemUI | LC_ALL=C sort)
if [[ $sources != "$want" ]]; then fail "SRPM sources: $(tr '\n' ' ' <<<"$sources")"; fi

files=$(rpm -qlp "$rpm" | LC_ALL=C sort)
expected=$(printf '%s\n' "$share" "$sets" "$sets/systemui.base" "$sets/systemui.manifest" "$sets/systemui.system" \
  "$sets/systemui" "$sets/systemui/system" "$sets/systemui/system/system_ext" "$sets/systemui/system/system_ext/priv-app" \
  "${apk%/*}" "$apk" "$licdir" "$licdir/NOTICE" "$licdir/NOTICE.SystemUI" | LC_ALL=C sort)
if [[ $files != "$expected" ]]; then
  fail "file list: $(diff <(echo "$expected") <(echo "$files") | grep '^[<>]' | tr '\n' ' ')"
fi
modes=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk '$1 != "drwxr-xr-x" && $1 != "-rw-r--r--"')
if [[ -n $modes ]]; then fail "modes other than 755 dirs and 644 files: $modes"; fi
licfiles=$(rpm -qp --licensefiles "$rpm" | LC_ALL=C sort)
[[ $licfiles == "$(printf '%s\n' "$licdir/NOTICE" "$licdir/NOTICE.SystemUI")" ]] ||
  fail "license files: $(tr '\n' ' ' <<<"$licfiles")"

tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
mkdir "$tmp/root" "$tmp/src"
rpm2cpio "$rpm" > "$tmp/rpm.cpio"
rpm2cpio "$srpm" > "$tmp/srpm.cpio"
(cd "$tmp/root" && cpio -idm --quiet < "$tmp/rpm.cpio")
(cd "$tmp/src" && cpio -idm --quiet < "$tmp/srpm.cpio")
root=$tmp/root

held=$(find "$tmp/src" -name '*.apk' -o -name '*.dex' -o -name '*.jar' -o -name '*.pk8' -o -name '*.pem' \
  -o -name '*.zip' -o -name '*.img')
[[ -z $held ]] || fail "the SRPM holds a stock, built or key file: $held"
cmp -s "$tmp/src/SOURCE.env" "$dir/SOURCE.env" || fail "the SRPM's SOURCE.env is not the build's"

[[ $SYSTEMUI_PATH == "/$apkpath" ]] || fail "SOURCE.env's SYSTEMUI_PATH is not /$apkpath"
[[ $(< "$root$sets/systemui.manifest") =~ ^[0-9a-f]{64}\ 0644\ $apkpath$ ]] ||
  fail "systemui.manifest is not one 0644 line for $apkpath: $(< "$root$sets/systemui.manifest")"
cmp -s "$tmp/src/systemui.manifest" "$root$sets/systemui.manifest" || fail "systemui.manifest is not the SRPM's"
read -r sum _ < "$root$sets/systemui.manifest"
[[ $(sha256sum < "$root$apk") == "$sum  -" ]] || fail "$apk does not match systemui.manifest"
[[ $(< "$root$sets/systemui.base") == "$SYSTEMUI_SHA256 $SYSTEMUI_PATH" ]] ||
  fail "systemui.base is not SOURCE.env's SYSTEMUI_SHA256 and SYSTEMUI_PATH"
[[ $(< "$root$sets/systemui.system") == "SYSTEM_SHA256=$SYSTEM_SHA256" ]] ||
  fail "systemui.system is not SOURCE.env's SYSTEM_SHA256"
for f in NOTICE NOTICE.SystemUI; do
  cmp -s "$tmp/src/$f" "$root$licdir/$f" || fail "$licdir/$f is not the SRPM's $f"
done
[[ $(sha256sum < "$root$licdir/NOTICE.SystemUI") == "$SYSTEMUI_NOTICE_SHA256  -" ]] ||
  fail "$licdir/NOTICE.SystemUI is not the notice SOURCE.env pins"
grep -qx ' *Version 2.0, January 2004' "$root$licdir/NOTICE.SystemUI" && grep -qx ' *END OF TERMS AND CONDITIONS' \
  "$root$licdir/NOTICE.SystemUI" || fail "$licdir/NOTICE.SystemUI does not hold the Apache License 2.0 text"

a=$root$apk
"$tools/zipalign" -c -p 4 "$a" > /dev/null || fail "$apk is not 4 byte aligned"
for e in classes.dex classes2.dex resources.arsc; do
  [[ $(unzip -Z "$a" "$e" | awk '{ print $6 }') == stor ]] || fail "$apk stores $e compressed"
done
v1=$(unzip -Z1 "$a" | grep -E '^META-INF/([^/]+\.(SF|RSA|DSA|EC)|MANIFEST\.MF)$' || true)
[[ -z $v1 ]] || fail "$apk holds v1 signature files: $(tr '\n' ' ' <<<"$v1")"
if out=$(java --enable-native-access=ALL-UNNAMED -jar "$tools/lib/apksigner.jar" verify -v --print-certs \
  --min-sdk-version 24 "$a"); then
  grep -qx 'Verified using v1 scheme (JAR signing): false' <<<"$out" || fail "$apk has a v1 signature"
  grep -qx 'Verified using v2 scheme (APK Signature Scheme v2): true' <<<"$out" || fail "$apk has no v2 signature"
  grep -qx 'Verified using v3 scheme (APK Signature Scheme v3): true' <<<"$out" || fail "$apk has no v3 signature"
  grep -qx 'Number of signers: 1' <<<"$out" || fail "$apk signers"
  grep -qx "Signer #1 certificate SHA-256 digest: $PLATFORM_CERT_SHA256" <<<"$out" ||
    fail "$apk is not signed with the platform certificate $PLATFORM_CERT_SHA256"
else
  fail "$apk signature"
fi
if out=$("$tools/aapt2" dump badging "$a"); then
  grep -q "^package: name='com.android.systemui' versionCode='33' " <<<"$out" ||
    fail "$apk package line: $(head -n 1 <<<"$out")"
else
  fail "aapt2 cannot read $apk"
fi

exit "$rc"
