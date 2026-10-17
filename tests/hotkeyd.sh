#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
hotkeyd=$tree/usr/libexec/microos/microos-hotkeyd
tables=$tree/usr/lib/microos/hotkeys.d
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

mkdir -p "$tmp/bin" "$tmp/home/.steam" "$tmp/input" "$tmp/t/t.conf.d" "$tmp/g" "$tmp/sd" "$tmp/units"
for t in steam systemctl microos-session wpctl; do
  cat > "$tmp/bin/$t" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$t \$*" >> "$tmp/calls.log"
EOF
  chmod +x "$tmp/bin/$t"
done
export PATH=$tmp/bin:$PATH
nodes=(pm8941_pwrkey "InputPlumber Keyboard" "InputPlumber Keyboard" gpio-keys pm8941_resin)
for i in "${!nodes[@]}"; do
  mkdir -p "$tmp/input/event$i/device"
  echo "${nodes[i]}" > "$tmp/input/event$i/device/name"
  mkfifo "$tmp/input/event$i/node"
done
unit=$tree/usr/lib/systemd/user/microos-hotkeyd@.service
post=$(sed -n 's/^ExecStopPost=//p' "$unit")
[[ $post == "/usr/libexec/microos/microos-hotkeyd --reset-intercept" ]] || fail "hotkeyd ExecStopPost: $post"
grep -qx 'Restart=always' "$unit" || fail "hotkeyd unit Restart"
grep -qx 'StartLimitIntervalSec=0' "$unit" || fail "hotkeyd unit start limit"
stop_post() { python3 "$hotkeyd" --reset-intercept 3<&- 4<&-; }
fd_open() {
  local f
  for f in /proc/"$hk"/fd/*; do [[ $(readlink "$f") == "$tmp/input/$1/node" ]] && return 0; done
  return 1
}
atime_old() { [[ $(stat -c %X "$tmp/input/event0/device/name") == 946684800 ]]; }
mkfifo "$tmp/home/.steam/steam.pipe"
exec 4<> "$tmp/home/.steam/steam.pipe"

waitfor() {
  for _ in {1..50}; do grep -qx "$2" "$1" 2> /dev/null && return 0; sleep 0.1; done
  return 1
}
until_ok() {
  for _ in {1..50}; do "$@" && return 0; sleep 0.1; done
  return 1
}
calls() { cat "$tmp/calls.log" 2> /dev/null || true; }
calls_are() { [[ $(calls) == "$1" ]]; }
count() { grep -cx "$2" "$1" 2> /dev/null || true; }
dev=/org/shadowblip/InputPlumber/CompositeDevice
modes() { awk '$1 == "mode" { m[$2] = $3 } END { for (d in m) print d, m[d] }' "$tmp/ip.log" | sort; }
want_modes() {
  local i exp=
  for ((i = 0; i < $2; i++)); do exp+="$dev$i $1"$'\n'; done
  [[ $(modes) == "${exp%$'\n'}" ]]
}
holder() { python3 "$here/hotkeyd/client" /dev/null get 2> /dev/null; }
is_holder() { local h; h=$(holder) || return 1; [[ $h == "$1" ]]; }

stub=
sys=
hk=
stop() { [[ -n $1 ]] && { kill "$1" 2> /dev/null || true; wait "$1" 2> /dev/null || true; }; return 0; }
stubs() {
  stop "$stub"
  stop "$sys"
  rm -f "$tmp/logind.log" "$tmp/ip.log"
  STUB_DENY=${1:-} python3 "$here/hotkeyd/logind-stub" "$tmp/logind.log" 3<&- 4<&- & stub=$!
  python3 "$here/hotkeyd/system-stub" "$tmp/ip.log" 3<&- 4<&- & sys=$!
  pids+=("$stub" "$sys")
  waitfor "$tmp/logind.log" ready || fail "logind stub did not start"
  waitfor "$tmp/ip.log" ready || fail "system stub did not start"
}
start() {
  stop "$hk"
  stop "${KEYS_PID:-}"
  rm -f "$tmp/calls.log"
  coproc KEYS { exec python3 "$here/hotkeyd/keys" "$tmp/input" 3<&- 4<&-; }
  pids+=("$KEYS_PID")
  HOME=$tmp/home MICROOS_HOTKEYD_INPUT=$tmp/input MICROOS_HOTKEYD_TABLES=${2:-$tables} MICROOS_HOTKEYD_SESSIONS=$tmp/sd \
    MICROOS_HOTKEYD_STEAM=$tmp/bin/steam python3 "$hotkeyd" "$1" 2> "$tmp/hotkeyd.err" 3<&- 4<&- & hk=$!
  pids+=("$hk")
  until_ok is_holder "" || fail "$1: no Intercept arbiter: $(cat "$tmp/hotkeyd.err")"
}
boot() { stubs "${3:-}"; start "$1" "${2:-}"; }
restart_ip() {
  stop "$sys"
  rm -f "$tmp/ip.log"
  python3 "$here/hotkeyd/system-stub" "$tmp/ip.log" 3<&- 4<&- & sys=$!
  pids+=("$sys")
  waitfor "$tmp/ip.log" ready || fail "system stub did not restart"
}
blocks_are() { [[ $(count "$tmp/logind.log" "inhibit handle-power-key:handle-suspend-key block") == "$1" ]]; }

k() {
  local reply=
  echo "$*" >&"${KEYS[1]}"
  read -r -t 15 reply <&"${KEYS[0]}" || true
  [[ $reply == ok ]] || fail "key writer on '$*': $reply"
}

press() { k "${1:-}${1:+.}down" wait:0.1 "${1:-}${1:+.}up" wait:0.3; }
hold() { k "${1:-}${1:+.}down" wait:1.2 "${1:-}${1:+.}up" wait:0.3; }
rumbles() { (( $(grep -c "^rumble .* 1.0$" "$tmp/ip.log") == $1 && $(grep -c "^rumble .* 0.0$" "$tmp/ip.log") == $1 )); }

declare -A client_pid
client() {
  local id=$1
  shift
  python3 "$here/hotkeyd/client" "$tmp/$id.log" "$@" 3<&- 4<&- &
  client_pid[$id]=$!
  pids+=($!)
  until_ok grep -qs '^ready ' "$tmp/$id.log" || fail "client $id did not start"
}
unique() { sed -n 's/^ready //p' "$tmp/$1.log"; }

r=0
timeout 5 python3 "$hotkeyd" "Bad/name" 2> /dev/null || r=$?
(( r == 2 )) || fail "a bad session name exits $r"

boot steam "" handle-power-key:handle-suspend-key
waitfor "$tmp/logind.log" "deny handle-power-key:handle-suspend-key block" || fail "no block Inhibit"
k wait:4.5
(( $(count "$tmp/logind.log" "deny handle-power-key:handle-suspend-key block") >= 2 )) || fail "a denied block Inhibit is not retried"
(( $(grep -c "inhibit failed" "$tmp/hotkeyd.err") == 1 )) || fail "a denied Inhibit not logged once: $(cat "$tmp/hotkeyd.err")"
kill -0 "$hk" 2> /dev/null || fail "hotkeyd exited with Inhibit denied"
press
[[ -z $(calls) ]] || fail "power key acted without the block inhibitor: $(calls)"
k deny:
until_ok blocks_are 1 || fail "block inhibitor not taken after the deny ended"
press
[[ $(calls) == "steam -ifrunning steam://shortpowerpress" ]] || fail "short press after the deny ended: $(calls)"

boot steam "" sleep
waitfor "$tmp/logind.log" "inhibit handle-power-key:handle-suspend-key block" || fail "no block inhibitor with the delay denied"
press
[[ $(calls) == "steam -ifrunning steam://shortpowerpress" ]] || fail "short press with the delay denied: $(calls)"
grep -q "sleep inhibitor failed" "$tmp/hotkeyd.err" || fail "no sleep inhibitor line: $(cat "$tmp/hotkeyd.err")"
kill -0 "$hk" 2> /dev/null || fail "hotkeyd exited with the delay denied: $(cat "$tmp/hotkeyd.err")"

boot steam
waitfor "$tmp/logind.log" "inhibit sleep delay" || fail "no sleep delay inhibitor: $(cat "$tmp/logind.log")"
waitfor "$tmp/logind.log" "inhibit handle-power-key:handle-suspend-key block" || fail "steam: no block inhibitor"
until_ok want_modes 0 2 || fail "InterceptMode 0 at start: $(modes)"
fd_open event0 || fail "steam: pwrkey node not open"
fd_open event1 && fail "steam: InputPlumber Keyboard open without a row"
touch -a -d @946684800 "$tmp/input/event0/device/name"
k wait:4.5
atime_old || fail "steam: node scan while every node is held"

press
[[ $(calls) == "steam -ifrunning steam://shortpowerpress" ]] || fail "short press: $(calls)"
grep -q "^rumble" "$tmp/ip.log" && fail "rumble on a tap"

rm -f "$tmp/calls.log"
k down wait:0.8
[[ -z $(calls) ]] || fail "long press fired before 1000 ms: $(calls)"
k wait:0.5
[[ $(calls) == "steam -ifrunning steam://longpowerpress" ]] || fail "long press while held: $(calls)"
k up wait:0.3
[[ $(calls) == "steam -ifrunning steam://longpowerpress" ]] || fail "release after a long press: $(calls)"
rumbles 2 || fail "hold rumble on two devices: $(grep rumble "$tmp/ip.log")"

rm -f "$tmp/calls.log"
k down repeat repeat wait:0.1 repeat up wait:0.3
[[ $(calls) == "steam -ifrunning steam://shortpowerpress" ]] || fail "repeats: $(calls)"

rm -f "$tmp/calls.log"
k sleep:true
waitfor "$tmp/logind.log" "release sleep delay" || fail "sleep delay inhibitor kept across sleep"
k wait:0.2 down wait:0.05 sleep:false up wait:0.3
[[ -z $(calls) ]] || fail "key down before (false): $(calls)"
(( $(count "$tmp/logind.log" "inhibit sleep delay") == 2 )) || fail "sleep delay inhibitor not taken again"

k sleep:true sleep:false wait:0.5
press
[[ -z $(calls) ]] || fail "key down 500 ms after (false): $(calls)"

k wait:1.5
press
[[ $(calls) == "steam -ifrunning steam://shortpowerpress" ]] || fail "key down 2000 ms after (false): $(calls)"

rm -f "$tmp/calls.log"
k down wait:0.1 sleep:true up wait:1.3
[[ -z $(calls) ]] || fail "(true) after the key down: $(calls)"
k sleep:false wait:1.6

k down wait:0.1 sleep:true sleep:false wait:1.6 up wait:0.3
[[ -z $(calls) ]] || fail "a press held across a sleep: $(calls)"

exec 4<&-
press
[[ -z $(calls) ]] || fail "URI with the client down: $(calls)"
grep -qx suspend "$tmp/logind.log" || fail "no Suspend with the client down: $(cat "$tmp/logind.log")"
hold
(( $(count "$tmp/logind.log" suspend) == 1 )) || fail "a power hold with the client down suspended"
[[ -z $(calls) ]] || fail "hold URI with the client down: $(calls)"
exec 4<> "$tmp/home/.steam/steam.pipe"

k close:power
waitfor "$tmp/logind.log" "release handle-power-key:handle-suspend-key block" || fail "read error kept the block inhibitor"
kill -0 "$hk" 2> /dev/null || fail "hotkeyd exited on a read error: $(cat "$tmp/hotkeyd.err")"
is_holder "" || fail "arbiter gone after a read error"
grep -q "pm8941_pwrkey (.*) closed" "$tmp/hotkeyd.err" || fail "no read error line: $(cat "$tmp/hotkeyd.err")"
until_ok blocks_are 2 || fail "block inhibitor not taken again after the reopen"
atime_old && fail "no node scan after a read error"
rm -f "$tmp/calls.log"
press
[[ $(calls) == "steam -ifrunning steam://shortpowerpress" ]] || fail "short press after the reopen: $(calls)"

boot recovery
waitfor "$tmp/logind.log" "inhibit handle-power-key:handle-suspend-key block" || fail "recovery: no block inhibitor"
press
grep -qx suspend "$tmp/logind.log" || fail "recovery: power tap did not suspend: $(cat "$tmp/logind.log")"
[[ -z $(calls) ]] || fail "recovery: power tap ran $(calls)"
: > "$tmp/ip.log"
hold
(( $(count "$tmp/logind.log" suspend) == 1 )) || fail "recovery: power hold suspended"
grep -q "^rumble" "$tmp/ip.log" && fail "recovery: rumble on a hold without a row"
rm -f "$tmp/calls.log"
k volup.down wait:0.2
calls_are "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+" || fail "recovery: volume up at key down: $(calls)"
k volup.up wait:0.2

cat > "$tmp/t/t.conf" <<EOF
power tap steam-uri steam://a
power hold switch microdap confirm-in-game
guide tap back
guide hold switch recovery
lc tap call test.Hotkeyd /test test.Hotkeyd Poke
lc hold suspend
volup tap volume up
voldown tap volume down
rc tap steam-uri steam://rc
rc hold steam-uri http://x

bogus tap none
guide tap frobnicate
guide hold switch Bad
power tap volume sideways
EOF
printf 'rc tap none\npower tap steam-uri steam://b\n' > "$tmp/t/t.conf.d/10-a.conf"
printf 'power tap steam-uri steam://c\n' > "$tmp/t/t.conf.d/20-b.conf"
printf 'power tap steam-uri steam://d\n' > "$tmp/t/t.conf.d/30-c.txt"
boot t "$tmp/t"
waitfor "$tmp/logind.log" "inhibit handle-power-key:handle-suspend-key block" || fail "t: no block inhibitor"
(( $(grep -c ": ignored: " "$tmp/hotkeyd.err") == 5 )) || fail "bad rows not ignored once each: $(cat "$tmp/hotkeyd.err")"
client s serve

press
[[ $(calls) == "steam -ifrunning steam://c" ]] || fail "later table row: $(calls)"
rm -f "$tmp/calls.log"
press rc
[[ -z $(calls) ]] || fail "none row acted: $(calls)"
press guide
[[ $(calls) == "microos-session back" ]] || fail "back: $(calls)"
rm -f "$tmp/calls.log"
press guide2
[[ $(calls) == "microos-session back" ]] || fail "second InputPlumber Keyboard node: $(calls)"
rm -f "$tmp/calls.log"
k sleep:true sleep:false wait:0.5
press guide
[[ -z $(calls) ]] || fail "guide down 500 ms after (false): $(calls)"
k wait:1.5
press guide
[[ $(calls) == "microos-session back" ]] || fail "guide down 2000 ms after (false): $(calls)"
rm -f "$tmp/calls.log"
: > "$tmp/ip.log"
hold guide
[[ $(calls) == "systemctl start --no-block microos-session-switch@recovery.service" ]] || fail "switch: $(calls)"
rumbles 2 || fail "switch hold rumble: $(grep rumble "$tmp/ip.log")"
rm -f "$tmp/calls.log"
press lc
until_ok grep -qsx poke "$tmp/s.log" || fail "call did not reach the session bus"
hold lc
grep -qx suspend "$tmp/logind.log" || fail "suspend row: $(cat "$tmp/logind.log")"
k step:10
press volup
until_ok calls_are "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 10%+" || fail "volume up by the step: $(calls)"
rm -f "$tmp/calls.log"
k step:0
press voldown
until_ok calls_are "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%-" || fail "volume down without a step: $(calls)"

rm -f "$tmp/calls.log"
k guide.down lc.down wait:1.2 guide.up lc.up wait:0.3
[[ $(calls) == "systemctl start --no-block microos-session-switch@recovery.service" ]] || fail "two keys held: $(calls)"
(( $(count "$tmp/logind.log" suspend) == 2 )) || fail "two keys held: no second suspend"

k close:guide2 wait:0.3
grep -q "InputPlumber Keyboard (.*event2/node) closed" "$tmp/hotkeyd.err" || fail "no close line for event2: $(cat "$tmp/hotkeyd.err")"
grep -qx "release handle-power-key:handle-suspend-key block" "$tmp/logind.log" && fail "EOF on a keyboard node dropped the block inhibitor"

rm -f "$tmp/calls.log"
hold power
[[ $(calls) == "systemctl start --no-block microos-session-switch@microdap.service" ]] || fail "confirm-in-game without a game: $(calls)"
python3 -c 'import time; time.sleep(60)' SteamLaunch AppId=7 3<&- 4<&- & game=$!
pids+=("$game")
rm -f "$tmp/calls.log"
: > "$tmp/ip.log"
hold power
[[ -z $(calls) ]] || fail "first hold in a game switched: $(calls)"
rumbles 4 || fail "first hold in a game: no double rumble: $(grep rumble "$tmp/ip.log")"
press guide
rm -f "$tmp/calls.log"
hold power
[[ $(calls) == "systemctl start --no-block microos-session-switch@microdap.service" ]] || fail "second hold in a game after another key: $(calls)"
rm -f "$tmp/calls.log"
hold power
k wait:3.2
hold power
[[ -z $(calls) ]] || fail "a hold 3 s after the first switched: $(calls)"
kill "$game"

: > "$tmp/ip.log"
client w watch
client a acquire usr1
a=$(unique a)
until_ok is_holder "$a" || fail "holder after Acquire: $(holder)"
until_ok want_modes 3 2 || fail "InterceptMode 3 while held: $(modes)"
until_ok grep -qx "holder $a" "$tmp/w.log" || fail "no PropertiesChanged for $a"
client b acquire
b=$(unique b)
until_ok is_holder "$b" || fail "stack top after a second holder: $(holder)"
until_ok grep -qx "holder $b" "$tmp/w.log" || fail "no PropertiesChanged for $b"
seen=$(wc -l < "$tmp/w.log")
kill -USR1 "${client_pid[a]}"
until_ok grep -qx acquired "$tmp/a.log" || fail "no second Acquire from $a"
until_ok is_holder "$a" || fail "an Acquire from a name on the stack does not move it to the top: $(holder)"
k wait:0.3
[[ $(tail -n +$((seen + 1)) "$tmp/w.log") == "holder $a" ]] || fail "move to top is not one Holder change: $(tail -n +$((seen + 1)) "$tmp/w.log")"
want_modes 3 2 || fail "InterceptMode changed on a move to top: $(modes)"
kill "${client_pid[b]}"
k wait:0.3
is_holder "$a" || fail "holder after the buried name left: $(holder)"
[[ $(tail -n +$((seen + 1)) "$tmp/w.log") == "holder $a" ]] || fail "the buried name leaving changed Holder: $(tail -n +$((seen + 1)) "$tmp/w.log")"
want_modes 3 2 || fail "InterceptMode changed while still held: $(modes)"
client c acquire acquire release
until_ok is_holder "$a" || fail "holder after a repeated Acquire and a Release: $(holder)"
k add
until_ok want_modes 3 3 || fail "a device added while held: $(modes)"
kill "${client_pid[a]}"
until_ok is_holder "" || fail "holder after the last name loss: $(holder)"
until_ok want_modes 0 3 || fail "InterceptMode 0 after the stack emptied: $(modes)"
until_ok grep -qx "holder " "$tmp/w.log" || fail "no PropertiesChanged to empty"
kill "${client_pid[c]}"
python3 "$here/hotkeyd/client" "$tmp/g.log" gone
k wait:0.5
is_holder "" || fail "a vanished name holds: $(holder)"
until_ok want_modes 0 3 || fail "InterceptMode after a vanished name: $(modes)"
k delay:300
python3 "$here/hotkeyd/client" "$tmp/q.log" acquire release get > /dev/null
k wait:1
want_modes 0 3 || fail "Acquire then Release with a slow Set: $(modes)"
k delay:0
: > "$tmp/ip.log"
k remove
hold guide
rumbles 2 || fail "rumble after a device was removed: $(grep rumble "$tmp/ip.log")"
client rm acquire
until_ok want_modes 3 2 || fail "InterceptMode 3 after a device was removed: $(modes)"
kill "${client_pid[rm]}"
until_ok want_modes 0 2 || fail "InterceptMode 0 after a device was removed: $(modes)"
grep -q "CompositeDevice2 failed" "$tmp/hotkeyd.err" && fail "InterceptMode sent to a removed device"

r=0
timeout 5 env MICROOS_HOTKEYD_INPUT=$tmp/input MICROOS_HOTKEYD_TABLES=$tmp/t python3 "$hotkeyd" t 2> "$tmp/second.err" 3<&- 4<&- || r=$?
(( r == 1 )) || fail "a second instance exits $r"
grep -q "lost the name net.seilent.MicroOs.Intercept" "$tmp/second.err" || fail "second instance: $(cat "$tmp/second.err")"
is_holder "" || fail "first instance lost the arbiter"

client i acquire
until_ok want_modes 3 2 || fail "InterceptMode 3 before the InputPlumber restart: $(modes)"
restart_ip
until_ok want_modes 3 2 || fail "InterceptMode after an InputPlumber restart while held: $(modes)"
kill -TERM "$hk"
wait "$hk" 2> /dev/null || true
stop_post
want_modes 0 2 || fail "InterceptMode after SIGTERM and ExecStopPost while held: $(modes)"
kill "${client_pid[i]}"
start t "$tmp/t"

client h acquire
until_ok want_modes 3 2 || fail "InterceptMode 3 before the kill: $(modes)"
kill -9 "$hk"
wait "$hk" 2> /dev/null || true
start t "$tmp/t"
until_ok want_modes 0 2 || fail "InterceptMode 0 after a restart while held: $(modes)"
is_holder "" || fail "holder after a restart: $(holder)"

kill -0 "$hk" 2> /dev/null || fail "hotkeyd died: $(cat "$tmp/hotkeyd.err")"

python3 "$here/hotkeyd/systemd-stub" "$tmp/units" 3<&- 4<&- & sd=$!
pids+=("$sd")
until_ok grep -qsx ready "$tmp/units/systemd.log" || fail "systemd stub did not start"
cat > "$tmp/g/g.conf" <<EOF
volup press volume up
volup tap volume down
voldown hold volume up
voldown press volume down
lc tap unit microemu-leave.service
lc hold unit microemu-stop@x.service
rc tap unit Bad.service
rc hold unit microemu-game.scope
guide press steam-uri steam://x
guide hold switch steam
guide tap back
power hold switch recovery confirm-in-game
EOF
printf 'LABEL=G\nGAME_SCOPE = "microemu-game.scope"\n' > "$tmp/sd/g.conf"
boot g "$tmp/g"
waitfor "$tmp/logind.log" "inhibit handle-power-key:handle-suspend-key block" || fail "g: no block inhibitor"
(( $(grep -c ": ignored: " "$tmp/hotkeyd.err") == 3 )) || fail "g: bad rows not ignored: $(cat "$tmp/hotkeyd.err")"
{ grep -qx "microos-hotkeyd: volup tap: ignored, volup has a press row" "$tmp/hotkeyd.err" &&
  grep -qx "microos-hotkeyd: voldown hold: ignored, voldown has a press row" "$tmp/hotkeyd.err"; } ||
  fail "g: tap or hold rows next to a press row: $(cat "$tmp/hotkeyd.err")"
ups() { grep -c "5%+$" "$tmp/calls.log" 2> /dev/null || true; }

k volup.down wait:0.25
calls_are "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+" || fail "press did not fire once at key down: $(calls)"
k wait:0.57 volup.up wait:0.4
(( $(ups) == 6 )) || fail "an 850 ms press did not step at 0, 400, 500, 600, 700, 800 ms: $(calls)"
k wait:0.3
(( $(ups) == 6 )) || fail "a press repeated after the release: $(calls)"
grep -q "%-$" "$tmp/calls.log" && fail "the tap row next to a press row fired: $(calls)"
rm -f "$tmp/calls.log"
k volup.down volup.repeat wait:0.1 volup.repeat volup.up wait:0.3
(( $(ups) == 1 )) || fail "kernel repeats stepped: $(calls)"
rm -f "$tmp/calls.log"
: > "$tmp/ip.log"
k voldown.down wait:1.15 voldown.up wait:0.3
(( $(grep -c "5%-$" "$tmp/calls.log") == 9 )) || fail "a 1150 ms voldown press: $(calls)"
grep -q "5%+$" "$tmp/calls.log" && fail "the hold row next to a press row fired: $(calls)"
grep -q "^rumble" "$tmp/ip.log" && fail "rumble on a press"
rm -f "$tmp/calls.log"
k sleep:true sleep:false wait:0.5
press volup
[[ -z $(calls) ]] || fail "press 500 ms after (false): $(calls)"
k wait:1.5
press volup
(( $(ups) == 1 )) || fail "press 2000 ms after (false): $(calls)"

rm -f "$tmp/calls.log"
press lc
[[ $(calls) == "systemctl --user start --no-block microemu-leave.service" ]] || fail "unit tap: $(calls)"
rm -f "$tmp/calls.log"
: > "$tmp/ip.log"
hold lc
[[ $(calls) == "systemctl --user start --no-block microemu-stop@x.service" ]] || fail "unit hold: $(calls)"
rumbles 2 || fail "unit hold rumble: $(grep rumble "$tmp/ip.log")"

rm -f "$tmp/calls.log"
hold guide
[[ $(calls) == "systemctl start --no-block microos-session-switch@steam.service" ]] || fail "switch with the scope not loaded: $(calls)"
grep -qx "GetUnit microemu-game.scope" "$tmp/units/systemd.log" || fail "no GetUnit for the game scope: $(cat "$tmp/units/systemd.log")"
echo 700 > "$tmp/units/delay"
rm -f "$tmp/calls.log"
press guide
press guide
k wait:1
[[ $(calls) == "microos-session back" ]] || fail "two backs while GetUnit is pending: $(calls)"
rm -f "$tmp/calls.log"
press guide
k sleep:true sleep:false wait:1
[[ -z $(calls) ]] || fail "back acted after a sleep while GetUnit was pending: $(calls)"
rm -f "$tmp/units/delay"
k wait:1.5
echo active > "$tmp/units/microemu-game.scope"
rm -f "$tmp/calls.log"
: > "$tmp/ip.log"
hold guide
[[ -z $(calls) ]] || fail "a switch row without confirm-in-game switched with the game scope active: $(calls)"
rumbles 4 || fail "first hold with the game scope active: no double rumble: $(grep rumble "$tmp/ip.log")"
hold guide
[[ $(calls) == "systemctl start --no-block microos-session-switch@steam.service" ]] || fail "second hold with the game scope active: $(calls)"
rm -f "$tmp/calls.log"
press guide
[[ -z $(calls) ]] || fail "back with the game scope active: $(calls)"
press guide
[[ $(calls) == "microos-session back" ]] || fail "second back with the game scope active: $(calls)"
rm -f "$tmp/calls.log"
hold power
[[ -z $(calls) ]] || fail "confirm-in-game with the game scope active: $(calls)"
hold power
[[ $(calls) == "systemctl start --no-block microos-session-switch@recovery.service" ]] || fail "second confirm-in-game hold: $(calls)"
echo deactivating > "$tmp/units/microemu-game.scope"
rm -f "$tmp/calls.log"
hold guide
[[ -z $(calls) ]] || fail "switch with the game scope deactivating: $(calls)"
k wait:3.2
echo inactive > "$tmp/units/microemu-game.scope"
hold guide
[[ $(calls) == "systemctl start --no-block microos-session-switch@steam.service" ]] || fail "switch with the game scope inactive: $(calls)"
echo active > "$tmp/units/microemu-game.scope"
stop "$sd"
rm -f "$tmp/calls.log"
hold guide
[[ -z $(calls) ]] || fail "switch with the user manager gone: $(calls)"
grep -q "microemu-game.scope state unknown" "$tmp/hotkeyd.err" || fail "no unknown state line: $(cat "$tmp/hotkeyd.err")"

printf 'GAME_SCOPE=../x.scope\n' > "$tmp/sd/b.conf"
printf 'guide hold switch steam\n' > "$tmp/g/b.conf"
: > "$tmp/units/systemd.log"
python3 "$here/hotkeyd/systemd-stub" "$tmp/units" 3<&- 4<&- & sd=$!
pids+=("$sd")
until_ok grep -qsx ready "$tmp/units/systemd.log" || fail "systemd stub did not restart"
boot b "$tmp/g"
grep -q "GAME_SCOPE ignored: ../x.scope" "$tmp/hotkeyd.err" || fail "a bad GAME_SCOPE not refused: $(cat "$tmp/hotkeyd.err")"
hold guide
[[ $(calls) == "systemctl start --no-block microos-session-switch@steam.service" ]] || fail "switch with a refused GAME_SCOPE: $(calls)"
grep -q GetUnit "$tmp/units/systemd.log" && fail "GetUnit with a refused GAME_SCOPE"
kill -0 "$hk" 2> /dev/null || fail "hotkeyd died: $(cat "$tmp/hotkeyd.err")"

mkdir -p "$tmp/o/o.conf.d"
echo "rc tap call net.seilent.MicroSet.Overlay /net/seilent/MicroSet/Overlay net.seilent.MicroSet.Overlay1 Toggle" \
  > "$tmp/o/o.conf.d/60-microset.conf"
boot o "$tmp/o"
grep -q ": ignored: " "$tmp/hotkeyd.err" && fail "MicroSET's rc row refused: $(cat "$tmp/hotkeyd.err")"
client v overlay
press rc
until_ok grep -qsx toggle "$tmp/v.log" || fail "rc did not toggle the MicroSET overlay: $(cat "$tmp/hotkeyd.err")"
(( $(grep -cx toggle "$tmp/v.log") == 1 )) || fail "one rc tap toggled $(grep -cx toggle "$tmp/v.log") times"

if (( rc == 0 )); then
  echo "hotkeyd: ok"
fi
exit $rc
