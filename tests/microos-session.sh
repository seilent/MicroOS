#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
session=$tree/usr/bin/microos-session
libexec=$tree/usr/libexec/microos
units=$tree/usr/lib/systemd
tmp=$(mktemp -d)
ticker=""
trap '[[ -z $ticker ]] || { : > "$tmp/stop"; wait "$ticker" 2> /dev/null || true; }; rm -rf "$tmp"' EXIT
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
export PATH=$here/microos-session/bin:$PATH MICROOS_BOOT_ID=$tmp/boot_id
export MICROOS_PAD_HOLD=$libexec/microos-pad-hold
boot=0123456789abcdef0123456789abcdef
echo 01234567-89ab-cdef-0123-456789abcdef > "$tmp/boot_id"
tick() { awk '{ printf "%.2f 0\n", $1 + 100000 }' /proc/uptime > "$tmp/uptime.new" && mv -f "$tmp/uptime.new" "$tmp/uptime"; }
tick
until [[ -e $tmp/stop ]]; do tick; sleep 0.05; done &
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
mkkeys() {
  local e=$1 plat base drv=$MICROOS_SYSFS/bus/platform/drivers/${5:-gpio-keys}
  if [[ $2 == virtual ]]; then
    plat=$MICROOS_SYSFS/devices/virtual/keys-$e
  else
    plat=$MICROOS_SYSFS/devices/platform/keys-$e
  fi
  base=$plat/input/in-$e
  mkdir -p "$base/$e" "$base/id" "$drv" "$MICROOS_SYSFS/class/input"
  echo "${3:-aya-keys}" > "$base/name"
  echo 0019 > "$base/id/bustype"
  echo 0001 > "$base/id/vendor"
  echo "${4:-0001}" > "$base/id/product"
  echo 13:64 > "$base/$e/dev"
  ln -sfn .. "$base/$e/device"
  ln -sfn ../.. "$base/device"
  ln -sfn "$drv" "$plat/driver"
  ln -sfn "$base/$e" "$MICROOS_SYSFS/class/input/$e"
}
nopads() { rm -rf "$MICROOS_SYSFS"; mkdir -p "$MICROOS_SYSFS/class/input"; }
feeder=""
feed() {
  local f=$FAKE/keys/$1
  shift
  mkfifo "$f.next"
  mv -f "$f.next" "$f"
  (
    while (( $# > 1 )); do
      exec 3> "$f"
      echo "$1" >&3
      shift
      if (( $# > 1 )); then
        mkfifo "$f.next"
      else
        echo "$1" > "$f.next"
      fi
      mv -f "$f.next" "$f"
      exec 3>&-
    done
  ) &
  feeder=$!
}
fed() {
  kill "$feeder" 2> /dev/null || true
  wait "$feeder" 2> /dev/null || true
  rm -f "$FAKE/keys/$1" "$FAKE/keys/$1.next"
}
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
mnow() { echo $(( $(mono) / 1000000 )); }
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
  mkdir -p "$run/user" "$run/hold" "$state/session" "$FAKE/units" "$FAKE/enter" "$FAKE/scopes" "$FAKE/desktops" "$FAKE/never" \
    "$FAKE/home/.steam"
  chmod 0755 "$run"
  install -m 0600 /dev/null "$run/hold/.lock"
  install -m 0600 /dev/null "$run/hold/.lock-keys"
  for s in steam recovery microdap; do
    unit_of "$s" > "$FAKE/desktops/$(desk_of "$s")"
  done
  echo steam > "$FAKE/default"
  echo 1 > "$FAKE/seat-id"
  : > "$FAKE/calls"
  : > "$run/splash.lock"
  settle || true
  unset FAKE_STOP_DELAY FAKE_SHUTDOWN_DELAY FAKE_RUN_SWITCH MICROOS_PAD_STATE
  nopads
  mkpad event4 real
  mkdir -p "$FAKE/keys"
}
cur() {
  local s=${2:-$(serial)}
  printf '%s %s %s %s\n' "$1" "$(unit_of "$1")" "$s" "${3:-$(( $(mono) - $(bt) * 1000000 + s ))}" > "$run/session-current"
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
for d in '../steam' 'a;b' 'x y' '$(id)' Bad; do
  reset
  if "$session" set-default "$d" 2> /dev/null; then fail "set-default took '$d'"; fi
  ! grep -q "microset set" "$FAKE/calls" 2> /dev/null || fail "set-default '$d' reached microset"
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
read -r n u s m < "$run/session-current"
[[ $n == microdap && $u == gamescope-session-plus@microdap.service && $s =~ ^[0-9]+$ && $m =~ ^[0-9]+$ ]] &&
  (( s / 1000000 >= 100000 && m <= $(mono) && s - m >= 99000000000 )) || fail "boot session-current: $n $u $s $m"
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
prev=$(cut -d' ' -f1-3 "$run/session-current")
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
! hasre '^restart sddm' || fail "sddm restarted on a clean switch"
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

clients() {
  mkdir -p "$MICROOS_SYSFS/kernel/debug/dri/0"
  {
    printf '%20s %5s %3s master a %5s %10s %*s %20s\n' command tgid dev uid magic 64 name id
    printf '%20s %5d %3d   %c    %c %5d %10u %*s %20llu\n' 'gamescope wl' 900 128 n y 0 0 64 '<unset>' 76
    printf '%20s %5d %3d   %c    %c %5d %10u %*s %20llu\n' systemd-logind 4000 128 y y 1000 0 64 '<unset>' 70
    printf '%20s %5d %3d   %c    %c %5d %10u %*s %20llu\n' systemd-logind 585 0 y y 0 0 64 '<unset>' 77
  } > "$MICROOS_SYSFS/kernel/debug/dri/0/clients"
}
splash_line() { calls | grep -nE "$1" | head -n 1 | cut -d: -f1 || true; }
printf 'LABEL="MicroEMU"\nDESKTOP=microemu.desktop\nUNIT=gamescope-session-plus@microemu.service\nSTOP=unit\n' > "$sd/microemu.conf"
echo '[Desktop Entry]' > "$root/usr/share/wayland-sessions/microemu.desktop"
for pair in steam:microdap microdap:microemu microemu:steam steam:recovery; do
  from=${pair%%:*} to=${pair#*:}
  reset
  unit_of microemu > "$FAKE/desktops/microemu.desktop"
  clients
  cur "$from"
  [[ $from != steam ]] || reader
  sw "$to"
  [[ $r == 0 ]] || fail "splash $from to $to: $r $(cat "$tmp/out")"
  s=$(cut -d' ' -f3 "$run/session-current")
  has "splash busy=$s target=$to $s 77 lock=free" || fail "splash $from to $to: files at the restart: $(calls)"
  [[ $(count "restart --no-block microos-splash-switch.service") == 1 ]] || fail "splash $from to $to: restarts: $(calls)"
  a=$(line_of "restart --no-block microos-splash-switch.service")
  if [[ $from == steam ]]; then
    g=$(splash_line '^steam -shutdown')
  else
    g=$(line_of "user stop $(unit_of "$from")")
  fi
  [[ -n $a && -n $g ]] && (( a < g )) || fail "splash $from to $to: restart not before the source stop: $(calls)"
  [[ ! -e $run/splash-busy ]] || fail "splash $from to $to: busy left with the unit inactive"
  [[ $(stat -c %a "$run/splash-target") == 644 ]] || fail "splash $from to $to: target mode"
  [[ $from != steam ]] || noreader
done

reset
cur microdap
echo inactive > "$FAKE/units/$(unit_of microdap)"
sw steam
[[ $r == 0 ]] && ! has "restart --no-block microos-splash-switch.service" || fail "splash with an inactive source: $(calls)"
[[ ! -e $run/splash-busy ]] || fail "splash with an inactive source: busy written"
reset
sw microdap
[[ $r == 0 ]] && ! has "restart --no-block microos-splash-switch.service" || fail "splash with no source: $(calls)"

reset
cur steam
touch "$FAKE/never/$(unit_of microdap)"
sw microdap
[[ $(count "restart --no-block microos-splash-switch.service") == 1 ]] || fail "splash on the recovery fallback from a dead target: $(calls)"

reset
cur microdap
touch "$FAKE/splash-restart-fails"
echo active > "$FAKE/splash-state"
sw steam
grep -q "restart of microos-splash-switch.service failed" "$FAKE/switch.log" || fail "failed splash restart not logged: $(cat "$FAKE/switch.log")"
[[ ! -e $run/splash-busy ]] || fail "failed splash restart left busy"

for st in deactivating active activating; do
  reset
  cur microdap
  echo "$st" > "$FAKE/splash-state"
  sw steam
  [[ $(cat "$run/splash-busy" 2> /dev/null) =~ ^[0-9]+$ ]] || fail "end removal with the unit $st"
done
reset
cur microdap
echo 4711 > "$FAKE/splash-job"
sw steam
[[ -e $run/splash-busy ]] || fail "end removal with a queued splash job"
reset
cur microdap
echo failed > "$FAKE/splash-state"
sw steam
[[ ! -e $run/splash-busy ]] || fail "end removal kept busy with the unit failed"

reset
cur microdap
python3 -c 'import fcntl, os, sys, time
fcntl.flock(os.open(sys.argv[1], os.O_RDONLY), fcntl.LOCK_EX)
time.sleep(30)' "$run/splash.lock" &
holder=$!
sleep 0.3
sw steam
kill "$holder"
wait "$holder" 2> /dev/null || true
grep -q "splash lock busy or splash files not written, no splash" "$FAKE/switch.log" || fail "held splash lock not logged: $(cat "$FAKE/switch.log")"
! has "restart --no-block microos-splash-switch.service" && [[ ! -e $run/splash-busy ]] || fail "splash with the lock held: $(calls)"

reset
cur microdap
rm "$run/splash.lock"
sw steam
[[ $r == 0 && $(current) == steam ]] && ! has "restart --no-block microos-splash-switch.service" || fail "switch without the splash lock: $(calls)"
rm -f "$sd/microemu.conf" "$root/usr/share/wayland-sessions/microemu.desktop"

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
now=$(mnow)
: > "$FAKE/journal"
for _ in 1 2 3; do printf '%s [%5d.000000] pm2 systemd[4242]: Started\n' "$boot" "$now" >> "$FAKE/journal"; done
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
  for t; do
    printf '%s [%5d.000000] pm2 systemd[%s]: Started gamescope-session-plus@recovery.service.\n' "${jboot:-$boot}" "$t" "${pid:-4242}" \
      >> "$FAKE/journal"
  done
}
reset
cur steam
status "$B b" "$P"
starts "$(mnow)" "$(mnow)" "$(mnow)"
giveup giveup
[[ $r == 1 ]] && ! hasre '^(bootc|stop|reboot)' || fail "giveup while steam is current: $r $(calls)"
giveup rollback
[[ $r == 1 ]] && ! hasre '^bootc' || fail "rollback while steam is current: $r"
cur recovery $(( ($(bt) - 100) * 1000000 ))
echo "$P" > "$state/confirmed"
now=$(mnow)
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
[[ $r == 0 ]] && ! has "stop display-manager.service" && ! has "plymouth quit" || fail "the display manager stopped twice in one boot"
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
now=$(mnow)
starts "$now" "$now" "$now"
giveup giveup
[[ $r == 0 ]] && ! has "bootc rollback" && has "stop display-manager.service" || fail "confirmed giveup: $(calls)"
a=$(line_of "stop display-manager.service")
g=$(line_of "plymouth quit")
[[ -n $a && -n $g ]] && (( a < g )) || fail "giveup did not quit plymouth after the display manager stop: $(calls)"
reset
cur recovery $(( ($(bt) - 10) * 1000000 ))
echo "$P" > "$state/confirmed"
status "$B b" "$P"
now=$(mnow)
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
feed event4 BTN_SOUTH BTN_SOUTH BTN_SOUTH BTN_SOUTH ""
giveup rollback
fed event4
[[ $r == 1 ]] && ! hasre '^bootc' || fail "rollback with A released in the window"
mkpad event6 real
echo "BTN_SOUTH BTN_START" > "$FAKE/keys/event4"
giveup rollback
[[ $r == 1 ]] && ! hasre '^bootc' || fail "rollback with one of two real pads not held"
echo BTN_SOUTH > "$FAKE/keys/event6"
: > "$FAKE/keys/event9"
flock -o -x "$run/hold/.lock" sleep 3 &
holder=$!
for _ in $(seq 40); do flock -n "$run/hold/.lock" true || break; sleep 0.05; done
giveup rollback
kill "$holder" 2> /dev/null || true
wait "$holder" 2> /dev/null || true
[[ $r == 1 ]] && ! hasre '^bootc' && grep -q "another A hold is waiting" "$tmp/out" ||
  fail "rollback while another A hold waits: $r $(cat "$tmp/out")"
giveup rollback
[[ $r == 0 ]] && has "bootc rollback" && has reboot || fail "rollback from recovery: $(calls) $(cat "$tmp/out")"

hold() { r=0; "$libexec/microos-pad-hold" "$@" > "$tmp/out" 2>&1 || r=$?; }
hold BTN_SOUTH 1
[[ $r == 2 ]] || fail "pad-hold usage: $r"
hold BTN_EAST 1 0
[[ $r == 2 ]] || fail "pad-hold took BTN_EAST: $r"
hold BTN_SOUTH 1 09
[[ $r == 2 ]] || fail "pad-hold took a wait with a leading zero: $r"
nopads
hold BTN_SOUTH 1 0
[[ $r == 1 ]] && grep -q "no AYANEO Controller" "$tmp/out" || fail "pad-hold without a pad: $r $(cat "$tmp/out")"
mkpad event9 virtual
echo BTN_SOUTH > "$FAKE/keys/event9"
hold BTN_SOUTH 1 0
[[ $r == 1 ]] && grep -q "no AYANEO Controller" "$tmp/out" || fail "pad-hold took a virtual pad: $r"
mkpad event4 real
echo BTN_SOUTH > "$FAKE/keys/event4"
hold BTN_SOUTH 1 0
[[ $r == 0 ]] || fail "pad-hold held: $r $(cat "$tmp/out")"
echo BTN_START > "$FAKE/keys/event4"
hold BTN_SOUTH 1 0
[[ $r == 1 ]] && grep -q "BTN_SOUTH not held for 1 s" "$tmp/out" || fail "pad-hold wrong button: $r"
hold BTN_START+BTN_SELECT 1 0
[[ $r == 1 ]] || fail "pad-hold accepted one of two buttons: $r"
echo "BTN_START BTN_SELECT" > "$FAKE/keys/event4"
hold BTN_START+BTN_SELECT 1 0
[[ $r == 0 ]] || fail "pad-hold two buttons: $r"
echo BTN_SOUTH > "$FAKE/keys/event4"
hold BTN_SOUTH 1 3
[[ $r == 1 ]] || fail "pad-hold with a wait counted a press held from the start: $r"
feed event4 "" BTN_SOUTH BTN_SOUTH BTN_SOUTH BTN_SOUTH BTN_SOUTH BTN_SOUTH
hold BTN_SOUTH 1 3
fed event4
[[ $r == 0 ]] || fail "pad-hold released first then held: $r $(cat "$tmp/out")"
feed event4 "" BTN_SOUTH BTN_SOUTH BTN_SOUTH BTN_SOUTH ""
hold BTN_SOUTH 1 2
fed event4
[[ $r == 1 ]] || fail "pad-hold took a short press: $r"
: > "$FAKE/keys/event4"
hold BTN_SOUTH 1 1
[[ $r == 1 ]] && grep -q "not held for 1 s" "$tmp/out" || fail "pad-hold wait expired: $r"
"$libexec/microos-pad-hold" BTN_SOUTH 1 2 > /dev/null 2>&1 &
first=$!
for _ in $(seq 40); do flock -n "$run/hold/.lock" true || break; sleep 0.05; done
hold BTN_SOUTH 1 1
[[ $r == 3 ]] && grep -q "another hold is waiting" "$tmp/out" || fail "pad-hold while another waits: $r $(cat "$tmp/out")"
wait "$first" || true
hold BTN_SOUTH 1 1
[[ $r == 1 ]] || fail "pad-hold after the other hold ended: $r"
! setpriv --reuid 65534 --regid 65534 --clear-groups sh -c 'exec 7< "$1"' sh "$run/hold/.lock" 2> /dev/null ||
  fail "another uid opened the hold lock"
for bad in mode link missing; do
  rm -f "$run/hold/.lock"
  case $bad in
    mode) install -m 0644 /dev/null "$run/hold/.lock" ;;
    link) install -m 0600 /dev/null "$tmp/lock-target" && ln -s "$tmp/lock-target" "$run/hold/.lock" ;;
  esac
  echo BTN_SOUTH > "$FAKE/keys/event4"
  hold BTN_SOUTH 1 0
  [[ $r == 1 ]] && grep -q "missing or not root 0600" "$tmp/out" || fail "pad-hold with a $bad lock: $r $(cat "$tmp/out")"
done
rm -f "$run/hold/.lock" "$tmp/lock-target"
install -m 0600 /dev/null "$run/hold/.lock"
echo BTN_SOUTH > "$FAKE/keys/event4"
echo "steam gamescope-session-plus@steam.service 1 0" > "$run/session-current"
hold --yield recovery BTN_SOUTH 1 0
[[ $r == 0 ]] || fail "pad-hold --yield recovery outside recovery: $r $(cat "$tmp/out")"
: > "$FAKE/keys/event4"
echo "recovery microos-recovery.service 2 0" > "$run/session-current"
hold --yield recovery BTN_SOUTH 1 3
[[ $r == 1 ]] && grep -q "the recovery session is active" "$tmp/out" || fail "pad-hold --yield in recovery: $r $(cat "$tmp/out")"
hold --yield 'bad name' BTN_SOUTH 1 0
[[ $r == 2 ]] || fail "pad-hold --yield with a bad name: $r"
for a in "KEY_PROG4+BTN_SOUTH 1 0" "BTN_SOUTH+KEY_PROG4 1 0" "KEY_PROG3 1 0" "--held" "--yield" \
  "--held --yield bad.name BTN_SOUTH 1 0" "--hold BTN_SOUTH 1 0" "--held BTN_SOUTH 1"; do
  read -r -a argv <<< "$a"
  hold "${argv[@]}"
  [[ $r == 2 ]] || fail "pad-hold usage $a: $r"
done
nopads
mkpad event4 real
echo "BTN_SOUTH KEY_PROG4" > "$FAKE/keys/event4"
hold KEY_PROG4 1 0
[[ $r == 1 ]] && grep -q "no aya-keys" "$tmp/out" || fail "pad-hold took KEY_PROG4 from the pad: $r $(cat "$tmp/out")"
for bad in virtual name ids driver two; do
  nopads
  case $bad in
    virtual) mkkeys event0 virtual ;;
    name) mkkeys event0 real gpio-keys ;;
    ids) mkkeys event0 real aya-keys 0002 ;;
    driver) mkkeys event0 real aya-keys 0001 gpio-keys-polled ;;
    two) mkkeys event0 real && mkkeys event7 real && echo KEY_PROG4 > "$FAKE/keys/event7" ;;
  esac
  echo KEY_PROG4 > "$FAKE/keys/event0"
  hold KEY_PROG4 1 0
  [[ $r == 1 ]] && grep -q "no aya-keys" "$tmp/out" || fail "pad-hold took a $bad aya-keys: $r $(cat "$tmp/out")"
