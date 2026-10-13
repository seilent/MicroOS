#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
powerd=$tree/usr/libexec/microos/microos-powerd
cli=$tree/usr/bin/microos-power
shipped=$tree/usr/lib/microos/power-profiles.conf
bus=$here/powerd/bus.py
tmp=$(mktemp -d)
chmod 755 "$tmp"
pd="" daemon="" mon=""
cleanup() {
  local p
  for p in $pd $mon $daemon; do kill "$p" 2> /dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

sys=$tmp/sys
cpu=$sys/devices/system/cpu
pol=$cpu/cpufreq
gpu=$sys/class/devfreq/3d00000.gpu
export MICROOS_SYSFS=$sys MICROOS_PROC=$tmp/proc MICROOS_STATEDIR=$tmp/state MICROOS_POWER_PROFILES=$tmp/profiles.conf
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=$tmp/bus/socket
allowed='/devices/system/cpu/(cpufreq/policy[047]/scaling_(max_freq|min_freq|governor)|cpu[0-9]+/online)$|/class/devfreq/3d00000\.gpu/(governor|min_freq|max_freq)$'

if grep -nE 'hwmon|thermal|pwm' "$powerd"; then fail "powerd names a hwmon, thermal or pwm path"; fi

getent passwd 1000 > /dev/null || useradd -u 1000 -M micro
mkdir -p "$tmp/bus" "$tmp/proc"
chmod 755 "$tmp/bus"
cat > "$tmp/bus.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <listen>unix:path=$tmp/bus/socket</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="*"/>
    <deny own="*"/>
    <deny send_type="method_call"/>
    <allow send_type="signal"/>
    <allow send_requested_reply="true" send_type="method_return"/>
    <allow send_requested_reply="true" send_type="error"/>
    <allow receive_type="method_call"/>
    <allow receive_type="method_return"/>
    <allow receive_type="error"/>
    <allow receive_type="signal"/>
    <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus"/>
    <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Introspectable"/>
  </policy>
  <policy user="root">
    <allow own="org.freedesktop.login1"/>
  </policy>
  <include>$tree/usr/share/dbus-1/system.d/net.seilent.MicroOs.Power.conf</include>
</busconfig>
EOF
dbus-daemon --config-file="$tmp/bus.conf" --nofork --nopidfile > "$tmp/dbus.log" 2>&1 &
daemon=$!
for _ in $(seq 100); do [[ -S $tmp/bus/socket ]] && break; sleep 0.05; done
[[ -S $tmp/bus/socket ]] || { echo "FAIL: dbus-daemon: $(cat "$tmp/dbus.log")" >&2; exit 1; }

as() {
  local cg=$1
  shift
  sh -c 'mkdir -p "$MICROOS_PROC/$$" && printf "%s\n" "$0" > "$MICROOS_PROC/$$/cgroup" && exec "$@"' "$cg" "$@"
}
user_cg=0::/user.slice/user-1000.slice/user@1000.service/app.slice/steamos-manager.service
game_cg=0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-steam-app1145360-1.scope
root() { as 0::/system.slice/sshd.service "$@"; }
wheel() { as "$user_cg" setpriv --reuid 1000 --regid 1000 --groups 10 "$@"; }
nowheel() { as "$user_cg" setpriv --reuid 1000 --regid 1000 --clear-groups "$@"; }
game() { as "$game_cg" setpriv --reuid 1000 --regid 1000 --groups 10 "$@"; }

S=com.steampowered.SteamOSManager1
P1=net.seilent.MicroOs.Power1
get() { python3 "$bus" get "$@"; }
set_() { root python3 "$bus" set "$@" > /dev/null || fail "set $*"; }
v() { cat "$1" 2> /dev/null || echo "?"; }
want() { [[ $(v "$1") == "$2" ]] || fail "$3: ${1#"$sys"} is $(v "$1"), expected $2"; }

policy() {
  local d=$pol/$1
  mkdir -p "$d"
  echo "ondemand userspace performance schedutil" > "$d/scaling_available_governors"
  echo schedutil > "$d/scaling_governor"
  echo "$2" > "$d/cpuinfo_min_freq"
  echo "$2" > "$d/scaling_min_freq"
  echo "$3" > "$d/cpuinfo_max_freq"
  echo "$3" > "$d/scaling_max_freq"
  echo "$4" > "$d/affected_cpus"
  echo "$4" > "$d/related_cpus"
}
mktree() {
  local c
  rm -rf "$sys" "$MICROOS_STATEDIR"
  for c in 0 1 2 3 4 5 6 7; do
    mkdir -p "$cpu/cpu$c"
    (( c == 0 )) || echo 1 > "$cpu/cpu$c/online"
  done
  policy policy0 300000 1804800 "0 1 2 3"
  policy policy4 710400 2419200 "4 5 6"
  policy policy7 844800 2841600 7
  mkdir -p "$gpu" "$sys/class/devfreq/1d84000.ufshc" "$sys/class/hwmon/hwmon0" "$sys/class/thermal/thermal_zone0"
  echo simple_ondemand > "$gpu/governor"
  echo "userspace performance simple_ondemand" > "$gpu/available_governors"
  echo "305000000 400000000 441600000 490000000 525000000 587000000" > "$gpu/available_frequencies"
  echo 305000000 > "$gpu/min_freq"
  echo 587000000 > "$gpu/max_freq"
  echo 300000000 > "$sys/class/devfreq/1d84000.ufshc/max_freq"
  echo 0 > "$sys/class/hwmon/hwmon0/pwm1"
  echo enabled > "$sys/class/thermal/thermal_zone0/mode"
  cp "$shipped" "$MICROOS_POWER_PROFILES"
}
snapshot() { (cd "$sys" && find . -type f | grep -Ev "$allowed" | sort | xargs sha256sum); }

start() {
  snap=$(snapshot)
  "$powerd" > "$tmp/log" 2>&1 &
  pd=$!
  python3 "$bus" wait-name 10 || fail "powerd did not own its name: $(tail -n 5 "$tmp/log")"
}
stop() {
  kill "$pd" 2> /dev/null || true
  wait "$pd" 2> /dev/null || true
  pd=""
  [[ $(snapshot) == "$snap" ]] || fail "powerd wrote outside the allowed paths"
}
tdp_rows() {
  printf '\n[tdp]\n3=1804800,1478400,1516800,400000000\n6=1804800,2419200,2841600,587000000\n9=1804800,2419200,2841600,587000000\n' \
    >> "$MICROOS_POWER_PROFILES"
}

mktree
echo 0 > "$cpu/cpu5/online"
echo 0 > "$cpu/cpu7/online"
echo performance > "$pol/policy4/scaling_governor"
echo 2419200 > "$pol/policy4/scaling_min_freq"
echo 525000000 > "$gpu/min_freq"
start
want "$cpu/cpu5/online" 1 "start"
want "$cpu/cpu7/online" 1 "start"
want "$pol/policy4/scaling_governor" schedutil "start"
want "$pol/policy4/scaling_min_freq" 710400 "start"
want "$pol/policy0/scaling_max_freq" 1804800 "balanced"
want "$pol/policy4/scaling_max_freq" 2419200 "balanced"
want "$pol/policy7/scaling_max_freq" 2073600 "balanced"
want "$gpu/governor" simple_ondemand "balanced"
want "$gpu/min_freq" 305000000 "balanced"
want "$gpu/max_freq" 587000000 "balanced"
[[ $(get $P1 AvailableProfiles) == "['low-power', 'balanced', 'performance']" ]] || fail "profiles: $(get $P1 AvailableProfiles)"
[[ $(get $S.PerformanceProfile1 SuggestedDefaultPerformanceProfile) == balanced ]] || fail "suggested default"
[[ $(get $S.CpuScaling1 AvailableCpuScalingGovernors) == "['ondemand', 'performance', 'schedutil']" ]] ||
  fail "governors: $(get $S.CpuScaling1 AvailableCpuScalingGovernors)"
[[ $(get $S.GpuPerformanceLevel1 ManualGpuClockMin) == 305 && $(get $S.GpuPerformanceLevel1 ManualGpuClockMax) == 587 ]] ||
  fail "manual clock range"
ifs=$(python3 "$bus" interfaces)
for i in $P1 $S.PerformanceProfile1 $S.GpuPerformanceLevel1 $S.CpuScaling1; do
  grep -qx "$i" <<< "$ifs" || fail "$i not on the bus"
done
! grep -q TdpLimit1 <<< "$ifs" || fail "TdpLimit1 exported without a [tdp] table"
[[ $(root "$cli" get | tail -n 1) == "tdp none" ]] || fail "cli get: $(root "$cli" get)"

python3 "$bus" monitor "$tmp/mon" &
mon=$!
for _ in $(seq 100); do grep -q ready "$tmp/mon" 2> /dev/null && break; sleep 0.05; done
root "$cli" set-profile low-power || fail "cli set-profile"
for _ in $(seq 100); do grep -q "PerformanceProfile=" "$tmp/mon" && break; sleep 0.05; done
grep -qx "$P1 Profile=low-power" "$tmp/mon" || fail "no PropertiesChanged on Power1: $(cat "$tmp/mon")"
grep -qx "$S.PerformanceProfile1 PerformanceProfile=low-power" "$tmp/mon" || fail "no PropertiesChanged on PerformanceProfile1"
want "$pol/policy0/scaling_max_freq" 1804800 "low-power"
want "$pol/policy4/scaling_max_freq" 1862400 "low-power"
want "$pol/policy7/scaling_max_freq" 2073600 "low-power"
want "$gpu/max_freq" 441600000 "low-power"

ino=$(stat -c %i "$MICROOS_STATEDIR/power.conf")
set_ $S.PerformanceProfile1 PerformanceProfile s performance
[[ $(stat -c %i "$MICROOS_STATEDIR/power.conf") != "$ino" ]] || fail "state file written in place"
[[ $(cat "$MICROOS_STATEDIR/power.conf") == $'profile=performance\ngpu_level=auto\ngpu_clock=587\ngovernor=schedutil\ntdp=' ]] ||
  fail "state file: $(cat "$MICROOS_STATEDIR/power.conf")"
[[ -z $(find "$MICROOS_STATEDIR" -name '.power.conf.*') ]] || fail "temp state file left behind"
want "$pol/policy7/scaling_max_freq" 2841600 "performance"

set_ $S.GpuPerformanceLevel1 GpuPerformanceLevel s manual
set_ $S.GpuPerformanceLevel1 ManualGpuClock u 587
want "$gpu/governor" userspace "manual"
want "$gpu/min_freq" 587000000 "manual 587"
want "$gpu/max_freq" 587000000 "manual 587"
set_ $S.GpuPerformanceLevel1 GpuPerformanceLevel s auto
want "$gpu/governor" simple_ondemand "auto after manual"
want "$gpu/min_freq" 305000000 "auto after manual"
want "$gpu/max_freq" 587000000 "auto after manual"
set_ $P1 GpuLevel s manual
set_ $P1 ManualGpuClock u 900
want "$gpu/max_freq" 587000000 "manual 900"
want "$gpu/min_freq" 587000000 "manual 900"
grep -q "manual GPU clock 900000000 clamped to 587000000" "$tmp/log" || fail "clamp not logged"
[[ $(get $P1 ManualGpuClock) == 900 ]] || fail "ManualGpuClock does not return the request"
set_ $P1 ManualGpuClock u 441
want "$gpu/max_freq" 441600000 "manual 441 snaps to the OPP"
want "$gpu/min_freq" 441600000 "manual 441 snaps to the OPP"
set_ $P1 GpuLevel s auto

set_ $S.CpuScaling1 CpuScalingGovernor s performance
for p in policy0 policy4 policy7; do want "$pol/$p/scaling_governor" performance "governor set"; done
[[ $(get $P1 CpuGovernor) == performance ]] || fail "CpuGovernor getter"
[[ $(root python3 "$bus" set $S.CpuScaling1 CpuScalingGovernor s userspace) == org.freedesktop.DBus.Error.InvalidArgs ]] ||
  fail "userspace governor accepted"
want "$pol/policy0/scaling_governor" performance "userspace refused"

[[ $(wheel python3 "$bus" set $P1 Profile s balanced) == "" ]] || fail "uid 1000 in wheel refused"
want "$pol/policy7/scaling_max_freq" 2073600 "wheel set"
[[ $(nowheel python3 "$bus" set $P1 Profile s low-power) == org.freedesktop.DBus.Error.AccessDenied ]] ||
  fail "uid 1000 without wheel allowed"
[[ $(game python3 "$bus" set $S.PerformanceProfile1 PerformanceProfile s low-power) == org.freedesktop.DBus.Error.AccessDenied ]] ||
  fail "a game cgroup allowed"
[[ $(get $P1 Profile) == balanced ]] || fail "a refused set changed the profile"
grep -q "refused: not in wheel" "$tmp/log" || fail "no wheel refusal line"
grep -q "refused: called from a game" "$tmp/log" || fail "no game refusal line"
clock=$(get $P1 ManualGpuClock)
[[ $(root python3 "$bus" set $P1 ManualGpuClock t 5000000000) == org.freedesktop.DBus.Error.InvalidArgs ]] ||
  fail "a t value for a u property accepted"
[[ $(root python3 "$bus" set $P1 ManualGpuClock b true) == org.freedesktop.DBus.Error.InvalidArgs ]] ||
  fail "a b value for a u property accepted"
[[ $(root python3 "$bus" set $P1 Profile u 1) == org.freedesktop.DBus.Error.InvalidArgs ]] || fail "a u value for an s property accepted"
[[ $(get $P1 ManualGpuClock) == "$clock" && $(get $P1 Profile) == balanced ]] || fail "a wrong type changed the state"
[[ $(get $P1 Nope) == org.freedesktop.DBus.Error.* ]] || fail "Get of an unknown property: $(get $P1 Nope)"
[[ $(get net.seilent.MicroOs.Nope1 Profile) == org.freedesktop.DBus.Error.* ]] || fail "Get on an unknown interface"

echo 2841600 > "$pol/policy7/scaling_max_freq"
echo 525000000 > "$gpu/min_freq"
echo schedutil > "$pol/policy4/scaling_governor"
: > "$tmp/mon"
python3 "$bus" sleep false || fail "stub logind"
for _ in $(seq 100); do [[ $(v "$pol/policy7/scaling_max_freq") == 2073600 ]] && break; sleep 0.05; done
want "$pol/policy7/scaling_max_freq" 2073600 "PrepareForSleep(false)"
want "$gpu/min_freq" 305000000 "PrepareForSleep(false)"
want "$pol/policy4/scaling_governor" performance "PrepareForSleep(false)"
stop
: > "$tmp/mon"
start
for _ in $(seq 100); do grep -q "PerformanceProfile=" "$tmp/mon" && break; sleep 0.05; done
grep -qx "$S.PerformanceProfile1 PerformanceProfile=balanced" "$tmp/mon" || fail "no PropertiesChanged after a restart"
want "$pol/policy4/scaling_governor" performance "governor after a restart"
stop
kill "$mon"
mon=""

mktree
printf 'default=balanced\n[balanced]\npolicy7=2073600\nturbo=1\n' > "$MICROOS_POWER_PROFILES"
start
grep -q "unknown key turbo, using stock clocks" "$tmp/log" || fail "no profile parse fallback line: $(cat "$tmp/log")"
[[ $(get $P1 AvailableProfiles) == "['low-power', 'balanced', 'performance']" ]] || fail "fallback profiles"
want "$pol/policy7/scaling_max_freq" 2841600 "profile fallback"
stop

mktree
mkdir -p "$MICROOS_STATEDIR"
printf 'profile=balanced\ngpu_level=fast\n' > "$MICROOS_STATEDIR/power.conf"
printf 'default=balanced\n[balanced]\npolicy7=2073600\n[performance]\ngpu=670000000\n' > "$MICROOS_POWER_PROFILES"
echo "305000000 400000000 441600000 490000000 525000000 587000000 670000000" > "$gpu/available_frequencies"
echo 670000000 > "$gpu/max_freq"
start
grep -q "using defaults" "$tmp/log" || fail "no state parse fallback line"
want "$gpu/max_freq" 587000000 "GPU cap at start"
set_ $P1 Profile s performance
want "$gpu/max_freq" 587000000 "GPU cap with a 670 MHz profile"
set_ $P1 GpuLevel s manual
set_ $P1 ManualGpuClock u 670
want "$gpu/max_freq" 587000000 "GPU cap with a 670 MHz manual clock"
stop

mktree
tdp_rows
start
ifs=$(python3 "$bus" interfaces)
grep -qx $S.TdpLimit1 <<< "$ifs" || fail "TdpLimit1 not exported with a [tdp] table"
[[ $(get $S.TdpLimit1 TdpLimitMin) == 3 && $(get $S.TdpLimit1 TdpLimitMax) == 9 ]] || fail "TdpLimitMin/Max"
[[ $(get $S.TdpLimit1 TdpLimit) == 9 ]] || fail "default TdpLimit"
set_ $P1 Profile s low-power
set_ $S.TdpLimit1 TdpLimit u 5
want "$pol/policy4/scaling_max_freq" 1478400 "5 W takes the 3 W row"
want "$pol/policy7/scaling_max_freq" 1516800 "5 W takes the 3 W row"
want "$gpu/max_freq" 400000000 "5 W takes the 3 W row"
set_ $S.TdpLimit1 TdpLimit u 6
want "$pol/policy4/scaling_max_freq" 1862400 "min(low-power, 6 W row)"
want "$pol/policy7/scaling_max_freq" 2073600 "min(low-power, 6 W row)"
want "$gpu/max_freq" 441600000 "min(low-power, 6 W row)"
set_ $S.TdpLimit1 TdpLimit u 1
want "$pol/policy7/scaling_max_freq" 1516800 "below the lowest row"
set_ $P1 Profile s balanced
set_ $P1 GpuLevel s manual
set_ $P1 ManualGpuClock u 587
want "$gpu/max_freq" 400000000 "manual clock under the 3 W row"
want "$gpu/min_freq" 400000000 "manual clock under the 3 W row"
[[ $(root "$cli" get | tail -n 1) == "tdp 1 (3 to 9)" ]] || fail "cli tdp: $(root "$cli" get | tail -n 1)"
stop

mktree
tdp_rows
start
caps() {
  local p lo hi
  for p in policy0 policy4 policy7; do
    lo=$(v "$pol/$p/scaling_min_freq")
    hi=$(v "$pol/$p/scaling_max_freq")
    (( lo >= $(v "$pol/$p/cpuinfo_min_freq") && lo <= hi && hi <= $(v "$pol/$p/cpuinfo_max_freq") )) ||
      fail "$1: $p min $lo max $hi"
    [[ $(v "$pol/$p/scaling_governor") != userspace ]] || fail "$1: $p governor userspace"
  done
  lo=$(v "$gpu/min_freq")
  hi=$(v "$gpu/max_freq")
  (( lo >= 305000000 && lo <= hi && hi <= 587000000 )) || fail "$1: GPU min $lo max $hi"
}
extreme() { wheel python3 "$bus" set "$@" > /dev/null || true; caps "$*"; }
for level in auto manual; do
  extreme $P1 GpuLevel s $level
  for c in 0 1 586 588 4294967295; do extreme $P1 ManualGpuClock u $c; done
done
for w in 0 1 4294967295; do extreme $S.TdpLimit1 TdpLimit u $w; done
for g in ondemand userspace performance schedutil conservative ""; do extreme $P1 CpuGovernor s "$g"; done
for p in low-power balanced performance turbo ""; do extreme $P1 Profile s "$p"; done
grep -q "by uid 1000 refused" "$tmp/log" && fail "a wheel caller outside a game was refused"
stop

mktree
: > "$pol/policy7/affected_cpus"
rm -f "$pol/policy4/scaling_min_freq"
mkdir "$pol/policy4/scaling_min_freq"
start
grep -q "policy7 inactive, skipped" "$tmp/log" || fail "inactive policy not skipped"
want "$pol/policy7/scaling_max_freq" 2841600 "inactive policy7"
grep -q "write /devices/system/cpu/cpufreq/policy4/scaling_min_freq=710400" "$tmp/log" || fail "failed write not logged"
want "$pol/policy4/scaling_governor" schedutil "after a failed write"
want "$pol/policy4/scaling_max_freq" 2419200 "after a failed write"
want "$gpu/max_freq" 587000000 "after a failed write"
set_ $P1 CpuGovernor s ondemand
want "$pol/policy0/scaling_governor" ondemand "governor set"
want "$pol/policy4/scaling_governor" ondemand "governor set"
want "$pol/policy7/scaling_governor" schedutil "governor set on an inactive policy"
stop

if (( rc == 0 )); then
  echo "powerd: ok"
fi
exit "$rc"
