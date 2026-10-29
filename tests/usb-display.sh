#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
lib=$tree/usr/libexec/microos
part=$lib/microos-usb-display
link=$lib/microos-usb-display-link
arm_sh=$lib/microos-usb-display-arm
gadget_sh=$lib/microos-usb-display-gadget
rules=$tree/usr/lib/udev/rules.d/70-microos-usb-display.rules
sys_units=$tree/usr/lib/systemd/system
user_units=$tree/usr/lib/systemd/user
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
export PYTHONDONTWRITEBYTECODE=1

for f in "$part" "$link" "$arm_sh" "$gadget_sh"; do
  [[ -x $f ]] || fail "${f#"$tree"} is not executable"
done
python3 -c 'import evdev, gi; gi.require_version("Gst", "1.0"); gi.require_version("GstVideo", "1.0")' ||
  { echo "FAIL: python3-evdev, python3-gobject or the GStreamer typelibs missing" >&2; exit 1; }
command -v openssl > /dev/null || { echo "FAIL: openssl missing" >&2; exit 1; }

mkdir -p "$tmp/link" "$tmp/session"
python3 "$here/usb-display/link" "$link" "$here/usb-display/wire-vectors.json" "$tmp/link" || fail "link"
python3 "$here/usb-display/session" "$part" "$link" "$here/usb-display" "$tmp/session" || fail "session part"

stubpath=$here/usb-display/bin:$PATH
export STUB_LOG=$tmp/stub.log STUB_NET=$tmp/net
log_is() { [[ $(< "$STUB_LOG") == "$1" ]]; }

sys=$tmp/sys
run=$tmp/run
stub=$tmp/hold
clock=$tmp/clock
added=1000000000
cat > "$tmp/session-bin" <<EOF
. "$tree/usr/bin/microos-session"
mono() { local t; read -r t < "$clock"; echo "\$t"; echo \$(( t + \${FAKE_STEP:-0} )) > "$clock"; }
EOF

arm_reset() {
  rm -rf "${sys:?}" "${run:?}" "${stub:?}"
  local input=$sys/devices/platform/aya-keys/input/input0
  mkdir -p "$sys/class/typec/port0" "$sys/class/typec/port0-partner" "$sys/class/udc/a600000.usb" "$sys/class/input" \
    "$input/event0" "$input/id" "$sys/bus/platform/drivers/gpio-keys" "$run/hold" "$run/usb-display" "$stub"
  echo "host [device]" > "$sys/class/typec/port0/data_role"
  echo aya-keys > "$input/name"
  for f in bustype:0019 vendor:0001 product:0001; do
    echo "${f#*:}" > "$input/id/${f%:*}"
  done
  ln -s .. "$input/event0/device"
  ln -s ../.. "$input/device"
  ln -s ../../../bus/platform/drivers/gpio-keys "$sys/devices/platform/aya-keys/driver"
  ln -s ../../devices/platform/aya-keys/input/input0/event0 "$sys/class/input/event0"
  : > "$run/hold/.lock-keys"
  chmod 600 "$run/hold/.lock-keys"
  mkfifo "$stub/hold.rc" "$stub/hold.started" "$stub/hold.done"
  : > "$stub/hold.log"
  : > "$STUB_LOG"
  echo $(( added + ${1:-100000} )) > "$clock"
}
arm_start() {
  exec 7<> "$stub/hold.done" 8<> "$stub/hold.started"
  PATH=$stubpath MICROOS_SESSION_BIN=$tmp/session-bin MICROOS_SYSFS=$sys MICROOS_DEV=/dev MICROOS_RUNDIR=$run \
    MICROOS_PAD_HOLD=$here/usb-display/pad-hold STUB_DIR=$stub STUB_ADDED=$added \
    timeout --foreground -s KILL 30 bash "$arm_sh" 2> "$tmp/arm.err" &
  apid=$!
}
hold_started() { local x=""; read -r -t 10 x <&8 && [[ $x == started ]]; }
release() { echo "$1" 1<> "$stub/hold.rc"; }
hold_done() { local x=""; read -r -t 10 x <&7 && [[ $x == done ]]; }
killed() { hold_done || { fail "$1: pad-hold not stopped"; release 1; hold_done; }; }
arm_wait() {
  r=0
  wait "$apid" || r=$?
  exec 7<&- 8<&-
}
arm_logged() { grep -qF "$1" "$tmp/arm.err"; }
armed() { [[ -f $run/usb-display/armed && $(stat -c %a "$run/usb-display/armed") == 600 ]]; }
no_flag() { [[ ! -e $run/usb-display/armed ]] && ! compgen -G "$run/usb-display/.armed.*" > /dev/null; }
hold_is() { [[ $(< "$stub/hold.log") == "$1" ]]; }
udev_call="udevadm info --query=property --property=USEC_INITIALIZED --value /class/typec/port0-partner"
start_call="systemctl start --no-block --job-mode=fail microos-usb-display-gadget.service|flag=600"

