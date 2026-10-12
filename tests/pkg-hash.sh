#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

mkdir -p "$tmp/build" "$tmp/tests" "$tmp/packages/a" "$tmp/packages/b"
cp "$root/build/pkg-hash.sh" "$tmp/build/"
echo base > "$tmp/build/pkg.Containerfile"
echo one > "$tmp/packages/a/build.sh"
echo one > "$tmp/packages/b/build.sh"
pkghash() { "$tmp/build/pkg-hash.sh" "$1"; }

h=$(pkghash a)
[[ $h =~ ^[0-9a-f]{16}$ ]] || fail "format: $h"
[[ $(pkghash a) == "$h" ]] || fail "not stable"
[[ $(cd / && pkghash a) == "$h" ]] || fail "depends on cwd"
[[ $(pkghash b) != "$h" ]] || fail "same hash for two packages"

echo two > "$tmp/packages/b/build.sh"
[[ $(pkghash a) == "$h" ]] || fail "changes with another package"
hb=$(pkghash b)

chmod +x "$tmp/packages/a/build.sh"
[[ $(pkghash a) != "$h" ]] || fail "ignores the exec bit"
chmod -x "$tmp/packages/a/build.sh"

echo two > "$tmp/packages/a/build.sh"
[[ $(pkghash a) != "$h" ]] || fail "ignores content"
echo one > "$tmp/packages/a/build.sh"

echo extra > "$tmp/packages/a/extra"
[[ $(pkghash a) != "$h" ]] || fail "ignores a new file"
rm "$tmp/packages/a/extra"

echo changed > "$tmp/build/pkg.Containerfile"
[[ $(pkghash a) != "$h" ]] || fail "ignores pkg.Containerfile"
echo base > "$tmp/build/pkg.Containerfile"

echo test > "$tmp/tests/pkg-a.sh"
[[ $(pkghash a) != "$h" ]] || fail "ignores tests/pkg-a.sh"
[[ $(pkghash b) == "$hb" ]] || fail "tests/pkg-a.sh changes another package"
rm "$tmp/tests/pkg-a.sh"

[[ $(pkghash a) == "$h" ]] || fail "not restored"
pkghash missing 2>/dev/null && fail "accepts a missing package"
pkghash ../build 2>/dev/null && fail "accepts a path"

exit "$rc"
