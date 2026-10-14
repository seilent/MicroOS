#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
session=$tree/usr/bin/microos-session
libexec=$tree/usr/libexec/microos
units=$tree/usr/lib/systemd
tmp=$(mktemp -d)
ticker=""
trap '[[ -z $ticker ]] || kill "$ticker" 2> /dev/null; rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

for t in jq python3 flock setpriv timeout systemd-tmpfiles; do
  command -v "$t" > /dev/null || { echo "FAIL: $t missing" >&2; exit 1; }
done
[[ $(id -u) == 0 ]] || { echo "FAIL: runs as root" >&2; exit 1; }

chmod 0755 "$tmp"
root=$tmp/root
export MICROOS_ROOT=$root MICROOS_RUNDIR=$tmp/run MICROOS_STATEDIR=$tmp/state FAKE=$tmp/fake
export MICROOS_SESSION_BIN=$session TREE=$tree MICROOS_UPTIME=$tmp/uptime
export MICROOS_SESSION_SHORT_TRACKER=$tmp/short-tracker
export MICROOS_SESSION_STEP=0.1 MICROOS_SESSION_SHUTDOWN_WAIT=2 MICROOS_SESSION_STOP_WAIT=2 MICROOS_SESSION_GAMES_WAIT=1
export MICROOS_SESSION_RATE_MS=0 MICROOS_SESSION_SEAT_WAIT=1 MICROOS_SESSION_START_WAIT=2 MICROOS_SESSION_RESTART_WAIT=2 MICROOS_SESSION_WATCH_WAIT=2 MICROOS_SESSION_WATCH_PENDING=8
export PATH=$here/microos-session/bin:$PATH
tick() { awk '{ printf "%.2f 0\n", $1 + 100000 }' /proc/uptime > "$tmp/uptime.new" && mv -f "$tmp/uptime.new" "$tmp/uptime"; }
tick
while :; do tick; sleep 0.05; done &
ticker=$!
TRACK=$libexec/microos-session-track
export MICROOS_SYSFS=$tmp/sys MICROOS_DEV=$tmp/dev
mkpad() {
  local e=$1 base
  if [[ $2 == virtual ]]; then
    base=$MICROOS_SYSFS/devices/virtual/input/in-$e
  else
    base=$MICROOS_SYSFS/devices/platform/soc@0/a8f8800.usb/usb1/1-1/input/in-$e
  fi
  mkdir -p "$base/$e" "$base/id" "$MICROOS_SYSFS/class/input"
  echo "${3:-AYANEO Controller}" > "$base/name"
  echo 0003 > "$base/id/bustype"
  echo 4001 > "$base/id/vendor"
  echo "${4:-0428}" > "$base/id/product"
  ln -sfn .. "$base/$e/device"
  ln -sfn "$base/$e" "$MICROOS_SYSFS/class/input/$e"
}
nopads() { rm -rf "$MICROOS_SYSFS"; mkdir -p "$MICROOS_SYSFS/class/input"; }
run=$MICROOS_RUNDIR
state=$MICROOS_STATEDIR

sd=$root/usr/lib/microos/sessions.d
mkdir -p "$sd" "$root/usr/share/wayland-sessions" "$root/usr/lib/systemd/user"
cp "$tree/usr/lib/microos/sessions.d/steam.conf" "$tree/usr/lib/microos/sessions.d/recovery.conf" "$sd/"
printf 'LABEL="MicroDAP"\nDESKTOP=microdap.desktop\nUNIT=gamescope-session-plus@microdap.service\nSTOP=unit\nDEFAULT=yes\n' > "$sd/microdap.conf"
printf 'DESKTOP=missing.desktop\nUNIT=gamescope-session-plus@nodesk.service\nSTOP=unit\nDEFAULT=yes\n' > "$sd/nodesk.conf"
printf 'DESKTOP=microdap.desktop\nUNIT=nounit.service\nSTOP=unit\nDEFAULT=yes\n' > "$sd/nounit.conf"
printf 'DESKTOP=microdap.desktop\nUNIT=gamescope-session-plus@microdap.service\nSTOP=unit\nDEFAULT=yes\n' > "$sd/other.conf"
printf 'DESKTOP=../../../etc/x.desktop\nUNIT=gamescope-session-plus@path.service\nSTOP=unit\nDEFAULT=yes\n' > "$sd/path.conf"
printf 'DESKTOP=microdap.desktop\nUNIT=gamescope-session-plus@Bad.service\nSTOP=unit\nDEFAULT=yes\n' > "$sd/Bad.conf"
for d in gamescope-session-steam microos-recovery microdap; do
  echo '[Desktop Entry]' > "$root/usr/share/wayland-sessions/$d.desktop"
done
echo '[Service]' > "$root/usr/lib/systemd/user/gamescope-session-plus@.service"

unit_of() { echo "gamescope-session-plus@$1.service"; }
desk_of() {
  case $1 in
    steam) echo gamescope-session-steam.desktop ;;
    recovery) echo microos-recovery.desktop ;;
    *) echo "$1.desktop" ;;
  esac
}
mono() { python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC) // 1000)'; }
bt() { cut -d. -f1 "$tmp/uptime"; }
serial() { echo $(( $(bt) * 1000000 )); }
settle() {
  local _
  for _ in $(seq 600); do
    if [[ ! -e $run/session-pending ]] && flock -n "$FAKE/worker.lock" true 2> /dev/null; then
      local busy=0 l
      for l in "$FAKE"/request-*.lock; do
        [[ ! -e $l ]] || flock -n "$l" true || busy=1
      done
      (( busy )) || return 0
    fi
    sleep 0.1
  done
  return 1
}

