#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-hyprland.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"
version=${HYPRLAND_VERSION:?SOURCE.env has no HYPRLAND_VERSION}
arch=$(rpm --eval '%{_arch}')
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT

one() {
  local f
  f=$(find "$dir" -maxdepth 1 -name "$1")
  if [[ -z $f || $(wc -l <<<"$f") -ne 1 ]]; then
    echo "FAIL: expected one $1 in $dir" >&2
    exit 1
  fi
  echo "$f"
}

declare -A rpmof
for name in hyprland hyprland-devel hyprutils hyprutils-devel hyprlang hyprlang-devel \
  hyprgraphics hyprgraphics-devel hyprwire hyprwire-devel hyprland-protocols-devel \
  aquamarine aquamarine-devel hyprcursor hyprcursor-devel; do
  rpmof[$name]=$(one "$name-$version-*.microos.$arch.rpm")
done
rpmof[glaze-devel]=$(one "glaze-devel-$version-*.microos.noarch.rpm")
srpm=$(one "hyprland-$version-*.microos.src.rpm")

count=$(find "$dir" -maxdepth 1 -name '*.rpm' ! -name '*.src.rpm' | wc -l)
if [[ $count -ne 16 ]]; then fail "16 binary RPMs, found $count"; fi
got=$(for f in "${rpmof[@]}"; do rpm -qp --qf '%{NAME}\n' "$f"; done | sort)
if [[ $got != "$(printf '%s\n' "${!rpmof[@]}" | sort)" ]]; then fail "RPM names: $got"; fi

declare -A lic=(
  [hyprland]='BSD-3-Clause AND BSD-2-Clause'
  [hyprland-devel]='BSD-3-Clause'
  [hyprutils]='BSD-3-Clause'
  [hyprutils-devel]='BSD-3-Clause'
  [hyprlang]='LGPL-3.0-only'
  [hyprlang-devel]='LGPL-3.0-only'
  [hyprgraphics]='BSD-3-Clause'
  [hyprgraphics-devel]='BSD-3-Clause'
  [hyprwire]='BSD-3-Clause'
  [hyprwire-devel]='BSD-3-Clause'
  [hyprland-protocols-devel]='BSD-3-Clause'
  [aquamarine]='BSD-3-Clause'
  [aquamarine-devel]='BSD-3-Clause'
  [hyprcursor]='BSD-3-Clause'
  [hyprcursor-devel]='BSD-3-Clause'
  [glaze-devel]='MIT'
)

for name in "${!rpmof[@]}"; do
  f=${rpmof[$name]}
  [[ $(rpm -qp --qf '%{VERSION}' "$f") == "$version" ]] || fail "$name version"
  [[ $(rpm -qp --qf '%{RELEASE}' "$f") == 1.fc44.microos ]] || fail "$name release"
  [[ $(rpm -qp --qf '%{VENDOR}' "$f") == MicroOS ]] || fail "$name vendor"
  [[ $(rpm -qp --qf '%{LICENSE}' "$f") == "${lic[$name]}" ]] || fail "$name License tag"
done
[[ $(rpm -qp --qf '%{VENDOR}' "$srpm") == MicroOS ]] || fail "SRPM vendor"

declare -A soversion=( [hyprutils]=13 [hyprlang]=2 [hyprgraphics]=5 [hyprwire]=3 [aquamarine]=14 [hyprcursor]=0 )
for name in "${!soversion[@]}"; do
  soname="lib$name.so.${soversion[$name]}"
  provides=$(rpm -qp --provides "${rpmof[$name]}")
  grep -qx "$soname()(64bit)" <<<"$provides" || fail "$name does not provide $soname"
done

reqs=$(rpm -qp --requires "${rpmof[hyprgraphics]}")
for lib in libheif libjxl; do
  grep -q "^$lib(" <<<"$reqs" || fail "hyprgraphics does not require $lib"
done

modes=$(rpm -qp --qf '[%{FILEMODES:octal} %{FILENAMES}\n]' "${rpmof[hyprland]}")
want=$(printf '%s\n' \
  '100644 /usr/share/hypr/stubs/hl.meta.lua' \
  '100644 /usr/share/licenses/hyprland/LICENSE' \
  '100644 /usr/share/licenses/hyprland/LICENSE.udis86' \
  '100644 /usr/share/man/man1/Hyprland.1.gz' \
  '100644 /usr/share/man/man1/hyprctl.1.gz' \
  '100755 /usr/bin/Hyprland' \
  '100755 /usr/bin/hyprctl' \
  '100755 /usr/bin/start-hyprland' \
  '120777 /usr/bin/hyprland' \
  '40755 /usr/share/hypr' \
  '40755 /usr/share/hypr/stubs' \
  '40755 /usr/share/licenses/hyprland' | LC_ALL=C sort)
got=$(awk 'NF' <<<"$modes" | LC_ALL=C sort)
if [[ $got != "$want" ]]; then fail "hyprland files: $got"; fi

allpaths=$work/paths
for f in "${rpmof[@]}"; do
  rpm -qp --qf '[%{FILENAMES}\n]' "$f"
done > "$allpaths"
for bad in hyprland.desktop hyprland-session.target hyprland-portals.conf \
  hyprtester hyprtestplugin test.lua lua-require hyprwayland-scanner; do
  hit=$(grep -F -- "$bad" "$allpaths" || true)
  if [[ -n $hit ]]; then fail "$bad packaged: $hit"; fi
done

