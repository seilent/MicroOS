#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-hyprland-guiutils.sh <rpmdir>}
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
tv=${HYPRTOOLKIT_VERSION:?SOURCE.env has no HYPRTOOLKIT_VERSION}
gv=${GUIUTILS_VERSION:?SOURCE.env has no GUIUTILS_VERSION}
arch=$(rpm --eval '%{_arch}')
libdir=$(rpm --eval '%{_libdir}')
declare -A rpmof
rpmof[hyprtoolkit]=$(onein "$dir" "hyprtoolkit-$tv-*.microos.$arch.rpm")
rpmof[hyprtoolkit-devel]=$(onein "$dir" "hyprtoolkit-devel-$tv-*.microos.$arch.rpm")
rpmof[hyprland-guiutils]=$(onein "$dir" "hyprland-guiutils-$gv-*.microos.$arch.rpm")
tsrpm=$(onein "$dir" "hyprtoolkit-$tv-*.microos.src.rpm")
gsrpm=$(onein "$dir" "hyprland-guiutils-$gv-*.microos.src.rpm")
others=$(find "$dir" -maxdepth 1 -name '*.rpm' ! -samefile "${rpmof[hyprtoolkit]}" ! -samefile "${rpmof[hyprtoolkit-devel]}" \
  ! -samefile "${rpmof[hyprland-guiutils]}" ! -samefile "$tsrpm" ! -samefile "$gsrpm")
if [[ -n $others ]]; then fail "other RPMs: $others"; fi

for name in "${!rpmof[@]}"; do
  f=${rpmof[$name]}
  [[ $(rpm -qp --qf '%{NAME}' "$f") == "$name" ]] || fail "$name name"
  [[ $(rpm -qp --qf '%{RELEASE}' "$f") == *.microos ]] || fail "$name release"
  [[ $(rpm -qp --qf '%{VENDOR}' "$f") == MicroOS ]] || fail "$name vendor"
  [[ $(rpm -qp --qf '%{LICENSE}' "$f") == BSD-3-Clause ]] || fail "$name License tag"
  writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$f" \
    | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
  if [[ -n $writable ]]; then fail "$name group or other writable: $writable"; fi
done
for name in hyprtoolkit hyprtoolkit-devel; do
  [[ $(rpm -qp --qf '%{SOURCERPM}' "${rpmof[$name]}") == "${tsrpm##*/}" ]] || fail "$name SOURCERPM"
done
[[ $(rpm -qp --qf '%{SOURCERPM}' "${rpmof[hyprland-guiutils]}") == "${gsrpm##*/}" ]] || fail "hyprland-guiutils SOURCERPM"
for f in "$tsrpm" "$gsrpm"; do
  [[ $(rpm -qp --qf '%{VENDOR}' "$f") == MicroOS ]] || fail "${f##*/} vendor"
done

modes=$(rpm -qp --qf '[%{FILEMODES:octal} %{FILENAMES}\n]' "${rpmof[hyprtoolkit]}" | LC_ALL=C sort)
want=$(printf '%s\n' \
  '100644 /usr/share/licenses/hyprtoolkit/LICENSE' \
  "100755 $libdir/libhyprtoolkit.so.$tv" \
  "120777 $libdir/libhyprtoolkit.so.6" | LC_ALL=C sort)
if [[ $modes != "$want" ]]; then fail "hyprtoolkit files: $modes"; fi

modes=$(rpm -qp --qf '[%{FILEMODES:octal} %{FILENAMES}\n]' "${rpmof[hyprtoolkit-devel]}")
got=$(grep -v ' /usr/include/hyprtoolkit/' <<<"$modes" | LC_ALL=C sort)
want=$(printf '%s\n' \
  '100644 /usr/share/licenses/hyprtoolkit-devel/LICENSE' \
  '40755 /usr/include/hyprtoolkit' \
  '40755 /usr/share/licenses/hyprtoolkit-devel' \
  "100644 $libdir/pkgconfig/hyprtoolkit.pc" \
  "120777 $libdir/libhyprtoolkit.so" | LC_ALL=C sort)
