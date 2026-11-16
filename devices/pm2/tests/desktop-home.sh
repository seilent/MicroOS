#!/usr/bin/env bash
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
home=$tree/usr/libexec/microos/microos-desktop-home
client=$here/desktop-home/client
fixtures=$here/desktop-home/fixtures
socket2=$here/desktop-home/socket2
hyprctl=$here/desktop-home/hyprctl
tmp=$(mktemp -d)
pids=()
checks=0
rc=0

cleanup() {
  local p
  for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done
  exec 3>&-
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; rc=1; }
ok() { checks=$((checks + 1)); }

for t in dbus-daemon python3; do
  command -v "$t" > /dev/null || { echo "FAIL: $t missing" >&2; exit 1; }
done
python3 -I -c 'import gi' || { echo "FAIL: python3-gobject missing" >&2; exit 1; }

run=$tmp/run
mkdir -p "$run/hypr/inst" "$run/microos" "$tmp/bin" "$tmp/hypr/evals"
export XDG_RUNTIME_DIR=$run HYPR_DIR=$tmp/hypr MICROOS_DESKTOP_HOME_HYPRCTL=$tmp/bin/hyprctl
cp "$hyprctl" "$tmp/bin/hyprctl"
chmod +x "$tmp/bin/hyprctl"

cat > "$tmp/session.conf" <<EOF
<busconfig>
  <type>session</type>
  <listen>unix:path=$tmp/session</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="*"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
EOF
dbus-daemon --config-file="$tmp/session.conf" --nofork & pids+=($!)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$tmp/session
for _ in {1..50}; do [[ -S $tmp/session ]] && break; sleep 0.1; done
[[ -S $tmp/session ]] || { echo "FAIL: dbus-daemon did not start" >&2; exit 1; }

sock=$run/hypr/inst/.socket2.sock
mkfifo "$tmp/sock2.in"
exec 3<> "$tmp/sock2.in"
"$socket2" "$sock" < "$tmp/sock2.in" > "$tmp/socket2.out" 2>&1 &
pids+=($!)
for _ in {1..50}; do [[ -S $sock ]] && break; sleep 0.1; done
[[ -S $sock ]] || { echo "FAIL: socket2 stub did not start" >&2; exit 1; }

count() {
  [[ -e $tmp/hypr/calls ]] || { echo 0; return; }
  grep -cx "$1" "$tmp/hypr/calls" || true
}
reset_calls() { rm -f "$tmp/hypr/calls"; }
eval_n() { cat "$tmp/hypr/eval-n" 2> /dev/null || echo 0; }
eval_last() { cat "$tmp/hypr/evals/$(eval_n)" 2> /dev/null || true; }
reset_evals() { rm -f "$tmp/hypr/evals/"* "$tmp/hypr/eval-n"; }
reset_faults() { rm -f "$tmp/hypr/json-rc" "$tmp/hypr/eval-rc" "$tmp/hypr/eval-reply"; }
get() { python3 -I "$client" get "$1" 2> /dev/null; }
ask() { python3 -I "$client" call "$@" 2> /dev/null; }
emit() { printf '%s\n' "$*" >&3; }
burst() { local all; printf -v all '%s\n' "$@"; /usr/bin/printf '%s' "$all" >&3; }
fixture() { python3 -I "$fixtures" "$tmp/hypr" "$@"; }
hold() { : > "$tmp/hypr/hold"; }
release() { rm -f "$tmp/hypr/hold"; }
quiet() { sleep 0.4; }
now() { read -r up _ < /proc/uptime; printf '%s\n' "$up"; }
in_window() { awk -v a="$1" -v b="$2" -v lo="$3" -v hi="$4" 'BEGIN { exit !(b - a >= lo && b - a <= hi) }'; }
drain() {
  local last=-1 current=0
  for _ in {1..80}; do
    current=$(wc -l < "$tmp/hypr/calls" 2> /dev/null || echo 0)
    [[ $current == "$last" ]] && return 0
    last=$current
    sleep 0.15
  done
  return 1
}

