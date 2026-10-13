#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
seed=$tree/usr/libexec/microos/microos-steam-seed
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

src=$tmp/src
mkdir -p "$src/.local/share/Steam/steamrtarm64" "$src/.steam"
for d in linux32 linux64 linuxarm64 ubuntu12_32 ubuntu12_64; do mkdir -p "$src/.local/share/Steam/$d"; done
printf '#!/bin/sh\n' > "$src/.local/share/Steam/steamrtarm64/steam"
chmod 755 "$src/.local/share/Steam/steamrtarm64/steam"
ln -s ../.local/share/Steam "$src/.steam/steam"
ln -s ../.local/share/Steam "$src/.steam/root"
ln -s ../.local/share/Steam/linux32 "$src/.steam/sdk32"
ln -s ../.local/share/Steam/linux64 "$src/.steam/sdk64"
ln -s ../.local/share/Steam/linuxarm64 "$src/.steam/sdkarm64"
ln -s ../.local/share/Steam/ubuntu12_32 "$src/.steam/bin32"
ln -s ../.local/share/Steam/ubuntu12_64 "$src/.steam/bin64"
echo oobe > "$src/.steam/registry.vdf"
mkdir -p "$tmp/seed"
tar -C "$src" -cf - .local/share/Steam .steam | zstd -q -o "$tmp/seed/steam-seed.tar.zst"
echo "1 2" > "$tmp/seed/steam-seed.version"

export MICROOS_SEED_DIR=$tmp/seed
links="steam root sdk32 sdk64 sdkarm64 bin32 bin64"
run() { HOME=$1 "$seed" > "$tmp/out" 2>&1; }
check_home() {
  local h=$1 l
  [[ -x $h/.local/share/Steam/steamrtarm64/steam ]] || fail "$2: client missing"
  for l in $links; do [[ -L $h/.steam/$l && -e $h/.steam/$l ]] || fail "$2: link $l"; done
  [[ $(cat "$h/.local/share/microos/steam-seed" 2>/dev/null) == "1 2" ]] || fail "$2: stamp"
  [[ ! -e $h/.local/share/.microos-seed.tmp ]] || fail "$2: tmp left"
}

h=$tmp/fresh
mkdir -p "$h/.local/share/.microos-seed.tmp/junk"
run "$h" || fail "fresh: exit $?: $(cat "$tmp/out")"
check_home "$h" fresh
[[ $(cat "$h/.steam/registry.vdf") == oobe ]] || fail "fresh: registry.vdf"

before=$(find "$h" -printf '%p %y %l\n' | sort)
run "$h" || fail "rerun: exit $?"
[[ $(find "$h" -printf '%p %y %l\n' | sort) == "$before" ]] || fail "rerun changed the home"

rm "$h/.steam/sdk32" "$h/.local/share/microos/steam-seed"
ln -s ../nowhere "$h/.steam/bin64"
run "$h" || fail "repair: exit $?"
check_home "$h" repair
[[ $(readlink "$h/.steam/bin64") == ../.local/share/Steam/ubuntu12_64 ]] || fail "repair: dangling link kept"

h=$tmp/own
mkdir -p "$h/.steam" "$h/elsewhere"
ln -s ../elsewhere "$h/.steam/steam"
echo mine > "$h/.steam/registry.vdf"
run "$h" || fail "own link: exit $?"
[[ $(readlink "$h/.steam/steam") == ../elsewhere ]] || fail "own link: replaced"
[[ $(cat "$h/.steam/registry.vdf") == mine ]] || fail "own registry.vdf: replaced"
[[ -x $h/.local/share/Steam/steamrtarm64/steam ]] || fail "own link: client missing"

