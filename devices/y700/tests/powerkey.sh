#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
powerkey=$tree/usr/libexec/microos/microos-powerkey
unit=$tree/usr/lib/systemd/user/microos-powerkey.service
dropin=$tree/usr/lib/systemd/user/gamescope-session-plus@steam.service.d/20-microos-powerkey.conf
tmp=$(mktemp -d)
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done
  rm -rf "${tmp:?}"
}
trap cleanup EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

for t in dbus-daemon python3; do
  command -v "$t" > /dev/null || { echo "FAIL: $t missing" >&2; exit 1; }
done
python3 -c 'import gi; gi.require_version("Gio", "2.0"); from gi.repository import Gio' || { echo "FAIL: python3 gi missing" >&2; exit 1; }

[[ $(< "$dropin") == $'[Unit]\nWants=microos-powerkey.service' ]] || fail "20-microos-powerkey.conf"
for l in BindsTo=gamescope-session-plus@steam.service After=gamescope-session-plus@steam.service \
  ExecStart=/usr/libexec/microos/microos-powerkey Restart=always StartLimitIntervalSec=0; do
  grep -qxF "$l" "$unit" || fail "microos-powerkey.service lacks $l"
done

cat > "$tmp/system.conf" <<CONF
<busconfig>
  <type>system</type>
  <listen>unix:path=$tmp/system</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="*"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
CONF
dbus-daemon --config-file="$tmp/system.conf" --nofork & pids+=($!)
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=$tmp/system
for _ in {1..50}; do [[ -S $tmp/system ]] && break; sleep 0.1; done
sed -e 's|<type>system</type>|<type>session</type>|' -e "s|$tmp/system<|$tmp/session<|" \
  -e "s|</listen>|</listen>\n  <servicedir>$tmp/services</servicedir>|" "$tmp/system.conf" > "$tmp/session.conf"
mkdir "$tmp/services"
printf '%s\n' '[D-BUS Service]' Name=net.seilent.MicroSet.Overlay "Exec=/usr/bin/touch $tmp/activated" \
  > "$tmp/services/net.seilent.MicroSet.Overlay.service"
dbus-daemon --config-file="$tmp/session.conf" --nofork & sb=$!
pids+=("$sb")
session=unix:path=$tmp/session
export DBUS_SESSION_BUS_ADDRESS=$session
for _ in {1..50}; do [[ -S $tmp/session ]] && break; sleep 0.1; done

mkdir -p "$tmp/bin" "$tmp/home/.steam"
cat > "$tmp/bin/steam" <<STEAM
#!/usr/bin/env bash
printf '%s\n' "steam \$*" >> "$tmp/calls.log"
STEAM
chmod +x "$tmp/bin/steam"
mkfifo "$tmp/home/.steam/steam.pipe" "$tmp/feed"

waitfor() {
  for _ in {1..50}; do grep -qx "$2" "$1" 2> /dev/null && return 0; sleep 0.1; done
  return 1
}
count() { grep -cx "$2" "$1" 2> /dev/null || true; }
calls() { cat "$tmp/calls.log" 2> /dev/null || true; }
login() { gdbus call --system -d org.freedesktop.login1 -o /org/freedesktop/login1 -m "org.freedesktop.login1.Manager.$1" "${@:2}" > /dev/null; }
feed() { printf '%s\n' "$@" > "$tmp/feed"; sleep 0.4; }
words() { sed -n 's/^word //p' "$tmp/vpad.log" | paste -sd' '; }

