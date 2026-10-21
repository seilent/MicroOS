#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-microos-eq.sh <rpmdir>}
here=$(cd "$(dirname "$0")" && pwd)
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

rpm=$(find "$dir" -maxdepth 1 -name 'microos-eq-[0-9]*.rpm' ! -name '*.src.rpm')
srpm=$(find "$dir" -maxdepth 1 -name 'microos-eq-[0-9]*.src.rpm')
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 || -z $srpm || $(wc -l <<<"$srpm") -ne 1 ]]; then
  echo "FAIL: expected one microos-eq RPM and one SRPM in $dir" >&2
  exit 1
fi
others=$(find "$dir" -maxdepth 1 -name '*.rpm' ! -samefile "$rpm" ! -samefile "$srpm")
if [[ -n $others ]]; then fail "other RPMs: $others"; fi
if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "release"; fi
if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi
if [[ $(rpm -qp --qf '%{SOURCERPM}' "$rpm") != "${srpm##*/}" ]]; then fail "SOURCERPM"; fi
writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi
files=$(rpm -qlp "$rpm")
want=$'/usr/lib64/ladspa\n/usr/lib64/ladspa/microos-eq.so\n/usr/share/licenses/microos-eq\n/usr/share/licenses/microos-eq/LICENSE\n/usr/share/licenses/microos-eq/LICENSE.BSD-3-Clause'
if [[ $files != "$want" ]]; then fail "files: $files"; fi

work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
(cd "$work" && rpm2cpio "$rpm" | cpio -idm --quiet && rpm2cpio "$srpm" | cpio -idm --quiet)
so=$work/usr/lib64/ladspa/microos-eq.so
exports=$(nm -D --defined-only "$so" | awk '{print $3}' | sort | tr '\n' ' ')
if [[ $exports != 'ladspa_descriptor microos_eq_design microos_eq_xfeed_design ' ]]; then fail "exports: $exports"; fi
lic=$work/usr/share/licenses/microos-eq
if ! grep -qx ' *Version 2, June 1991' "$lic/LICENSE"; then fail "LICENSE"; fi
if ! grep -qx 'Copyright (c) 2013 The Chromium OS Authors. All rights reserved.' "$lic/LICENSE.BSD-3-Clause" \
  || ! grep -qx 'Copyright (C) 2010 Google Inc. All rights reserved.' "$lic/LICENSE.BSD-3-Clause"; then fail "LICENSE.BSD-3-Clause"; fi
if [[ $(rpm -qp --qf '%{LICENSE}' "$rpm") != 'GPL-2.0-or-later AND BSD-3-Clause' ]]; then fail "License tag"; fi
. "$dir/SOURCE.env"
if [[ ! -f $dir/pipewire/biquad.c || ! -f $dir/pipewire/biquad.h ]]; then fail "no PipeWire $PIPEWIRE_EVR biquad.c in $dir/pipewire"; fi

tar -xzf "$work/microos-eq.tar.gz" -C "$work"
cflags=$(rpm --eval '%{optflags}')
for v in test:MICROOS_EQ_TEST v0:MICROOS_EQ_V0 v1:MICROOS_EQ_V1 nogate:MICROOS_EQ_NOGATE; do
  make -s -C "$work/microos-eq" CFLAGS="$cflags" DEFS="-D${v#*:}" OUT="$work/eq-${v%%:*}.so"
done
g++ -std=c++20 -O2 -o "$work/biquad-ref" "$here/pkg-microos-eq/fixtures/biquad-ref.cpp" "$here/pkg-microos-eq/fixtures/Biquad.cpp"
g++ -std=c++20 -O2 -ffp-contract=off -o "$work/flatdap-ref" "$here/pkg-microos-eq/fixtures/flatdap-ref.cpp"

PYTHONDONTWRITEBYTECODE=1 python3 "$here/pkg-microos-eq/eqtest.py" --so "$so" --test "$work/eq-test.so" --v0 "$work/eq-v0.so" \
  --v1 "$work/eq-v1.so" --nogate "$work/eq-nogate.so" --flatdap-ref "$work/flatdap-ref" \
  --biquad-ref "$work/biquad-ref" --fixture "$here/pkg-microos-eq/fixtures/flatdap-987ddd3.txt" --work "$work" --pipewire "$dir/pipewire" || rc=1

exit "$rc"