done
nopads
mkkeys event0 real
echo BTN_SOUTH > "$FAKE/keys/event0"
hold BTN_SOUTH 1 0
[[ $r == 1 ]] && grep -q "no AYANEO Controller" "$tmp/out" || fail "pad-hold took BTN_SOUTH from aya-keys: $r $(cat "$tmp/out")"
mkpad event4 real
mkkeys event1 real gpio-keys
mkkeys event9 virtual
echo KEY_PROG4 > "$FAKE/keys/event0"
: > "$FAKE/keys/event1"
: > "$FAKE/keys/event4"
: > "$FAKE/keys/event9"
hold KEY_PROG4 1 0
[[ $r == 0 ]] || fail "pad-hold KEY_PROG4 on aya-keys: $r $(cat "$tmp/out")"
feed event0 "" KEY_PROG4 KEY_PROG4 KEY_PROG4 KEY_PROG4 KEY_PROG4 ""
hold KEY_PROG4 1 2
fed event0
[[ $r == 0 ]] || fail "pad-hold KEY_PROG4 held 5 polls: $r $(cat "$tmp/out")"
feed event0 "" KEY_PROG4 KEY_PROG4 KEY_PROG4 KEY_PROG4 ""
hold KEY_PROG4 1 2
fed event0
[[ $r == 1 ]] && grep -q "KEY_PROG4 not held for 1 s" "$tmp/out" || fail "pad-hold KEY_PROG4 took a press of 4 polls: $r $(cat "$tmp/out")"
echo KEY_PROG4 > "$FAKE/keys/event0"
hold KEY_PROG4 1 2
[[ $r == 1 ]] || fail "pad-hold KEY_PROG4 counted a press held from the start without --held: $r"
! grep -q "first sample at" "$tmp/out" || fail "pad-hold logged the first sample without --held: $(cat "$tmp/out")"
m0=$(mono)
hold --held KEY_PROG4 1 2
m1=$(mono)
[[ $r == 0 ]] || fail "pad-hold --held KEY_PROG4: $r $(cat "$tmp/out")"
at=$(sed -n 's/^microos-pad-hold: first sample at \([0-9]*\) monotonic$/\1/p' "$tmp/out")
[[ $(grep -c "first sample at" "$tmp/out") == 1 && -n $at ]] && (( m0 <= at && at <= m1 )) ||
  fail "pad-hold --held first sample line, monotonic $m0 to $m1: $(cat "$tmp/out")"
