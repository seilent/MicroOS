#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
script=$tree/usr/libexec/microos/microos-usb-console
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

export FAKE_STATE=$tmp/fake PATH=$here/usb-console/bin:$PATH
cfg=$tmp/config
class=$tmp/class
g=$cfg/usb_gadget/microos
role=$class/usb_role/a600000.usb-role-switch/role

reset() {
  rm -rf "$cfg" "$class" "$FAKE_STATE"
  mkdir -p "$cfg/usb_gadget" "$class/udc/a600000.usb" "${role%/*}" "$FAKE_STATE"
  echo host > "$role"
  echo "root=PARTLABEL=microos rootwait androidboot.serialno=TESTSERIAL0 microos.test=1" > "$tmp/cmdline"
}
run() {
  env MICROOS_CONFIGFS="$cfg" MICROOS_SYSCLASS="$class" MICROOS_CMDLINE="$tmp/cmdline" \
    MICROOS_MODPROBE="$here/usb-console/bin/modprobe" MICROOS_USB_POLLS="${POLLS:-4}" "$script" "$@" 2> "$tmp/err"
}
local_mac() { (( (0x${1%%:*} & 3) == 2 )); }
check_gadget() {
  local f d h
  [[ $(< "$g/idVendor") == 0x1d6b && $(< "$g/idProduct") == 0x0104 ]] || fail "$2: ids $(cat "$g/idVendor" "$g/idProduct" | tr '\n' ' ')"
  [[ $(< "$g/strings/0x409/serialnumber") == "$1" ]] || fail "$2: serial $(cat "$g/strings/0x409/serialnumber")"
  [[ $(ls "$g/strings/0x409") == serialnumber ]] || fail "$2: strings $(ls "$g/strings/0x409" | tr '\n' ' ')"
  [[ $(ls "$g/configs") == c.1 && $(ls "$g/configs/c.1" | tr '\n' ' ') == "acm.usb0 ncm.usb0 " ]] \
    || fail "$2: config $(ls -R "$g/configs" | tr '\n' ' ')"
  for f in acm.usb0 ncm.usb0; do
    [[ $(readlink "$g/configs/c.1/$f") == "$g/functions/$f" ]] || fail "$2: $f not linked"
  done
  d=$(< "$g/functions/ncm.usb0/dev_addr")
  h=$(< "$g/functions/ncm.usb0/host_addr")
  [[ $d == 02:6e:3a:91:c4:05 && $h == 02:6e:3a:91:c4:06 ]] || fail "$2: MACs $d $h"
  local_mac "$d" && local_mac "$h" || fail "$2: MACs not locally administered unicast"
  [[ $(< "$g/UDC") == a600000.usb ]] || fail "$2: UDC $(cat "$g/UDC")"
}

reset
run start || fail "start: exit $?: $(cat "$tmp/err")"
check_gadget TESTSERIAL0-microos start
[[ $(< "$FAKE_STATE/modprobe.log") == "modprobe -a phy-nxp-ptn3222 snd-soc-wcd939x libcomposite" ]] \
  || fail "modprobe: $(cat "$FAKE_STATE/modprobe.log")"
[[ $(< "$role") == host ]] || fail "role written with a UDC present"

run start || fail "rerun: exit $?: $(cat "$tmp/err")"
check_gadget TESTSERIAL0-microos rerun
[[ $(wc -l < "$FAKE_STATE/modprobe.log") == 1 && $(< "$tmp/err") == *"already bound to a600000.usb"* ]] \
  || fail "rerun on a bound gadget did work: $(cat "$tmp/err")"

: > "$g/UDC"
echo 02:00:00:00:00:99 > "$g/functions/ncm.usb0/dev_addr"
run start || fail "rerun unbound: exit $?: $(cat "$tmp/err")"
[[ $(< "$g/functions/ncm.usb0/dev_addr") == 02:00:00:00:00:99 ]] || fail "rerun wrote dev_addr of a linked function"
echo 02:6e:3a:91:c4:05 > "$g/functions/ncm.usb0/dev_addr"
check_gadget TESTSERIAL0-microos "rerun unbound"

run stop || fail "stop: exit $?: $(cat "$tmp/err")"
[[ ! -e $g ]] || fail "stop left $(find "$g" | tr '\n' ' ')"
run stop || fail "stop without a gadget: exit $?"
run start || fail "start after stop: exit $?: $(cat "$tmp/err")"
check_gadget TESTSERIAL0-microos "start after stop"
run stop || fail "second stop: exit $?: $(cat "$tmp/err")"
[[ ! -e $g ]] || fail "second stop left the gadget"

reset
MICROOS_USB_FUNCS=acm.usb0 run start || fail "acm only: exit $?: $(cat "$tmp/err")"
[[ $(ls "$g/configs/c.1" | tr '\n' ' ') == "acm.usb0 " && ! -e $g/functions/ncm.usb0 && $(< "$g/UDC") == a600000.usb ]] \
  || fail "acm only: $(ls -R "$g" | tr '\n' ' ')"
