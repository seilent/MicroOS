#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
audio=$tree/usr/libexec/microos/microos-audio
unit=$tree/usr/lib/systemd/user/microos-audio.service
tmp=$(mktemp -d)
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill -- "-$p" 2> /dev/null || kill "$p" 2> /dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

for t in dbus-daemon python3 gdbus setsid; do
  command -v "$t" > /dev/null || { echo "FAIL: $t missing" >&2; exit 1; }
done
[[ -x $audio ]] || fail "${audio#"$tree"} is not executable"
for l in 'After=wireplumber.service pipewire-pulse.service pipewire-pulse.socket' BindsTo=wireplumber.service 'WantedBy=default.target wireplumber.service' \
  ExecStart=/usr/libexec/microos/microos-audio; do
  grep -qxF "$l" "$unit" || fail "${unit##*/} lacks $l"
done
grep -qxF "enable microos-audio.service" "$tree/usr/lib/systemd/user-preset/60-microos-steam.preset" ||
  fail "microos-audio.service is not in the user preset"

cat > "$tmp/bus.conf" << EOF
<busconfig>
  <type>system</type>
  <listen>unix:path=$tmp/bus</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="*"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
EOF
dbus-daemon --config-file="$tmp/bus.conf" --nofork & pids+=($!)
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=$tmp/bus
for _ in {1..50}; do [[ -S $tmp/bus ]] && break; sleep 0.1; done

export STUB_DIR=$tmp/stub DAPM_MS=1500
mkdir -p "$STUB_DIR"
log=$STUB_DIR/log
set_log=$STUB_DIR/microset.log
spk=alsa_output.platform-sound.HiFi__Speaker__sink
hp=alsa_output.platform-sound.HiFi__Headphones__sink
usb=alsa_output.usb-Focusrite_Scarlett-00.analog-stereo
bt=bluez_output.00_1B_66_00_00_01.1
dp=alsa_output.platform-dp.HiFi__DP__sink

sys=$tmp/sys
mkdir -p "$sys/card0/device/MultiMedia1" "$sys/card0/device/WSA Playback" "$sys/card1/device/MultiMedia1"
echo PocketMICRO2 > "$sys/card0/id"
echo 1500 > "$sys/card0/device/MultiMedia1/pmdown_time"
echo 1200 > "$sys/card0/device/WSA Playback/pmdown_time"
echo Other > "$sys/card1/id"
echo 9000 > "$sys/card1/device/MultiMedia1/pmdown_time"

declare -A state=([$spk]=IDLE [$hp]=IDLE) avail=([$spk]=available [$hp]=available)
write_sinks() {
  local n sep=
  {
    printf '['
    for n in "${!state[@]}"; do
      printf '%s{"name":"%s","state":"%s","ports":[{"name":"p","availability":"%s"}],"active_port":"p","properties":{"priority.session":"%s"}}' \
        "$sep" "$n" "${state[$n]}" "${avail[$n]}" "$([[ $n == "$hp" ]] && echo 1100 || echo 1000)"
      sep=,
    done
    printf ']\n'
  } > "$STUB_DIR/sinks.json.new"
  mv "$STUB_DIR/sinks.json.new" "$STUB_DIR/sinks.json"
}
sinks_changed() { write_sinks; echo "Event 'change' on sink #$RANDOM" >> "$STUB_DIR/pactl.feed"; }
meta() {
  printf "update: id:0 key:'%s' value:'{ \"name\": \"%s\" }' type:'Spa:String:JSON'\n" "$1" "$2" >> "$STUB_DIR/meta.feed"
}
poke() {
  gdbus call --system -d net.seilent.MicroSet -o /net/seilent/MicroSet -m test.Stub.Poke "'$1'" "$2" > /dev/null
}
mark() { wc -l < "$log"; }
since() { tail -n "+$(($1 + 1))" "$log"; }
waitlog() {
  local from=$1 want=$2 n
  for n in {1..40}; do since "$from" | grep -qxF "$want" && return 0; sleep 0.1; done
  return 1
}
quiet() {
  sleep "${2:-1}"
  [[ -z $(since "$1") ]]
}
sets() { grep -c '^set ' "$set_log" || true; }

start_microsetd() {
  python3 "$here/audio-policy/microsetd" "$set_log" speaker & msd=$!
  pids+=("$msd")
  for _ in {1..50}; do grep -qx ready "$set_log" 2> /dev/null && return 0; sleep 0.1; done
  echo "FAIL: fake microsetd did not start" >&2
  exit 1
}
errline() {
  local want=$1 n
  for n in {1..60}; do grep -qF "$want" "$tmp/audio.err" && return 0; sleep 0.1; done
  return 1
}
now() { date +%s%N; }

write_sinks
: > "$log"
: > "$STUB_DIR/pactl.feed"
echo HiFi > "$STUB_DIR/profile"
meta default.configured.audio.sink "$hp"

PATH=$here/audio-policy:$PATH MICROOS_AUDIO_SYSFS=$sys MICROOS_AUDIO_SETTLE=2 \
  setsid python3 "$audio" 2>> "$tmp/audio.err" & as=$!
