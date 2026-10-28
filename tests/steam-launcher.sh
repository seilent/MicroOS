#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
real=$tree/usr/bin/steam
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

grep -qxF '    m=$(timeout -k 1 3 /usr/libexec/microos/microos-steam-compat "$mode") || m=""' "$real" \
  || fail "launcher does not run the compat helper under timeout"
launcher=$tmp/steam
sed "s|/usr/libexec/microos/microos-steam-compat|$tmp/helper|" "$real" > "$launcher"
sed 's|flock -w 10 9|flock -w 1 9|' "$launcher" > "$tmp/steam-short"
chmod 755 "$launcher" "$tmp/steam-short"
grep -q "$tmp/helper" "$launcher" || fail "helper path not rewritten in the launcher copy"
grep -q 'flock -w 1 9' "$tmp/steam-short" || fail "lock wait not rewritten in the launcher copy"
cat > "$tmp/helper" <<'STUB'
#!/usr/bin/env bash
echo "start $1" >> "$HELPER_LOG"
[[ -z ${HELPER_SLEEP:-} ]] || sleep "$HELPER_SLEEP"
echo "end $1" >> "$HELPER_LOG"
[[ ! -f ${HELPER_OUT:-} ]] || cat "$HELPER_OUT"
exit "${HELPER_RC:-0}"
STUB
chmod 755 "$tmp/helper"
export HELPER_LOG=$tmp/helper.log HELPER_OUT=$tmp/helper.out
mkdir -p "$tmp/run"
export XDG_RUNTIME_DIR=$tmp/run
unset STEAM_COMPAT_TOOL_MAPPINGS HELPER_SLEEP HELPER_RC

root=$tmp/home/.local/share/Steam
mkdir -p "$root/steamrtarm64"
cat > "$root/steamrtarm64/steam" <<'STUB'
#!/usr/bin/env bash
printf 'cwd=%s\n' "$PWD"
printf 'arg=%s\n' "$@"
env | grep -E '^(PATH|LD_LIBRARY_PATH|SYSTEM_PATH|SYSTEM_LD_LIBRARY_PATH|FUSERMOUNT_PROG|SteamDeck|STEAM_COMPAT_TOOL_MAPPINGS)=' | sort
if [[ -e /proc/self/fd/9 ]]; then echo fd9=open; fi
STUB
chmod 755 "$root/steamrtarm64/steam"
ticks() { local u _; read -r u _ < /proc/uptime; echo "${u/./}"; }

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
grep -q '^STEAM_COMPAT_TOOL_MAPPINGS=' <<<"$out" && fail "empty helper output exported: $out"
[[ $(< "$HELPER_LOG") == $'start start\nend start' ]] || fail "helper calls: $(cat "$HELPER_LOG")"
start_env=$(grep -v '^arg=' <<<"$out")