feed event0 KEY_PROG4 KEY_PROG4 KEY_PROG4 KEY_PROG4 KEY_PROG4 ""
hold --held KEY_PROG4 1 2
fed event0
[[ $r == 0 ]] || fail "pad-hold --held KEY_PROG4 held 5 polls from the start: $r $(cat "$tmp/out")"
feed event0 KEY_PROG4 KEY_PROG4 KEY_PROG4 KEY_PROG4 ""
hold --held KEY_PROG4 1 2
fed event0
[[ $r == 1 ]] || fail "pad-hold --held took a press of 4 polls: $r"
echo BTN_SOUTH > "$FAKE/keys/event4"
hold --held BTN_SOUTH 1 2
[[ $r == 0 ]] || fail "pad-hold --held BTN_SOUTH: $r $(cat "$tmp/out")"
echo "steam gamescope-session-plus@steam.service 1 0" > "$run/session-current"
for a in "--yield recovery --held" "--held --yield recovery"; do
  read -r -a argv <<< "$a"
  hold "${argv[@]}" BTN_SOUTH 1 2
  [[ $r == 0 ]] || fail "pad-hold $a outside recovery: $r $(cat "$tmp/out")"
done
echo "recovery microos-recovery.service 2 0" > "$run/session-current"
for a in "--yield recovery --held" "--held --yield recovery"; do
  read -r -a argv <<< "$a"
  hold "${argv[@]}" BTN_SOUTH 1 2
  [[ $r == 1 ]] && grep -q "the recovery session is active" "$tmp/out" || fail "pad-hold $a in recovery: $r $(cat "$tmp/out")"
