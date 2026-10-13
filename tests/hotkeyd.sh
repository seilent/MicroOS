#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
hotkeyd=$tree/usr/libexec/microos/microos-hotkeyd
tmp=$(mktemp -d)
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

for t in dbus-daemon python3; do
  command -v "$t" > /dev/null || { echo "FAIL: $t missing" >&2; exit 1; }
done
python3 -c 'import evdev, gi' || { echo "FAIL: python3-evdev or python3-gobject missing" >&2; exit 1; }

cat > "$tmp/bus.conf" <<EOF
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

mkdir -p "$tmp/bin" "$tmp/home/.steam"
cat > "$tmp/bin/steam" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/steam.log"
EOF
chmod +x "$tmp/bin/steam"
mkfifo "$tmp/home/.steam/steam.pipe"
exec 4<> "$tmp/home/.steam/steam.pipe"

waitfor() {
  for _ in {1..50}; do grep -qx "$2" "$1" 2> /dev/null && return 0; sleep 0.1; done
  return 1
}
uris() { cat "$tmp/steam.log" 2> /dev/null || true; }

stub=
hk=
boot() {
  [[ -n $hk ]] && { kill "$hk" 2> /dev/null || true; wait "$hk" 2> /dev/null || true; }
  [[ -n $stub ]] && { kill "$stub" 2> /dev/null || true; wait "$stub" 2> /dev/null || true; }
  [[ -n ${KEYS_PID:-} ]] && { kill "$KEYS_PID" 2> /dev/null || true; wait "$KEYS_PID" 2> /dev/null || true; }
  rm -f "$tmp/logind.log" "$tmp/steam.log" "$tmp/events"
  mkfifo "$tmp/events"
  exec 3<> "$tmp/events"
  STUB_DENY=${1:-} python3 "$here/hotkeyd/logind-stub" "$tmp/logind.log" 3<&- 4<&- & stub=$!
  pids+=("$stub")
  waitfor "$tmp/logind.log" ready || fail "logind stub did not start"
  coproc KEYS { exec python3 "$here/hotkeyd/keys" "$tmp/events" 3<&- 4<&-; }
  pids+=("$KEYS_PID")
  HOME=$tmp/home MICROOS_HOTKEYD_EVENTS=$tmp/events MICROOS_HOTKEYD_STEAM=$tmp/bin/steam \
    python3 "$hotkeyd" 2> "$tmp/hotkeyd.err" 3<&- 4<&- & hk=$!
  pids+=("$hk")
}

k() {
  local reply=
  echo "$*" >&"${KEYS[1]}"
  read -r -t 15 reply <&"${KEYS[0]}" || true
  [[ $reply == ok ]] || fail "key writer on '$*': $reply"
}

press() { k down wait:0.1 up wait:0.3; }

boot handle-power-key:handle-suspend-key
r=0
timeout 5 tail --pid="$hk" -f /dev/null || r=$?
(( r == 0 )) || fail "hotkeyd still running with Inhibit denied"
wait "$hk" && fail "hotkeyd exit 0 with Inhibit denied" || true
hk=
grep -q "inhibit failed" "$tmp/hotkeyd.err" || fail "no inhibit line: $(cat "$tmp/hotkeyd.err")"
(( $(wc -l < "$tmp/hotkeyd.err") == 1 )) || fail "more than one line on a denied Inhibit: $(cat "$tmp/hotkeyd.err")"

boot sleep
waitfor "$tmp/logind.log" "inhibit handle-power-key:handle-suspend-key block" || fail "no block inhibitor with the delay denied"
press
[[ $(uris) == "-ifrunning steam://shortpowerpress" ]] || fail "short press with the delay denied: $(uris)"
grep -q "sleep inhibitor failed" "$tmp/hotkeyd.err" || fail "no sleep inhibitor line: $(cat "$tmp/hotkeyd.err")"
kill -0 "$hk" 2> /dev/null || fail "hotkeyd exited with the delay denied: $(cat "$tmp/hotkeyd.err")"

boot
waitfor "$tmp/logind.log" "inhibit sleep delay" || fail "no sleep delay inhibitor: $(cat "$tmp/logind.log")"
grep -qx "inhibit handle-power-key:handle-suspend-key block" "$tmp/logind.log" || fail "no block inhibitor"

press
[[ $(uris) == "-ifrunning steam://shortpowerpress" ]] || fail "short press: $(uris)"

rm -f "$tmp/steam.log"
k down wait:0.8
[[ -z $(uris) ]] || fail "long press fired before 1000 ms: $(uris)"
k wait:0.5
[[ $(uris) == "-ifrunning steam://longpowerpress" ]] || fail "long press while held: $(uris)"
k up wait:0.3
[[ $(uris) == "-ifrunning steam://longpowerpress" ]] || fail "release after a long press: $(uris)"

rm -f "$tmp/steam.log"
k down repeat repeat wait:0.1 repeat up wait:0.3
[[ $(uris) == "-ifrunning steam://shortpowerpress" ]] || fail "repeats: $(uris)"

rm -f "$tmp/steam.log"
k sleep:true
waitfor "$tmp/logind.log" "release sleep delay" || fail "sleep delay inhibitor kept across sleep"
k wait:0.2 down wait:0.05 sleep:false up wait:0.3
[[ -z $(uris) ]] || fail "key down before (false): $(uris)"
(( $(grep -cx "inhibit sleep delay" "$tmp/logind.log") == 2 )) || fail "sleep delay inhibitor not taken again"

k sleep:true sleep:false wait:0.5
press
[[ -z $(uris) ]] || fail "key down 500 ms after (false): $(uris)"

k wait:1.5
press
[[ $(uris) == "-ifrunning steam://shortpowerpress" ]] || fail "key down 2000 ms after (false): $(uris)"

rm -f "$tmp/steam.log"
k down wait:0.1 sleep:true up wait:1.3
[[ -z $(uris) ]] || fail "(true) after the key down: $(uris)"
k sleep:false wait:1.6

k down wait:0.1 sleep:true sleep:false wait:1.6 up wait:0.3
[[ -z $(uris) ]] || fail "a press held across a sleep: $(uris)"

exec 4<&-
press
[[ -z $(uris) ]] || fail "URI with the client down: $(uris)"
grep -qx suspend "$tmp/logind.log" || fail "no Suspend with the client down: $(cat "$tmp/logind.log")"

kill -0 "$hk" 2> /dev/null || fail "hotkeyd died: $(cat "$tmp/hotkeyd.err")"

if (( rc == 0 )); then
  echo "hotkeyd: ok"
fi
exit $rc
