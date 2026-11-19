#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
vpad=$tree/usr/libexec/microos/microos-vpad
unit=$tree/usr/lib/systemd/system/microos-vpad.service
tmp=$(mktemp -d)
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done
  rm -rf "${tmp:?}"
}
trap cleanup EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

vp() { MICROOS_VPAD_DRYRUN=$1 python3 "$vpad" "${@:2}" 2>&1; }
check() {
  local got
  got=$(vp power 1200 "$1")
  [[ $got == "$2" ]] || fail "power '$1': $(tr '\n' '|' <<< "$got")"
}

off=$'save 1200\nbl 0\ngrab'
check 'key=0:1 key=80:0' "$off"
check 'key=0:1 key=80:0 key=1000:1 key=1050:0' "$off"$'\nbl 1200\nungrab'
check 'key=0:1 key=80:0 key=200:1 key=260:0' 'qam'
check 'key=0:1 key=1500:0' ''
check 'helper=1 key=0:1 key=80:0' $'send down 0.000000 on\nsend single 0.000000 on'
check 'helper=1 key=0:1 key=80:0 key=200:1 key=260:0' \
  $'send down 0.000000 on\nsend down 0.200000 on\nsend double 0.200000 on\nqam'
check 'helper=1 key=0:1 key=1500:0' $'send down 0.000000 on\nsend hold 0.000000 on'
check 'helper=1 key=0:1 key=700:0' 'send down 0.000000 on'
check 'helper=1 word=blank' "$off"$'\nsend state off'
check 'helper=1 word=blank word=blank word=restore word=restore' "$off"$'\nsend state off\nsend state off\nbl 1200\nungrab\nsend state on\nsend state on'
check 'helper=1 word=blank key=0:1 key=80:0 key=200:1 key=260:0' \
  "$off"$'\nsend state off\nsend down 0.000000 off\nsend down 0.200000 off\nsend double 0.200000 off'
check 'helper=1 word=blank bl=900 word=blank' "$off"$'\nsend state off\nbl 0\nsend state off'
check 'helper=1 word=bogus' 'microos-vpad: power key helper: unknown word '"'bogus'"
check 'helper=1 word=blank helper=0 key=0:1 key=80:0' "$off"$'\nsend state off\nbl 1200\nungrab'
check 'word=qam' 'qam'
check 'helper=1 word=qam' $'qam\nsend state on'

mset() { MICROOS_VPAD_MICROSET=1 check "$@"; }
dark=$'bl_power 4\ngrab'
mset 'key=0:1 key=80:0 key=200:1 key=260:0' ''
mset 'helper=1 key=0:1 key=80:0 key=200:1 key=260:0' $'send down 0.000000 on\nsend down 0.200000 on\nsend double 0.200000 on'
mset 'key=0:1 key=80:0' "$dark"
mset 'key=0:1 key=80:0 key=1000:1 key=1050:0' "$dark"$'\nbl_power 0\nungrab'
mset 'helper=1 word=blank word=restore' "$dark"$'\nsend state off\nbl_power 0\nungrab\nsend state on'
mset 'helper=1 word=blank bl=900 word=blank' "$dark"$'\nsend state off\nsend state off'
mset 'helper=1 word=blank blp=0 word=blank' "$dark"$'\nsend state off\nbl_power 4\nsend state off'
mset 'helper=1 word=qam' $'qam\nsend state on'
mset 'helper=1 word=blank key=0:1 key=80:0 key=200:1 key=260:0' \
  "$dark"$'\nsend state off\nsend down 0.000000 off\nsend down 0.200000 off\nsend double 0.200000 off'
mset 'resume=1000 key=900:1 key=900:0' ''
mset 'resume=1000 key=9000:1 key=9080:0' "$dark"
mset 'key=0:1 key=80:0 at=1000 resume=10000 blp=0 check=10100 key=9500:1 key=9500:0' "$dark"$'\nungrab'
mset 'key=0:1 key=80:0 at=1000 resume=10000 blp=0 check=10500 check=11600' "$dark"$'\nbl_power 4'
mset 'helper=1 word=blank resume=10000 blp=0 check=20000 key=9500:1 key=9500:0 word=restore' \
  "$dark"$'\nsend state off\nsend down 9.500000 off\nungrab\nsend state on\nsend single 9.500000 on'
mset 'helper=1 word=blank resume=10000 blp=0 check=20000 word=blank' "$dark"$'\nsend state off\nbl_power 4\nsend state off'
mset 'helper=1 word=blank resume=10000 blp=0 helper=0 check=12000' "$dark"$'\nsend state off\nbl_power 4'
check 'resume=1000 key=900:1 key=900:0' ''
[[ $(vp resume 0) == None && $(vp resume 200) == 5 ]] || fail "resume detection: $(vp resume 0) $(vp resume 200)"

