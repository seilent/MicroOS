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

hid() { python3 "$here/vpad/hidfd" "$vpad" "$@" 2>&1; }
transport() {
  local got
  got=$(hid "$1")
  [[ $got == "register in pri"$'\n'"$2" ]] || fail "hid transport '$1': $(tr '\n' '|' <<< "$got")"
}
serial=4d4943524f4f5359373030
reply() { printf 'ioctl reply %02x014000ae0c01%s00%0106d' "$1" "$serial" 0; }
transport 'send read=ae1501 in id=0 pri' $'write 64 ok\nread ae1501\nread EAGAIN\nread EAGAIN\nioctl id 0\n'"$(reply 0)"
transport 'read=ea0402010000 read=ae1501 id=3 in+pri' \
  $'read ea0402010000\nplay left 12 40960\nplay right 12 40960\nread ae1501\nread EAGAIN\nioctl id 3\n'"$(reply 3)"
paused=$'read ENOMEM\nmodify pri'
transport 'read=ENOMEM in in send read=ae1501 in' "$paused"$'\nwrite 64 ok\nmodify in pri\nread ae1501\nread EAGAIN'
transport 'read=ENOMEM in write=EAGAIN send in' "$paused"$'\nwrite 64 EAGAIN\nmodify in pri\nread EAGAIN'
transport 'read=ENOMEM in write=ESHUTDOWN send in' "$paused"$'\nwrite 64 ESHUTDOWN'
transport 'read=ENOMEM in write=EIO send write=EIO send' \
  "$paused"$'\nwrite 64 EIO\nmicroos-vpad: hidg: Input/output error\nmodify in pri\nwrite 64 EIO'
transport 'read=ENOMEM in read=ae1501 id=0 pri' "$paused"$'\nmodify in pri\nread ae1501\nread EAGAIN\nioctl id 0\n'"$(reply 0)"

