#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-inputplumber.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"
version=${INPUTPLUMBER_VERSION:?SOURCE.env has no INPUTPLUMBER_VERSION}

rpm=$(find "$dir" -maxdepth 1 -name "inputplumber-$version-*.rpm" ! -name '*.src.rpm')
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 ]]; then
  echo "FAIL: expected one inputplumber RPM in $dir" >&2
  exit 1
fi
if [[ -z $(find "$dir" -maxdepth 1 -name "inputplumber-$version-*.src.rpm") ]]; then fail "SRPM missing"; fi
if [[ -n $(find "$dir" -maxdepth 1 \( -name '*-debuginfo-*' -o -name '*-debugsource-*' \)) ]]; then fail "debug RPM present"; fi

if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "release"; fi
if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi

writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi

files=$(rpm -qlp "$rpm")
for f in \
  /usr/share/licenses/inputplumber/LICENSE \
  /usr/bin/inputplumber \
  /usr/lib/systemd/system/inputplumber.service \
  /usr/lib/systemd/system/inputplumber-suspend.service \
  /usr/share/dbus-1/system.d/org.shadowblip.InputPlumber.conf \
  /usr/share/polkit-1/actions/org.shadowblip.InputPlumber.policy \
  /usr/share/polkit-1/rules.d/org.shadowblip.InputPlumber.rules \
  /usr/lib/udev/rules.d/90-inputplumber-autostart.rules \
  /usr/share/inputplumber/schema/composite_device_v1.json \
  /usr/share/inputplumber/schema/capability_map_v2.json; do
  if ! grep -qx "$f" <<<"$files"; then fail "missing $f"; fi
done
for f in /usr/lib/modules-load.d/ /usr/share/dbus-1/system-services/; do
  if grep -q "^$f" <<<"$files"; then fail "ships $f"; fi
done
if (( $(grep -c '^/usr/share/inputplumber/devices/.*\.yaml$' <<<"$files") < 50 )); then fail "upstream device configs missing"; fi

exit "$rc"
