#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script=$here/../build/android/microos-return.sh
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
same() { [[ $(sha256sum < "$1") == $(sha256sum < "$2") ]]; }

efi=$tmp/efi
export FAKE_STATE=$tmp/fake PATH=$here/android-return/bin:$PATH MICROOS_RETURN_EFI_DIR=$efi
export MICROOS_RETURN_BOOT_B=$tmp/boot_b MICROOS_RETURN_LOG=$tmp/return.log MICROOS_RETURN_SEEN=$tmp/seen
export MICROOS_RETURN_BOOT_ID=$tmp/boot_id MICROOS_RETURN_BOOTCTLS="$tmp/none $here/android-return/bin/bootctl"
full=100663296
T=0123456789ab
P=aaaaaaaaaaaa

hdr() {
  printf 'ANDROID!' | dd of="$1" bs=1 conv=notrunc status=none
  printf '\002' | dd of="$1" bs=1 seek=40 conv=notrunc status=none
  printf 'root=PARTLABEL=microos microos.id=%s microos.test=once' "$2" | dd of="$1" bs=1 seek=64 conv=notrunc status=none
}
truncate -s "$full" "$tmp/prev.img"
hdr "$tmp/prev.img" "$P"
head -c 65536 /dev/urandom | dd of="$tmp/prev.img" bs=65536 seek=16 conv=notrunc status=none
truncate -s "$full" "$tmp/test.img"
hdr "$tmp/test.img" "$T"
head -c 65536 /dev/urandom | dd of="$tmp/test.img" bs=65536 seek=32 conv=notrunc status=none

boots=0
reset() {
  rm -rf "$efi" "$FAKE_STATE" "$MICROOS_RETURN_LOG" "$MICROOS_RETURN_BOOT_B"
  mkdir -p "$efi/microos" "$FAKE_STATE"
  cp "$tmp/prev.img" "$efi/microos/boot-prev.img"
  echo "$P $(sha256sum < "$tmp/prev.img" | cut -d' ' -f1)" > "$efi/microos/boot-prev.id"
  echo "$T $P" > "$efi/microos/testboot.id"
  cp "$tmp/test.img" "$MICROOS_RETURN_BOOT_B"
  newboot
}
newboot() { boots=$((boots + 1)); echo "boot-$boots" > "$MICROOS_RETURN_BOOT_ID"; }
run() { sh "$script" > "$tmp/out" 2>&1 || fail "$1: exit $?: $(cat "$tmp/out")"; }
events() { cat "$FAKE_STATE/events" 2> /dev/null || true; }
untouched() {
  same "$MICROOS_RETURN_BOOT_B" "$tmp/test.img" || fail "$1: boot_b changed"
  [[ -z $(events) ]] || fail "$1: $(events)"
  [[ -z $2 ]] || grep -qF -- "$2" "$MICROOS_RETURN_LOG" || fail "$1: log $(cat "$MICROOS_RETURN_LOG" 2> /dev/null)"
}
writes() { events | grep -c '^dd ' || true; }

[[ -x $script ]] || fail "microos-return.sh is not executable"

reset
run "valid marker"
same "$MICROOS_RETURN_BOOT_B" "$tmp/prev.img" || fail "valid marker: boot_b is not boot-prev.img"
want="dd if=/dev/zero of=$MICROOS_RETURN_BOOT_B bs=4096 count=1 conv=notrunc,fsync
dd if=$efi/microos/boot-prev.img of=$MICROOS_RETURN_BOOT_B bs=4096 skip=1 seek=1 conv=notrunc,fsync
dd if=$efi/microos/boot-prev.img of=$MICROOS_RETURN_BOOT_B bs=4096 count=1 conv=notrunc,fsync
bootctl set-active-boot-slot 1
reboot "
[[ $(events) == "$want" ]] || fail "valid marker: order $(events)"
for l in "testboot.id: test $T, prev $P" "boot-prev.img holds $P, sha256 matches" "boot_b holds $P, read back matches" \
  "slot b active by $here/android-return/bin/bootctl, rebooting"; do
  grep -qF -- "$l" "$MICROOS_RETURN_LOG" || fail "valid marker: log lacks '$l': $(cat "$MICROOS_RETURN_LOG")"
done
: > "$FAKE_STATE/events"
cp "$tmp/test.img" "$MICROOS_RETURN_BOOT_B"
run "second run in the same boot"
untouched "second run in the same boot" ""

