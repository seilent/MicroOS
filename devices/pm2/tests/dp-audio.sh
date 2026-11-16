#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
hook=$tree/usr/libexec/microos/microos-dp-audio
service=$tree/usr/libexec/microos/microos-dp-audio-sleep
rules=$tree/usr/lib/udev/rules.d/70-microos-dp-audio.rules
tmp=$(mktemp -d)
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

for f in "$hook" "$service"; do
  [[ -x $f ]] || fail "${f#"$tree"} is not executable"
done

root=$tmp/root
run_dir=$tmp/run
connector=$root/sys/class/drm/card0-DP-1/status
flag=$run_dir/dp-audio
marker=$run_dir/dp-audio.sleeping
lock=$run_dir/lock/dp-audio
route='name=DISPLAY_PORT_RX Audio Mixer MultiMedia4'
export STUB_DIR=$tmp/stub STUB_LOG=$tmp/log STUB_FLAG=$flag STUB_PCM=$root/proc/asound/PocketMICRO2/pcm3p/sub0/status
export MICROOS_DP_ROOT=$root MICROOS_RUN_DIR=$run_dir MICROOS_DP_SETTLE=0 MICROOS_DP_RETRY=0.01
stubpath=$here/dp-audio:$PATH

reset() {
  rm -rf "$root" "$run_dir" "$STUB_DIR"
  mkdir -p "${connector%/*}" "${STUB_PCM%/*}" "$run_dir/lock" "$STUB_DIR"
  ln -s /proc/uptime "$root/proc/uptime"
  echo "$1" > "$connector"
  echo closed > "$STUB_PCM"
  : > "$STUB_LOG"
}
run() {
  local r=0
  PATH=$stubpath bash "$hook" "$@" 2> "$tmp/err" || r=$?
  return "$r"
}
plays() { cat "$STUB_DIR/aplay.n" 2> /dev/null || echo 0; }
last_route() { grep '^amixer' "$STUB_LOG" | tail -1; }
logged() { grep -qF "$1" "$tmp/err"; }
on() { echo "$2" > "$STUB_DIR/on-$1"; }

reset connected
run hotplug || fail "ready on try 1: exit $?"
[[ -f $flag && ! -L $flag && $(stat -c %a "$flag") == 644 ]] || fail "ready on try 1: no 0644 flag"
[[ $(plays) == 1 ]] || fail "ready on try 1: $(plays) plays"
grep -qxF "amixer -q -D hw:PocketMICRO2 cset $route 1|flag=absent|pcm=closed" "$STUB_LOG" || fail "route not set: $(cat "$STUB_LOG")"
grep -qxF 'aplay -q -D hw:CARD=PocketMICRO2,DEV=3 -t raw -f S16_LE -r 48000 -c 2 -d 1 /dev/zero' "$STUB_LOG" ||
  fail "aplay arguments: $(grep aplay "$STUB_LOG")"
logged "DP audio ready (try 1)" || fail "ready on try 1 not logged: $(cat "$tmp/err")"
: > "$STUB_LOG"
run hotplug || fail "second run with the flag: exit $?"
[[ ! -s $STUB_LOG && $(plays) == 1 ]] || fail "second run with the flag acted: $(cat "$STUB_LOG")"

reset connected
echo 3 > "$STUB_DIR/ready"
run hotplug || fail "ready on try 3: exit $?"
[[ -f $flag && $(plays) == 3 ]] || fail "ready on try 3: flag $([[ -e $flag ]] && echo set || echo absent), $(plays) plays"
logged "try 2 failed: aplay: main:850: audio open error: Invalid argument" || fail "failed try not logged: $(cat "$tmp/err")"
logged "DP audio ready (try 3)" || fail "ready on try 3 not logged"

reset connected
echo never > "$STUB_DIR/ready"
run hotplug || fail "never ready: exit $?"
[[ ! -e $flag && $(plays) == 18 ]] || fail "never ready: $(plays) plays, flag $([[ -e $flag ]] && echo set || echo absent)"
[[ $(last_route) == "amixer -q -D hw:PocketMICRO2 cset $route 0|flag=absent|pcm=closed" ]] || fail "never ready left the route: $(last_route)"
logged "never became ready after 18 tries" || fail "give up not logged"

reset connected
echo never > "$STUB_DIR/ready"
on 2 "echo disconnected > $connector"
run hotplug || fail "unplug in the retry loop: exit $?"
[[ ! -e $flag && $(plays) == 2 ]] || fail "unplug in the retry loop: $(plays) plays"
[[ $(last_route) == *" 0|flag=absent|pcm=closed" ]] || fail "unplug in the retry loop left the route: $(last_route)"

