#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
audio=$tree/usr/libexec/microos/microos-audio
unit=$tree/usr/lib/systemd/user/microos-audio.service
equnit=$tree/usr/lib/systemd/user/microos-eq@.service
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
for l in ExecStart=/usr/bin/pipewire\ -c\ %t/microos-audio/eq/%i.conf Restart=on-failure PartOf=pipewire.service After=pipewire.service; do
  grep -qxF "$l" "$equnit" || fail "${equnit##*/} lacks $l"
done
grep -qE '^(BindsTo|Requires|PartOf)=.*microos-audio' "$equnit" && fail "${equnit##*/} is bound to microos-audio"
grep -qxF "enable microos-audio.service" "$tree/usr/lib/systemd/user-preset/60-microos-steam.preset" ||
  fail "microos-audio.service is not in the user preset"
wpdir=$tree/usr/lib/systemd/user/wireplumber.service.d/60-microos-config-dir.conf
wpdefaults=%E/wireplumber:/etc/xdg/wireplumber:/etc/wireplumber:/usr/local/share/wireplumber:/usr/share/wireplumber
[[ $(< "$wpdir") == $'[Service]\nEnvironment=WIREPLUMBER_CONFIG_DIR=%t/microos-audio/wireplumber:'"$wpdefaults" ]] ||
  fail "${wpdir##*/} is not the runtime dir followed by the default lookup: $(cat "$wpdir")"
