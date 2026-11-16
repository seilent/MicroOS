#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
mod=$tree/usr/lib/dracut/modules.d/92microos-y700-guard
guard=$mod/microos-guard
initrdlog=$mod/microos-initrd-log
mtest=$tree/usr/libexec/microos/microos-test
mfail=$tree/usr/libexec/microos/microos-fail
efilog=$tree/usr/libexec/microos/microos-efi-log
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

export FAKE_STATE=$tmp/fake PATH=$here/guard/bin:$PATH MICROOS_SDAM_LIB=$tree/usr/libexec/microos/microos-sdam
export MICROOS_BOOTB_LIB=$tree/usr/libexec/microos/microos-bootb MICROOS_BOOT_B=$tmp/dev/sde37 MICROOS_BOOT_A=$tmp/dev/sde36
export MICROOS_CLASS_BLOCK=$tmp/sysfs/class/block
mkdir -p "$tmp/dev" "$MICROOS_CLASS_BLOCK"
for p in sde/sde36 sde/sde37 sdf/sdf1; do
  mkdir -p "$tmp/sysfs/devices/$p"
  ln -s "../../devices/$p" "$MICROOS_CLASS_BLOCK/${p#*/}"
  : > "$tmp/dev/${p#*/}"
done
id=0123456789ab
nv=$tmp/nvmem
efi=$tmp/efi

reset() {
  rm -rf "$nv" "$efi" "$FAKE_STATE" "$tmp/run"
  mkdir -p "$nv/spmi_sdam0" "$nv/spmi_sdam1" "$tmp/dt/pmic@0/nvram@7000" "$tmp/dt/pmic@0/nvram@7100" "$efi" "$FAKE_STATE"
  head -c 256 /dev/zero > "$nv/spmi_sdam0/nvmem"
  head -c 256 /dev/zero > "$nv/spmi_sdam1/nvmem"
  ln -s "$tmp/dt/pmic@0/nvram@7000" "$nv/spmi_sdam0/of_node"
  ln -s "$tmp/dt/pmic@0/nvram@7100" "$nv/spmi_sdam1/of_node"
}
cmdline() { echo "root=PARTLABEL=microos rootwait ro init=/init $* microos.id=$id" > "$tmp/cmdline"; }
noid() { echo "root=PARTLABEL=microos $*" > "$tmp/cmdline"; }
run_guard() {
  env MICROOS_CMDLINE="$tmp/cmdline" MICROOS_EFI_DIR="$efi" MICROOS_NVMEM_ROOT="$nv" MICROOS_INITRD_ID="$tmp/initrd-id" \
    MICROOS_SLOT_CONF="${GUARD_CONF:-$tree/usr/lib/microos/slot.conf}" sh "$guard" 2> "$tmp/guard.err"
}
preset_of() { od -An -tx1 -j72 -N1 "$nv/$1/nvmem" | tr -d ' \n'; }
nonzero() { tr -d '\0' < "$nv/$1/nvmem" | wc -c; }
attempts() { cat "$efi/microos/boot-attempts" 2> /dev/null || echo none; }
echo "7.2.12-microos 20261111T000000Z" > "$tmp/initrd-id"

for w in "" 1 noguard bootloader panic emergency wdhang gptdump; do
  name=${w:-production}
  reset
  cmdline ${w:+microos.test=$w}
  run_guard || fail "guard $name: exit $?: $(cat "$tmp/guard.err")"
  if [[ $w == 1 ]]; then
    [[ $(preset_of spmi_sdam1) == 04 && $(nonzero spmi_sdam1) == 1 ]] || fail "guard 1: preset byte $(preset_of spmi_sdam1)"
  else
    [[ $(nonzero spmi_sdam1) == 0 ]] || fail "guard $name wrote the preset"
  fi
  [[ $(nonzero spmi_sdam0) == 0 ]] || fail "guard $name wrote another SDAM"
  if [[ $w == noguard || $w == gptdump ]]; then
    [[ $(attempts) == none ]] || fail "guard $name counted: $(attempts)"
  else
    [[ $(attempts) == "$id 1" ]] || fail "guard $name count: $(attempts)"
  fi
  [[ $(tail -n 1 "$efi/logs/guard.txt") == "initrd=7.2.12-microos 20261111T000000Z id=$id test=${w:-none} count="* ]] \
    || fail "guard $name log: $(tail -n 1 "$efi/logs/guard.txt")"