if [[ $got != "$want" ]]; then fail "hyprtoolkit-devel files: $got"; fi
bad=$(grep ' /usr/include/hyprtoolkit/' <<<"$modes" | awk '$1 != "100644" && $1 != "40755"' || true)
if [[ -n $bad ]]; then fail "hyprtoolkit-devel headers: $bad"; fi
grep -qx '100644 /usr/include/hyprtoolkit/core/Backend.hpp' <<<"$modes" || fail "hyprtoolkit-devel has no core/Backend.hpp"

modes=$(rpm -qp --qf '[%{FILEMODES:octal} %{FILENAMES}\n]' "${rpmof[hyprland-guiutils]}" | LC_ALL=C sort)
want=$(printf '%s\n' \
  '100644 /usr/share/licenses/hyprland-guiutils/LICENSE' \
  '100755 /usr/bin/hyprland-dialog' \
  '100755 /usr/bin/hyprland-donate-screen' \
  '100755 /usr/bin/hyprland-run' \
  '100755 /usr/bin/hyprland-update-screen' \
  '100755 /usr/bin/hyprland-welcome' | LC_ALL=C sort)
if [[ $modes != "$want" ]]; then fail "hyprland-guiutils files: $modes"; fi

provides=$(rpm -qp --provides "${rpmof[hyprtoolkit]}")
grep -qx 'libhyprtoolkit.so.6()(64bit)' <<<"$provides" || fail "hyprtoolkit does not provide libhyprtoolkit.so.6"
treqs=$(rpm -qp --requires "${rpmof[hyprtoolkit]}")
greqs=$(rpm -qp --requires "${rpmof[hyprland-guiutils]}")
grep -qx 'libhyprtoolkit.so.6()(64bit)' <<<"$greqs" || fail "hyprland-guiutils does not require libhyprtoolkit.so.6"
for lib in hyprutils hyprlang hyprgraphics aquamarine; do
  dep=$(onein /deps "$lib-[0-9]*-*.microos.$arch.rpm")
  so=$(rpm -qp --provides "$dep" | grep -x "lib$lib\.so\.[0-9]*()(64bit)" || true)
  if [[ -z $so ]]; then fail "/deps $lib provides no lib$lib soname"; continue; fi
  grep -qxF "$so" <<<"$treqs" || fail "hyprtoolkit does not require $so of the /deps $lib"
  if [[ $lib == hyprutils ]]; then
    grep -qxF "$so" <<<"$greqs" || fail "hyprland-guiutils does not require $so of the /deps $lib"
  fi
done

work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
mkdir -p "$work/tsrc" "$work/gsrc" "$work/unpack"
rpm2archive -n - < "$tsrpm" | tar -x -C "$work/tsrc" --no-same-owner
rpm2archive -n - < "$gsrpm" | tar -x -C "$work/gsrc" --no-same-owner
[[ -n $(find "$work/tsrc" -name 'hyprtoolkit.spec') ]] || fail "the hyprtoolkit SRPM has no spec"
[[ -n $(find "$work/gsrc" -name 'hyprland-guiutils.spec') ]] || fail "the hyprland-guiutils SRPM has no spec"
n=$(find "$work/tsrc" -type f | wc -l)
if [[ $n -ne 3 ]]; then fail "the hyprtoolkit SRPM carries $n files"; fi
n=$(find "$work/gsrc" -type f | wc -l)
if [[ $n -ne 2 ]]; then fail "the hyprland-guiutils SRPM carries $n files"; fi
carried=$(rpm -qp --qf '[%{PATCH}\n]' "$tsrpm" "$gsrpm" | sed '/^$/d')
if [[ -n $carried ]]; then fail "the SRPMs carry patches: $carried"; fi

hash_check() {
  local f=$work/$1/$2 got
  if [[ ! -f $f ]]; then fail "the SRPM has no $2"; return; fi
  got=$(sha256sum < "$f" | cut -d' ' -f1)
  [[ $got == "$3" ]] || fail "$2 hashes to $got"
}
hash_check tsrc "hyprtoolkit-$HYPRTOOLKIT_COMMIT.tar.gz" "$HYPRTOOLKIT_SHA256"
hash_check gsrc "hyprland-guiutils-$GUIUTILS_COMMIT.tar.gz" "$GUIUTILS_SHA256"
hash_check tsrc "hyprwayland-scanner-$HYPRWSCANNER_COMMIT.tar.gz" "$HYPRWSCANNER_SHA256"
hsrpm=$(onein /deps "hyprland-[0-9]*-*.microos.src.rpm")
rpm -qlp "$hsrpm" | grep -qxF "hyprwayland-scanner-$HYPRWSCANNER_COMMIT.tar.gz" ||
  fail "the hyprland SRPM in /deps builds another hyprwayland-scanner than HYPRWSCANNER_COMMIT"