arm_reset
arm_start
hold_started || fail "armed: pad-hold not started"
release 0
hold_done || fail "armed: pad-hold did not finish"
arm_wait
(( r == 0 )) || fail "armed: exit $r: $(cat "$tmp/arm.err")"
armed || fail "armed: no root 0600 flag"
! compgen -G "$run/usb-display/.armed.*" > /dev/null || fail "armed: mktemp file left"
log_is "$udev_call"$'\n'"$start_call" || fail "armed: calls $(cat "$STUB_LOG")"
hold_is $'start --held KEY_PROG4 1 9\nexit 0' || fail "armed: hold $(cat "$stub/hold.log")"
arm_logged "pad-hold started 100 ms after the partner add, hold window 9 s" || fail "armed: pad-hold start not logged: $(cat "$tmp/arm.err")"
arm_logged "microos-usb-display-arm: armed" || fail "armed: not logged"

arm_reset
arm_start
hold_started || fail "armed after 0.5 s: pad-hold not started"
echo $(( added + 600000 )) > "$clock"
release 0
hold_done || fail "armed after 0.5 s: pad-hold did not finish"
arm_wait
(( r == 0 )) && armed || fail "armed after the 0.5 s partner check: exit $r, $(cat "$tmp/arm.err")"

for state in role udc; do
  arm_reset 3200000
  if [[ $state == role ]]; then echo "[host] device" > "$sys/class/typec/port0/data_role"; else rmdir "$sys/class/udc/a600000.usb"; fi
  arm_start
  if read -r -t 1 x <&8; then
    fail "$state: pad-hold started while not in the device role with the UDC"
  fi
  [[ ! -s $stub/hold.log && $(< "$STUB_LOG") == "$udev_call" ]] || fail "$state: acted: $(cat "$STUB_LOG")"
  if [[ $state == role ]]; then echo "host [device]" > "$sys/class/typec/port0/data_role"; else mkdir "$sys/class/udc/a600000.usb"; fi
  hold_started || fail "$state: pad-hold not started once the role and the UDC are there"
  release 1
  hold_done || fail "$state: pad-hold did not finish"
  arm_wait
  hold_is $'start --held KEY_PROG4 1 6\nexit 1' || fail "$state: hold $(cat "$stub/hold.log")"
  arm_logged "pad-hold started 3200 ms after the partner add" || fail "$state: pad-hold start: $(cat "$tmp/arm.err")"
  (( r == 0 )) && no_flag || fail "$state: missed hold: exit $r, flag left"
done

for state in host gone; do
  arm_reset
  if [[ $state == host ]]; then echo "[host] device" > "$sys/class/typec/port0/data_role"; else rmdir "$sys/class/udc/a600000.usb"; fi
  echo $(( added + 8500000 )) > "$clock"
  arm_start
  arm_wait
  (( r == 0 )) && no_flag || fail "docked ($state): exit $r or a flag"
  [[ ! -s $stub/hold.log ]] || fail "docked ($state): pad-hold started, the keys lock taken"
  arm_logged "not armed: no device role with the UDC in the window" || fail "docked ($state): $(cat "$tmp/arm.err")"