for stamped in 0 1; do
  h=$tmp/broken$stamped
  mkdir -p "$h/.local/share/Steam/steamrtarm64"
  echo x > "$h/.local/share/Steam/keep"
  if (( stamped )); then
    mkdir -p "$h/.local/share/microos"
    echo old > "$h/.local/share/microos/steam-seed"
  fi
  run "$h" || fail "broken $stamped: exit $?: $(cat "$tmp/out")"
  aside=("$h"/.local/share/Steam.broken-*)
  [[ ${#aside[@]} == 1 && ${aside[0]} =~ /Steam\.broken-[0-9]{8}T[0-9]{6}Z$ ]] || fail "broken $stamped: aside: ${aside[*]}"
  [[ $(ls -A "${aside[0]}") == $'keep\nsteamrtarm64' ]] || fail "broken $stamped: aside content"
  [[ $(grep -c . "$tmp/out") == 2 ]] || fail "broken $stamped: output: $(cat "$tmp/out")"
  grep -qxF "microos-steam-seed: Steam tree has no steamrtarm64/steam, moved to ${aside[0]}" "$tmp/out" ||
    fail "broken $stamped: message: $(cat "$tmp/out")"
  check_home "$h" "broken $stamped"
  [[ ! -e $h/.local/share/Steam/keep ]] || fail "broken $stamped: old content in the fresh tree"
done

h=$tmp/repair
b=$h/.local/share/Steam
mkdir -p "$b/steamrtarm64" "$b/steamapps/common/Game" "$b/userdata/1" "$b/config" "$b/compatibilitytools.d/p"
echo game > "$b/steamapps/common/Game/game.bin"
echo u > "$b/userdata/1/localconfig.vdf"
echo c > "$b/config/config.vdf"
echo s > "$b/ssfn123"
echo x > "$b/keep"
mkdir -p "$h/.local/share/Steam.broken-20200101T000000Z/steamrtarm64" "$h/.local/share/Steam.broken-20200102T000000Z/steamapps"
head -c 2M /dev/zero > "$h/.local/share/Steam.broken-20200101T000000Z/steamrtarm64/old"
run "$h" || fail "repair data: exit $?: $(cat "$tmp/out")"
check_home "$h" "repair data"
[[ $(cat "$b/steamapps/common/Game/game.bin" 2> /dev/null) == game ]] || fail "repair data: game not in the new tree"
for f in userdata/1/localconfig.vdf config/config.vdf compatibilitytools.d/p ssfn123; do
  [[ -e $b/$f ]] || fail "repair data: $f not in the new tree"
done
[[ ! -e $b/keep ]] || fail "repair data: client file moved back"
aside=("$h"/.local/share/Steam.broken-*)
[[ ${#aside[@]} == 2 && ${aside[0]} == *20200102T000000Z ]] || fail "repair data: broken dirs: ${aside[*]}"
[[ $(ls -A "${aside[1]}") == $'keep\nsteamrtarm64' ]] || fail "repair data: aside content: $(ls -A "${aside[1]}")"
grep -qxF "microos-steam-seed: moved back from ${aside[1]}: steamapps userdata config compatibilitytools.d ssfn123" "$tmp/out" ||
  fail "repair data: moved message: $(cat "$tmp/out")"
grep -qxE "microos-steam-seed: removed $h/.local/share/Steam.broken-20200101T000000Z \([0-9.]+M\)" "$tmp/out" ||
  fail "repair data: removed message: $(cat "$tmp/out")"

h=$tmp/resume
mkdir -p "$h/.local/share/Steam.broken-20200101T000000Z/steamapps/common/Game"
echo game > "$h/.local/share/Steam.broken-20200101T000000Z/steamapps/common/Game/game.bin"
run "$h" || fail "resume: exit $?: $(cat "$tmp/out")"
check_home "$h" resume
[[ $(cat "$h/.local/share/Steam/steamapps/common/Game/game.bin" 2> /dev/null) == game ]] || fail "resume: game not moved back"

h=$tmp/clash
cp -a "$tmp/fresh" "$h"
mkdir -p "$h/.local/share/Steam/steamapps" "$h/.local/share/Steam.broken-20200102T000000Z/steamapps/common/Game"
mkdir -p "$h/.local/share/Steam.broken-20200101T000000Z/steamrtarm64"
echo game > "$h/.local/share/Steam.broken-20200102T000000Z/steamapps/common/Game/game.bin"
run "$h" || fail "clash: exit $?: $(cat "$tmp/out")"
grep -qxF "microos-steam-seed: kept in $h/.local/share/Steam.broken-20200102T000000Z, not moved back: steamapps" "$tmp/out" ||
  fail "clash: message: $(cat "$tmp/out")"
[[ -e $h/.local/share/Steam.broken-20200102T000000Z/steamapps/common/Game/game.bin ]] || fail "clash: game removed"
[[ -d $h/.local/share/Steam.broken-20200101T000000Z ]] || fail "clash: pruned after a failed move back"

h=$tmp/short
mkdir -p "$tmp/short-src" "$tmp/short-seed"
cp -a "$src/." "$tmp/short-src/"
rm "$tmp/short-src/.steam/sdk64"
tar -C "$tmp/short-src" -cf - .local/share/Steam .steam | zstd -q -o "$tmp/short-seed/steam-seed.tar.zst"
cp "$tmp/seed/steam-seed.version" "$tmp/short-seed/"
mkdir -p "$h"
code=0
HOME=$h MICROOS_SEED_DIR=$tmp/short-seed "$seed" > "$tmp/out" 2>&1 || code=$?
(( code == 1 )) || fail "short seed: exit $code, expected 1"
grep -qx 'microos-steam-seed: seed has no .steam/sdk64' "$tmp/out" || fail "short seed: message: $(cat "$tmp/out")"
[[ -z $(find "$h" -mindepth 1 ! -path "$h/.local" ! -path "$h/.local/share") ]] || fail "short seed: home changed: $(find "$h" -mindepth 1)"

exit "$rc"
