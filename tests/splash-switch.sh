#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
script=$tree/usr/libexec/microos/microos-splash-switch
unit=$tree/usr/lib/systemd/system/microos-splash-switch.service
tmp=$(mktemp -d)
ticker=""
trap '[[ -z $ticker ]] || kill "$ticker" 2> /dev/null; rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

[[ -x $script ]] || fail "${script#"$tree"} is not executable"

root=$tmp/root
run=$root/run/microos
clients=$root/sys/kernel/debug/dri/0/clients
export STUB_DIR=$tmp/stub STUB_LOG=$tmp/log MICROOS_SPLASH_ROOT=$root MICROOS_SPLASH_CLOCK=$tmp/clock
stubpath=$here/splash-switch:$PATH
echo 0 > "$tmp/skip"
tick() { awk -v s="$(< "$tmp/skip")" '{ printf "%.2f\n", $1 + s }' /proc/uptime > "$tmp/clock.new" && mv -f "$tmp/clock.new" "$tmp/clock" 2> /dev/null; }
tick
while :; do tick; sleep 0.02; done &
ticker=$!
skip() { echo "$1" > "$tmp/skip"; }

wrap='import os, runpy, sys
fd = os.open(os.environ["STUB_LOG"], os.O_WRONLY | os.O_APPEND)
skip = (os.environ["MICROOS_SPLASH_CLOCK"], os.environ["MICROOS_SPLASH_ROOT"] + "/sys/kernel/debug/dri/0/clients")
def hook(event, args):
    if event == "open" and isinstance(args[0], str) and args[0] not in skip:
        os.write(fd, f"open {args[0]}\n".encode())
sys.addaudithook(hook)
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")'