stub=
vp=
pk=
stop() { [[ -n $1 ]] && { kill "$1" 2> /dev/null || true; wait "$1" 2> /dev/null || true; }; return 0; }
start_vpad() {
  stop "$vp"
  rm -f "$tmp/vpad.log"
  python3 "$here/powerkey/vpad" "$tmp/power" "$tmp/feed" "$tmp/vpad.log" "$@" & vp=$!
  pids+=("$vp")
  waitfor "$tmp/vpad.log" ready || fail "fake vpad did not start"
}
start_helper() {
  stop "$pk"
  HOME=$tmp/home MICROOS_POWERKEY_SOCKET=$tmp/power MICROOS_POWERKEY_STEAM=$tmp/bin/steam MICROOS_POWERKEY_RESLEEP=${RESLEEP:-1} \
    MICROOS_POWERKEY_OVERLAY=${OVERLAY:-} DBUS_SESSION_BUS_ADDRESS=${SESSION_BUS:-$session} \
    python3 "$powerkey" 2>> "$tmp/powerkey.err" & pk=$!
  pids+=("$pk")
}
boot() {
  stop "$pk"
  stop "$stub"
  rm -f "$tmp/logind.log" "$tmp/calls.log" "$tmp/powerkey.err"
  python3 "$here/powerkey/logind-stub" "$tmp/logind.log" & stub=$!
  pids+=("$stub")
  waitfor "$tmp/logind.log" ready || fail "logind stub did not start"
  start_vpad
  start_helper
  waitfor "$tmp/vpad.log" connected || fail "$1: helper did not connect: $(cat "$tmp/powerkey.err")"
  waitfor "$tmp/logind.log" "inhibit sleep delay" || fail "$1: no sleep delay inhibitor"
}
steam_on() { exec {steam}<> "$tmp/home/.steam/steam.pipe"; }
steam_off() { exec {steam}>&-; }
suspends() { count "$tmp/logind.log" "suspend false"; }
cycle() {
  login EmitPrepareForSleep true
  waitfor "$tmp/logind.log" "release sleep delay" || fail "$1: delay not released on sleep"
  login EmitPrepareForSleep false
  sleep 0.2
}
said() { grep -cxF "microos-powerkey: $1" "$tmp/powerkey.err" || true; }
ov=
start_overlay() {
  rm -f "$tmp/overlay.log"
  python3 "$here/powerkey/overlay" "$tmp/overlay.log" "$@" & ov=$!
  pids+=("$ov")
  waitfor "$tmp/overlay.log" ready || fail "fake overlay did not start"
}
toggles() { count "$tmp/overlay.log" Toggle; }
quick() {
  gdbus call --session -d net.seilent.MicroOS.PowerKey -o /net/seilent/MicroOS/PowerKey \
    -m net.seilent.MicroOS.PowerKey1.OpenQuickAccess 2>&1
}
owned() {
  gdbus call --session -d org.freedesktop.DBus -o /org/freedesktop/DBus -m org.freedesktop.DBus.NameHasOwner \
    net.seilent.MicroOS.PowerKey
}

start_overlay
boot steam
steam_on
feed 'down now on' 'single last on'
[[ $(calls) == 'steam -ifrunning steam://shortpowerpress' ]] || fail "tap with Steam: $(calls)"
: > "$tmp/calls.log"
feed 'down now on' 'hold last on'
[[ $(calls) == 'steam -ifrunning steam://longpowerpress' ]] || fail "hold with Steam: $(calls)"
: > "$tmp/calls.log"
feed 'down now on' 'down now+0.2 on' 'double last on'
[[ -z $(calls) && -z $(words) && $(toggles) == 0 ]] || fail "double tap: $(calls) $(words) $(toggles) toggles"
[[ $(suspends) == 0 ]] || fail "suspend with Steam running"
[[ $(owned) == '(false,)' ]] || fail "PowerKey name owned without the knob"
steam_off

feed 'down now on' 'single last on'
waitfor "$tmp/logind.log" "suspend false" || fail "tap without Steam did not suspend"
feed 'down now on' 'hold last on'
[[ $(suspends) == 1 && -z $(calls) ]] || fail "hold without Steam: $(calls)"

