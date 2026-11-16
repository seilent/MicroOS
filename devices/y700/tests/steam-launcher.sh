#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
launcher=$tree/usr/bin/steam
tmp=$(mktemp -d)
bg=()
cleanup() {
  local p
  for p in "${bg[@]}"; do kill "$p" 2> /dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

! grep -q 'microos-steam-compat' "$launcher" || fail "launcher still runs the compat helper"

root=$tmp/home/.local/share/Steam
mkdir -p "$root/steamrtarm64"
cat > "$root/steamrtarm64/steam" <<'STUB'
#!/usr/bin/env bash
printf 'cwd=%s\n' "$PWD"
printf 'arg=%s\n' "$@"
env | grep -E '^(PATH|LD_LIBRARY_PATH|SYSTEM_PATH|SYSTEM_LD_LIBRARY_PATH|FUSERMOUNT_PROG|SteamDeck)=' | sort
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
start_env=$(grep -v '^arg=' <<<"$out")

for a in -ifrunning -shutdown; do
  out=$(cd / && HOME=$tmp/home PATH=/usr/bin:/bin LD_LIBRARY_PATH=/opt/x "$launcher" "$a" steam://open/x)
  [[ $(grep -v '^arg=' <<<"$out") == "$start_env" ]] || fail "$a env or cwd differs from the start path: $out"
  grep -qxF "arg=$a" <<<"$out" || fail "$a not passed on: $out"
done

run() {
  r=0
  out=$(HOME=$tmp/home "$@" 2> "$tmp/err") || r=$?
}

stale=("$root/.crash" "$root/steam.pid" "$tmp/home/.steam/steam.pid" "$root/config/htmlcache/SingletonLock"
  "$root/config/htmlcache/SingletonCookie" "$root/config/htmlcache/SingletonSocket")
mkdir -p "$root/config/htmlcache" "$tmp/home/.steam"
touch "${stale[@]}" "$root/config/htmlcache/keep"
echo 999999999 > "$tmp/home/.steam/steam.pid"
run "$launcher"
[[ $r == 0 && ! -s $tmp/err ]] || fail "plain start: rc $r, stderr $(cat "$tmp/err")"
for f in "${stale[@]}"; do [[ ! -e $f ]] || fail "stale ${f#"$tmp"/} kept"; done
[[ -e $root/config/htmlcache/keep ]] || fail "htmlcache content removed"

for a in -ifrunning -shutdown; do
  touch "${stale[@]}"
  run "$launcher" "$a"
  for f in "${stale[@]}"; do [[ -e $f ]] || fail "$a removed ${f#"$tmp"/}"; done
done

mkdir -p "$tmp/bin" "$tmp/direct"
{ echo '#!/bin/bash'; tail -n +2 "$launcher"; } > "$tmp/direct/steam"
chmod 755 "$tmp/direct/steam"
for how in bash direct; do
  touch "${stale[@]}"
  if [[ $how == bash ]]; then
    run /bin/bash "$launcher"
  else
    run "$tmp/direct/steam"
  fi
  for f in "${stale[@]}"; do [[ ! -e $f ]] || fail "$how: stale ${f#"$tmp"/} kept"; done
  grep -qxF "cwd=$root/steamrtarm64" <<<"$out" || fail "$how: client not started: $out"
done

cp "$(command -v sleep)" "$tmp/bin/steam"
"$tmp/bin/steam" 30 &
bg+=($!)
running=$!
touch "${stale[@]}"
echo "$running" > "$tmp/home/.steam/steam.pid"
run "$launcher" steam://open/x
for f in "${stale[@]}"; do [[ -e $f ]] || fail "${f#"$tmp"/} removed while Steam runs"; done
grep -qxF "arg=steam://open/x" <<<"$out" || fail "client not started with a running client: $out"
kill "$running"
wait "$running" 2> /dev/null || true

out=$(HOME=$tmp/home env -u LD_LIBRARY_PATH "$launcher")
grep -qxF "LD_LIBRARY_PATH=$root/steamrtarm64:$root/lib/aarch64-linux-gnu" <<<"$out" || fail "unset LD_LIBRARY_PATH: $out"

chmod 644 "$root/steamrtarm64/steam"
code=0
HOME=$tmp/home "$launcher" 2>/dev/null || code=$?
(( code == 127 )) || fail "non executable client exits $code, expected 127"

if (( rc == 0 )); then
  echo "steam-launcher: ok"
fi
exit "$rc"
