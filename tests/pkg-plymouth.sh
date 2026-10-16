#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-plymouth.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"
version=${PLYMOUTH_VERSION:?SOURCE.env has no PLYMOUTH_VERSION}

declare -A rpm
for name in plymouth plymouth-core-libs plymouth-graphics-libs plymouth-plugin-script plymouth-scripts; do
  found=$(find "$dir" -maxdepth 1 -name "$name-$version-*.rpm" ! -name '*.src.rpm')
  if [[ -z $found || $(wc -l <<<"$found") -ne 1 ]]; then
    echo "FAIL: expected one $name RPM in $dir" >&2
    exit 1
  fi
  rpm[$name]=$found
  if [[ $(rpm -qp --qf '%{RELEASE}' "$found") != *.microos ]]; then fail "$name release"; fi
  if [[ $(rpm -qp --qf '%{VENDOR}' "$found") != MicroOS ]]; then fail "$name vendor"; fi
  writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$found" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
  if [[ -n $writable ]]; then fail "$name group or other writable: $writable"; fi
done
srpm=$(find "$dir" -maxdepth 1 -name "plymouth-$version-*.src.rpm")
if [[ -z $srpm ]]; then
  fail "SRPM missing"
else
  for p in \
    0001-close-the-fb-on-retain-to-keep-the-image-on-the-screen.patch \
    0002-script-draw-sprites-on-display-message.patch \
    0003-drm-skip-retain-on-a-head-without-a-scanout-buffer.patch; do
    if ! rpm -qp --qf '[%{PATCH}\n]' "$srpm" | grep -qx "$p"; then fail "SRPM spec lacks $p"; fi
  done
fi
if [[ -n $(find "$dir" -maxdepth 1 \( -name '*-debuginfo-*' -o -name '*-debugsource-*' \)) ]]; then fail "debug RPM present"; fi

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
(cd "$root" && rpm2cpio "${rpm[plymouth-graphics-libs]}" | cpio -idm --quiet)
drm=$(find "$root" -path '*/plymouth/renderers/drm.so')
if [[ -z $drm ]]; then
  fail "missing renderers/drm.so"
elif ! grep -qaF 'Closing FB %u (retaining)' "$drm"; then
  fail "drm.so lacks the retain hook"
fi
if ! rpm -qlp "${rpm[plymouth-plugin-script]}" | grep -q '/plymouth/script\.so$'; then fail "missing script.so"; fi

exit "$rc"
