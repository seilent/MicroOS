#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
fixture=${MICROOS_CONTROLS:-$here/fixtures/pm2-controls.txt}
ucm=$tree/usr/share/alsa/ucm2
card=$ucm/Qualcomm/sm8250/PocketMICRO2.conf
hifi=$ucm/Qualcomm/sm8250/PocketMICRO2-HiFi.conf
tmp=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; wait; rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

for t in alsaucm spa-json-dump pipewire pipewire-pulse wireplumber wpctl pactl pacat pw-cat pw-link; do
  command -v "$t" >/dev/null || { echo "FAIL: $t missing" >&2; exit 1; }
done
[[ -d /usr/share/alsa/ucm2 ]] || { echo "FAIL: no alsa-ucm tree" >&2; exit 1; }

[[ $(readlink "$ucm/conf.d/sm8250/PocketMICRO2.conf") == ../../Qualcomm/sm8250/PocketMICRO2.conf ]] ||
  fail "conf.d/sm8250/PocketMICRO2.conf is not the relative link to the card file"

u=$tmp/ucm2
cp -a /usr/share/alsa/ucm2 "$u"
cp -a "$ucm/." "$u/"
sed -i 's/[$]{CardId}/0/g' "$u/Qualcomm/sm8250/PocketMICRO2-HiFi.conf"
mkdir -p "$u/conf.virt.d"
ln -s ../conf.d/sm8250/PocketMICRO2.conf "$u/conf.virt.d/PocketMICRO2.conf"
if ALSA_CONFIG_UCM2=$u alsaucm -c PocketMICRO2 dump text > "$tmp/dump" 2> "$tmp/dump.err"; then
  for want in 'Verb.HiFi {' 'Device.Headphones {' 'Device.Speaker {' 'Device.Headset {' 'PlaybackPCM "_ucm0001.hw:0,0"' \
    'PlaybackPCM "_ucm0001.hw:0,1"' 'CapturePCM "_ucm0001.hw:0,2"' 'PlaybackPriority 200' 'PlaybackPriority 100' \
    'PlaybackMixerElem HP' 'PlaybackMixerElem Speakers' 'CaptureMixerElem ADC2' 'JackControl "Headphone Jack"' \
    'JackHWMute Speaker' 'JackControl "Mic Jack"'; do
    grep -qF "$want" "$tmp/dump" || fail "ucm dump lacks $want"
  done
else
  fail "alsaucm cannot parse the PocketMICRO2 ucm: $(grep -v 'no soundcards found' "$tmp/dump.err")"
fi

srcs=("$card" "$hifi")
while read -r inc; do
  [[ -f /usr/share/alsa/ucm2$inc ]] || { fail "include $inc missing"; continue; }
  srcs+=("/usr/share/alsa/ucm2$inc")
done < <(sed -n 's/^Include\.[^ ]*\.File "\(.*\)"$/\1/p' "$card")

{
  sed -n "s/.*cset \"name='\([^']*\)'.*/\1/p" "${srcs[@]}"
  sed -n "s/.*\"name='\([^']*\)'\"\.vindex.*/\1/p" "${srcs[@]}"
  sed -n 's/.*JackControl "\([^"]*\)".*/\1/p' "${srcs[@]}"
  sed -n 's/.*CaptureMixerElem "\([^"]*\)".*/\1 Volume/p' "${srcs[@]}"
} | sort -u > "$tmp/names"
(( $(wc -l < "$tmp/names") )) || fail "no control names found in the ucm"

if [[ -s $fixture ]]; then
  sed -n "s/.*,name='\([^']*\)'.*/\1/p" "$fixture" | sort -u > "$tmp/have"
  while read -r n; do
    grep -qxF "$n" "$tmp/have" || fail "control '$n' not in $(basename "$fixture")"
  done < "$tmp/names"
else
  echo "audio: $(wc -l < "$tmp/names") control names unchecked, $(basename "$fixture") is empty"
fi

declare -A boot=(
  ['RX HPH Mode']=CLS_H_LOHIFI ['RX_HPH PWR Mode']=LOHIFI ['HPHL Volume']=24 ['HPHR Volume']=24
  ['WSA_RX0 Digital Volume']=102 ['WSA_RX1 Digital Volume']=102 ['SpkrLeft PA Volume']=12 ['SpkrRight PA Volume']=12
)
for f in "${srcs[@]}"; do
  awk -v f="${f##*/}" '
    /^[ \t]*BootSequence[ \t]*\[/ { b = 1 }
    /cset "name=/ { n = $0; sub(/.*name=\047/, "", n); v = n; sub(/\047.*/, "", n); sub(/.*\047 */, "", v); sub(/" *$/, "", v)
      print (b ? "boot" : "seq") "\t" f ":" NR "\t" n "\t" v }
    b && /^[ \t]*\]/ { b = 0 }
  ' "$f"