done
echo "steam gamescope-session-plus@steam.service 1 0" > "$run/session-current"
: > "$FAKE/keys/event0"
"$libexec/microos-pad-hold" KEY_PROG4 1 2 > /dev/null 2>&1 &
first=$!
for _ in $(seq 40); do flock -n "$run/hold/.lock-keys" true || break; sleep 0.05; done
! flock -n "$run/hold/.lock-keys" true || fail "an RC hold did not take .lock-keys"
flock -n "$run/hold/.lock" true || fail "an RC hold took .lock"
hold KEY_PROG4 1 1
[[ $r == 3 ]] && grep -q "another hold is waiting" "$tmp/out" || fail "an RC hold while another waits: $r $(cat "$tmp/out")"
wait "$first" || true
: > "$FAKE/keys/event4"
"$libexec/microos-pad-hold" BTN_SOUTH 1 2 > /dev/null 2>&1 &
first=$!
for _ in $(seq 40); do flock -n "$run/hold/.lock" true || break; sleep 0.05; done
! flock -n "$run/hold/.lock" true || fail "a pad hold did not take .lock"
flock -n "$run/hold/.lock-keys" true || fail "a pad hold took .lock-keys"
wait "$first" || true
! setpriv --reuid 65534 --regid 65534 --clear-groups sh -c 'exec 7< "$1"' sh "$run/hold/.lock-keys" 2> /dev/null ||
  fail "another uid opened the keys hold lock"
