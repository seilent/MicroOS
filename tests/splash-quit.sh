#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
script=$tree/usr/libexec/microos/microos-splash-quit
unit=$tree/usr/lib/systemd/system/microos-splash-quit.service
sddm=$tree/usr/lib/systemd/system/sddm.service.d/10-microos-splash.conf
quit=$tree/usr/lib/systemd/system/plymouth-quit.service.d/10-microos.conf
conf=$tree/etc/plymouth/plymouthd.conf
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

[[ -x $script ]] || fail "${script#"$tree"} is not executable"

root=$tmp/root
clients=$root/sys/kernel/debug/dri/0/clients
export STUB_DIR=$tmp/stub STUB_LOG=$tmp/log MICROOS_SPLASH_ROOT=$root MICROOS_SPLASH_POLL=0.01 MICROOS_SPLASH_WAIT=5
stubpath=$here/splash-quit:$PATH

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
reset() {
  rm -rf "$root" "$STUB_DIR"
  mkdir -p "$root/sys/kernel/debug/dri/0" "$root/proc" "$STUB_DIR"
  ln -s /proc/uptime "$root/proc/uptime"
  : > "$STUB_LOG"
}
set_uptime() {
  echo "$1 0.00" > "$root/proc/uptime.new"
  mv -f "$root/proc/uptime.new" "$root/proc/uptime"
}
run() {
  local r=0
  PATH=$stubpath bash "$script" > "$tmp/out" 2>&1 || r=$?
  return "$r"
}
quits() { grep -c '^plymouth quit' "$STUB_LOG" || true; }
retains() { grep -cx 'plymouth quit --retain-splash' "$STUB_LOG" || true; }
plain() { grep -cx 'plymouth quit' "$STUB_LOG" || true; }
kills() { grep -c '^pkill' "$STUB_LOG" || true; }
logged() { grep -qF "$1" "$tmp/out"; }
ms() { echo $((${EPOCHREALTIME/./} / 1000)); }

reset
table plymouthd 400 y 1
touch "$STUB_DIR/down"
run || fail "plymouthd down: exit $?"
[[ $(quits) == 0 ]] || fail "plymouthd down: quit called"
logged "plymouthd is not running" || fail "plymouthd down not logged: $(cat "$tmp/out")"

reset
table plymouthd 400 n 1 systemd-logind 585 y 2
run || fail "logind master: exit $?"
grep -qx 'plymouth quit --retain-splash' "$STUB_LOG" || fail "logind master: $(cat "$STUB_LOG")"
[[ $(quits) == 1 ]] || fail "logind master: $(quits) quits"
logged "systemd-logind holds DRM master on dri/0" || fail "logind master not logged: $(cat "$tmp/out")"

reset
table plymouthd 400 y 1 'gamescope wl' 900 y 3
(sleep 0.4; table plymouthd 400 n 1 'gamescope wl' 900 y 3 systemd-logind 585 y 4) &
writer=$!
t0=$(ms)
run || fail "master later: exit $?"
dt=$(($(ms) - t0))
wait "$writer"
((dt >= 300 && dt < 4000)) || fail "master later: quit after $dt ms"
[[ $(quits) == 1 ]] || fail "master later: $(quits) quits"
logged "systemd-logind holds" || fail "master later not logged: $(cat "$tmp/out")"

reset
table plymouthd 400 n 1 gamescope-wl 900 y 3 Xwayland 950 y 5
t0=$(ms)
MICROOS_SPLASH_WAIT=1 run || fail "backstop: exit $?"
dt=$(($(ms) - t0))
((dt >= 1000 && dt < 2500)) || fail "backstop: quit after $dt ms"
grep -qx 'plymouth quit --retain-splash' "$STUB_LOG" || fail "backstop: $(cat "$STUB_LOG")"
logged "no systemd-logind DRM master on dri/0 after 1 s" || fail "backstop not logged: $(cat "$tmp/out")"

