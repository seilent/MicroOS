#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-hyprgrass.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"

onein() {
  local d=$1 f
  f=$(find "$d" -maxdepth 1 -name "$2")
  if [[ -z $f || $(wc -l <<<"$f") -ne 1 ]]; then
    echo "FAIL: expected one $2 in $d" >&2
    exit 1
  fi
  echo "$f"
}
version=${HYPRGRASS_VERSION:?SOURCE.env has no HYPRGRASS_VERSION}
arch=$(rpm --eval '%{_arch}')
libdir=$(rpm --eval '%{_libdir}')
rpm=$(onein "$dir" "hyprgrass-$version-*.microos.$arch.rpm")
srpm=$(onein "$dir" "hyprgrass-$version-*.microos.src.rpm")
hyprland=$(onein /deps "hyprland-[0-9]*-*.microos.$arch.rpm")
hyprland_devel=$(onein /deps "hyprland-devel-[0-9]*-*.microos.$arch.rpm")
others=$(find "$dir" -maxdepth 1 -name '*.rpm' ! -samefile "$rpm" ! -samefile "$srpm")
if [[ -n $others ]]; then fail "other RPMs: $others"; fi

[[ $(rpm -qp --qf '%{RELEASE}' "$rpm") == *.microos ]] || fail "release"
[[ $(rpm -qp --qf '%{VENDOR}' "$rpm") == MicroOS ]] || fail "vendor"
[[ $(rpm -qp --qf '%{SOURCERPM}' "$rpm") == "${srpm##*/}" ]] || fail "SOURCERPM"
[[ $(rpm -qp --qf '%{LICENSE}' "$rpm") == 'BSD-3-Clause AND Apache-2.0 AND MIT' ]] || fail "License tag"
writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" \
  | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi

modes=$(rpm -qp --qf '[%{FILEMODES:octal} %{FILENAMES}\n]' "$rpm")
want=$(printf '%s\n' \
  '100644 /usr/share/licenses/hyprgrass/LICENSE' \
  '100644 /usr/share/licenses/hyprgrass/LICENSE.aosp' \
  '100644 /usr/share/licenses/hyprgrass/LICENSE.wf-touch' \
  "100755 $libdir/libhyprgrass.so" | LC_ALL=C sort)
got=$(awk '$1 != "40755" { print }' <<<"$modes" | LC_ALL=C sort)
if [[ $got != "$want" ]]; then fail "files: $got"; fi
got=$(awk '$1 == "40755" { print $2 }' <<<"$modes")
if [[ -n $got ]]; then fail "dirs: $got"; fi

evr=$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$hyprland")
reqs=$(rpm -qp --requires "$rpm")
grep -qx "hyprland = $evr" <<<"$reqs" || fail "no Requires on hyprland = $evr"

work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
mkdir -p "$work/deps" "$work/src" "$work/rpm" "$work/unpack"
rpm2archive -n - < "$hyprland_devel" | tar -x -C "$work/deps" --no-same-owner
vh=$work/deps/usr/include/hyprland/src/version.h
if [[ ! -f $vh ]]; then
  fail "the hyprland-devel RPM has no /usr/include/hyprland/src/version.h"
else
  grep -Eq "^#define GIT_COMMIT_HASH +\"$HYPRLAND_COMMIT\"" "$vh" \
    || fail "the hyprland-devel RPM pairs with another Hyprland than HYPRLAND_COMMIT"
fi

rpm2archive -n - < "$srpm" | tar -x -C "$work/src" --no-same-owner
if [[ -z $(find "$work/src" -name 'hyprgrass.spec') ]]; then fail "the SRPM has no spec"; fi
if [[ $(find "$work/src" -type f | wc -l) -ne 4 ]]; then fail "the SRPM carries $(find "$work/src" -type f | wc -l) files"; fi
carried=$(rpm -qp --qf '[%{PATCH}\n]' "$srpm" | sed '/^$/d')
if [[ -n $carried ]]; then fail "the SRPM carries patches: $carried"; fi

hash_check() {
  local f=$work/src/$1 got
  if [[ ! -f $f ]]; then fail "the SRPM has no $1"; return; fi
  got=$(sha256sum < "$f" | cut -d' ' -f1)
  [[ $got == "$2" ]] || fail "$1 hashes to $got"
}
hash_check "hyprgrass-$HYPRGRASS_COMMIT.tar.gz" "$HYPRGRASS_SHA256"
hash_check "wf-touch-$WFTOUCH_COMMIT.tar.gz" "$WFTOUCH_SHA256"
hash_check "hyprpm.toml" "$HYPRGRASS_PINS_SHA256"

pair="[\"$HYPRLAND_COMMIT\", \"$HYPRGRASS_COMMIT\"]"
grep -qF "$pair" "$work/src/hyprpm.toml" || fail "hyprpm.toml has no row $pair"

tar -xzf "$work/src/hyprgrass-$HYPRGRASS_COMMIT.tar.gz" -C "$work/unpack"
grep -qx "v$version" "$work/unpack/hyprgrass-$HYPRGRASS_COMMIT/VERSION" || fail "VERSION is not v$version"

rpm2archive -n - < "$rpm" | tar -x -C "$work/rpm" --no-same-owner
lic=$work/rpm/usr/share/licenses/hyprgrass
so=$work/rpm$libdir/libhyprgrass.so
grep -q 'BSD 3-Clause License' "$lic/LICENSE" || fail "LICENSE is not BSD-3-Clause"
grep -q 'Apache License' "$lic/LICENSE.aosp" || fail "LICENSE.aosp is not Apache-2.0"
grep -q 'Version 2.0' "$lic/LICENSE.aosp" || fail "LICENSE.aosp is not Apache-2.0"
grep -q 'MIT License' "$lic/LICENSE.wf-touch" || fail "LICENSE.wf-touch is not MIT"

if [[ ! -f $so ]]; then
  fail "no $libdir/libhyprgrass.so"
else
  if [[ $(readelf -h "$so" | awk '/Type:/ { print $2 }') != DYN ]]; then fail "libhyprgrass.so is not a shared object"; fi
  strings "$so" > "$work/strs"
  grep -qF "$HYPRLAND_COMMIT" "$work/strs" || fail "libhyprgrass.so does not name HYPRLAND_COMMIT"
  staged=$(grep -E "/stage/|/BUILD/|hyprgrass-$HYPRGRASS_COMMIT" "$work/strs" || true)
  if [[ -n $staged ]]; then fail "stage paths in libhyprgrass.so: $staged"; fi
fi

echo "pkg-hyprgrass: skipped 0"
if (( rc == 0 )); then echo "pkg-hyprgrass: ok"; fi
exit "$rc"