home_pid=
boot() {
  stop_home
  reset_faults
  : > "$tmp/home.err"
  HYPRLAND_INSTANCE_SIGNATURE=inst python3 -I "$home" 2> "$tmp/home.err" 3>&- &
  home_pid=$!
  pids+=("$home_pid")
}
stop_home() {
  [[ -n $home_pid ]] || return 0
  kill "$home_pid" 2> /dev/null || true
  wait "$home_pid" 2> /dev/null || true
  home_pid=
}
until_calls() {
  for _ in {1..160}; do [[ $(count "$1") -ge $2 ]] && return 0; sleep 0.05; done
  return 1
}
until_value() {
  for _ in {1..160}; do [[ $(get "$1") == "$2" ]] && return 0; sleep 0.05; done
  return 1
}
want() { until_value "$1" "$2" && ok || fail "$3: $1 is $(get "$1"), want $2"; }
want_calls() { local n; n=$(count "$1"); [[ $n == "$2" ]] && ok || fail "$3: $1 ran $n times, want $2"; }
settle() {
  reset_calls
  emit "configreloaded>>"
  until_calls monitors 1 || { fail "$1: no query"; return 1; }
  drain || { fail "$1: the query did not finish"; return 1; }
  reset_calls
}

flip="$tmp/flip.log"

fixture active=1
boot
python3 -I "$client" wait net.seilent.MicroOs.DesktopHome ||
  { echo "FAIL: no owner of the name: $(cat "$tmp/home.err")" >&2; exit 1; }
until_calls monitors 1 || fail "no start query"
drain || fail "the start query did not finish"
want Shown true "start on an empty workspace"
want Transform 1 "start transform"
want Windows "" "start windows"
want_calls monitors 1 "start"

settle "closewindow"
fixture active=1 "ws:2:1" "win:0x1,foot,foot,2,0"
emit "closewindow>>0x9"
until_calls monitors 1 || fail "closewindow: no re-query"
want Shown true "a window on another workspace keeps the home"
want Windows "0x1,foot,foot" "windows on any monitor"

settle "activespecial"
fixture active=1 "ws:2:1" "win:0x1,foot,foot,2,0" special=special:sp
emit "activespecial>>special:sp,DSI-1"
until_calls monitors 1 || fail "activespecial: no re-query"
want Shown false "an open special workspace hides the home"

settle "activespecial close"
fixture active=1 "ws:2:1" "win:0x1,foot,foot,2,0"
emit "activespecial>>,DSI-1"
until_calls monitors 1 || fail "activespecial close: no re-query"
want Shown true "a closed special workspace shows the home"

settle "configreloaded"
fixture active=1 "ws:2:1" "win:0x1,foot,foot,2,0" transform=3
emit "configreloaded>>"
until_calls monitors 1 || fail "configreloaded: no re-query"
want Transform 3 "transform follows the monitor JSON"

settle "workspacev2"
fixture active=1 "ws:1:1" "win:0x1,foot,foot,1,0" transform=3
emit "workspacev2>>1,1"
until_calls monitors 1 || fail "workspacev2: no re-query"
want Shown false "a window on the home workspace hides it"

settle "moveworkspacev2"
fixture active=1 "ws:1:1" "win:0x2,kitty,shell,3,0" "win:0x1,foot,foot,1,1"
emit "moveworkspacev2>>3,3,DSI-1"
until_calls monitors 1 || fail "moveworkspacev2: no re-query"
want Shown false "moveworkspacev2 re-queries Shown"
want Windows "0x2,kitty,shell|0x1,foot,foot" "windows in focus history order"

settle "pin"
fixture active=1 "ws:3:1" "win:0x3,mpv,movie,3,0" "win:0x1,foot,foot,1,1"
emit "pin>>3,1"
until_calls monitors 1 || fail "pin: no re-query"
want Shown false "pin re-queries Shown"
want Windows "0x3,mpv,movie|0x1,foot,foot" "pin re-queries Windows"

settle "windowtitlev2"
fixture active=3 "ws:3:1" "win:0x3,mpv,other movie,3,0"
emit "windowtitlev2>>3,other movie"
until_calls monitors 1 || fail "windowtitlev2: no re-query"
want Shown false "windowtitlev2 re-queries Shown"
want Windows "0x3,mpv,other movie" "windowtitlev2 re-queries Windows"