MICROOS_USB_FUNCS=acm.usb0 run stop || fail "acm only stop: exit $?: $(cat "$tmp/err")"
[[ ! -e $g ]] || fail "acm only stop left $(find "$g" | tr '\n' ' ')"
run start || fail "root start after the initrd: exit $?: $(cat "$tmp/err")"
check_gadget TESTSERIAL0-microos "root start after the initrd"

mod=$tree/usr/lib/dracut/modules.d/93microos-y700-usbcon
unit=$mod/microos-initrd-usbcon.service
[[ $(tail -n 1 "$mod/microos-initrd-usbcon") == "exec journalctl "* ]] || fail "initrd console: journalctl is not the main process"
grep -qx 'ExecStart=-/usr/libexec/microos/microos-initrd-usbcon' "$unit" || fail "initrd console: ExecStart without the - prefix"
grep -qx 'KillSignal=SIGKILL' "$unit" || fail "initrd console: no KillSignal=SIGKILL, a journalctl blocked on ttyGS0 holds SIGTERM until the stop times out"

reset
rm -rf "${class:?}/udc/a600000.usb"
(
  for _ in $(seq 1 100); do
    if [[ $(< "$role") == device ]]; then
      mkdir -p "$class/udc/a600000.usb"
      exit 0
    fi
    sleep 0.1
  done
) &
watcher=$!
run start || fail "role fallback: exit $?: $(cat "$tmp/err")"
wait "$watcher" || fail "role fallback: device never written"
[[ $(< "$role") == device ]] || fail "role fallback: role $(cat "$role")"
[[ $(< "$tmp/err") == *"$role set to device"* ]] || fail "role fallback not logged: $(cat "$tmp/err")"
check_gadget TESTSERIAL0-microos "role fallback"

reset
echo "root=PARTLABEL=microos rootwait microos.test=1" > "$tmp/cmdline"
run start || fail "no serial: exit $?: $(cat "$tmp/err")"
check_gadget microos "no serial"

reset
rm -f "$tmp/cmdline"
run start || fail "no cmdline: exit $?: $(cat "$tmp/err")"
check_gadget microos "no cmdline"

reset
rm -rf "${class:?}/udc" "${class:?}/usb_role"
if POLLS=2 run start; then
  fail "start passed without a UDC"
fi
[[ $(< "$tmp/err") == *"no UDC"* ]] || fail "missing UDC not reported: $(cat "$tmp/err")"
[[ ! -e $g ]] || fail "gadget built without a UDC"

reset
rm -rf "${class:?}/udc/a600000.usb"
if POLLS=2 run start; then
  fail "start passed when the role switch brought no UDC"
fi
[[ $(< "$role") == device && ! -e $g ]] || fail "role without a UDC: role $(cat "$role")"

sh -n "$tree/usr/lib/dracut/modules.d/93microos-y700-usbcon/microos-initrd-usbcon" || fail "microos-initrd-usbcon syntax"

r=0
run bogus || r=$?
(( r == 2 )) || fail "usage exit $r"

if command -v systemd-analyze > /dev/null && [[ -d /usr/lib/systemd/system ]]; then
  root=$tmp/root
  mkdir -p "$root/usr/lib/systemd" "$root/usr/libexec/microos" "$root/usr/sbin"
  cp -a /usr/lib/systemd/system "$root/usr/lib/systemd/"
  [[ ! -d /usr/lib/dracut ]] || cp -a /usr/lib/dracut "$root/usr/lib/"
  cp -a "$tree/usr/lib/systemd/system/microos-usb-console.service" "$tree/usr/lib/systemd/system/serial-getty@ttyGS0.service.d" \
    "$root/usr/lib/systemd/system/"
  cp -a "$script" "$tree/usr/lib/dracut/modules.d/93microos-y700-usbcon/microos-initrd-usbcon" "$root/usr/libexec/microos/"
  cp -a "$tree/usr/lib/dracut/modules.d/93microos-y700-usbcon/microos-initrd-usbcon.service" "$root/usr/lib/systemd/system/"
  cp -a /usr/sbin/agetty "$root/usr/sbin/"
  systemd-analyze verify --man=no --root="$root" microos-usb-console.service serial-getty@ttyGS0.service microos-initrd-usbcon.service \
    > "$tmp/verify" 2>&1 || fail "systemd-analyze verify: $(cat "$tmp/verify")"
  [[ ! -s $tmp/verify ]] || fail "systemd-analyze verify: $(cat "$tmp/verify")"
else
  echo "usb-console: systemd-analyze not available, units not verified"
fi
if command -v udevadm > /dev/null && udevadm verify --help > /dev/null 2>&1; then
  udevadm verify --no-style "$tree/usr/lib/udev/rules.d/90-microos-usb-console.rules" > "$tmp/udev" 2>&1 \
    || fail "udevadm verify: $(cat "$tmp/udev")"
fi

if (( rc == 0 )); then
  echo "usb-console: ok"
fi
exit "$rc"