done

for change in role udc; do
  arm_reset
  arm_start
  hold_started || fail "$change change: pad-hold not started"
  if [[ $change == role ]]; then echo "[host] device" > "$sys/class/typec/port0/data_role"; else rmdir "$sys/class/udc/a600000.usb"; fi
  killed "$change change"
  arm_wait
  hold_is $'start --held KEY_PROG4 1 9\nkilled' || fail "$change change: hold $(cat "$stub/hold.log")"
  (( r == 0 )) && no_flag || fail "$change change: exit $r or a flag"
  [[ $(< "$STUB_LOG") == "$udev_call" ]] || fail "$change change: calls $(cat "$STUB_LOG")"
  arm_logged "not armed: the role or the UDC changed during the hold" || fail "$change change: $(cat "$tmp/arm.err")"
done

arm_reset
arm_start
hold_started || fail "partner gone at 0.5 s: pad-hold not started"
rm -rf "${sys:?}/class/typec/port0-partner"
echo $(( added + 600000 )) > "$clock"
killed "partner gone at 0.5 s"
arm_wait
hold_is $'start --held KEY_PROG4 1 9\nkilled' || fail "partner gone at 0.5 s: hold $(cat "$stub/hold.log")"
(( r == 0 )) && no_flag || fail "partner gone at 0.5 s: exit $r or a flag"
arm_logged "not armed: the partner left within 0.5 s" || fail "partner gone at 0.5 s: $(cat "$tmp/arm.err")"

arm_reset
arm_start
hold_started || fail "partner gone after the hold: pad-hold not started"
rm -rf "${sys:?}/class/typec/port0-partner"
release 0
hold_done || fail "partner gone after the hold: pad-hold did not finish"
arm_wait
(( r == 0 )) && no_flag || fail "partner gone after the hold: exit $r or a flag"
arm_logged "not armed: the partner left during the hold" || fail "partner gone after the hold: $(cat "$tmp/arm.err")"

arm_reset 7500000
arm_start
hold_started || fail "2.5 s left: pad-hold not started"
release 1
hold_done || fail "2.5 s left: pad-hold did not finish"
arm_wait
hold_is $'start --held KEY_PROG4 1 2\nexit 1' || fail "2.5 s left: hold $(cat "$stub/hold.log")"
arm_reset 8500000
arm_start
arm_wait
(( r == 0 )) && no_flag && [[ ! -s $stub/hold.log ]] || fail "1.5 s left: exit $r, hold $(cat "$stub/hold.log")"
arm_logged "not armed: under 2 s left in the window" || fail "1.5 s left: $(cat "$tmp/arm.err")"

for code in 1 3; do
  arm_reset
  arm_start
  hold_started || fail "pad-hold exit $code: not started"
  release "$code"
  hold_done || fail "pad-hold exit $code: did not finish"
  arm_wait
  (( r == 0 )) && no_flag || fail "pad-hold exit $code: exit $r or a flag"
  [[ $(< "$STUB_LOG") == "$udev_call" ]] || fail "pad-hold exit $code: calls $(cat "$STUB_LOG")"
  arm_logged "not armed: no RC hold (microos-pad-hold exit $code)" || fail "pad-hold exit $code: $(cat "$tmp/arm.err")"
done

arm_reset
rm "$sys/class/input/event0"
FAKE_STEP=100000 arm_start
arm_wait
(( r == 0 )) && no_flag && [[ ! -s $stub/hold.log ]] || fail "no aya-keys: exit $r or a hold"
arm_logged "not armed: no aya-keys within 2 s" || fail "no aya-keys: $(cat "$tmp/arm.err")"
(( $(< "$clock") - added >= 2100000 )) || fail "no aya-keys: gave up before 2 s"

