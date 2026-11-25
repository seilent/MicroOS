#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-android-sensors.sh <rpmdir>}
here=$(cd "$(dirname "$0")" && pwd)
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

rpm=$(find "$dir" -maxdepth 1 -name 'microos-android-sensors-[0-9]*.rpm' ! -name '*.src.rpm')
srpm=$(find "$dir" -maxdepth 1 -name 'microos-android-sensors-[0-9]*.src.rpm')
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 || -z $srpm || $(wc -l <<<"$srpm") -ne 1 ]]; then
  echo "FAIL: expected one microos-android-sensors RPM and one SRPM in $dir" >&2
  exit 1
fi
others=$(find "$dir" -maxdepth 1 -name '*.rpm' ! -samefile "$rpm" ! -samefile "$srpm")
if [[ -n $others ]]; then fail "other RPMs: $others"; fi
if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "release"; fi
if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi
if [[ $(rpm -qp --qf '%{SOURCERPM}' "$rpm") != "${srpm##*/}" ]]; then fail "SOURCERPM"; fi
if [[ $(rpm -qp --qf '%{LICENSE}' "$rpm") != GPL-2.0-or-later ]]; then fail "License tag"; fi
writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi
files=$(rpm -qlp "$rpm")
want=$'/usr/bin/waydroid-sensord\n/usr/share/licenses/microos-android-sensors\n/usr/share/licenses/microos-android-sensors/LICENSE'
if [[ $files != "$want" ]]; then fail "files: $files"; fi
if [[ $(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | grep ' /usr/bin/waydroid-sensord$') != '-rwxr-xr-x /usr/bin/waydroid-sensord' ]]; then
  fail "/usr/bin/waydroid-sensord is not 755"
fi
requires=$(rpm -qp --requires "$rpm")
grep -qx 'waydroid' <<<"$requires" || fail "does not require waydroid"
grep -q '^libgbinder\.so\.1' <<<"$requires" || fail "does not require libgbinder: $(tr '\n' ' ' <<<"$requires")"
if [[ $(rpm -qp --qf '[%{SOURCE}\n]' "$srpm") != microos-android-sensors.tar.gz ]]; then fail "SRPM sources"; fi

work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
(cd "$work" && rpm2cpio "$rpm" | cpio -idm --quiet && rpm2cpio "$srpm" | cpio -idm --quiet)
bin=$work/usr/bin/waydroid-sensord
undefined=$(nm -D --undefined-only "$bin" | awk '{ print $2 }' | sed 's/@.*//')
for s in gbinder_servicemanager_new2 gbinder_servicemanager_add_service gbinder_remote_request_block \
  gbinder_remote_request_complete gbinder_writer_append_buffer_object_with_parent socket recvfrom sendto; do
  grep -qx "$s" <<<"$undefined" || fail "waydroid-sensord does not call $s"
done
if ! grep -qx ' *Version 2, June 1991' "$work/usr/share/licenses/microos-android-sensors/LICENSE"; then fail "LICENSE"; fi

tar -xzf "$work/microos-android-sensors.tar.gz" -C "$work"
src=$work/microos-android-sensors
read -ra cflags <<<"$(pkg-config --cflags libgbinder libglibutil glib-2.0)"
read -ra libs <<<"$(pkg-config --libs libglibutil glib-2.0)"
gcc -O2 -g -std=gnu11 -Wall -Wextra -Werror "${cflags[@]}" -o "$work/sensord-fake" \
  "$src/sensord.c" "$src/ssc.c" "$here/pkg-android-sensors/fake.c" "${libs[@]}" -ldl ||
  { fail "the daemon does not build against the fake libgbinder"; exit 1; }
PYTHONDONTWRITEBYTECODE=1 python3 "$here/pkg-android-sensors/sensortest.py" "$work/sensord-fake" || rc=1

exit "$rc"