wpenv=$(sed -n 's/^Environment=WIREPLUMBER_CONFIG_DIR=//p' "$wpdir")
[[ ${wpenv%%:*} == %t/microos-audio/wireplumber && ${wpenv#*:} == "$wpdefaults" ]] ||
  fail "WIREPLUMBER_CONFIG_DIR does not list the runtime dir first and every default dir after it: $wpenv"

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

declare -A state=([$spk]=IDLE [$hp]=IDLE) avail=([$spk]=available [$hp]=available) vol=() volr=() mute=() target=() oid=()
write_sinks() {
  local n props sep="" out=${1:-$STUB_DIR/sinks.json}
  {
    printf '['
    for n in "${!state[@]}"; do
      if [[ -n ${target[$n]:-} ]]; then
        props=$(printf '"object.id":"%s","filter.smart.target":"{ node.name = \\"%s\\" }"' "${oid[$n]}" "${target[$n]}")
      else
        props=$(printf '"priority.session":"%s"' "$([[ $n == "$hp" ]] && echo 1100 || echo 1000)")
      fi
      printf '%s{"name":"%s","state":"%s","description":"%s desc","mute":%s,"volume":{"front-left":{"value":%s},"front-right":{"value":%s}},"ports":[{"name":"p","availability":"%s"}],"active_port":"p","properties":{%s}}' \
        "$sep" "$n" "${state[$n]}" "$n" "${mute[$n]:-false}" "${vol[$n]:-65536}" "${volr[$n]:-${vol[$n]:-65536}}" "${avail[$n]:-available}" "$props"
      sep=,
    done
    printf ']\n'
  } > "$out.new"
  mv "$out.new" "$out"
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

readies() {
  local c
  c=$(grep -cx ready "$set_log" 2> /dev/null) || true
  echo "${c:-0}"
}
start_microsetd() {
  local ready
  ready=$(readies)
  python3 "$here/audio-policy/microsetd" "$set_log" speaker & msd=$!
  pids+=("$msd")
  for _ in {1..50}; do (($(readies) > ready)) && return 0; sleep 0.1; done
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

export XDG_RUNTIME_DIR=$tmp/xdg
eqdir=$XDG_RUNTIME_DIR/microos-audio/eq
mkdir -p "$XDG_RUNTIME_DIR"
PATH=$here/audio-policy:$PATH MICROOS_AUDIO_SYSFS=$sys MICROOS_AUDIO_SETTLE=2 MICROOS_AUDIO_CODEC_RETRY_MS=50 \
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

eqhash() { printf '%s\n%s\n%s' "$1" "$2" "${3:-off}" | sha256sum | cut -c1-12; }
count() { since "$1" | grep -cxF "$2" || true; }
params() {
  local out='{ params = [' preamp=$1 side n b
  shift
  for side in L R; do
    out+=" \"f${side}0:Gain\" $preamp"
    n=1
    for b in "$@"; do
      read -r f q g <<< "$b"
      out+=" \"f$side$n:Freq\" $f \"f$side$n:Q\" $q \"f$side$n:Gain\" $g"
      n=$((n + 1))
    done
  done
  echo "$out \"bL:Gain\" ${balance_l:-0.0} \"bR:Gain\" ${balance_r:-0.0} ] }"
}
m=$(mark)
poke audio.eq.headphones.filters "<['preamp -3', 'peak 1000 6 1']>"
quiet "$m" 0.5 || fail "EQ filters with the slot off acted: $(since "$m")"
poke audio.eq.headphones.on "<true>"
h1=$(eqhash "$hp" peak)
i1=headphones-$h1 n1=microos-eq.headphones.$h1
waitlog "$m" "start microos-eq@$i1.service" || fail "EQ on: no chain unit for $hp: $(since "$m")"
conf=$eqdir/$i1.conf
for want in "node.name = \"$n1\"" "node.name = \"$n1.out\"" "filter.smart.name = \"$n1\"" \
  "filter.smart.target = { node.name = \"$hp\" }" "target.object = \"$hp\"" "node.description = \"$hp desc EQ\"" \
  "media.class = Audio/Sink" "filter.smart = true" "filter.smart.targetable = false" "state.restore-props = false" \
  "node.dont-fallback = true" "node.passive = true" "node.linger = true" "name = libpipewire-module-filter-chain" \
  '{ type = builtin name = fL0 label = bq_highshelf control = { "Freq" = 0.0 "Q" = 1.0 "Gain" = -3.0 } }' \
  '{ type = builtin name = fL1 label = bq_peaking control = { "Freq" = 1000.0 "Q" = 1.0 "Gain" = 6.0 } }' \
  '{ type = builtin name = fR0 label = bq_highshelf control = { "Freq" = 0.0 "Q" = 1.0 "Gain" = -3.0 } }' \
  '{ type = builtin name = fR1 label = bq_peaking control = { "Freq" = 1000.0 "Q" = 1.0 "Gain" = 6.0 } }' \
  '{ type = builtin name = bL label = bq_highshelf control = { "Freq" = 0.0 "Q" = 1.0 "Gain" = 0.0 } }' \
  '{ type = builtin name = bR label = bq_highshelf control = { "Freq" = 0.0 "Q" = 1.0 "Gain" = 0.0 } }' \
  '{ output = "fL0:Out" input = "fL1:In" }' '{ output = "fR0:Out" input = "fR1:In" }' \
  '{ output = "fL1:Out" input = "bL:In" }' '{ output = "fR1:Out" input = "bR:In" }' \
  'inputs = [ "fL0:In" "fR0:In" ]' 'outputs = [ "bL:Out" "bR:Out" ]'; do
  grep -qF -- "$want" "$conf" 2> /dev/null || fail "$i1.conf lacks $want"
done
(($(wc -l < "$conf") > 40)) || fail "$i1.conf is not written with newlines"
[[ $(stat -c %a "$eqdir") == 700 ]] || fail "EQ conf dir mode $(stat -c %a "$eqdir")"
since "$m" | grep -q "microos-eq@speaker" && fail "the speaker slot is off and got a chain"

m=$(mark)
state[$n1]=IDLE target[$n1]=$hp oid[$n1]=70
sinks_changed
sleep 1
sinks_changed
sleep 1
since "$m" | grep -q "^props $n1 " && fail "values sent to a chain that loaded them from its conf: $(since "$m")"

m=$(mark)
poke audio.eq.headphones.filters "<['preamp -3', 'peak 2000 4 2']>"
p=$(params -3.0 "2000.0 2.0 4.0")
waitlog "$m" "props $n1 $p" || fail "a band edit was not sent live: $(since "$m")"
grep -qF '"Freq" = 2000.0 "Q" = 2.0 "Gain" = 4.0' "$conf" || fail "a live edit did not reach $i1.conf"
since "$m" | grep -qE '^(start|stop) ' && fail "a band edit restarted a chain: $(since "$m")"

m=$(mark)
poke audio.eq.headphones.filters "<['preamp -3', 'lowshelf 100 3 0.7']>"
h2=$(eqhash "$hp" lowshelf)
i2=headphones-$h2 n2=microos-eq.headphones.$h2
waitlog "$m" "start microos-eq@$i2.service" || fail "a type change did not start a new chain: $(since "$m")"
sleep 0.5
poke audio.eq.headphones.filters "<['preamp -2', 'lowshelf 200 5 0.7']>"
sleep 1
since "$m" | grep -qxF "stop microos-eq@$i1.service" && fail "the old chain stopped before the new one was up"
since "$m" | grep -q "^props $n2 " && fail "values sent to a chain that is not up: $(since "$m")"
grep -qF '"Freq" = 200.0 "Q" = 0.7 "Gain" = 5.0' "$eqdir/$i2.conf" || fail "an edit during the rebuild missed $i2.conf"
state[$n2]=IDLE target[$n2]=$hp oid[$n2]=71
sinks_changed
p=$(params -2.0 "200.0 0.7 5.0")
waitlog "$m" "props $n2 $p" || fail "the newest edit was not applied once the new chain was up: $(since "$m")"
waitlog "$m" "stop microos-eq@$i1.service" || fail "the old chain was not stopped: $(since "$m")"
(($(since "$m" | grep -c "^props $n2 ") == 1)) || fail "the rebuild sent more than one set of values: $(since "$m")"
[[ ! -e $conf ]] || fail "$i1.conf left after its chain stopped"
unset "state[$n1]" "target[$n1]" "oid[$n1]"
sinks_changed

m=$(mark)
oid[$n2]=72
sinks_changed
sleep 1
since "$m" | grep -q "^props $n2 " && fail "values sent to a restarted chain that loads its conf: $(since "$m")"
since "$m" | grep -q '^volume ' && fail "a chain restart changed a volume: $(since "$m")"

m=$(mark)
vol[$hp]=39321 vol[$n2]=32768
sinks_changed
waitlog "$m" "volume $n2 65536" || fail "a chain below 100 % was not set back: $(since "$m")"
[[ $(since "$m" | grep '^volume ') == "volume $hp 19660 19660"$'\n'"volume $n2 65536" ]] ||
  fail "chain volume not folded into the hardware first: $(since "$m")"
vol[$hp]=19660 vol[$n2]=65536
write_sinks
m=$(mark)
vol[$n2]=70000
sinks_changed
waitlog "$m" "volume $n2 65536" || fail "a chain above 100 % was not set back: $(since "$m")"
since "$m" | grep -q "^volume $hp " && fail "a chain above 100 % changed the hardware: $(since "$m")"
vol[$n2]=65536
write_sinks
m=$(mark)
mute[$n2]=true
sinks_changed
waitlog "$m" "mute $n2 0" || fail "a muted chain was not unmuted: $(since "$m")"
[[ $(since "$m" | grep '^mute ') == "mute $hp 1"$'\n'"mute $n2 0" ]] || fail "chain mute not moved to the hardware first: $(since "$m")"
mute[$n2]=false
write_sinks

m=$(mark)
vol[$hp]=20000 vol[$n2]=32768
write_sinks "$STUB_DIR/sinks.after"
vol[$hp]=39321
sinks_changed
waitlog "$m" "volume $n2 65536" || fail "fold with a fresh hardware read: chain not set back: $(since "$m")"
[[ $(since "$m" | grep "^volume $hp ") == "volume $hp 10000 10000" ]] ||
  fail "fold did not use the lower of the fresh and the listed hardware volume: $(since "$m")"
vol[$hp]=10000 vol[$n2]=65536
write_sinks
m=$(mark)
: > "$tmp/audio.err"
vol[$hp]=40000 vol[$n2]=32768
: > "$STUB_DIR/chainvol-fails"
sinks_changed
errline "folding the volume of $n2 failed" || fail "a failed chain reset was not logged"
waitlog "$m" "volume $n2 65536" || fail "a failed chain reset was not retried: $(since "$m")"
[[ $(since "$m" | grep -c "^volume $hp ") == 1 ]] || fail "a retried fold lowered the hardware twice: $(since "$m")"
vol[$hp]=20000 vol[$n2]=65536
write_sinks
nb=microos-eq.speaker.000000000bad
m=$(mark)
: > "$tmp/audio.err"
state[$nb]=IDLE target[$nb]='a\\q' oid[$nb]=80 vol[$nb]=32768 vol[$n2]=32768
sinks_changed
waitlog "$m" "volume $n2 65536" || fail "a chain with an unreadable target stopped the fold of another chain: $(since "$m")"
vol[$hp]=10000 vol[$n2]=65536
sinks_changed
sleep 0.5
sinks_changed
sleep 0.5
(($(grep -c "$nb is not at 100 %" "$tmp/audio.err") == 1)) || fail "an unfoldable chain was not logged once: $(cat "$tmp/audio.err")"
since "$m" | grep -q "^volume $nb" && fail "a chain with an unreadable target was changed"
unset "state[$nb]" "target[$nb]" "oid[$nb]" "vol[$nb]"
sinks_changed

n=$(sets)
m=$(mark)
meta default.configured.audio.sink "$n2"
waitlog "$m" "default $hp" || fail "a picked chain was not mapped to its hardware sink: $(since "$m")"
grep -qx "set audio.output headphones" <(tail -n "+$((n + 1))" <(grep '^set ' "$set_log")) ||
  fail "a picked chain was not stored as its slot: $(cat "$set_log")"

m=$(mark)
avail[$hp]="not available"
sinks_changed
waitlog "$m" "stop microos-eq@$i2.service" || fail "a chain outlived its route: $(since "$m")"
[[ ! -e $eqdir/$i2.conf ]] || fail "$i2.conf left after its route went"
unset "state[$n2]"
avail[$hp]=available
sinks_changed
waitlog "$m" "start microos-eq@$i2.service" || fail "the chain did not come back with its route: $(since "$m")"
m=$(mark)
state[$n2]=IDLE oid[$n2]=73
sinks_changed
sleep 1
since "$m" | grep -q "^props $n2 " && fail "values sent to a fresh chain: $(since "$m")"
grep -qF '"Freq" = 200.0 "Q" = 0.7 "Gain" = 5.0' "$eqdir/$i2.conf" || fail "the chain back with its route has no current conf"

m=$(mark)
state[$bt]=IDLE avail[$bt]=available
sinks_changed
sleep 1
since "$m" | grep -q "microos-eq@bt" && fail "the bt slot is off by default and got a chain: $(since "$m")"
poke audio.eq.bt.on "<true>"
hb=$(eqhash "$bt" "")
waitlog "$m" "start microos-eq@bt-$hb.service" || fail "bt EQ on: no chain: $(since "$m")"
grep -qF '"Gain" = 0.0 } }' "$eqdir/bt-$hb.conf" || fail "the default bt profile is not a preamp only chain"
since "$m" | grep -q "start microos-eq@headphones" && fail "turning on bt touched the headphones chain"
m=$(mark)
unset "state[$bt]" "avail[$bt]"
sinks_changed
waitlog "$m" "stop microos-eq@bt-$hb.service" || fail "a bt chain outlived its sink: $(since "$m")"
poke audio.eq.bt.on "<false>"

m=$(mark)
poke audio.eq.headphones.filters "<['peak 1000 6 1']>"
errline "audio.eq.headphones.filters" || fail "invalid filters were not logged"
waitlog "$m" "stop microos-eq@$i2.service" || fail "invalid filters kept the chain: $(since "$m")"
poke audio.eq.headphones.filters "<['preamp -2', 'lowshelf 200 5 0.7']>"
waitlog "$m" "start microos-eq@$i2.service" || fail "valid filters again: no chain: $(since "$m")"
m=$(mark)
poke audio.eq.headphones.on "<false>"
waitlog "$m" "stop microos-eq@$i2.service" || fail "EQ off kept the chain: $(since "$m")"
unset "state[$n2]" "target[$n2]" "oid[$n2]"
sinks_changed
grep -q "^default microos-eq" "$log" && fail "a chain was set as the default sink"

m=$(mark)
: > "$tmp/audio.err"
poke audio.eq.speaker.on "<true>"
hs=$(eqhash "$spk" "")
waitlog "$m" "start microos-eq@speaker-$hs.service" || fail "speaker EQ on: no chain: $(since "$m")"
for _ in {1..200}; do (($(count "$m" "start microos-eq@speaker-$hs.service") >= 2)) && break; sleep 0.1; done
(($(count "$m" "start microos-eq@speaker-$hs.service") == 2)) || fail "a chain with no node was not started again: $(since "$m")"
grep -qF "EQ chain speaker-$hs has no node after 10 refreshes" "$tmp/audio.err" || fail "no log line for the chain with no node"
(($(count "$m" "reset microos-eq@speaker-$hs.service") == 2)) || fail "start did not reset the failed state: $(since "$m")"
m=$(mark)
poke audio.eq.speaker.on "<false>"
waitlog "$m" "stop microos-eq@speaker-$hs.service" || fail "speaker EQ off kept the chain: $(since "$m")"

card() {
  printf ',{"name":"%s","index":%s,"properties":{"object.serial":"%s"},"active_profile":"%s","profiles":{%s}}' \
    "$1" "$2" "$2" "${4:-a2dp-sink-sbc}" "$3"
}
prof() { printf '"%s":{"description":"High Fidelity Playback (A2DP Sink, codec %s)","available":%s}' "$1" "$2" "${3:-true}"; }
cardA=bluez_card.00_1B_66_00_00_01 cardB=bluez_card.00_1B_66_00_00_02
cards() { echo "$*" > "$STUB_DIR/cards.json"; echo "Event '${EVENT:-new}' on card #$RANDOM" >> "$STUB_DIR/pactl.feed"; }
a_profiles="$(prof a2dp-sink "aptX HD"),$(prof a2dp-sink-aptx aptX),$(prof a2dp-sink-sbc SBC),$(prof a2dp-sink-ldac LDAC false)"
m=$(mark)
cards "$(card $cardA 80 "$a_profiles")"
sleep 1
since "$m" | grep -q '^profile ' && fail "audio.bt_codec_headphones auto changed a profile: $(since "$m")"
poke audio.bt_codec_headphones "<'aptx'>"
waitlog "$m" "profile $cardA a2dp-sink-aptx" || fail "aptx not applied: $(since "$m")"
(($(since "$m" | grep -c '^profile ') == 1)) || fail "aptx applied more than once: $(since "$m")"
m=$(mark)
poke audio.bt_codec_headphones "<'ldac'>"
errline "audio.bt_codec_headphones ldac: $cardA offers no profile for it" || fail "an unavailable codec was not logged"
EVENT=change cards "$(card $cardA 80 "$a_profiles")"
sleep 1
(($(grep -c "audio.bt_codec_headphones ldac: $cardA offers no profile" "$tmp/audio.err") == 1)) || fail "a missing codec was logged more than once"
since "$m" | grep -q '^profile ' && fail "a missing codec changed the profile: $(since "$m")"
m=$(mark)
EVENT=change cards "$(card $cardA 80 "${a_profiles/\"available\":false/\"available\":true}")"
waitlog "$m" "profile $cardA a2dp-sink-ldac" || fail "a codec profile that became available was not applied: $(since "$m")"
m=$(mark)
poke audio.bt_codec_headphones "<'aac'>"
cards "$(card $cardA 81 "$a_profiles")$(card $cardB 82 "$(prof a2dp-sink AAC),$(prof a2dp-sink-sbc SBC)")"
waitlog "$m" "profile $cardB a2dp-sink" || fail "aac by the bare a2dp-sink description not applied: $(since "$m")"
since "$m" | grep -q "^profile $cardA" && fail "a card without aac got a profile: $(since "$m")"
m=$(mark)
state[$bt]=RUNNING avail[$bt]=available
write_sinks
EVENT=change cards "$(card $cardA 81 "$a_profiles")$(card $cardB 82 "$(prof a2dp-sink AAC),$(prof a2dp-sink-sbc SBC)" a2dp-sink)"
poke audio.bt_codec_headphones "<'sbc'>"
waitlog "$m" "profile $cardA a2dp-sink-sbc" && fail "a card already on sbc was switched again"
waitlog "$m" "profile $cardB a2dp-sink-sbc" || fail "a codec change with a stream playing not applied: $(since "$m")"
m=$(mark)
poke audio.bt_codec_headphones "<'aptx'>"
waitlog "$m" "profile $cardA a2dp-sink-aptx" || fail "aptx not applied again: $(since "$m")"
m=$(mark)
cards "$(card $cardA 83 "$a_profiles")$(card $cardB 82 "$(prof a2dp-sink AAC),$(prof a2dp-sink-sbc SBC)" a2dp-sink)"
waitlog "$m" "profile $cardA a2dp-sink-aptx" || fail "a reconnected card did not get the codec again: $(since "$m")"
sleep 0.5
(($(since "$m" | grep -c '^profile ') == 1)) || fail "a card that stayed got the codec again: $(since "$m")"
grep -qi wireplumber "$tmp/audio.err" && fail "a codec change touched wireplumber: $(grep -i wireplumber "$tmp/audio.err")"
m=$(mark)
poke audio.bt_codec_headphones "<'auto'>"
sleep 0.5
poke audio.bt_codec_headphones "<'aptx'>"
waitlog "$m" "profile $cardA a2dp-sink-aptx" || fail "aptx after auto was not applied again: $(since "$m")"
m=$(mark)
phone=bluez_card.BB_BB_BB_BB_BB_01 duplex=bluez_card.CC_CC_CC_CC_CC_01
gw='"audio-gateway":{"description":"Audio Gateway (A2DP Source & HSP/HFP AG)","available":true}'
dprof='"a2dp-duplex-aptx":{"description":"High Fidelity Duplex (A2DP Source/Sink, codec aptX)","available":true}'
dprof+=',"a2dp-duplex-sbc":{"description":"High Fidelity Duplex (A2DP Source/Sink, codec SBC)","available":true}'
cards "$(card $cardA 84 "$a_profiles" a2dp-sink-aptx)$(card $phone 85 "$gw" audio-gateway)$(card $duplex 86 "$dprof,$gw" audio-gateway)"
sleep 1
since "$m" | grep -q "^profile $duplex" && fail "a duplex card on audio-gateway was taken off it: $(since "$m")"
since "$m" | grep -q "^profile $phone" && fail "a phone card got the headphones codec: $(since "$m")"
m=$(mark)
poke audio.bt_codec "<'ldac'>"
errline "audio.bt_codec ldac: $phone streams from a phone, the phone picks the codec, left as is" \
  || fail "a receiver codec on a phone card was not logged"
sleep 0.5
since "$m" | grep -q '^profile ' && fail "audio.bt_codec changed a profile: $(since "$m")"
m=$(mark)
EVENT=change cards "$(card $cardA 84 "$a_profiles" a2dp-sink-aptx)$(card $phone 85 "$gw" audio-gateway)$(card $duplex 86 "$dprof,$gw" a2dp-duplex-sbc)"
waitlog "$m" "profile $duplex a2dp-duplex-aptx" || fail "a duplex card sending on a2dp did not take the headphones codec: $(since "$m")"
sleep 0.5
(($(since "$m" | grep -c '^profile ') == 1)) || fail "a card change into a2dp switched more than the duplex card: $(since "$m")"
(($(grep -c "audio.bt_codec ldac: $phone streams from a phone" "$tmp/audio.err") == 1)) || fail "the phone line was logged more than once"
m=$(mark)
poke audio.bt_codec_headphones "<'auto'>"
poke audio.bt_codec "<'auto'>"
EVENT=change cards "$(card $cardA 84 "$a_profiles" a2dp-sink-sbc)$(card $phone 85 "$gw" audio-gateway)"
sleep 1
since "$m" | grep -q '^profile ' && fail "auto on both keys changed a profile: $(since "$m")"
m=$(mark)
poke audio.bt_codec_headphones "<'aptx_hd'>"
waitlog "$m" "profile $cardA a2dp-sink" || fail "aptx_hd by the bare a2dp-sink description not applied: $(since "$m")"
m=$(mark)
: > "$STUB_DIR/profile-fails"
poke audio.bt_codec_headphones "<'aptx'>"
errline "setting $cardA profile a2dp-sink-aptx failed" || fail "a failed profile set was not logged"
waitlog "$m" "profile $cardA a2dp-sink-aptx" || fail "a failed profile set was not retried: $(since "$m")"
m=$(mark)
: > "$STUB_DIR/profile-fails-always"
poke audio.bt_codec_headphones "<'aptx_hd'>"
sleep 3
tries=$(grep -c . "$STUB_DIR/profile-tries")
((tries == 6)) || fail "a profile set that always fails was tried $tries times, not 6"
poke audio.bt_codec_headphones "<'aptx_hd'>"
sleep 1
(($(grep -c . "$STUB_DIR/profile-tries") == tries)) || fail "a profile set kept retrying after the last try"
(($(grep -cF "setting $cardA profile a2dp-sink failed" "$tmp/audio.err") == 1)) \
  || fail "a failing profile set was logged more than once"
EVENT=change cards "$(card $cardA 84 "$a_profiles" a2dp-sink-sbc)$(card $phone 85 "$gw" audio-gateway)"
sleep 1
(($(grep -c . "$STUB_DIR/profile-tries") == tries)) || fail "a card change with the same profiles retried a failed set"
poke audio.bt_codec_headphones "<'ldac'>"
sleep 0.5
poke audio.bt_codec_headphones "<'aptx_hd'>"
sleep 0.5
(($(grep -c . "$STUB_DIR/profile-tries") > tries)) || fail "a codec with no profile kept the old failure"
sleep 3
rm "$STUB_DIR/profile-fails-always"
m=$(mark)
EVENT=change cards "$(card $cardA 84 "$a_profiles" a2dp-sink-aptx)$(card $phone 85 "$gw" audio-gateway)"
waitlog "$m" "profile $cardA a2dp-sink" || fail "a card change to another profile did not retry a failed set: $(since "$m")"
unset "state[$bt]" "avail[$bt]"
rm "$STUB_DIR/cards.json"
sinks_changed

: > "$STUB_DIR/get-fails"
kill "$msd"
wait "$msd" 2> /dev/null || true
start_microsetd
errline "reading the audio keys failed" || fail "a failing List was not logged"
kill -0 "$as" 2> /dev/null || fail "microos-audio died on a failing List: $(cat "$tmp/audio.err")"

kill "$(cat "$STUB_DIR/subscribe.pid")"
for _ in {1..30}; do kill -0 "$as" 2> /dev/null || break; sleep 0.1; done
if kill -0 "$as" 2> /dev/null; then
  fail "microos-audio kept running without pactl subscribe"
else
  wait "$as" && arc=0 || arc=$?
  ((arc == 1)) || fail "microos-audio exited $arc after pactl subscribe exited"
  grep -qF "pactl exited" "$tmp/audio.err" || fail "no log line for the watcher exit"
fi

rm "$STUB_DIR/get-fails"
kill "$msd"
wait "$msd" 2> /dev/null || true
start_microsetd
poke audio.output "<'headphones'>"
poke audio.eq.headphones.on "<true>"
poke audio.eq.headphones.filters "<['preamp -1', 'highshelf 8000 -5 0.7']>"
ha=$(eqhash "$hp" highshelf)
ia=headphones-$ha na=microos-eq.headphones.$ha
stray=speaker-000000000000
rm -rf "$STUB_DIR/units"
mkdir -p "$STUB_DIR/units" "$eqdir"
echo active > "$STUB_DIR/units/microos-eq@$ia.service"
echo active > "$STUB_DIR/units/microos-eq@$stray.service"
echo inactive > "$STUB_DIR/units/microos-eq@usb-111111111111.service"
: > "$eqdir/$stray.conf"
state[$na]=IDLE target[$na]=$hp oid[$na]=90
write_sinks
dump() {
  printf '[{"id":7,"type":"PipeWire:Interface:Node","info":{"state":"running","props":{"node.name":"%s.out"},"params":{"Format":%s}}},{"id":8,"type":"PipeWire:Interface:Node","info":{"state":"running","props":{"node.name":"%s"},"params":{}}},{"id":9,"type":"PipeWire:Interface:Link","info":{"output-node-id":7,"input-node-id":8,"state":"active"}}]\n' \
    "$na" "$1" "$hp" > "$STUB_DIR/dump.json"
}
dump '[]'
n=$(sets)
m=$(mark)
: > "$tmp/audio.err"
PATH=$here/audio-policy:$PATH MICROOS_AUDIO_SYSFS=$sys MICROOS_AUDIO_SETTLE=2 \
  setsid python3 "$audio" 2>> "$tmp/audio.err" & as=$!
pids+=("$as")
sleep 0.5
meta default.configured.audio.sink "microos-eq.speaker.000000000000"
errline "running EQ chains: $ia $stray" || fail "running chains not listed at start: $(cat "$tmp/audio.err")"
waitlog "$m" "stop microos-eq@$stray.service" || fail "a chain that is not wanted was not stopped at start: $(since "$m")"
waitlog "$m" "props $na $(params -1.0 "8000.0 0.7 -5.0")" || fail "the adopted chain did not get the current values: $(since "$m")"
waitlog "$m" "default $spk" || fail "a saved chain default was not mapped to the hardware sink: $(since "$m")"
since "$m" | grep -qxF "start microos-eq@$ia.service" && fail "a running chain was started again"
since "$m" | grep -q "microos-eq@usb-111111111111" && fail "an inactive unit was touched"
[[ ! -e $eqdir/$stray.conf ]] || fail "the stray chain conf was left"
errline "EQ chain $ia output has no format, suspending its sink" || fail "no log line for the output suspend"
waitlog "$m" "resume $na" || fail "an adopted chain whose output has no format was not suspended and resumed: $(since "$m")"
for _ in {1..250}; do grep -qF "EQ chain $ia output has no format after 3 suspends, left as is" "$tmp/audio.err" && break; sleep 0.1; done
grep -qF "EQ chain $ia output has no format after 3 suspends, left as is" "$tmp/audio.err" || fail "the output suspends did not give up"
sleep 1.5
(($(suspends "$m" "$na") == 3 && $(since "$m" | grep -cxF "resume $na") == 3)) ||
  fail "the output suspends are not bounded to 3: $(since "$m")"
grep -qx "set audio.output speaker" <(tail -n "+$((n + 1))" <(grep '^set ' "$set_log")) ||
  fail "a saved chain default was not stored as its slot: $(cat "$set_log")"
kill "$as"
wait "$as" 2> /dev/null || true
dump '[{"mediaType":"audio"}]'
m=$(mark)
: > "$tmp/audio.err"
PATH=$here/audio-policy:$PATH MICROOS_AUDIO_SYSFS=$sys MICROOS_AUDIO_SETTLE=2 \
  setsid python3 "$audio" 2>> "$tmp/audio.err" & as=$!
pids+=("$as")
errline "running EQ chains: $ia" || fail "the chain was not listed at the second start: $(cat "$tmp/audio.err")"
sleep 1.5
since "$m" | grep -q "^props $na " && fail "values sent to an adopted chain whose conf already holds them: $(since "$m")"
since "$m" | grep -qE "^(start|stop) microos-eq@$ia" && fail "the adopted chain was restarted: $(since "$m")"
since "$m" | grep -q "^suspend $na" && fail "an adopted chain whose output has a format was suspended: $(since "$m")"

kill "$as"
wait "$as" 2> /dev/null || true
unset "state[$na]" "target[$na]" "oid[$na]"
vol[$hp]=65536 vol[$spk]=65536
write_sinks
echo boot-a > "$tmp/boot_id"
echo "$hp" > "$STUB_DIR/default-sink"
marker=$XDG_RUNTIME_DIR/microos-audio/power-on
poke audio.eq.headphones.on "<false>"
poke audio.max_volume "<uint32 60>"
poke audio.power_on_volume "<uint32 80>"
cap60=$((65536 * 60 / 100)) cap50=$((65536 * 50 / 100))
novol() { sleep 1; ! since "$1" | grep -q "^volume "; }
poweron() {
  for _ in {1..40}; do since "$1" | grep -qxF "$2" && break; sleep 0.1; done
  (($(since "$1" | grep -cxF "$2") == 1))
}
start_audio_boot() {
  PATH=$here/audio-policy:$PATH MICROOS_AUDIO_SYSFS=$sys MICROOS_AUDIO_SETTLE=2 MICROOS_AUDIO_BOOT_ID=$tmp/boot_id \
    setsid python3 "$audio" 2>> "$tmp/audio.err" & as=$!
  pids+=("$as")
}
m=$(mark)
start_audio_boot
waitlog "$m" "volume $hp $cap60 $cap60" || fail "max volume: $hp above the cap at start was not folded: $(since "$m")"
waitlog "$m" "volume $spk $cap60 $cap60" || fail "max volume: $spk above the cap at start was not folded: $(since "$m")"
vol[$hp]=$cap60 vol[$spk]=$cap60
sinks_changed
poweron "$m" "volume $hp $cap60" || fail "power on volume 80 was not applied once at the cap 60: $(since "$m")"
[[ $(cat "$marker") == boot-a$'\n'"$hp" ]] || fail "no power on marker for boot-a naming $hp: $(cat "$marker")"
m=$(mark)
vol[$hp]=$((65536 * 80 / 100))
sinks_changed
waitlog "$m" "volume $hp $cap60 $cap60" || fail "max volume: a raise to 80 % was not folded to 60 %: $(since "$m")"
vol[$hp]=$cap60
write_sinks
m=$(mark)
poke audio.max_volume "<uint32 50>"
waitlog "$m" "volume $hp $cap50 $cap50" || fail "max volume: a cap lowered to 50 % did not lower $hp: $(since "$m")"
waitlog "$m" "volume $spk $cap50 $cap50" || fail "max volume: a cap lowered to 50 % did not lower $spk: $(since "$m")"
vol[$hp]=$cap50 vol[$spk]=$cap50
sinks_changed
m=$(mark)
vol[$hp]=$((65536 * 30 / 100))
sinks_changed
novol "$m" || fail "max volume: a level under the cap was changed: $(since "$m")"
vol[$hp]=$cap50
write_sinks
kill "$as"
wait "$as" 2> /dev/null || true
m=$(mark)
start_audio_boot
sleep 3
sinks_changed
novol "$m" || fail "a microos-audio restart in the same boot wrote a volume: $(since "$m")"
kill "$as"
wait "$as" 2> /dev/null || true
echo boot-b > "$tmp/boot_id"
m=$(mark)
start_audio_boot
poweron "$m" "volume $hp $cap50" || fail "power on volume on a new boot was not applied at the cap 50: $(since "$m")"
kill "$as"
wait "$as" 2> /dev/null || true
poke audio.power_on_volume "<uint32 0>"
echo boot-c > "$tmp/boot_id"
m=$(mark)
start_audio_boot
sleep 3
sinks_changed
novol "$m" || fail "power on volume LAST wrote a volume: $(since "$m")"
[[ $(cat "$marker") == boot-c ]] || fail "power on LAST did not mark boot-c"

kill "$as"
wait "$as" 2> /dev/null || true
poke audio.power_on_volume "<uint32 40>"
cap40=$((65536 * 40 / 100))
echo auto_null > "$STUB_DIR/default-sink"
echo boot-d > "$tmp/boot_id"
m=$(mark)
start_audio_boot
errline "audio.power_on_volume 40: default sink auto_null is not a listed output, waiting" ||
  fail "power on volume did not wait for a hardware default"
novol "$m" || fail "power on volume was set with no hardware default: $(since "$m")"
[[ $(cat "$marker") == boot-c ]] || fail "power on volume marked boot-d with no hardware default"
echo "$hp" > "$STUB_DIR/default-sink"
sinks_changed
poweron "$m" "volume $hp $cap40" || fail "power on volume was not applied once the default was $hp: $(since "$m")"
[[ $(cat "$marker") == boot-d$'\n'"$hp" ]] || fail "no power on marker for boot-d naming $hp: $(cat "$marker")"
kill "$as"
wait "$as" 2> /dev/null || true
vol[$hp]=$cap50
state[$na]=IDLE target[$na]=$hp oid[$na]=91
write_sinks
echo "$na" > "$STUB_DIR/default-sink"
echo boot-e > "$tmp/boot_id"
m=$(mark)
start_audio_boot
poweron "$m" "volume $hp $cap40" || fail "a chain default did not set the power on volume on its hardware sink: $(since "$m")"
since "$m" | grep -q "^volume $na " && fail "power on volume was written to the chain sink: $(since "$m")"
[[ $(cat "$marker") == boot-e$'\n'"$hp" ]] || fail "the power on marker for a chain default does not name $hp: $(cat "$marker")"
kill "$as"
wait "$as" 2> /dev/null || true
unset "state[$na]" "target[$na]" "oid[$na]"
vol[$hp]=$cap50
write_sinks
echo "$hp" > "$STUB_DIR/default-sink"
rm -f "$marker"
mkdir "$marker"
echo boot-f > "$tmp/boot_id"
m=$(mark)
start_audio_boot
poweron "$m" "volume $hp $cap40" || fail "power on volume was not applied on boot-f: $(since "$m")"
errline "writing the power on marker failed" || fail "a failed marker write was not logged"
vol[$hp]=$((65536 * 20 / 100))
sinks_changed
sleep 1
sinks_changed
sleep 1
(($(since "$m" | grep -cxF "volume $hp $cap40") == 1)) || fail "a failed marker write reapplied the power on volume: $(since "$m")"
rmdir "$marker"

m=$(mark)
poke audio.max_volume "<uint32 60>"
vol[$hp]=$((65536 * 80 / 100)) volr[$hp]=$((65536 * 40 / 100))
sinks_changed
waitlog "$m" "volume $hp $cap60 $((volr[$hp] * cap60 / vol[$hp]))" ||
  fail "max volume: unequal channels 80 and 40 % were not folded to 60 and 30 %: $(since "$m")"
unset "volr[$hp]"
vol[$hp]=$((65536 * 30 / 100))
write_sinks
m=$(mark)
vol[$hp]=$((65536 * 90 / 100))
write_sinks
vol[$hp]=$((65536 * 30 / 100))
write_sinks "$STUB_DIR/sinks.after"
echo "Event 'change' on sink #$RANDOM" >> "$STUB_DIR/pactl.feed"
novol "$m" || fail "max volume: a level lowered after the listing was raised to the cap: $(since "$m")"
m=$(mark)
state[$na]=IDLE target[$na]=$hp oid[$na]=92 vol[$na]=$((65536 * 90 / 100))
sinks_changed
waitlog "$m" "volume $na 65536" || fail "a chain sink at 90 % was not folded: $(since "$m")"
since "$m" | grep -q "^volume $na $cap60" && fail "max volume: a chain sink was capped and not left to the fold: $(since "$m")"
unset "state[$na]" "target[$na]" "oid[$na]" "vol[$na]"
write_sinks
m=$(mark)
poke audio.max_volume "<'loud'>"
errline "audio.max_volume 'loud' not valid, using 100" || fail "a bad audio.max_volume was not logged"
vol[$hp]=$((65536 * 120 / 100))
sinks_changed
waitlog "$m" "volume $hp 65536 65536" || fail "a bad audio.max_volume did not cap at 100 %: $(since "$m")"
m=$(mark)
poke audio.max_volume "<uint32 100>"
vol[$spk]=$((65536 * 120 / 100))
sinks_changed
waitlog "$m" "volume $spk 65536 65536" || fail "max volume 100: a sink at 120 % was not folded to 100 %: $(since "$m")"
kill "$as"
wait "$as" 2> /dev/null || true
vol[$spk]=65536 vol[$hp]=$cap50
write_sinks
echo auto_null > "$STUB_DIR/default-sink"
echo boot-g > "$tmp/boot_id"
m=$(mark)
start_audio_boot
for _ in {1..200}; do grep -qF "default sink auto_null is still not a listed output, skipped for this boot" "$tmp/audio.err" && break; sleep 0.1; done
grep -qF "default sink auto_null is still not a listed output, skipped for this boot" "$tmp/audio.err" ||
  fail "power on volume did not give up on a default that never became an output"
[[ $(cat "$marker") == boot-g ]] || fail "power on volume did not mark boot-g after the waits ran out"
echo "$hp" > "$STUB_DIR/default-sink"
sinks_changed
novol "$m" || fail "power on volume was applied after the waits ran out: $(since "$m")"

if ((rc != 0)); then
  cat "$tmp/audio.err" >&2
else
  echo "audio-policy: ok"
fi
exit $rc