done

reset
cmdline
run_guard
run_guard
[[ $(attempts) == "$id 2" ]] || fail "second boot count: $(attempts)"
cmdline microos.test=noguard
run_guard
[[ $(attempts) == "$id 2" ]] || fail "noguard changed the count: $(attempts)"
echo "aaaaaaaaaaaa 7" > "$efi/microos/boot-attempts"
cmdline
run_guard
[[ $(attempts) == "$id 1" ]] || fail "another id did not start at 0: $(attempts)"
echo "$id x" > "$efi/microos/boot-attempts"
run_guard
[[ $(attempts) == "$id 1" ]] || fail "a bad count did not start at 0: $(attempts)"
noid
run_guard || fail "guard without microos.id failed"
[[ $(attempts) == "$id 1" ]] || fail "boot without microos.id counted: $(attempts)"
for i in $(seq 1 210); do echo "line $i"; done > "$efi/logs/guard.txt"
cmdline
run_guard
(( $(wc -l < "$efi/logs/guard.txt") == 200 )) || fail "guard.txt not trimmed to 200 lines"

reset
printf '\001' | dd of="$nv/spmi_sdam1/nvmem" bs=1 seek=72 conv=notrunc status=none
cmdline microos.test=1
run_guard || fail "guard 1 with bit 0 set: $(cat "$tmp/guard.err")"
[[ $(preset_of spmi_sdam1) == 05 && $(nonzero spmi_sdam1) == 1 ]] || fail "guard 1 with bit 0 set: preset byte $(preset_of spmi_sdam1)"

reset
rm "$nv/spmi_sdam1/of_node"
cmdline microos.test=1
run_guard || fail "guard 1 without the SDAM failed"
[[ $(cat "$tmp/guard.err") == *"no fastboot preset"* ]] || fail "missing SDAM not reported: $(cat "$tmp/guard.err")"
[[ $(nonzero spmi_sdam0) == 0 && $(nonzero spmi_sdam1) == 0 ]] || fail "guard 1 wrote an SDAM with no nvram@7100 node"
[[ $(attempts) == "$id 1" ]] || fail "guard 1 without the SDAM did not count"

P=aaaaaaaaaaaa
full=100663296
hdr() {
  printf 'ANDROID!' | dd of="$1" bs=1 conv=notrunc status=none
  printf '\002' | dd of="$1" bs=1 seek=40 conv=notrunc status=none
  printf 'root=PARTLABEL=microos microos.id=%s' "$2" | dd of="$1" bs=1 seek=64 conv=notrunc status=none
}
previmg() {
  local img=$efi/microos/boot-prev.img
  mkdir -p "$efi/microos"
  rm -f "$img" "$MICROOS_BOOT_B"
  truncate -s "${4:-$full}" "$img"
  hdr "$img" "$P"
  head -c 65536 /dev/urandom | dd of="$img" bs=65536 seek=16 conv=notrunc status=none
  echo "${1:-$P} $(sha256sum < "$img" | cut -d' ' -f1)" > "$efi/microos/boot-prev.id"
  truncate -s "${3:-$full}" "$MICROOS_BOOT_B"
  hdr "$MICROOS_BOOT_B" "${2:-$id}"
  cp "$MICROOS_BOOT_B" "$tmp/boot_b.before"
}
notrestored() {
  [[ $(tail -n 1 "$efi/logs/guard.txt") == "$2" ]] || fail "$1: guard.txt $(tail -n 1 "$efi/logs/guard.txt")"
}
restarts() { cat "$FAKE_STATE/systemctl.log" 2> /dev/null | grep -c '^systemctl --no-block reboot$' || true; }
restored() {
  [[ $(sha256sum < "$MICROOS_BOOT_B") == $(sha256sum < "$efi/microos/boot-prev.img") ]] || fail "$1: boot_b is not boot-prev.img"
  [[ $(attempts) == "$P 0" ]] || fail "$1: count $(attempts)"
  [[ $(tail -n 1 "$efi/logs/guard.txt") == "restored $P from boot-prev.img to $MICROOS_BOOT_B after $2 starts of $id" ]] \
    || fail "$1: guard.txt $(tail -n 1 "$efi/logs/guard.txt")"
  [[ $(restarts) == 1 ]] || fail "$1: $(restarts) reboots"
}
kept() {
  [[ $(sha256sum < "$MICROOS_BOOT_B") == $(sha256sum < "$tmp/boot_b.before") ]] || fail "$1: boot_b changed"
  [[ $(attempts) == "$id $2" ]] || fail "$1: count $(attempts)"
  [[ $(restarts) == 0 ]] || fail "$1: rebooted"
}
reset
cmdline
previmg
echo "$id 2" > "$efi/microos/boot-attempts"
run_guard || fail "restore: exit $?: $(cat "$tmp/guard.err")"
restored "restore at 3" 3
reset
cmdline
previmg
echo "$id 5" > "$efi/microos/boot-attempts"
run_guard || fail "restore at 6: exit $?: $(cat "$tmp/guard.err")"
restored "restore at 6" 6
reset
cmdline
previmg
echo "$id 1" > "$efi/microos/boot-attempts"
run_guard
kept "count 2 with a valid prev" 2
printf 'MICROOS_SLOT_WRITE=1\nMICROOS_BOOT_TRIES=5\n' > "$tmp/tries5.conf"
for c in "2 3 kept" "3 4 kept" "4 5 restored"; do
  read -r before now what <<< "$c"
  reset
  cmdline
  previmg
  echo "$id $before" > "$efi/microos/boot-attempts"
  GUARD_CONF=$tmp/tries5.conf run_guard
  if [[ $what == kept ]]; then
    kept "MICROOS_BOOT_TRIES=5 at count $now" "$now"
  else
    restored "MICROOS_BOOT_TRIES=5 at count $now" "$now"
  fi