pulse=$'1000 4\n1099 4\n1100 0'
[[ $(vp qam 1000 1000 1099 1100) == "$pulse" ]] || fail "qam pulse: $(vp qam 1000 1000 1099 1100 | tr '\n' '|')"
[[ $(MICROOS_VPAD_MICROSET=1 vp qam 1000 1000 1099 1100) == "$pulse" ]] || fail "qam pulse with MicroSet"
for t in '900 1200 4|bl_power 0' '0 1200 4|bl_power 0'$'\nbl 1200' '900 1200 0|' '0 none 0|bl 512'; do
  read -r level saved power <<< "${t%%|*}"
  got=$(vp stop "$level" "$saved" "$power")
  [[ $got == "${t#*|}" ]] || fail "stop ${t%%|*}: $(tr '\n' '|' <<< "$got")"
done

unit_of() { awk -F/ '/^0::/ { print $NF }' /proc/self/cgroup; }
here_unit=$(unit_of)
link() {
  local tag=$1 user=$2 group=${3:-$here_unit}
  rm -f "$tmp/in.$tag"
  mkfifo "$tmp/in.$tag"
  MICROOS_VPAD_DRYRUN=link MICROOS_VPAD_SOCKET=$tmp/power.$tag MICROOS_VPAD_HELPER=$user MICROOS_VPAD_HELPER_UNIT=$group python3 "$vpad" 1200 \
    < "$tmp/in.$tag" > "$tmp/out.$tag" 2> "$tmp/err.$tag" & pids+=($!)
  exec {hold}> "$tmp/in.$tag"
  for _ in {1..50}; do grep -qx ready "$tmp/out.$tag" 2> /dev/null && return 0; sleep 0.1; done
  fail "link $tag: not ready: $(cat "$tmp/err.$tag")"
}
client() { python3 "$here/vpad/client" "$tmp/power.$1" "$tmp/in.$1" "${@:2}" 2>&1; }

me=$(id -un)
link a "$me"
[[ $(stat -c %a "$tmp/power.a") == 666 ]] || fail "socket mode $(stat -c %a "$tmp/power.a")"
got=$(client a recv key:0:1 key:80:0 recv at:380 recv send:blank recv send:restore recv)
[[ $got == $'state on\ndown 0.000000 on\nsingle 0.000000 on\nstate off\nstate on' ]] || fail "link: $(tr '\n' '|' <<< "$got")"
[[ $(cat "$tmp/out.a") == $'ready\nsave 1200\nbl 0\ngrab\nbl 1200\nungrab' ]] || fail "link screen: $(tr '\n' '|' <<< "$(cat "$tmp/out.a")")"
python3 - "$tmp/power.a" > "$tmp/first" 2>&1 <<'PY' & pids+=($!)
import socket
import sys
import time
c = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
c.connect(sys.argv[1])
c.settimeout(5)
print(c.recv(64).decode())
time.sleep(1)
print(c.recv(64).decode() or "closed")
PY
sleep 0.5
got=$(client a recv send:blank recv)
[[ $got == $'state on\nstate off' ]] || fail "second client: $(tr '\n' '|' <<< "$got")"
wait "${pids[-1]}" || true
[[ $(cat "$tmp/first") == $'state on\nclosed' ]] || fail "first client not dropped: $(tr '\n' '|' < "$tmp/first")"
grep -qx 'microos-vpad: power key helper connected' "$tmp/err.a" || fail "no connect line: $(cat "$tmp/err.a")"

link b microos-no-such-user
got=$(client b recv)$(client b recv)
[[ $got == closedclosed ]] || fail "foreign uid not refused: $got"
[[ $(grep -c "^microos-vpad: power key helper: uid $(id -u) in .* refused$" "$tmp/err.b") == 1 ]] || fail "uid refusal lines: $(cat "$tmp/err.b")"

link c "$me" microos-powerkey.service
got=$(client c recv)$(client c recv)
[[ $got == closedclosed ]] || fail "foreign cgroup not refused: $got"
[[ $(grep -c "^microos-vpad: power key helper: uid $(id -u) in .* refused$" "$tmp/err.c") == 1 ]] || fail "cgroup refusal lines: $(cat "$tmp/err.c")"

for l in RestrictAddressFamilies=AF_UNIX RuntimeDirectory=microos-vpad PrivateNetwork=yes CapabilityBoundingSet= \
  'InaccessiblePaths=-/run/dbus -/run/systemd -/run/user -/run/udev -/run/chrony'; do
  grep -qxF "$l" "$unit" || fail "microos-vpad.service lacks $l"
done

if (( rc == 0 )); then
  echo "vpad: ok"
fi
exit "$rc"