settle "windowtitle"
fixture active=3 "ws:3:1" "win:0x3,mpv,plain title,3,0"
emit "windowtitle>>3"
until_calls monitors 1 || fail "windowtitle: no re-query"
want Shown false "windowtitle re-queries Shown"
want Windows "0x3,mpv,plain title" "windowtitle re-queries Windows"

settle "focusedmon"
fixture active=1 "ws:3:1" "win:0x3,mpv,plain title,3,0" focused=0
emit "focusedmon>>HDMI-A-1,9"
until_calls monitors 1 || fail "focusedmon: no re-query"
want Shown true "a focus change on another monitor keeps the home"
want Windows "0x3,mpv,plain title" "focusedmon re-queries Windows"

settle "monitoraddedv2"
fixture active=1 "ws:3:1" "win:0x3,mpv,plain title,3,0" focused=1
emit "monitoraddedv2>>1,HDMI-A-1,HDMI"
until_calls monitors 1 || fail "monitoraddedv2: no re-query"
want Shown true "a monitor add re-queries the home"
want Windows "0x3,mpv,plain title" "a monitor add re-queries Windows"

settle "monitorremovedv2"
fixture active=1 "ws:1:1" "win:0x1,foot,foot,1,0"
emit "monitorremovedv2>>1,HDMI-A-1,HDMI"
until_calls monitors 1 || fail "monitorremovedv2: no re-query"
want Shown false "a monitor remove re-queries the home"
want Windows "0x1,foot,foot" "a monitor remove re-queries Windows"

settle "an ignored event"
emit "activewindow>>foot,foot"
quiet
want_calls monitors 0 "an event outside the list queries nothing"

settle "a burst"
burst "closewindow>>0x9" "movewindowv2>>1,1,DSI-1" "windowtitlev2>>1,x" "focusedmon>>DSI-1,1" \
  "pin>>1,1" "monitoraddedv2>>1,HDMI-A-1,HDMI" "configreloaded>>"
until_calls monitors 1 || fail "a burst of events gives no query"
drain || fail "the burst query did not finish"
want_calls monitors 1 "a burst of seven events"

settle "a burst across two reads"
hold
burst "closewindow>>0x9" "movewindowv2>>1,1,DSI-1" "windowtitlev2>>1,x" "focusedmon>>DSI-1,1" \
  "pin>>1,1" "monitoraddedv2>>1,HDMI-A-1,HDMI" "configreloaded>>"
until_calls monitors 1 || fail "a held burst gives no query"
emit "closewindow>>0x9"
release
until_calls monitors 2 || fail "an event during a burst query gives no second query"
drain || fail "the coalesced burst query did not finish"
want_calls monitors 2 "an event during a burst query coalesces into one re-query"

settle "a partial line"
reset_calls
emit "half closewindow>>0x9"
quiet
want_calls monitors 0 "half an event line queries nothing"
emit "rest"
until_calls monitors 1 || fail "the rest of the line gives no query"
drain || fail "the partial line query did not finish"
want_calls monitors 1 "the rest of the line gives one query"

settle "socket loss"
emit "close"
until_calls monitors 1 || fail "socket loss: no query after the reconnect"
drain || fail "the reconnect query did not finish"
want_calls monitors 1 "socket loss and reconnect re-queries"

settle "the transform file"
reset_calls
printf '1' > "$tmp/transform.tmp"
before=$(now)
mv -f "$tmp/transform.tmp" "$run/microos/desktop-transform"
until_calls monitors 1 || fail "a transform rename gives no query"
drain || fail "the transform query did not finish"
first=$(now)
until_calls monitors 2 || fail "a transform rename gives no 250 ms query"
drain || fail "the 250 ms query did not finish"
second=$(now)
want_calls monitors 2 "a transform rename gives the event query and the 250 ms one"
in_window "$first" "$second" 0.1 2 && ok || fail "the 250 ms re-query took $(awk -v a="$first" -v b="$second" 'BEGIN { printf "%.2f", b - a }') s"
in_window "$before" "$second" 0.2 3 && ok || fail "the transform rename took $(awk -v a="$before" -v b="$second" 'BEGIN { printf "%.2f", b - a }') s"

