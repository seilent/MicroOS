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

hw=$tmp/hw
mkdir -p "$hw" "$tmp/sbin" "$tmp/ssys/block" "$tmp/class"
cat > "$tmp/storage" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == classify ]]; then
  cat "$CLASS_DIR/$2" 2>/dev/null
  exit 0
fi
printf '%q ' "$@" >> "$STORAGE_LOG"
echo >> "$STORAGE_LOG"
exit "$STORAGE_RC"
EOF
cat > "$tmp/sbin/pkexec" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$PKEXEC_LOG"
echo >> "$PKEXEC_LOG"
exit "$STORAGE_RC"
EOF
cat > "$tmp/sbin/id" <<'EOF'
#!/usr/bin/env bash
case $1 in
  -u) echo "$ID_U" ;;
  -g) echo "$ID_G" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/storage" "$tmp/sbin/pkexec" "$tmp/sbin/id"
for f in format-device.sh format-sdcard.sh trim-devices.sh; do
  sed "s|/usr/libexec/microos/microos-storage|$tmp/storage|" "$tree/usr/lib/hwsupport/$f" > "$hw/$f"
done
for f in steamos-format-device steamos-format-sdcard steamos-trim-devices; do
  sed "s|/usr/lib/hwsupport/|$hw/|" "$helpers/$f" > "$hw/$f"
done
chmod +x "$hw"/*

srun() {
  local want=$1 uid=$2
  shift 2
  : > "$tmp/slog"
  : > "$tmp/plog"
  r=0
  env -i PATH="$tmp/sbin:/usr/bin:/bin" STORAGE_LOG="$tmp/slog" PKEXEC_LOG="$tmp/plog" STORAGE_RC="$want" \
    CLASS_DIR="$tmp/class" MICROOS_SYSFS="$tmp/ssys" ID_U="$uid" ID_G=1000 "$@" > "$tmp/out" 2>&1 || r=$?
  (( r == want )) || fail "$*: exit $r, want $want: $(cat "$tmp/out")"
}
slog() { [[ $(< "$tmp/slog") == "$1" ]] || fail "$2: microos-storage got '$(< "$tmp/slog")', want '$1'"; }
plog() { [[ $(< "$tmp/plog") == "$1" ]] || fail "$2: pkexec got '$(< "$tmp/plog")', want '$1'"; }

for want in 0 2 5 13 14 16 19 22 32 53 77; do
  srun "$want" 0 "$hw/format-device.sh" --label "" --skip-validation --device /dev/mmcblk0
  slog "format --label '' --skip-validation --device /dev/mmcblk0 " "format-device.sh exit $want"
done
srun 1 0 "$hw/trim-devices.sh"
slog "trim " "trim-devices.sh"
srun 0 0 "$hw/trim-devices.sh" extra
slog "trim " "trim-devices.sh extra"

for d in mmcblk0 mmcblk1 mmcblk2 sda mmcblk0p1; do
  mkdir -p "$tmp/ssys/block/$d"
done
echo system > "$tmp/class/mmcblk0"
echo data > "$tmp/class/mmcblk1"
echo data > "$tmp/class/mmcblk2"
echo data > "$tmp/class/sda"
echo data > "$tmp/class/mmcblk0p1"
for want in 0 13 53 77; do
  srun "$want" 0 "$hw/format-sdcard.sh" --label "" --device /dev/mmcblk0
  slog "format --label '' --device /dev/mmcblk0 --device /dev/mmcblk1 " "format-sdcard.sh exit $want"
done
echo system > "$tmp/class/mmcblk1"
echo bogus > "$tmp/class/mmcblk2"
srun 19 0 "$hw/format-sdcard.sh"
slog "" "format-sdcard.sh with only system disks"
rm -rf "$tmp/ssys/block"/*
srun 19 0 "$hw/format-sdcard.sh"
slog "" "format-sdcard.sh with no card"

for want in 0 13 77 126; do
  srun "$want" 1000 "$hw/steamos-format-device" --label x --device /dev/mmcblk0
  plog "--disable-internal-agent /usr/bin/steamos-polkit-helpers/steamos-format-device --owner 1000:1000 --label x --device /dev/mmcblk0 " "steamos-format-device as micro"
  slog "" "steamos-format-device as micro"
  srun "$want" 1000 "$hw/steamos-format-sdcard" --skip-validation
  plog "--disable-internal-agent /usr/bin/steamos-polkit-helpers/steamos-format-sdcard --owner 1000:1000 --skip-validation " "steamos-format-sdcard as micro"
  srun "$want" 1000 "$hw/steamos-trim-devices"
  plog "--disable-internal-agent /usr/bin/steamos-polkit-helpers/steamos-trim-devices " "steamos-trim-devices as micro"
done

srun 53 0 "$hw/steamos-format-device" --owner 1000:1000 --label "" --device /dev/mmcblk0
plog "" "steamos-format-device as root"
slog "format --owner 1000:1000 --label '' --device /dev/mmcblk0 " "steamos-format-device as root"
srun 0 0 "$hw/steamos-trim-devices"
plog "" "steamos-trim-devices as root"
slog "trim " "steamos-trim-devices as root"
mkdir -p "$tmp/ssys/block/mmcblk0"
echo data > "$tmp/class/mmcblk0"
srun 14 0 "$hw/steamos-format-sdcard" --owner 1000:1000
plog "" "steamos-format-sdcard as root"
slog "format --owner 1000:1000 --device /dev/mmcblk0 " "steamos-format-sdcard as root"
echo system > "$tmp/class/mmcblk0"
srun 19 0 "$hw/steamos-format-sdcard" --owner 1000:1000
slog "" "steamos-format-sdcard as root with only system disks"

if command -v udevadm > /dev/null; then
  udevadm verify --no-summary "$tree/usr/lib/udev/rules.d/60-microos-backlight.rules" || fail "backlight rules do not verify"
else
  fail "udevadm missing, backlight rules unchecked"
fi

if (( rc == 0 )); then
  echo "helpers: ok"
fi
exit "$rc"