done
reset
cmdline
previmg
printf 'x' | dd of="$efi/microos/boot-prev.img" bs=1 seek=4096 conv=notrunc status=none
echo "$id 2" > "$efi/microos/boot-attempts"
run_guard
kept "prev with a bad sha256" 3
reset
cmdline
previmg "$id"
echo "$id 2" > "$efi/microos/boot-attempts"
run_guard
kept "prev naming the running id" 3
reset
cmdline microos.test=noguard
previmg
echo "$id 5" > "$efi/microos/boot-attempts"
run_guard
kept "noguard with a valid prev" 5
reset
cmdline
previmg "$P" "$id" 1048576
echo "$id 2" > "$efi/microos/boot-attempts"
run_guard || fail "restore onto a smaller boot_b: exit $?"
kept "restore onto a smaller boot_b" 3
notrestored "smaller boot_b" "boot_b or boot-prev.img is not $full bytes, boot-prev.img not restored"
reset
cmdline
previmg "$P" "$id" "$full" $(( full + 4096 ))
echo "$id 2" > "$efi/microos/boot-attempts"
run_guard
kept "larger boot-prev.img" 3
notrestored "larger boot-prev.img" "boot_b or boot-prev.img is not $full bytes, boot-prev.img not restored"
reset
cmdline
previmg "$P" bbbbbbbbbbbb
echo "$id 2" > "$efi/microos/boot-attempts"
run_guard
kept "RAM boot while boot_b holds another image" 3
notrestored "RAM boot" "boot_b holds bbbbbbbbbbbb, not $id, boot-prev.img not restored"
reset
cmdline
previmg
echo "$id 2" > "$efi/microos/boot-attempts"
MICROOS_BOOT_A=$tmp/dev/sdf1 run_guard
kept "boot_a on another disk" 3
notrestored "boot_a on another disk" "boot_b is not on the boot_a disk, boot-prev.img not restored"
reset
cmdline
previmg
echo "$id 2" > "$efi/microos/boot-attempts"
MICROOS_CLASS_BLOCK=$tmp/nosys run_guard
kept "no sysfs entry for boot_b" 3
reset
cmdline microos.test=1
previmg
echo "$id 2" > "$efi/microos/boot-attempts"
run_guard || fail "restore on a test image: exit $?: $(cat "$tmp/guard.err")"
restored "restore on a test image" 3
[[ $(preset_of spmi_sdam1) == 00 ]] || fail "restore on a test image kept the preset: $(preset_of spmi_sdam1)"
reset
cmdline microos.test=1
mkdir -p "$efi/microos"
rm -f "$MICROOS_BOOT_B"
truncate -s "$full" "$MICROOS_BOOT_B"
hdr "$MICROOS_BOOT_B" "$id"
cp "$MICROOS_BOOT_B" "$tmp/boot_b.before"
echo "$id 2" > "$efi/microos/boot-attempts"
run_guard
kept "test image with no prev" 3
[[ $(preset_of spmi_sdam1) == 04 ]] || fail "test image with no prev lost the preset: $(preset_of spmi_sdam1)"