pids+=("$as")
sleep 0.5
meta default.configured.audio.sink "$dp"
quiet 0 2.5 || fail "acted without microsetd: $(cat "$log")"
start_microsetd
waitlog 0 "default $spk" || fail "no reconcile to the stored speaker once microsetd appeared: $(cat "$log")"
(($(sets) == 0)) || fail "a change in the settle time was stored: $(cat "$set_log")"

m=$(mark)
meta default.audio.sink "$hp"
quiet "$m" || fail "an effective default change acted: $(since "$m")"
(($(sets) == 0)) || fail "an effective default change was stored: $(cat "$set_log")"

m=$(mark)
meta default.configured.audio.sink "$hp"
for _ in {1..30}; do grep -qx "set audio.output headphones" "$set_log" && break; sleep 0.1; done
grep -qx "set audio.output headphones" "$set_log" || fail "a foreign headphones pick was not stored: $(cat "$set_log")"
quiet "$m" || fail "a stored foreign pick was rewritten: $(since "$m")"

m=$(mark)
meta default.configured.audio.sink "$dp"
for _ in {1..30}; do grep -qx "set audio.output auto" "$set_log" && break; sleep 0.1; done
grep -qx "set audio.output auto" "$set_log" || fail "an unclassed pick was not stored as auto: $(cat "$set_log")"
quiet "$m" || fail "an unclassed pick was not left as configured: $(since "$m")"

n=$(sets)
m=$(mark)
poke audio.output "<'speaker'>"
waitlog "$m" "default $spk" || fail "speaker: no configured default: $(since "$m")"
m=$(mark)
poke audio.output "<'auto'>"
waitlog "$m" remove || fail "auto did not remove the configured key: $(since "$m")"

m=$(mark)
poke audio.output "<'headphones'>"
waitlog "$m" "default $hp" || fail "headphones: no configured default: $(since "$m")"
m=$(mark)
avail[$hp]="not available"
sinks_changed
waitlog "$m" remove || fail "unplugged headphones kept the configured key: $(since "$m")"
m=$(mark)
avail[$hp]=available
sinks_changed
waitlog "$m" "default $hp" || fail "plugged headphones not set again: $(since "$m")"

m=$(mark)
avail[$spk]="not available"
write_sinks
poke audio.output "<'speaker'>"
waitlog "$m" remove || fail "speaker unavailable kept the headphones as configured: $(since "$m")"
m=$(mark)
avail[$spk]=available
sinks_changed
waitlog "$m" "default $spk" || fail "speaker not set once available: $(since "$m")"
m=$(mark)
avail[$spk]="not available"
sinks_changed
waitlog "$m" remove || fail "unavailable speaker kept the configured key: $(since "$m")"
avail[$spk]=available
write_sinks

for c in usb bt; do
  s=${!c}
  m=$(mark)
  poke audio.output "<'$c'>"
  quiet "$m" 0.5 || fail "$c without a sink acted: $(since "$m")"
  state[$s]=IDLE avail[$s]=available
  sinks_changed
  waitlog "$m" "default $s" || fail "$c: no configured default: $(since "$m")"
  m=$(mark)
  unset "state[$s]" "avail[$s]"
  sinks_changed
  waitlog "$m" remove || fail "$c gone kept the configured key: $(since "$m")"
done

m=$(mark)
: > "$STUB_DIR/list-fails"
poke audio.output "<'speaker'>"
waitlog "$m" "default $spk" || fail "speaker: no configured default after a failed sink list: $(since "$m")"
[[ ! -e $STUB_DIR/list-fails ]] || fail "the failing sink list was never called"
grep -qF "listing sinks failed" "$tmp/audio.err" || fail "a failed sink list was not logged"
m=$(mark)
echo off > "$STUB_DIR/profile"
unset "state[$spk]" "state[$hp]"
sinks_changed
quiet "$m" || fail "the card profile off changed the configured default: $(since "$m")"
echo HiFi > "$STUB_DIR/profile"
state[$spk]=IDLE state[$hp]=IDLE
sinks_changed
quiet "$m" || fail "the card back from off changed the configured default: $(since "$m")"
(($(sets) == n)) || fail "own writes or the suspend were stored as picks: $(cat "$set_log")"

m=$(mark)
: > "$STUB_DIR/no-echo"
poke audio.output "<'headphones'>"
waitlog "$m" "default $hp" || fail "headphones: no configured default without an echo: $(since "$m")"
rm "$STUB_DIR/no-echo"
sleep 2.5
meta default.configured.audio.sink "$hp"
for _ in {1..30}; do (($(sets) > n)) && break; sleep 0.1; done
(($(sets) == n + 1)) || fail "a pick after a lost echo was swallowed: $(cat "$set_log")"
poke audio.output "<'speaker'>"
waitlog "$m" "default $spk" || fail "speaker: no configured default after the lost echo: $(since "$m")"

