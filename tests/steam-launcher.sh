#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
launcher=$tree/usr/bin/steam
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

root=$tmp/home/.local/share/Steam
mkdir -p "$root/steamrtarm64"
cat > "$root/steamrtarm64/steam" <<'STUB'
#!/usr/bin/env bash
printf 'cwd=%s\n' "$PWD"
printf 'arg=%s\n' "$@"
env | grep -E '^(PATH|LD_LIBRARY_PATH|SYSTEM_PATH|SYSTEM_LD_LIBRARY_PATH|FUSERMOUNT_PROG|SteamDeck)='
STUB
chmod 755 "$root/steamrtarm64/steam"

out=$(cd / && HOME=$tmp/home PATH=/usr/bin:/bin LD_LIBRARY_PATH=/opt/x "$launcher" -gamepadui "a b" steam://open/x)
want() { grep -qxF "$1" <<<"$out" || fail "missing '$1' in: $out"; }
ld=$root/steamrtarm64:$root/lib/aarch64-linux-gnu:/opt/x
path=$root/steam-runtime-steamrt-arm64/bin:/usr/bin:/bin
want "cwd=$root/steamrtarm64"
want "arg=-gamepadui"
want "arg=a b"
want "arg=steam://open/x"
want "LD_LIBRARY_PATH=$ld"
want "PATH=$path"
want "SYSTEM_LD_LIBRARY_PATH=$ld"
want "SYSTEM_PATH=$path"
want "FUSERMOUNT_PROG=/run/host/usr/bin/fusermount3"
want "SteamDeck=1"

stale=("$root/.crash" "$root/steam.pid" "$tmp/home/.steam/steam.pid" "$root/config/htmlcache/SingletonLock"
  "$root/config/htmlcache/SingletonCookie" "$root/config/htmlcache/SingletonSocket")
mkdir -p "$root/config/htmlcache" "$tmp/home/.steam"
touch "${stale[@]}" "$root/config/htmlcache/keep"
echo 999999999 > "$tmp/home/.steam/steam.pid"
HOME=$tmp/home "$launcher" > /dev/null
for f in "${stale[@]}"; do [[ ! -e $f ]] || fail "stale ${f#"$tmp"/} kept"; done
[[ -e $root/config/htmlcache/keep ]] || fail "htmlcache content removed"

mkdir -p "$tmp/bin" "$tmp/direct"
{ echo '#!/bin/bash'; tail -n +2 "$launcher"; } > "$tmp/direct/steam"
chmod 755 "$tmp/direct/steam"
for how in bash direct; do
  touch "${stale[@]}"
  if [[ $how == bash ]]; then
    HOME=$tmp/home /bin/bash "$launcher" > /dev/null
  else
    HOME=$tmp/home "$tmp/direct/steam" > /dev/null
  fi
  for f in "${stale[@]}"; do [[ ! -e $f ]] || fail "$how: stale ${f#"$tmp"/} kept"; done
done

cp "$(command -v sleep)" "$tmp/bin/steam"
"$tmp/bin/steam" 30 &
running=$!
touch "${stale[@]}"
echo "$running" > "$tmp/home/.steam/steam.pid"
HOME=$tmp/home "$launcher" -ifrunning steam://open/x > /dev/null
for f in "${stale[@]}"; do [[ -e $f ]] || fail "${f#"$tmp"/} removed while Steam runs"; done
rm "$tmp/home/.steam/steam.pid"
echo "$running" > "$root/steam.pid"
HOME=$tmp/home "$launcher" -ifrunning steam://open/x > /dev/null
for f in "${stale[@]}"; do
  [[ $f == "$tmp/home/.steam/steam.pid" || -e $f ]] || fail "${f#"$tmp"/} removed while Steam runs with the pid only in Steam/steam.pid"
done
kill "$running"
wait "$running" 2> /dev/null || true

out=$(HOME=$tmp/home env -u LD_LIBRARY_PATH "$launcher")
grep -qxF "LD_LIBRARY_PATH=$root/steamrtarm64:$root/lib/aarch64-linux-gnu" <<<"$out" || fail "unset LD_LIBRARY_PATH: $out"

chmod 644 "$root/steamrtarm64/steam"
code=0
HOME=$tmp/home "$launcher" 2>/dev/null || code=$?
(( code == 127 )) || fail "non executable client exits $code, expected 127"

exit "$rc"