for bad in missing 0644 symlink; do
  arm_reset
  case $bad in
    missing) rm "$run/hold/.lock-keys" ;;
    0644) chmod 644 "$run/hold/.lock-keys" ;;
    symlink) mv "$run/hold/.lock-keys" "$run/hold/real"; ln -s real "$run/hold/.lock-keys" ;;
  esac
  arm_start
  arm_wait
  (( r == 1 )) || fail "keys lock $bad: exit $r, want 1"
  no_flag && [[ ! -s $stub/hold.log ]] || fail "keys lock $bad: acted"
  arm_logged "refused: lock file $run/hold/.lock-keys missing or not root 0600" || fail "keys lock $bad: $(cat "$tmp/arm.err")"
done

arm_reset
arm_start
hold_started || fail "SIGTERM: pad-hold not started"
kill -TERM "$apid"
killed SIGTERM
arm_wait
(( r == 0 )) && no_flag || fail "SIGTERM: exit $r or a flag"
hold_is $'start --held KEY_PROG4 1 9\nkilled' || fail "SIGTERM: hold $(cat "$stub/hold.log")"

arm_reset
mkfifo "$stub/mv.held" "$stub/mv.go"
exec 6<> "$stub/mv.held"
export STUB_MV_HOLD=1
arm_start
hold_started || fail "SIGTERM before the flag rename: pad-hold not started"
release 0
hold_done || fail "SIGTERM before the flag rename: pad-hold did not finish"
x=""
read -r -t 10 x <&6 && [[ $x == mv ]] || fail "SIGTERM before the flag rename: mv not reached"
kill -TERM "$apid"
echo go 1<> "$stub/mv.go"
arm_wait
unset STUB_MV_HOLD
exec 6<&-
(( r == 0 )) && no_flag || fail "SIGTERM before the flag rename: exit $r, left $(ls -A "$run/usb-display")"

arm_reset
export STUB_SYSTEMCTL_RC=1
arm_start
hold_started || fail "systemctl fails: pad-hold not started"
release 0
hold_done || fail "systemctl fails: pad-hold did not finish"
arm_wait
unset STUB_SYSTEMCTL_RC
(( r == 1 )) || fail "systemctl fails: exit $r, want 1"
arm_logged "start of microos-usb-display-gadget.service failed" || fail "systemctl fails: $(cat "$tmp/arm.err")"

root=$tmp/root
cfg=/sys/kernel/config/usb_gadget/microos-usb-display
g=$root$cfg
key=$root/var/lib/microos/usb-display/key
export MICROOS_USB_DISPLAY_ROOT=$root
g_reset() {
  rm -rf "${root:?}" "${STUB_NET:?}"
  mkdir -p "$root/sys/kernel/config/usb_gadget" "$root/sys/class/udc/a600000.usb" "${key%/*}" "$STUB_NET"
  echo "1 lo 00:00:00:00:00:00" > "$STUB_NET/main"
  printf '%032d' 0 > "$key"
  chmod 600 "$key"
  : > "$STUB_LOG"
}
grun() {
  r=0
  PATH=$stubpath bash "$gadget_sh" "$@" 2> "$tmp/gerr" || r=$?
}
glogged() { grep -qF "$1" "$tmp/gerr"; }
val() { cat "$1" 2> /dev/null || echo missing; }
nsip="nsenter --net=/run/netns/usbdisp ip"
ns_sysctl="nsenter --net=/run/netns/usbdisp sysctl -q -w net.ipv6.conf.all.disable_ipv6=1"
ns_sysctl+=" net.ipv6.conf.default.disable_ipv6=1 net.ipv4.ip_forward=0 net.ipv4.conf.all.forwarding=0"
ns_sysctl+=" net.ipv4.conf.default.forwarding=0"
bind_calls() {
  printf '%s\n' "modprobe libcomposite" "ip netns add usbdisp" "$ns_sysctl" "ip -o link show" \
    "sysctl -q -w net/ipv6/conf/$1/disable_ipv6=1" "ip link set dev $1 netns usbdisp" "$nsip -o link show" \
    "ip -o link show" "nsenter --net=/run/netns/usbdisp sysctl -q -w net/ipv6/conf/$1/disable_ipv6=1" \
    "$nsip link set dev lo up" "$nsip addr add 10.77.0.1/30 dev $1" "$nsip link set dev $1 up"
}
unbind_calls="rmdir $cfg/functions/ncm.usb0
rmdir $cfg/configs/c.1/strings/0x409
rmdir $cfg/configs/c.1
rmdir $cfg/strings/0x409
rmdir $cfg
nsenter --net=/run/netns/usbdisp ip -o link show
ip -o link show
ip netns del usbdisp"
clean() { [[ ! -e $g && ! -e $root/run/netns/usbdisp && $(< "$STUB_NET/main") == "1 lo 00:00:00:00:00:00" ]]; }