login SetCanSuspend challenge
steam_on
feed 'down now on' 'single last on'
[[ $(words) == blank && -z $(calls) ]] || fail "tap with CanSuspend challenge: $(words) $(calls)"
feed 'down now off' 'single last off'
[[ $(words) == 'blank restore' && -z $(calls) ]] || fail "tap while blank: $(words) $(calls)"
feed 'down now on' 'hold last on'
[[ $(words) == 'blank restore blank' && -z $(calls) ]] || fail "hold with CanSuspend challenge: $(words) $(calls)"
feed 'down now off' 'hold last off'
[[ $(words) == 'blank restore blank restore' ]] || fail "hold while blank: $(words)"
login SetCanSuspend no
feed 'down now on' 'single last on'
[[ $(words) == 'blank restore blank restore blank' && -z $(calls) ]] || fail "tap with CanSuspend no: $(words) $(calls)"
[[ $(suspends) == 1 ]] || fail "blocked tap slept while CanSuspend is no"
login SetCanSuspend yes
for _ in {1..30}; do (( $(suspends) == 2 )) && break; sleep 0.1; done
(( $(suspends) == 2 )) || fail "blocked tap did not sleep once CanSuspend is yes: $(suspends) suspends"
[[ -z $(calls) ]] || fail "blocked tap slept through Steam: $(calls)"
steam_off

boot sleep
login EmitPrepareForSleep true
sleep 0.5
[[ $(count "$tmp/logind.log" "release sleep delay") == 1 ]] || fail "delay not released on the vpad word"
[[ $(words) == blank ]] || fail "sleep words: $(words)"
login EmitPrepareForSleep false
waitfor "$tmp/logind.log" "inhibit sleep delay" && [[ $(count "$tmp/logind.log" "inhibit sleep delay") == 2 ]] \
  || fail "delay not taken again on wake"
feed 'down now-0.3 off' 'single last off'
[[ $(words) == 'blank blank restore' && $(suspends) == 0 ]] || fail "power key wake: $(words)"
sleep 2.5
[[ $(suspends) == 0 ]] || fail "power key wake slept again"
steam_on
feed 'down now on' 'single last on'
[[ $(calls) == 'steam -ifrunning steam://shortpowerpress' ]] || fail "tap after a wake: $(calls)"
steam_off

for c in 'now-5.5 dark' 'now-4.5 wake' 'now+1.0 wake' 'now+2.0 dark'; do
  read -r at want <<< "$c"
  boot "window $at"
  cycle "window $at"
  feed "down $at off"
  if [[ $want == wake ]]; then
    [[ $(words) == 'blank blank restore' ]] || fail "press at woke ${at#now}: not the wake: $(words)"
    sleep 2.5
    [[ $(suspends) == 0 ]] || fail "press at woke ${at#now}: slept again"
  else
    [[ $(words) == 'blank blank' ]] || fail "press at woke ${at#now}: taken as the wake: $(words)"
    waitfor "$tmp/logind.log" "suspend false" || fail "press at woke ${at#now}: no sleep again"
  fi
done

boot gestures
steam_on
for c in 'now-5.5 1' 'now-4.5 0' 'now+1.0 0' 'now+2.0 1'; do
  read -r at want <<< "$c"
  cycle "gesture $at"
  : > "$tmp/calls.log"
  feed "single $at on"
  [[ $(grep -c . "$tmp/calls.log" 2> /dev/null || true) == "$want" ]] || fail "tap with key down at woke ${at#now}: $(calls)"
done
steam_off

boot onwake
steam_on
cycle "wake press while on"
feed 'down now on' 'single last on'
[[ $(words) == 'blank blank restore' && -z $(calls) ]] || fail "wake press while vpad says on: $(words) $(calls)"
steam_off

boot prefreeze
login EmitPrepareForSleep true
waitfor "$tmp/logind.log" "release sleep delay" || fail "prefreeze: delay not released"
feed 'down now-20 off' 'single last off'
[[ $(words) == blank ]] || fail "press while asleep acted: $(words)"
login EmitPrepareForSleep false
sleep 0.4
[[ $(words) == 'blank blank' ]] || fail "press 20 s before the wake taken as the wake: $(words)"
waitfor "$tmp/logind.log" "suspend false" || fail "prefreeze: no sleep again"
boot shortsleep
login EmitPrepareForSleep true
waitfor "$tmp/logind.log" "release sleep delay" || fail "shortsleep: delay not released"
feed 'down now off'
login EmitPrepareForSleep false
sleep 0.4
[[ $(words) == 'blank restore' ]] || fail "press that ended a short sleep not taken as the wake: $(words)"

