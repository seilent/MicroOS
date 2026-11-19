#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
seed=$tree/usr/libexec/microos/microos-ii-seed
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

src=$tmp/src
home=$tmp/home
c=$home/.config
s=$home/.local/share/microos
mk() { mkdir -p "$(dirname "$src/$1")" && printf '%s\n' "$2" > "$src/$1"; }
run() {
  r=0
  env -i HOME="$home" PATH=/usr/bin:/bin MICROOS_II_SEED_DIR="$src" MICROOS_VERSION_FILE="$tmp/version" \
    bash "$seed" > "$tmp/log" 2>&1 || r=$?
  (( r == 0 )) || fail "seed exit $r: $(cat "$tmp/log")"
}
said() { grep -qF -- "$1" "$tmp/log"; }
val() { cat "$1" 2> /dev/null || true; }
image() { echo "IMAGE_VERSION=$1" > "$tmp/version"; }

mk quickshell/ii/shell.qml s1
mk quickshell/ii/sub/a.qml a1
mk quickshell/ii/gone.qml x1
mk quickshell/ii/mine-gone.qml y1
mk quickshell/ii/del.qml d1
mk matugen/config.toml "output_path = '~/.config/hypr/hyprland/colors.lua'"
mk hypr/hyprland.lua h1
mk hypr/general.lua g1
mk hypr/hyprland/colors.lua template
mk hypr/scripts/x.sh '#!/bin/sh'
chmod +x "$src/hypr/scripts/x.sh"

image A
run
[[ $(val "$c/hypr/hyprland.lua") == h1 && -x $c/hypr/scripts/x.sh && -w $c/quickshell/ii/shell.qml ]] ||
  fail "fresh seed: $(ls -lR "$c/hypr")"
[[ $(val "$s/ii-seed") == "3 IMAGE_VERSION=A" ]] || fail "stamp after a fresh seed: $(cat "$s/ii-seed")"

run
[[ ! -s $tmp/log ]] || fail "same image did work: $(cat "$tmp/log")"

echo mine > "$c/hypr/general.lua"
echo mine > "$c/quickshell/ii/mine-gone.qml"
rm "$c/quickshell/ii/del.qml"
mk hypr/hyprland.lua h2
mk hypr/general.lua g2
mk quickshell/ii/sub/b.qml b2
rm "$src/quickshell/ii/gone.qml" "$src/quickshell/ii/mine-gone.qml"
image B
run
[[ $(val "$c/hypr/hyprland.lua") == h2 ]] || fail "untouched file not updated"
[[ $(val "$c/hypr/general.lua") == mine ]] || fail "edited file not kept"
[[ $(val "$c/quickshell/ii/sub/b.qml") == b2 ]] || fail "new file not added"
[[ ! -e $c/quickshell/ii/del.qml ]] || fail "a deleted shipped file came back"
[[ ! -e $c/quickshell/ii/gone.qml ]] || fail "an untouched file the image dropped stays"
[[ $(val "$c/quickshell/ii/mine-gone.qml") == mine ]] || fail "an edited file the image dropped is gone"
said "kept $c/hypr/general.lua, it has local changes" || fail "no kept line: $(cat "$tmp/log")"

mk hypr/general.lua g3
image C
run
[[ $(val "$c/hypr/general.lua") == mine ]] || fail "edit not kept against the next image"

rm "$src/quickshell/ii/sub/a.qml"
mk quickshell/ii/sub/a.qml/inner.qml i1
mkdir "$c/hypr/dir.lua"
mk hypr/dir.lua f1
image D
run
[[ $(val "$c/quickshell/ii/sub/a.qml/inner.qml") == i1 ]] || fail "file to dir change: $(cat "$tmp/log")"
said "kept $c/hypr/dir.lua, it is not a regular file" || fail "dir where a file ships: $(cat "$tmp/log")"
[[ $(val "$s/ii-seed") == "3 IMAGE_VERSION=D" ]] || fail "stamp after a refresh with kept paths"
rm -rf "$src/quickshell/ii/sub/a.qml" "$src/hypr/dir.lua" "$c/hypr/dir.lua"
mk quickshell/ii/sub/a.qml a1
image D2
run
[[ -f $c/quickshell/ii/sub/a.qml && $(val "$c/quickshell/ii/sub/a.qml") == a1 ]] || fail "dir to file change: $(cat "$tmp/log")"