once() {
  reset
  cmdline microos.test=once
  previmg "$@"
  rm -f "$FAKE_STATE/dd.log"
}
reset
cmdline microos.test=once
run_guard || fail "once with no prev: exit $?: $(cat "$tmp/guard.err")"
[[ $(attempts) == "$id 1" && $(nonzero spmi_sdam1) == 0 && $(restarts) == 0 ]] \
  || fail "once with no prev: $(attempts), preset $(preset_of spmi_sdam1), $(restarts) reboots"
once
printf '\004' | dd of="$nv/spmi_sdam1/nvmem" bs=1 seek=72 conv=notrunc status=none
rm -f "$FAKE_STATE/dd.log"
run_guard || fail "once restore: exit $?: $(cat "$tmp/guard.err")"
[[ $(sha256sum < "$MICROOS_BOOT_B") == $(sha256sum < "$efi/microos/boot-prev.img") ]] || fail "once restore: boot_b is not boot-prev.img"
[[ $(attempts) == "$P 0" && $(restarts) == 0 ]] || fail "once restore: $(attempts), $(restarts) reboots"
[[ $(tail -n 1 "$efi/logs/guard.txt") == "once: restored $P to boot_b at start 1 of $id" ]] \
  || fail "once restore: guard.txt $(tail -n 1 "$efi/logs/guard.txt")"
[[ $(preset_of spmi_sdam1) == 00 ]] || fail "once restore kept the preset: $(preset_of spmi_sdam1)"
[[ $(sed -n '$p' "$FAKE_STATE/dd.log") == "dd of=nvmem" && $(grep -c 'of=boot_b' "$FAKE_STATE/dd.log") == 3 &&
  $(grep -n 'of=nvmem' "$FAKE_STATE/dd.log" | head -n 1 | cut -d: -f1) == 4 ]] \
  || fail "once restore: SDAM clear before the boot_b write: $(cat "$FAKE_STATE/dd.log")"
once
echo "$id 4" > "$efi/microos/boot-attempts"
run_guard
[[ $(tail -n 1 "$efi/logs/guard.txt") == "once: restored $P to boot_b at start 5 of $id" && $(restarts) == 0 ]] \
  || fail "once restore at 5: guard.txt $(tail -n 1 "$efi/logs/guard.txt"), $(restarts) reboots"
once "$P" bbbbbbbbbbbb
run_guard
kept "once RAM boot" 1
notrestored "once RAM boot" "once: boot_b holds bbbbbbbbbbbb, not $id, boot-prev.img not restored"
once
printf 'x' | dd of="$efi/microos/boot-prev.img" bs=1 seek=4096 conv=notrunc status=none
run_guard
kept "once prev with a bad sha256" 1
notrestored "once prev with a bad sha256" "once: boot-prev.img is missing, does not match boot-prev.id or names $id, not restored"
once "$id"
run_guard
kept "once prev naming the running id" 1
notrestored "once prev naming the running id" "once: boot-prev.img is missing, does not match boot-prev.id or names $id, not restored"
once
FAKE_DD_FAIL=1 run_guard || fail "once failed write: exit $?"
kept "once failed write" 1
notrestored "once failed write" "once: restore of $P from boot-prev.img to $MICROOS_BOOT_B failed"
[[ $(grep -c 'of=boot_b' "$FAKE_STATE/dd.log") == 2 && $(nonzero spmi_sdam1) == 0 ]] \
  || fail "once failed write: $(cat "$FAKE_STATE/dd.log"), preset $(preset_of spmi_sdam1)"