boot dark
cycle dark
sleep 0.8
[[ $(suspends) == 0 ]] || fail "dark wake slept again before the grace"
waitfor "$tmp/logind.log" "suspend false" || fail "dark wake did not sleep again"
[[ $(words) == 'blank blank' ]] || fail "dark wake words: $(words)"
[[ $(said 'not a power key wake, dark, sleeping again in 1 s') == 1 ]] || fail "no dark wake line"

boot press
cycle press
sleep 1.6
feed 'down now off' 'single last off'
[[ $(words) == 'blank blank restore' ]] || fail "press in a dark wake: $(words)"
sleep 1.5
[[ $(suspends) == 0 ]] || fail "dark wake slept again after a press"

boot inhibited
login SetCanSuspend challenge
cycle inhibited
sleep 4
[[ $(suspends) == 0 ]] || fail "dark wake slept with CanSuspend challenge"
[[ $(said 'CanSuspend is challenge, staying dark, trying again every 1 s') == 1 ]] || fail "staying dark line: $(cat "$tmp/powerkey.err")"
login SetCanSuspend yes
waitfor "$tmp/logind.log" "suspend false" || fail "dark wake did not sleep once CanSuspend is yes"

RESLEEP=3 boot repeated
for n in 1 2 3 4; do
  cycle "dark wake $n"
  for _ in {1..80}; do (( $(suspends) >= n )) && break; sleep 0.1; done
  (( $(suspends) == n )) || fail "dark wake $n: $(suspends) suspends"
done
[[ $(said 'not a power key wake, dark, sleeping again in 3 s') == 2 ]] || fail "normal dark lines: $(cat "$tmp/powerkey.err")"
[[ $(said '3 dark wakes within 5 min, sleeping again after 2 s') == 1 ]] || fail "fast line: $(cat "$tmp/powerkey.err")"
cycle "key wake"
feed 'down now off'
[[ $(words | tr ' ' '\n' | grep -c restore) == 1 ]] || fail "key wake after dark wakes: $(words)"
cycle "dark after a key wake"
sleep 4
[[ $(said 'not a power key wake, dark, sleeping again in 3 s') == 3 ]] || fail "count not reset by a key wake: $(cat "$tmp/powerkey.err")"
[[ $(suspends) == 4 ]] || fail "dark wake after a key wake slept after 2 s: $(suspends)"
waitfor "$tmp/logind.log" "suspend false" && for _ in {1..30}; do (( $(suspends) == 5 )) && break; sleep 0.1; done
(( $(suspends) == 5 )) || fail "dark wake after a key wake: $(suspends) suspends"

RESLEEP=3 boot restart
cycle restart
sleep 2.3
[[ $(said 'not a power key wake, dark, sleeping again in 3 s') == 1 && $(suspends) == 0 ]] || fail "restart: not dark yet"
RESLEEP=3 start_helper
for _ in {1..30}; do [[ $(count "$tmp/vpad.log" connected) == 2 ]] && break; sleep 0.1; done
sleep 0.3
[[ $(said 'microos-vpad is dark at connect, sleeping again in 3 s') == 1 ]] || fail "restarted helper: $(cat "$tmp/powerkey.err")"
waitfor "$tmp/logind.log" "suspend false" || fail "helper restarted while dark did not sleep again"

boot suspendfails
login SetSuspendFails true
cycle suspendfails
for _ in {1..60}; do (( $(suspends) >= 3 )) && break; sleep 0.1; done
(( $(suspends) >= 3 )) || fail "failed Suspend not retried: $(suspends) suspends"
[[ $(grep -c '^microos-powerkey: Suspend failed: ' "$tmp/powerkey.err") == 1 ]] || fail "Suspend failed lines: $(cat "$tmp/powerkey.err")"
login SetSuspendFails false