reset_calls
fixture active=1 "ws:2:1" "win:0x1,foot,foot,2,0" transform=0
settle "transform from the JSON"
hold
printf '1' > "$tmp/transform2"
mv -f "$tmp/transform2" "$run/microos/desktop-transform"
until_calls monitors 1 || fail "the transform rename did not start a query"
want Transform 0 "transform comes from the monitor JSON, not the file"
release
until_calls monitors 2 || fail "the 250 ms re-query did not run"
drain || fail "the transform queries did not finish"
want_calls monitors 2 "the transform rename gives two queries"
reset_calls

fixture active=1 "ws:1:0" "ws:2:1" "win:0x1,foot,foot,2,0" focused=0
settle "the workspacev2 fast path without focus"
hold
emit "workspacev2>>2,2"
quiet
[[ $(get Shown) == true ]] && ok || fail "the workspacev2 fast path flipped with DSI-1 unfocused"
release
until_calls monitors 1 || fail "the workspacev2 query did not run"
drain || fail "the workspacev2 query did not finish"
reset_calls

fixture active=1 "ws:1:0" "ws:2:1" "win:0x1,foot,foot,2,0" focused=1
settle "the fast path correction"
hold
emit "openwindow>>0x9,1,foot,foot"
for _ in {1..100}; do [[ $(get Shown) == false ]] && break; sleep 0.05; done
[[ $(get Shown) == false ]] && ok || fail "the openwindow fast path did not set Shown false"
release
until_calls monitors 1 || fail "openwindow: no re-query"
want Shown true "the re-query corrects the wrong fast flip"
reset_calls

python3 -I "$client" watch "$flip" &
pids+=($!)
sleep 0.3
fixture active=1 "ws:1:0"
settle "the stale query"
want Shown true "the home is shown before the stale query"
: > "$flip"
hold
emit "closewindow>>0x9"
until_calls monitors 1 || fail "the held query did not start"
fixture active=1 "ws:1:1" "win:0x1,foot,foot,1,0"
emit "openwindow>>0x9,1,foot,foot"
for _ in {1..100}; do grep -q '^Shown false' "$flip" 2> /dev/null && break; sleep 0.05; done
grep -q '^Shown false' "$flip" || fail "the fast path did not flip while a query was held"
release
until_calls monitors 2 || fail "the stale query was not replaced"
drain || fail "the replacement query did not finish"
want Shown false "the replacement query agrees"
sleep 0.3
[[ $(grep -c '^Shown true' "$flip") == 0 ]] && ok || fail "the stale query overwrote the fast flip"
[[ $(grep -c '^Shown false' "$flip") == 1 ]] && ok || fail "the fast flip repeated"
reset_calls

fixture active=1 "ws:1:1" "win:0x1,foot,foot,1,0" focused=1
settle "Enter with a query in flight"
want Shown false "a window hides the home before the in-flight Enter"
hold
emit "closewindow>>0x9"
until_calls monitors 1 || fail "the held query did not start"
fixture active=1 "ws:1:1" "win:0x1,foot,foot,1,0" focused=0
reset_evals
ask Enter > "$tmp/inflight" &
inflight=$!
sleep 0.3
release
wait "$inflight" || true
drain || fail "the fresh query did not finish"
want_inflight='hl.dispatch(hl.dsp.focus({monitor="DSI-1"}))
hl.dispatch(hl.dsp.focus({workspace="emptym"}))'
[[ $(eval_last) == "$want_inflight" ]] && ok || fail "the in-flight Enter used stale state: $(eval_last)"
reset_calls

fixture active=1 "ws:1:0" "win:0x5,foot,pinned,1,0,pinned"
settle "a pinned window"
want Shown true "a pinned window does not fill the home workspace"
want Windows "0x5,foot,pinned" "a pinned window is still listed"

fixture active=1 "ws:2:1" "win:0x6,foot,BADBYTE,2,0"
settle "an invalid title byte"
bad=$(printf '\357\277\275')
want Windows "0x6,foot,$bad" "an invalid title byte is replaced"

fixture active=1 "ws:1:0"
settle "Enter while shown"
want Shown true "the home is shown before the Enter no op"
reset_evals
ask Enter > /dev/null
quiet
[[ $(eval_n) == 0 ]] && ok || fail "Enter on a shown home dispatched $(eval_n) evals"

