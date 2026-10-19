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
pd="" daemon="" mon="" h1="" h2="" hs="" sd=""
cleanup() {
  local p
  for p in $pd $mon $h1 $h2 $hs $sd $daemon; do kill "$p" 2> /dev/null || true; done
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
allowed+='|/fs/cgroup/user\.slice(/user-[0-9]+\.slice(/user@[0-9]+\.service(/game\.slice)?)?)?/cpu\.uclamp\.min$'

if grep -nE 'hwmon|thermal|pwm' "$powerd"; then fail "powerd names a hwmon, thermal or pwm path"; fi
if grep -nE '/var/lib|power\.conf|STATEDIR' "$powerd"; then fail "powerd names a state file"; fi
rw=$(grep '^ReadWritePaths=' "$tree/usr/lib/systemd/system/microos-powerd.service")
[[ $rw == "ReadWritePaths=/sys/devices/system/cpu -/sys/class/devfreq/3d00000.gpu /sys/fs/cgroup" ]] || fail "powerd unit $rw"

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
    <allow own="org.freedesktop.systemd1"/>
    <allow send_destination="org.freedesktop.systemd1"/>
  </policy>
  <include>$tree/usr/share/dbus-1/system.d/net.seilent.MicroOs.Power.conf</include>
</busconfig>
EOF
dbus-daemon --config-file="$tmp/bus.conf" --nofork --nopidfile > "$tmp/dbus.log" 2>&1 &
daemon=$!
for _ in $(seq 100); do [[ -S $tmp/bus/socket ]] && break; sleep 0.05; done
[[ -S $tmp/bus/socket ]] || { echo "FAIL: dbus-daemon: $(cat "$tmp/dbus.log")" >&2; exit 1; }

enter='mkdir -p "$MICROOS_PROC/$$" && printf "%s\n" "$0" > "$MICROOS_PROC/$$/cgroup" && exec "$@"'
as() {
  local cg=$1
  shift
  sh -c "$enter" "$cg" "$@"
}
user_cg=0::/user.slice/user-1000.slice/user@1000.service/app.slice/steamos-manager.service
game_cg=0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-steam-app1145360-1.scope
root() { as 0::/system.slice/sshd.service "$@"; }
spawn() { exec sh -c "$enter" 0::/system.slice/sshd.service "$@"; }
wheel() { as "$user_cg" setpriv --reuid 1000 --regid 1000 --groups 10 "$@"; }
nowheel() { as "$user_cg" setpriv --reuid 1000 --regid 1000 --clear-groups "$@"; }
emu_cg=0::/user.slice/user-1000.slice/user@1000.service/app.slice/microemu-game.scope
emu_like_cg=0::/user.slice/user-1000.slice/user@1000.service/app.slice/microemu-game.scope-x.service
game() { as "$game_cg" setpriv --reuid 1000 --regid 1000 --groups 10 "$@"; }
emu() { as "$emu_cg" setpriv --reuid 1000 --regid 1000 --groups 10 "$@"; }
emu_like() { as "$emu_like_cg" setpriv --reuid 1000 --regid 1000 --groups 10 "$@"; }

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
  awk '/^\[/ { skip = ($0 == "[tdp]") } !skip' "$shipped" > "$MICROOS_POWER_PROFILES"
}
snapshot() { (cd "$sys" && find . -type f | grep -Ev "$allowed" | sort | xargs sha256sum); }