g_reset
grun bind
(( r == 0 )) || fail "bind: exit $r: $(cat "$tmp/gerr")"
log_is "ip -o link show"$'\n'"$(bind_calls usbdisp0)" || fail "bind calls: $(cat "$STUB_LOG")"
for kv in idVendor=0x1d6b idProduct=0x0104 strings/0x409/manufacturer=MicroOS "strings/0x409/product=Pocket MICRO 2" \
  configs/c.1/strings/0x409/configuration=NCM functions/ncm.usb0/dev_addr=02:53:52:54:00:01 \
  functions/ncm.usb0/host_addr=02:53:52:54:00:02 functions/ncm.usb0/ifname=usbdisp%d UDC=a600000.usb; do
  [[ $(val "$g/${kv%%=*}") == "${kv#*=}" ]] || fail "bind: ${kv%%=*} is $(val "$g/${kv%%=*}"), want ${kv#*=}"
done
[[ -L $g/configs/c.1/ncm.usb0 && $(readlink "$g/configs/c.1/ncm.usb0") == "$g/functions/ncm.usb0" ]] ||
  fail "bind: ncm.usb0 is not linked into c.1"
[[ $(< "$STUB_NET/usbdisp") == $'1 lo 00:00:00:00:00:00\n5 usbdisp0 02:53:52:54:00:01' &&
  $(< "$STUB_NET/main") == "1 lo 00:00:00:00:00:00" ]] || fail "bind: the netdev is not only in usbdisp"
! grep -qE '^ip (-o )?link set dev [^ ]+ up' "$STUB_LOG" || fail "bind: a netdev set up in the main netns"
glogged "bound to a600000.usb, usbdisp0 10.77.0.1/30 in usbdisp" || fail "bind: not logged: $(cat "$tmp/gerr")"

: > "$STUB_LOG"
grun bind
(( r == 0 )) || fail "second bind: exit $r: $(cat "$tmp/gerr")"
log_is "$unbind_calls"$'\n'"$(bind_calls usbdisp0)" || fail "second bind calls: $(cat "$STUB_LOG")"

: > "$STUB_LOG"
grun unbind
(( r == 0 )) || fail "unbind: exit $r: $(cat "$tmp/gerr")"
log_is "$unbind_calls" || fail "unbind calls: $(cat "$STUB_LOG")"
clean || fail "unbind left the gadget, the netns or the netdev"
: > "$STUB_LOG"
grun unbind
(( r == 0 )) && log_is "ip -o link show" || fail "unbind with nothing bound: exit $r, calls $(cat "$STUB_LOG")"

g_reset
STUB_NAME=usb0 grun bind
(( r == 0 )) || fail "bind with a kernel named netdev: exit $r: $(cat "$tmp/gerr")"
log_is "ip -o link show"$'\n'"$(bind_calls usb0)" || fail "bind with a kernel named netdev: calls $(cat "$STUB_LOG")"
for name in "usb%d" "a234567890123456" "../usbdisp0"; do
  g_reset
  STUB_NAME=$name grun bind
  (( r == 1 )) && clean || fail "netdev named '$name': exit $r, want 1, or left state"
  glogged "netdev 5 has the name '$name'" || fail "netdev named '$name': $(cat "$tmp/gerr")"
  ! grep -q "netns usbdisp" "$STUB_LOG" || fail "netdev named '$name': moved"