reset() {
  [[ ! -d $FAKE ]] || settle || true
  rm -rf "$run" "$state" "$FAKE" "$tmp/victim" "$MICROOS_SESSION_SHORT_TRACKER"
  mkdir -p "$run/user" "$state/session" "$FAKE/units" "$FAKE/enter" "$FAKE/scopes" "$FAKE/desktops" "$FAKE/never" \
    "$FAKE/home/.steam"
  chmod 0755 "$run"
  for s in steam recovery microdap; do
    unit_of "$s" > "$FAKE/desktops/$(desk_of "$s")"
  done
  echo steam > "$FAKE/default"
  echo 1 > "$FAKE/seat-id"
  : > "$FAKE/calls"
  settle || true
  unset FAKE_STOP_DELAY FAKE_SHUTDOWN_DELAY FAKE_RUN_SWITCH MICROOS_PAD_STATE
  nopads
  mkpad event4 real
  mkdir -p "$FAKE/keys"
}
cur() {
  printf '%s %s %s\n' "$1" "$(unit_of "$1")" "${2:-$(serial)}" > "$run/session-current"
  printf '[Autologin]\nSession=%s\n' "$(desk_of "$1")" > "$run/sddm-autologin.conf"
  desk_of "$1" > "$FAKE/sddm-loaded"
  echo active > "$FAKE/units/$(unit_of "$1")"
  touch "$FAKE/sddm-up"
}
ustate() { cat "$FAKE/units/$(unit_of "$1")" 2> /dev/null || echo inactive; }
calls() { cat "$FAKE/calls" 2> /dev/null || true; }
has() { calls | grep -qxF -- "$1"; }
hasre() { calls | grep -qE -- "$1"; }
count() { calls | grep -cxF -- "$1" || true; }
line_of() { calls | grep -nF -- "$1" | head -n 1 | cut -d: -f1 || true; }
current() { cut -d' ' -f1 "$run/session-current"; }
login() { sed -n 's/^Session=//p' "$run/sddm-autologin.conf"; }
sw() { r=0; "$session" switch "$1" > "$tmp/out" 2>&1 || r=$?; }
reader() {
  mkfifo "$FAKE/home/.steam/steam.pipe"
  exec 4<> "$FAKE/home/.steam/steam.pipe"
}
noreader() { exec 4<&-; }
plant() {
  local p
  echo "${victim:-keep}" > "$tmp/victim"
  for p; do
    rm -f "$p"
    ln -s "$tmp/victim" "$p"
  done
}
planted_ok() {
  local p
  [[ $(< "$tmp/victim") == "${victim:-keep}" ]] || fail "$1: a planted link was followed"
  shift
  for p; do
    [[ ! -L $p ]] || fail "planted link $p still in place"
  done
}
status() {
  local e id fl i=0 sep=""
  {
    printf '{"deployments":['
    for e; do
      id=${e%% *}
      fl=${e#"$id"}
      printf '%s{"checksum":"%s","serial":%s,"index":%d,"booted":%s,"staged":%s}' "$sep" "${id%.*}" "${id##*.}" "$i" \
        "$([[ $fl == *b* ]] && echo true || echo false)" "$([[ $fl == *s* ]] && echo true || echo false)"
      sep=,
      i=$(( i + 1 ))
    done
    printf ']}\n'
  } > "$FAKE/status.json"
}
c64() { local s; s=$(printf '%064d' 0); echo "${s//0/$1}.0"; }
B=$(c64 b)
P=$(c64 a)

reset
out=$(MICROOS_ROOT=$root "$session" list)
[[ $out == $'microdap\tMicroDAP\tyes\nrecovery\tRecovery\tno\nsteam\tSteam\tyes' ]] || fail "list: $out"
[[ -z $(calls) ]] || fail "list called a tool: $(calls)"
rm "$root/usr/share/wayland-sessions/microdap.desktop"
[[ $("$session" list | cut -f1 | paste -sd,) == recovery,steam ]] || fail "list kept a session without its desktop file"
echo '[Desktop Entry]' > "$root/usr/share/wayland-sessions/microdap.desktop"
mv "$root/usr/lib/systemd/user/gamescope-session-plus@.service" "$tmp/gsp"
[[ -z $("$session" list) ]] || fail "list kept sessions without their unit file"
mv "$tmp/gsp" "$root/usr/lib/systemd/user/gamescope-session-plus@.service"

for d in nope ../steam recovery nodesk "" Bad; do
  reset
  echo "$d" > "$FAKE/default"
  "$libexec/microos-session-boot" 2> "$tmp/out" || fail "boot exited non zero for default '$d'"
  [[ $(current) == steam && $(login) == gamescope-session-steam.desktop ]] || fail "default '$d' did not boot steam: $(cat "$run/session-current")"
  [[ $("$session" get-default) == steam ]] || fail "get-default for '$d'"
done
reset
touch "$FAKE/microset-down"
"$libexec/microos-session-boot" 2> /dev/null
[[ $(current) == steam ]] || fail "microsetd down did not boot steam"
reset
echo microdap > "$FAKE/default"
status "$B b" "$P"
echo "$P" > "$state/confirmed"
"$libexec/microos-session-boot" 2> /dev/null
read -r n u s < "$run/session-current"
[[ $n == microdap && $u == gamescope-session-plus@microdap.service && $s =~ ^[0-9]+$ ]] && (( s / 1000000 >= 100000 )) || fail "boot session-current: $n $u $s"
[[ $(login) == microdap.desktop ]] || fail "boot autologin: $(login)"
[[ $(< "$run/sddm-autologin.conf") == $'[Autologin]\nSession=microdap.desktop' ]] || fail "autologin file: $(< "$run/sddm-autologin.conf")"
[[ $(< "$run/deployments") == "booted=$B"$'\nconfirmed=no\nrollback=yes' ]] || fail "deployments: $(< "$run/deployments")"
[[ $(< "$state/session/attempt") == $'name=microdap\ncount=1\nfallback=0\ntarget=microdap' ]] || fail "first attempt: $(< "$state/session/attempt")"
[[ $(stat -c %a "$run/session-current") == 644 ]] || fail "session-current mode"
"$libexec/microos-session-boot" 2> /dev/null
[[ $(< "$state/session/attempt") == $'name=microdap\ncount=2\nfallback=0\ntarget=microdap' ]] || fail "second attempt: $(< "$state/session/attempt")"
"$libexec/microos-session-boot" 2> "$tmp/out"
[[ $(current) == steam ]] || fail "attempt count 2 did not boot the fallback"
[[ $(< "$state/session/attempt") == $'name=microdap\ncount=2\nfallback=1\ntarget=steam' ]] || fail "fallback boot attempt: $(< "$state/session/attempt")"
grep -q "the default stays microdap" "$tmp/out" || fail "fallback boot line: $(cat "$tmp/out")"
! hasre '^microset set' || fail "the fallback boot wrote the default"
"$libexec/microos-session-boot" 2> /dev/null
[[ $(current) == steam && $(< "$state/session/attempt") == $'name=microdap\ncount=2\nfallback=2\ntarget=steam' ]] ||
  fail "second fallback boot: $(current) $(< "$state/session/attempt")"
"$libexec/microos-session-boot" 2> "$tmp/out"
[[ $(current) == recovery ]] || fail "two failed fallback boots did not boot recovery: $(current)"
grep -q "microdap and steam did not come up" "$tmp/out" || fail "recovery boot line: $(cat "$tmp/out")"
echo "$B" > "$state/confirmed"
status "$B b"
printf 'name=steam\ncount=7\n' > "$state/session/attempt"
"$libexec/microos-session-boot" 2> /dev/null
[[ $(current) == microdap && $(< "$state/session/attempt") == $'name=microdap\ncount=1\nfallback=0\ntarget=microdap' ]] || fail "attempt of another session"
[[ $(< "$run/deployments") == "booted=$B"$'\nconfirmed=yes\nrollback=no' ]] || fail "confirmed deployments: $(< "$run/deployments")"
reset
printf 'name=steam\ncount=2\n' > "$state/session/attempt"
"$libexec/microos-session-boot" 2> /dev/null
[[ $(current) == recovery ]] || fail "steam default with count 2 did not boot recovery"
reset
plant "$run/deployments" "$run/sddm-autologin.conf" "$run/session-current" "$state/session/attempt" "$run/.session-current.planted"
"$libexec/microos-session-boot" 2> /dev/null
planted_ok "boot" "$run/deployments" "$run/sddm-autologin.conf" "$run/session-current" "$state/session/attempt"

reset
printf 'name=steam\ncount=1\n' > "$state/session/attempt"
systemctl _shutdown microos-session-attempt.service
[[ ! -e $state/session/attempt ]] || fail "a clean shutdown left the attempt"
touch "$run/switching"
systemctl _stop microos-session-switcher.service
[[ ! -e $run/switching ]] || fail "a stopped switcher left switching"

reset
cur steam
reader
printf 'name=steam\ncount=1\n' > "$state/session/attempt"
touch "$FAKE/scopes/app-steam-app570-1.scope"
prev=$(< "$run/session-current")
sw microdap
[[ $(< "$run/session-previous") == "$prev requested" ]] || fail "session-previous: $(cat "$run/session-previous" 2> /dev/null)"
[[ $(stat -c %a "$run/session-previous") == 644 ]] || fail "session-previous mode"
[[ $r == 0 ]] || fail "switch to microdap: $r $(cat "$tmp/out")"
has "steam -shutdown current=microdap login=microdap.desktop switching=yes attempt=no" ||
  fail "files not written before the source stop: $(calls)"
! hasre '^user stop gamescope-session-plus@steam' || fail "steam unit stopped although -shutdown ended it"
[[ $(current) == microdap && $(ustate microdap) == active && $(ustate steam) == inactive ]] || fail "switch end state"
[[ $(< "$run/session-wanted") == "microdap requested root" ]] || fail "session-wanted"
[[ ! -e $run/session-pending ]] || fail "session-pending left behind"
[[ ! -e $run/switching ]] || fail "switching left behind"
a=$(line_of "steam -shutdown")
g=$(line_of "user stop --no-block app-steam-app570-1.scope")
[[ -n $a && -n $g ]] && (( a < g )) || fail "game scope not stopped after the source: $(calls)"
has "busctl set-property org.shadowblip.InputPlumber /org/shadowblip/InputPlumber/CompositeDevice0 org.shadowblip.Input.CompositeDevice InterceptMode u 0" ||
  fail "InterceptMode 0 not set"
has "busctl set-property org.shadowblip.InputPlumber /org/shadowblip/InputPlumber/CompositeDevice1 org.shadowblip.Input.CompositeDevice InterceptMode u 0" ||
  fail "InterceptMode 0 not set on the second device"
! hasre '^restart' || fail "sddm restarted on a clean switch"
grep -q -- '--reuid=1000' "$FAKE/setpriv.log" || fail "user commands not run as uid 1000"
[[ ! -e $run/user/track/steam ]] || fail "the stop of the switch source was counted"
[[ $(stat -c %a "$run/lock") == 700 ]] || fail "lock dir mode $(stat -c %a "$run/lock")"
/usr/bin/setpriv --reuid=65534 --regid=65534 --clear-groups cat "$run/session-current" > /dev/null || fail "nobody cannot read session-current"
if /usr/bin/setpriv --reuid=65534 --regid=65534 --clear-groups bash -c "exec 9< '$run/lock/session.lock'" 2> /dev/null; then
  fail "a user process opened the switch lock"
fi
noreader

reset
cur steam
touch "$FAKE/home/.steam/steam.pipe"
touch "$FAKE/scopes/app-steam-app1.scope" "$FAKE/stubborn"
sw microdap
[[ $r == 0 ]] || fail "switch without pipe reader: $r"
! hasre '^steam' || fail "steam -shutdown ran without a pipe reader"
has "user stop gamescope-session-plus@steam.service" || fail "steam unit not stopped"
has "user kill app-steam-app1.scope" || fail "stubborn game scope not killed"

reset
cur steam
sw steam
[[ $r == 0 && $(count "user stop gamescope-session-plus@steam.service") == 0 ]] || fail "switch to the active current session not a no op"
echo activating > "$FAKE/units/$(unit_of steam)"
sw steam
[[ $r == 0 ]] && ! hasre '^(user stop|steam|restart)' || fail "switch to the activating current session not a no op"
sw nope
[[ $r == 2 ]] || fail "unlisted switch exit $r"
sw ../steam
[[ $r == 2 ]] || fail "path switch exit $r"

reset
cur steam
touch "$FAKE/stale"
sw microdap
[[ $r == 0 ]] || fail "stale relogin switch: $r $(cat "$tmp/out")"
[[ $(count "restart sddm.service") == 1 && $(count "reset-failed sddm.service") == 1 ]] || fail "restart path: $(calls)"
a=$(line_of "reset-failed sddm.service")
g=$(line_of "restart sddm.service")
[[ -n $a && -n $g ]] && (( a < g )) || fail "reset-failed not before the restart"
[[ $(ustate microdap) == active && $(ustate steam) == inactive ]] || fail "stale relogin end state"
[[ ! -e $run/user/track/steam ]] || fail "the source restarted by a stale relogin was counted"

reset
cur steam
touch "$FAKE/never/$(unit_of microdap)"
sw microdap
[[ $(count "restart sddm.service") == 1 ]] || fail "failing target restarts: $(count "restart sddm.service")"
[[ $(current) == recovery && $(ustate recovery) == active ]] || fail "a target that never started did not go to recovery: $(current)"
[[ $(cut -d' ' -f1,4 "$run/session-previous") == "microdap fallback" ]] || fail "session-previous after the failed target"
! has "start --no-block microos-session-giveup.service" || fail "giveup after a recovery that started"
reset
cur steam
touch "$FAKE/never/$(unit_of microdap)" "$FAKE/never/$(unit_of recovery)"
sw microdap
[[ $(count "restart sddm.service") == 2 ]] || fail "failing target and recovery restarts: $(count "restart sddm.service")"
has "start --no-block microos-session-giveup.service" || fail "recovery that never started did not start the giveup"
[[ $(< "$run/session-failed") == "recovery $(cut -d' ' -f3 "$run/session-current")" ]] || fail "session-failed after the failed recovery"

reset
cur steam
export FAKE_RUN_SWITCH=1 FAKE_STOP_DELAY=1 MICROOS_SESSION_RATE_MS=5000
for n in microdap recovery steam recovery microdap recovery; do
  systemctl start --no-block "microos-session-switch@$n.service"
  sleep 1.5
done
settle || fail "six requests did not settle"
[[ $(current) == recovery && $(ustate recovery) == active ]] || fail "six requests ended on $(current)"
for s in steam microdap; do
  [[ $(ustate "$s") == inactive ]] || fail "six requests left $s $(ustate "$s")"
done
[[ $(count "restart sddm.service") == 0 ]] || fail "six requests restarted sddm $(count "restart sddm.service") times"
(( $(grep -c 'microos-session: switch from' "$FAKE/switch.log") <= 3 )) ||
  fail "six requests ran $(grep -c 'switch from' "$FAKE/switch.log") switches"
grep -q 'within 5000 ms of the last, held' "$FAKE/switch.log" || fail "six requests were not rate limited"
export MICROOS_SESSION_RATE_MS=0
unset FAKE_STOP_DELAY

reset
cur steam
export FAKE_RUN_SWITCH=1 FAKE_REQUEST_DELAY=1
systemctl start --no-block microos-session-switch@microdap.service
sleep 0.3
systemctl start --no-block microos-session-switch@microdap.service
sleep 0.3
has "merged microos-session-switch@microdap.service" || fail "the stub did not merge a running request"
unset FAKE_REQUEST_DELAY
settle
[[ $(current) == microdap ]] || fail "merged request lost: $(current)"

reset
cur steam
export FAKE_RUN_SWITCH=1 MICROOS_SESSION_RATE_MS=5000
plant "$run/switch-last"
t0=$(date +%s%N)
systemctl start --no-block microos-session-switch@microdap.service
sleep 0.3
systemctl start --no-block microos-session-fallback@steam.service
settle
t1=$(date +%s%N)
(( t1 - t0 >= 3000000000 )) && [[ $(current) == steam ]] || fail "a unit request within 5 s was not held: $(( (t1 - t0) / 1000000 )) ms $(current)"
planted_ok "switch-last" "$run/switch-last"
t0=$(date +%s%N)
"$session" switch microdap 2> /dev/null
"$session" switch steam 2> /dev/null
t1=$(date +%s%N)
(( t1 - t0 < 3000000000 )) && [[ $(current) == steam ]] || fail "root switches were rate limited"
export MICROOS_SESSION_RATE_MS=0

reset
cur steam
export FAKE_RUN_SWITCH=1 FAKE_STOP_DELAY=2
systemctl start --no-block microos-session-switch@microdap.service
sleep 0.5
systemctl start --no-block microos-session-fallback@steam.service
settle
[[ $(current) == steam && $(ustate steam) == active && $(ustate microdap) == inactive ]] || fail "the fallback was lost: $(current)"
unset FAKE_STOP_DELAY

reset
cur steam
victim=reset
cur steam
victim="steam gamescope-session-plus@steam.service 1"
plant "$run/session-wanted" "$run/switching" "$run/sddm-autologin.conf" "$run/session-current" "$state/session/attempt" \
  "$run/session-previous" "$run/session-pending" "$run/.session-current.planted" "$run/.switching.planted"
mkdir -p "$run/lock"
ln -s "$tmp/victim" "$run/lock/session.lock"
sw microdap
[[ $r == 0 ]] || fail "switch with planted links: $r $(cat "$tmp/out")"
planted_ok "switch" "$run/session-wanted" "$run/sddm-autologin.conf" "$run/session-current" "$run/session-previous"
[[ ! -e $run/switching && ! -L $run/switching ]] || fail "switching left behind"
unset victim

reset
echo microdap > "$FAKE/default"
cur microdap
"$TRACK" stop microdap 2> /dev/null
[[ $(wc -l < "$run/user/track/microdap") == 1 ]] || fail "first short run not counted"
[[ $(stat -c %a "$run/user/track") == 755 ]] || fail "track dir mode"
touch "$MICROOS_SESSION_SHORT_TRACKER"
EXIT_STATUS=1 "$TRACK" stop microdap 2> /dev/null
[[ ! -e $MICROOS_SESSION_SHORT_TRACKER ]] || fail "the launcher short session tracker was kept"
! hasre 'microos-session-(switch|fallback)' || fail "fallback after two runs"
touch "$FAKE/fail-blocking"
EXIT_STATUS=0 "$TRACK" stop microdap 2> /dev/null
has "start --no-block microos-session-fallback@steam.service" || fail "three short runs: $(calls)"
[[ $(count "start --no-block microos-session-fallback@steam.service") == 1 ]] || fail "fallback started more than once"
cur steam
"$TRACK" stop steam 2> /dev/null
"$TRACK" stop steam 2> /dev/null
"$TRACK" stop steam 2> /dev/null
has "start --no-block microos-session-fallback@recovery.service" || fail "the failing fallback did not reach recovery: $(calls)"
cur recovery
: > "$FAKE/calls"
for _ in 1 2 3; do "$TRACK" stop recovery 2> /dev/null; done
has "start --no-block microos-session-fallback@recovery.service" || fail "recovery failing did not start the fallback to recovery"
! hasre 'giveup' || fail "the tracker started the giveup itself"
rm -f "$FAKE/fail-blocking"
sw recovery
[[ $r == 0 ]] && ! hasre 'giveup' || fail "a requested switch to the current recovery started the giveup"
r=0
"$session" switch recovery fallback 2> /dev/null || r=$?
[[ $r == 0 ]] && has "start --no-block microos-session-giveup.service" || fail "the fallback to a failing recovery did not start the giveup"

reset
cur recovery $(( ($(bt) - 10) * 1000000 ))
export FAKE_RUN_SWITCH=1
systemctl start --no-block microos-session-fallback@recovery.service
settle
! has "start --no-block microos-session-giveup.service" || fail "a unit fallback to recovery started the giveup without root evidence"
now=$(date +%s)
: > "$FAKE/journal"
for _ in 1 2 3; do echo "$now.000000 pm2 systemd[4242]: Started" >> "$FAKE/journal"; done
systemctl start --no-block microos-session-fallback@recovery.service
settle
has "start --no-block microos-session-giveup.service" || fail "a unit fallback to recovery with 3 trusted starts did not start the giveup"
unset FAKE_RUN_SWITCH

reset
echo steam > "$FAKE/default"
cur steam
for _ in 1 2 3; do "$TRACK" stop steam 2> /dev/null; done
has "start --no-block microos-session-fallback@recovery.service" || fail "steam default failing did not go to recovery"

reset
echo microdap > "$FAKE/default"
cur microdap
now=$(bt)
mkdir -p "$run/user/track"
printf '%s\n%s\n' $(( now - 700 )) $(( now - 650 )) > "$run/user/track/microdap"
"$TRACK" stop microdap 2> /dev/null
[[ $(wc -l < "$run/user/track/microdap") == 1 ]] || fail "runs older than 600 s kept"
cur microdap $(( (now + 5) * 1000000 ))
printf '%s\n%s\n' "$now" "$now" > "$run/user/track/microdap"
"$TRACK" stop microdap 2> /dev/null
[[ $(wc -l < "$run/user/track/microdap") == 1 ]] || fail "runs before the current serial kept"

reset
cur steam
touch "$run/switching"
for _ in 1 2 3; do "$TRACK" stop steam 2> /dev/null; done
[[ ! -e $run/user/track/steam ]] && ! hasre 'microos-session-(switch|fallback)' || fail "a stop while switching was counted"
rm "$run/switching"
echo stopping > "$FAKE/system-state"
for _ in 1 2 3; do "$TRACK" stop steam 2> /dev/null; done
[[ ! -e $run/user/track/steam ]] || fail "a stop while the system is stopping was counted"
rm "$FAKE/system-state"
echo "steam $(cut -d' ' -f3 "$run/session-current") 0123456789abcdef0123456789abcdef" > "$run/session-up"
INVOCATION_ID=0123456789abcdef0123456789abcdef "$TRACK" stop steam 2> /dev/null
[[ ! -e $run/user/track/steam ]] || fail "a stop of a session that was up was counted"
"$TRACK" stop steam 2> /dev/null
[[ $(wc -l < "$run/user/track/steam" 2> /dev/null) == 1 ]] || fail "a stop without INVOCATION_ID skipped the count"
rm "$run/user/track/steam"
INVOCATION_ID=fedcba9876543210fedcba9876543210 "$TRACK" stop steam 2> /dev/null
[[ $(wc -l < "$run/user/track/steam" 2> /dev/null) == 1 ]] || fail "a later run of a session that was up skipped the count"
rm "$run/user/track/steam"
echo "steam 1 0123456789abcdef0123456789abcdef" > "$run/session-up"
INVOCATION_ID=0123456789abcdef0123456789abcdef "$TRACK" stop steam 2> /dev/null
[[ -e $run/user/track/steam ]] || fail "session-up of an older serial skipped the count"
cur microdap
"$TRACK" stop steam 2> /dev/null
[[ $(wc -l < "$run/user/track/steam") == 1 ]] || fail "a stop of a session that is not current was counted"

reset
cur steam
s=$(cut -d' ' -f3 "$run/session-current")
printf 'name=microdap\ncount=2\nfallback=1\ntarget=steam\n' > "$state/session/attempt"
echo $(( $(mono) - 30000000 )) > "$FAKE/enter/$(unit_of steam)"
r=0
"$session" up steam 2> /dev/null || r=$?
[[ $r == 1 && ! -e $run/session-up ]] || fail "up after 30 s accepted"
echo $(( $(mono) - 61000000 )) > "$FAKE/enter/$(unit_of steam)"
r=0
"$session" up microdap 2> /dev/null || r=$?
[[ $r == 1 && ! -e $run/session-up ]] || fail "up of a session that is not current accepted"
plant "$run/session-up"
"$session" up steam 2> /dev/null || fail "up after 61 s refused"
[[ $(< "$run/session-up") == "steam $s 0123456789abcdef0123456789abcdef" ]] || fail "session-up: $(< "$run/session-up")"
planted_ok "up" "$run/session-up"
[[ ! -e $state/session/attempt ]] || fail "up kept its attempt"
printf 'name=steam\ncount=1\nfallback=0\ntarget=microdap\n' > "$state/session/attempt"
"$session" up steam 2> /dev/null
[[ -e $state/session/attempt ]] || fail "up removed the attempt of another session"
echo inactive > "$FAKE/units/$(unit_of steam)"
rm -f "$FAKE/sddm-up"
r=0
"$session" up steam 2> /dev/null || r=$?
[[ $r == 1 ]] || fail "up of an inactive session accepted"

giveup() { r=0; "$libexec/microos-session-giveup" "$1" > "$tmp/out" 2>&1 || r=$?; }
starts() {
  local t
  : > "$FAKE/journal"
  for t; do echo "$t.000000 pm2 systemd[${pid:-4242}]: Started gamescope-session-plus@recovery.service." >> "$FAKE/journal"; done
}
reset
cur steam
status "$B b" "$P"
starts "$(date +%s)" "$(date +%s)" "$(date +%s)"
giveup giveup
[[ $r == 1 ]] && ! hasre '^(bootc|stop|reboot)' || fail "giveup while steam is current: $r $(calls)"
giveup rollback
[[ $r == 1 ]] && ! hasre '^bootc' || fail "rollback while steam is current: $r"
cur recovery $(( ($(bt) - 100) * 1000000 ))
echo "$P" > "$state/confirmed"
now=$(date +%s)
starts $(( now - 200 )) $(( now - 50 )) "$now"
giveup giveup
[[ $r == 1 ]] && ! hasre '^(bootc|stop)' || fail "giveup with 2 starts since the serial: $r $(calls)"
hasre "^journalctl .*_UID=1000 USER_UNIT=gamescope-session-plus@recovery.service MESSAGE_ID=39f53479d3a045ac8e11786248231fbf" ||
  fail "journal read: $(calls)"
pid=999 starts $(( now - 50 )) $(( now - 20 )) "$now"
giveup giveup
[[ $r == 1 ]] && ! hasre '^(bootc|stop)' || fail "giveup counted forged journal lines"
hasre "^journalctl .*_PID=4242 _UID=1000" || fail "journal read without the manager pid"
starts $(( now - 50 )) $(( now - 20 )) "$now"
touch "$FAKE/no-manager"
giveup giveup
[[ $r == 1 ]] || fail "giveup without a user manager pid"
rm "$FAKE/no-manager"
plant "$state/session/rollback-done" "$run/update.lock"
giveup giveup
[[ $r == 0 ]] && has "bootc rollback" && has reboot || fail "unconfirmed giveup: $r $(calls) $(cat "$tmp/out")"
a=$(line_of "bootc rollback")
g=$(line_of reboot)
[[ -n $a && -n $g ]] && (( a < g )) || fail "reboot before the rollback"
[[ $(< "$state/session/rollback-done") == "$B" ]] || fail "rollback-done marker"
planted_ok "giveup" "$state/session/rollback-done"
: > "$FAKE/calls"
giveup giveup
[[ $r == 0 ]] && ! has "bootc rollback" && has "stop display-manager.service" || fail "second giveup on the same deployment: $(calls)"
: > "$FAKE/calls"
giveup giveup
[[ $r == 0 ]] && ! has "stop display-manager.service" || fail "the display manager stopped twice in one boot"
rm -f "$run/giveup-stopped"
echo /etc/systemd/user/gamescope-session-plus@.service > "$FAKE/fragment"
giveup giveup
[[ $r == 1 ]] && ! has "stop display-manager.service" || fail "giveup accepted a recovery unit outside /usr/lib"
rm "$FAKE/fragment"
echo "/usr/lib/systemd/user/x.conf /var/home/micro/.config/systemd/user/gamescope-session-plus@.service.d/x.conf" > "$FAKE/dropins"
giveup giveup
[[ $r == 1 ]] && ! has "stop display-manager.service" || fail "giveup accepted a drop-in from the home"
rm "$FAKE/dropins"
reset
cur recovery $(( ($(bt) - 10) * 1000000 ))
echo "$B" > "$state/confirmed"
status "$B b" "$P"
now=$(date +%s)
starts "$now" "$now" "$now"
giveup giveup
[[ $r == 0 ]] && ! has "bootc rollback" && has "stop display-manager.service" || fail "confirmed giveup: $(calls)"
reset
cur recovery $(( ($(bt) - 10) * 1000000 ))
echo "$P" > "$state/confirmed"
status "$B b" "$P"
now=$(date +%s)
starts "$now" "$now" "$now"
touch "$FAKE/bootc-fails"
giveup giveup
[[ $r == 0 ]] && has "bootc rollback" && has "stop display-manager.service" && ! has reboot || fail "giveup after a failed rollback: $(calls)"
[[ ! -e $state/session/rollback-done ]] || fail "rollback-done written although bootc failed"
rm "$FAKE/bootc-fails" "$run/giveup-stopped"
: > "$FAKE/calls"
exec 7< "$run/update.lock"
flock 7
MICROOS_SESSION_UPDATE_WAIT=1 giveup giveup
exec 7<&-
[[ $r == 0 ]] && ! has "bootc rollback" && has "stop display-manager.service" || fail "giveup with update.lock busy: $(calls)"
[[ ! -e $state/session/rollback-done ]] || fail "rollback-done written with update.lock busy"
reset
cur recovery
status "$B b"
starts
echo "recovery $(cut -d' ' -f3 "$run/session-current")" > "$run/session-failed"
giveup giveup
[[ $r == 0 ]] && has "stop display-manager.service" || fail "giveup after the watch marker: $r $(calls)"
echo "recovery 1" > "$run/session-failed"
: > "$FAKE/calls"
giveup giveup
[[ $r == 1 ]] || fail "giveup accepted a watch marker of another serial"
reset
cur recovery
status "$B b"
giveup rollback
[[ $r == 1 ]] && ! hasre '^bootc' || fail "rollback without a rollback deployment"
status "$B b" "$P"
export MICROOS_PAD_STATE=$FAKE/keys
nopads
giveup rollback
[[ $r == 1 ]] && ! hasre '^bootc' && grep -q "no AYANEO Controller" "$tmp/out" || fail "rollback without a pad"
mkpad event9 virtual
echo BTN_SOUTH > "$FAKE/keys/event9"
giveup rollback
[[ $r == 1 ]] && ! hasre '^bootc' && grep -q "no AYANEO Controller" "$tmp/out" || fail "rollback accepted a virtual pad"
mkpad event5 real "AYANEO Controller" 0429
echo BTN_SOUTH > "$FAKE/keys/event5"
giveup rollback
[[ $r == 1 ]] && ! hasre '^bootc' || fail "rollback accepted a pad with other ids"
mkpad event4 real
echo BTN_START > "$FAKE/keys/event4"
giveup rollback
[[ $r == 1 ]] && ! hasre '^bootc' && grep -q "A not held for 1 s" "$tmp/out" || fail "rollback without A held"
echo BTN_SOUTH > "$FAKE/keys/event4"
( sleep 0.6; : > "$FAKE/keys/event4" ) &
rel=$!
giveup rollback
wait "$rel"
[[ $r == 1 ]] && ! hasre '^bootc' || fail "rollback with A released in the window"
mkpad event6 real
echo "BTN_SOUTH BTN_START" > "$FAKE/keys/event4"
giveup rollback
[[ $r == 1 ]] && ! hasre '^bootc' || fail "rollback with one of two real pads not held"
echo BTN_SOUTH > "$FAKE/keys/event6"
: > "$FAKE/keys/event9"
giveup rollback
[[ $r == 0 ]] && has "bootc rollback" && has reboot || fail "rollback from recovery: $(calls) $(cat "$tmp/out")"
unset MICROOS_PAD_STATE

reset
cur microdap
touch "$FAKE/never/$(unit_of microdap)"
echo inactive > "$FAKE/units/$(unit_of microdap)"
export FAKE_RUN_SWITCH=1
r=0
"$libexec/microos-session-watch" 2> "$tmp/out" || r=$?
has "start microos-session-switcher.service" || fail "watch did not switch to recovery: $(calls)"
[[ $(current) == recovery && $(ustate recovery) == active ]] || fail "watch end state $(current)"
[[ $(cut -d' ' -f1,4 "$run/session-previous") == "microdap fallback" ]] || fail "watch session-previous: $(cat "$run/session-previous")"
! has "start --no-block microos-session-giveup.service" || fail "watch gave up although recovery started"
reset
cur microdap
echo inactive > "$FAKE/units/$(unit_of microdap)"
touch "$FAKE/never/$(unit_of microdap)" "$FAKE/never/$(unit_of recovery)"
export FAKE_RUN_SWITCH=1
"$libexec/microos-session-watch" 2> /dev/null || true
has "start --no-block microos-session-giveup.service" || fail "no giveup when recovery never started after the watch"
[[ $(< "$run/session-failed") == "recovery $(cut -d' ' -f3 "$run/session-current")" ]] || fail "session-failed: $(cat "$run/session-failed")"
reset
cur recovery
echo inactive > "$FAKE/units/$(unit_of recovery)"
touch "$FAKE/never/$(unit_of recovery)"
plant "$run/session-failed"
"$libexec/microos-session-watch" 2> /dev/null || true
has "start --no-block microos-session-giveup.service" || fail "watch did not give up on a recovery boot that never started"
! has "start microos-session-switcher.service" || fail "watch switched from recovery to recovery"
[[ $(< "$run/session-failed") == "recovery $(cut -d' ' -f3 "$run/session-current")" ]] || fail "watch session-failed"
planted_ok "watch" "$run/session-failed"
reset
cur microdap
echo inactive > "$FAKE/units/$(unit_of microdap)"
rm -f "$FAKE/sddm-up"
echo "7 gamescope-session-plus@microdap.service start waiting" > "$FAKE/jobs"
( sleep 4; echo active > "$FAKE/units/$(unit_of microdap)"; rm "$FAKE/jobs" ) &
"$libexec/microos-session-watch" 2> /dev/null
wait $!
! hasre 'microos-session-(switch|fallback)|giveup' || fail "watch acted on a queued session start"
reset
cur microdap
echo inactive > "$FAKE/units/$(unit_of microdap)"
touch "$FAKE/never/$(unit_of microdap)"
echo "7 gamescope-session-plus@microdap.service start waiting" > "$FAKE/jobs"
( sleep 4; rm "$FAKE/jobs" ) &
"$libexec/microos-session-watch" 2> /dev/null || true
wait $!
has "start microos-session-switcher.service" || fail "watch did not switch when a queued start ended without the unit up: $(calls)"
unset FAKE_RUN_SWITCH

hot() {
  local k=$1
  shift
  r=0
  MICROOS_PAD_STATE=$FAKE/keys MICROOS_BOOT_HOTKEYS_FIND_MS=300 "$libexec/microos-boot-hotkeys" > "$tmp/out" 2>&1 &
  hk=$!
  if [[ -n $k ]]; then
    sleep "$k"
    "$@"
  fi
  wait "$hk" || r=$?
}
reset
echo microdap > "$FAKE/default"
cur microdap
s0=$(cat "$run/session-current")
rm -f "$FAKE/sddm-up"
echo inactive > "$FAKE/units/$(unit_of microdap)"
nopads
mkpad event9 virtual
echo BTN_START > "$FAKE/keys/event9"
hot ""
[[ $r == 0 && $(count "notify --ready current=microdap") == 1 && $(cat "$run/session-current") == "$s0" ]] || fail "hotkey without a pad: $(calls)"
mkpad event4 real
: > "$FAKE/keys/event4"
hot 0.4 eval 'echo BTN_START > "$FAKE/keys/event4"'
[[ $r == 0 && $(cat "$run/session-current") == "$s0" ]] || fail "a key pressed after the first poll armed the hotkey"
has "notify --ready current=microdap" || fail "hotkey not ready without a key"
reset
echo microdap > "$FAKE/default"
cur microdap
rm -f "$FAKE/sddm-up"
echo inactive > "$FAKE/units/$(unit_of microdap)"
printf 'name=microdap\ncount=1\n' > "$state/session/attempt"
echo BTN_START > "$FAKE/keys/event4"
plant "$run/sddm-autologin.conf" "$run/session-current"
hot ""
[[ $r == 0 ]] && has "notify --ready current=steam" || fail "hotkey ready before the rewrite: $(calls)"
[[ $(current) == steam && $(login) == gamescope-session-steam.desktop ]] || fail "hotkey rewrite: $(cat "$run/session-current")"
planted_ok "hotkey" "$run/sddm-autologin.conf" "$run/session-current"
[[ ! -e $state/session/attempt ]] || fail "hotkey kept the attempt"
! hasre 'microos-session-(switch|fallback)|microset set' || fail "a held hotkey switched or wrote the default: $(calls)"
grep -q "BTN_START held at boot, steam for this boot" "$tmp/out" || fail "hotkey line: $(cat "$tmp/out")"
reset
echo microdap > "$FAKE/default"
cur microdap
rm -f "$FAKE/sddm-up"
echo inactive > "$FAKE/units/$(unit_of microdap)"
echo recovery > "$FAKE/default"
printf 'name=microdap\ncount=1\nfallback=0\ntarget=microdap\n' > "$state/session/attempt"
echo BTN_SELECT > "$FAKE/keys/event4"
hot 0.5 eval ': > "$FAKE/keys/event4"'
settle
grep -q "BTN_SELECT held at boot, steam for this boot" "$tmp/out" || fail "Select did not arm: $(cat "$tmp/out")"
[[ $(current) == microdap ]] || fail "release before 1000 ms did not restore microdap: $(current)"
[[ $(< "$state/session/attempt") == $'name=microdap\ncount=1\nfallback=0\ntarget=microdap' ]] || fail "release did not restore the attempt"
reset
cur steam
s0=$(cat "$run/session-current")
echo BTN_START > "$FAKE/keys/event4"
hot ""
[[ $(cat "$run/session-current") == "$s0" ]] && ! hasre 'microos-session-(switch|fallback)' || fail "hold to the current session not a no op"
grep -q "steam is current" "$tmp/out" || fail "hotkey no op line"

reset
"$tree/usr/bin/steamos-session-select" gamescope || fail "steamos-session-select gamescope"
r=0
"$tree/usr/bin/steamos-session-select" plasma || r=$?
[[ $r == 1 ]] && has "logger -t steamos-session-select session plasma refused, no desktop yet" || fail "steamos-session-select plasma: $r $(calls)"

re=$(sed -n 's/^  var units = \/\(.*\)\/;$/\1/p' "$tree/usr/share/polkit-1/rules.d/50-microos-session.rules")
[[ -n $re ]] || fail "polkit unit pattern not found"
python3 - "$re" << 'EOF' || fail "polkit unit pattern"
import re
import sys

p = re.compile(sys.argv[1])
ok = ["microos-session-fallback@steam.service", "microos-session-switch@micro-dap2.service", "microos-session-up@recovery.service",
      "microos-session-rollback.service"]
bad = ["microos-session-giveup.service", "microos-session-switch@.service", "microos-session-switch@Steam.service", "microos-session-switch@a.b.service",
       "microos-session-boot.service", "microos-session-switch@x.service.d", "sddm.service", "microos-session-up@-x.service"]
sys.exit(0 if all(p.match(u) for u in ok) and not any(p.match(u) for u in bad) else 1)
EOF
grep -qF 'action.lookup("verb") == "start"' "$tree/usr/share/polkit-1/rules.d/50-microos-session.rules" || fail "polkit verb check"
grep -qF 'subject.user != "micro"' "$tree/usr/share/polkit-1/rules.d/50-microos-session.rules" || fail "polkit subject check"

tr=$tmp/tfroot
mkdir -p "$tr/etc" "$tr/usr/lib/tmpfiles.d"
printf 'root:x:0:0::/root:/bin/bash\nmicro:x:1000:1000::/var/home/micro:/bin/bash\n' > "$tr/etc/passwd"
printf 'root:x:0:\nmicro:x:1000:\n' > "$tr/etc/group"
cp "$tree/usr/lib/tmpfiles.d/microos.conf" "$tr/usr/lib/tmpfiles.d/"
systemd-tmpfiles --create --root="$tr" microos.conf 2> "$tmp/out" || fail "systemd-tmpfiles: $(cat "$tmp/out")"
for e in 'run/microos 755 0 0' 'run/microos/lock 700 0 0' 'run/microos/user 755 1000 1000' 'var/lib/microos/session 755 0 0'; do
  read -r d m o g <<< "$e"
  [[ $(stat -c '%a %u %g' "$tr/$d" 2> /dev/null) == "$m $o $g" ]] || fail "tmpfiles /$d: $(stat -c '%a %u %g' "$tr/$d" 2>&1)"
done
[[ ! -e $tr/run/microos/user/track ]] || fail "tmpfiles created the track dir"

reset
echo steam > "$FAKE/default"
cur steam
echo inactive > "$FAKE/units/$(unit_of steam)"
systemctl --user show -p ActiveState --value "$(unit_of steam)" > /dev/null
[[ $(ustate steam) == active && $(cat "$FAKE/timers/microos-session-alive@steam.timer" 2> /dev/null) == armed ]] ||
  fail "the session start did not arm the alive timer"
systemctl --user _fire
has "start --no-block microos-session-up@steam.service" || fail "the alive timer did not start up@: $(calls)"
: > "$FAKE/calls"
systemctl --user _exit "$(unit_of steam)"
[[ -e $run/user/track/steam ]] || fail "ExecStopPost did not run the tracker on a crash"
systemctl --user show -p ActiveState --value "$(unit_of steam)" > /dev/null
[[ $(cat "$FAKE/timers/microos-session-alive@steam.timer" 2> /dev/null) == armed ]] || fail "the alive timer was not re-armed after a crash and relogin"
systemctl --user _fire
has "start --no-block microos-session-up@steam.service" || fail "no up@ after the crash and relogin"
[[ $(readlink "$tree/etc/sddm.conf.d/zzz-microos-autologin.conf") == /run/microos/sddm-autologin.conf ]] || fail "autologin link"
[[ $(< "$units/system/sddm.service.d/10-microos-tz.conf") == $'[Service]\nEnvironment=TZ=UTC0' ]] || fail "TZ drop-in"
for u in microos-session-boot microos-session-switch@ microos-session-fallback@ microos-session-switcher microos-session-up@ \
  microos-session-attempt microos-session-watch microos-boot-hotkeys; do
  for k in ProtectSystem=strict 'ReadWritePaths=/run/microos /var/lib/microos/session'; do
    grep -qxF "$k" "$units/system/$u.service" || fail "$u.service lacks $k"
  done
done
for u in microos-session-boot microos-session-switch@ microos-session-fallback@ microos-session-switcher microos-session-up@ \
  microos-session-attempt microos-session-watch microos-boot-hotkeys microos-session-giveup microos-session-rollback; do
  for k in NoNewPrivileges=yes PrivateTmp=yes ProtectHome=read-only RestrictSUIDSGID=yes; do
    grep -qxF "$k" "$units/system/$u.service" || fail "$u.service lacks $k"
  done
done
for u in microos-session-switcher microos-session-up@ microos-session-watch microos-boot-hotkeys; do
  grep -qxF 'CapabilityBoundingSet=CAP_SETUID CAP_SETGID' "$units/system/$u.service" || fail "$u.service capabilities"
done
for u in microos-session-boot microos-session-attempt microos-session-switch@ microos-session-fallback@; do
  grep -qxF 'CapabilityBoundingSet=' "$units/system/$u.service" || fail "$u.service capabilities"
done
for u in microos-session-giveup microos-session-rollback; do
  for k in PrivateMounts=yes 'RequiresMountsFor=/sysroot /boot /boot/efi /var/lib/microos'; do
    grep -qxF "$k" "$units/system/$u.service" || fail "$u.service lacks $k"
  done
  ! grep -q '^ProtectSystem' "$units/system/$u.service" || fail "$u.service has ProtectSystem"
done
exit $rc
