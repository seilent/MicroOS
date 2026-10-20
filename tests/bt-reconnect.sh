#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
daemon=$tree/usr/libexec/microos/microos-bt-reconnect
unit=$tree/usr/lib/systemd/user/microos-bt-reconnect.service
conf=$tree/etc/bluetooth/main.conf
client=$here/bt-reconnect/client.py
stubpy=$here/bt-reconnect/bluez.py
tmp=$(mktemp -d)
pids=()
stub="" d=""
cleanup() {
  local p
  for p in "${pids[@]}" $stub $d; do kill "$p" 2> /dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

for t in dbus-daemon python3; do
  command -v "$t" > /dev/null || { echo "FAIL: $t missing" >&2; exit 1; }
done
python3 -c 'import gi' || { echo "FAIL: python3-gobject missing" >&2; exit 1; }

MICROOS_TREE=$tree python3 "$here/bt-reconnect/engine.py" || fail "engine tests"

for line in Type=dbus BusName=net.seilent.MicroOs.Reconnect StartLimitIntervalSec=600 StartLimitBurst=5 \
  StateDirectory=microos-bt-reconnect WantedBy=default.target Restart=on-failure NoNewPrivileges=yes \
  RestrictAddressFamilies=AF_UNIX; do
  grep -qx "$line" "$unit" || fail "unit lacks $line"
done
if grep -nE '^(PartOf|BindsTo|After)=.*gamescope' "$unit"; then fail "unit is tied to a gamescope session"; fi
grep -qx 'Experimental = true' "$conf" || fail "main.conf lacks Experimental = true"
grep -qx 'ReconnectAttempts = 0' "$conf" || fail "main.conf lacks ReconnectAttempts = 0"
[[ $(awk '/^\[/ { s = $0 } /^ReconnectAttempts/ { print s }' "$conf") == "[Policy]" ]] || fail "ReconnectAttempts is not under [Policy]"

for b in system session; do
  cat > "$tmp/$b.conf" <<EOF
<busconfig>
  <type>$b</type>
  <listen>unix:path=$tmp/$b</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="*"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
EOF
  dbus-daemon --config-file="$tmp/$b.conf" --nofork & pids+=($!)
done
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=$tmp/system DBUS_SESSION_BUS_ADDRESS=unix:path=$tmp/session
for _ in {1..50}; do [[ -S $tmp/system && -S $tmp/session ]] && break; sleep 0.1; done
export XDG_STATE_HOME=$tmp/state
unset STATE_DIRECTORY
state=$tmp/state/microos-bt-reconnect/state.json
calls=$tmp/calls.log
dlog=$tmp/daemon.log
HEAD=/org/bluez/hci0/dev_AA_AA_AA_AA_AA_01
HEAD2=/org/bluez/hci0/dev_AA_AA_AA_AA_AA_02
PHONE=/org/bluez/hci0/dev_BB_BB_BB_BB_BB_01

st() { python3 "$client" stub "$@" > /dev/null || fail "stub $*"; }
cl() { python3 "$client" call "$@"; }
prop() { python3 "$client" get "$1"; }
waitprop() { python3 "$client" wait "$1" "$2" "${3:-5}" > /dev/null; }
n() { awk -v m="$1" -v a="${2:-AA:AA:AA:AA:AA:01}" '$2 == m && $3 == a' "$calls" 2> /dev/null | wc -l; }
stamps() { awk -v m="$1" -v a="${2:-AA:AA:AA:AA:AA:01}" '$2 == m && $3 == a { print $1 }' "$calls"; }
mono() { python3 -c 'import time; print(f"{time.monotonic():.3f}")'; }
within() { python3 -c 'import sys; v = float(sys.argv[1]); sys.exit(0 if float(sys.argv[2]) <= v <= float(sys.argv[3]) else 1)' "$@"; }
waitn() {
  local i
  for ((i = 0; i < ${4:-50}; i++)); do (( $(n "$1" "${3:-AA:AA:AA:AA:AA:01}") >= $2 )) && return 0; sleep 0.1; done
  return 1
}
waitlog() {
  for _ in {1..50}; do grep -qF -- "$1" "$dlog" 2> /dev/null && return 0; sleep 0.1; done
  return 1
}
stop_all() {
  local p
  for p in $d $stub; do kill "$p" 2> /dev/null || true; wait "$p" 2> /dev/null || true; done
  d="" stub=""
}
stub_up() {
  python3 "$stubpy" "$calls" & stub=$!
  for _ in {1..50}; do python3 "$client" stub default Connect org.bluez.Error.Failed br-connection-key-missing > /dev/null 2>&1 && break; sleep 0.1; done
  st default Disconnect ok
}
start_daemon() {
  "$daemon" 2>> "$dlog" & d=$!
  python3 "$client" wait-name 5 || fail "daemon did not own its name: $(tail -n 5 "$dlog")"
}
restart_daemon() {
  kill "$d" 2> /dev/null || true
  wait "$d" 2> /dev/null || true
  start_daemon
}
fresh() {
  stop_all
  rm -rf "$tmp/state" "$calls" "$dlog"
  mkdir -p "${state%/*}"
  [[ -n ${1:-} ]] && printf '{"target": "%s"}\n' "$1" > "$state"
  stub_up
  st own
  st adapter 1
  st device AA:AA:AA:AA:AA:01 headset 0
  st device BB:BB:BB:BB:BB:01 phone 0
  st device AA:AA:AA:AA:AA:02 headset 0
}
target() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("target"))' "$state" 2> /dev/null; }