reset connected
on 1 "echo disconnected > $connector"
run hotplug || fail "plug then unplug: exit $?"
[[ ! -e $flag ]] || fail "plug then unplug during the run left the flag"
[[ $(last_route) == *" 0|flag=absent|pcm=closed" ]] || fail "plug then unplug left the route: $(last_route)"
logged "changed during the run" || fail "state change not logged: $(cat "$tmp/err")"

reset connected
echo never > "$STUB_DIR/ready"
on 2 "touch $marker"
run hotplug || fail "marker in the retry loop: exit $?"
[[ ! -e $flag && $(plays) == 2 ]] || fail "marker in the retry loop: $(plays) plays"

reset disconnected
: > "$flag"
echo RUNNING > "$STUB_PCM"
(sleep 0.3; echo closed > "$STUB_PCM") &
start=$(date +%s%N)
run hotplug || fail "unplug: exit $?"
elapsed=$((($(date +%s%N) - start) / 1000000))
[[ ! -e $flag ]] || fail "unplug kept the flag"
[[ $(grep -c '^amixer' "$STUB_LOG") == 1 && $(last_route) == "amixer -q -D hw:PocketMICRO2 cset $route 0|flag=absent|pcm=closed" ]] ||
  fail "unplug: route not cleared after the flag and closed pcm: $(cat "$STUB_LOG")"
((elapsed >= 300)) || fail "unplug did not wait for closed ($elapsed ms)"
[[ $(plays) == 0 ]] || fail "unplug played"

reset disconnected
echo RUNNING > "$STUB_PCM"
start=$(date +%s%N)
run hotplug || fail "pcm never closes: exit $?"
elapsed=$((($(date +%s%N) - start) / 1000000))
((elapsed >= 1400 && elapsed < 2500)) || fail "pcm never closes: route cleared after $elapsed ms"
[[ $(last_route) == *" 0|flag=absent|pcm=RUNNING" ]] || fail "pcm never closes: $(last_route)"
logged "still open after 1.5 s" || fail "open pcm not logged"

reset disconnected
echo RUNNING > "$STUB_PCM"
echo "100.00 0.00" > "$root/proc/uptime.new"
mv -f "$root/proc/uptime.new" "$root/proc/uptime"
PATH=$stubpath bash "$hook" hotplug 2> "$tmp/err" &
pid=$!
sleep 0.3
echo "100.60 0.00" > "$root/proc/uptime.new"
mv -f "$root/proc/uptime.new" "$root/proc/uptime"
sleep 1.6
kill -0 "$pid" 2> /dev/null || fail "clock step: closed wait ended at 1.9 s wall time, 0.6 s uptime"
echo "101.51 0.00" > "$root/proc/uptime.new"
mv -f "$root/proc/uptime.new" "$root/proc/uptime"
r=0
wait "$pid" || r=$?
((r == 0)) || fail "clock step: exit $r"
[[ $(last_route) == *" 0|flag=absent|pcm=RUNNING" ]] || fail "clock step: $(last_route)"

reset connected
mkdir "$flag"
run hotplug || fail "flag write fails: exit $?"
[[ $(plays) == 1 ]] || fail "flag write fails: $(plays) plays"
[[ $(last_route) == *" 0|flag=present|pcm=closed" ]] || fail "flag write fails left the route: $(last_route)"
logged "failed, clearing the route" || fail "flag write failure not logged: $(cat "$tmp/err")"

reset connected
echo "100.00 0.00" > "$root/proc/uptime.new"
mv -f "$root/proc/uptime.new" "$root/proc/uptime"
(sleep 0.1; echo "100.01 0.00" > "$root/proc/uptime.new"; mv -f "$root/proc/uptime.new" "$root/proc/uptime") &
MICROOS_DP_DEADLINE=0 MICROOS_DP_SETTLE=0.4 run hotplug || fail "deadline: exit $?"
[[ ! -e $flag && $(plays) == 0 ]] || fail "deadline: $(plays) plays"
[[ $(last_route) == *" 0|flag=absent|pcm=closed" ]] || fail "deadline left the route: $(last_route)"
logged "not ready 0 s after the run started" || fail "deadline not logged: $(cat "$tmp/err")"

reset connected
: > "$marker"
run hotplug || fail "marker: exit $?"
[[ ! -s $STUB_LOG && ! -e $flag ]] || fail "hotplug ran under the marker: $(cat "$STUB_LOG")"

reset connected
rm -rf "$root/proc/asound/PocketMICRO2"
run hotplug || fail "no card: exit $?"
[[ ! -s $STUB_LOG && ! -e $flag ]] || fail "hotplug ran without the card: $(cat "$STUB_LOG")"

