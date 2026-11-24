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
  "$repo/packages/microos-android/data/usr/bin/microos-android"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-check"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-guest"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-install"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-fetch"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-gamescope-plain"
)
python=(
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-battery"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-brightness"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-client"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-lsfg"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-perf"
  "$repo/packages/microos-android/data/usr/libexec/microos/microos-android-root"
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
for f in "$repo"/packages/microos-android/data/usr/libexec/microos/* "$repo"/packages/microos-android/data/usr/bin/*; do
  [[ -f $f ]] || continue
  if [[ $(stat -c %a "$f") != 755 ]]; then fail "${f#"$repo/"} is not 755"; fi
done

hits=$(grep -rnE 'MICROEMU|microemu|microos-lepton|lepton-android|liblepton|podman' "$repo/packages/microos-android/data" || true)
[[ -z $hits ]] || fail "MicroEMU, Lepton or podman names in: ${hits//"$repo/"/}"

out=$(mktemp)
trap 'rm -f "${out:?}"' EXIT
for t in guest-test root-test reset-test gapps-install-test play-unit-test run-test check-test status-test state-test \
  client-test session-test cli-test storage-test lsfg-test perf-test battery-test brightness-test; do
  if ! bash "${tests}/${t}.sh" > "$out" 2>&1; then
    fail "${t}.sh: $(tail -n 5 "$out" | tr '\n' ' ')"
  fi
  sed -n "s|^SKIP |${t}.sh: SKIP |p" "$out"
done

exit "$rc"