fresh AA:AA:AA:AA:AA:01
mkfifo "$tmp/own.in"
python3 "$client" own < "$tmp/own.in" > "$tmp/own.out" & owner=$!
exec 7> "$tmp/own.in"
for _ in {1..50}; do grep -q owned "$tmp/own.out" 2> /dev/null && break; sleep 0.1; done
set +e
timeout 10 "$daemon" 2>> "$dlog"
code=$?
set -e
[[ $code == 1 ]] || fail "a second instance exited $code"
sleep 0.5
[[ ! -s $calls ]] || fail "a second instance called BlueZ: $(cat "$calls")"
exec 7>&-
kill "$owner" 2> /dev/null || true
wait "$owner" 2> /dev/null || true

fresh AA:AA:AA:AA:AA:01
start_daemon
waitn Connect 1 || fail "no boot Connect at start"
waitlog "start 1 in this boot" || fail "no start count line"
sleep 1
restart_daemon
sleep 2
[[ $(n Connect) == 1 ]] || fail "two starts 1 s apart gave $(n Connect) boot attempts"
grep -qF "start 2 in this boot, start boot run skipped" "$dlog" || fail "no throttle line"

before=$(n Connect)
st disconnected AA:AA:AA:AA:AA:01 s org.bluez.Reason.Timeout
st disconnected AA:AA:AA:AA:AA:01 sss org.bluez.Reason.Timeout
sleep 1.5
[[ $(n Connect) == "$before" ]] || fail "Disconnected s or sss started a run"
t0=$(mono)
st disconnected AA:AA:AA:AA:AA:01 ss org.bluez.Reason.Timeout
waitn Connect $((before + 1)) || fail "no Connect after Disconnected ss Timeout"
within "$(python3 -c "print($(stamps Connect | tail -n 1) - $t0)")" 0.8 1.6 || fail "loss Connect not about 1 s after the signal"

st reply Connect org.bluez.Error.InProgress -
st disconnected AA:AA:AA:AA:AA:01 ss org.bluez.Reason.Timeout
before=$(n Connect)
waitn Connect $((before + 2)) AA:AA:AA:AA:AA:01 50 || fail "no busy retry"
mapfile -t s < <(stamps Connect | tail -n 2)
within "$(python3 -c "print(${s[1]} - ${s[0]})")" 1.9 2.6 || fail "InProgress retry not 2 s later: ${s[*]}"