boot refused
start_vpad refuse
sleep 7.5
[[ $(count "$tmp/vpad.log" refused) == 2 ]] || fail "refused helper reconnects: $(count "$tmp/vpad.log" refused) in 7.5 s"
[[ $(said 'microos-vpad closed the connection before a state word, retrying up to every 60 s') == 1 ]] \
  || fail "backoff line: $(cat "$tmp/powerkey.err")"
[[ $(said 'microos-vpad gone') == 1 ]] || fail "gone lines: $(cat "$tmp/powerkey.err")"

boot mute
feed mute
login EmitPrepareForSleep true
sleep 0.5
[[ $(count "$tmp/logind.log" "release sleep delay") == 0 ]] || fail "mute: delay released before the wait"
waitfor "$tmp/logind.log" "release sleep delay" || fail "mute: delay not released after the wait"
[[ $(said 'no word from microos-vpad in 1000 ms, sleeping anyway') == 1 ]] || fail "no blank wait line"

boot vpadgone
feed mute
login EmitPrepareForSleep true
sleep 0.2
start_vpad
sleep 0.3
[[ $(count "$tmp/logind.log" "release sleep delay") == 1 ]] || fail "vpad restart in the blank wait: delay not released"
[[ $(said 'no word from microos-vpad in 1000 ms, sleeping anyway') == 0 ]] || fail "vpad restart in the blank wait: waited"

boot reconnect
stop "$vp"
start_vpad
for _ in {1..40}; do grep -qx connected "$tmp/vpad.log" && break; sleep 0.1; done
grep -qx connected "$tmp/vpad.log" || fail "helper did not reconnect"
steam_on
feed 'down now on' 'single last on'
[[ $(calls) == 'steam -ifrunning steam://shortpowerpress' ]] || fail "tap after a reconnect: $(calls)"
steam_off
[[ $(count "$tmp/logind.log" "release sleep delay") == 0 ]] || fail "delay released by a vpad restart"
kill -0 "$pk" 2> /dev/null || fail "helper exited: $(cat "$tmp/powerkey.err")"

OVERLAY=1 boot overlay
for _ in {1..30}; do [[ $(owned) == '(true,)' ]] && break; sleep 0.1; done
[[ $(owned) == '(true,)' ]] || fail "PowerKey name not owned with the knob: $(cat "$tmp/powerkey.err")"
feed 'down now on' 'down now+0.2 on' 'double last on'
[[ $(toggles) == 1 && -z $(words) && -z $(calls) ]] || fail "double tap with the knob: $(toggles) toggles, $(words) $(calls)"
steam_on
feed 'down now on' 'single last on'
feed 'down now on' 'hold last on'
[[ $(calls) == $'steam -ifrunning steam://shortpowerpress\nsteam -ifrunning steam://longpowerpress' && $(toggles) == 1 ]] \
  || fail "tap and hold with the knob: $(calls)"