export FAKE_STATE=$tmp/fake
cfg=$tmp/config
class=$tmp/class
module=$tmp/module
g=$cfg/usb_gadget/microos-vpad
desc=06ffff0901a10109020903150026ff00750895408102090609071500
desc+=26ff0075089540b102c0
kbd=05010906a101050719e029e715002501750195088102950175088101950575010508190129059102950175039101
kbd+=95067508150025650507190029658100c0
greset() {
  rm -rf "${cfg:?}" "${class:?}" "${module:?}" "${FAKE_STATE:?}"
  mkdir -p "$cfg/usb_gadget" "$class/udc/a600000.usb" "$class/udc/dummy_udc.0" "$module" "$FAKE_STATE"
}
gadget() {
  env MICROOS_CONFIGFS="$cfg" MICROOS_SYSCLASS="$class" MICROOS_SYSMODULE="$module" MICROOS_MODPROBE="$here/vpad/modprobe" \
    python3 "$here/vpad/configfs" "$vpad" gadget "$@" 2> "$tmp/err"
}
hex() { od -An -tx1 -v "$1" | tr -d ' \n'; }
check_gadget() {
  local f
  [[ $(cat "$g/idVendor" "$g/idProduct" "$g/bcdDevice" "$g/bcdUSB" | tr '\n' ' ') == '0x28de 0x1205 0x0300 0x0200 ' ]] \
    || fail "$1: ids $(cat "$g/idVendor" "$g/idProduct" "$g/bcdDevice" "$g/bcdUSB" | tr '\n' ' ')"
  [[ $(< "$g/strings/0x409/manufacturer") == 'Valve Software' && $(< "$g/strings/0x409/product") == 'Steam Deck Controller' \
    && $(< "$g/strings/0x409/serialnumber") == MICROOSY700 ]] || fail "$1: strings $(cat "$g/strings/0x409/"* | tr '\n' '|')"
  [[ $(ls "$g/configs") == c.1 && $(ls "$g/configs/c.1" | tr '\n' ' ') == 'hid.ctl hid.kbd hid.kbd2 strings ' ]] \
    || fail "$1: config $(ls -R "$g/configs" | tr '\n' ' ')"
  [[ -z $(ls "$g/configs/c.1/strings") ]] || fail "$1: config strings $(ls "$g/configs/c.1/strings" | tr '\n' ' ')"
  [[ $(ls "$g/functions" | tr '\n' ' ') == 'hid.ctl hid.kbd hid.kbd2 ' ]] || fail "$1: functions $(ls "$g/functions" | tr '\n' ' ')"
  [[ $(tr '\n' ' ' < "$FAKE_STATE/links.log") == 'hid.kbd hid.kbd2 hid.ctl ' ]] || fail "$1: link order $(tr '\n' ' ' < "$FAKE_STATE/links.log")"
  for f in hid.kbd hid.kbd2 hid.ctl; do
    [[ $(readlink "$g/configs/c.1/$f") == "$g/functions/$f" ]] || fail "$1: $f not linked"
    [[ $(< "$g/functions/$f/no_out_endpoint") == 1 ]] || fail "$1: $f no_out_endpoint $(cat "$g/functions/$f/no_out_endpoint")"
  done
  [[ $(< "$g/functions/hid.kbd/report_length") == 8 && $(< "$g/functions/hid.kbd2/report_length") == 8 \
    && $(< "$g/functions/hid.ctl/report_length") == 64 ]] || fail "$1: report lengths"
  [[ $(hex "$g/functions/hid.kbd/report_desc") == "$kbd" && $(hex "$g/functions/hid.kbd2/report_desc") == "$kbd" \
    && $(hex "$g/functions/hid.ctl/report_desc") == "$desc" ]] || fail "$1: report descriptors"
  [[ $(< "$g/UDC") == dummy_udc.0 ]] || fail "$1: UDC $(cat "$g/UDC")"
  [[ $(tail -n 1 "$FAKE_STATE/modprobe.log") == 'modprobe dummy_hcd tick_us=1000' ]] || fail "$1: modprobe $(cat "$FAKE_STATE/modprobe.log")"
  [[ $(< "$tmp/err") == 'microos-vpad: bound to dummy_udc.0' ]] || fail "$1: $(cat "$tmp/err")"
}

greset
gadget start || fail "gadget start: exit $?: $(cat "$tmp/err")"
check_gadget "gadget start"
echo 240:2 > "$g/functions/hid.ctl/dev"
for n in 0:240:0 1:240:1 7:240:2; do
  mkdir -p "$class/hidg/hidg${n%%:*}"
  echo "${n#*:}" > "$class/hidg/hidg${n%%:*}/dev"
done
got=$(MICROOS_CONFIGFS=$cfg MICROOS_SYSCLASS=$class vp node)
[[ $got == /dev/hidg7 ]] || fail "hid.ctl node: $got"
gadget stop || fail "gadget stop: exit $?: $(cat "$tmp/err")"
[[ ! -e $g ]] || fail "gadget stop left $(find "$g" | tr '\n' ' ')"
[[ $(tail -n 1 "$FAKE_STATE/modprobe.log") == 'modprobe -r dummy_hcd' && ! -e $module/dummy_hcd ]] \
  || fail "gadget stop modprobe: $(cat "$FAKE_STATE/modprobe.log")"
[[ -d $cfg/usb_gadget && -d $class/udc/dummy_udc.0 ]] || fail "gadget stop removed more than the gadget"
gadget stop || fail "second gadget stop: exit $?: $(cat "$tmp/err")"
[[ $(wc -l < "$FAKE_STATE/modprobe.log") == 2 && ! -s $tmp/err ]] || fail "second gadget stop: $(cat "$FAKE_STATE/modprobe.log" "$tmp/err")"