st reply Connect ok
st disconnected AA:AA:AA:AA:AA:01 ss org.bluez.Reason.Timeout
before=$(n Connect)
waitn Connect $((before + 1)) || fail "no Connect for the ok case"
waitprop Phase loss-a 2 || fail "Phase after ok: $(prop Phase)"
st transport fd0 AA:AA:AA:AA:AA:01 0000110a
waitprop Phase idle 2 || fail "transport after ok does not end the run: $(prop Phase)"
st untransport fd0 AA:AA:AA:AA:AA:01

[[ $(cl SetRole x) == org.freedesktop.DBus.Error.InvalidArgs ]] || fail "SetRole x not refused"
[[ $(cl SetTarget "$PHONE") == org.freedesktop.DBus.Error.InvalidArgs ]] || fail "SetTarget of a phone not refused"
[[ $(cl SetTarget /org/freedesktop/foo) == org.freedesktop.DBus.Error.InvalidArgs ]] || fail "SetTarget of a non BlueZ path not refused"
(( $(grep -c refused "$dlog") >= 3 )) || fail "refusals not logged"

before=$(n Connect)
[[ $(cl Want) == ok ]] || fail "Want"
waitn Connect $((before + 1)) || fail "Want sent no Connect"
cl Want > /dev/null
sleep 1
[[ $(n Connect) == $((before + 1)) ]] || fail "a second Want within 60 s sent a Connect"

for m in Hold Scope SetRole; do
  arg=true
  [[ $m == SetRole ]] && arg=receiver
  mkfifo "$tmp/h.$m"
  python3 "$client" holder < "$tmp/h.$m" > "$tmp/h.$m.out" & h=$!
  exec 8> "$tmp/h.$m"
  for _ in {1..50}; do [[ -s $tmp/h.$m.out ]] && break; sleep 0.1; done
  name=$(head -n 1 "$tmp/h.$m.out")
  echo "$m $arg" >&8
  for _ in {1..50}; do (( $(wc -l < "$tmp/h.$m.out") >= 2 )) && break; sleep 0.1; done
  [[ $(sed -n 2p "$tmp/h.$m.out") == ok ]] || fail "$m by a holder: $(cat "$tmp/h.$m.out")"
  [[ $m == Hold ]] && { waitprop Phase held 2 || fail "Phase under a hold: $(prop Phase)"; }
  [[ $m == SetRole ]] && { waitprop Role receiver 2 || fail "Role after a claim: $(prop Role)"; }
  exec 8>&-
  kill "$h" 2> /dev/null || true
  wait "$h" 2> /dev/null || true
  waitlog "$m of $name dropped: name gone" || fail "$m holder killed not dropped"
done
waitprop Role headphones 2 || fail "Role after the claimer left: $(prop Role)"
name=$(python3 "$client" gone Hold true) || fail "client gone Hold true"
waitlog "Hold of $name dropped: name gone" || fail "a holder gone before the check was not dropped"
waitprop Phase idle 2 || fail "Phase after the gone holder: $(prop Phase)"
hs=()
for i in 1 2 3 4 5; do
  mkfifo "$tmp/m.$i"
  python3 "$client" holder < "$tmp/m.$i" > "$tmp/m.$i.out" & hs+=($!)
  exec {fd}> "$tmp/m.$i"
  echo "Hold true" >&$fd
  for _ in {1..50}; do (( $(wc -l < "$tmp/m.$i.out") >= 2 )) && break; sleep 0.1; done
done
[[ $(sed -n 2p "$tmp/m.5.out") == org.freedesktop.DBus.Error.LimitsExceeded ]] || fail "a fifth holder: $(cat "$tmp/m.5.out")"
for h in "${hs[@]}"; do kill "$h" 2> /dev/null || true; wait "$h" 2> /dev/null || true; done
waitprop Phase idle 3 || fail "Phase after the holders left: $(prop Phase)"