tar -xzf "$work/tsrc/hyprtoolkit-$HYPRTOOLKIT_COMMIT.tar.gz" -C "$work/unpack"
tar -xzf "$work/gsrc/hyprland-guiutils-$GUIUTILS_COMMIT.tar.gz" -C "$work/unpack"
grep -qx "$tv" "$work/unpack/hyprtoolkit-$HYPRTOOLKIT_COMMIT/VERSION" || fail "hyprtoolkit VERSION is not $tv"
grep -qx "$gv" "$work/unpack/hyprland-guiutils-$GUIUTILS_COMMIT/VERSION" || fail "hyprland-guiutils VERSION is not $gv"
tar -xzf "$work/tsrc/hyprwayland-scanner-$HYPRWSCANNER_COMMIT.tar.gz" -C "$work/unpack"
grep -qx "$HYPRWSCANNER_VERSION" "$work/unpack/hyprwayland-scanner-$HYPRWSCANNER_COMMIT/VERSION" ||
  fail "hyprwayland-scanner VERSION is not $HYPRWSCANNER_VERSION"

for name in "${!rpmof[@]}"; do
  mkdir -p "$work/$name"
  rpm2archive -n - < "${rpmof[$name]}" | tar -x -C "$work/$name" --no-same-owner
  staged=$(grep -rlE -- "/BUILD/|scanner-stage" "$work/$name" || true)
  if [[ -n $staged ]]; then fail "build paths in: $staged"; fi
done
grep -q 'BSD 3-Clause License' "$work/hyprtoolkit/usr/share/licenses/hyprtoolkit/LICENSE" || fail "hyprtoolkit LICENSE is not BSD-3-Clause"
grep -q 'BSD 3-Clause License' "$work/hyprland-guiutils/usr/share/licenses/hyprland-guiutils/LICENSE" || fail "hyprland-guiutils LICENSE is not BSD-3-Clause"

lib=$work/hyprtoolkit$libdir/libhyprtoolkit.so.$tv
if [[ ! -f $lib ]]; then
  fail "no libhyprtoolkit.so.$tv"
else
  readelf -d "$lib" | grep -q 'SONAME.*\[libhyprtoolkit\.so\.6\]' || fail "libhyprtoolkit SONAME is not libhyprtoolkit.so.6"
  [[ $(readlink "$work/hyprtoolkit$libdir/libhyprtoolkit.so.6") == "libhyprtoolkit.so.$tv" ]] || fail "libhyprtoolkit.so.6 points elsewhere"
fi
[[ $(readlink "$work/hyprtoolkit-devel$libdir/libhyprtoolkit.so") == libhyprtoolkit.so.6 ]] || fail "libhyprtoolkit.so points elsewhere"
pc=$work/hyprtoolkit-devel$libdir/pkgconfig/hyprtoolkit.pc
grep -qx 'prefix=/usr' "$pc" || fail "hyprtoolkit.pc: $(grep -m1 '^prefix=' "$pc")"
grep -qx "Version: $tv" "$pc" || fail "hyprtoolkit.pc: $(grep -m1 '^Version:' "$pc")"

for b in dialog donate-screen run update-screen welcome; do
  f=$work/hyprland-guiutils/usr/bin/hyprland-$b
  if [[ ! -f $f ]]; then fail "no hyprland-$b"; continue; fi
  [[ $(readelf -h "$f" | awk '/Type:/ { print $2 }') == DYN ]] || fail "hyprland-$b is not a PIE"
  readelf -d "$f" | grep -q 'NEEDED.*\[libhyprtoolkit\.so\.6\]' || fail "hyprland-$b does not link libhyprtoolkit.so.6"
done

echo "pkg-hyprland-guiutils: skipped 0"
if (( rc == 0 )); then echo "pkg-hyprland-guiutils: ok"; fi
exit "$rc"
