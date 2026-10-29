#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-gamescope.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"
version=${GAMESCOPE_VERSION:?SOURCE.env has no GAMESCOPE_VERSION}

rpm=$(find "$dir" -maxdepth 1 -name "gamescope-$version-*.rpm" ! -name '*.src.rpm')
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 ]]; then
  echo "FAIL: expected one gamescope RPM in $dir" >&2
  exit 1
fi
if [[ -z $(find "$dir" -maxdepth 1 -name "gamescope-$version-*.src.rpm") ]]; then fail "SRPM missing"; fi
if [[ -n $(find "$dir" -maxdepth 1 \( -name '*-debuginfo-*' -o -name '*-debugsource-*' \)) ]]; then fail "debug RPM present"; fi

if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "release"; fi
if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi

writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi

files=$(rpm -qlp "$rpm")
for f in \
  /usr/share/licenses/gamescope/LICENSE \
  /usr/bin/gamescope \
  /usr/bin/gamescopectl \
  /usr/bin/gamescopereaper \
  /usr/bin/gamescopevirtual; do
  if ! grep -qx "$f" <<<"$files"; then fail "missing $f"; fi
done
if ! grep -q '^/usr/share/vulkan/implicit_layer.d/VkLayer_FROG_gamescope_wsi\..*\.json$' <<<"$files"; then fail "missing WSI layer manifest"; fi
if ! rpm -qp --filecaps "$rpm" | grep -qxP '/usr/bin/gamescope\tcap_sys_nice=ep'; then fail "gamescope lacks cap_sys_nice"; fi

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
(cd "$root" && rpm2cpio "$rpm" | cpio -idm --quiet)
help=$("$root/usr/bin/gamescope" --help 2>&1) || fail "gamescope --help exit $?"
for opt in --fake-output-mm --custom-refresh-rates --force-panel-type --touch-gestures; do
  if ! grep -q -- "^ *$opt " <<<"$help"; then fail "--help lacks $opt"; fi
done

exit "$rc"