fixture active=1 "ws:1:1" "win:0x1,foot,foot,1,0"
settle "Enter with DSI-1 focused"
want Shown false "a window hides the home before Enter"
reset_evals
ask Enter > /dev/null
[[ $(eval_last) == 'hl.dispatch(hl.dsp.focus({workspace="emptym"}))' ]] &&
  ok || fail "Enter with DSI-1 focused: $(eval_last)"

fixture active=1 "ws:1:1" "win:0x1,foot,foot,1,0" focused=0
settle "Enter with another monitor focused"
want Shown false "a window hides the home before Enter"
reset_evals
ask Enter > /dev/null
want_mon='hl.dispatch(hl.dsp.focus({monitor="DSI-1"}))
hl.dispatch(hl.dsp.focus({workspace="emptym"}))'
[[ $(eval_last) == "$want_mon" ]] && ok || fail "Enter with another monitor focused: $(eval_last)"

fixture active=1 "ws:1:1" "win:0x1,foot,foot,1,0" special=special:sp
settle "Enter with a special workspace open"
want Shown false "a special workspace hides the home before Enter"
reset_evals
ask Enter > /dev/null
want_sp='hl.dispatch(hl.dsp.workspace.toggle_special("sp"))
hl.dispatch(hl.dsp.focus({workspace="emptym"}))'
[[ $(eval_last) == "$want_sp" ]] && ok || fail "Enter with a special workspace open: $(eval_last)"

fixture active=1 "ws:1:1" "win:0x1,foot,foot,1,0" special=special:sp focused=0
settle "Enter with a special workspace and another monitor"
want Shown false "a special workspace hides the home before Enter"
reset_evals
ask Enter > /dev/null
want_all='hl.dispatch(hl.dsp.focus({monitor="DSI-1"}))
hl.dispatch(hl.dsp.workspace.toggle_special("sp"))
hl.dispatch(hl.dsp.focus({workspace="emptym"}))'
[[ $(eval_last) == "$want_all" ]] && ok || fail "Enter with a special workspace and another monitor: $(eval_last)"

fixture active=1 "ws:1:1" "win:0x1,foot,foot,1,0"
settle "Leave to the remembered workspace"
ask Enter > /dev/null
fixture active=5 "ws:1:1" "ws:5:0" "win:0x1,foot,foot,1,0"
emit "workspacev2>>5,5"
until_value Shown true || fail "no home state before Leave"
reset_evals
ask Leave > /dev/null
[[ $(eval_last) == 'hl.dispatch(hl.dsp.focus({workspace="1"}))' ]] &&
  ok || fail "Leave to the remembered workspace: $(eval_last)"

setup_previous() {
  fixture active=1 "ws:1:1" "win:0x1,foot,foot,1,0"
  settle "the previous setup"
  ask Enter > /dev/null
  fixture active=3 "ws:1:0" "ws:3:1" "win:0x3,mpv,movie,3,0"
  emit "workspacev2>>3,3"
  until_value Shown false || fail "workspace 3 with a window is not the home"
  fixture active=5 "ws:1:0" "ws:3:1" "ws:5:0" "win:0x3,mpv,movie,3,0"
  emit "workspacev2>>5,5"
  until_value Shown true || fail "workspace 5 is not the home"
}

settle "Leave to previous"
setup_previous
reset_evals
ask Leave > /dev/null
want_prev='hl.dispatch(hl.dsp.focus({monitor="DSI-1"}))
hl.dispatch(hl.dsp.focus({workspace="3"}))'
[[ $(eval_last) == "$want_prev" ]] && ok || fail "Leave to previous: $(eval_last)"

settle "Leave with nothing remembered"
fixture active=1 "ws:1:1" "win:0x1,foot,foot,1,0"
settle "the remembered clear"
fixture active=3 "ws:1:1" "ws:3:1" "win:0x3,mpv,movie,3,0"
emit "workspacev2>>3,3"
until_value Shown false || fail "workspace 3 with a window is not the home"
fixture active=1 "ws:1:0" "ws:3:1" "win:0x3,mpv,movie,3,0"
emit "workspacev2>>1,1"
until_value Shown true || fail "workspace 1 is not the home"
reset_evals
ask Leave > /dev/null
[[ $(eval_last) == "$want_prev" ]] && ok || fail "Leave with no remembered workspace: $(eval_last)"

