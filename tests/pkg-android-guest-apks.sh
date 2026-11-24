#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-android-guest-apks.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"
readelf=/opt/android-ndk-$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf
share=/usr/share/microos-android
overlay=$share/overlay
manifest=$share/overlay.manifest
hal=android.hardware.lights-service.microos
bin=$overlay/system/bin/hw/$hal
initrc=$overlay/system/etc/init/$hal.rc
vintf=$overlay/system/etc/vintf/manifest/$hal.xml

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
if [[ $license != GPL-2.0-or-later ]]; then fail "license tag: $license"; fi
if requires=$(rpm -qp --requires "$rpm" | grep -v '^rpmlib('); then fail "requires: $requires"; fi

sources=$(rpm -qp --qf '[%{SOURCE}\n]' "$srpm" | sort)
want=$(printf '%s\n' overlay.manifest service.c "$hal.rc" "$hal.xml" build.sh SOURCE.env | sort)
if [[ $sources != "$want" ]]; then fail "SRPM sources: $(tr '\n' ' ' <<<"$sources")"; fi

files=$(rpm -qlp "$rpm" | LC_ALL=C sort)
expected=$(printf '%s\n' "$share" "$manifest" "$overlay" "$overlay/system" "$overlay/system/bin" "${bin%/*}" "$bin" \
  "$overlay/system/etc" "${initrc%/*}" "$initrc" "$overlay/system/etc/vintf" "${vintf%/*}" "$vintf" | LC_ALL=C sort)
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
  "b163a203c7ddc5c2886f6030c3c531341b68d7d0a6b6d2d2aaa46eb0cf12efd7 0644 ${vintf#"$overlay"/}")
[[ $(< "$root$manifest") == "$pins" ]] || fail "$manifest is not the pinned lights HAL set: $(< "$root$manifest")"
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

out=$("$readelf" -l -S "$root$bin") || fail "llvm-readelf cannot read $bin"
grep -qF '[Requesting program interpreter: /system/bin/linker64]' <<<"$out" ||
  fail "$bin is not an Android arm64 executable"
if grep -qF .symtab <<<"$out"; then fail "$bin is not stripped"; fi

exit "$rc"
