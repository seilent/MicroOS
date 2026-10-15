#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
fixture=${MICROOS_CONTROLS:-$here/fixtures/pm2-controls.txt}
ucm=$tree/usr/share/alsa/ucm2
card=$ucm/Qualcomm/sm8250/PocketMICRO2.conf
hifi=$ucm/Qualcomm/sm8250/PocketMICRO2-HiFi.conf
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

for t in alsaucm spa-json-dump; do
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
  for want in 'Verb.HiFi {' 'Device.Headphones {' 'Device.Speaker {' 'PlaybackPCM "_ucm0001.hw:0,0"' \
    'PlaybackPCM "_ucm0001.hw:0,1"' 'PlaybackPriority 200' 'PlaybackPriority 100' 'PlaybackMixerElem HP' \
    'PlaybackMixerElem Speakers' 'JackControl "Headphone Jack"' 'JackHWMute Speaker'; do
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

if command -v udevadm >/dev/null; then
  udevadm verify --no-summary "$tree/usr/lib/udev/rules.d/60-microos-wcd938x-awake.rules" || fail "udev rules do not verify"
else
  echo "audio: udevadm missing, udev rules unchecked"
fi

exit $rc