done

g_reset
STUB_KEEP=1 grun bind
(( r == 0 )) || fail "bind for a kept netdev: exit $r"
: > "$STUB_LOG"
STUB_KEEP=1 grun unbind
(( r == 4 )) || fail "netdev left in usbdisp: exit $r, want 4"
[[ -e $root/run/netns/usbdisp ]] || fail "netdev left in usbdisp: the netns was deleted"
grep -qx "$nsip link set dev usbdisp0 down" "$STUB_LOG" || fail "netdev left in usbdisp: not set down: $(cat "$STUB_LOG")"
! grep -q "netns del" "$STUB_LOG" || fail "netdev left in usbdisp: netns del called"
glogged "netdev usbdisp0 with 02:53:52:54:00:01 is left in usbdisp, keeping it" || fail "netdev left in usbdisp: $(cat "$tmp/gerr")"
: > "$STUB_LOG"
grun bind
(( r == 4 )) && ! grep -q modprobe "$STUB_LOG" || fail "bind with a netdev left: exit $r, calls $(cat "$STUB_LOG")"

g_reset
STUB_FALLBACK=1 grun bind
(( r == 0 )) || fail "bind with fallback tunnels in the netns: exit $r: $(cat "$tmp/gerr")"
: > "$STUB_LOG"
STUB_FALLBACK=1 grun unbind
(( r == 0 )) && clean || fail "fallback tunnels in the netns: exit $r, want 0, or the netns kept"
log_is "$unbind_calls" || fail "fallback tunnels in the netns: calls $(cat "$STUB_LOG")"

g_reset
STUB_FALLBACK=1 grun bind
: > "$STUB_LOG"
STUB_FALLBACK=1 STUB_KEEP=1 grun unbind
(( r == 4 )) && [[ -e $root/run/netns/usbdisp ]] || fail "gadget netdev beside fallback tunnels: exit $r or the netns deleted"
grep -qx "$nsip link set dev usbdisp0 down" "$STUB_LOG" && ! grep -qE 'set dev (sit0|gretap0)' "$STUB_LOG" ||
  fail "gadget netdev beside fallback tunnels: calls $(cat "$STUB_LOG")"

g_reset
grun bind
: > "$STUB_LOG"
STUB_BUSY=1 grun unbind
(( r == 4 )) && [[ -e $root/run/netns/usbdisp ]] || fail "busy function: exit $r or the netns deleted"
glogged "the function ncm.usb0 is left, keeping usbdisp" || fail "busy function: $(cat "$tmp/gerr")"
! grep -q "netns del" "$STUB_LOG" || fail "busy function: netns del called"

g_reset
grun bind
: > "$STUB_LOG"
STUB_LIST_FAIL=1 grun unbind
(( r == 4 )) && [[ -e $root/run/netns/usbdisp ]] || fail "failing netns listing: exit $r or the netns deleted"
glogged "cannot list the netdevs in usbdisp, keeping it" || fail "failing netns listing: $(cat "$tmp/gerr")"

g_reset
echo "7 dev7 02:53:52:54:00:01" >> "$STUB_NET/main"
grun bind
(( r == 4 )) || fail "stray netdev in the main netns: exit $r, want 4"
log_is $'ip -o link show\nip link set dev dev7 down' || fail "stray netdev: calls $(cat "$STUB_LOG")"
glogged "netdev dev7 with 02:53:52:54:00:01 is in the main netns" || fail "stray netdev: $(cat "$tmp/gerr")"

g_reset
STUB_RENAME=1 grun bind
(( r == 1 )) || fail "rename before the move: exit $r, want 1"
clean || fail "rename before the move: not torn down"
grep -qx "ip link set dev usbdisp0 netns usbdisp" "$STUB_LOG" || fail "rename before the move: calls $(cat "$STUB_LOG")"