reset
table plymouthd 400 y 1
set_uptime 100.00
MICROOS_SPLASH_WAIT=1 PATH=$stubpath bash "$script" > "$tmp/out" 2>&1 &
pid=$!
sleep 0.3
set_uptime 100.60
sleep 1.4
kill -0 "$pid" 2> /dev/null || fail "clock step: wait ended at 1.7 s wall time, 0.6 s uptime"
[[ $(quits) == 0 ]] || fail "clock step: quit before the bound"
set_uptime 101.01
r=0
wait "$pid" || r=$?
((r == 0)) || fail "clock step: exit $r"
[[ $(quits) == 1 ]] || fail "clock step: $(quits) quits"
logged "no systemd-logind DRM master on dri/0 after 1 s" || fail "clock step not logged: $(cat "$tmp/out")"

reset
MICROOS_SPLASH_WAIT=1 run || fail "no clients file: exit $?"
[[ $(quits) == 1 ]] || fail "no clients file: $(quits) quits"
logged "no systemd-logind DRM master" || fail "no clients file not logged: $(cat "$tmp/out")"

reset
table plymouthd 400 y 1
rm "$root/proc/uptime"
run || fail "no uptime: exit $?"
[[ $(quits) == 1 ]] || fail "no uptime: $(quits) quits"
logged "cannot read $root/proc/uptime" || fail "no uptime not logged: $(cat "$tmp/out")"

reset
table systemd-logind 585 y 2
echo 1 > "$STUB_DIR/retain-fails"
run || fail "retry: exit $?"
[[ $(retains) == 2 && $(plain) == 0 && $(kills) == 0 ]] || fail "retry: $(cat "$STUB_LOG")"
logged "plymouth quit --retain-splash failed, trying again" || fail "retry not logged: $(cat "$tmp/out")"

reset
table systemd-logind 585 y 2
echo 2 > "$STUB_DIR/retain-fails"
if run; then fail "plain quit: exit 0"; fi
[[ $(retains) == 2 && $(plain) == 1 && $(kills) == 0 ]] || fail "plain quit: $(cat "$STUB_LOG")"
logged "failed again, quitting without the splash" || fail "plain quit not logged: $(cat "$tmp/out")"

reset
table systemd-logind 585 y 2
echo 2 > "$STUB_DIR/retain-fails"
touch "$STUB_DIR/quit-fails"
if run; then fail "sigterm: exit 0"; fi
[[ $(retains) == 2 && $(plain) == 1 ]] || fail "sigterm: $(cat "$STUB_LOG")"
grep -qx 'pkill -TERM -x plymouthd' "$STUB_LOG" || fail "sigterm: $(cat "$STUB_LOG")"
logged "plymouth quit failed, sending SIGTERM to plymouthd" || fail "sigterm not logged: $(cat "$tmp/out")"
! logged "no plymouthd to signal" || fail "sigterm: $(cat "$tmp/out")"

reset
table systemd-logind 585 y 2
echo 2 > "$STUB_DIR/retain-fails"
touch "$STUB_DIR/quit-fails" "$STUB_DIR/gone"
if run; then fail "plymouthd gone: exit 0"; fi
logged "no plymouthd to signal" || fail "plymouthd gone not logged: $(cat "$tmp/out")"

for l in After=display-manager.service WantedBy=display-manager.service Type=oneshot \
  ExecStart=/usr/libexec/microos/microos-splash-quit RestrictAddressFamilies=AF_UNIX ProtectSystem=strict; do
  grep -qxF "$l" "$unit" || fail "unit lacks $l"
done
! grep -q '^PrivateNetwork=' "$unit" || fail "unit sets PrivateNetwork, plymouthd is on an abstract socket"
[[ $(< "$sddm") == "[Service]"$'\n'"ExecStartPre=-/bin/sh -c '/usr/bin/plymouth deactivate || /usr/bin/plymouth quit'" ]] ||
  fail "sddm drop-in: $(< "$sddm")"
[[ $(< "$quit") == "[Service]"$'\n'"ExecStart="$'\n'"ExecStart=-/bin/sh -c '/usr/bin/plymouth deactivate || /usr/bin/plymouth quit'" ]] ||
  fail "plymouth-quit drop-in: $(< "$quit")"
[[ $(< "$conf") == $'[Daemon]\nTheme=microos\nShowDelay=0\nDeviceScale=1' ]] || fail "plymouthd.conf: $(< "$conf")"

if ((rc == 0)); then
  echo "splash-quit: ok"
fi
exit "$rc"
