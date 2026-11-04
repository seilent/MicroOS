#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-wvkbd.sh <rpmdir>}
rc=0
skipped=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"

one() {
  local f
  f=$(find "$dir" -maxdepth 1 -name "$1")
  if [[ -z $f || $(wc -l <<<"$f") -ne 1 ]]; then
    echo "FAIL: expected one $1 in $dir" >&2
    exit 1
  fi
  echo "$f"
}
arch=$(rpm --eval '%{_arch}')
rpm=$(one "wvkbd-${WVKBD_VERSION}-*.microos.${arch}.rpm")
srpm=$(one "wvkbd-${WVKBD_VERSION}-*.microos.src.rpm")
others=$(find "$dir" -maxdepth 1 -name '*.rpm' ! -samefile "$rpm" ! -samefile "$srpm")
if [[ -n $others ]]; then fail "other RPMs: $others"; fi

[[ $(rpm -qp --qf '%{RELEASE}' "$rpm") == *.microos ]] || fail "release"
[[ $(rpm -qp --qf '%{VENDOR}' "$rpm") == MicroOS ]] || fail "vendor"
[[ $(rpm -qp --qf '%{SOURCERPM}' "$rpm") == "${srpm##*/}" ]] || fail "SOURCERPM"
[[ $(rpm -qp --qf '%{LICENSE}' "$rpm") == 'GPL-3.0-only AND MIT AND HPND-sell-variant' ]] || fail "License tag"
writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" \
  | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi

modes=$(rpm -qp --qf '[%{FILEMODES:octal} %{FILENAMES}\n]' "$rpm")
want=$(printf '%s\n' \
  '100644 /usr/share/licenses/wvkbd/COPYING' \
  '100644 /usr/share/licenses/wvkbd/COPYING_WESTON' \
  '100644 /usr/share/licenses/wvkbd/LICENSE' \
  '100644 /usr/share/licenses/wvkbd/LICENSE.wlr-layer-shell' \
  '100644 /usr/share/man/man1/wvkbd.1.gz' \
  '100755 /usr/bin/wvkbd-mobintl' | LC_ALL=C sort)
got=$(awk '$1 != "40755" { print }' <<<"$modes" | LC_ALL=C sort)
if [[ $got != "$want" ]]; then fail "files: $got"; fi
want=$(printf '%s\n' /usr/share/licenses/wvkbd)
got=$(awk '$1 == "40755" { print $2 }' <<<"$modes" | LC_ALL=C sort)
if [[ $got != "$want" ]]; then fail "dirs: $got"; fi

reqs=$(rpm -qp --requires "$rpm")
for lib in libwayland-client.so.0 libpangocairo-1.0.so.0 libpango-1.0.so.0 libcairo.so.2; do
  if ! grep -q "^${lib}()" <<<"$reqs"; then fail "no Requires on $lib"; fi
done

work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
mkdir -p "$work/rpm" "$work/src"
rpm2archive -n - < "$rpm" | tar -x -C "$work/rpm" --no-same-owner
rpm2archive -n - < "$srpm" | tar -x -C "$work/src" --no-same-owner
lic=$work/rpm/usr/share/licenses/wvkbd
bin=$work/rpm/usr/bin/wvkbd-mobintl

grep -qx '                    GNU GENERAL PUBLIC LICENSE' "$lic/LICENSE" || fail "LICENSE is not the GPL text"
grep -q 'Version 3, 29 June 2007' "$lic/LICENSE" || fail "LICENSE is not GPLv3"
grep -q 'COPYING_WESTON' "$lic/COPYING" || fail "COPYING does not point at COPYING_WESTON"
grep -q 'Permission is hereby granted, free of charge' "$lic/COPYING_WESTON" || fail "COPYING_WESTON is not MIT"
grep -q 'distribute, and sell' "$lic/LICENSE.wlr-layer-shell" || fail "LICENSE.wlr-layer-shell is not HPND-sell-variant"
[[ $(sha256sum < "$lic/LICENSE" | cut -d' ' -f1) == "$WVKBD_LICENSE_SHA256" ]] || fail "LICENSE hash"
[[ $(sha256sum < "$lic/COPYING" | cut -d' ' -f1) == "$WVKBD_COPYING_SHA256" ]] || fail "COPYING hash"
[[ $(sha256sum < "$lic/COPYING_WESTON" | cut -d' ' -f1) == "$WVKBD_WESTON_SHA256" ]] || fail "COPYING_WESTON hash"

man=$work/rpm/usr/share/man/man1/wvkbd.1.gz
zcat "$man" | grep -q 'wvkbd' || fail "the man page does not name wvkbd"
if zcat "$man" | grep -qw 'VERSION'; then fail "the man page still holds the unsubstituted VERSION token"; fi

if [[ $(readelf -h "$bin" | awk '/Type:/ { print $2 }') != DYN ]]; then fail "wvkbd-mobintl is not a PIE"; fi
dyn=$(readelf -d "$bin")
grep -q 'BIND_NOW' <<<"$dyn" || fail "no BIND_NOW"
grep -q 'NOW PIE' <<<"$dyn" || fail "no PIE flag"
readelf -l "$bin" | grep -q 'GNU_RELRO' || fail "no GNU_RELRO"
syms=$(nm -D "$bin")
grep -q '__stack_chk_fail' <<<"$syms" || fail "no __stack_chk_fail, the build did not take the hardening flags"
grep -q '__printf_chk' <<<"$syms" || fail "no __printf_chk, the build did not take the hardening flags"

if [[ -z $(find "$work/src" -name 'wvkbd.spec') ]]; then fail "the SRPM has no spec"; fi
carried=$(rpm -qp --qf '[%{PATCH}\n]' "$srpm" | sed '/^$/d' | LC_ALL=C sort -u)
listed=$(grep -o '`[0-9]\{4\}-[^`]*\.patch`' "$dir/PATCHES.md" | tr -d '`' | LC_ALL=C sort -u)
if [[ -z $listed || $listed != "$carried" ]]; then fail "SRPM patches differ from PATCHES.md: $carried"; fi
for p in $carried; do
  [[ -f $work/src/$p ]] || fail "the SRPM has no patch $p"
done

tarball=$(find "$work/src" -name 'wvkbd-*.tar.gz')
if [[ -z $tarball ]]; then fail "the SRPM carries no source tarball"; fi
got=$(sha256sum < "$tarball" | cut -d' ' -f1)
if [[ $got != "$WVKBD_SHA256" ]]; then fail "the SRPM tarball hashes to $got"; fi
mkdir -p "$work/unpack"
tar -xzf "$tarball" -C "$work/unpack"
cfg=$(find "$work/unpack" -name config.mk -path "*wvkbd-$WVKBD_COMMIT*")
if [[ -z $cfg ]]; then fail "the tarball has no config.mk for $WVKBD_COMMIT"; fi
grep -qx "VERSION = $WVKBD_VERSION" "$cfg" || fail "config.mk does not carry VERSION = $WVKBD_VERSION"

if command -v ldd > /dev/null; then
  mkdir -p "$work/lib"
  if ldd "$bin" 2>&1 | grep -q 'not found'; then
    skipped=$((skipped + 1))
  fi
else
  skipped=$((skipped + 1))
fi

echo "pkg-wvkbd: skipped $skipped"
if (( rc == 0 )); then echo "pkg-wvkbd: ok"; fi
exit "$rc"