row() { printf '%20s %5d %3d   %c    %c %5d %10u %*s %20llu\n' "$1" "$2" 0 "$3" y 0 0 64 '<unset>' "$4"; }
table() {
  local t=$tmp/clients.new
  printf '%20s %5s %3s master a %5s %10s %*s %20s\n' command tgid dev uid magic 64 name id > "$t"
  while (($#)); do
    row "$1" "$2" "$3" "$4" >> "$t"
    shift 4
  done
  mv -f "$t" "$clients"
}
urow() { printf '%20s %5d %3d   %c    %c %5d %10u %*s %20llu\n' "$1" "$2" 128 "$3" y "$4" 0 64 '<unset>' "$5" >> "$clients"; }
reset() {
  rm -rf "$root" "$STUB_DIR"
  mkdir -p "$run/user" "$root/sys/kernel/debug/dri/0" "$root/dev/dri" "$STUB_DIR"
  : > "$run/splash.lock"
  : > "$root/dev/dri/renderD128"
  : > "$STUB_LOG"
  : >> "$tmp/all"
  skip 0
  table
}
setup() {
  echo "$2" > "$run/splash-busy"
  echo "$1 $2 $3" > "$run/splash-target"
}
start() {
  PATH=$stubpath python3 -c "$wrap" "$script" "$@" > "$tmp/out" 2>&1 &
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
  ((r == 0)) || fail "$1: exit $r: $(cat "$tmp/out")"
  cat "$STUB_LOG" >> "$tmp/all"
  if [[ -e $STUB_DIR/plymouthd.pid ]] && kill -0 "$(< "$STUB_DIR/plymouthd.pid")" 2> /dev/null; then
    kill -9 "$(< "$STUB_DIR/plymouthd.pid")"
    fail "$1: plymouthd left running"
  fi
}
until_log() {
  local i
  for i in $(seq 200); do
    grep -qF -- "$1" "$STUB_LOG" && return 0
    sleep 0.05
  done
  fail "$2: no '$1' in the log: $(cat "$STUB_LOG")"
  return 1
}
line() { grep -nF -- "$1" "$STUB_LOG" | head -n 1 | cut -d: -f1; }
before() {
  local a b
  a=$(line "$1") b=$(line "$2")
  [[ -n $a && -n $b ]] && ((a < b)) || fail "$3: '$1' not before '$2': $(cat "$STUB_LOG")"
}
logged() { grep -qF -- "$1" "$tmp/out"; }
nolog() { ! grep -qF -- "$1" "$STUB_LOG"; }
busy() { cat "$run/splash-busy" 2> /dev/null || echo none; }

reset
table systemd-logind 585 y 77 steam 900 n 78
setup microdap 123 77
start
sleep 0.4
nolog "plymouthd --mode" || fail "happy: plymouthd started while the old master was on dri/0"
table steam 900 n 78
until_log "plymouth deactivate" happy
urow systemd-logind 4000 y 1000 89
sleep 0.3
nolog "plymouth quit" || fail "happy: quit before a new logind master, or on a uid 1000 systemd-logind row"
table systemd-logind 585 y 90
finish happy
before "open $root/dev/dri/renderD128" "plymouthd --mode=updates --no-daemon" happy
grep -qxF "plymouthd --mode=updates --no-daemon run=123 busy=123 lock=held" "$STUB_LOG" ||
  fail "happy: plymouthd start state: $(cat "$STUB_LOG")"
before "plymouthd --mode" "plymouth display-message --text=microos-session-microdap" happy
before "plymouth display-message --text=microos-session-microdap" "plymouth show-splash" happy
[[ $(grep -cxF "plymouth display-message --text=microos-session-microdap" "$STUB_LOG") == 2 ]] ||
  fail "happy: two messages: $(cat "$STUB_LOG")"
before "plymouth show-splash" "plymouth deactivate" happy
grep -qxF "quit busy=no lock=free hold=yes" "$STUB_LOG" || fail "happy: busy or lock at the quit: $(cat "$STUB_LOG")"
grep -qxF "plymouthd exit" "$STUB_LOG" || fail "happy: plymouthd did not quit: $(cat "$STUB_LOG")"
[[ $(busy) == none && $(< "$run/splash-run") == 123 ]] || fail "happy: busy $(busy), run $(cat "$run/splash-run")"
[[ $(stat -c %a "$run/splash-run") == 644 ]] || fail "happy: splash-run mode"
logged "showing microdap" || fail "happy not logged: $(cat "$tmp/out")"

reset
touch "$STUB_DIR/boot"
setup microemu 124 -
start
until_log "plymouth deactivate" "no recorded id"
table systemd-logind 585 y 91
finish "no recorded id"
grep -qF "plymouthd --mode=updates" "$STUB_LOG" || fail "no recorded id: no plymouthd: $(cat "$STUB_LOG")"
grep -qxF "systemctl stop --no-block microos-splash-quit.service" "$STUB_LOG" || fail "boot splash: quit unit not stopped"
before "systemctl stop --no-block microos-splash-quit.service" "plymouthd --mode" "boot splash"
grep -qxF "plymouth display-message --text=microos-session-microemu" "$STUB_LOG" || fail "no recorded id: message"
[[ $(busy) == none ]] || fail "no recorded id: busy $(busy)"

reset
table systemd-logind 585 y 77
setup steam 125 77
start
sleep 0.3
skip 61
finish "old id stays"
nolog "plymouthd --mode" || fail "old id stays: plymouthd started"
logged "DRM client 77 still on dri/0 after 60 s" || fail "old id stays not logged: $(cat "$tmp/out")"
[[ $(busy) == none ]] || fail "old id stays: busy $(busy)"

reset
table 'gamescope wl' 700 y 80
setup microdap 126 -
start
finish "other master"
nolog "plymouthd --mode" || fail "other master: plymouthd started"
logged "another DRM master on dri/0" || fail "other master not logged: $(cat "$tmp/out")"
[[ $(busy) == none ]] || fail "other master: busy $(busy)"

reset
setup microdap 127 -
touch "$run/user/splash-passed-127"
start
finish "passed mark"
nolog "plymouthd --mode" || fail "passed mark: plymouthd started"
logged "the session gate passed" || fail "passed mark not logged: $(cat "$tmp/out")"

reset
setup microdap 128 -
echo 999 > "$run/splash-busy"
start
finish "token at start"
nolog "plymouthd --mode" || fail "token at start: plymouthd started"
[[ $(busy) == 999 && $(< "$run/splash-run") == 128 ]] || fail "token at start: busy $(busy)"

reset
table systemd-logind 585 y 77
setup microdap 129 77
start
sleep 0.3
echo 456 > "$run/splash-busy"
table
finish "token at window"
nolog "plymouthd --mode" || fail "token at window: plymouthd started"
logged "splash-busy no longer holds 129" || fail "token at window not logged: $(cat "$tmp/out")"
[[ $(busy) == 456 ]] || fail "token at window: busy $(busy)"

reset
setup microdap 130 -
touch "$STUB_DIR/plymouthd-fails"
start
finish "plymouthd fails"
logged "plymouthd exited with 1" || fail "plymouthd fails not logged: $(cat "$tmp/out")"
nolog "plymouth show-splash" || fail "plymouthd fails: show-splash sent"
[[ $(busy) == none ]] || fail "plymouthd fails: busy $(busy)"

reset
setup microdap 131 -
touch "$STUB_DIR/hang" "$STUB_DIR/row"
start
until_log "plymouth show-splash" "show hangs"
for _ in $(seq 100); do
  kill -0 "$(< "$STUB_DIR/plymouthd.pid")" 2> /dev/null || break
  sleep 0.02
done
kill -0 "$(< "$STUB_DIR/plymouthd.pid")" 2> /dev/null && fail "show hangs: plymouthd not killed"
sleep 0.3
[[ $(busy) == 131 ]] || fail "show hangs: busy removed before the master row cleared"
table
finish "show hangs"
nolog "plymouthd exit" || fail "show hangs: plymouthd quit instead of SIGKILL"
logged "plymouth show-splash failed or passed 1 s" || fail "show hangs not logged: $(cat "$tmp/out")"
[[ $(busy) == none ]] || fail "show hangs: busy $(busy) after the row cleared"

reset
setup microdap 132 -
touch "$STUB_DIR/hang" "$STUB_DIR/row"
start
finish "row stays"
logged "plymouthd still holds DRM master 1 s after SIGKILL, keeping splash-busy" || fail "row stays not logged: $(cat "$tmp/out")"
[[ $(busy) == 132 && ! -e $run/splash-run ]] || fail "row stays: busy $(busy)"
start --cleanup
finish "row stays, cleanup"
[[ $(busy) == 132 ]] || fail "row stays: cleanup removed the kept busy file"

reset
touch "$STUB_DIR/boot" "$STUB_DIR/boot-stays"
setup microdap 133 -
start
finish "boot stays"
nolog "plymouthd --mode" || fail "boot stays: plymouthd started"
logged "the boot plymouthd still answers after 2 s" || fail "boot stays not logged: $(cat "$tmp/out")"
[[ $(busy) == none ]] || fail "boot stays: busy $(busy)"

reset
table systemd-logind 585 y 77
setup microdap 140 77
start
sleep 0.3
kill -TERM "$pid"
finish "term in release wait"
logged "stopped" || fail "term in release wait not logged: $(cat "$tmp/out")"
nolog "plymouthd --mode" || fail "term in release wait: plymouthd started"
[[ $(busy) == none ]] || fail "term in release wait: busy $(busy)"

reset
setup microdap 141 -
touch "$STUB_DIR/slow"
start
until_log "plymouthd --mode" "term before plymouthd answers"
sleep 0.2
[[ ! -e $STUB_DIR/plymouthd.pid ]] || fail "term before plymouthd answers: the stub was not slow"
kill -TERM "$pid"
finish "term before plymouthd answers"
logged "stopped" || fail "term before plymouthd answers not logged: $(cat "$tmp/out")"
nolog "plymouthd exit" || fail "term before plymouthd answers: plymouthd quit instead of SIGKILL"
nolog "plymouth display-message" || fail "term before plymouthd answers: message sent"
[[ $(busy) == none ]] || fail "term before plymouthd answers: busy $(busy)"
! kill -0 "$(< "$STUB_DIR/plymouthd.started")" 2> /dev/null || fail "term before plymouthd answers: plymouthd still runs"

reset
setup microdap 134 -
touch "$STUB_DIR/hang"
start
until_log "plymouth show-splash" "term in window"
kill -TERM "$pid"
finish "term in window"
logged "stopped" || fail "term in window not logged: $(cat "$tmp/out")"
nolog "plymouthd exit" || fail "term in window: plymouthd quit instead of SIGKILL"
[[ $(busy) == none ]] || fail "term in window: busy $(busy)"

reset
setup microdap 135 -
start
until_log "plymouth deactivate" "term after"
sleep 0.2
kill -TERM "$pid"
finish "term after"
logged "stopped" || fail "term after not logged: $(cat "$tmp/out")"
grep -qxF "plymouthd exit" "$STUB_LOG" || fail "term after: no retain quit: $(cat "$STUB_LOG")"
grep -qxF "plymouth quit --retain-splash" "$STUB_LOG" || fail "term after: $(cat "$STUB_LOG")"

reset
echo 456 > "$run/splash-busy"
echo 123 > "$run/splash-run"
start --cleanup
finish "cleanup, new token"
[[ $(busy) == 456 ]] || fail "cleanup removed the new token's busy file"
echo 123 > "$run/splash-busy"
start --cleanup
finish "cleanup, own token"
[[ $(busy) == none ]] || fail "cleanup left its own busy file"

reset
setup microdap 136 -
rm "$run/splash.lock"
start
finish "no lock file"
nolog "plymouthd --mode" || fail "no lock file: plymouthd started"

! grep -q 'plymouthd signal' "$tmp/all" || fail "plymouthd got a signal: $(grep 'plymouthd signal' "$tmp/all")"
! grep -q '^open .*card' "$tmp/all" || fail "a card node was opened: $(grep '^open .*card' "$tmp/all")"
grep -q "^open $root/dev/dri/renderD128$" "$tmp/all" || fail "the open hook recorded nothing"
! grep -qE 'date \+%s|EPOCHREALTIME|time\.time\(' "$script" || fail "wall clock in the script"

for l in Type=oneshot ExecStart=/usr/libexec/microos/microos-splash-switch \
  'ExecStopPost=/usr/libexec/microos/microos-splash-switch --cleanup' KillMode=mixed TimeoutStartSec=120 \
  TimeoutStopSec=3 Conflicts=shutdown.target \
  'Before=shutdown.target plymouth-reboot.service plymouth-poweroff.service plymouth-halt.service plymouth-kexec.service' \
  ProtectSystem=strict 'ReadWritePaths=/run/microos /run/plymouth' ProtectHome=yes PrivateTmp=yes NoNewPrivileges=yes \
  'RestrictAddressFamilies=AF_UNIX AF_NETLINK' 'CapabilityBoundingSet=CAP_SYS_ADMIN CAP_SYS_TTY_CONFIG CAP_DAC_OVERRIDE' \
  ProtectKernelModules=yes ProtectKernelLogs=yes ProtectControlGroups=yes RestrictNamespaces=yes LockPersonality=yes \
  RestrictRealtime=yes SystemCallArchitectures=native; do
  grep -qxF "$l" "$unit" || fail "unit lacks $l"
done
! grep -qE '^\[Install\]|^ProtectKernelTunables=|^PrivateDevices=' "$unit" || fail "unit has [Install], ProtectKernelTunables or PrivateDevices"

if ((rc == 0)); then
  echo "splash-switch: ok"
fi
exit "$rc"