reset
cmdline
if env MICROOS_CMDLINE="$tmp/cmdline" MICROOS_EFI_DEV="$tmp/missing" MICROOS_NVMEM_ROOT="$nv" sh "$guard" 2> /dev/null; then
  fail "guard passed without microos_efi"
fi

mkdir -p "$efi/logs"
for i in 1 2 3 4 5 6 7 8; do : > "$efi/logs/initrd-$i.txt"; done
MICROOS_EFI_DIR=$efi sh "$initrdlog" || fail "initrd log failed"
[[ -s $efi/logs/initrd-9.txt && ! -e $efi/logs/initrd-1.txt && -e $efi/logs/initrd-2.txt ]] \
  || fail "initrd log rotation: $(ls "$efi/logs" | tr '\n' ' ')"

sysblock=$tmp/sys/block
devdir=$tmp/dev
platform=$tmp/platform
mkdir -p "$sysblock/sda/queue" "$sysblock/sdb/queue" "$devdir" "$platform/soc@0/1d84000.ufshc/attributes"
echo 4096 > "$sysblock/sda/queue/logical_block_size"
echo 160 > "$sysblock/sda/size"
echo 512 > "$sysblock/sdb/queue/logical_block_size"
echo 40 > "$sysblock/sdb/size"
for i in $(seq 0 19); do printf "%-4096s" "sda$i"; done > "$devdir/sda"
for i in $(seq 0 39); do printf "%-512s" "sdb$i"; done > "$devdir/sdb"
echo 2 > "$platform/soc@0/1d84000.ufshc/attributes/boot_lun_enabled"
run_test() {
  env MICROOS_EFI="$efi" MICROOS_SYSBLOCK="$sysblock" MICROOS_DEVDIR="$devdir" MICROOS_PLATFORM="$platform" \
    MICROOS_SYSRQ="$tmp/sysrq" MICROOS_WATCHDOG="$tmp/watchdog" "$mtest" "$1" > /dev/null 2>&1
}
for w in bootloader panic emergency wdhang gptdump; do
  reset
  rm -f "$tmp/sysrq" "$tmp/watchdog"
  r=0
  run_test "$w" || r=$?
  [[ $(nonzero spmi_sdam0) == 0 && $(nonzero spmi_sdam1) == 0 ]] || fail "case $w wrote the preset"
  log=$(cat "$FAKE_STATE/systemctl.log" 2> /dev/null || true)
  case $w in
    bootloader) [[ $log == "systemctl reboot --reboot-argument=bootloader" ]] || fail "case bootloader: $log" ;;
    panic) [[ $(cat "$tmp/sysrq") == c && $r != 0 ]] || fail "case panic: sysrq $(cat "$tmp/sysrq" 2> /dev/null), exit $r" ;;
    emergency) [[ $log == "systemctl --no-block start emergency.target" ]] || fail "case emergency: $log" ;;
    wdhang)
      [[ $(cat "$FAKE_STATE/sleep.log") == "sleep infinity fd3=$tmp/watchdog" ]] || fail "case wdhang: $(cat "$FAKE_STATE/sleep.log")"
      [[ ! -s $tmp/watchdog ]] || fail "case wdhang wrote to the watchdog"
      ;;
    gptdump)
      d=$efi/logs/gpt-1
      [[ $log == "systemctl reboot" ]] || fail "case gptdump: $log"
      [[ $(sha256sum < "$d/sda-primary.bin") == $(head -c $((6 * 4096)) "$devdir/sda" | sha256sum) ]] || fail "sda primary"
      [[ $(sha256sum < "$d/sda-backup.bin") == $(tail -c $((5 * 4096)) "$devdir/sda" | sha256sum) ]] || fail "sda backup"
      [[ $(sha256sum < "$d/sdb-primary.bin") == $(head -c $((6 * 512)) "$devdir/sdb" | sha256sum) ]] || fail "sdb primary"
      [[ $(sha256sum < "$d/sdb-backup.bin") == $(tail -c $((5 * 512)) "$devdir/sdb" | sha256sum) ]] || fail "sdb backup"
      [[ $(cat "$d/boot_lun_enabled.txt") == "soc@0/1d84000.ufshc/attributes/boot_lun_enabled 2" ]] || fail "boot_lun_enabled: $(cat "$d/boot_lun_enabled.txt")"
      [[ $(cat "$d/disks.txt") == $'sda logical_block_size=4096 blocks=20\nsdb logical_block_size=512 blocks=40' ]] || fail "disks.txt: $(cat "$d/disks.txt")"
      (cd "$d" && sha256sum -c --quiet SHA256SUMS) || fail "gpt SHA256SUMS"
      run_test gptdump
      [[ -d $efi/logs/gpt-2 ]] || fail "second gptdump did not use gpt-2"
      ;;
  esac