steam_off
quick > /dev/null || fail "OpenQuickAccess: $(cat "$tmp/powerkey.err")"
for _ in {1..30}; do [[ $(words) == qam ]] && break; sleep 0.1; done
[[ $(words) == qam ]] || fail "OpenQuickAccess words: $(words)"
stop "$ov"
feed 'down now on' 'down now+0.2 on' 'double last on'
[[ $(words) == 'qam qam' && $(toggles) == 1 && ! -e $tmp/activated ]] || fail "failed Toggle: $(words) $(toggles) toggles"
start_overlay
feed 'down now on' 'down now+0.2 on' 'double last on'
stop "$ov"
feed 'down now on' 'down now+0.2 on' 'double last on'
[[ $(words) == 'qam qam qam' && $(toggles) == 1 ]] || fail "Toggle after a failed one: $(words) $(toggles) toggles"
toggle_failed() { grep -c '^microos-powerkey: MicroSet overlay Toggle failed: ' "$tmp/powerkey.err" || true; }
[[ $(toggle_failed) == 2 ]] || fail "Toggle failed lines: $(cat "$tmp/powerkey.err")"
stop "$vp"
for _ in {1..30}; do [[ $(said 'microos-vpad gone') == 1 ]] && break; sleep 0.1; done
got=$(quick) && fail "OpenQuickAccess with vpad gone: $got"
[[ $got == *net.seilent.MicroOS.PowerKey.Error.NoVpad* ]] || fail "OpenQuickAccess with vpad gone: $got"
start_vpad
for _ in {1..40}; do grep -qx connected "$tmp/vpad.log" && break; sleep 0.1; done
grep -qx connected "$tmp/vpad.log" || fail "helper did not reconnect after vpad gone"
start_overlay hang
feed mute
feed 'down now on' 'down now+0.2 on' 'double last on'
login EmitPrepareForSleep true
got=$(quick) && fail "OpenQuickAccess asleep: $got"
[[ $got == *net.seilent.MicroOS.PowerKey.Error.ScreenOff* ]] || fail "OpenQuickAccess asleep: $got"
sleep 1
[[ $(words) == blank && $(toggles) == 1 && $(toggle_failed) == 2 ]] || fail "Toggle timeout while asleep: $(words) $(toggles) toggles"
login EmitPrepareForSleep false
start_vpad
for _ in {1..40}; do grep -qx connected "$tmp/vpad.log" && break; sleep 0.1; done
grep -qx connected "$tmp/vpad.log" || fail "helper did not reconnect after the muted vpad"
login SetCanSuspend challenge
sleep 1.6
feed 'down now on' 'single last on'
before=$(words)
[[ $before == blank ]] || fail "blank before the dark double tap: $before"
feed 'double now off'
[[ $(words) == "$before" && $(toggles) == 1 ]] || fail "double tap while dark: $(words) $(toggles) toggles"
stop "$ov"
got=$(quick) && fail "OpenQuickAccess while dark: $got"
[[ $got == *net.seilent.MicroOS.PowerKey.Error.ScreenOff* && $(words) == "$before" ]] || fail "OpenQuickAccess while dark: $got $(words)"
HOME=$tmp/home MICROOS_POWERKEY_SOCKET=$tmp/none MICROOS_POWERKEY_OVERLAY=1 python3 "$powerkey" 2> "$tmp/second.err" & p2=$!
pids+=("$p2")
for _ in {1..30}; do grep -sqxF "microos-powerkey: net.seilent.MicroOS.PowerKey has another owner" "$tmp/second.err" && break; sleep 0.1; done
grep -qxF "microos-powerkey: net.seilent.MicroOS.PowerKey has another owner" "$tmp/second.err" || fail "second owner: $(cat "$tmp/second.err")"
stop "$p2"
stop "$sb"
for _ in {1..30}; do [[ $(said 'user bus closed, double tap opens the quick access menu') == 1 ]] && break; sleep 0.1; done
[[ $(said 'user bus closed, double tap opens the quick access menu') == 1 ]] || fail "no user bus closed line: $(cat "$tmp/powerkey.err")"
kill -0 "$pk" 2> /dev/null || fail "helper exited with the user bus: $(cat "$tmp/powerkey.err")"

SESSION_BUS=unix:path=$tmp/nobus OVERLAY=1 boot nobus
[[ $(grep -c '^microos-powerkey: user bus: ' "$tmp/powerkey.err") == 1 ]] || fail "no user bus line: $(cat "$tmp/powerkey.err")"
steam_on
feed 'down now on' 'single last on'
feed 'down now on' 'hold last on'
[[ $(calls) == $'steam -ifrunning steam://shortpowerpress\nsteam -ifrunning steam://longpowerpress' ]] || fail "tap and hold with no user bus: $(calls)"
steam_off
feed 'down now on' 'down now+0.2 on' 'double last on'
[[ $(words) == qam ]] || fail "double tap with no user bus: $(words)"
kill -0 "$pk" 2> /dev/null || fail "helper exited with no user bus: $(cat "$tmp/powerkey.err")"

if (( rc == 0 )); then
  echo "powerkey: ok"
fi
exit "$rc"
