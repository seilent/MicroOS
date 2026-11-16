#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
policy=${1:-$here/../packages/steamos-manager/com.steampowered.SteamOSManager1.conf}
tmp=$(mktemp -d)
chmod 755 "$tmp"
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

for t in dbus-daemon python3 setpriv; do
  command -v "$t" > /dev/null || { echo "FAIL: $t missing" >&2; exit 1; }
done
python3 -c 'import gi' || { echo "FAIL: python3-gobject missing" >&2; exit 1; }
getent passwd 1000 > /dev/null || useradd -u 1000 -M micro

cat > "$tmp/bus.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <listen>unix:path=$tmp/bus</listen>
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
  </policy>
  <include>$policy</include>
</busconfig>
EOF
dbus-daemon --config-file="$tmp/bus.conf" --nofork --nopidfile > "$tmp/dbus.log" 2>&1 & pids+=($!)
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=$tmp/bus
for _ in {1..50}; do [[ -S $tmp/bus ]] && break; sleep 0.1; done
[[ -S $tmp/bus ]] || { echo "FAIL: dbus-daemon: $(cat "$tmp/dbus.log")" >&2; exit 1; }

python3 - "$tmp/ready" <<'EOF' & pids+=($!)
import sys
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

def owned(_conn, _name):
    open(sys.argv[1], "w").close()

bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
Gio.bus_own_name_on_connection(bus, "com.steampowered.SteamOSManager1", Gio.BusNameOwnerFlags.NONE, owned, None)
GLib.MainLoop().run()
EOF
for _ in {1..50}; do [[ -e $tmp/ready ]] && break; sleep 0.1; done
[[ -e $tmp/ready ]] || { echo "FAIL: the stub did not own com.steampowered.SteamOSManager1" >&2; exit 1; }

cat > "$tmp/client" <<'EOF'
import sys
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio

bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
for line in sys.stdin:
    path, iface, member = line.split()
    msg = Gio.DBusMessage.new_method_call("com.steampowered.SteamOSManager1", path, None if iface == "-" else iface, member)
    reply, _ = bus.send_message_with_reply_sync(msg, Gio.DBusSendMessageFlags.NONE, 2000, None)
    denied = reply.get_error_name() == "org.freedesktop.DBus.Error.AccessDenied"
    print(f"{iface}.{member} {'denied' if denied else 'reached'}")
EOF

M=/com/steampowered/SteamOSManager1
R=com.steampowered.SteamOSManager1.RootManager
J=com.steampowered.SteamOSManager1.Job1
allowed="$M org.freedesktop.DBus.Introspectable Introspect
$M org.freedesktop.DBus.Peer Ping
$M org.freedesktop.DBus.Properties Get
$M org.freedesktop.DBus.Properties GetAll
$M $R ReloadConfig
$M $R SetWifiBackend
$M $R SetWifiPowerManagementState
$M $R UpdateBios"
for m in Pause Resume Cancel Wait ExitCode; do allowed+=$'\n'"$M/Jobs/0 $J $m"; done
denied="$M org.freedesktop.DBus.Properties Set
$M - SetDefaultSession
$M com.steampowered.SteamOSManager1.Manager2 ReloadConfig"
for m in PrepareFactoryReset SetFanSpeed GetAlsIntegrationTimeFileDescriptor UpdateDock TrimDevices FormatDevice \
  SetGpuPowerProfile SetCpuScalingGovernor SetCpuBoostState SetGpuPerformanceLevel SetManualGpuClock SetTdpLimit \
  SetWifiDebugMode CaptureDebugTraceOutput GenerateDebugDump SetMaxChargeLevel SetPerformanceProfile \
  SetTemporarySession SetDefaultSession CleanTemporarySessions; do
  denied+=$'\n'"$M $R $m"
done

check() {
  local who=$1 want=$2 calls=$3 out
  shift 3
  out=$("$@" python3 "$tmp/client" <<< "$calls")
  while read -r call result; do
    [[ $result == "$want" ]] || fail "$who: $call $result, want $want"
  done <<< "$out"
  (( $(wc -l <<< "$out") == $(wc -l <<< "$calls") )) || fail "$who: $(wc -l <<< "$out") results for $(wc -l <<< "$calls") calls"
}
wheel=(setpriv --reuid 1000 --regid 1000 --groups 10)
check wheel reached "$allowed" "${wheel[@]}"
check wheel denied "$denied" "${wheel[@]}"
check root reached "$allowed"$'\n'"$denied" env
check "uid 1000 without wheel" denied "$allowed"$'\n'"$denied" setpriv --reuid 1000 --regid 1000 --clear-groups

if (( rc == 0 )); then
  echo "steamos-manager policy: ok"
fi
exit "$rc"