done

slotconf=$tmp/slot.conf
run_fail() {
  env MICROOS_EFI="$efi" MICROOS_RUNDIR="$tmp/run" MICROOS_CMDLINE="$tmp/cmdline" MICROOS_SLOT_CONF="$slotconf" \
    MICROOS_EFI_LOG="$efilog" MICROOS_NVMEM_ROOT="$nv" "$mfail" "$@" > /dev/null 2> "$tmp/fail.err"
}
reboots() { cat "$FAKE_STATE/systemctl.log" 2> /dev/null | grep -c '^systemctl reboot$' || true; }
bootloader_reboots() { cat "$FAKE_STATE/systemctl.log" 2> /dev/null | grep -c '^systemctl reboot --reboot-argument=bootloader$' || true; }
reset
cmdline
mkdir -p "$efi/microos"
printf 'MICROOS_SLOT_WRITE=1\nMICROOS_BOOT_TRIES=3\n' > "$slotconf"
echo "$id 3" > "$efi/microos/boot-attempts"
mkdir -p "$tmp/run"
echo "$id" > "$tmp/run/boot-confirmed"
run_fail deadline || fail "deadline after boot ok failed"
[[ $(reboots) == 0 ]] || fail "deadline acted on a confirmed boot"
rm "$tmp/run/boot-confirmed"
run_fail deadline
[[ $(cat "$tmp/fail.err") == *"no $tmp/run/boot-confirmed"* ]] || fail "deadline reason: $(cat "$tmp/fail.err")"
[[ $(reboots) == 1 && $(attempts) == "$id 3" ]] || fail "deadline at 3 tries: reboots $(reboots), $(attempts)"
[[ $(cat "$tmp/fail.err") == *"plain reboot, the ABL retry budget decides"* ]] || fail "deadline at 3 tries: $(cat "$tmp/fail.err")"
[[ $(cat "$efi/logs/deadline-1.txt") == "journal of this boot" ]] || fail "deadline log"
reset
cmdline
mkdir -p "$efi/microos"
echo "$id 2" > "$efi/microos/boot-attempts"
run_fail deadline
[[ $(reboots) == 1 && $(attempts) == "$id 2" ]] || fail "deadline at 2 tries"
echo "$id 3" > "$efi/microos/boot-attempts"
for w in 0 1; do
  printf 'MICROOS_SLOT_WRITE=%s\nMICROOS_BOOT_TRIES=3\n' "$w" > "$slotconf"
  run_fail emergency
done
[[ $(reboots) == 3 && $(bootloader_reboots) == 0 && $(attempts) == "$id 3" && $(nonzero spmi_sdam1) == 0 ]] \
  || fail "production image at 3 tries: reboots $(reboots), bootloader $(bootloader_reboots), preset $(preset_of spmi_sdam1)"
[[ -s $efi/logs/emergency-1.txt ]] || fail "emergency log"
rm -f "$FAKE_STATE/systemctl.log"
cmdline microos.test=1
printf 'MICROOS_SLOT_WRITE=0\nMICROOS_BOOT_TRIES=3\n' > "$slotconf"
run_fail emergency
[[ $(reboots) == 0 && $(bootloader_reboots) == 1 && $(attempts) == "$id 3" && $(preset_of spmi_sdam1) == 04 ]] \
  || fail "test image with slot writes off: reboots $(reboots), bootloader $(bootloader_reboots), preset $(preset_of spmi_sdam1)"