before=$(n Connect)
st default Connect org.bluez.Error.Failed br-connection-page-timeout 0.1
st disconnected AA:AA:AA:AA:AA:01 ss org.bluez.Reason.Timeout
waitn Connect $((before + 1)) || fail "no loss Connect before the pause"
sleep 0.5
st prop adapter Discovering 1
waitprop Phase paused 2 || fail "Discovering does not pause: $(prop Phase)"
[[ $(prop NextAttempt) == 0 ]] || fail "NextAttempt in a pause: $(prop NextAttempt)"
sleep 2.5
[[ $(n Connect) == $((before + 1)) ]] || fail "a Connect in a pause"
st default Connect org.bluez.Error.Failed br-connection-key-missing
st prop adapter Discovering 0
waitn Connect $((before + 2)) AA:AA:AA:AA:AA:01 10 || fail "the pause end gave no attempt"
sleep 1
[[ $(n Connect) == $((before + 2)) ]] || fail "the pause end gave more than one attempt"

before=$(n Connect)
st prop adapter Powered 0
st prop adapter Powered 1
waitn Connect $((before + 1)) || fail "Powered false then true gave no boot attempt"

sleep 1
before=$(n Connect)
st sleep 1
t0=$(mono)
st sleep 0
waitn Connect $((before + 1)) AA:AA:AA:AA:AA:01 40 || fail "no attempt after resume"
within "$(python3 -c "print($(stamps Connect | tail -n 1) - $t0)")" 1.8 2.8 || fail "resume attempt not about 2 s after the thaw"

sleep 1
before=$(n Connect)
st teardown
sleep 0.5
[[ $(prop Target) == "$HEAD" ]] || fail "teardown cleared Target: $(prop Target)"
[[ $(target) == AA:AA:AA:AA:AA:01 ]] || fail "teardown changed the state file: $(cat "$state")"
[[ $(prop Phase) == notready ]] || fail "Phase without BlueZ: $(prop Phase)"
st own
sleep 1
[[ $(n Connect) == "$before" ]] || fail "a Connect before the adapter came back"
st adapter 1
st device AA:AA:AA:AA:AA:01 headset 0
waitn Connect $((before + 1)) || fail "name back then hci0 gave no boot run"
sleep 1
[[ $(n Connect) == $((before + 1)) ]] || fail "name back then hci0 gave more than one boot attempt"
sleep 4
[[ $(prop Target) == "$HEAD" ]] || fail "reconcile after the return cleared Target"

st remove AA:AA:AA:AA:AA:01
sleep 2
[[ $(prop Target) == "$HEAD" ]] || fail "a forget cleared Target before 3 s"
sleep 1.5
[[ $(prop Target) == / ]] || fail "a forget did not clear Target after 3 s: $(prop Target)"
[[ $(target) == None ]] || fail "a forget left the target in the file: $(cat "$state")"

stop_all
rm -rf "$tmp/state" "$calls"
stub_up
st own
st adapter 1
st device AA:AA:AA:AA:AA:01 headset 0
st device AA:AA:AA:AA:AA:02 headset 1
st transport fd0 AA:AA:AA:AA:AA:02 0000110a
start_daemon
sleep 9
[[ $(prop Target) == / ]] || fail "retarget before 10 s"
waitprop Target "$HEAD2" 3 || fail "a transport present at start did not retarget: $(prop Target)"
[[ $(target) == AA:AA:AA:AA:AA:02 ]] || fail "retarget not written: $(cat "$state")"
restart_daemon
[[ $(prop Target) == "$HEAD2" ]] || fail "the state file not read at a restart: $(prop Target)"
[[ $(cl SetTarget /) == ok && $(prop Target) == / && $(target) == None ]] || fail "SetTarget / does not clear"