hold_done() {
  local from=$1 sink=$2 t1 t2 hold
  t1=$(since "$from" | awk -v s="$sink" '$1 == "suspend" && $2 == s { t = $3 } END { print t }')
  errline "apply cycle: $sink closed for its pmdown_time" || { fail "no hold done line for $sink"; return; }
  t2=$(now)
  [[ $(cat "$STUB_DIR/dapm") == off ]] || fail "$sink hold done with the DAPM fixture on"
  hold=$(((t2 - t1) / 1000000))
  ((hold >= 2500 && hold < 3500)) || fail "$sink held $hold ms from its last suspend, pmdown_time is 1500 ms"
}
suspends() { since "$1" | awk -v s="$2" '$1 == "suspend" && $2 == s' | wc -l; }

sleep 1.5
m=$(mark)
: > "$STUB_DIR/lists"
state[$hp]=RUNNING
write_sinks
poke audio.hp_amp "<'hifi'>"
sleep 2
((($(suspends "$m" "$hp")) == 0)) || fail "the apply cycle suspended a running sink: $(since "$m")"
(($(wc -l < "$STUB_DIR/lists") <= 1)) || fail "sinks listed $(wc -l < "$STUB_DIR/lists") times in 2 s while a stream plays"
state[$hp]=IDLE
sinks_changed
for _ in {1..20}; do (($(suspends "$m" "$hp") == 1)) && break; sleep 0.1; done
(($(suspends "$m" "$hp") == 1)) || fail "no suspend once $hp went idle: $(since "$m")"
hold_done "$m" "$hp"
: > "$tmp/audio.err"

m=$(mark)
poke audio.speaker_gain "<uint32 108>"
for _ in {1..20}; do (($(suspends "$m" "$spk") == 1)) && break; sleep 0.1; done
(($(suspends "$m" "$spk") == 1)) || fail "no suspend of $spk: $(since "$m")"
sleep 0.5
rm -f "$STUB_DIR/susp/$spk"
echo $RANDOM > "$STUB_DIR/dapm.gen"
echo on > "$STUB_DIR/dapm"
state[$spk]=RUNNING
write_sinks
sleep 0.3
state[$spk]=IDLE
write_sinks
for _ in {1..40}; do (($(suspends "$m" "$spk") == 2)) && break; sleep 0.1; done
(($(suspends "$m" "$spk") == 2)) || fail "a short stream inside the hold did not restart the cycle: $(since "$m")"
grep -qF "apply cycle: $spk opened during the hold" "$tmp/audio.err" || fail "no log line for the stream inside the hold"
hold_done "$m" "$spk"
: > "$tmp/audio.err"

m=$(mark)
poke audio.speaker_gain "<uint32 84>"
for _ in {1..20}; do (($(suspends "$m" "$spk") == 1)) && break; sleep 0.1; done
rm -f "$STUB_DIR/susp/$spk"
echo $RANDOM > "$STUB_DIR/dapm.gen"
echo on > "$STUB_DIR/dapm"
state[$spk]=RUNNING
sinks_changed
for _ in {1..20}; do grep -qF "apply cycle: $spk opened during the hold" "$tmp/audio.err" && break; sleep 0.1; done
grep -qF "apply cycle: $spk opened during the hold" "$tmp/audio.err" || fail "a stream event inside the hold was missed"
state[$spk]=IDLE
sinks_changed
for _ in {1..20}; do (($(suspends "$m" "$spk") == 2)) && break; sleep 0.1; done
(($(suspends "$m" "$spk") == 2)) || fail "no suspend after the stream inside the hold ended: $(since "$m")"
hold_done "$m" "$spk"
: > "$tmp/audio.err"

m=$(mark)
state[$hp]=RUNNING
write_sinks
poke audio.hp_amp "<'ulp'>"
sleep 0.5
unset "state[$hp]" "avail[$hp]"
sinks_changed
errline "apply cycle: $hp is gone, dropped" || fail "a sink gone mid cycle was not dropped"
((($(suspends "$m" "$hp")) == 0)) || fail "a gone sink was suspended: $(since "$m")"
state[$hp]=IDLE avail[$hp]=available
write_sinks

: > "$STUB_DIR/get-fails"
kill "$msd"
wait "$msd" 2> /dev/null || true
start_microsetd
errline "reading audio.output failed" || fail "a failing Get was not logged"
kill -0 "$as" 2> /dev/null || fail "microos-audio died on a failing Get: $(cat "$tmp/audio.err")"

kill "$(cat "$STUB_DIR/subscribe.pid")"
for _ in {1..30}; do kill -0 "$as" 2> /dev/null || break; sleep 0.1; done
if kill -0 "$as" 2> /dev/null; then
  fail "microos-audio kept running without pactl subscribe"
else
  wait "$as" && arc=0 || arc=$?
  ((arc == 1)) || fail "microos-audio exited $arc after pactl subscribe exited"
  grep -qF "pactl exited" "$tmp/audio.err" || fail "no log line for the watcher exit"
fi

if ((rc != 0)); then
  cat "$tmp/audio.err" >&2
else
  echo "audio-policy: ok"
fi
exit $rc