greset
gadget stop || fail "gadget stop with nothing loaded: exit $?: $(cat "$tmp/err")"
[[ ! -e $FAKE_STATE/modprobe.log && ! -s $tmp/err ]] || fail "gadget stop with nothing loaded ran modprobe"
mkdir "$module/dummy_hcd"
gadget stop || fail "gadget stop with no gadget: exit $?: $(cat "$tmp/err")"
[[ $(< "$FAKE_STATE/modprobe.log") == 'modprobe -r dummy_hcd' && ! -e $module/dummy_hcd ]] \
  || fail "gadget stop with no gadget: $(cat "$FAKE_STATE/modprobe.log")"

greset
mkdir -p "$g/strings/0x409" "$g/configs/c.1/strings/0x409" "$g/functions/hid.old"
echo 0x1234 > "$g/idVendor"
echo old > "$g/strings/0x409/product"
echo dummy_udc.0 > "$g/UDC"
echo 8 > "$g/functions/hid.old/report_length"
ln -s "$g/functions/hid.old" "$g/configs/c.1/hid.old"
gadget start || fail "leftover gadget: exit $?: $(cat "$tmp/err")"
check_gadget "leftover gadget"

greset
if FAKE_LINK_FAIL=hid.ctl gadget start; then
  fail "gadget start passed with a failed hid.ctl link"
fi
[[ $(tr '\n' ' ' < "$FAKE_STATE/links.log") == 'hid.kbd hid.kbd2 ' && $(< "$tmp/err") == *"hid.ctl: Input/output error"* ]] \
  || fail "failed link: $(cat "$FAKE_STATE/links.log" "$tmp/err")"
[[ ! -e $g ]] || fail "failed gadget start left $(find "$g" | tr '\n' ' ')"

greset
if FAKE_WRITE_FAIL=UDC gadget start; then
  fail "gadget start passed with a failed UDC write"
fi
[[ $(< "$tmp/err") == *"$g/UDC: No such device"* ]] || fail "failed UDC write: $(cat "$tmp/err")"
[[ ! -e $g ]] || fail "failed UDC write left $(find "$g" | tr '\n' ' ')"

greset
mkdir -p "$module/dummy_hcd/parameters"
echo 125 > "$module/dummy_hcd/parameters/tick_us"
if gadget start; then
  fail "gadget start passed with dummy_hcd at tick_us 125"
fi
[[ $(< "$tmp/err") == 'microos-vpad: dummy_hcd runs with tick_us 125, not 1000' && ! -e $g ]] \
  || fail "tick_us 125: $(cat "$tmp/err")"

greset
rm -rf "${class:?}/udc/dummy_udc.0"
if gadget start; then
  fail "gadget start passed without a dummy_udc"
fi
[[ $(< "$tmp/err") == "microos-vpad: no dummy_udc in $class/udc after modprobe" && ! -e $g ]] \
  || fail "no dummy_udc: $(cat "$tmp/err"), $(ls -R "$cfg")"

r=0
gadget bogus || r=$?
(( r == 2 )) || fail "gadget usage exit $r"

gunit=$tree/usr/lib/systemd/system/microos-vpad-gadget.service
for l in RestrictAddressFamilies=AF_UNIX RuntimeDirectory=microos-vpad PrivateNetwork=yes CapabilityBoundingSet= \
  'InaccessiblePaths=-/run/dbus -/run/systemd -/run/user -/run/udev -/run/chrony' 'DeviceAllow=char-hidg rw' \
  Requires=microos-vpad-gadget.service After=microos-vpad-gadget.service; do
  grep -qxF "$l" "$unit" || fail "microos-vpad.service lacks $l"
done
! grep -q uhid "$unit" || fail "microos-vpad.service still names uhid"
for l in StopWhenUnneeded=yes Type=oneshot RemainAfterExit=yes 'ExecStart=/usr/libexec/microos/microos-vpad gadget start' \
  'ExecStop=/usr/libexec/microos/microos-vpad gadget stop'; do
  grep -qxF "$l" "$gunit" || fail "microos-vpad-gadget.service lacks $l"
done
! grep -q '^\[Install\]' "$gunit" || fail "microos-vpad-gadget.service has an [Install] section"

if (( rc == 0 )); then
  echo "vpad: ok"
fi
exit "$rc"