st disown
sleep 0.3
[[ $(cl SetTarget /org/bluez/hci0/dev_DD_DD_DD_DD_DD_01) == ok ]] || fail "SetTarget while BlueZ is down refused"
[[ $(prop Target) == /org/bluez/hci0/dev_DD_DD_DD_DD_DD_01 ]] || fail "SetTarget while BlueZ is down not stored"
st own
sleep 6
[[ $(prop Target) == / ]] || fail "an unknown target not dropped at the return: $(prop Target)"
st disown
sleep 0.3
[[ $(cl SetTarget "$HEAD") == ok ]] || fail "SetTarget of a known headset while BlueZ is down"
st own
sleep 6
[[ $(prop Target) == "$HEAD" ]] || fail "a valid target dropped at the return: $(prop Target)"

fresh
printf '{"phone": "BB:BB:BB:BB:BB:01"}\n' > "$state"
st prop BB:BB:BB:BB:BB:01 Connected 1
st default ConnectProfile ok
st default DisconnectProfile ok
start_daemon
P=BB:BB:BB:BB:BB:01
mkfifo "$tmp/r.in"
python3 "$client" holder < "$tmp/r.in" > "$tmp/r.out" & pids+=($!)
exec 9> "$tmp/r.in"
claim() {
  local before
  before=$(wc -l < "$tmp/r.out")
  printf '%s\n' "$@" >&9
  for _ in {1..50}; do (( $(wc -l < "$tmp/r.out") >= before + $# )) && break; sleep 0.1; done
}
claim "SetRole receiver" "Scope true"
waitprop Role receiver 2 || fail "receiver claim: $(prop Role)"
st disconnected $P ss org.bluez.Reason.Timeout
waitn ConnectProfile 1 $P || fail "no ConnectProfile to the phone"
[[ $(awk -v a=$P '$2 == "ConnectProfile" && $3 == a { print $4 }' "$calls") == 0000110c-0000-1000-8000-00805f9b34fb ]] \
  || fail "ConnectProfile not 0000110c: $(cat "$calls")"
waitn DisconnectProfile 1 $P 120 || fail "no DisconnectProfile without A2DP"
mapfile -t a < <(stamps ConnectProfile $P)
mapfile -t b < <(stamps DisconnectProfile $P)
within "$(python3 -c "print(${b[0]} - ${a[0]})")" 9.8 11.0 || fail "DisconnectProfile not 10 s after the ok: ${a[*]} ${b[*]}"
[[ $(awk -v a=$P '$2 == "DisconnectProfile" && $3 == a { print $4 }' "$calls") == 0000110c-0000-1000-8000-00805f9b34fb ]] \
  || fail "DisconnectProfile not 0000110c"
[[ $(n Connect $P) == 0 && $(n Disconnect $P) == 0 ]] || fail "Connect or Disconnect sent to the phone"
grep -qF "oui BB:BB:BB" "$dlog" || fail "no OUI line"

claim "Scope false" "Scope true"
st disconnected $P ss org.bluez.Reason.Timeout
waitn ConnectProfile 2 $P || fail "no ConnectProfile after a new scope edge"
sleep 3
restart_daemon
waitn DisconnectProfile 2 $P 120 || fail "no DisconnectProfile after a restart inside the window"
mapfile -t a < <(stamps ConnectProfile $P)
mapfile -t b < <(stamps DisconnectProfile $P)
within "$(python3 -c "print(${b[1]} - ${a[1]})")" 9.5 11.5 || fail "restart: DisconnectProfile not at until: ${a[*]} ${b[*]}"

claim "SetRole receiver" "Scope true"
st disconnected $P ss org.bluez.Reason.Timeout
waitn ConnectProfile 3 $P || fail "no ConnectProfile for the A2DP case"
sleep 1
st transport fd1 $P 0000110b
waitprop Phase idle 3 || fail "a phone transport does not end the receiver run: $(prop Phase)"
sleep 10
[[ $(n DisconnectProfile $P) == 2 ]] || fail "DisconnectProfile with A2DP up"
exec 9>&-

stop_all
(( rc == 0 )) && echo "bt-reconnect: ok"
exit $rc