reset connected
: > "$STUB_DIR/hang"
echo RUNNING > "$STUB_PCM"
PATH=$stubpath bash "$hook" hotplug 2> "$tmp/hotplug.err" &
unit=$!
pids+=("$unit")
echo "$unit" > "$STUB_DIR/unit.pid"
for _ in {1..50}; do [[ -s $STUB_DIR/aplay.pid ]] && break; sleep 0.1; done
aplay_pid=$(cat "$STUB_DIR/aplay.pid" 2> /dev/null || true)
[[ -n $aplay_pid ]] || fail "sleep: hotplug never reached aplay"
start=$(date +%s%N)
run sleep || fail "sleep: exit $?"
elapsed=$((($(date +%s%N) - start) / 1000000))
wait "$unit" 2> /dev/null || true
[[ -f $marker && ! -L $marker ]] || fail "sleep wrote no marker"
grep -qxF 'systemctl stop microos-dp-audio-hotplug-*.service' "$STUB_LOG" || fail "sleep did not stop the hotplug units: $(cat "$STUB_LOG")"
if [[ -z $aplay_pid ]] || kill -0 "$aplay_pid" 2> /dev/null; then fail "sleep left aplay running"; fi
awk '/^stopped$/ { s = NR } /^amixer/ { a = NR } END { exit !(s && a > s) }' "$STUB_LOG" ||
  fail "route cleared before the hotplug run was stopped: $(cat "$STUB_LOG")"
[[ $(last_route) == *" 0|flag=absent|pcm=closed" ]] || fail "sleep did not wait for closed: $(last_route)"
((elapsed >= 500 && elapsed < 4000)) || fail "sleep took $elapsed ms"
rm -f "$STUB_DIR/hang" "$STUB_DIR/unit.pid" "$STUB_DIR/aplay.pid"
: > "$STUB_LOG"
run hotplug || fail "hotplug after sleep: exit $?"
[[ ! -s $STUB_LOG && ! -e $flag ]] || fail "hotplug after sleep acted: $(cat "$STUB_LOG")"

echo 0 > "$STUB_DIR/aplay.n"
run resume || fail "resume: exit $?"
[[ ! -e $marker ]] || fail "resume left the marker"
[[ -f $flag && $(plays) == 1 ]] || fail "resume did not retest: $(plays) plays"

reset connected
: > "$tmp/victim"
ln -s "$tmp/victim" "$flag"
run hotplug || fail "planted flag: exit $?"
[[ -f $flag && ! -L $flag && ! -s $tmp/victim ]] || fail "planted flag symlink was followed"
echo keep > "$tmp/victim"
ln -sfn "$tmp/victim" "$flag"
echo disconnected > "$connector"
run hotplug || fail "planted flag on unplug: exit $?"
[[ ! -e $flag && ! -L $flag && $(cat "$tmp/victim") == keep ]] || fail "unplug followed the planted flag"
ln -s "$tmp/victim" "$marker"
run sleep || fail "planted marker: exit $?"
[[ -f $marker && ! -L $marker && $(cat "$tmp/victim") == keep ]] || fail "sleep followed the planted marker"
reset connected
ln -s "$tmp/lock-victim" "$lock"
if run hotplug; then fail "planted lock symlink accepted"; fi
[[ ! -e $tmp/lock-victim && ! -s $STUB_LOG ]] || fail "planted lock symlink was followed"
logged "is a symlink" || fail "planted lock not logged"

reset connected
flock "$lock" sleep 3 &
holder=$!
pids+=("$holder")
for _ in {1..20}; do flock -n "$lock" true 2> /dev/null || break; sleep 0.05; done
MICROOS_DP_LOCK_WAIT=0.5 run hotplug || fail "busy lock: exit $?"
[[ ! -s $STUB_LOG ]] || fail "busy lock ran anyway: $(cat "$STUB_LOG")"
logged "held for 0.5 s" || fail "busy lock not logged: $(cat "$tmp/err")"
kill "$holder" 2> /dev/null || true
wait "$holder" 2> /dev/null || true

reset connected
: > "$flag"
echo RUNNING > "$STUB_PCM"
: > "$STUB_DIR/systemctl-hang"
on stop "rm -f $marker"
start=$(date +%s%N)
run sleep || fail "hanging stop: exit $?"
elapsed=$((($(date +%s%N) - start) / 1000000))
((elapsed < 3800)) || fail "hanging stop: route cleared after $elapsed ms"
[[ $(last_route) == *" 0|flag=absent|pcm=RUNNING" ]] || fail "hanging stop left the route: $(last_route)"
logged "stopping microos-dp-audio-hotplug-*.service failed" || fail "hanging stop not logged: $(cat "$tmp/err")"
logged "still open after 1.5 s" || fail "hanging stop: open pcm not logged"
[[ -f $marker && ! -L $marker ]] || fail "a run removing the marker during the stop left it removed"

