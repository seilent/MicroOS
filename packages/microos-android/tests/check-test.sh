#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
check="${repo}/data/usr/libexec/microos/microos-android-check"

T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

export HOME="${T}/home"
export MICROOS_ANDROID_IMAGES="${T}/images"
export MICROOS_ANDROID_IMAGES_STATE="${T}/images.state"
export MICROOS_ANDROID_INPUTS="${T}/images.inputs"
export MICROOS_WAYDROID_DATA="${T}/home/.local/share/microos-waydroid"
export MICROOS_ANDROID_PINS="${T}/images.env"
export MICROOS_ANDROID_IMAGES_BIN="${T}/images-bin"
mkdir -p "${HOME}" "${MICROOS_ANDROID_IMAGES}"
printf 'SET=los20av-20260927-20261022\n' > "${MICROOS_ANDROID_PINS}"
printf '%064d\n' 1 > "${T}/stamp"
printf '#!/bin/sh\n[ "$*" = --stamp ] || exit 9\ncat "%s"\n' "${T}/stamp" > "${MICROOS_ANDROID_IMAGES_BIN}"
chmod 0755 "${MICROOS_ANDROID_IMAGES_BIN}"
ready() { printf 'state=ready\nset=%s\n' "$1" > "${MICROOS_ANDROID_IMAGES_STATE}"; }
applied() { cp "${T}/stamp" "${MICROOS_ANDROID_INPUTS}"; }

expect() {
    local want_rc=$1 want_out=$2 rc=0 out
    out=$(timeout -k 1 1 "${check}" 2> "${T}/err") || rc=$?
    [[ "${rc}" == "${want_rc}" && "${out}" == "${want_out}" ]] || fail "$3: exit ${rc}, out '${out}', $(cat "${T}/err")"
}

expect 1 "" "no images"
printf 'state=failed\nset=los20av-20260927-20261022\n' > "${MICROOS_ANDROID_IMAGES_STATE}"
expect 1 "" "a failed images fetch with no set"
printf 'state=fetching\nset=los20av-20260927-20261022\n' > "${MICROOS_ANDROID_IMAGES_STATE}"
expect 2 downloading "an images fetch running"
rm -f "${MICROOS_ANDROID_IMAGES_STATE}"
mkdir -p "${MICROOS_ANDROID_IMAGES}/los20av-20260927-20261022"
ln -s los20av-20260927-20261022 "${MICROOS_ANDROID_IMAGES}/current"
export MICROOS_ANDROID_FLOOR=1
expect 1 "" "a set with no images state"
printf 'state=failed\nset=los20av-20260927-20261022\n' > "${MICROOS_ANDROID_IMAGES_STATE}"
applied
expect 1 "" "a failed fetch of a new set beside the current one"
printf 'state=fetching\nset=los20av-20260927-20261022\n' > "${MICROOS_ANDROID_IMAGES_STATE}"
expect 2 downloading "a new set fetching"
rm "${MICROOS_ANDROID_INPUTS}"
ready los20av-20260927-20261022
expect 1 "" "a ready set with no inputs file"
applied
expect 0 "" "a ready set with the booted inputs"
printf '%064d\n' 2 > "${T}/stamp"
expect 1 "" "a ready set with a stale inputs file"
applied
expect 0 "" "a ready set with the new inputs"
rm "${MICROOS_ANDROID_INPUTS}"
mv "${T}/stamp" "${T}/stamp.off"
expect 1 "" "a stamp that fails with no inputs file"
mv "${T}/stamp.off" "${T}/stamp"
applied
ready los20a-20260927-20261022
expect 1 "" "a ready state of another set"
ready los20av-20260927-20261022
mkdir -p "${MICROOS_ANDROID_IMAGES}/los20a-20260927-20261022"
ln -sfn los20a-20260927-20261022 "${MICROOS_ANDROID_IMAGES}/current"
expect 1 "" "current on another set"
ln -sfn los20av-20260927-20261022 "${MICROOS_ANDROID_IMAGES}/current"
expect 0 "" "current back on the booted set"
export MICROOS_ANDROID_FLOOR=$((1 << 62))
expect 2 no-space "under the floor"
mkdir -p "${MICROOS_WAYDROID_DATA}"
expect 2 no-space "under the floor with the data dir"
export MICROOS_ANDROID_FLOOR=1
rmdir "${MICROOS_ANDROID_IMAGES}/los20av-20260927-20261022"
expect 1 "" "a dangling current link"
[[ "$(grep -c -e podman -e lepton -e Steam "${check}")" == 0 ]] || fail "the check reads Lepton or Steam"

(( failures == 0 )) || { echo "${failures} failure(s)" >&2; exit 1; }
echo "check-test: pass"
