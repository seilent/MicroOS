#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
vpower=$tree/usr/libexec/microos/microos-vpower
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

export MICROOS_POWER_SUPPLY=$tmp/ps MICROOS_VPOWER=$tmp/out

supply() {
  rm -rf "$tmp/ps" "$tmp/out"
  mkdir -p "$tmp/out" "$tmp/ps/battery" "$tmp/ps/pm8150b-charger"
  local b=$tmp/ps/battery c=$tmp/ps/pm8150b-charger
  echo Battery > "$b/type"
  echo 1 > "$b/present"
  echo "$1" > "$b/status"
  echo "$2" > "$b/capacity"
  echo "$3" > "$b/current_now"
  echo 3950000 > "$b/charge_full_design"
  echo USB > "$c/type"
  echo "$4" > "$c/online"
}

out() { (cd "$tmp/out" && grep -H . ac_status battery_percent battery_status secs_until_battery_full secs_until_shutdown_request | paste -sd' '); }
check() {
  local want=$1 got
  "$vpower" --once || fail "$2: exit $?"
  got=$(out)
  [[ $got == "$want" ]] || fail "$2: $got"
}

supply Charging 40 -2000000 16
check "ac_status:Connected battery_percent:40.00 battery_status:Charging secs_until_battery_full:4260 secs_until_shutdown_request:-1" "charging, online 16"

supply Discharging 50 500000 0
check "ac_status:Disconnected battery_percent:50.00 battery_status:Discharging secs_until_battery_full:-1 secs_until_shutdown_request:14220" "discharging"

supply Full 100 0 1
check "ac_status:Connected battery_percent:100.00 battery_status:Full secs_until_battery_full:0 secs_until_shutdown_request:-1" "full"

supply Discharging 50 10000 0
check "ac_status:Disconnected battery_percent:50.00 battery_status:Discharging secs_until_battery_full:-1 secs_until_shutdown_request:-1" "current below 50 mA"

supply Discharging 50 1000000 0
echo 2000000 > "$tmp/ps/battery/charge_full"
echo 1500000 > "$tmp/ps/battery/charge_now"
check "ac_status:Disconnected battery_percent:50.00 battery_status:Discharging secs_until_battery_full:-1 secs_until_shutdown_request:5400" "charge counters win"

rm -rf "$tmp/ps" "$tmp/out"
mkdir -p "$tmp/ps" "$tmp/out"
"$vpower" --once || fail "no battery: exit $?"
[[ -z $(ls -A "$tmp/out") ]] || fail "no battery wrote files: $(ls "$tmp/out")"

supply Charging 40 -2000000 1
mkdir -p "$tmp/out"
ln -s "$tmp/victim" "$tmp/out/battery_status"
"$vpower" --once || fail "planted link: exit $?"
[[ ! -e $tmp/victim && -f $tmp/out/battery_status && ! -L $tmp/out/battery_status ]] || fail "followed a planted link"

supply Charging 40 -2000000 1
rm "$tmp/ps/battery/capacity"
mkdir -p "$tmp/out"
"$vpower" --once || fail "no capacity: exit $?"
[[ -z $(ls -A "$tmp/out") ]] || fail "no capacity wrote files: $(ls "$tmp/out")"

exit $rc