start() {
  snap=$(snapshot)
  "$@" "$powerd" > "$tmp/log" 2>&1 &
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

set_ $S.PerformanceProfile1 PerformanceProfile s performance
[[ -z $(ls -A "$MICROOS_STATEDIR" 2> /dev/null) ]] || fail "state written: $(ls -A "$MICROOS_STATEDIR")"
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
grep -q "gpu_clock 900 clamped to 587" "$tmp/log" || fail "clamp not logged"
[[ $(get $P1 ManualGpuClock) == 587 ]] || fail "ManualGpuClock 900 published as $(get $P1 ManualGpuClock)"
grep -qx "$P1 ManualGpuClock=900" "$tmp/mon" && fail "ManualGpuClock 900 published unclamped"
set_ $P1 ManualGpuClock u 0
[[ $(get $S.GpuPerformanceLevel1 ManualGpuClock) == 305 ]] || fail "ManualGpuClock 0 published as $(get $P1 ManualGpuClock)"
grep -qx "$S.GpuPerformanceLevel1 ManualGpuClock=305" "$tmp/mon" || fail "no PropertiesChanged with the clamped clock"
want "$gpu/max_freq" 305000000 "manual 0"
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
[[ $(emu python3 "$bus" set $P1 Profile s low-power) == org.freedesktop.DBus.Error.AccessDenied ]] ||
  fail "a MicroEMU game scope allowed"
[[ $(get $P1 Profile) == balanced ]] || fail "a refused set changed the profile"
[[ $(emu_like python3 "$bus" set $P1 Profile s balanced) == "" ]] || fail "a unit named like the MicroEMU game scope refused"
grep -q "refused: not in wheel" "$tmp/log" || fail "no wheel refusal line"
long=$(printf 'x%.0s' $(seq 5000))
[[ $(nowheel python3 "$bus" set $P1 Profile s "$long") == org.freedesktop.DBus.Error.AccessDenied ]] || fail "a long value without wheel allowed"
[[ $(nowheel python3 "$bus" calls "Hold:$long") == org.freedesktop.DBus.Error.AccessDenied ]] || fail "a long mode without wheel allowed"
grep -q xxxx "$tmp/log" && fail "a refused value logged"
grep -qx "set $P1.Profile by uid 1000 refused: not in wheel" "$tmp/log" || fail "no refusal line without the value"
[[ $(root python3 "$bus" set $P1 Profile s "$long") == org.freedesktop.DBus.Error.InvalidArgs ]] || fail "a long profile accepted"
grep -qx "set $P1.Profile='x\{63\} by uid 0" "$tmp/log" || fail "accepted value not cut to 64: $(grep -o "Profile='x*" "$tmp/log" | tail -n 1 | wc -c)"
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
want "$pol/policy4/scaling_governor" schedutil "governor default after a restart"
[[ $(get $P1 CpuGovernor) == schedutil && $(get $P1 GpuLevel) == auto ]] || fail "restart kept a value"
[[ -z $(ls -A "$MICROOS_STATEDIR" 2> /dev/null) ]] || fail "state written: $(ls -A "$MICROOS_STATEDIR")"
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
printf 'default=balanced\n[balanced]\npolicy7=2073600\n[performance]\ngpu=670000000\n' > "$MICROOS_POWER_PROFILES"
echo "305000000 400000000 441600000 490000000 525000000 587000000 670000000" > "$gpu/available_frequencies"
echo 670000000 > "$gpu/max_freq"
start
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
[[ $(get $S.TdpLimit1 TdpLimit) == 3 ]] || fail "TdpLimit 1 published as $(get $S.TdpLimit1 TdpLimit)"
set_ $S.TdpLimit1 TdpLimit u 4294967295
[[ $(get $S.TdpLimit1 TdpLimit) == 9 ]] || fail "TdpLimit 4294967295 published as $(get $S.TdpLimit1 TdpLimit)"
set_ $S.TdpLimit1 TdpLimit u 1
set_ $P1 Profile s balanced
set_ $P1 GpuLevel s manual
set_ $P1 ManualGpuClock u 587
want "$gpu/max_freq" 400000000 "manual clock under the 3 W row"
want "$gpu/min_freq" 400000000 "manual clock under the 3 W row"
[[ $(root "$cli" get | tail -n 1) == "tdp 3 (3 to 9)" ]] || fail "cli tdp: $(root "$cli" get | tail -n 1)"
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

mktree
cp "$shipped" "$MICROOS_POWER_PROFILES"
start
[[ $(get $S.TdpLimit1 TdpLimitMin) == 3 && $(get $S.TdpLimit1 TdpLimitMax) == 10 ]] || fail "shipped TdpLimitMin/Max"
set_ $S.TdpLimit1 TdpLimit u 3
want "$pol/policy7/scaling_max_freq" 844800 "shipped 3 W row"
want "$gpu/max_freq" 400000000 "shipped 3 W row"
stop

mktree
made=""
getent passwd microset > /dev/null || { useradd -r -M microset; made=1; }
ms=$(id -u microset)
microset() { as 0::/system.slice/microsetd.service setpriv --reuid "$ms" --regid "$ms" --clear-groups "$@"; }
start
[[ $(microset python3 "$bus" set $P1 Profile s low-power) == "" ]] || fail "uid of microset refused"
[[ $(get $P1 Profile) == low-power ]] || fail "set by microset not applied"
[[ $(microset python3 "$bus" set $S.PerformanceProfile1 PerformanceProfile s balanced) == org.freedesktop.DBus.Error.AccessDenied ]] ||
  fail "microset allowed on PerformanceProfile1"
[[ $(microset python3 "$bus" calls Hold:dap Release:dap | paste -sd ' ') == "org.freedesktop.DBus.Error.AccessDenied org.freedesktop.DBus.Error.AccessDenied" ]] ||
  fail "Hold or Release by microset allowed"
[[ $(get $P1 Holds) == "[]" ]] || fail "Hold by microset held"
stop
if [[ -n $made ]]; then
  userdel microset
  start
  [[ $(microset python3 "$bus" set $P1 Profile s low-power) == org.freedesktop.DBus.Error.AccessDenied ]] ||
    fail "uid of a removed microset user allowed"
  stop
fi

holds() { get $P1 Holds; }
taken() { grep -c "dap hold by" "$tmp/log" || true; }
held() {
  local _
  for _ in $(seq 100); do (( $(taken) > $1 )) && break; sleep 0.05; done
  (( $(taken) > $1 )) || fail "no hold after $1"
  [[ $(holds) == "['dap']" ]] || fail "hold after $1 not taken: $(holds)"
}
released() {
  local _
  for _ in $(seq 100); do [[ $(holds) == "[]" ]] && break; sleep 0.05; done
  [[ $(holds) == "[]" ]] || fail "$1: holds $(holds)"
}
dap() {
  local c
  for c in 1 2 3; do want "$cpu/cpu$c/online" 1 "$1"; done
  for c in 4 5 6 7; do want "$cpu/cpu$c/online" 0 "$1"; done
  want "$pol/policy0/scaling_max_freq" 787200 "$1"
  want "$gpu/governor" simple_ondemand "$1"
  want "$gpu/min_freq" 305000000 "$1"
  want "$gpu/max_freq" 305000000 "$1"
}
online() {
  local c
  for c in 1 2 3 4 5 6 7; do want "$cpu/cpu$c/online" 1 "$1"; done
}
exited() {
  local code=0
  kill "$1"
  wait "$1" || code=$?
  (( code == 0 )) || fail "$2 exited $code"
}

mktree
start
python3 "$bus" monitor "$tmp/mon" &
mon=$!
for _ in $(seq 100); do grep -q ready "$tmp/mon" 2> /dev/null && break; sleep 0.05; done
[[ $(holds) == "[]" ]] || fail "holds at start: $(holds)"
n=$(taken)
spawn "$cli" hold dap &
h1=$!
held "$n"
dap "hold"
for _ in $(seq 100); do grep -q "Holds=" "$tmp/mon" && break; sleep 0.05; done
grep -qx "$P1 Holds=\['dap'\]" "$tmp/mon" || fail "no PropertiesChanged for Holds: $(cat "$tmp/mon")"
set_ $S.PerformanceProfile1 PerformanceProfile s performance
set_ $P1 GpuLevel s manual
set_ $P1 ManualGpuClock u 587
dap "setters under a hold"
[[ $(get $P1 Profile) == performance && $(get $P1 GpuLevel) == manual && $(get $P1 ManualGpuClock) == 587 ]] ||
  fail "setters under a hold not stored"
n=$(taken)
spawn "$cli" hold dap &
h2=$!
held "$n"
exited "$h1" "hold 1"
h1=""
[[ $(holds) == "['dap']" ]] || fail "hold 2 lost with hold 1"
dap "second holder"
exited "$h2" "hold 2"
h2=""
released "name loss"
grep -qx "$P1 Holds=\[\]" "$tmp/mon" || fail "no PropertiesChanged for the release: $(cat "$tmp/mon")"
online "name loss"
want "$pol/policy0/scaling_max_freq" 1804800 "performance after the release"
want "$pol/policy7/scaling_max_freq" 2841600 "performance after the release"
want "$gpu/governor" userspace "manual after the release"
want "$gpu/min_freq" 587000000 "manual after the release"
want "$gpu/max_freq" 587000000 "manual after the release"

out=$(root python3 "$bus" calls Hold:dap holds Hold:dap holds Release:dap holds Release:dap holds | paste -sd ' ')
[[ $out == "ok ['dap'] ok ['dap'] ok [] ok []" ]] || fail "Hold, Hold, Release, Release: $out"
online "Release"
want "$gpu/governor" userspace "manual after Release"
[[ $(root python3 "$bus" calls Hold:x Release:x | paste -sd ' ') == "org.freedesktop.DBus.Error.InvalidArgs org.freedesktop.DBus.Error.InvalidArgs" ]] ||
  fail "a mode other than dap or dap-off accepted"
out=$(root python3 "$bus" calls Hold:dap-off holds Hold:dap holds Hold:dap-off holds Release:dap holds | paste -sd ' ')
[[ $out == "ok ['dap-off'] ok ['dap'] ok ['dap-off'] ok []" ]] || fail "one name dap-off, dap, dap-off, Release: $out"
online "Release of a replaced mode"
[[ $(nowheel python3 "$bus" calls Hold:dap) == org.freedesktop.DBus.Error.AccessDenied ]] || fail "Hold without wheel allowed"
[[ $(game python3 "$bus" calls Hold:dap) == org.freedesktop.DBus.Error.AccessDenied ]] || fail "Hold from a game allowed"
[[ $(holds) == "[]" ]] || fail "a refused Hold held: $(holds)"
code=0
root "$cli" hold x 2> /dev/null || code=$?
(( code == 1 )) || fail "cli hold x exited $code"
kill -STOP "$pd"
root python3 "$bus" hold-gone dap
kill -CONT "$pd"
for _ in $(seq 100); do grep -q "Hold by uid None refused: no credentials" "$tmp/log" && break; sleep 0.05; done
grep -q "Hold by uid None refused: no credentials" "$tmp/log" || fail "a name gone at Hold not refused: $(tail -n 3 "$tmp/log")"
released "a name gone at Hold"
online "a name gone at Hold"
outcomes() { grep -cE "Hold by uid None refused: no credentials|Hold by :[0-9.]+ dropped: name gone|dap hold of .* released" "$tmp/log" || true; }
o=$(outcomes)
root python3 "$bus" hold-gone dap
for _ in $(seq 100); do (( $(outcomes) > o )) && break; sleep 0.05; done
(( $(outcomes) > o )) || fail "a name gone during Hold left no line: $(tail -n 3 "$tmp/log")"
released "a name gone during Hold"
online "a name gone during Hold"

applies() { grep -c "^applied" "$tmp/log" || true; }
gone() { grep -c "dap hold of .* released" "$tmp/log" || true; }
changes() { grep -c "Holds=" "$tmp/mon" || true; }
a=$(applies) m=$(changes)
for _ in 1 2 3 4; do
  n=$(taken)
  spawn "$cli" hold dap &
  hs="$hs $!"
  held "$n"
done
(( $(applies) == a + 1 )) || fail "four holders applied $(( $(applies) - a )) times"
dap "four holders"
[[ $(root python3 "$bus" calls Hold:dap) == org.freedesktop.DBus.Error.LimitsExceeded ]] || fail "a fifth holder accepted"
read -ra holders <<< "$hs"
g=$(gone)
for p in "${holders[@]:0:3}"; do exited "$p" "holder $p"; done
for _ in $(seq 100); do (( $(gone) == g + 3 )) && break; sleep 0.05; done
(( $(gone) == g + 3 )) || fail "three holders not released"
(( $(applies) == a + 1 )) || fail "releases that left a holder applied $(( $(applies) - a - 1 )) times"
dap "one of four holders left"
exited "${holders[3]}" "holder ${holders[3]}"
hs=""
released "last of four holders"
(( $(applies) == a + 2 )) || fail "four holders and their release applied $(( $(applies) - a )) times"
online "last of four holders"
for _ in $(seq 100); do (( $(changes) == m + 2 )) && break; sleep 0.05; done
(( $(changes) == m + 2 )) || fail "Holds changed $(( $(changes) - m )) times for four holders"

n=$(taken)
spawn "$cli" hold dap &
h1=$!
held "$n"
dap "hold before a restart"
stop
start
[[ $(holds) == "[]" ]] || fail "holds after a restart: $(holds)"
online "restart"
want "$pol/policy0/scaling_max_freq" 1804800 "restart"
exited "$h1" "hold over a restart"
h1=""
stop
kill "$mon"
mon=""

off() {
  local c
  for c in 1 2 3; do want "$cpu/cpu$c/online" 1 "$1"; done
  for c in 4 5 6 7; do want "$cpu/cpu$c/online" 0 "$1"; done
  want "$pol/policy0/scaling_max_freq" 1804800 "$1"
  want "$gpu/governor" userspace "$1"
  want "$gpu/min_freq" 525000000 "$1"
  want "$gpu/max_freq" 525000000 "$1"
}
send() {
  local n _
  n=$(wc -l < "$tmp/hout")
  echo "$1" >&3
  for _ in $(seq 100); do (( $(wc -l < "$tmp/hout") > n )) && break; sleep 0.05; done
  [[ $(tail -n 1 "$tmp/hout") == ok ]] || fail "$1: $(tail -n 1 "$tmp/hout")"
}
settled() {
  local _
  for _ in $(seq 100); do [[ $(holds) == "$1" ]] && (( $(applies) == $2 )) && break; sleep 0.05; done
  [[ $(holds) == "$1" ]] || fail "$3: holds $(holds), expected $1"
  (( $(applies) == $2 )) || fail "$3: applied $(( $(applies) - a )) times, expected $(( $2 - a ))"
}

mktree
start
set_ $S.PerformanceProfile1 PerformanceProfile s performance
set_ $P1 GpuLevel s manual
set_ $P1 ManualGpuClock u 525
a=$(applies)
mkfifo "$tmp/hin"
: > "$tmp/hout"
root python3 "$bus" holder < "$tmp/hin" > "$tmp/hout" &
h2=$!
exec 3> "$tmp/hin"
send Hold:dap
settled "['dap']" $(( a + 1 )) "dap by one name"
dap "dap by one name"
send Hold:dap-off
settled "['dap-off']" $(( a + 2 )) "dap to dap-off by one name"
off "dap to dap-off by one name"
send Hold:dap-off
settled "['dap-off']" $(( a + 2 )) "dap-off again by the same name"
spawn "$cli" hold dap &
h1=$!
settled "['dap', 'dap-off']" $(( a + 3 )) "dap next to dap-off"
dap "dap wins over dap-off"
send Hold:dap
settled "['dap']" $(( a + 3 )) "dap-off to dap under another dap"
send Hold:dap-off
settled "['dap', 'dap-off']" $(( a + 3 )) "dap to dap-off under another dap"
dap "dap still wins"
exited "$h1" "dap next to dap-off"
h1=""
settled "['dap-off']" $(( a + 4 )) "dap holder gone"
off "dap holder gone"
send Release:dap-off
settled "[]" $(( a + 5 )) "Release of dap-off"
online "Release of dap-off"
want "$gpu/governor" userspace "manual after dap-off"
want "$gpu/max_freq" 525000000 "manual after dap-off"
send Hold:dap-off
settled "['dap-off']" $(( a + 6 )) "dap-off hold"
off "dap-off hold"
exec 3>&-
code=0
wait "$h2" || code=$?
h2=""
(( code == 0 )) || fail "dap-off holder exited $code"
settled "[]" $(( a + 7 )) "dap-off name loss"
online "dap-off name loss"
stop

cg=$sys/fs/cgroup
users=$cg/user.slice
rusers=/fs/cgroup/user.slice
mgr() { echo "$users/user-$1.slice/user@$1.service"; }
cgdir() {
  mkdir -p "$1"
  echo 0.00 > "$1/cpu.uclamp.min"
  echo max > "$1/cpu.uclamp.max"
  : > "$1/cgroup.procs"
  echo "cpu memory pids" > "$1/cgroup.subtree_control"
}
utree() {
  local d
  for d in "$users" "$users/user-$1.slice" "$(mgr "$1")" "$(mgr "$1")/app.slice" "$(mgr "$1")/app.slice/app-steam-app1-1.scope"; do
    cgdir "$d"
  done
}
gslice() { cgdir "$(mgr "$1")/game.slice"; }
chain() { echo "$users" "$users/user-$1.slice" "$(mgr "$1")" "$(mgr "$1")/game.slice"; }
floors() {
  local d _
  for _ in $(seq 100); do
    for d in $(chain "$1"); do [[ $(v "$d/cpu.uclamp.min") == "$2" ]] || { sleep 0.05; continue 2; }; done
    break
  done
  for d in $(chain "$1"); do want "$d/cpu.uclamp.min" "$2" "$3"; done
}
stamps() { find "$cg" -name cpu.uclamp.min -printf '%p %T@\n' 2> /dev/null | sort; }
writes() { grep -c "^floor $1 on" "$tmp/log" || true; }
watches() { cat /proc/"$pd"/fdinfo/* 2> /dev/null | grep -c '^inotify wd:' || true; }
in_cg() {
  local c=$1
  shift
  as "0::/user.slice/user-1000.slice/user@1000.service/$c" setpriv --reuid 1000 --regid 1000 --groups 10 "$@"
}
sdstart() {
  local _
  rm -f "$tmp/sdin"
  mkfifo "$tmp/sdin"
  : > "$tmp/sdout"
  root python3 "$bus" systemd < "$tmp/sdin" > "$tmp/sdout" &
  sd=$!
  exec 4> "$tmp/sdin"
  for _ in $(seq 100); do grep -q ready "$tmp/sdout" && break; sleep 0.05; done
}
sdstop() {
  exec 4>&-
  wait "$sd" || true
  sd=""
}
sdsend() {
  local n _
  n=$(grep -c '^ok$' "$tmp/sdout" || true)
  echo "$1" >&4
  for _ in $(seq 100); do (( $(grep -c '^ok$' "$tmp/sdout" || true) > n )) && break; sleep 0.05; done
}
subscribed() {
  local _
  for _ in $(seq 100); do grep -q Subscribe "$tmp/sdout" && break; sleep 0.05; done
  grep -q Subscribe "$tmp/sdout" || fail "$1: no Subscribe"
}

mktree
tdp_rows
utree 1000
gslice 1000
echo 0.00 > "$cg/cpu.uclamp.min"
cgdir "$cg/system.slice"
s0=$(stamps)
start
[[ $(get $P1 GameCpuFloor) == 0 ]] || fail "GameCpuFloor at start: $(get $P1 GameCpuFloor)"
[[ $(root "$cli" get | grep game-floor) == "game-floor 0" ]] || fail "cli get: $(root "$cli" get)"
grep -q "^applied .* floor=0 " "$tmp/log" || fail "no floor in the applied line"
[[ $(stamps) == "$s0" ]] || fail "floor 0 from start wrote a cpu.uclamp.min"
set_ $P1 GameCpuFloor u 68
floors 1000 68 "set 68"
want "$(mgr 1000)/app.slice/cpu.uclamp.min" 0.00 "app.slice at 68"
want "$(mgr 1000)/app.slice/app-steam-app1-1.scope/cpu.uclamp.min" 0.00 "scope at 68"
want "$(mgr 1000)/game.slice/cpu.uclamp.max" max "cpu.uclamp.max at 68"
(( $(writes 68) == 4 )) || fail "set 68 wrote $(writes 68) times"
s1=$(stamps)
set_ $P1 GameCpuFloor u 68
set_ $P1 CpuGovernor s performance
set_ $P1 Profile s low-power
set_ $P1 Profile s balanced
set_ $P1 CpuGovernor s schedutil
set_ $S.TdpLimit1 TdpLimit u 5
set_ $S.TdpLimit1 TdpLimit u 9
floors 1000 68 "governor, profile and TDP sets"
[[ $(stamps) == "$s1" ]] || fail "an identical apply wrote a cpu.uclamp.min"
(( $(writes 68) == 4 )) || fail "identical applies wrote $(( $(writes 68) - 4 )) times"
for f in 84 100 4294967295; do
  set_ $P1 GameCpuFloor u "$f"
  [[ $(get $P1 GameCpuFloor) == 83 ]] || fail "GameCpuFloor $f published as $(get $P1 GameCpuFloor)"
  floors 1000 83 "GameCpuFloor $f"
done
grep -q "game_floor 100 clamped to 83" "$tmp/log" || fail "floor clamp not logged"
[[ $(in_cg game.slice/app-steam-app1-1.scope python3 "$bus" set $P1 GameCpuFloor u 0) == org.freedesktop.DBus.Error.AccessDenied ]] ||
  fail "a Steam game scope under game.slice allowed"
[[ $(in_cg app.slice/microemu-game.scope python3 "$bus" set $P1 GameCpuFloor u 0) == org.freedesktop.DBus.Error.AccessDenied ]] ||
  fail "a MicroEMU game scope allowed"
[[ $(in_cg game.slice/microemu-game.scope/core python3 "$bus" set $P1 GameCpuFloor u 0) == org.freedesktop.DBus.Error.AccessDenied ]] ||
  fail "a cgroup below the MicroEMU game scope allowed"
[[ $(get $P1 GameCpuFloor) == 83 ]] || fail "a refused set changed the floor"
[[ $(in_cg app.slice/app-steam-appx.scope python3 "$bus" set $P1 GameCpuFloor u 68) == org.freedesktop.DBus.Error.AccessDenied ]] ||
  fail "a scope named app-steam-appx allowed"
[[ $(in_cg app.slice/app-steam-x.service python3 "$bus" set $P1 GameCpuFloor u 68) == "" ]] ||
  fail "a unit named app-steam-x.service refused"
floors 1000 68 "set from app-steam-x.service"
root "$cli" game-floor 49 || fail "cli game-floor"
floors 1000 49 "cli game-floor 49"
[[ $(root "$cli" get | grep game-floor) == "game-floor 49" ]] || fail "cli get after game-floor 49"
rm -rf "$(mgr 1000)/game.slice"
mkdir -p "$tmp/stage"
cgdir "$tmp/stage/game.slice"
mv "$tmp/stage/game.slice" "$(mgr 1000)/"
floors 1000 49 "game.slice made after arm"
rm -rf "$(mgr 1000)/game.slice"
mkdir "$(mgr 1000)/game.slice"
sleep 0.3
gslice 1000
floors 1000 49 "cpu.uclamp.min added after game.slice"
echo 0.00 > "$tmp/target"
rm "$(mgr 1000)/game.slice/cpu.uclamp.min"
ln -s "$tmp/target" "$(mgr 1000)/game.slice/cpu.uclamp.min"
set_ $P1 GameCpuFloor u 28
want "$tmp/target" 0.00 "symlink in place of cpu.uclamp.min"
[[ -L $(mgr 1000)/game.slice/cpu.uclamp.min ]] || fail "symlink replaced"
grep -q "^write $rusers/user-1000.slice/user@1000.service/game.slice/cpu.uclamp.min=28: " "$tmp/log" || fail "symlink write not logged"
rm "$(mgr 1000)/game.slice/cpu.uclamp.min"
set_ $P1 CpuGovernor s schedutil
for _ in $(seq 160); do grep -q "missing after" "$tmp/log" && break; sleep 0.05; done
grep -qx "floor: $rusers/user-1000.slice/user@1000.service/game.slice/cpu.uclamp.min missing after 50 polls" "$tmp/log" ||
  fail "missing cpu.uclamp.min not logged: $(tail -n 3 "$tmp/log")"
echo 0.00 > "$(mgr 1000)/game.slice/cpu.uclamp.min"
set_ $P1 GameCpuFloor u 28
echo 28.32 > "$(mgr 1000)/game.slice/cpu.uclamp.min"
set_ $P1 CpuGovernor s schedutil
want "$(mgr 1000)/game.slice/cpu.uclamp.min" 28 "28.32 with floor 28"
echo max > "$(mgr 1000)/game.slice/cpu.uclamp.min"
set_ $P1 CpuGovernor s schedutil
want "$(mgr 1000)/game.slice/cpu.uclamp.min" 28 "max with floor 28"
rm "$(mgr 1000)/game.slice/cpu.uclamp.min"
set_ $P1 GameCpuFloor u 0
sleep 6
(( $(grep -c "missing after" "$tmp/log") == 1 )) || fail "floor 0 polled a missing file: $(grep "missing after" "$tmp/log")"
stop

MICROOS_SYSFS=$sys python3 - "$powerd" > "$tmp/refused" 2>&1 <<'PY'
import importlib.machinery
import importlib.util
import sys

loader = importlib.machinery.SourceFileLoader("powerd", sys.argv[1])
powerd = importlib.util.module_from_spec(importlib.util.spec_from_loader("powerd", loader))
loader.exec_module(powerd)
m = "/fs/cgroup/user.slice/user-1000.slice/user@1000.service"
for rel in (f"{m}/app.slice/cpu.uclamp.min", f"{m}/app.slice/app-steam-app1-1.scope/cpu.uclamp.min",
            f"{m}/game.slice/cpu.uclamp.max", f"{m}/game.slice/cgroup.procs", f"{m}/game.slice/cgroup.subtree_control",
            "/fs/cgroup/system.slice/cpu.uclamp.min", "/fs/cgroup/cpu.uclamp.min"):
    powerd.write_cgroup(rel, 68)
PY
for rel in app.slice/cpu.uclamp.min app.slice/app-steam-app1-1.scope/cpu.uclamp.min game.slice/cpu.uclamp.max \
  game.slice/cgroup.procs game.slice/cgroup.subtree_control; do
  grep -qx "refused write $rusers/user-1000.slice/user@1000.service/$rel" "$tmp/refused" || fail "write to $rel not refused"
done
for rel in system.slice/cpu.uclamp.min cpu.uclamp.min; do
  grep -qx "refused write /fs/cgroup/$rel" "$tmp/refused" || fail "write to /fs/cgroup/$rel not refused"
done
want "$(mgr 1000)/app.slice/cpu.uclamp.min" 0.00 "refused app.slice"
want "$(mgr 1000)/game.slice/cpu.uclamp.max" max "refused cpu.uclamp.max"
[[ -z $(v "$(mgr 1000)/game.slice/cgroup.procs") ]] || fail "refused cgroup.procs written"
want "$(mgr 1000)/game.slice/cgroup.subtree_control" "cpu memory pids" "refused cgroup.subtree_control"
want "$cg/system.slice/cpu.uclamp.min" 0.00 "refused system.slice"
want "$cg/cpu.uclamp.min" 0.00 "refused root cgroup"

for d in "$users" "$users/user-1000.slice" "$(mgr 1000)"; do echo 68 > "$d/cpu.uclamp.min"; done
echo 28.32 > "$(mgr 1000)/game.slice/cpu.uclamp.min"
start
floors 1000 0 "stale values at start with floor 0"
stop

mktree
start
sdstart
subscribed "systemd after powerd"
set_ $P1 GameCpuFloor u 68
utree 1000
gslice 1000
snap=$(snapshot)
sdsend "job user@1000.service done"
floors 1000 68 "JobRemoved done, active"
(( $(watches) == 1 )) || fail "$(watches) inotify watches after one arm"
utree 1001
mkdir "$(mgr 1001)/game.slice"
snap=$(snapshot)
sdsend "state user@1001.service inactive"
sdsend "job user@1001.service done"
sleep 0.3
echo 0.00 > "$(mgr 1001)/game.slice/cpu.uclamp.min"
sleep 0.3
for d in "$users/user-1001.slice" "$(mgr 1001)" "$(mgr 1001)/game.slice"; do want "$d/cpu.uclamp.min" 0.00 "stop job"; done
(( $(watches) == 1 )) || fail "$(watches) inotify watches after a stop job"
rm -rf "$users/user-1001.slice"
utree 1003
gslice 1003
snap=$(snapshot)
sdsend "job user@1003.service failed"
sleep 0.3
want "$(mgr 1003)/game.slice/cpu.uclamp.min" 0.00 "failed job"
set_ $P1 CpuGovernor s schedutil
floors 1003 68 "apply arms a tree without a watch"
(( $(watches) == 2 )) || fail "$(watches) inotify watches after the apply"
rm -rf "$users/user-1003.slice" "$users/user-1000.slice"
for _ in $(seq 100); do (( $(watches) == 0 )) && break; sleep 0.05; done
(( $(watches) == 0 )) || fail "$(watches) inotify watches after the tree went"
set_ $P1 CpuGovernor s schedutil
sleep 6
grep -q "missing after" "$tmp/log" && fail "a removed tree polled: $(grep "missing after" "$tmp/log")"
utree 1000
gslice 1000
snap=$(snapshot)
sdsend "job user@1000.service done"
floors 1000 68 "relogin"
(( $(watches) == 1 )) || fail "$(watches) inotify watches after relogin"
rm -rf "$(mgr 1000)/game.slice"
gslice 1000
floors 1000 68 "game.slice made after relogin"
n=$(grep -c "systemd Subscribe:" "$tmp/log" || true)
sdstop
sleep 0.5
(( $(grep -c "systemd Subscribe:" "$tmp/log" || true) == n )) || fail "Subscribe called when systemd left the bus"
sdstart
subscribed "systemd restarted"
utree 1002
gslice 1002
snap=$(snapshot)
sdsend "job user@1002.service done"
floors 1002 68 "JobRemoved after a systemd restart"
stop
sdstop

mktree
utree 1000
gslice 1000
sdstart
start
subscribed "systemd before powerd"
set_ $P1 GameCpuFloor u 68
floors 1000 68 "scan at start"
stop
sdstop

mktree
utree 1000
gslice 1000
gf=$(mgr 1000)/game.slice/cpu.uclamp.min
chown 1000 "$gf"
chmod 644 "$gf"
start setpriv --bounding-set -all,+dac_override --inh-caps -all
set_ $P1 GameCpuFloor u 68
floors 1000 68 "with CAP_DAC_OVERRIDE"
stop
for d in "$users" "$users/user-1000.slice" "$(mgr 1000)" "$(mgr 1000)/game.slice"; do echo 0.00 > "$d/cpu.uclamp.min"; done
start setpriv --bounding-set -all --inh-caps -all
set_ $P1 GameCpuFloor u 68
want "$gf" 0.00 "without CAP_DAC_OVERRIDE"
want "$users/cpu.uclamp.min" 68 "root owned level without CAP_DAC_OVERRIDE"
grep -q "^write $rusers/user-1000.slice/user@1000.service/game.slice/cpu.uclamp.min=68: Permission denied" "$tmp/log" ||
  fail "refused game.slice write not logged: $(tail -n 3 "$tmp/log")"
stop

if (( rc == 0 )); then
  echo "powerd: ok"
fi
exit "$rc"
