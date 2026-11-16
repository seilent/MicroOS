#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
audio=$tree/usr/libexec/microos/microos-audio
wpconf=$tree/usr/share/wireplumber/wireplumber.conf.d/54-microos-eq.conf
bypass=$tree/usr/share/wireplumber/scripts/microos/eq-bypass.lua
level=$here/audio-eq/level
tmp=$(mktemp -d)
pids=()
cleanup() {
  local p f
  for f in "$tmp"/shim/*.sup; do
    [[ -e $f ]] && { kill -- "-$(cat "$f")" 2> /dev/null || true; }
  done
  for p in "${pids[@]}"; do kill -- "-$p" 2> /dev/null || kill "$p" 2> /dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

for t in pipewire wireplumber pipewire-pulse pactl pw-cli pw-play pw-record pw-link pw-metadata wpctl gcc g++ python3 \
  dbus-daemon gdbus setsid; do
  command -v "$t" > /dev/null || { echo "FAIL: $t missing" >&2; exit 1; }
done
python3 -c 'import gi, numpy' || { echo "FAIL: python3-gobject or numpy missing" >&2; exit 1; }
for f in "$wpconf" "$bypass"; do
  [[ -f $f ]] || { echo "FAIL: ${f#"$tree"} missing" >&2; exit 1; }
done
g++ -std=c++20 -O2 -o "$tmp/biquad-ref" "$here/pkg-microos-eq/fixtures/biquad-ref.cpp" "$here/pkg-microos-eq/fixtures/Biquad.cpp"
g++ -std=c++20 -O2 -ffp-contract=off -o "$tmp/flatdap-ref" "$here/pkg-microos-eq/fixtures/flatdap-ref.cpp"
python3 - "$tmp/flatdap-ref" "$here/pkg-microos-eq/fixtures/flatdap-987ddd3.txt" << 'PY' || fail "flatdap-ref differs from flatdap 987ddd3 design_biquad or xfeed_design"
import subprocess, sys
ref, golden = sys.argv[1], sys.argv[2]
one, bad = 1 << 30, []
for line in open(golden):
    f = line.split()
    out = subprocess.run([ref, *f[:3]] if f[0] == "xcoef" else [ref, *f[:5]], capture_output=True, text=True, check=True).stdout
    if f[0] == "coef":
        ok = all(abs(a - b) <= 1e-12 * max(1.0, abs(b)) for a, b in zip(map(float, out.split()), map(float, f[5:])))
    else:
        lo, hi = ([float(v) for v in l.split()] for l in out.splitlines())
        got = (lo[0] * one, -lo[3] * one, hi[0] * one, hi[1] * one, -hi[3] * one)
        ok = all(abs(a - int(b)) <= 2 for a, b in zip(got, f[3:]))
    if not ok:
        bad.append(line.strip())
if bad:
    sys.exit("\n".join(bad))
PY
[[ -f /usr/include/ladspa.h ]] || { echo "FAIL: ladspa.h missing (ladspa-devel)" >&2; exit 1; }
src=$here/../packages/microos-eq/src
gcc -O2 -std=gnu11 -fPIC -ffp-contract=off -fvisibility=hidden -shared -o "$tmp/microos-eq.so" \
  "$src/eq.c" "$src/rbj.c" "$src/crossfeed.c" -lm
export MICROOS_EQ_PLUGIN=$tmp/microos-eq.so

export XDG_RUNTIME_DIR=$tmp/run XDG_CONFIG_HOME=$tmp/config XDG_DATA_HOME=$tmp/data XDG_STATE_HOME=$tmp/state EQ_SHIM_DIR=$tmp/shim
mkdir "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
mkdir -p "$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d" "$XDG_DATA_HOME/wireplumber/scripts/microos" "$EQ_SHIM_DIR"
cp "$wpconf" "$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d/"
cp "$bypass" "$XDG_DATA_HOME/wireplumber/scripts/microos/"
: > "$EQ_SHIM_DIR/log"
: > "$tmp/audio.err"

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
dbus-daemon --session --address="unix:path=$XDG_RUNTIME_DIR/bus" --nofork --nopidfile & pids+=($!)
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=$tmp/bus DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
for _ in {1..50}; do [[ -S $tmp/bus && -S $XDG_RUNTIME_DIR/bus ]] && break; sleep 0.1; done

setsid pipewire > "$tmp/pw.log" 2>&1 & pids+=($!)
for _ in {1..50}; do [[ -S $XDG_RUNTIME_DIR/pipewire-0 ]] && break; sleep 0.1; done
start_wp() {
  setsid wireplumber >> "$tmp/wp.log" 2>&1 & wp=$!
  pids+=("$wp")
}
start_wp
setsid pipewire-pulse > "$tmp/pp.log" 2>&1 & pids+=($!)
for _ in {1..50}; do pactl info > /dev/null 2>&1 && break; sleep 0.1; done

hp=alsa_output.platform-sound.HiFi__Headphones__sink
spk=alsa_output.platform-sound.HiFi__Speaker__sink
bt=bluez_output.00_1B_66_00_00_01.1
load_hp() { hpmod=$(pactl load-module module-null-sink "sink_name=$hp" sink_properties=priority.session=1100); }
load_hp
pactl load-module module-null-sink "sink_name=$spk" sink_properties=priority.session=1000 > /dev/null
for _ in {1..50}; do wpctl status 2> /dev/null | grep -q HiFi__Speaker && break; sleep 0.1; done

python3 "$here/audio-policy/microsetd" "$tmp/microset.log" headphones & pids+=($!)
for _ in {1..50}; do grep -qx ready "$tmp/microset.log" 2> /dev/null && break; sleep 0.1; done
poke() {
  gdbus call --system -d net.seilent.MicroSet -o /net/seilent/MicroSet -m test.Stub.Poke "'$1'" "$2" > /dev/null
}
start_audio() {
  PATH=$here/audio-eq:$PATH MICROOS_AUDIO_SETTLE=1 setsid python3 "$audio" >> "$tmp/audio.err" 2>&1 & as=$!
  pids+=("$as")
}
amark() { wc -l < "$tmp/audio.err"; }
await() {
  local from=$1 want=$2
  for _ in {1..100}; do
    tail -n "+$((from + 1))" "$tmp/audio.err" | grep -qF -- "$want" && return 0
    sleep 0.1
  done
  return 1
}
smark() { wc -l < "$EQ_SHIM_DIR/log"; }
ssince() { tail -n "+$(($1 + 1))" "$EQ_SHIM_DIR/log"; }
chain_up() {
  local n=microos-eq.${1/-/.}
  for _ in {1..100}; do
    pactl list sinks short 2> /dev/null | grep -qF "$n" && return 0
    sleep 0.1
  done
  return 1
}
eqhash() { printf '%s\n%s' "$1" "$2" | sha256sum | cut -c1-12; }
volume() { pactl get-sink-volume "$1" 2> /dev/null | awk '/Volume:/ { print $3; exit }'; }

start_audio
for _ in {1..50}; do [[ $(pactl get-default-sink) == "$hp" ]] && break; sleep 0.1; done

freqs=(40 100 250 500 1000 2000 4000 8000 12000 16000)
filters_a=("preamp -3" "peak 1000 6 1" "lowshelf 105 6 0.7" "highshelf 8000 -5 0.7" "lowpass 18000 0 0.707" "highpass 30 0 0.707")
filters_b=("preamp 0" "bandpass 2000 0 0.7" "allpass 1000 0 1" "peak 300 -8 2")
filters_c=("preamp -1" "bandpass 2000 0 0.7" "allpass 1000 0 1" "peak 300 4 2")
ha=$(eqhash "$hp" "eq crossfeed")
ia=headphones-$ha
na=microos-eq.headphones.$ha
variant() {
  local out="<[" sep="" f
  for f in "$@"; do out+="$sep'$f'"; sep=", "; done
  echo "$out]>"
}
ref() {
  local rate=$1 preamp f args=()
  shift
  preamp=${1#preamp }
  shift
  for f in "$@"; do
    read -r -a b <<< "$f"
    args+=("${b[@]}")
  done
  printf '%s\n' "${freqs[@]}" | "$tmp/biquad-ref" "$rate" "$preamp" "${args[@]}"
}
play() {
  local rate=$1 file=$tmp/tones-$1.raw
  [[ -e $file ]] || "$level" gen "$rate" 90 0.02 "${freqs[@]}" > "$file"
  setsid pw-play --raw --rate "$rate" --channels 1 --format f32 -P '{ media.name = microos-eq-test-tones }' "$file" 2>> "$tmp/play.log" &
  player=$!
  pids+=("$player")
}
capture() {
  local out=$1 rate=$2 sink=${3:-$hp} port=${4:-FL} tones=("${@:5}") rec
  rm -f "$out"
  pw-record --raw --rate "$rate" --channels 1 --format f32 -P '{ node.name = microos-eq-test-rec node.autoconnect = false }' "$out" 2>> "$tmp/play.log" &
  rec=$!
  for _ in {1..50}; do pw-link -i | grep -qxF microos-eq-test-rec:input_MONO && break; sleep 0.05; done
  pw-link "$sink:monitor_$port" microos-eq-test-rec:input_MONO
  sleep 1.6
  kill "$rec"
  wait "$rec" 2> /dev/null || true
  ((${#tones[@]})) || tones=("${freqs[@]}")
  "$level" mag "$rate" "$out" "${tones[@]}"
}
compare() {
  local label=$1 limit=$2 rate=$3 dry=$4 want=$5 out
  for _ in 1 2 3; do
    out=$(awk -v label="$label" -v limit="$limit" '
      FILENAME == ARGV[1] { m[$1] = $2; next }
      FILENAME == ARGV[2] { d[$1] = $2; next }
      { got = m[$1] - d[$1]; diff = got - $2; if (diff < 0) diff = -diff
        if (diff > limit) { printf "FAIL: %s at %s Hz: %.3f dB, reference %.3f dB\n", label, $1, got, $2; bad = 1 } }
      END { exit bad }' <(capture "$tmp/eq.raw" "$rate") <(echo "$dry") <(echo "$want")) && return 0
    echo "audio-eq: $label: capture off by more than $limit dB" >> "$tmp/retries"
    sleep 1
  done
  echo "$out" >&2
  rc=1
}
shape() {
  awk '$1 == 1000 { a = $2 } $1 == 4000 { b = $2 } END { printf "%.3f\n", a - b }' <<< "$1"
}

for rate in 44100 48000 96000; do
  pw-metadata -n settings 0 clock.force-rate "$rate" > /dev/null
  sleep 0.5
  play "$rate"
  sleep 1
  dry=$(capture "$tmp/dry.raw" "$rate")
  m=$(amark)
  s=$(smark)
  poke audio.eq.headphones.filters "$(variant "${filters_a[@]}")"
  poke audio.eq.headphones.on "<true>"
  chain_up "$ia" || fail "$rate: chain $ia did not come up: $(tail -n +"$((m + 1))" "$tmp/audio.err")"
  sleep 0.7
  compare "$rate A" 0.1 "$rate" "$dry" "$(ref "$rate" "${filters_a[@]}")"
  m=$(amark)
  s=$(smark)
  poke audio.eq.headphones.filters "$(variant "${filters_b[@]}")"
  await "$m" "EQ values sent to $ia" || fail "$rate: the type and count change A to B was not sent live to $ia"
  sleep 0.7
  kill -0 "$player" 2> /dev/null || fail "$rate: the stream died in the A to B change"
  compare "$rate B (live)" 0.1 "$rate" "$dry" "$(ref "$rate" "${filters_b[@]}")"
  [[ -z $(ssince "$s") ]] || fail "$rate: the A to B change touched a unit: $(ssince "$s")"
  m=$(amark)
  s=$(smark)
  poke audio.eq.headphones.filters "$(variant "${filters_c[@]}")"
  await "$m" "EQ values sent to $ia" || fail "$rate: live edit not sent to $ia"
  sleep 0.3
  compare "$rate C (live)" 0.1 "$rate" "$dry" "$(ref "$rate" "${filters_c[@]}")"
  [[ -z $(ssince "$s") ]] || fail "$rate: a live edit touched a unit: $(ssince "$s")"
  m=$(amark)
  poke audio.eq.headphones.on "<false>"
  await "$m" "EQ chain $ia stopped" || fail "$rate: EQ off did not stop $ia"
  kill "$player" 2> /dev/null || true
  wait "$player" 2> /dev/null || true
done

mref() {
  local rate=$1 preamp f args=()
  shift
  preamp=${1#preamp }
  shift
  for f in "$@"; do
    read -r -a b <<< "$f"
    args+=("${b[@]:1}")
  done
  printf '%s\n' "${freqs[@]}" | "$tmp/flatdap-ref" mag "$rate" "$preamp" "${args[@]}"
}
filters_m=("preamp -6" "matchedpeak 1000 6 0.92" "matchedpeak 8000 -4 0.92" "matchedpeak 16000 9 0.92")
filters_n=("preamp -4" "matchedpeak 2000 4 1.5" "matchedpeak 12000 -6 0.7")
filters_g=("preamp -6" "matchedpeak 31.25 3 0.92" "matchedpeak 62.5 -2 0.92" "matchedpeak 125 4 0.92" "matchedpeak 250 0 0.92"
  "matchedpeak 500 -3 0.92" "matchedpeak 1000 6 0.92" "matchedpeak 2000 -1 0.92" "matchedpeak 4000 2 0.92"
  "matchedpeak 8000 -4 0.92" "matchedpeak 16000 5 0.92")
im=$ia
play 48000
sleep 1
declare -A dry_at
for rate in 44100 48000 96000; do
  pw-metadata -n settings 0 clock.force-rate "$rate" > /dev/null
  sleep 0.7
  dry_at[$rate]=$(capture "$tmp/dry.raw" "$rate")
done
m=$(amark)
poke audio.eq.headphones.filters "$(variant "${filters_m[@]}")"
poke audio.eq.headphones.on "<true>"
chain_up "$im" || fail "matched peak: chain $im did not come up: $(tail -n +"$((m + 1))" "$tmp/audio.err")"
sleep 0.7
s=$(smark)
for rate in 96000 44100 48000; do
  pw-metadata -n settings 0 clock.force-rate "$rate" > /dev/null
  sleep 0.7
  compare "$rate M (rate switch)" 0.1 "$rate" "${dry_at[$rate]}" "$(mref "$rate" "${filters_m[@]}")"
done
[[ -z $(ssince "$s") ]] || fail "matched peak: a rate switch touched a unit: $(ssince "$s")"
for set in n g; do
  declare -n fs=filters_$set
  m=$(amark)
  s=$(smark)
  poke audio.eq.headphones.filters "$(variant "${fs[@]}")"
  await "$m" "EQ values sent to $im" || fail "matched peak $set: new values were not sent live to $im"
  for rate in 96000 44100 48000; do
    pw-metadata -n settings 0 clock.force-rate "$rate" > /dev/null
    sleep 0.7
    compare "$rate M $set (live, rate switch)" 0.1 "$rate" "${dry_at[$rate]}" "$(mref "$rate" "${fs[@]}")"
  done
  [[ -z $(ssince "$s") ]] || fail "matched peak $set: a live change touched a unit: $(ssince "$s")"
  unset -n fs
done
m=$(amark)
poke audio.eq.headphones.filters "$(variant "${filters_m[@]}")"
await "$m" "EQ values sent to $im" || fail "matched peak: the first set was not sent back to $im"
m=$(amark)
s=$(smark)
poke audio.balance.headphones "<6>"
await "$m" "EQ values sent to $im" || fail "matched peak: a balance edit was not sent to $im"
for rate in 96000 44100 48000; do
  pw-metadata -n settings 0 clock.force-rate "$rate" > /dev/null
  sleep 0.7
  compare "$rate M balance R 3 dB (rate switch)" 0.1 "$rate" "${dry_at[$rate]}" \
    "$(mref "$rate" "${filters_m[@]}" | awk '{ print $1, $2 - 3 }')"
done
[[ -z $(ssince "$s") ]] || fail "matched peak: a balance edit touched a unit: $(ssince "$s")"
m=$(amark)
poke audio.balance.headphones "<0>"
await "$m" "EQ values sent to $im" || fail "matched peak: balance 0 was not sent to $im"
m=$(amark)
poke audio.eq.headphones.on "<false>"
await "$m" "EQ chain $im stopped" || fail "matched peak: EQ off did not stop $im"
kill "$player" 2> /dev/null || true
wait "$player" 2> /dev/null || true

pw-metadata -n settings 0 clock.force-rate 48000 > /dev/null
pw-metadata -n settings 0 clock.force-quantum 1024 > /dev/null
sleep 0.5
m=$(amark)
poke audio.eq.headphones.filters "<['preamp -12', 'matchedpeak 1000 12 0.92']>"
poke audio.eq.headphones.on "<true>"
chain_up "$ia" || fail "live: chain $ia did not come up: $(tail -n +"$((m + 1))" "$tmp/audio.err")"
sleep 0.7
for leg in continuity hammer slow resume; do
  case $leg in
    continuity) "$here/audio-eq/live" continuity "$hp" || rc=1 ;;
    resume) "$here/audio-eq/live" resume "$na" "$hp" "$EQ_SHIM_DIR/$ia.err" || rc=1 ;;
    *) "$here/audio-eq/live" "$leg" "$na" "$hp" || rc=1 ;;
  esac
done
m=$(amark)
poke audio.eq.headphones.filters "<['preamp 0', 'matchedpeak 1000 6 0.92']>"
await "$m" "EQ values sent to $ia" || fail "clamp: the matched peak was not sent to $ia"
play 48000
sleep 1
pw-cli s "$na" Props '{ params = [ "eqL:Gain1" 30.0 "eqR:Gain1" 30.0 ] }' > /dev/null
sleep 0.5
compare "48000 clamp Gain1 30 to 12" 0.1 48000 "${dry_at[48000]}" "$(mref 48000 "preamp 0" "matchedpeak 1000 12 0.92")"
kill "$player" 2> /dev/null || true
wait "$player" 2> /dev/null || true
pw-metadata -n settings -d 0 clock.force-quantum > /dev/null
m=$(amark)
poke audio.eq.headphones.on "<false>"
await "$m" "EQ chain $ia stopped" || fail "live: EQ off did not stop $ia"

rate=48000
level_at() { capture "$tmp/b.raw" "$rate" "$hp" "$1" | awk '$1 == 1000 { print $2 }'; }
near() { awk -v a="$1" -v b="$2" -v want="$3" 'BEGIN { d = a - b - want; exit !(d < 0.1 && d > -0.1) }'; }
play "$rate"
sleep 1
dl=$(level_at FL)
dr=$(level_at FR)
ibal=$ia
m=$(amark)
s=$(smark)
poke audio.balance.headphones "<6>"
chain_up "$ibal" || fail "balance: no chain for balance alone: $(tail -n +"$((m + 1))" "$tmp/audio.err")"
sleep 0.7
l=$(level_at FL) r=$(level_at FR)
near "$l" "$dl" -3 && near "$r" "$dr" 0 || fail "balance R 3 dB: L $l R $r, dry L $dl R $dr"
grep -qF 'label = crossfeed control = { "On" = 0.0 ' "$XDG_RUNTIME_DIR/microos-audio/eq/$ibal.conf" ||
  fail "balance alone: no crossfeed node with On 0.0"
m=$(amark)
s=$(smark)
poke audio.balance.headphones "<-4>"
await "$m" "EQ values sent to $ibal" || fail "balance: a live edit was not sent to $ibal"
sleep 0.3
l=$(level_at FL) r=$(level_at FR)
near "$l" "$dl" 0 && near "$r" "$dr" -2 || fail "balance L 2 dB: L $l R $r, dry L $dl R $dr"
[[ -z $(ssince "$s") ]] || fail "balance: a live edit touched a unit: $(ssince "$s")"
m=$(amark)
poke audio.balance.headphones "<0>"
await "$m" "EQ chain $ibal stopped" || fail "balance 0 kept the chain"
kill "$player" 2> /dev/null || true
wait "$player" 2> /dev/null || true

"$level" gen2 "$rate" 60 0.1 0 700 > "$tmp/x.raw"
setsid pw-play --target "$hp" -P '{ node.name = microos-eq-test-xdry node.dont-reconnect = true }' --raw --rate "$rate" \
  --channels 2 --format f32 "$tmp/x.raw" 2>> "$tmp/play.log" & xd=$!
pids+=("$xd")
sleep 1
xdry=$(capture "$tmp/xd.raw" "$rate" "$hp" FL 700 | awk '{ print $2 }')
kill "$xd" 2> /dev/null || true
wait "$xd" 2> /dev/null || true
prev=$ia
for preset in default chuMoy janMeier; do
  m=$(amark)
  s=$(smark)
  poke audio.crossfeed.headphones "<'$preset'>"
  if [[ $preset == default ]]; then
    chain_up "$ia" || fail "crossfeed $preset: no chain: $(tail -n +"$((m + 1))" "$tmp/audio.err")"
    (($(ssince "$s" | grep -c "^start ") == 1)) || fail "crossfeed $preset: not one unit start: $(ssince "$s")"
  else
    await "$m" "EQ values sent to $ia" || fail "crossfeed $preset: not sent live to $ia"
    sleep 0.3
    [[ -z $(ssince "$s") ]] || fail "crossfeed $preset: a preset change touched a unit: $(ssince "$s")"
  fi
  setsid pw-play --raw --rate "$rate" --channels 2 --format f32 -P '{ node.name = microos-eq-test-x }' "$tmp/x.raw" 2>> "$tmp/play.log" & xp=$!
  pids+=("$xp")
  sleep 1
  read -r hi lo <<< "$("$tmp/flatdap-ref" xfeed "$preset" "$rate" 700)"
  l=$(capture "$tmp/xl.raw" "$rate" "$hp" FL 700 | awk '{ print $2 }')
  r=$(capture "$tmp/xr.raw" "$rate" "$hp" FR 700 | awk '{ print $2 }')
  near "$l" "$xdry" "$hi" && near "$r" "$xdry" "$lo" || fail "crossfeed $preset at 700 Hz on L: L $l R $r, dry $xdry, want $hi $lo dB"
  kill "$xp" 2> /dev/null || true
  wait "$xp" 2> /dev/null || true
done
m=$(amark)
poke audio.balance.headphones "<6>"
await "$m" "EQ values sent to $prev" || fail "crossfeed and balance: the balance was not sent to $prev"
setsid pw-play --raw --rate "$rate" --channels 2 --format f32 -P '{ node.name = microos-eq-test-x }' "$tmp/x.raw" 2>> "$tmp/play.log" & xp=$!
pids+=("$xp")
sleep 1
read -r hi lo <<< "$("$tmp/flatdap-ref" xfeed janMeier "$rate" 700)"
l=$(capture "$tmp/xl.raw" "$rate" "$hp" FL 700 | awk '{ print $2 }')
r=$(capture "$tmp/xr.raw" "$rate" "$hp" FR 700 | awk '{ print $2 }')
near "$l" "$xdry" "$(awk -v h="$hi" 'BEGIN { print h - 3 }')" && near "$r" "$xdry" "$lo" ||
  fail "crossfeed janMeier and balance R 3 dB at 700 Hz on L: L $l R $r, dry $xdry, want $hi - 3 and $lo dB"
kill "$xp" 2> /dev/null || true
wait "$xp" 2> /dev/null || true
m=$(amark)
poke audio.balance.headphones "<0>"
await "$m" "EQ values sent to $prev" || fail "crossfeed and balance: balance 0 was not sent to $prev"
m=$(amark)
poke audio.crossfeed.headphones "<'off'>"
await "$m" "EQ chain $prev stopped" || fail "crossfeed off kept the chain"
pw-metadata -n settings -d 0 clock.force-rate > /dev/null

rate=48000
want_a=$(ref "$rate" "${filters_a[@]}")
eq_shape=$(shape "$want_a")
on_eq() {
  local got levels
  for _ in 1 2 3; do
    levels=$(capture "$tmp/v.raw" "$rate")
    got=$(shape "$levels")
    awk -v g="$got" -v w="$eq_shape" 'BEGIN { d = g - w; exit !(d < 0.3 && d > -0.3) }' && return 0
    echo "audio-eq: $1: capture $(tr '\n' ' ' <<< "$levels")" >> "$tmp/retries"
    sleep 1
  done
  fail "$1: stream not on EQ (1 kHz to 4 kHz $got dB, want $eq_shape): $(tr '\n' ' ' <<< "$levels") $(pw-link -l | tr '\n' ' ')"
}
off_eq() {
  local got
  got=$(shape "$(capture "$tmp/v.raw" "$rate")")
  awk -v g="$got" 'BEGIN { exit !(g < 0.3 && g > -0.3) }' || fail "$1: stream not plain (1 kHz to 4 kHz $got dB)"
}
user=19661
pactl set-sink-volume "$hp" "$user"
play "$rate"
m=$(amark)
poke audio.eq.headphones.filters "$(variant "${filters_a[@]}")"
poke audio.eq.headphones.on "<true>"
chain_up "$ia" || fail "V1: chain $ia did not come up"
sleep 0.7
on_eq start
(while :; do volume "$hp" >> "$tmp/vol" || true; sleep 0.05; done) & poller=$!
pids+=("$poller")
peak() { sort -n "$tmp/vol" | tail -n 1; }
v1() {
  local top now
  top=$(peak)
  now=$(volume "$hp")
  ((top <= user)) || fail "$1: hardware volume rose to $top from $user"
  ((now == user)) || fail "$1: hardware volume $now after, was $user"
  kill -0 "$player" 2> /dev/null || fail "$1: the stream died"
  : > "$tmp/vol"
}

m=$(amark)
s=$(smark)
systemctl() { "$here/audio-eq/systemctl" "$@"; }
systemctl --user kill -s KILL "microos-eq@$ia.service"
for _ in {1..50}; do ssince "$s" | grep -q "^restart $ia " && break; sleep 0.1; done
ssince "$s" | grep -q "^restart $ia " || fail "kill: the chain was not restarted"
chain_up "$ia" || fail "kill: the restarted chain did not come up"
sleep 0.7
on_eq kill
v1 kill

m=$(amark)
s=$(smark)
kill "$as"
wait "$as" 2> /dev/null || true
start_audio
await "$m" "running EQ chains: $ia" || fail "microos-audio restart: the running chain was not adopted"
sleep 1.5
(($(tail -n "+$((m + 1))" "$tmp/audio.err" | grep -cF "EQ values sent to $ia") == 1)) ||
  fail "microos-audio restart: an adopted chain did not get its values once"
ssince "$s" | grep -q "^start $ia" && fail "microos-audio restart: the running chain was started again"
on_eq "microos-audio restart"
v1 "microos-audio restart"

old=headphones-000000000000
kill "$as"
wait "$as" 2> /dev/null || true
sed "s/microos-eq\.headphones\.$ha/microos-eq.headphones.000000000000/g" "$XDG_RUNTIME_DIR/microos-audio/eq/$ia.conf" \
  > "$XDG_RUNTIME_DIR/microos-audio/eq/$old.conf"
systemctl --user stop --no-block "microos-eq@$ia.service"
for _ in {1..50}; do pactl list sinks short 2> /dev/null | grep -qF "microos-eq.headphones.$ha" || break; sleep 0.1; done
systemctl --user start --no-block "microos-eq@$old.service"
chain_up "$old" || fail "adoption: the chain of another graph did not come up"
m=$(amark)
s=$(smark)
start_audio
await "$m" "EQ chain $old stopped" || fail "adoption: the chain of another graph was not stopped"
chain_up "$ia" || fail "adoption: no new chain replaced the one of another graph"
(($(ssince "$s" | grep -c "^start ") == 1)) || fail "adoption: not one new unit: $(ssince "$s")"
sleep 0.7
on_eq "adoption of another graph"
v1 "adoption of another graph"

m=$(amark)
s=$(smark)
kill "$wp" "$as"
wait "$wp" "$as" 2> /dev/null || true
start_wp
start_audio
await "$m" "running EQ chains: $ia" || fail "wireplumber restart: the chain did not survive"
sleep 2
ssince "$s" | grep -q "^start $ia" && fail "wireplumber restart: the chain was started again"
on_eq "wireplumber restart"
v1 "wireplumber restart"

m=$(amark)
pactl unload-module "$hpmod"
await "$m" "EQ chain $ia stopped" || fail "plug: the chain outlived its sink"
sleep 0.5
m=$(amark)
load_hp
for _ in {1..50}; do [[ $(volume "$hp") == "$user" ]] && break; sleep 0.1; done
: > "$tmp/vol"
chain_up "$ia" || fail "plug: the chain did not come back with its sink"
sleep 1
on_eq plug
v1 plug

m=$(amark)
poke audio.eq.headphones.on "<false>"
await "$m" "EQ chain $ia stopped" || fail "EQ off: chain not stopped"
sleep 0.7
off_eq "EQ off"
m=$(amark)
poke audio.eq.headphones.on "<true>"
chain_up "$ia" || fail "EQ on: chain not back"
sleep 0.7
on_eq "EQ on"
v1 "EQ off and on"

wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%-
sleep 0.3
down=$(volume "$hp")
((down < user)) || fail "a down step from 30 % left the hardware at $down"
[[ $(volume "$na") == 65536 ]] || fail "a down step moved the chain sink to $(volume "$na")"
wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
sleep 0.3
up=$(volume "$hp")
((up > down && up <= user + 2)) || fail "an up step from $down went to $up, want about $user"
user=$up
((user <= 19663)) || fail "steps raised the hardware above 30 %: $user"

"$level" gen "$rate" 30 0.1 3000 > "$tmp/bp.raw"
setsid pw-play --target "$hp" -P '{ node.name = microos-eq-test-bp node.dont-fallback = true node.dont-reconnect = true }' \
  --raw --rate "$rate" --channels 1 --format f32 "$tmp/bp.raw" 2>> "$tmp/play.log" & bp=$!
pids+=("$bp")
sleep 1
links=$(pw-link -l)
grep -A3 '^microos-eq-test-bp:output' <<< "$links" | grep -qF "$hp:playback_" ||
  fail "bitperfect stream not linked to the hardware sink: $(grep -A3 '^microos-eq-test-bp' <<< "$links")"
grep -A3 '^microos-eq-test-bp:output' <<< "$links" | grep -q "microos-eq\." && fail "bitperfect stream went through the chain"
wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%-
sleep 0.3
[[ $(volume "$hp") -lt $user ]] || fail "a volume step with a bitperfect stream did not move the hardware"
wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
sleep 0.3
user=$(volume "$hp")
kill "$bp" 2> /dev/null || true
wait "$bp" 2> /dev/null || true

m=$(amark)
n=$(grep -c '^set ' "$tmp/microset.log" || true)
pactl set-default-sink "$na"
for _ in {1..50}; do [[ $(pactl get-default-sink) == "$hp" ]] && break; sleep 0.1; done
[[ $(pactl get-default-sink) == "$hp" ]] || fail "a picked chain was not mapped to $hp: $(pactl get-default-sink)"
(($(grep -c '^set audio.output headphones' "$tmp/microset.log") > 0 && $(grep -c '^set ' "$tmp/microset.log") > n)) ||
  fail "a picked chain was not stored as headphones"

m=$(amark)
prev=$user
: > "$tmp/vol"
pactl set-sink-volume "$na" 32768
await "$m" "folded into $hp" || fail "a chain volume change was not folded"
sleep 0.3
[[ $(volume "$na") == 65536 ]] || fail "the chain sink was not set back to 100 %: $(volume "$na")"
folded=$(volume "$hp")
((folded == user / 2)) || fail "the folded hardware volume is $folded, want $((user / 2))"
user=$folded
top=$(peak)
((top <= prev)) || fail "fold: hardware volume rose to $top from $prev"
on_eq fold
((folded == $(volume "$hp"))) || fail "fold: hardware volume moved after the fold"

m=$(amark)
: > "$tmp/vol"
pactl set-sink-mute "$na" 1
await "$m" "mute True folded into $hp" || fail "a muted chain was not folded"
sleep 0.3
[[ $(pactl get-sink-mute "$hp") == "Mute: yes" ]] || fail "mute fold: hardware not muted: $(pactl get-sink-mute "$hp")"
[[ $(pactl get-sink-mute "$na") == "Mute: no" ]] || fail "mute fold: chain still muted"
[[ $(volume "$na") == 65536 ]] || fail "mute fold: chain volume $(volume "$na")"
top=$(peak)
((top <= user)) || fail "mute fold: hardware volume rose to $top from $user"
((user == $(volume "$hp"))) || fail "mute fold: hardware volume moved"
pactl set-sink-mute "$hp" 0

usb_a=alsa_output.usb-Test_EQ-00.analog-stereo usb_b=alsa_output.usb-Test_EQ-01.analog-stereo
desc_a='Test "K3" {x} \ end'
node() {
  pw-cli create-node adapter "{ factory.name = support.null-audio-sink node.name = \"$1\" node.description = \"$2\" media.class = Audio/Sink object.linger = true audio.position = [ FL FR ] monitor.channel-volumes = true }" > /dev/null
}
node "$usb_a" 'Test \"K3\" {x} \\ end'
node "$usb_b" 'Ünï DAC'
ua=usb-$(eqhash "$usb_a" "eq crossfeed") ub=usb-$(eqhash "$usb_b" "eq crossfeed")
m=$(amark)
poke audio.eq.usb.on "<true>"
chain_up "$ua" || fail "usb: no chain for $usb_a"
chain_up "$ub" || fail "usb: no chain for $usb_b"
for i in "$ua" "$ub"; do
  conf=$XDG_RUNTIME_DIR/microos-audio/eq/$i.conf
  spa-json-dump "$conf" > /dev/null 2> "$tmp/json.err" || fail "$i.conf is not valid SPA JSON: $(cat "$tmp/json.err")"
  (($(grep -c 'type = builtin' "$conf") == 2 && $(grep -c 'type = ladspa' "$conf") == 3)) ||
    fail "$i.conf: the default profile is not an eq node per side, a crossfeed node and a balance node per side"
  grep -qF '{ output = "x:OutL" input = "bL:In" }' "$conf" || fail "$i.conf: the default profile is not eq to crossfeed to balance"
done
descs=$(pw-dump | python3 -c 'import json, sys
for o in json.load(sys.stdin):
    p = (o.get("info") or {}).get("props") or {}
    if p.get("node.name", "").startswith("microos-eq.usb.") and not p["node.name"].endswith(".out"):
        print(p["node.name"], p.get("node.description"), sep="\t")')
grep -qxF "microos-eq.${ua/-/.}"$'\t'"$desc_a EQ" <<< "$descs" || fail "usb chain description is not \"$desc_a EQ\": $descs"
grep -qxF "microos-eq.${ub/-/.}"$'\t'"$usb_b EQ" <<< "$descs" || fail "a non ASCII description did not fall back to the node name: $descs"
setsid pw-play --target "$usb_a" --raw --rate "$rate" --channels 1 --format f32 "$tmp/tones-$rate.raw" 2>> "$tmp/play.log" & up=$!
pids+=("$up")
sleep 1
pw-link -l | grep -A3 '^pw-play:output_FL' | grep -qF "microos-eq.${ua/-/.}:playback_FL" || fail "a stream to $usb_a did not go through its chain"
levels=$(capture "$tmp/u.raw" "$rate" "$usb_a")
got=$(shape "$levels")
awk -v g="$got" 'BEGIN { exit !(g < 0.3 && g > -0.3) }' || fail "the preamp 0 chain is not flat: $got dB"
awk '$1 == 1000 { exit !($2 > -60) }' <<< "$levels" || fail "the preamp 0 chain is silent: $levels"
kill "$up" 2> /dev/null || true
m=$(amark)
s=$(smark)
poke audio.crossfeed.usb "<'janMeier'>"
await "$m" "EQ values sent to $ua" || fail "usb crossfeed: values not sent to $ua"
grep -qF 'label = crossfeed control = { "On" = 1.0 "Fc" = 650.0 "Level" = 9.5 }' "$XDG_RUNTIME_DIR/microos-audio/eq/$ua.conf" ||
  fail "usb crossfeed: $ua.conf has no JAN MEIER crossfeed"
m=$(amark)
poke audio.crossfeed.usb "<'off'>"
await "$m" "EQ values sent to $ua" || fail "usb crossfeed off: values not sent to $ua"
[[ -z $(ssince "$s") ]] || fail "usb crossfeed: a preset change touched a unit: $(ssince "$s")"
m=$(amark)
poke audio.eq.usb.on "<false>"
await "$m" "EQ chain $ub stopped" || fail "usb EQ off kept a chain"
sinkid() {
  pactl --format=json list sinks 2> /dev/null | python3 -c 'import json, sys
print(next(s["properties"]["object.id"] for s in json.load(sys.stdin) if s["name"] == sys.argv[1]))' "$1"
}
m=$(amark)
s=$(smark)
poke audio.eq.usb.on "<true>"
chain_up "$ua" || fail "layout: no chain for $usb_a"
pw-cli destroy "$(sinkid "$usb_a")" > /dev/null
pw-cli create-node adapter "{ factory.name = support.null-audio-sink node.name = \"$usb_a\" media.class = Audio/Sink object.linger = true audio.position = [ MONO ] monitor.channel-volumes = true }" > /dev/null
um=usb-$(eqhash "$usb_a" eq)
chain_up "$um" || fail "layout: no eq chain for $usb_a with one channel"
await "$m" "EQ chain $ua stopped" || fail "layout: the stereo chain of $usb_a was not stopped"
(($(ssince "$s" | grep -c "^start usb-${um#usb-}") == 1)) || fail "layout: not one new unit for the one channel layout: $(ssince "$s")"
grep -q "label = crossfeed" "$XDG_RUNTIME_DIR/microos-audio/eq/$um.conf" && fail "layout: the one channel chain has a crossfeed node"
m=$(amark)
poke audio.eq.usb.on "<false>"
await "$m" "EQ chain $um stopped" || fail "layout: usb EQ off kept $um"
for n in "$usb_a" "$usb_b"; do
  pw-cli destroy "$(sinkid "$n")" > /dev/null
done

usb_1=alsa_output.usb-Test_Mono-00.mono-fallback usb_6=alsa_output.usb-Test_Six-00.analog-surround-51
pw-cli create-node adapter "{ factory.name = support.null-audio-sink node.name = \"$usb_1\" media.class = Audio/Sink object.linger = true audio.position = [ MONO ] monitor.channel-volumes = true }" > /dev/null
pw-cli create-node adapter "{ factory.name = support.null-audio-sink node.name = \"$usb_6\" media.class = Audio/Sink object.linger = true audio.position = [ FL FR FC LFE RL RR ] monitor.channel-volumes = true }" > /dev/null
for _ in {1..50}; do pactl list sinks short 2> /dev/null | grep -qF "$usb_6" && break; sleep 0.1; done
m=$(amark)
s=$(smark)
poke audio.balance.usb "<4>"
poke audio.crossfeed.usb "<'default'>"
await "$m" "$usb_1 has 1 channels, balance and crossfeed skipped" || fail "a mono sink skip was not logged"
await "$m" "$usb_6 has 6 channels, balance and crossfeed skipped" || fail "a 6 channel sink skip was not logged"
sleep 1
ssince "$s" | grep -q "^start usb-" && fail "a mono or 6 channel sink got a chain: $(ssince "$s")"
poke audio.balance.usb "<0>"
poke audio.crossfeed.usb "<'off'>"
for n in "$usb_1" "$usb_6"; do
  pw-cli destroy "$(pactl --format=json list sinks 2> /dev/null | python3 -c 'import json, sys
print(next(s["properties"]["object.id"] for s in json.load(sys.stdin) if s["name"] == sys.argv[1]))' "$n")" > /dev/null
done

s=$(smark)
btmod=$(pactl load-module module-null-sink "sink_name=$bt")
sleep 2
ssince "$s" | grep -q "^start bt-" && fail "the bt slot is off by default and got a chain"
m=$(amark)
poke audio.crossfeed.headphones "<'default'>"
ixa=$ia
s=$(smark)
await "$m" "EQ values sent to $ixa" || fail "headphones crossfeed with EQ: not sent to $ixa"
for slot in speaker bt; do
  sink=$spk
  [[ $slot == bt ]] && sink=$bt
  i=$slot-$(eqhash "$sink" eq)
  poke "audio.balance.$slot" "<2>"
  chain_up "$i" || fail "$slot balance: no chain"
  grep -q "label = crossfeed" "$XDG_RUNTIME_DIR/microos-audio/eq/$i.conf" && fail "$slot got a crossfeed"
  grep -qF '"Gain" = -1.0' "$XDG_RUNTIME_DIR/microos-audio/eq/$i.conf" || fail "$slot balance R 1 dB is not in $i.conf"
  m=$(amark)
  poke "audio.balance.$slot" "<0>"
  await "$m" "EQ chain $i stopped" || fail "$slot balance 0 kept the chain"
done
m=$(amark)
poke audio.crossfeed.headphones "<'off'>"
await "$m" "EQ values sent to $ixa" || fail "headphones crossfeed off was not sent to $ixa"
ssince "$s" | grep -q " $ixa" && fail "headphones crossfeed on and off with EQ touched $ixa: $(ssince "$s")"
pactl unload-module "$btmod"

kill "$poller" 2> /dev/null || true
[[ -e $tmp/retries ]] && cat "$tmp/retries" >&2
if ((rc != 0)); then
  cat "$tmp/audio.err" >&2
else
  echo "audio-eq: ok"
fi
exit $rc