settle "Leave with nothing to return to"
fixture active=1 "ws:1:1" "win:0x1,foot,foot,1,0"
ask Enter > /dev/null
fixture active=6 "ws:1:0" "ws:6:0"
emit "workspacev2>>6,6"
until_value Shown true || fail "no home state on workspace 6 before Leave"
reset_evals
ask Leave > /dev/null
quiet
[[ $(eval_n) == 0 ]] && ok || fail "Leave with nothing to return to dispatched $(eval_n) evals"

settle "Toggle while shown"
setup_previous
reset_evals
ask Toggle > /dev/null
[[ $(eval_last) == "$want_prev" ]] && ok || fail "Toggle while shown: $(eval_last)"
fixture active=1 "ws:1:1" "win:0x1,foot,foot,1,0"
settle "Toggle while not shown"
reset_evals
ask Toggle > /dev/null
[[ $(eval_last) == 'hl.dispatch(hl.dsp.focus({workspace="emptym"}))' ]] &&
  ok || fail "Toggle while not shown: $(eval_last)"

fixture active=1 "ws:1:1" "win:0x1,foot,foot,1,0"
settle "FocusWindow"
reset_evals
ask FocusWindow 0x1 > /dev/null
[[ $(eval_last) == 'hl.dispatch(hl.dsp.focus({window="address:0x1"}))' ]] &&
  ok || fail "FocusWindow on a known address: $(eval_last)"
reset_evals
r=$(ask FocusWindow 0xbeef)
[[ $r == org.freedesktop.DBus.Error.InvalidArgs ]] && ok || fail "FocusWindow on an unknown address: $r"
quiet
[[ $(eval_n) == 0 ]] && ok || fail "FocusWindow on an unknown address dispatched an eval"

echo 4 > "$tmp/hypr/eval-rc"
r=$(ask Enter)
[[ $r == net.seilent.MicroOs.DesktopHome1.Failed ]] && ok || fail "hyprctl exit 4: $r"
echo 6 > "$tmp/hypr/eval-rc"
r=$(ask Enter)
[[ $r == net.seilent.MicroOs.DesktopHome1.Failed ]] && ok || fail "hyprctl exit 6: $r"
reset_faults
printf 'warning: something\n' > "$tmp/hypr/eval-reply"
r=$(ask Enter)
[[ $r == net.seilent.MicroOs.DesktopHome1.Failed ]] && ok || fail "a warning reply: $r"

reset_faults
mkfifo "$tmp/hypr/eval-freeze"
before=$(now)
r=$(ask Enter)
after=$(now)
[[ $r == net.seilent.MicroOs.DesktopHome1.Failed ]] && ok || fail "a hung hyprctl: $r"
in_window "$before" "$after" 2 8 && ok || fail "the hung hyprctl bound took $(awk -v a="$before" -v b="$after" 'BEGIN { printf "%.2f", b - a }') s"
rm -f "$tmp/hypr/eval-freeze"
reset_faults

fixture active=1 "ws:1:1" "win:0x1,foot,foot,1,0"
emit "closewindow>>0x9"
until_value Shown false || fail "no window state before the failing query"
before=$(get Shown)
fixture active=1 "ws:1:0"
echo 1 > "$tmp/hypr/json-rc"
emit "closewindow>>0x9"
until_calls monitors 1 || fail "a failing hyprctl did not run a query"
drain || fail "the failing query did not finish"
[[ $(get Shown) == "$before" ]] && ok || fail "a failing hyprctl changed the state"
reset_faults

stop_home
r=0
env -u HYPRLAND_INSTANCE_SIGNATURE python3 -I "$home" > "$tmp/out" 2>&1 || r=$?
[[ $r == 2 ]] && ok || fail "an empty HYPRLAND_INSTANCE_SIGNATURE exited $r"
grep -qx 'microos-desktop-home: HYPRLAND_INSTANCE_SIGNATURE is empty' "$tmp/out" && ok ||
  fail "an empty HYPRLAND_INSTANCE_SIGNATURE logged: $(cat "$tmp/out")"

if (( rc == 0 )); then
  echo "desktop-home: ok ($checks checks)"
fi
exit "$rc"