done > "$tmp/csets"
for n in "${!boot[@]}"; do
  while IFS=$'\t' read -r where at name value; do
    [[ $name == "$n" ]] || continue
    if [[ $where == seq ]]; then
      fail "$at: a sequence writes '$n', microsetd owns it"
    elif [[ $value != "${boot[$n]}" ]]; then
      fail "$at: boot writes '$n' $value, the default is ${boot[$n]}"
    fi
  done < "$tmp/csets"
  [[ $(grep -cP "^boot\t[^\t]*\t\Q$n\E\t" "$tmp/csets") == 1 ]] || fail "the boot sequence does not write '$n' once"
done
while read -r e; do
  for n in "${!boot[@]}"; do
    [[ $n == "$e "* ]] && fail "${hifi##*/}: CaptureMixerElem '$e' is '$n', microsetd owns it"
  done
done < <(sed -n 's/.*CaptureMixerElem "\([^"]*\)".*/\1/p' "$hifi")

soft=$tree/usr/share/wireplumber/wireplumber.conf.d/50-microos-soft-mixer.conf
if spa-json-dump "$soft" > "$tmp/soft.json" 2> "$tmp/soft.err"; then
  grep -q '"api.alsa.soft-mixer": true' "$tmp/soft.json" || fail "${soft##*/} does not set api.alsa.soft-mixer"
  mapfile -t devs < <(sed -n 's/^ *"device.name": "\(.*\)",\{0,1\}$/\1/p' "$tmp/soft.json")
  [[ ${devs[*]} == alsa_card.platform-sound ]] || fail "${soft##*/} matches '${devs[*]}', not alsa_card.platform-sound"
  ! grep -q '"node.name"\|"alsa.card_name"' "$tmp/soft.json" || fail "${soft##*/} matches nodes, the soft mixer is a device property"
else
  fail "${soft##*/}: $(cat "$tmp/soft.err")"
fi

wp=$tree/usr/share/wireplumber/wireplumber.conf.d/52-microos-pm2.conf
if spa-json-dump "$wp" > "$tmp/wp.json" 2> "$tmp/wp.err"; then
  grep -q '"session.suspend-timeout-seconds": 0' "$tmp/wp.json" || fail "${wp##*/} lacks the suspend timeout"
  hp=alsa_output.platform-sound.HiFi__Headphones__sink
  spk=alsa_output.platform-sound.HiFi__Speaker__sink
  grep -q '"node.name": "~' "$tmp/wp.json" || fail "${wp##*/} has no node.name match"
  while read -r re; do
    [[ $re =~ [^.]\* ]] && fail "${wp##*/}: '$re' is a glob, node.name ~ values are regexes"
    hits=0
    for n in "$hp" "$spk"; do
      if grep -qE "^($re)$" <<< "$n"; then
        hits=$((hits + 1))
        [[ $re == *Headphones* && $n == "$spk" ]] && fail "${wp##*/}: '$re' matches the speaker node"
        [[ $re == *Speaker* && $n == "$hp" ]] && fail "${wp##*/}: '$re' matches the headphones node"
      fi
    done
    (( hits )) || fail "${wp##*/}: '$re' matches no PocketMICRO2 output node"
  done < <(sed -n 's/^ *"node.name": "~\(.*\)",\{0,1\}$/\1/p' "$tmp/wp.json")
else
  fail "${wp##*/}: $(cat "$tmp/wp.err")"
fi

pins=$here/../packages/pipewire-aptx/SOURCE.env
if [[ -f $pins ]]; then
  for p in pipewire:PIPEWIRE_EVR pipewire-pulseaudio:PIPEWIRE_EVR wireplumber:WIREPLUMBER_EVR; do
    want=$(sed -n "s/^${p#*:}=//p" "$pins")
    [[ $(rpm -q --qf '%{VERSION}-%{RELEASE}' "${p%%:*}") == "$want" ]] || fail "${p%%:*} is not the pinned $want"
  done
fi

eq=$tree/usr/share/wireplumber/wireplumber.conf.d/54-microos-eq.conf
bypass=$tree/usr/share/wireplumber/scripts/microos/eq-bypass.lua
[[ -f $bypass ]] || fail "eq-bypass.lua missing"
if spa-json-dump "$eq" > "$tmp/eq.json" 2> "$tmp/eq.err"; then
  grep -q '"name": "microos/eq-bypass.lua"' "$tmp/eq.json" || fail "${eq##*/} does not load microos/eq-bypass.lua"
  grep -q '"provides": "hooks.linking.microos-eq-bypass"' "$tmp/eq.json" || fail "${eq##*/} does not provide hooks.linking.microos-eq-bypass"
  grep -q '"hooks.linking.microos-eq-bypass": "required"' "$tmp/eq.json" || fail "${eq##*/} does not require the bypass in the main profile"
  grep -q '"device.restore-profile": false' "$tmp/eq.json" || fail "${eq##*/} does not turn device.restore-profile off"
  ! grep -q 'allowed-rates' "$tmp/eq.json" || fail "${eq##*/} sets allowed rates"
else
  fail "${eq##*/}: $(cat "$tmp/eq.err")"
fi

