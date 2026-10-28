#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
gate=$tree/usr/libexec/microos/microos-splash-gate
dropin=$tree/usr/lib/systemd/user/gamescope-session-plus@.service.d/10-microos-track.conf
tmp=$(mktemp -d)
ticker=""
holder=""
trap '[[ -z $ticker ]] || { : > "$tmp/stop"; wait "$ticker" 2> /dev/null || true; }; [[ -z $holder ]] || kill "$holder" 2> /dev/null; rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

[[ -x $gate ]] || fail "${gate#"$tree"} is not executable"

root=$tmp/root
run=$root/run/microos
export STUB_DIR=$tmp/stub STUB_LOG=$tmp/log MICROOS_SPLASH_ROOT=$root MICROOS_SPLASH_CLOCK=$tmp/clock
stubpath=$here/splash-switch:$PATH
echo 0 > "$tmp/skip"
tick() { awk -v s="$(< "$tmp/skip")" '{ printf "%.2f\n", $1 + s }' /proc/uptime > "$tmp/clock.new" && mv -f "$tmp/clock.new" "$tmp/clock" 2> /dev/null; }
tick
until [[ -e $tmp/stop ]]; do tick; sleep 0.02; done &
ticker=$!
skip() { echo "$1" > "$tmp/skip"; }

reset() {
  [[ -z $holder ]] || { kill "$holder" 2> /dev/null; wait "$holder" 2> /dev/null || true; holder=""; }
  rm -rf "$root" "$STUB_DIR"
  mkdir -p "$run/user" "$STUB_DIR"
  : > "$run/splash.lock"
  : > "$STUB_LOG"
  skip 0
}
ms() { awk '{ printf "%d\n", $1 * 1000 }' /proc/uptime; }
start() {
  t0=$(ms)
  PATH=$stubpath python3 "$gate" > "$tmp/out" 2>&1 &
  pid=$!
}
finish() {
  local i
  r=0
  for i in $(seq 300); do
    kill -0 "$pid" 2> /dev/null || break
    sleep 0.05
  done
  if kill -0 "$pid" 2> /dev/null; then
    kill -9 "$pid"
    fail "$1: still running after 15 s"
  fi
  wait "$pid" || r=$?
  dt=$(($(ms) - t0))
  ((r == 0)) || fail "$1: exit $r: $(cat "$tmp/out")"
}
running() { kill -0 "$pid" 2> /dev/null; }
hold() {
  python3 -c 'import fcntl, os, sys, time
fcntl.flock(os.open(sys.argv[1], os.O_RDONLY), fcntl.LOCK_EX)
time.sleep(60)' "$run/splash.lock" &
  holder=$!
  sleep 0.2
}
logged() { grep -qF -- "$1" "$tmp/out"; }
marks() { (cd "$run/user" && ls -1 | paste -sd,); }

reset
start
finish "no busy file"
((dt < 1500)) || fail "no busy file: $dt ms"
[[ -z $(marks) ]] || fail "no busy file: marks $(marks)"

reset
echo 123 > "$run/splash-busy"
start
finish "stale busy"
((dt < 1500)) || fail "stale busy: $dt ms"
logged "splash-busy left by an inactive microos-splash-switch.service" || fail "stale busy not logged: $(cat "$tmp/out")"
[[ -z $(marks) ]] || fail "stale busy: marks $(marks)"

reset
echo failed > "$STUB_DIR/state"
echo 123 > "$run/splash-busy"
start
finish "failed unit"
((dt < 1500)) || fail "failed unit: $dt ms"

reset
echo deactivating > "$STUB_DIR/state"
echo 123 > "$run/splash-busy"
start
sleep 0.6
running || fail "deactivating: passed with the unit deactivating"
rm "$run/splash-busy"
finish "deactivating"
((dt >= 500 && dt < 3000)) || fail "deactivating: $dt ms"
[[ -z $(marks) ]] || fail "deactivating: marks $(marks)"

reset
echo 4242 > "$STUB_DIR/job"
echo 123 > "$run/splash-busy"
start
sleep 0.6
running || fail "queued job: passed with a queued start job"
rm "$run/splash-busy"
finish "queued job"
((dt >= 500)) || fail "queued job: $dt ms"

reset
echo activating > "$STUB_DIR/state"
echo 123 > "$run/splash-busy"
start
sleep 0.6
running || fail "activating: passed early"
skip 3
sleep 0.4
running || fail "activating: passed before 5 s on the injected clock"
touch "$run/user/splash-passed-100"
hold
skip 6
sleep 0.4
running || fail "activating: passed with the lock held"
[[ ! -e $run/user/splash-passed-123 ]] || fail "activating: mark made with the lock held"
kill "$holder"
wait "$holder" 2> /dev/null || true
holder=""
finish "mark"
[[ $(marks) == splash-passed-123 ]] || fail "mark: marks $(marks)"
logged "splash still busy after 5 s, passed 123" || fail "mark not logged: $(cat "$tmp/out")"

reset
echo active > "$STUB_DIR/state"
echo 123 > "$run/splash-busy"
hold
start
sleep 0.3
skip 6
sleep 0.4
running || fail "lock held: passed before the lock wait"
skip 10
finish "lock held"
logged "splash lock busy after 3 s, passing" || fail "lock held not logged: $(cat "$tmp/out")"
[[ -z $(marks) ]] || fail "lock held: marks $(marks)"

reset
echo active > "$STUB_DIR/state"
echo '../x' > "$run/splash-busy"
start
sleep 0.3
skip 6
finish "bad token"
logged "splash-busy holds no token" || fail "bad token not logged: $(cat "$tmp/out")"
[[ -z $(marks) && ! -e $run/x ]] || fail "bad token: marks $(marks)"

reset
echo active > "$STUB_DIR/state"
echo 123 > "$run/splash-busy"
rm -r "$run/user"
start
sleep 0.3
skip 6
finish "no user dir"
logged "passing" || fail "no user dir not logged: $(cat "$tmp/out")"

! grep -qE 'date \+%s|EPOCHREALTIME|time\.time\(' "$gate" || fail "wall clock in the gate"
grep -qxF 'ExecStartPre=-/usr/libexec/microos/microos-splash-gate' "$dropin" || fail "the session drop-in lacks the gate"

if ((rc == 0)); then
  echo "splash-gate: ok"
fi
exit "$rc"