if run bogus; then fail "unknown verb accepted"; fi

if command -v udevadm > /dev/null; then
  udevadm verify --no-summary "$rules" || fail "dp audio rules do not verify"
else
  fail "udevadm missing, dp audio rules unchecked"
fi
cmd='RUN+="/usr/bin/systemd-run --no-block --collect --unit=microos-dp-audio-hotplug-$env{SEQNUM} -p RuntimeMaxSec=240 -p TimeoutStopSec=2 /usr/libexec/microos/microos-dp-audio hotplug"'
grep -qxF "ACTION==\"change\", SUBSYSTEM==\"drm\", KERNEL==\"card0\", $cmd" "$rules" || fail "no card0 change rule"
grep -qxF "ACTION==\"add\", SUBSYSTEM==\"sound\", KERNEL==\"card*\", ATTR{id}==\"PocketMICRO2\", $cmd" "$rules" || fail "no sound card add rule"
! grep -q HOTPLUG "$rules" || fail "rules match HOTPLUG"
! grep -q SYSTEMD_WANTS "$rules" || fail "rules use SYSTEMD_WANTS"

for t in dbus-daemon python3; do
  command -v "$t" > /dev/null || { echo "FAIL: $t missing" >&2; exit 1; }
done
cat > "$tmp/bus.conf" << EOF
<busconfig>
  <type>system</type>
  <listen>unix:path=$tmp/bus</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="*"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
EOF
dbus-daemon --config-file="$tmp/bus.conf" --nofork & pids+=($!)
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=$tmp/bus
for _ in {1..50}; do [[ -S $tmp/bus ]] && break; sleep 0.1; done

reset disconnected
export STUB_LOG=$STUB_DIR/logind.log
python3 "$here/hotkeyd/logind-stub" "$STUB_LOG" & pids+=($!)
waitfor() {
  for _ in {1..50}; do grep -qxE "$1" "$STUB_LOG" 2> /dev/null && return 0; sleep 0.1; done
  return 1
}
waitfor ready || fail "logind stub did not start"
sleep_signal() {
  python3 - "$1" << 'EOF'
import sys
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib
Gio.bus_get_sync(Gio.BusType.SYSTEM, None).call_sync(
    "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager",
    "EmitPrepareForSleep", GLib.Variant("(b)", (sys.argv[1] == "true",)), None, Gio.DBusCallFlags.NONE, -1, None)
EOF
}
after() { awk -v a="$1" -v b="$2" '$0 ~ a && !x { x = NR } $0 ~ b && x && NR > x { y = 1 } END { exit !y }' "$STUB_LOG"; }
stub_hook=$here/dp-audio/microos-dp-audio
resume_run="systemd-run --no-block --collect --unit=microos-dp-audio-hotplug-resume-[0-9]+ -p RuntimeMaxSec=240 -p TimeoutStopSec=2 $stub_hook resume"

MICROOS_DP_HOOK=$stub_hook PATH=$stubpath python3 "$service" 2> "$tmp/service.err" & svc=$!
pids+=("$svc")
waitfor "inhibit sleep delay" || fail "no sleep delay inhibitor: $(cat "$STUB_LOG")"
waitfor "$resume_run" || fail "no resume run at start: $(cat "$STUB_LOG")"

: > "$STUB_LOG"
sleep_signal true
waitfor "release sleep delay" || fail "sleep delay inhibitor kept across sleep"
after "^hook sleep$" "^release sleep delay$" || fail "inhibitor released before the sleep verb: $(cat "$STUB_LOG")"
! grep -q '^systemd-run' "$STUB_LOG" || fail "resume started on sleep"

: > "$STUB_LOG"
sleep_signal false
waitfor "$resume_run" || fail "no resume run after wake: $(cat "$STUB_LOG")"
after "^inhibit sleep delay$" "^systemd-run " || fail "resume started before the inhibitor: $(cat "$STUB_LOG")"
! grep -q '^hook' "$STUB_LOG" || fail "the hook ran inline on wake: $(cat "$STUB_LOG")"

: > "$STUB_DIR/hook-hang"
: > "$STUB_LOG"
start=$(date +%s%N)
sleep_signal true
waitfor "release sleep delay" || fail "a hanging sleep verb kept the inhibitor"
elapsed=$((($(date +%s%N) - start) / 1000000))
((elapsed >= 3900 && elapsed < 5000)) || fail "a hanging sleep verb released after $elapsed ms"
rm -f "$STUB_DIR/hook-hang"
kill -0 "$svc" 2> /dev/null || fail "dp audio sleep died: $(cat "$tmp/service.err")"

if (( rc == 0 )); then
  echo "dp-audio: ok"
fi
exit "$rc"
