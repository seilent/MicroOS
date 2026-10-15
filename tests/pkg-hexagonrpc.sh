#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-hexagonrpc.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

srpm=$(find "$dir" -maxdepth 1 -name 'hexagonrpc-0.5.0^*.src.rpm')
if [[ -z $srpm || $(wc -l <<<"$srpm") -ne 1 ]]; then fail "expected one SRPM in $dir"; fi
if [[ -n $(find "$dir" -maxdepth 1 \( -name '*-debuginfo-*' -o -name '*-debugsource-*' \)) ]]; then fail "debug RPM present"; fi

rpm=$(find "$dir" -maxdepth 1 -name 'hexagonrpc-0.5.0^*.rpm' ! -name '*.src.rpm')
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 ]]; then
  echo "FAIL: expected one hexagonrpc RPM in $dir" >&2
  exit 1
fi
if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "release"; fi
if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi
if [[ -n $srpm && $(rpm -qp --qf '%{SOURCERPM}' "$rpm") != "${srpm##*/}" ]]; then fail "SOURCERPM"; fi
writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi

files=$(rpm -qlp "$rpm")
for f in \
  /usr/share/licenses/hexagonrpc/COPYING \
  /usr/share/licenses/hexagonrpc/LICENSE.BSD-3-Clause \
  /usr/bin/hexagonrpcd \
  /usr/lib64/libhexagonrpc.so.0.5; do
  if ! grep -qx "$f" <<<"$files"; then fail "missing $f"; fi
done
if grep -qE '(/systemd/|\.so$|^/usr/include/)' <<<"$files"; then fail "ships units or devel files"; fi
if ! grep -qx 'libhexagonrpc.so.0.5()(64bit)' <<<"$(rpm -qp --provides "$rpm")"; then fail "does not provide libhexagonrpc.so.0.5"; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rpm2cpio "$rpm" > "$tmp/hexagonrpc.cpio"
(cd "$tmp" && cpio -idm --quiet < hexagonrpc.cpio)
bsd=$tmp/usr/share/licenses/hexagonrpc/LICENSE.BSD-3-Clause
if ! grep -qx 'Copyright (c) 2019, The Linux Foundation. All rights reserved.' "$bsd" \
  || ! grep -qx 'IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.' "$bsd"; then fail "LICENSE.BSD-3-Clause lacks the error.c notice"; fi
if ! LD_LIBRARY_PATH=$tmp/usr/lib64 "$tmp/usr/bin/hexagonrpcd" -h 2>&1 | grep -q -- '-R'; then fail "hexagonrpcd -h does not list -R"; fi

exit "$rc"