g_reset
STUB_UDC_GONE=1 grun bind
(( r == 3 )) || fail "UDC gone mid bind: exit $r, want 3"
glogged "the UDC a600000.usb is gone" || fail "UDC gone mid bind: $(cat "$tmp/gerr")"
clean || fail "UDC gone mid bind: not torn down"

g_reset
rmdir "$root/sys/class/udc/a600000.usb"
grun bind
(( r == 3 )) && clean || fail "bind without the UDC: exit $r, want 3, or left state"

for what in modprobe nsenter; do
  g_reset
  if [[ $what == modprobe ]]; then STUB_MODPROBE_RC=1 grun bind; else STUB_NSENTER_RC=1 grun bind; fi
  (( r == 1 )) && clean || fail "$what fails: exit $r, want 1, or left state"
  glogged "bind failed, tearing down" || fail "$what fails: $(cat "$tmp/gerr")"
done

for bad in 0644 short symlink missing owner; do
  g_reset
  case $bad in
    0644) chmod 644 "$key" ;;
    short) printf '%031d' 0 > "$key" ;;
    symlink) mv "$key" "$key.real"; ln -s key.real "$key" ;;
    missing) rm "$key" ;;
    owner) chown 1000 "$key" ;;
  esac
  grun bind
  (( r == 5 )) || fail "key $bad: exit $r, want 5"
  log_is "ip -o link show" && clean || fail "key $bad: acted: $(cat "$STUB_LOG")"
done

grun bogus
(( r == 2 )) || fail "unknown mode: exit $r, want 2"

udc_rule='SUBSYSTEM=="udc", KERNEL=="a600000.usb", ACTION!="remove", TAG+="systemd", ENV{SYSTEMD_ALIAS}="/sys/subsystem/udc/devices/a600000.usb"'
typec_rule='SUBSYSTEM=="typec", KERNEL=="port0-partner", ACTION!="remove", TAG+="systemd", ENV{SYSTEMD_ALIAS}="/sys/subsystem/typec/devices/port0-partner", ENV{SYSTEMD_WANTS}+="microos-usb-display-arm.service"'
[[ $(< "$rules") == "$typec_rule"$'\n'"$udc_rule" ]] || fail "udev rules: $(cat "$rules")"
partner_dev=$(systemd-escape --path --suffix=device /sys/subsystem/typec/devices/port0-partner)
udc_dev=$(systemd-escape --path --suffix=device /sys/subsystem/udc/devices/a600000.usb)
want_lines() {
  local f=$1 l
  shift
  for l; do
    grep -qxF -- "$l" "$f" || fail "${f##*/} lacks $l"
  done
}
want_lines "$sys_units/microos-usb-display-arm.service" DefaultDependencies=no After=sysinit.target \
  Conflicts=shutdown.target Before=shutdown.target "BindsTo=$partner_dev" "After=$partner_dev" \
  ConditionPathExists=/var/lib/microos/usb-display/key Type=oneshot RemainAfterExit=yes \
  ExecStart=/usr/libexec/microos/microos-usb-display-arm "ExecStopPost=/usr/bin/rm -f /run/microos/usb-display/armed" \
  TimeoutStartSec=20
! grep -qE '^(Wants|Restart|StartLimit)' "$sys_units/microos-usb-display-arm.service" || fail "arm unit wants, restarts or limits"
want_lines "$sys_units/microos-usb-display-gadget.service" DefaultDependencies=no After=sysinit.target \
  Conflicts=shutdown.target Before=shutdown.target BindsTo=microos-usb-display-arm.service \
  After=microos-usb-display-arm.service "BindsTo=$udc_dev" "After=$udc_dev" Wants=microos-usb-display-link.socket \
  ConditionPathExists=/run/microos/usb-display/armed ConditionPathExists=/var/lib/microos/usb-display/key \
  StartLimitIntervalSec=0 Type=oneshot RemainAfterExit=yes "ExecStart=/usr/libexec/microos/microos-usb-display-gadget bind" \
  "ExecStopPost=/usr/libexec/microos/microos-usb-display-gadget unbind" Restart=on-failure RestartSec=2 RestartSteps=3 \
  RestartMaxDelaySec=10 "RestartPreventExitStatus=3 4 5" TimeoutStartSec=30