reset
rm "$efi/microos/testboot.id"
run "no marker"
untouched "no marker" ""
[[ ! -e $MICROOS_RETURN_LOG ]] || fail "no marker: log written $(cat "$MICROOS_RETURN_LOG")"

reset
hdr "$MICROOS_RETURN_BOOT_B" bbbbbbbbbbbb
cp "$MICROOS_RETURN_BOOT_B" "$tmp/other.img"
: > "$FAKE_STATE/events"
run "boot_b holds another id"
same "$MICROOS_RETURN_BOOT_B" "$tmp/other.img" && [[ -z $(events) ]] || fail "boot_b holds another id: $(events)"
grep -qF "boot_b holds bbbbbbbbbbbb, not the test image $T, nothing written" "$MICROOS_RETURN_LOG" \
  || fail "boot_b holds another id: log $(cat "$MICROOS_RETURN_LOG")"

reset
printf 'x' | dd of="$efi/microos/boot-prev.img" bs=1 seek=4096 conv=notrunc status=none
run "bad prev sha"
untouched "bad prev sha" "boot-prev.img does not match boot-prev.id, nothing written"

reset
echo "bbbbbbbbbbbb $(sha256sum < "$tmp/prev.img" | cut -d' ' -f1)" > "$efi/microos/boot-prev.id"
run "prev names another id"
untouched "prev names another id" "boot-prev.id names 'bbbbbbbbbbbb', not $P, nothing written"

reset
truncate -s $(( full + 4096 )) "$MICROOS_RETURN_BOOT_B"
cp "$MICROOS_RETURN_BOOT_B" "$tmp/big.img"
run "wrong boot_b size"
same "$MICROOS_RETURN_BOOT_B" "$tmp/big.img" && [[ -z $(events) ]] || fail "wrong boot_b size: $(events)"

reset
echo "nothex $P" > "$efi/microos/testboot.id"
run "bad marker"
untouched "bad marker" "testboot.id is not '<test id> <prev id>', nothing written"

reset
echo 1 > "$FAKE_STATE/sha-bad"
run "one readback mismatch"
same "$MICROOS_RETURN_BOOT_B" "$tmp/prev.img" || fail "one readback mismatch: boot_b is not boot-prev.img"
[[ $(writes) == 6 && $(events | grep -c '^bootctl ') == 1 && $(events | grep -c '^reboot') == 1 ]] \
  || fail "one readback mismatch: $(events)"

reset
echo 2 > "$FAKE_STATE/sha-bad"
run "two readback mismatches"
[[ $(writes) == 6 && -z $(events | grep -v '^dd ') ]] || fail "two readback mismatches: $(events)"
grep -qF "boot_b read back differs twice, stopped with Android up" "$MICROOS_RETURN_LOG" \
  || fail "two readback mismatches: log $(cat "$MICROOS_RETURN_LOG")"

reset
FAKE_BOOTCTL_RC=1 run "bootctl failure"
same "$MICROOS_RETURN_BOOT_B" "$tmp/prev.img" || fail "bootctl failure: boot_b is not boot-prev.img"
[[ $(events | grep -c '^bootctl ') == 1 && $(events | grep -c '^reboot') == 0 ]] || fail "bootctl failure: $(events)"
grep -qF "$here/android-return/bin/bootctl set-active-boot-slot 1 failed, Android stays up" "$MICROOS_RETURN_LOG" \
  || fail "bootctl failure: log $(cat "$MICROOS_RETURN_LOG")"

reset
printf '#!/usr/bin/env bash\necho "shipped $*" >> "$FAKE_STATE/events"\n' > "$tmp/shipped"
chmod 755 "$tmp/shipped"
MICROOS_RETURN_BOOTCTLS="$tmp/shipped $here/android-return/bin/bootctl" run "shipped bootctl first"
[[ $(events | grep -v '^dd ') == $'shipped set-active-boot-slot 1\nreboot ' ]] || fail "shipped bootctl first: $(events)"

reset
MICROOS_RETURN_BOOTCTLS="$tmp/none $tmp/none2" run "no bootctl"
same "$MICROOS_RETURN_BOOT_B" "$tmp/prev.img" || fail "no bootctl: boot_b is not boot-prev.img"
[[ -z $(events | grep -v '^dd ') ]] || fail "no bootctl: $(events)"
grep -qF "no bootctl in $tmp/none $tmp/none2, slot b not set, Android stays up" "$MICROOS_RETURN_LOG" \
  || fail "no bootctl: log $(cat "$MICROOS_RETURN_LOG")"

if (( rc == 0 )); then
  echo "android-return: ok"
fi
exit "$rc"