for a in -ifrunning -shutdown; do
  : > "$HELPER_LOG"
  rm -f "$tmp/run/microos-steam.lock"
  echo "1 250 proton_11-arm64" > "$HELPER_OUT"
  out=$(cd / && HOME=$tmp/home PATH=/usr/bin:/bin LD_LIBRARY_PATH=/opt/x "$launcher" "$a" steam://open/x)
  [[ $(grep -v '^arg=' <<<"$out") == "$start_env" ]] || fail "$a env or cwd differs from the start path: $out"
  grep -qxF "arg=$a" <<<"$out" || fail "$a not passed on: $out"
  [[ ! -s $HELPER_LOG ]] || fail "$a ran the helper: $(cat "$HELPER_LOG")"
  [[ ! -e $tmp/run/microos-steam.lock ]] || fail "$a took the lock"
done

run() {
  : > "$HELPER_LOG"
  r=0
  out=$(HOME=$tmp/home "$@" 2> "$tmp/err") || r=$?
}
mapped() { grep -x "STEAM_COMPAT_TOOL_MAPPINGS=.*" <<<"$out" | cut -d= -f2-; }

v="3000001 250 proton_11-arm64,3000002 250 proton_11-arm64"
echo "$v" > "$HELPER_OUT"
run "$launcher"
[[ $r == 0 && $(mapped) == "$v" ]] || fail "value not in the client env: $out"
[[ ! -s $tmp/err ]] || fail "stderr on a plain start: $(cat "$tmp/err")"
[[ -e $tmp/run/microos-steam.lock ]] || fail "start path made no lock file"
grep -qx fd9=open <<<"$out" && fail "client holds the lock fd"

for bad in "abc" "1 250 proton_11-arm64,2 250 bad name" "1 251 x" "1 250 x," "1 250 x;rm" $'1 250 x\n2 250 y'; do
  printf '%s' "$bad" > "$HELPER_OUT"
  run "$launcher"
  [[ $r == 0 && -z $(mapped) ]] || fail "malformed '$bad' exported: $out"
  grep -qxF 'steam: compat mappings from the helper refused' "$tmp/err" || fail "malformed '$bad': stderr $(cat "$tmp/err")"
done

echo "$v" > "$HELPER_OUT"
run env HELPER_RC=1 "$launcher"
[[ $r == 0 && -z $(mapped) ]] || fail "failing helper output exported: $out"
grep -q '^cwd=' <<<"$out" || fail "client not started with a failing helper"

t0=$(ticks)
run env HELPER_SLEEP=30 "$launcher"
t1=$(ticks)
[[ $r == 0 && -z $(mapped) ]] || fail "sleeping helper: rc $r, $out"
grep -q '^cwd=' <<<"$out" || fail "client not started after a sleeping helper"
(( t1 - t0 < 600 )) || fail "sleeping helper held the start for $(( (t1 - t0) / 100 )) s"
(( t1 - t0 >= 250 )) || fail "sleeping helper ended after $(( t1 - t0 )) cs, before the bound"
[[ $(< "$HELPER_LOG") == "start start" ]] || fail "sleeping helper was not killed: $(cat "$HELPER_LOG")"

run env STEAM_COMPAT_TOOL_MAPPINGS="3000002 250 mine, 7 250 other" "$launcher"
[[ $(mapped) == "3000002 250 mine, 7 250 other,3000001 250 proton_11-arm64" ]] || fail "inherited merge: $out"
: > "$HELPER_OUT"
run env STEAM_COMPAT_TOOL_MAPPINGS="7 250 other" "$launcher"
[[ $(mapped) == "7 250 other" ]] || fail "inherited value with an empty helper output: $out"

big=$(for i in $(seq 1000000 1005000); do printf '%s 250 proton_11-arm64,' "$i"; done)
printf '%s' "${big%,}" > "$HELPER_OUT"
run "$launcher"
[[ $r == 0 && -z $(mapped) ]] || fail "over long value exported: ${#out} bytes"
grep -qF 'over the environment string limit' "$tmp/err" || fail "over long value: stderr $(cat "$tmp/err")"

echo "$v" > "$HELPER_OUT"
for how in nodir unset; do
  if [[ $how == nodir ]]; then
    run env XDG_RUNTIME_DIR="$tmp/missing" "$launcher"
    [[ $(< "$tmp/err") == "steam: $tmp/missing/microos-steam.lock not taken, going on without it" ]] \
      || fail "lock in a missing dir: stderr $(cat "$tmp/err")"
  else
    run env -u XDG_RUNTIME_DIR "$launcher"
  fi
  [[ $r == 0 && $(mapped) == "$v" ]] || fail "lock $how: rc $r, $out"
done

lockf=$tmp/run/microos-steam.lock
flock -o "$lockf" sleep 6 &
bg+=($!)
holder=$!
for _ in {1..50}; do flock -n "$lockf" true 2> /dev/null || break; sleep 0.1; done
t0=$(ticks)
run "$tmp/steam-short"
t1=$(ticks)
[[ $r == 0 && $(mapped) == "$v" ]] || fail "lock held: rc $r, $out"
[[ $(< "$tmp/err") == "steam: $lockf not taken, going on without it" ]] || fail "lock held: stderr $(cat "$tmp/err")"
(( t1 - t0 >= 90 && t1 - t0 < 500 )) || fail "lock held: start took $(( t1 - t0 )) cs"
kill "$holder" 2> /dev/null || true
wait "$holder" 2> /dev/null || true

: > "$HELPER_LOG"
HOME=$tmp/home HELPER_SLEEP=1 "$launcher" > "$tmp/out1" 2>&1 &
bg+=($!)
one=$!
HOME=$tmp/home HELPER_SLEEP=1 "$launcher" > "$tmp/out2" 2>&1 &
bg+=($!)
two=$!
wait "$one" "$two"
[[ $(< "$HELPER_LOG") == $'start start\nend start\nstart start\nend start' || $(< "$HELPER_LOG") == $'start start\nend start\nstart forward\nend forward' ]] \
  || fail "two launchers did not take turns: $(cat "$HELPER_LOG")"
grep -qxF "STEAM_COMPAT_TOOL_MAPPINGS=$v" "$tmp/out1" && grep -qxF "STEAM_COMPAT_TOOL_MAPPINGS=$v" "$tmp/out2" \
  || fail "two launchers: value missing in $(cat "$tmp/out1" "$tmp/out2")"

stale=("$root/.crash" "$root/steam.pid" "$tmp/home/.steam/steam.pid" "$root/config/htmlcache/SingletonLock"
  "$root/config/htmlcache/SingletonCookie" "$root/config/htmlcache/SingletonSocket")
mkdir -p "$root/config/htmlcache" "$tmp/home/.steam"
touch "${stale[@]}" "$root/config/htmlcache/keep"
echo 999999999 > "$tmp/home/.steam/steam.pid"
run "$launcher"
for f in "${stale[@]}"; do [[ ! -e $f ]] || fail "stale ${f#"$tmp"/} kept"; done
[[ -e $root/config/htmlcache/keep ]] || fail "htmlcache content removed"

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
  [[ $(mapped) == "$v" ]] || fail "$how: value not in the client env: $out"
  [[ $(< "$HELPER_LOG") == $'start start\nend start' ]] || fail "$how: helper calls $(cat "$HELPER_LOG")"
done

cp "$(command -v sleep)" "$tmp/bin/steam"
"$tmp/bin/steam" 30 &
bg+=($!)
running=$!
touch "${stale[@]}"
echo "$running" > "$tmp/home/.steam/steam.pid"
run "$launcher" steam://open/x
for f in "${stale[@]}"; do [[ -e $f ]] || fail "${f#"$tmp"/} removed while Steam runs"; done
[[ $(< "$HELPER_LOG") == $'start forward\nend forward' ]] || fail "helper with a running client: $(cat "$HELPER_LOG")"
[[ $(mapped) == "$v" ]] || fail "value not exported with a running client: $out"
rm "$tmp/home/.steam/steam.pid"
echo "$running" > "$root/steam.pid"
run "$launcher" steam://open/x
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

if (( rc == 0 )); then
  echo "steam-launcher: ok"
fi
exit "$rc"