for bad in mode link missing owner; do
  rm -f "$run/hold/.lock-keys"
  case $bad in
    mode) install -m 0644 /dev/null "$run/hold/.lock-keys" ;;
    link) install -m 0600 /dev/null "$tmp/lock-target" && ln -s "$tmp/lock-target" "$run/hold/.lock-keys" ;;
    owner) install -m 0600 -o 65534 /dev/null "$run/hold/.lock-keys" ;;
  esac
  echo KEY_PROG4 > "$FAKE/keys/event0"
  hold KEY_PROG4 1 0
  [[ $r == 1 ]] && grep -q "missing or not root 0600" "$tmp/out" || fail "pad-hold with a $bad keys lock: $r $(cat "$tmp/out")"
done
rm -f "$run/hold/.lock-keys" "$tmp/lock-target"
echo BTN_SOUTH > "$FAKE/keys/event4"
hold BTN_SOUTH 1 0
[[ $r == 0 ]] || fail "pad-hold BTN_SOUTH without .lock-keys: $r $(cat "$tmp/out")"
install -m 0600 /dev/null "$run/hold/.lock-keys"
rm -f "$run/hold/.lock"
hold KEY_PROG4 1 0
[[ $r == 0 ]] || fail "pad-hold KEY_PROG4 without .lock: $r $(cat "$tmp/out")"
install -m 0600 /dev/null "$run/hold/.lock"
for a in "BTN_SOUTH 1 0" "BTN_SOUTH 1 15" "--yield recovery BTN_SOUTH 1 15"; do
  read -r -a argv <<< "$a"
  : > "$FAKE/keys/event0"
  : > "$FAKE/keys/event4"
  "$libexec/microos-pad-hold" --held KEY_PROG4 1 10 > "$tmp/other" 2>&1 &
  other=$!
  for _ in $(seq 40); do flock -n "$run/hold/.lock-keys" true || break; sleep 0.05; done
  if [[ ${argv[-1]} == 0 ]]; then
    echo BTN_SOUTH > "$FAKE/keys/event4"
  else
    feed event4 "" BTN_SOUTH BTN_SOUTH BTN_SOUTH BTN_SOUTH BTN_SOUTH BTN_SOUTH
  fi
  hold "${argv[@]}"
  [[ ${argv[-1]} == 0 ]] || fed event4
  [[ $r == 0 ]] || fail "pad-hold $a while an RC hold waits: $r $(cat "$tmp/out")"
  kill -0 "$other" 2> /dev/null || fail "the RC hold ended during pad-hold $a: $(cat "$tmp/other")"
  kill "$other" 2> /dev/null || true
  wait "$other" 2> /dev/null || true
  echo KEY_PROG4 > "$FAKE/keys/event0"
  if [[ ${argv[-1]} == 0 ]]; then
    echo BTN_SOUTH > "$FAKE/keys/event4"
  else
    : > "$FAKE/keys/event4"
  fi
  "$libexec/microos-pad-hold" "${argv[@]}" > "$tmp/other" 2>&1 &
  other=$!
  for _ in $(seq 40); do flock -n "$run/hold/.lock" true || break; sleep 0.05; done
  hold --held KEY_PROG4 1 5
  [[ $r == 0 ]] || fail "an RC hold while pad-hold $a waits: $r $(cat "$tmp/out")"
  if [[ ${argv[-1]} == 0 ]]; then
    r=0
    wait "$other" || r=$?
    [[ $r == 0 ]] || fail "pad-hold $a beside an RC hold: $r $(cat "$tmp/other")"
  else
    kill -0 "$other" 2> /dev/null || fail "pad-hold $a ended during an RC hold: $(cat "$tmp/other")"
    kill "$other" 2> /dev/null || true
    wait "$other" 2> /dev/null || true
  fi
