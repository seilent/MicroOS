#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
hook=$tree/usr/lib/systemd/system-sleep/microos-sdw-sleep
wake=$tree/usr/lib/systemd/system-sleep/microos-wake-reason
audio=$tree/usr/libexec/microos/microos-audio-sleep
tmp=$(mktemp -d)
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

for f in "$hook" "$wake" "$audio"; do
  [[ -x $f ]] || fail "${f#"$tree"} is not executable"
done

sdw=$tmp/sdw
run_dir=$tmp/run
state=$run_dir/sdw-sleep
for dev in sdw:2:0:0217:010d:00:4 sdw:3:0:0217:010d:00:3 sdw:1:0:0217:2010:00:1; do
  mkdir -p "$sdw/$dev/power"
  echo on > "$sdw/$dev/power/control"
  echo suspended > "$sdw/$dev/power/runtime_status"
done
echo auto > "$sdw/sdw:1:0:0217:2010:00:1/power/control"
run_hook() { MICROOS_SDW_ROOT=$sdw MICROOS_RUN_DIR=$run_dir bash "$hook" "$@" 2> "$tmp/hook.log"; }
control() { cat "$sdw/$1/power/control"; }

run_hook pre suspend
[[ $(control sdw:2:0:0217:010d:00:4) == auto && $(control sdw:3:0:0217:010d:00:3) == auto ]] ||
  fail "pre suspend did not release the WCD slaves"
[[ $(control sdw:1:0:0217:2010:00:1) == auto ]] || fail "pre suspend touched the WSA slave"
[[ $(wc -l < "$state" 2> /dev/null) == 2 ]] || fail "state does not hold the two WCD slaves"
run_hook post suspend
[[ $(control sdw:2:0:0217:010d:00:4) == on && $(control sdw:3:0:0217:010d:00:3) == on ]] ||
  fail "post suspend did not pin the WCD slaves"
[[ $(control sdw:1:0:0217:2010:00:1) == auto ]] || fail "post suspend touched the WSA slave"
[[ ! -e $state ]] || fail "state left after post"

echo auto > "$sdw/sdw:3:0:0217:010d:00:3/power/control"
run_hook pre suspend
[[ $(cat "$state" 2> /dev/null) == "$sdw/sdw:2:0:0217:010d:00:4" ]] || fail "an auto slave was recorded"
run_hook post suspend
[[ $(control sdw:2:0:0217:010d:00:4) == on ]] || fail "the on slave was not restored"
[[ $(control sdw:3:0:0217:010d:00:3) == auto ]] || fail "the auto slave was pinned"
echo on > "$sdw/sdw:3:0:0217:010d:00:3/power/control"

run_hook pre hibernate
[[ ! -e $state && $(control sdw:2:0:0217:010d:00:4) == on ]] || fail "pre hibernate acted"
for verb in suspend-then-hibernate hybrid-sleep; do
  run_hook pre "$verb"
  [[ $(control sdw:2:0:0217:010d:00:4) == auto ]] || fail "pre $verb did not release"
  run_hook post "$verb"
  [[ $(control sdw:2:0:0217:010d:00:4) == on ]] || fail "post $verb did not pin"
done
run_hook post suspend
[[ $(control sdw:2:0:0217:010d:00:4) == on ]] || fail "post without pre changed a slave"

echo active > "$sdw/sdw:2:0:0217:010d:00:4/power/runtime_status"
start=$(date +%s%N)
run_hook pre suspend
elapsed=$((($(date +%s%N) - start) / 1000000))
((elapsed >= 900 && elapsed < 3000)) || fail "wait for a busy slave took $elapsed ms"
run_hook post suspend

mkdir -p "$tmp/wake/sys/power" "$tmp/wake/proc"
echo 172 > "$tmp/wake/sys/power/pm_wakeup_irq"
cat > "$tmp/wake/proc/interrupts" << 'EOF'
           CPU0       CPU1
  17:        210          0     GICv3  27 Level     arch_timer
 172:          3          0  pmic_arb 13 Edge      pm8941_pwrkey