want_lines "$sys_units/microos-usb-display-link.socket" DefaultDependencies=no Conflicts=shutdown.target \
  Before=shutdown.target BindsTo=microos-usb-display-gadget.service After=microos-usb-display-gadget.service \
  ListenStream=10.77.0.1:47800 ListenStream=/run/microos/usb-display/session.sock NetworkNamespacePath=/run/netns/usbdisp \
  SocketUser=root SocketGroup=micro SocketMode=0660 RemoveOnStop=yes Accept=no
[[ $(grep '^ListenStream=' "$sys_units/microos-usb-display-link.socket") == \
  $'ListenStream=10.77.0.1:47800\nListenStream=/run/microos/usb-display/session.sock' ]] || fail "socket listener order"
! grep -qE '^(Condition|FreeBind)' "$sys_units/microos-usb-display-link.socket" || fail "socket has a condition or FreeBind"
want_lines "$sys_units/microos-usb-display-link.service" BindsTo=microos-usb-display-link.socket \
  After=microos-usb-display-link.socket StartLimitIntervalSec=0 ExecStart=/usr/libexec/microos/microos-usb-display-link \
  DynamicUser=yes LoadCredential=key:/var/lib/microos/usb-display/key Environment=MICROOS_USB_DISPLAY_FORMAT=jpeg \
  Restart=on-failure RestartSec=2 RestartSteps=3 RestartMaxDelaySec=10
[[ $(< "$user_units/gamescope-session-plus@.service.d/40-microos-usb-display.conf") == $'[Unit]\nWants=microos-usb-display@%i.path' ]] ||
  fail "session drop-in: $(cat "$user_units/gamescope-session-plus@.service.d/40-microos-usb-display.conf")"
want_lines "$user_units/microos-usb-display@.path" DefaultDependencies=no BindsTo=gamescope-session-plus@%i.service \
  After=gamescope-session-plus@%i.service ConditionPathExists=/usr/bin/gamescopevirtual \
  PathExists=/run/microos/usb-display/session.sock
want_lines "$user_units/microos-usb-display@.service" Requisite=gamescope-session-plus@%i.service \
  After=gamescope-session-plus@%i.service PartOf=microos-usb-display@%i.path StartLimitIntervalSec=0 Slice=app.slice \
  "ExecStart=/usr/libexec/microos/microos-usb-display %i" Restart=on-failure RestartSec=2 RestartSteps=3 \
  RestartMaxDelaySec=10 WatchdogSec=10 NoNewPrivileges=yes SystemCallArchitectures=native MemoryMax=512M \
  "RestrictAddressFamilies=AF_UNIX AF_NETLINK"
! grep -q '^BindsTo=' "$user_units/microos-usb-display@.service" || fail "session part unit binds to the session"
for f in "$user_units/microos-usb-display.service" "$user_units/gamescope-session-plus@steam.service.d/40-microos-usb-display.conf"; do
  [[ ! -e $f ]] || fail "v3 file ${f#"$tree"} still shipped"
done
[[ $(< "$tree/usr/lib/tmpfiles.d/microos-usb-display.conf") == \
  $'d /run/microos/usb-display 0755 root root -\nd /var/lib/microos/usb-display 0700 root root -' ]] ||
  fail "microos-usb-display.conf tmpfiles"

if command -v udevadm > /dev/null; then
  udevadm verify --no-summary "$rules" || fail "usb display rules do not verify"
else
  fail "udevadm missing, usb display rules unchecked"
fi

if (( rc == 0 )); then
  echo "usb-display: ok"
fi
exit "$rc"
