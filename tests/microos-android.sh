#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
tests=$repo/packages/microos-android/tests
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

for t in shellcheck bash python3; do
  command -v "$t" > /dev/null || { echo "FAIL: $t missing" >&2; exit 1; }
done

scripts=(
  "$repo/packages/microos-android/build.sh"
  "$repo/packages/microos-android/build/stub.sh"
  "$repo/packages/microos-android/data/usr/bin/microos-android"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-keyboard"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-pad-nodes"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-run"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-sideload"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-stop"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-fetch"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-lepton"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-lepton-steam"
)
for f in "${scripts[@]}"; do
  if ! out=$(shellcheck -s bash -e SC2015,SC2016,SC2094 "$f" 2>&1); then
    fail "${f#"$repo/"} shellcheck: ${out//$'\n'/ }"
  fi
done
if ! out=$(shellcheck -s bash -e SC1091,SC2034,SC2033,SC2154 "$repo/packages/microos-android/data/usr/libexec/microos/microos-liblepton.sh" 2>&1); then
  fail "microos-liblepton.sh shellcheck: ${out//$'\n'/ }"
fi
if [[ $(head -c 2 "$repo/packages/microos-android/data/usr/libexec/microos/microos-liblepton.sh") == '#!' ]]; then
  fail "microos-liblepton.sh is sourced and carries a shebang"
fi
if [[ $(stat -c %a "$repo/packages/microos-android/data/usr/libexec/microos/microos-liblepton.sh") != 644 ]]; then
  fail "microos-liblepton.sh is not 644"
fi
for f in "$repo"/packages/microos-android/data/usr/libexec/microos/* "$repo"/packages/microos-android/data/usr/bin/*; do
  [[ -f $f ]] || continue
  [[ $f == */microos-liblepton.sh ]] && continue
  if [[ $(stat -c %a "$f") != 755 ]]; then fail "${f#"$repo/"} is not 755"; fi
done

hits=$(grep -rlE 'MICROEMU|microemu' "$repo/packages/microos-android/data" || true)
[[ -z $hits ]] || fail "MicroEMU names in: ${hits//"$repo/"/}"

out=$(mktemp)
trap 'rm -f "${out:?}"' EXIT
for t in stub-test keyboard-test sideload-test reset-test gapps-install-test play-unit-test run-test lepton-test; do
  if ! bash "${tests}/${t}.sh" > "$out" 2>&1; then
    fail "${t}.sh: $(tail -n 5 "$out" | tr '\n' ' ')"
  fi
done

exit "$rc"
