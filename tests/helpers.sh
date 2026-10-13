#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
helpers=$tree/usr/bin/steamos-polkit-helpers
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/logger" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOGGER_LOG"
EOF
chmod +x "$tmp/bin/logger"

node=/sys/class/backlight/backlight/brightness
dev=devices/platform/soc@0/c440000.spmi/spmi-0/0-05/c440000.spmi:pmic@5:leds@d800/backlight/backlight
sys=$tmp/sys
mkdir -p "$sys/$dev" "$sys/class/backlight/other"
ln -s "../../$dev" "$sys/class/backlight/backlight"
echo 4095 > "$sys/$dev/max_brightness"
echo 4095 > "$sys/class/backlight/other/max_brightness"

run() {
  : > "$tmp/log"
  r=0
  env -i PATH="$tmp/bin:/usr/bin:/bin" LOGGER_LOG="$tmp/log" MICROOS_SYSFS="$sys" "$@" > "$tmp/out" 2>&1 || r=$?
}
logs() { wc -l < "$tmp/log"; }

for v in 0 123 3071 4095; do
  echo 1000 > "$sys/$dev/brightness"
  run "$helpers/steamos-priv-write" "$node" "$v"
  (( r == 0 )) || fail "priv-write $v: exit $r: $(cat "$tmp/out")"
  [[ $(< "$sys/$dev/brightness") == "$v" ]] || fail "priv-write $v: brightness is $(< "$sys/$dev/brightness")"
  (( $(logs) == 0 )) || fail "priv-write $v: logged $(cat "$tmp/log")"
done

refused() {
  echo 1000 > "$sys/$dev/brightness"
  echo 1000 > "$sys/class/backlight/other/brightness"
  run "$helpers/steamos-priv-write" "$@"
  (( r == 1 )) || fail "priv-write $*: exit $r, want 1"
  [[ $(< "$sys/$dev/brightness") == 1000 && $(< "$sys/class/backlight/other/brightness") == 1000 ]] ||
    fail "priv-write $*: a brightness node changed"
  (( $(logs) == 1 )) || fail "priv-write $*: $(logs) logger calls, want 1"
  grep -q '^-t steamos-priv-write ' "$tmp/log" || fail "priv-write $*: logger tag: $(cat "$tmp/log")"
}
refused "$node" 4096
refused "$node" -1
refused "$node" 12a
refused "$node" ""
refused "$node" 0x10
refused "$node" " 5"
refused "$node" 99999999999999999999
refused /sys/class/backlight/other/brightness 500
refused "/sys/$dev/brightness" 500
refused /sys/class/backlight/backlight/../backlight/brightness 500
refused /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 500
refused "$node"
refused "$node" 500 extra
refused

echo nope > "$sys/$dev/max_brightness"
refused "$node" 500
echo 4095 > "$sys/$dev/max_brightness"

run "$helpers/steamos-devkit-mode" --disable
(( r == 0 && $(logs) == 0 )) || fail "devkit-mode --disable: exit $r, $(logs) logger calls"
for args in --enable "" "--disable --enable"; do
  read -ra a <<< "$args"
  run "$helpers/steamos-devkit-mode" "${a[@]}"
  (( r == 1 )) || fail "devkit-mode '$args': exit $r, want 1"
  [[ $(cat "$tmp/log") == "-t steamos-devkit-mode devkit mode refused" ]] || fail "devkit-mode '$args': logged $(cat "$tmp/log")"
done

run "$tree/usr/bin/steamos-mandatory-update" check
(( r == 7 )) || fail "steamos-mandatory-update check: exit $r, want 7"
run "$tree/usr/bin/steamos-mandatory-update" check --supports-duplicate-detection
(( r == 0 )) || fail "steamos-mandatory-update --supports-duplicate-detection: exit $r, want 0"
run "$tree/usr/bin/jupiter-initial-firmware-update" check
(( r == 0 )) || fail "jupiter-initial-firmware-update check: exit $r, want 0"

if command -v udevadm > /dev/null; then
  udevadm verify --no-summary "$tree/usr/lib/udev/rules.d/60-microos-backlight.rules" || fail "backlight rules do not verify"
else
  fail "udevadm missing, backlight rules unchecked"
fi

if (( rc == 0 )); then
  echo "helpers: ok"
fi
exit "$rc"
