#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
script=$tree/usr/libexec/microos/microos-bt-address
unit=$tree/usr/lib/systemd/system/microos-bt-address.service
rules=$tree/usr/lib/udev/rules.d/70-microos-bt.rules
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

[[ -x $script ]] || fail "${script#"$tree"} is not executable"

root=$tmp/root
export STUB_DIR=$tmp/stub STUB_LOG=$tmp/log MICROOS_BT_ROOT=$root MICROOS_BT_POLL=0.01
stubpath=$here/bt-address:$PATH

reset() {
  rm -rf "$root" "$STUB_DIR"
  mkdir -p "$root/sys/devices/soc0" "$root/proc" "$STUB_DIR"
  ln -s /proc/uptime "$root/proc/uptime"
  echo "$1" > "$STUB_DIR/state"
  echo "$2" > "$root/sys/devices/soc0/serial_number"
  : > "$STUB_LOG"
}
set_uptime() {
  echo "$1 0.00" > "$root/proc/uptime.new"
  mv -f "$root/proc/uptime.new" "$root/proc/uptime"
}
run() {
  local r=0
  PATH=$stubpath bash "$script" > "$tmp/out" 2>&1 || r=$?
  return "$r"
}
set_addr() { grep '^btmgmt --index 0 public-addr' "$STUB_LOG" || true; }
configs() { cat "$STUB_DIR/config.n" 2> /dev/null || echo 0; }
logged() { grep -qF "$1" "$tmp/out"; }

reset unconfigured 599856448
echo 3 > "$STUB_DIR/absent"
run || fail "absent then unconfigured: exit $?"
[[ $(set_addr) == 'btmgmt --index 0 public-addr 00:03:7F:48:64:85' ]] || fail "absent then unconfigured: $(cat "$STUB_LOG")"
[[ $(configs) == 4 ]] || fail "absent then unconfigured: $(configs) config polls"
logged "hci0 public address 00:03:7F:48:64:85" || fail "address not logged: $(cat "$tmp/out")"

reset unconfigured 'abc123def'
run || fail "hex serial: exit $?"
[[ $(set_addr) == 'btmgmt --index 0 public-addr 00:03:7F:EF:3D:12' ]] || fail "hex serial: $(set_addr)"

reset configured 599856448
run || fail "configured: exit $?"
[[ -z $(set_addr) ]] || fail "configured: address set"
logged "hci0 is configured" || fail "configured not logged: $(cat "$tmp/out")"

reset other 599856448
run || fail "hci1 unconfigured, hci0 configured: exit $?"
[[ -z $(set_addr) ]] || fail "hci1 unconfigured, hci0 configured: address set"

reset unconfigured-set 599856448
run || fail "unconfigured with an address: exit $?"
[[ -z $(set_addr) ]] || fail "unconfigured with an address: address set"

reset unconfigured 5998564G8
run || fail "bad serial: exit $?"
[[ -z $(set_addr) ]] || fail "bad serial: address set"
logged "ends in non hex characters" || fail "bad serial not logged: $(cat "$tmp/out")"

reset unconfigured 12345
run || fail "short serial: exit $?"
[[ -z $(set_addr) ]] || fail "short serial: address set"
logged "shorter than 6 characters" || fail "short serial not logged: $(cat "$tmp/out")"

reset unconfigured 599856448
rm "$root/sys/devices/soc0/serial_number"
run || fail "no serial: exit $?"
[[ -z $(set_addr) ]] || fail "no serial: address set"
logged "no $root/sys/devices/soc0/serial_number" || fail "no serial not logged: $(cat "$tmp/out")"

reset unconfigured 599856448
: > "$STUB_DIR/fail"
if run; then fail "failed public-addr accepted"; fi
logged "setting 00:03:7F:48:64:85 on hci0 failed: Set Public Address for hci0 failed" || fail "failure not logged: $(cat "$tmp/out")"

reset absent 599856448
start=$(date +%s%N)
if MICROOS_BT_WAIT=1 run; then fail "never listed accepted"; fi
elapsed=$((($(date +%s%N) - start) / 1000000))
((elapsed < 2500)) || fail "never listed: gave up after $elapsed ms"
(($(configs) > 1)) || fail "never listed: $(configs) config polls"
[[ -z $(set_addr) ]] || fail "never listed: address set"
logged "hci0 not listed after 1 s" || fail "never listed not logged: $(cat "$tmp/out")"

reset absent 599856448
set_uptime 100.00
MICROOS_BT_WAIT=1 PATH=$stubpath bash "$script" > "$tmp/out" 2>&1 &
pid=$!
sleep 0.3
set_uptime 100.60
sleep 1.4
kill -0 "$pid" 2> /dev/null || fail "clock step: wait ended at 1.7 s wall time, 0.6 s uptime"
set_uptime 101.01
r=0
wait "$pid" || r=$?
((r == 1)) || fail "clock step: exit $r"
logged "hci0 not listed after 1 s" || fail "clock step not logged: $(cat "$tmp/out")"

reset absent 599856448
rm "$root/proc/uptime"
if run; then fail "no uptime accepted"; fi
logged "cannot read $root/proc/uptime" || fail "no uptime not logged: $(cat "$tmp/out")"

if command -v udevadm > /dev/null; then
  udevadm verify --no-summary "$rules" || fail "bt rules do not verify"
else
  fail "udevadm missing, bt rules unchecked"
fi
grep -qxF 'SUBSYSTEM=="bluetooth", KERNEL=="hci0", TAG+="systemd", ENV{SYSTEMD_WANTS}+="microos-bt-address.service"' "$rules" ||
  fail "no hci0 rule"
for l in Before=bluetooth.service Type=oneshot ExecStart=/usr/libexec/microos/microos-bt-address \
  CapabilityBoundingSet=CAP_NET_ADMIN 'RestrictAddressFamilies=AF_BLUETOOTH AF_UNIX' ProtectSystem=strict PrivateTmp=yes; do
  grep -qxF "$l" "$unit" || fail "unit lacks $l"
done
! grep -q '^\[Install\]' "$unit" || fail "unit has an [Install] section"
! grep -q '^PrivateNetwork=' "$unit" || fail "unit sets PrivateNetwork"
! grep -q '^RemainAfterExit=yes' "$unit" || fail "unit stays active, a hci0 re add would not run it"

if (( rc == 0 )); then
  echo "bt-address: ok"
fi
exit "$rc"