export XDG_RUNTIME_DIR=$tmp/run XDG_CONFIG_HOME=$tmp/config XDG_DATA_HOME=$tmp/data XDG_STATE_HOME=$tmp/state HOME=$tmp/home
mkdir -p "$XDG_RUNTIME_DIR" "$HOME" "$XDG_CONFIG_HOME/wireplumber" "$XDG_DATA_HOME/wireplumber"
chmod 700 "$XDG_RUNTIME_DIR"
if [[ $tree != / ]]; then
  cp -a "$tree/usr/share/wireplumber/wireplumber.conf.d" "$XDG_CONFIG_HOME/wireplumber/"
  cp -a "$tree/usr/share/wireplumber/scripts" "$XDG_DATA_HOME/wireplumber/"
fi
until_true() {
  local n
  for ((n = 0; n < 100; n++)); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}
linked() {
  local n
  for ((n = 0; n < 100; n++)); do
    pw-link -l > "$tmp/links"
    grep -A1 -x "$1:output_FL" "$tmp/links" | grep -qxF "  |-> $2:playback_FL" && return 0
    sleep 0.1
  done
  return 1
}
pipewire > "$tmp/pw.log" 2>&1 &
until_true test -S "$XDG_RUNTIME_DIR/pipewire-0" || fail "pipewire did not start: $(tail -3 "$tmp/pw.log")"
wireplumber > "$tmp/wp.log" 2>&1 &
wp=$!
pipewire-pulse > "$tmp/pp.log" 2>&1 &
if until_true pactl info >/dev/null 2>&1 && until_true wpctl settings device.restore-profile >/dev/null 2>&1; then
  kill -0 "$wp" 2>/dev/null || fail "wireplumber exited: $(tail -3 "$tmp/wp.log")"
  [[ $(wpctl settings device.restore-profile 2>/dev/null) == 'Value: false' ]] || fail "device.restore-profile is not false in WirePlumber"
  hp=alsa_output.platform-sound.HiFi__Headphones__sink
  spk=alsa_output.platform-sound.HiFi__Speaker__sink
  chain=microos-eq.headphones.0123456789ab
  pactl load-module module-null-sink sink_name=$hp sink_properties=priority.session=1100 >/dev/null
  pactl load-module module-null-sink sink_name=$spk sink_properties=priority.session=1000 >/dev/null
  until_true sh -c "[ \"\$(pactl get-default-sink)\" = $hp ]" || fail "default sink is not $hp"
  cat > "$tmp/eq.conf" <<EOF
context.spa-libs = {
  audio.convert.* = audioconvert/libspa-audioconvert
  support.* = support/libspa-support
}
context.modules = [
  { name = libpipewire-module-protocol-native }
  { name = libpipewire-module-client-node }
  { name = libpipewire-module-adapter }
  {
    name = libpipewire-module-filter-chain
    args = {
      node.description = "Headphones EQ"
      audio.channels = 2
      audio.position = [ FL FR ]
      filter.graph = {
        nodes = [
          { type = builtin name = f0 label = bq_highshelf control = { Freq = 0 Q = 1 Gain = -3 } }
          { type = builtin name = f1 label = bq_peaking control = { Freq = 1000 Q = 1 Gain = 6 } }
        ]
        links = [
          { output = "f0:Out" input = "f1:In" }
        ]
      }
      capture.props = {
        node.name = "$chain"
        media.class = Audio/Sink
        filter.smart = true
        filter.smart.name = "$chain"
        filter.smart.target = { node.name = "$hp" }
        filter.smart.targetable = false
        state.restore-props = false
      }
      playback.props = {
        node.name = "$chain.out"
        target.object = "$hp"
        node.dont-fallback = true
        node.passive = true
        node.linger = true
      }
    }
  }
]
EOF
  pipewire -c "$tmp/eq.conf" > "$tmp/eq.log" 2>&1 &
  linked "$chain.out" "$hp" || fail "the chain is not linked to $hp: $(tail -3 "$tmp/eq.log")"
  pacat --property=node.name=t-default /dev/zero 2>/dev/null &
  pacat --device=$hp --property=node.name=t-device /dev/zero 2>/dev/null &
  pacat --device=$hp --property=node.name=t-pulse-bitperfect --property=node.dont-reconnect=true /dev/zero 2>/dev/null &
  pw-cat -p --raw --target $hp -P '{ node.name = t-bitperfect node.dont-fallback = true node.dont-reconnect = true }' - < /dev/zero 2>/dev/null &
  pacat --device=$spk --property=node.name=t-speaker /dev/zero 2>/dev/null &
  while read -r node to; do
    linked "$node" "$to" || fail "$node is not linked to $to: $(grep -A1 -x "$node:output_FL" "$tmp/links" | tail -1)"
  done <<< "t-default $chain
t-device $chain
t-pulse-bitperfect $hp
t-bitperfect $hp
t-speaker $spk"
  [[ $(pactl get-default-sink) == "$hp" ]] || fail "the chain took the default sink"
else
  fail "pipewire-pulse or wireplumber did not come up: $(tail -3 "$tmp/wp.log")"
fi

if command -v udevadm >/dev/null; then
  udevadm verify --no-summary "$tree/usr/lib/udev/rules.d/60-microos-wcd938x-awake.rules" || fail "udev rules do not verify"
else
  echo "audio: udevadm missing, udev rules unchecked"
fi

exit $rc