done
rm -f "$run/session-current"
nopads
unset MICROOS_PAD_STATE
mkkeys event0 real
mkdir -p "$MICROOS_DEV/input"
ln -sfn /dev/null "$MICROOS_DEV/input/event0"
hold KEY_PROG4 1 0
[[ $r == 1 ]] && grep -q "is not the device in" "$tmp/out" || fail "pad-hold took a node with another st_rdev: $r $(cat "$tmp/out")"
printf '%d:%d\n' "0x$(stat -L -c %t /dev/null)" "0x$(stat -L -c %T /dev/null)" > "$MICROOS_SYSFS/class/input/event0/dev"
hold KEY_PROG4 1 0
[[ $r == 1 ]] && ! grep -q "is not the device in" "$tmp/out" || fail "pad-hold refused a node with the same st_rdev: $r $(cat "$tmp/out")"
rm -f "$MICROOS_DEV/input/event0"
nopads

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
for e in 'run/microos 755 0 0' 'run/microos/lock 700 0 0' 'run/microos/hold/.lock-keys 600 0 0' 'run/microos/user 755 1000 1000' \
  'var/lib/microos/session 755 0 0'; do
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
for u in microos-session-switch@ microos-session-fallback@ microos-session-switcher; do
  ! grep -qE '^(ProtectKernelTunables=yes|(ReadOnlyPaths|InaccessiblePaths)=.*/sys)' "$units/system/$u.service" \
    || fail "$u.service makes /sys read only, the panel reset needs bl_power"
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