echo mine > "$c/quickshell/ii/extra"
mk quickshell/ii/extra/new.qml n1
image D3
run
said "cannot add $c/quickshell/ii/extra/new.qml" || fail "no cannot add line: $(cat "$tmp/log")"
[[ $(val "$s/ii-seed") == "3 IMAGE_VERSION=D2" ]] || fail "stamp written after a failed add"
rm "$c/quickshell/ii/extra"
run
[[ $(val "$c/quickshell/ii/extra/new.qml") == n1 ]] || fail "a failed add was not retried: $(cat "$tmp/log")"
[[ $(val "$s/ii-seed") == "3 IMAGE_VERSION=D3" ]] || fail "stamp after the retried add"
rm -rf "$src/quickshell/ii/extra"

rm -rf "$home"
for t in quickshell/ii matugen hypr; do
  mkdir -p "$c/$(dirname "$t")"
  cp -rL --no-preserve=mode,ownership "$src/$t" "$c/$t"
done
mkdir -p "$s"
echo 2 > "$s/ii-seed"
[[ ! -x $c/hypr/scripts/x.sh ]] || fail "the old seed copy kept the exec bit, the case proves nothing"
run
[[ -x $c/hypr/scripts/x.sh ]] || fail "old unmodified tree: exec bit not restored"
! compgen -G "$c/hypr.pre-ii-*" > /dev/null || fail "old unmodified tree moved aside"
said "adopted $c/hypr" || fail "no adopted line: $(cat "$tmp/log")"

rm -rf "$s/ii-seed-sums"
echo 2 > "$s/ii-seed"
echo edited > "$c/hypr/general.lua"
echo generated > "$c/hypr/hyprland/colors.lua"
mkdir -p "$c/hypr/hyprlock" "$c/hypr/custom/scripts"
echo generated > "$c/hypr/hyprlock/colors.conf"
echo added > "$c/hypr/custom/scripts/wall.sh"
ln -s "$tmp/dots-local.lua" "$c/hypr/local.lua"
run
aside=$(compgen -G "$c/hypr.pre-ii-*" | head -n 1)
[[ -n $aside && $(val "$aside/general.lua") == edited ]] || fail "old edited tree: edit not kept aside"
[[ $(val "$c/hypr/general.lua") == g3 ]] || fail "old edited tree: not reseeded"
[[ $(val "$c/hypr/hyprland/colors.lua") == generated ]] || fail "matugen output not restored"
[[ $(val "$c/hypr/hyprlock/colors.conf") == generated && $(val "$c/hypr/custom/scripts/wall.sh") == added ]] ||
  fail "files the image does not ship not restored"
[[ $(readlink "$c/hypr/local.lua") == "$tmp/dots-local.lua" ]] || fail "a symlink in the old tree not restored"
said "restored 4 generated or added files into $c/hypr; 1 changed shipped files stay in $aside" ||
  fail "no restore line: $(cat "$tmp/log")"

echo again > "$c/hypr/hyprland/colors.lua"
mk hypr/hyprland/colors.lua template2
image E
run
[[ $(val "$c/hypr/hyprland/colors.lua") == again ]] || fail "a regenerated matugen output was replaced"

rm -rf "$c/matugen"
ln -s "$src/matugen" "$c/matugen"
mkdir -p "$tmp/dots/hypr"
rm -rf "$c/hypr"
ln -s "$tmp/dots/hypr" "$c/hypr"
image F
run
[[ -d $c/matugen && ! -L $c/matugen ]] || fail "legacy symlink not replaced"
[[ $(readlink "$c/hypr") == "$tmp/dots/hypr" ]] || fail "a symlink outside the image was removed"

rm -rf "$src/matugen"
image G
run
said "no $src/matugen" || fail "no line for a missing tree: $(cat "$tmp/log")"
[[ $(val "$s/ii-seed") == "3 IMAGE_VERSION=F" ]] || fail "stamp written after an incomplete run"

if (( rc == 0 )); then
  echo "ii-seed: ok"
fi
exit "$rc"