printf '\000' | dd of="$nv/spmi_sdam1/nvmem" bs=1 seek=72 conv=notrunc status=none
printf 'MICROOS_SLOT_WRITE=1\nMICROOS_BOOT_TRIES=3\n' > "$slotconf"
run_fail emergency
[[ $(reboots) == 0 && $(bootloader_reboots) == 2 && $(preset_of spmi_sdam1) == 04 ]] \
  || fail "test image with slot writes on: reboots $(reboots), bootloader $(bootloader_reboots), preset $(preset_of spmi_sdam1)"
rm "$nv/spmi_sdam1/of_node"
printf '\000' | dd of="$nv/spmi_sdam1/nvmem" bs=1 seek=72 conv=notrunc status=none
run_fail emergency
[[ $(bootloader_reboots) == 2 && $(reboots) == 1 && $(cat "$tmp/fail.err") == *"no fastboot preset"* ]] || fail "no SDAM: bootloader $(bootloader_reboots), plain $(reboots): $(cat "$tmp/fail.err")"
ln -s "$tmp/dt/pmic@0/nvram@7100" "$nv/spmi_sdam1/of_node"
echo "bbbbbbbbbbbb 5" > "$efi/microos/boot-attempts"
run_fail emergency
[[ $(bootloader_reboots) == 2 && $(reboots) == 2 ]] || fail "another id's count acted: bootloader $(bootloader_reboots)"

for w in 1 0; do
  for t in "" 1; do
    name="valid prev, slot writes $w, test ${t:-none}"
    reset
    cmdline ${t:+microos.test=$t}
    previmg
    echo "$id 3" > "$efi/microos/boot-attempts"
    printf '\004' | dd of="$nv/spmi_sdam1/nvmem" bs=1 seek=72 conv=notrunc status=none
    printf 'MICROOS_SLOT_WRITE=%s\nMICROOS_BOOT_TRIES=3\n' "$w" > "$slotconf"
    run_fail emergency
    [[ $(reboots) == 1 && $(bootloader_reboots) == 0 && $(attempts) == "$id 3" ]] \
      || fail "$name: reboots $(reboots), bootloader $(bootloader_reboots), $(attempts)"
    [[ $(cat "$tmp/fail.err") == *"boot-prev.img holds $P, the guard restores it on the next start"* ]] || fail "$name: $(cat "$tmp/fail.err")"
    if [[ -n $t ]]; then
      [[ $(preset_of spmi_sdam1) == 00 ]] || fail "$name: preset $(preset_of spmi_sdam1)"
    else
      [[ $(preset_of spmi_sdam1) == 04 ]] || fail "$name: preset touched $(preset_of spmi_sdam1)"
    fi
  done
done
for c in "self 1 1" "bad 1 0" "self 0 1" "bad 0 0" "held 1 0" "size 1 0" "held 0 1" "size 0 1" "disk 1 0" "disk 0 1"; do
  read -r kind w t <<< "$c"
  name="prev $kind, slot writes $w, test $t"
  reset
  if [[ $t == 1 ]]; then cmdline microos.test=1; else cmdline; fi
  if [[ $kind == self ]]; then
    previmg "$id"
  elif [[ $kind == held ]]; then
    previmg "$P" bbbbbbbbbbbb
  elif [[ $kind == size ]]; then
    previmg "$P" "$id" "$full" $(( full + 4096 ))
  elif [[ $kind == disk ]]; then
    previmg
  else
    previmg
    printf 'x' | dd of="$efi/microos/boot-prev.img" bs=1 seek=4096 conv=notrunc status=none
  fi
  echo "$id 3" > "$efi/microos/boot-attempts"
  printf 'MICROOS_SLOT_WRITE=%s\nMICROOS_BOOT_TRIES=3\n' "$w" > "$slotconf"
  if [[ $kind == disk ]]; then
    MICROOS_BOOT_A=$tmp/dev/sdf1 run_fail emergency
  else
    run_fail emergency
  fi
  [[ $(cat "$tmp/fail.err") != *"the guard restores it"* && $(attempts) == "$id 3" ]] || fail "$name: $(attempts): $(cat "$tmp/fail.err")"
  if [[ $t == 1 ]]; then
    [[ $(bootloader_reboots) == 1 && $(preset_of spmi_sdam1) == 04 ]] || fail "$name: bootloader $(bootloader_reboots), preset $(preset_of spmi_sdam1)"
  else
    [[ $(reboots) == 1 && $(bootloader_reboots) == 0 && $(nonzero spmi_sdam1) == 0 ]] || fail "$name: reboots $(reboots), preset $(preset_of spmi_sdam1)"
  fi