EOF
out=$(MICROOS_WAKE_ROOT=$tmp/wake "$wake" post suspend)
[[ $out == "microos-wake-reason: irq 172 pmic_arb 13 Edge pm8941_pwrkey" ]] || fail "wake reason: $out"
[[ -z $(MICROOS_WAKE_ROOT=$tmp/wake "$wake" pre suspend) ]] || fail "wake reason printed on pre"
rm "$tmp/wake/sys/power/pm_wakeup_irq"
[[ $(MICROOS_WAKE_ROOT=$tmp/wake "$wake" post suspend) == "microos-wake-reason: no wakeup irq" ]] ||
  fail "wake reason without pm_wakeup_irq"

if command -v udevadm > /dev/null; then
  udevadm verify --no-summary "$tree/usr/lib/udev/rules.d/60-microos-pad-wakeup.rules" || fail "pad wakeup rules do not verify"
else
  fail "udevadm missing, pad wakeup rules unchecked"
fi

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

export STUB_DIR=$tmp/stub
mkdir -p "$STUB_DIR"
log=$STUB_DIR/logind.log
python3 "$here/hotkeyd/logind-stub" "$log" & pids+=($!)
waitfor() {
  for _ in {1..50}; do grep -qx "$1" "$log" 2> /dev/null && return 0; sleep 0.1; done
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
after() { awk -v a="$1" -v b="$2" '$0 == a && !x { x = NR } $0 == b && x && NR > x { y = 1 } END { exit !y }' "$log"; }
profile() { cat "$STUB_DIR/profile"; }

echo off > "$STUB_DIR/profile"
PATH=$here/sleep:$PATH python3 "$audio" 2> "$tmp/audio.err" & as=$!
pids+=("$as")
waitfor "inhibit sleep delay" || fail "no sleep delay inhibitor: $(cat "$log")"
[[ $(profile) == HiFi ]] || fail "card off at start ends $(profile)"

sleep_signal true
waitfor "release sleep delay" || fail "sleep delay inhibitor kept across sleep"
[[ $(profile) == off ]] || fail "card $(profile) before sleep"
after "pactl off" "release sleep delay" || fail "inhibitor released before the card was off: $(cat "$log")"

: > "$log"
sleep_signal false
for _ in {1..50}; do [[ $(profile) == HiFi ]] && break; sleep 0.1; done
[[ $(profile) == HiFi ]] || fail "card $(profile) after wake"
after "inhibit sleep delay" "pactl HiFi" || fail "profile restored before the inhibitor was taken: $(cat "$log")"

: > "$STUB_DIR/hang"
start=$(date +%s%N)
sleep_signal true
waitfor "release sleep delay" || fail "a hanging pactl kept the inhibitor"
elapsed=$((($(date +%s%N) - start) / 1000000))
((elapsed >= 2900 && elapsed < 4500)) || fail "a hanging pactl released after $elapsed ms"
hang=$(cat "$STUB_DIR/hang.pid" 2> /dev/null || true)
[[ -n $hang ]] && ! kill -0 "$hang" 2> /dev/null || fail "the hanging pactl was not killed"
rm -f "$STUB_DIR/hang"

hung() {
  : > "$log"
  sleep_signal false
  waitfor "inhibit sleep delay" || fail "$1: no inhibitor after wake"
  : > "$log"
  rm -f "$STUB_DIR/hang.pid"
  touch "${@:2}"
  start=$(date +%s%N)
  sleep_signal true
  waitfor "release sleep delay" || fail "$1: the inhibitor was kept"
  elapsed=$((($(date +%s%N) - start) / 1000000))
  ((elapsed >= 2900 && elapsed < 4500)) || fail "$1: released after $elapsed ms"
  rm -f "${@:2}"
}
hung "a slow list and a hanging set" "$STUB_DIR/slow-list" "$STUB_DIR/hang"
hung "a hanging list" "$STUB_DIR/hang-list"
hang=$(cat "$STUB_DIR/hang.pid" 2> /dev/null || true)
[[ -n $hang ]] && ! kill -0 "$hang" 2> /dev/null || fail "the hanging list was not killed"
kill -0 "$as" 2> /dev/null || fail "audio sleep died: $(cat "$tmp/audio.err")"

if (( rc == 0 )); then
  echo "sleep: ok"
fi
exit $rc
