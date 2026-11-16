#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
gameidle=$tree/usr/libexec/microos/microos-gameidle
unit=$tree/usr/lib/systemd/user/microos-gameidle.service
dropin=$tree/usr/lib/systemd/user/gamescope-session-plus@steam.service.d/30-microos-gameidle.conf
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

[[ $(< "$dropin") == $'[Unit]\nWants=microos-gameidle.service' ]] || fail "30-microos-gameidle.conf"
for l in BindsTo=gamescope-session-plus@steam.service After=gamescope-session-plus@steam.service \
  ExecStart=/usr/libexec/microos/microos-gameidle Restart=always StartLimitIntervalSec=0; do
  grep -qxF "$l" "$unit" || fail "microos-gameidle.service lacks $l"
done

cat > "$tmp/session.conf" <<CONF
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
CONF
dbus-daemon --config-file="$tmp/session.conf" --nofork & pids+=($!)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$tmp/session
for _ in {1..50}; do [[ -S $tmp/session ]] && break; sleep 0.1; done

waitfor() {
  for _ in {1..50}; do grep -q "$2" "$1" 2> /dev/null && return 0; sleep 0.1; done
  return 1
}
count() { grep -c "$2" "$1" 2> /dev/null || true; }

python3 "$here/gameidle/saver" "$tmp/saver.log" & pids+=($!)
waitfor "$tmp/saver.log" ready || fail "ScreenSaver stub did not start"

mkdir -p "$tmp/proc/10" "$tmp/proc/11" "$tmp/proc/self"
printf '/usr/bin/bash\0-c\0reaper SteamLaunch\0' > "$tmp/proc/10/cmdline"
printf '/usr/bin/steam\0-gamepadui\0' > "$tmp/proc/11/cmdline"
MICROOS_GAMEIDLE_PROC=$tmp/proc MICROOS_GAMEIDLE_POLL=0.2 python3 "$gameidle" 2> "$tmp/gameidle.err" & pids+=($!)
sleep 1
[[ $(count "$tmp/saver.log" "^inhibit") == 0 ]] || fail "inhibited without a game: $(cat "$tmp/saver.log")"

printf '/home/micro/.local/share/Steam/steamrtarm64/reaper\0SteamLaunch\0AppId=1\0--\0game\0' > "$tmp/proc/10/cmdline"
waitfor "$tmp/saver.log" "^inhibit 1 " || fail "no inhibit with a game running: $(cat "$tmp/saver.log")"
sleep 1
[[ $(count "$tmp/saver.log" "^inhibit") == 1 ]] || fail "inhibited more than once: $(cat "$tmp/saver.log")"

printf '/usr/bin/steam\0-gamepadui\0' > "$tmp/proc/10/cmdline"
waitfor "$tmp/saver.log" "^uninhibit 1$" || fail "not released after the game exited: $(cat "$tmp/saver.log")"

printf '/home/micro/.local/share/Steam/steamrtarm64/reaper\0SteamLaunch\0AppId=2\0' > "$tmp/proc/10/cmdline"
waitfor "$tmp/saver.log" "^inhibit 2 " || fail "no inhibit for a second game: $(cat "$tmp/saver.log")"

if (( rc == 0 )); then
  echo "gameidle: ok"
fi
exit "$rc"
