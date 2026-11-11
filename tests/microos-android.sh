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
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-check"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-install"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-keyboard"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-pad-nodes"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-run"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-sideload"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-stop"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-fetch"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-gamescope-plain"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-lepton"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-lepton-prepare"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-lepton-steam"
)
python=(
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-client"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-lsfg"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-session-watch"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-status"
)
for f in "${python[@]}"; do
  if ! out=$(python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$f" 2>&1); then
    fail "${f#"$repo/"} syntax: ${out//$'\n'/ }"
  fi
done
for f in "${scripts[@]}"; do
  if ! out=$(shellcheck -s bash -e SC1090,SC1091,SC2015,SC2016,SC2094 "$f" 2>&1); then
    fail "${f#"$repo/"} shellcheck: ${out//$'\n'/ }"
  fi
done
for lib in microos-liblepton.sh microos-lepton-lib.sh; do
  if ! out=$(shellcheck -s bash -e SC1090,SC1091,SC2033,SC2034,SC2154 \
    "$repo/packages/microos-android/data/usr/libexec/microos/$lib" 2>&1); then
    fail "$lib shellcheck: ${out//$'\n'/ }"
  fi
  if [[ $(head -c 2 "$repo/packages/microos-android/data/usr/libexec/microos/$lib") == '#!' ]]; then
    fail "$lib is sourced and carries a shebang"
  fi
  if [[ $(stat -c %a "$repo/packages/microos-android/data/usr/libexec/microos/$lib") != 644 ]]; then
    fail "$lib is not 644"
  fi
done
for f in "$repo"/packages/microos-android/data/usr/libexec/microos/* "$repo"/packages/microos-android/data/usr/bin/*; do
  [[ -f $f ]] || continue
  case $f in */microos-liblepton.sh|*/microos-lepton-lib.sh) continue ;; esac
  if [[ $(stat -c %a "$f") != 755 ]]; then fail "${f#"$repo/"} is not 755"; fi
done

guest_cmd=$repo/packages/microos-android/data/usr/share/microos-android/cmd
if ! out=$(shellcheck -s ksh "$guest_cmd" 2>&1); then
  fail "cmd shellcheck: ${out//$'\n'/ }"
fi
if [[ $(head -n 1 "$guest_cmd") != '#!/system/bin/sh' ]]; then fail "cmd has no /system/bin/sh shebang"; fi
if [[ $(stat -c %a "$guest_cmd") != 755 ]]; then fail "cmd is not 755"; fi

hits=$(grep -rnE 'MICROEMU|microemu' "$repo/packages/microos-android/data" | grep -vE 'legacy_contexts|contexts/microemu-\$\{old\}|share/microemu/android/home' || true)
[[ -z $hits ]] || fail "MicroEMU names in: ${hits//"$repo/"/}"

out=$(mktemp)
trap 'rm -f "${out:?}"' EXIT
for t in stub-test keyboard-test sideload-test reset-test gapps-install-test play-unit-test run-test lepton-test \
  check-test prepare-test install-request-test status-test state-test client-test session-test cli-test \
  session-watch-test storage-test lsfg-test; do
  if ! bash "${tests}/${t}.sh" > "$out" 2>&1; then
    fail "${t}.sh: $(tail -n 5 "$out" | tr '\n' ' ')"
  fi
done

exit "$rc"