mkdir -p "$work/src"
rpm2archive -n - < "$srpm" | tar -x -C "$work/src" --no-same-owner
if [[ -z $(find "$work/src" -name 'hyprland.spec') ]]; then fail "the SRPM has no spec"; fi
if [[ $(find "$work/src" -type f | wc -l) -ne 11 ]]; then fail "the SRPM carries $(find "$work/src" -type f | wc -l) files"; fi

hash_check() {
  local f=$work/src/$1 got
  if [[ ! -f $f ]]; then fail "the SRPM has no $1"; return; fi
  got=$(sha256sum < "$f" | cut -d' ' -f1)
  [[ $got == "$2" ]] || fail "$1 hashes to $got"
}
hash_check "hyprutils-$HYPRUTILS_COMMIT.tar.gz" "$HYPRUTILS_SHA256"
hash_check "hyprlang-$HYPRLANG_COMMIT.tar.gz" "$HYPRLANG_SHA256"
hash_check "hyprgraphics-$HYPRGRAPHICS_COMMIT.tar.gz" "$HYPRGRAPHICS_SHA256"
hash_check "hyprwire-$HYPRWIRE_COMMIT.tar.gz" "$HYPRWIRE_SHA256"
hash_check "hyprland-protocols-$HYPRPROTOCOLS_COMMIT.tar.gz" "$HYPRPROTOCOLS_SHA256"
hash_check "aquamarine-$AQUAMARINE_COMMIT.tar.gz" "$AQUAMARINE_SHA256"
hash_check "hyprcursor-$HYPRCURSOR_COMMIT.tar.gz" "$HYPRCURSOR_SHA256"
hash_check "source-v$version.tar.gz" "$HYPRLAND_SHA256"
hash_check "glaze-$GLAZE_COMMIT.tar.gz" "$GLAZE_SHA256"
hash_check "hyprwayland-scanner-$HYPRWSCANNER_COMMIT.tar.gz" "$HYPRWSCANNER_SHA256"

for name in "${!rpmof[@]}"; do
  mkdir -p "$work/$name"
  rpm2archive -n - < "${rpmof[$name]}" | tar -x -C "$work/$name" --no-same-owner
done

for name in "${!soversion[@]}"; do
  soname="lib$name.so.${soversion[$name]}"
  lib=$(find "$work/$name/usr/lib64" -maxdepth 1 -name "lib$name.so.*" -type f)
  if [[ -z $lib || $(wc -l <<<"$lib") -ne 1 ]]; then fail "$name: no versioned library"; continue; fi
  readelf -d "$lib" | grep -q "SONAME.*\[$soname\]" || fail "$name: SONAME is not $soname"
  [[ -L $work/$name/usr/lib64/$soname ]] || fail "$name: no $soname symlink"
  [[ $(readlink "$work/$name/usr/lib64/$soname") == "${lib##*/}" ]] || fail "$name: $soname points elsewhere"
done

if [[ $(readlink "$work/hyprland/usr/bin/hyprland") != /usr/bin/Hyprland ]]; then fail "hyprland symlink"; fi

vh=$work/hyprland-devel/usr/include/hyprland/src/version.h
if [[ ! -f $vh ]]; then
  fail "no version.h"
else
  grep -Eq "^#define GIT_COMMIT_HASH +\"$HYPRLAND_COMMIT\"" "$vh" || fail "version.h does not carry HYPRLAND_COMMIT"
  grep -Eq "^#define GIT_TAG +\"v$version\"" "$vh" || fail "version.h does not carry the Hyprland tag"
fi

mapfile -t pcs < <(find "$work" -name '*.pc' -path '*pkgconfig*')
if [[ ${#pcs[@]} -ne 9 ]]; then fail "9 pkg-config files, found ${#pcs[@]}"; fi
for pc in "${pcs[@]}"; do
  grep -q '^prefix=' "$pc" || continue
  grep -Eq '^prefix=/usr(/|$)' "$pc" || fail "${pc##*/}: $(grep -m1 '^prefix=' "$pc")"
done

for name in "${!rpmof[@]}"; do
  staged=$(grep -rl -- '/stage/usr' "$work/$name" || true)
  if [[ -n $staged ]]; then fail "stage path in: $staged"; fi
done

check_license() {
  local f=$work/$1/usr/share/licenses/$1/$2
  if [[ ! -f $f ]]; then fail "$1 has no $2"; return; fi
  grep -q -- "$3" "$f" || fail "$1/$2 does not hold $3"
}
for name in hyprland hyprland-devel hyprutils hyprutils-devel hyprgraphics hyprgraphics-devel \
  hyprwire hyprwire-devel hyprland-protocols-devel aquamarine aquamarine-devel hyprcursor hyprcursor-devel; do
  check_license "$name" LICENSE 'BSD 3-Clause License'
done
check_license hyprland LICENSE.udis86 'Vivek Thampi'
check_license hyprlang LICENSE 'GNU LESSER GENERAL PUBLIC LICENSE'
check_license hyprlang-devel LICENSE 'GNU LESSER GENERAL PUBLIC LICENSE'
check_license hyprlang COPYRIGHT 'LGPL-3.0-Only'
check_license hyprlang-devel COPYRIGHT 'LGPL-3.0-Only'
check_license glaze-devel LICENSE 'MIT License'

bin=$work/hyprland/usr/bin/Hyprland
if [[ ! -x $bin ]]; then
  fail "no Hyprland binary"
else
  nm "$bin" > "$work/syms" 2> /dev/null || true
  strings "$bin" > "$work/strs" 2> /dev/null || true
  if grep -q '__gcov' "$work/syms" "$work/strs"; then fail "Hyprland carries gcov symbols"; fi
fi

if (( rc == 0 )); then echo "pkg-hyprland: ok"; fi
exit "$rc"