done

for p in valid none; do
  name="once image at 3 tries, prev $p"
  reset
  cmdline microos.test=once
  if [[ $p == valid ]]; then
    previmg
  else
    mkdir -p "$efi/microos"
  fi
  echo "$id 3" > "$efi/microos/boot-attempts"
  printf 'MICROOS_SLOT_WRITE=1\nMICROOS_BOOT_TRIES=3\n' > "$slotconf"
  run_fail emergency
  [[ $(reboots) == 1 && $(bootloader_reboots) == 0 && $(nonzero spmi_sdam1) == 0 ]] \
    || fail "$name: reboots $(reboots), bootloader $(bootloader_reboots), preset $(preset_of spmi_sdam1): $(cat "$tmp/fail.err")"
done

own=$tmp/own
mkdir -p "$own/usr/libexec/microos" "$own/usr/lib/microos"
for f in microos-fail microos-efi-log microos-sdam microos-bootb; do
  cp "$tree/usr/libexec/microos/$f" "$own/usr/libexec/microos/"
done
printf '#!/usr/bin/env bash\necho "own microos-slot $*" >> "$FAKE_STATE/slot.log"\n' > "$own/usr/libexec/microos/microos-slot"
chmod 755 "$own/usr/libexec/microos/microos-slot"
for n in 5 3; do
  reset
  cmdline microos.test=1
  mkdir -p "$efi/microos" "$tmp/run"
  echo "$id 3" > "$efi/microos/boot-attempts"
  printf 'MICROOS_SLOT_WRITE=1\nMICROOS_BOOT_TRIES=%s\n' "$n" > "$own/usr/lib/microos/slot.conf"
  env -u MICROOS_SDAM_LIB -u MICROOS_BOOTB_LIB MICROOS_EFI="$efi" MICROOS_RUNDIR="$tmp/run" MICROOS_CMDLINE="$tmp/cmdline" \
    MICROOS_NVMEM_ROOT="$nv" MICROOS_SDAM_TRIES=1 "$own/usr/libexec/microos/microos-fail" emergency > /dev/null 2> "$tmp/fail.err"
  [[ -s $efi/logs/emergency-1.txt ]] || fail "own tree, tries $n: no log from its microos-efi-log"
  [[ ! -e $FAKE_STATE/slot.log && $(attempts) == "$id 3" ]] || fail "own tree, tries $n: slot $(cat "$FAKE_STATE/slot.log" 2> /dev/null)"
  if [[ $n == 5 ]]; then
    [[ $(reboots) == 1 && $(bootloader_reboots) == 0 && $(nonzero spmi_sdam1) == 0 ]] \
      || fail "own tree, tries 5: reboots $(reboots), bootloader $(bootloader_reboots): $(cat "$tmp/fail.err")"
  else
    [[ $(bootloader_reboots) == 1 && $(preset_of spmi_sdam1) == 04 ]] \
      || fail "own tree, tries 3: bootloader $(bootloader_reboots), preset $(preset_of spmi_sdam1): $(cat "$tmp/fail.err")"
  fi
done

reset
mkdir -p "$efi/logs"
for i in $(seq 1 9); do : > "$efi/logs/boot-$i.txt"; done
log() { env MICROOS_EFI="$efi" MICROOS_RUNDIR="$tmp/run" "$efilog" boot; }
[[ $(log) == "$efi/logs/boot-10.txt" ]] || fail "boot log number"
[[ $(log) == "$efi/logs/boot-10.txt" ]] || fail "boot log of the same boot moved"
[[ $(ls "$efi/logs" | sort -V | tr '\n' ' ') == "boot-3.txt boot-4.txt boot-5.txt boot-6.txt boot-7.txt boot-8.txt boot-9.txt boot-10.txt " ]] \
  || fail "boot logs kept: $(ls "$efi/logs" | tr '\n' ' ')"

if (( rc == 0 )); then
  echo "guard: ok"
fi
exit "$rc"