bl=$MICROOS_SYSFS/class/backlight
dark() {
  local d
  for d in ae94000.dsi.0 backlight-1; do
    mkdir -p "$bl/$d"
    echo 1 > "$bl/$d/bl_power"
  done
}
lit() {
  local d
  for d in ae94000.dsi.0 backlight-1; do
    has "panel $(unit_of "$1") $bl/$d 0" || return 1
  done
  ! hasre '^panel .* 1$'
}
reset
dark
cur microdap
sw steam
[[ $r == 0 && $(current) == steam && $(ustate steam) == active ]] || fail "panel: microdap to steam: $r $(cat "$tmp/out")"
lit steam || fail "panel: bl_power before steam started: $(calls)"
reset
dark
cur steam
touch "$FAKE/never/$(unit_of microdap)" "$FAKE/panel-off"
sw microdap
[[ $(current) == recovery && $(ustate recovery) == active && $(count "restart sddm.service") == 1 ]] ||
  fail "panel: failed microdap start: $(current) $(calls)"
lit recovery || fail "panel: bl_power before the recovery fallback started: $(calls)"
reset
dark
cur steam
mkdir -p "$FAKE/darken"
touch "$FAKE/stale" "$FAKE/darken/$(unit_of steam)"
sw microdap
[[ $r == 0 && $(ustate microdap) == active && $(count "restart sddm.service") == 1 ]] || fail "panel: stale relogin: $(calls)"
lit microdap || fail "panel: bl_power before the sddm restart started microdap: $(calls)"
reset
sw microdap
read -r _ _ s m < "$run/session-current"
(( m <= $(mono) && $(mono) - m < 30000000 && s - m >= 99000000000 )) || fail "switch session-current stamps: $s $m"

