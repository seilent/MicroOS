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
git -C "$tmp" init -q
pkghash() { git -C "$tmp" add -A && "$tmp/build/pkg-hash.sh" "$@"; }

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

mkdir -p "$tmp/tests/pkg-a"
echo helper > "$tmp/tests/pkg-a/helper.sh"
[[ $(pkghash a) != "$h" ]] || fail "ignores tests/pkg-a/"
[[ $(pkghash b) == "$hb" ]] || fail "tests/pkg-a/ changes another package"
rm -r "$tmp/tests/pkg-a"

[[ $(pkghash a) == "$h" ]] || fail "not restored"
echo scratch > "$tmp/packages/a/untracked"
git -C "$tmp" add -A
git -C "$tmp" rm -q --cached "$tmp/packages/a/untracked"
[[ $("$tmp/build/pkg-hash.sh" a) == "$h" ]] || fail "counts an untracked file"
rm "$tmp/packages/a/untracked"

pkghash missing 2>/dev/null && fail "accepts a missing package"
pkghash ../build 2>/dev/null && fail "accepts a path"

[[ -z $(pkghash --deps a) ]] || fail "deps without DEPS"
[[ $(pkghash --inputs a) == "$(printf '%s\n' packages/a build/pkg.Containerfile build/pkg-wrap.Containerfile tests/pkg-a.sh tests/pkg-a)" ]] || fail "inputs without DEPS"
plain=$(git -C "$tmp" ls-files -s -- packages/a build/pkg.Containerfile build/pkg-wrap.Containerfile tests/pkg-a.sh tests/pkg-a | LC_ALL=C sort -k4 | sha256sum | cut -c1-16)
[[ $h == "$plain" ]] || fail "input without DEPS is not the index entries alone"

mkdir -p "$tmp/packages/c"
echo one > "$tmp/packages/c/build.sh"
printf 'b\n\na\n' > "$tmp/packages/c/DEPS"
hc=$(pkghash c)
[[ $hc =~ ^[0-9a-f]{16}$ ]] || fail "deps format: $hc"
[[ $(pkghash --deps c) == "$(printf 'a\nb')" ]] || fail "deps list: $(pkghash --deps c)"
want=$({ git -C "$tmp" ls-files -s -- packages/c build/pkg.Containerfile build/pkg-wrap.Containerfile tests/pkg-c.sh tests/pkg-c | LC_ALL=C sort -k4; printf 'dep a %s\ndep b %s\n' "$h" "$hb"; } | sha256sum | cut -c1-16)
[[ $hc == "$want" ]] || fail "deps input is not the index entries plus the dep hashes"
[[ $(pkghash a) == "$h" && $(pkghash b) == "$hb" ]] || fail "DEPS of c moves its deps"
grep -qx packages/b <(pkghash --inputs c) || fail "inputs of c miss its dep b"
echo two > "$tmp/packages/b/extra"
[[ $(pkghash c) != "$hc" ]] || fail "ignores a dep change"
rm "$tmp/packages/b/extra"
[[ $(pkghash c) == "$hc" ]] || fail "deps not restored"
printf 'a\n' > "$tmp/packages/c/DEPS"
[[ $("$tmp/build/pkg-hash.sh" c) == "$hc" ]] || fail "reads DEPS from the work tree"
[[ $("$tmp/build/pkg-hash.sh" --deps c) == "$(printf 'a\nb')" ]] || fail "reads the deps list from the work tree"
echo c > "$tmp/packages/a/DEPS"
pkghash c >/dev/null 2>&1 && fail "accepts a dep with DEPS"
rm "$tmp/packages/a/DEPS"
echo c > "$tmp/packages/c/DEPS"
pkghash c >/dev/null 2>&1 && fail "accepts itself as dep"
echo missing > "$tmp/packages/c/DEPS"
pkghash c >/dev/null 2>&1 && fail "accepts a missing dep"
echo ../a > "$tmp/packages/c/DEPS"
pkghash c >/dev/null 2>&1 && fail "accepts a path as dep"

base=${PKG_HASH_BASE:-main}
if old=$(git -C "$root" show "$base:build/pkg-hash.sh" 2>/dev/null); then
  mkdir -p "$tmp/base/build"
  printf '%s\n' "$old" > "$tmp/base/build/pkg-hash.sh"
  chmod +x "$tmp/base/build/pkg-hash.sh"
  n=0
  for name in $(git -C "$root" ls-files -- 'packages/*/build.sh' | cut -d/ -f2); do
    [[ -z $(git -C "$root" ls-files -- "packages/$name/DEPS") ]] || continue
    new=$("$root/build/pkg-hash.sh" "$name")
    was=$(GIT_DIR=$(git -C "$root" rev-parse --absolute-git-dir) GIT_WORK_TREE=$tmp/base "$tmp/base/build/pkg-hash.sh" "$name")
    if [[ $new == "$was" ]]; then
      n=$((n + 1))
    else
      fail "$name hashes $new, $was with the $base script"
    fi
  done
  (( n )) || fail "no package matches the $base script"
  echo "$n packages hash the same as with the $base script"
else
  fail "no build/pkg-hash.sh at $base"
fi

exit "$rc"