jl() {
  printf '%s [%5d.000000] pm2 systemd[4242]: Started gamescope-session-plus@recovery.service.\n' "$1" "$2" >> "$FAKE/journal"
}
mkdir -p "$tmp/stepped"
printf '#!/usr/bin/env bash\necho "date $*" >> "$FAKE/calls"\necho 1790000000\n' > "$tmp/stepped/date"
chmod +x "$tmp/stepped/date"
stepped() { PATH=$tmp/stepped:$PATH giveup giveup; }
reset
cur recovery $(( ($(bt) - 100) * 1000000 ))
echo "$B" > "$state/confirmed"
status "$B b" "$P"
now=$(mnow)
: > "$FAKE/journal"
for t in $(( now - 30 )) $(( now - 20 )) "$now"; do jl fedcba9876543210fedcba9876543210 "$t"; done
jl "$boot" $(( now - 150 ))
cur recovery $(( ($(bt) - 1100) * 1000000 )) $(( (now - 100) * 1000000 ))
jl "$boot" $(( now - 50 ))
jl "$boot" "$now"
stepped
[[ $r == 1 ]] && ! hasre '^(bootc|stop)' || fail "giveup counted starts of another boot or before the serial: $r $(calls)"
grep -q "recovery started 2 times" "$tmp/out" || fail "recovery count across a stepped clock: $(cat "$tmp/out")"
hasre "^journalctl .*_BOOT_ID=$boot _PID=4242 _UID=1000" || fail "journal read without the boot id: $(calls)"
jl "$boot" "$now"
stepped
[[ $r == 0 ]] && has "stop display-manager.service" || fail "giveup with 3 starts across a stepped clock: $r $(calls)"
! hasre '^date' || fail "the recovery count read the wall clock"
reset
cur recovery $(( ($(bt) - 1000) * 1000000 ))
echo "$B" > "$state/confirmed"
status "$B b" "$P"
now=$(mnow)
: > "$FAKE/journal"
for t in $(( now - 700 )) $(( now - 500 )) "$now"; do jl "$boot" "$t"; done
stepped
[[ $r == 1 ]] && grep -q "recovery started 2 times" "$tmp/out" || fail "a start older than the window counted: $(cat "$tmp/out")"
echo garbage > "$tmp/boot_id"
jl "$boot" "$now"
stepped
[[ $r == 1 ]] && grep -q "recovery started 0 times" "$tmp/out" || fail "starts counted without a boot id: $(cat "$tmp/out")"
echo 01234567-89ab-cdef-0123-456789abcdef > "$tmp/boot_id"

padt=$libexec/microos-pad-target
dropin=$units/user/gamescope-session-plus@steam.service.d/30-microos-pad.conf
[[ $(< "$dropin") == $'[Service]\nExecStartPre=-/usr/libexec/microos/microos-pad-target deck-uhid keyboard' ]] ||
  fail "steam pad drop-in: $(cat "$dropin")"
: > "$FAKE/calls"
r=0
"$padt" deck-uhid keyboard > "$tmp/out" 2>&1 || r=$?
[[ $r == 0 ]] || fail "pad target: exit $r $(cat "$tmp/out")"
for d in 0 1; do
  has "busctl call org.shadowblip.InputPlumber /org/shadowblip/InputPlumber/CompositeDevice$d org.shadowblip.Input.CompositeDevice SetTargetDevices as 2 deck-uhid keyboard" ||
    fail "pad target not set on CompositeDevice$d: $(calls)"
done
[[ $(calls | grep -c ' SetTargetDevices ') == 2 ]] || fail "pad target touched another path: $(calls)"
! hasre '^(date|sleep)' || fail "pad target waited on a clock"
mkdir -p "$tmp/padbin"
printf '#!/usr/bin/env bash\necho "busctl $*" >> "$FAKE/calls"\n[[ $1 == tree ]] && printf "/org/shadowblip/InputPlumber/CompositeDevice0\\n/org/shadowblip/InputPlumber/CompositeDevice1\\n" && exit 0\n[[ $3 == */CompositeDevice0 ]] && exit 1\nexit 0\n' > "$tmp/padbin/busctl"
chmod 755 "$tmp/padbin/busctl"
: > "$FAKE/calls"
r=0
PATH=$tmp/padbin:$PATH "$padt" deck-uhid keyboard > "$tmp/out" 2>&1 || r=$?
[[ $r == 1 ]] || fail "pad target with a failing device: exit $r"
has "busctl call org.shadowblip.InputPlumber /org/shadowblip/InputPlumber/CompositeDevice1 org.shadowblip.Input.CompositeDevice SetTargetDevices as 2 deck-uhid keyboard" ||
  fail "pad target stopped at the failing device: $(calls)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/padbin/busctl"
r=0
PATH=$tmp/padbin:$PATH "$padt" deck-uhid keyboard > "$tmp/out" 2>&1 || r=$?
[[ $r == 0 ]] || fail "pad target without InputPlumber: exit $r"
r=0
"$padt" > /dev/null 2>&1 || r=$?
[[ $r == 2 ]] || fail "pad target without targets: exit $r"

step_up=$tmp/uptime-step
set_step() { echo "$1 0" > "$step_up.new" && mv -f "$step_up.new" "$step_up"; }
set_step 100.00
(MICROOS_UPTIME=$step_up; . "$session"; within 1 false) &
pid=$!
sleep 0.3
set_step 100.60
sleep 1.4
kill -0 "$pid" 2> /dev/null || fail "within ended at 1.7 s wall time, 0.6 s uptime"
set_step 101.01
r=0
wait "$pid" || r=$?
(( r == 1 )) || fail "within after the bound: exit $r"
exit $rc
