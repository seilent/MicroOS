#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
tmp=$(realpath "$tmp")
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
same() { [[ $(sha256sum < "$1") == $(sha256sum < "$2") ]]; }
sha() { sha256sum < "$1" | cut -d' ' -f1; }

export FAKE_STATE=$tmp/fake MICROOS_SYSROOT=$tmp/sysroot MICROOS_ESP=$tmp/esp MICROOS_RUNDIR=$tmp/run
export MICROOS_STATEDIR=$tmp/state MICROOS_CMDLINE=$tmp/cmdline MICROOS_BOOT_B=$tmp/boot_b
export MICROOS_SLOT=$here/bootimg-update/bin/microos-slot PATH=$here/bootimg-update/bin:$PATH
export MICROOS_NVMEM_ROOT=$tmp/nvmem MICROOS_SDAM_TRIES=1
as=()
(( EUID == 0 )) || as=(unshare -r)

. "$tree/usr/lib/microos/stub.conf"
. "$tree/usr/lib/microos/bootimg.conf"
c() { local s; s=$(printf '%064d' 0); echo "${s//0/$1}"; }
A=$(c a).0
N=$(c b).0
RUN=0123456789ab
kver=7.2.12-microos
size=100663296
sys=$MICROOS_SYSROOT
ent=$sys/boot/loader/entries
panel=msm_drm.dsi_display0=qcom,mdss_dsi_kirby_nt36523_boe_dsc_vid:

t=$tmp/tree
mkdir -p "$t/usr/libexec/microos" "$t/usr/lib/microos/stub"
for f in microos-bootimg-update microos-stub-pack microos-bootb microos-sdam; do
  cp "$tree/usr/libexec/microos/$f" "$t/usr/libexec/microos/"
done
cp "$tree/usr/lib/microos/stub.conf" "$t/usr/lib/microos/stub/stub-preset-free.conf"
{ head -c 56 /dev/zero; printf 'ARMd'; head -c 4096 /dev/urandom; } > "$t/usr/lib/microos/stub/stub-preset-free.bin"
truncate -s "$(( MICROOS_STUB_PAYLOAD ))" "$t/usr/lib/microos/stub/stub-preset-free.bin"
tool=$t/usr/libexec/microos/microos-bootimg-update

le64() {
  local i
  for i in 0 1 2 3 4 5 6 7; do
    printf "\\$(printf %03o $(( ($1 >> (8 * i)) & 255 )))"
  done
}
le32() { printf "$(printf '\\x%02x' $(( $1 & 0xff )) $(( $1 >> 8 & 0xff )) $(( $1 >> 16 & 0xff )) $(( $1 >> 24 & 0xff )))"; }
put() { dd of="$1" bs=1 seek="$(( $2 ))" conv=notrunc status=none; }

deployment() {
  local id=$1 bc=$2 tag=$3 n=$4 d=$sys/ostree/deploy/default/deploy/$1
  mkdir -p "$d/usr/lib/microos" "$d/usr/libexec/microos" "$d/usr/share/microos/avb" "$d/usr/lib/modules/$kver/dtb/qcom" \
    "$d/usr/lib/modules/$kver/kernel/drivers" "$sys/ostree/boot.1/default/$bc" "$sys/boot/ostree/default-$bc" "$ent"
  cp "$tree/usr/lib/microos/bootimg.conf" "$tree/usr/lib/microos/stub.conf" "$d/usr/lib/microos/"
  cp "$tree/usr/libexec/microos/microos-bootimg-build" "$t"/usr/libexec/microos/* "$d/usr/libexec/microos/"
  cp -r "$t/usr/lib/microos/stub" "$d/usr/lib/microos/"
  cp "$tree/usr/share/microos/avb/testkey_rsa4096.pem" "$d/usr/share/microos/avb/"
  echo "IMAGE_VERSION=20261112.927c913" > "$d/usr/lib/microos/version"
  cp "$tmp/Image" "$d/usr/lib/modules/$kver/vmlinuz"
  cp "$tmp/Image" "$sys/boot/ostree/default-$bc/vmlinuz-$kver"
  { printf '\xd0\x0d\xfe\xed'; seq 1 500; echo "$tag"; } > "$d/usr/lib/modules/$kver/dtb/$MICROOS_DTB"
  echo "module a" > "$d/usr/lib/modules/$kver/kernel/drivers/a.ko.xz"
  echo "module b" > "$d/usr/lib/modules/$kver/kernel/drivers/b.ko"
  seq 1 50000 | sed "s/^/initrd $tag /" > "$sys/boot/ostree/default-$bc/initramfs-$kver.img"
  ln -sfn "../../../deploy/default/deploy/$id" "$sys/ostree/boot.1/default/$bc/0"
  printf 'title MicroOS %s\nversion 1\nlinux /boot/ostree/default-%s/vmlinuz-%s\ninitrd /boot/ostree/default-%s/initramfs-%s.img\noptions %s\n' \
    "$tag" "$bc" "$kver" "$bc" "$kver" "root=PARTLABEL=microos rw $(cat "$here/bootimg/kargs.txt") ostree=/ostree/boot.1/default/$bc/0" \
    > "$ent/ostree-$n-default.conf"
}
st() {
  local e id fl i=0
  local -a d=()
  for e; do
    id=${e%% *}
    fl=${e#"$id"}
    d+=("$(jq -c --arg c "${id%.*}" --argjson s "${id##*.}" --argjson i "$i" \
      --argjson b "$([[ $fl == *b* ]] && echo true || echo false)" --argjson g "$([[ $fl == *s* ]] && echo true || echo false)" \
      --argjson p "$([[ $fl == *p* ]] && echo true || echo false)" \
      '.deployments[0] | .checksum = $c | .serial = $s | .index = $i | .booted = $b | .staged = $g | .pinned = $p' \
      "$here/bootimg-update/status.json")")
    i=$(( i + 1 ))
  done
  printf '%s\n' "${d[@]}" | jq -s '{deployments: .}' > "$FAKE_STATE/status.json"
}

{ head -c 16 /dev/zero; le64 65339392; head -c 32 /dev/zero; printf 'ARMd'; seq 1 300000; } > "$tmp/Image"
runimg=$tmp/running.img
truncate -s "$size" "$runimg"
printf 'ANDROID!' | put "$runimg" 0
le32 2 | put "$runimg" 40
printf '%s' "ostree=/ostree/boot.1/default/$(c 1)/0 root=PARTLABEL=microos microos.deploy=$A microos.id=$RUN" | put "$runimg" 64
head -c 65536 /dev/urandom | put "$runimg" 1048576

reset() {
  rm -rf "$sys" "$MICROOS_ESP" "$MICROOS_RUNDIR" "$MICROOS_STATEDIR" "$FAKE_STATE" "$MICROOS_NVMEM_ROOT"
  mkdir -p "$MICROOS_ESP" "$MICROOS_RUNDIR" "$MICROOS_STATEDIR" "$FAKE_STATE" "$MICROOS_NVMEM_ROOT/spmi_sdam1" "$tmp/dt/nvram@7100"
  head -c 256 /dev/zero > "$MICROOS_NVMEM_ROOT/spmi_sdam1/nvmem"
  ln -sfn "$tmp/dt/nvram@7100" "$MICROOS_NVMEM_ROOT/spmi_sdam1/of_node"
  deployment "$A" "$(c 1)" A 2
  deployment "$N" "$(c 2)" N 1
  st "$A b" "$N"
  echo "$A" > "$MICROOS_RUNDIR/boot-confirmed"
  echo "root=PARTLABEL=microos ro init=/init microos.id=$RUN $panel" > "$MICROOS_CMDLINE"
  cp "$runimg" "$MICROOS_BOOT_B"
}
run() { "${as[@]}" "$tool" --tree "$t" "$@" > "$tmp/out" 2>&1; }
run_rc() { r=0; run "$@" || r=$?; }
armed() { cat "$FAKE_STATE/slot.log" 2> /dev/null | grep -c '^microos-slot arm$' || true; }
writes() { cat "$FAKE_STATE/events" 2> /dev/null | grep -c "^dd .*of=$MICROOS_BOOT_B " || true; }
untouched() {
  same "$MICROOS_BOOT_B" "${2:-$runimg}" || fail "$1: boot_b changed"
  [[ $(armed) == 0 ]] || fail "$1: slot armed"
  [[ ! -e $MICROOS_STATEDIR/bootimg-update ]] || fail "$1: record written"
}
refused() {
  local name=$1 why=$2
  shift 2
  run_rc "$@"
  (( r != 0 )) || fail "$name: exit 0"
  [[ $(cat "$tmp/out") == *"$why"* ]] || fail "$name: $(cat "$tmp/out")"
  untouched "$name"
}
unpack() {
  rm -rf "$tmp/u"
  info=$(unpack_bootimg --boot_img "$1" --out "$tmp/u")
  hcmd=$(sed -n 's/^command line args: \{0,1\}//p' <<< "$info")
}

for f in "$tree/usr/libexec/microos/microos-bootimg-update" "$tree/usr/libexec/microos/microos-stub-pack"; do
  [[ -x $f ]] || fail "${f##*/} is not executable"
done

reset
run --deployment "$A" || fail "update: $(cat "$tmp/out")"
[[ $(cat "$FAKE_STATE/inhibit.log") == "--what=sleep:shutdown --mode=block --who=microos-bootimg-update --why=writing boot_b $tool --tree $t --deployment $A" ]] \
  || fail "update sleep block: $(cat "$FAKE_STATE/inhibit.log")"
new=$MICROOS_ESP/microos/boot-new.img
prev=$MICROOS_ESP/microos/boot-prev.img
nid=$(sed -n 's/^armed=//p' "$MICROOS_STATEDIR/bootimg-update")
[[ $nid =~ ^[0-9a-f]{12}$ ]] || fail "update: armed id '$nid'"
[[ $(cat "$MICROOS_STATEDIR/bootimg-update") == "target=$A"$'\n'"armed=$nid"$'\n'"prev=$RUN" ]] \
  || fail "update record: $(cat "$MICROOS_STATEDIR/bootimg-update")"
same "$prev" "$runimg" || fail "boot-prev.img is not the running image"
[[ $(cat "$MICROOS_ESP/microos/boot-prev.id") == "$RUN $(sha "$runimg")" ]] || fail "boot-prev.id: $(cat "$MICROOS_ESP/microos/boot-prev.id")"
same "$MICROOS_BOOT_B" "$new" || fail "boot_b is not boot-new.img"
[[ $(stat -c %s "$new") == "$size" ]] || fail "boot-new.img size $(stat -c %s "$new")"
[[ $(armed) == 1 ]] || fail "update: arm calls $(armed)"
[[ -z $(find "$MICROOS_ESP" -name '*.tmp') ]] || fail "update left tmp files: $(find "$MICROOS_ESP" -name '*.tmp')"
unpack "$new"
[[ " $hcmd " == *" microos.deploy=$A "* && " $hcmd " == *" microos.id=$nid "* && " $hcmd " == *" maxcpus=7 "* ]] \
  || fail "boot-new.img cmdline: $hcmd"
[[ " $hcmd " != *" microos.test="* && " $hcmd " == *" root=PARTLABEL=microos "* ]] || fail "boot-new.img cmdline: $hcmd"
same "$tmp/u/ramdisk" "$sys/boot/ostree/default-$(c 1)/initramfs-$kver.img" || fail "boot-new.img ramdisk is not A's initrd"
same "$tmp/u/dtb" "$sys/ostree/deploy/default/deploy/$A/usr/lib/modules/$kver/dtb/$MICROOS_DTB" || fail "boot-new.img dtb is not A's"
"$t/usr/libexec/microos/microos-stub-pack" "$tmp/Image" "$tmp/packed" > /dev/null
gzip -dc < "$tmp/u/kernel" > "$tmp/u/Image"
same "$tmp/u/Image" "$tmp/packed" || fail "boot-new.img kernel is not the stub packed vmlinuz"
avbtool info_image --image "$new" > /dev/null || fail "avbtool info_image on boot-new.img"
order() {
  grep -E '^(mv -f [^ ]*boot-(prev|new)\.(img|id)\.tmp |mv -fT [^ ]*/bootimg-update\.|microos-slot arm|dd )' "$FAKE_STATE/events" \
    | sed -E "s#^mv -fT .*#record#; s#$MICROOS_ESP/microos/##g; s#$MICROOS_BOOT_B#B#g" | awk '{ l = $1 " " $2 " " $3; sub(/ +$/, "", l); print l }'
}
want="mv -f boot-prev.img.tmp
mv -f boot-prev.id.tmp
mv -f boot-new.img.tmp
record
microos-slot arm
dd if=/dev/zero of=B
dd if=boot-new.img of=B
dd if=boot-new.img of=B"
[[ $(order) == "$want" ]] || fail "save, record, arm and write order: $(order)"
grep "^dd " "$FAKE_STATE/events" | sed -n 1p | grep -q ' count=1 ' || fail "page 0 zeroing: $(grep '^dd ' "$FAKE_STATE/events")"
grep "^dd " "$FAKE_STATE/events" | sed -n 2p | grep -q ' skip=4096 seek=4096 ' || fail "bulk write: $(grep '^dd ' "$FAKE_STATE/events")"
grep "^dd " "$FAKE_STATE/events" | sed -n 3p | grep -q ' count=1 ' || fail "header page write: $(grep '^dd ' "$FAKE_STATE/events")"
cp "$new" "$tmp/first.img"

rm -f "$FAKE_STATE/inhibit.log"
run --status || fail "status: $(cat "$tmp/out")"
[[ ! -e $FAKE_STATE/inhibit.log ]] || fail "status took the sleep block"
for l in "running $RUN" "boot_b $nid" "prev $RUN" "record target=$A" "record armed=$nid" "disk /dev/sdz block 4096"; do
  grep -qxF "$l" "$tmp/out" || fail "status lacks '$l': $(cat "$tmp/out")"
done

: > "$FAKE_STATE/slot.log"
: > "$FAKE_STATE/events"
run --restore-prev || fail "undo before the reboot: $(cat "$tmp/out")"
[[ $(cat "$FAKE_STATE/inhibit.log") == "--what=sleep:shutdown --mode=block --who=microos-bootimg-update --why=writing boot_b $tool --tree $t --restore-prev" ]] \
  || fail "restore sleep block: $(cat "$FAKE_STATE/inhibit.log")"
same "$MICROOS_BOOT_B" "$runimg" || fail "undo before the reboot: boot_b is not boot-prev.img"
[[ $(cat "$MICROOS_STATEDIR/bootimg-update") == "target=$A"$'\n'"armed=$RUN"$'\n'"prev=$RUN"$'\n'"confirmed=$RUN" ]] \
  || fail "undo record: $(cat "$MICROOS_STATEDIR/bootimg-update")"
[[ $(order) == $'record\nmicroos-slot arm\ndd if=/dev/zero of=B\ndd if=boot-prev.img of=B\ndd if=boot-prev.img of=B' ]] \
  || fail "restore record, arm and write order: $(order)"
: > "$FAKE_STATE/slot.log"
run_rc --restore-prev
(( r != 0 )) && [[ $(cat "$tmp/out") == *"boot_b already holds boot-prev.img ($RUN)"* ]] || fail "restore onto itself: $(cat "$tmp/out")"
same "$MICROOS_BOOT_B" "$runimg" && [[ $(armed) == 0 ]] || fail "restore onto itself wrote or armed"
cp "$tmp/first.img" "$MICROOS_BOOT_B"
echo "root=PARTLABEL=microos ro microos.id=$nid $panel" > "$MICROOS_CMDLINE"
: > "$FAKE_STATE/slot.log"
run --restore-prev || fail "restore: $(cat "$tmp/out")"
same "$MICROOS_BOOT_B" "$runimg" || fail "restore: boot_b is not boot-prev.img"
[[ $(armed) == 1 ]] || fail "restore: arm calls $(armed)"
[[ $(cat "$MICROOS_STATEDIR/bootimg-update") == "target=$A"$'\n'"armed=$RUN"$'\n'"prev=$RUN" ]] \
  || fail "restore record: $(cat "$MICROOS_STATEDIR/bootimg-update")"
cp "$tmp/first.img" "$MICROOS_BOOT_B"
printf 'x' | put "$prev" 2097152
: > "$FAKE_STATE/slot.log"
rm -f "$MICROOS_STATEDIR/bootimg-update"
run_rc --restore-prev
(( r != 0 )) || fail "restore with a bad sha256: exit 0"
untouched "restore with a bad sha256" "$tmp/first.img"
truncate -s $(( size + 4096 )) "$prev"
echo "$RUN $(sha "$prev")" > "$MICROOS_ESP/microos/boot-prev.id"
run_rc --restore-prev
(( r != 0 )) && [[ $(cat "$tmp/out") == *"is not $size bytes"* ]] || fail "restore of a wrong size boot-prev.img: $(cat "$tmp/out")"
untouched "restore of a wrong size boot-prev.img" "$tmp/first.img"

reset
run --deployment "$A" --initrd-from "$N" || fail "initrd from N: $(cat "$tmp/out")"
unpack "$new"
same "$tmp/u/ramdisk" "$sys/boot/ostree/default-$(c 2)/initramfs-$kver.img" || fail "initrd from N: ramdisk is not N's initrd"
same "$tmp/u/dtb" "$sys/ostree/deploy/default/deploy/$A/usr/lib/modules/$kver/dtb/$MICROOS_DTB" || fail "initrd from N: dtb is not A's"
[[ " $hcmd " == *" microos.deploy=$A "* ]] || fail "initrd from N: cmdline $hcmd"

reset
echo "module b changed" > "$sys/ostree/deploy/default/deploy/$N/usr/lib/modules/$kver/kernel/drivers/b.ko"
refused "initrd from N, other module bytes" "modules of $N and $A differ" --deployment "$A" --initrd-from "$N"
reset
echo "module c" > "$sys/ostree/deploy/default/deploy/$N/usr/lib/modules/$kver/kernel/drivers/c.ko.zst"
refused "initrd from N, one more module" "modules of $N and $A differ" --deployment "$A" --initrd-from "$N"
reset
echo x >> "$sys/ostree/deploy/default/deploy/$N/usr/lib/modules/$kver/vmlinuz"
refused "initrd from N, other vmlinuz" "vmlinuz of $N and $A differ" --deployment "$A" --initrd-from "$N"

reset
FAKE_ARM_RC=1 run_rc --deployment "$A"
(( r != 0 )) && [[ $(cat "$tmp/out") == *"microos-slot arm failed, boot_b untouched"* ]] || fail "arm failure: $(cat "$tmp/out")"
same "$MICROOS_BOOT_B" "$runimg" || fail "arm failure: boot_b changed"
[[ $(writes) == 0 && $(sed -n 's/^armed=//p' "$MICROOS_STATEDIR/bootimg-update") =~ ^[0-9a-f]{12}$ ]] \
  || fail "arm failure: boot_b written or no record before the arm"

reset
echo 1 > "$FAKE_STATE/dd-bad"
run --deployment "$A" || fail "one write mismatch: $(cat "$tmp/out")"
same "$MICROOS_BOOT_B" "$new" || fail "one write mismatch: boot_b is not boot-new.img"
[[ $(writes) == 6 ]] || fail "one write mismatch: $(writes) boot_b writes"
reset
echo 2 > "$FAKE_STATE/dd-bad"
run_rc --deployment "$A"
(( r != 0 )) && [[ $(cat "$tmp/out") == *"boot_b holds boot-prev.img ($RUN) again"* ]] || fail "two write mismatches: $(cat "$tmp/out")"
same "$MICROOS_BOOT_B" "$runimg" || fail "two write mismatches: boot_b is not boot-prev.img"
[[ $(writes) == 9 ]] || fail "two write mismatches: $(writes) writes"
[[ $(cat "$MICROOS_STATEDIR/bootimg-update") == "target=$A"$'\n'"armed=$RUN"$'\n'"prev=$RUN"$'\n'"confirmed=$RUN" ]] \
  || fail "two write mismatches: record $(cat "$MICROOS_STATEDIR/bootimg-update")"
reset
FAKE_DD_FAIL_BULK=1 run_rc --deployment "$A"
(( r != 0 )) && [[ $(cat "$tmp/out") == *"did not read back from boot_b either"* ]] || fail "torn writes: $(cat "$tmp/out")"
[[ -z $(head -c 4096 "$MICROOS_BOOT_B" | tr -d '\0') ]] || fail "torn writes left a header on boot_b"

reset
echo "MICROOS_STUB_DEADLINE=600" >> "$sys/ostree/deploy/default/deploy/$A/usr/lib/microos/stub.conf"
refused "stub conf mismatch" "differs from $sys/ostree/deploy/default/deploy/$A/usr/lib/microos/stub.conf" --deployment "$A"
[[ ! -e $prev ]] || fail "stub conf mismatch saved boot-prev.img"

conf_a=$sys/ostree/deploy/default/deploy/$A/usr/lib/microos/bootimg.conf
reset
sed -i 's/^MICROOS_CMDLINE_MAX=.*/MICROOS_CMDLINE_MAX=600/' "$conf_a"
sed -i "s#^options .*#& microos.pad=$(printf 'x%.0s' $(seq 1 150))#" "$ent/ostree-2-default.conf"
refused "cmdline over 440 bytes" "cmdline is" --deployment "$A"
reset
sed -i 's/^MICROOS_AVB_PARTITION_SIZE=.*/MICROOS_AVB_PARTITION_SIZE=67108864/' "$conf_a"
refused "64 MiB image" "is not $size bytes" --deployment "$A"
reset
FAKE_AVB_FAIL=1 refused "avbtool failure" "avbtool info_image failed" --deployment "$A"

reset
( exec 7> "$MICROOS_RUNDIR/update.lock"; flock 7; exec sleep 5 ) &
holder=$!
sleep 0.3
refused "lock busy" "update.lock is busy" --deployment "$A"
kill "$holder" 2> /dev/null || true
wait "$holder" 2> /dev/null || true

reset
rm "$MICROOS_RUNDIR/boot-confirmed"
refused "not confirmed" "is not confirmed" --deployment "$A"
reset
echo "$N" > "$MICROOS_RUNDIR/boot-confirmed"
refused "confirmed names another deployment" "is not confirmed" --deployment "$A"
reset
echo "root=PARTLABEL=microos ro microos.id=ba9876543210 $panel" > "$MICROOS_CMDLINE"
refused "boot_b holds another image" "boot_b does not hold the running image" --deployment "$A"
reset
echo "root=PARTLABEL=microos ro $panel" > "$MICROOS_CMDLINE"
refused "no microos.id" "no microos.id" --deployment "$A"
reset
echo "root=PARTLABEL=microos ro microos.id=$RUN msm_drm.dsi_display0=qcom,mdss_dsi_other_vid:" > "$MICROOS_CMDLINE"
refused "unknown panel" "names no known panel" --deployment "$A"
reset
echo "root=PARTLABEL=microos ro microos.id=$RUN msm_drm.dsi_display0=qcom,mdss_dsi_kirby_nt36523_csot_dsc_vid:" > "$MICROOS_CMDLINE"
refused "csot panel without a csot dtb" "has no MICROOS_DTB_CSOT" --deployment "$A"
reset
FAKE_PARTLABEL=boot_a refused "wrong partlabel" "not boot_b" --deployment "$A"
reset
FAKE_DISK=sdy refused "other disk" "the disk microos-slot uses" --deployment "$A"
reset
truncate -s $(( size + 4096 )) "$MICROOS_BOOT_B"
cp "$MICROOS_BOOT_B" "$tmp/big.img"
run_rc --deployment "$A"
(( r != 0 )) && [[ $(cat "$tmp/out") == *"bytes, not $size"* ]] || fail "wrong size: $(cat "$tmp/out")"
untouched "wrong size" "$tmp/big.img"
reset
refused "drill for another deployment" "--drill builds for the booted deployment" --deployment "$N" --drill
reset
refused "unknown deployment" "is not a deployment" --deployment "$(c d).0"
reset
jq '.deployments[] |= (del(.stateroot) | .osname = "default")' "$FAKE_STATE/status.json" > "$tmp/osname.json"
mv -f "$tmp/osname.json" "$FAKE_STATE/status.json"
FAKE_LOGIND_RC=3 run --deployment "$A" || fail "osname: $(cat "$tmp/out")"
[[ ! -e $FAKE_STATE/inhibit.log ]] || fail "sleep block taken without logind: $(cat "$FAKE_STATE/inhibit.log")"
grep -qxF 'microos-bootimg-update: systemd-logind is not running, writing boot_b without a sleep block' "$tmp/out" \
  || fail "no line for the write without logind: $(cat "$tmp/out")"
reset
rm "$ent/ostree-1-default.conf"
refused "no BLS entry" "no BLS entry" --deployment "$N"
for a in "" "--deployment" "--deployment x" "--restore-prev --deployment $A" "--status --drill" "--restore-prev --initrd-from $A" "--bogus"; do
  reset
  refused "usage '$a'" "" $a
done
reset
r=0
"${as[@]}" "$tool" --deployment "$A" > "$tmp/out" 2>&1 || r=$?
(( r != 0 )) || fail "no --tree: exit 0"
untouched "no --tree"
if (( EUID != 0 )); then
  reset
  r=0
  "$tool" --tree "$t" --deployment "$A" > "$tmp/out" 2>&1 || r=$?
  (( r != 0 )) && grep -q "run as root" "$tmp/out" || fail "not root: $(cat "$tmp/out")"
fi

reset
st "$A b" "$N s"
mv "$ent/ostree-1-default.conf" "$FAKE_STATE/staged.conf"
run --deployment "$N" || fail "staged N: $(cat "$tmp/out")"
grep -qx "ostree admin finalize-staged" "$FAKE_STATE/ostree.log" || fail "finalize-staged not run"
[[ $(grep -E "lock-finalization|finalize-staged" "$FAKE_STATE/ostree.log") == \
  $'ostree admin lock-finalization --unlock\nostree admin finalize-staged' ]] || fail "staged N: no unlock before the finalize"
unpack "$new"
[[ " $hcmd " == *" microos.deploy=$N "* ]] || fail "staged N: cmdline $hcmd"
same "$tmp/u/ramdisk" "$sys/boot/ostree/default-$(c 2)/initramfs-$kver.img" || fail "staged N: ramdisk is not N's initrd"
reset
run --deployment "$A" || fail "no staged deployment: $(cat "$tmp/out")"
! grep -q finalize-staged "$FAKE_STATE/ostree.log" || fail "finalize-staged run with nothing staged"
reset
st "$A b" "$N s"
rm "$ent/ostree-1-default.conf"
refused "staged N without a BLS entry after the finalize" "no BLS entry" --deployment "$N"
grep -qx "ostree admin finalize-staged" "$FAKE_STATE/ostree.log" || fail "no BLS entry: finalize-staged not run"
same "$prev" "$runimg" || fail "no BLS entry: boot-prev.img is not the running image saved before the finalize"
[[ $(cat "$MICROOS_ESP/microos/boot-prev.id") == "$RUN $(sha "$runimg")" ]] || fail "no BLS entry: boot-prev.id"
reset
mkdir -p "$MICROOS_ESP/microos"
cp "$runimg" "$prev"
echo "$RUN $(sha "$runimg")" > "$MICROOS_ESP/microos/boot-prev.id"
touch -d @1000 "$prev"
run --deployment "$A" || fail "boot-prev.img already saved: $(cat "$tmp/out")"
grep -q "boot-prev.img already holds $RUN" "$tmp/out" || fail "boot-prev.img already saved: saved again: $(cat "$tmp/out")"
[[ $(stat -c %Y "$prev") == 1000 ]] || fail "boot-prev.img already saved: rewritten"
same "$MICROOS_BOOT_B" "$new" || fail "boot-prev.img already saved: boot_b is not boot-new.img"
reset
mkdir -p "$MICROOS_ESP/microos"
cp "$runimg" "$prev"
echo "$RUN $(c f)" > "$MICROOS_ESP/microos/boot-prev.id"
run --deployment "$A" || fail "boot-prev.id with a wrong sha: $(cat "$tmp/out")"
[[ $(cat "$MICROOS_ESP/microos/boot-prev.id") == "$RUN $(sha "$runimg")" ]] || fail "boot-prev.id with a wrong sha: not saved again"

reset
FAKE_SYSTEM=stopping refused "shutting down" "the system is shutting down, boot_b untouched" --deployment "$A"
reset
run --deployment "$A" --drill || fail "drill: $(cat "$tmp/out")"
unpack "$new"
[[ " $hcmd " == *" root=PARTLABEL=microos_missing "* && " $hcmd " != *" root=PARTLABEL=microos "* ]] || fail "drill cmdline: $hcmd"
same "$prev" "$runimg" || fail "drill: boot-prev.img is not the running image"

D=$sys/ostree/deploy/default/deploy/$A
dtool=$D/usr/libexec/microos/microos-bootimg-update
trun() { "${as[@]}" "$dtool" --tree "${TREE:-$D}" "$@" > "$tmp/out" 2>&1; }
trun_rc() { r=0; trun "$@" || r=$?; }
sdam() { od -An -tx1 -j72 -N1 "$MICROOS_NVMEM_ROOT/spmi_sdam1/nvmem" | tr -d ' \n'; }
tworder() {
  grep -E '^(mv -f [^ ]*(boot-prev\.(img|id)|testboot\.id)\.tmp |mv -fT [^ ]*/(bootimg-update|testboot)\.|microos-slot arm|dd )' \
    "$FAKE_STATE/events" | sed -E "s#^mv -fT [^ ]*/(bootimg-update|testboot)\..*#record \1#; s#$MICROOS_ESP/microos/##g; s#$MICROOS_BOOT_B#B#g; s#$tmp/imgs/##g" \
    | awk '{ l = $1 " " $2 " " $3; sub(/ +$/, "", l); print l }'
}
tuntouched() {
  same "$MICROOS_BOOT_B" "${2:-$runimg}" || fail "$1: boot_b changed"
  [[ $(armed) == 0 ]] || fail "$1: slot armed"
  [[ ! -e $MICROOS_STATEDIR/testboot && ! -e $MICROOS_ESP/microos/testboot.id ]] || fail "$1: testboot record written"
  [[ ! -e $MICROOS_ESP/microos/boot-prev.img || -n ${3:-} ]] || fail "$1: boot-prev.img written"
}
trefused() {
  local name=$1 why=$2
  shift 2
  trun_rc "$@"
  (( r != 0 )) || fail "$name: exit 0"
  [[ $(cat "$tmp/out") == *"$why"* ]] || fail "$name: $(cat "$tmp/out")"
  tuntouched "$name"
}
mkdir -p "$tmp/imgs"
"$t/usr/libexec/microos/microos-stub-pack" "$tmp/Image" "$tmp/imgs/kernel" > /dev/null
cp "$t/usr/lib/microos/stub/stub-preset-free.bin" "$tmp/other-prefix.bin"
printf 'x' | put "$tmp/other-prefix.bin" 4096
"$t/usr/libexec/microos/microos-stub-pack" --prefix "$tmp/other-prefix.bin" "$tmp/Image" "$tmp/imgs/preset-kernel" > /dev/null
reset
st "$A bp" "$N"
opts() { sed -n 's/^options //p' "$ent/ostree-$1-default.conf"; }
tbake() {
  local out=$1 dep=$2 n=$3 init=$4 kernel=$5 extra=$6
  shift 6
  bash "$dep/usr/libexec/microos/microos-bootimg-build" --root "$dep" --kernel "$kernel" \
    --initrd "$sys/boot/ostree/default-$init/initramfs-$kver.img" --dtb "$dep/usr/lib/modules/$kver/dtb/$MICROOS_DTB" \
    --options "$(opts "$n") $extra" --sysroot "$sys" --out "$tmp/imgs/$out" "$@" | cut -c1-12
}
NDIR=$sys/ostree/deploy/default/deploy/$N
tid=$(tbake once.img "$D" 2 "$(c 1)" "$tmp/imgs/kernel" microos.kround=p2c --test once --maxcpus 7)
tbake test1.img "$D" 2 "$(c 1)" "$tmp/imgs/kernel" microos.kround=p2c --test 1 --maxcpus 7 > /dev/null
tbake both.img "$D" 2 "$(c 1)" "$tmp/imgs/kernel" "microos.kround=p2c microos.test=1" --test once --maxcpus 7 > /dev/null
tbake twice.img "$D" 2 "$(c 1)" "$tmp/imgs/kernel" "microos.kround=p2c microos.test=once" --test once --maxcpus 7 > /dev/null
tbake nokround.img "$D" 2 "$(c 1)" "$tmp/imgs/kernel" "" --test once --maxcpus 7 > /dev/null
tbake maxcpus1.img "$D" 2 "$(c 1)" "$tmp/imgs/kernel" microos.kround=p2c --test once --maxcpus 1 > /dev/null
tbake preset.img "$D" 2 "$(c 1)" "$tmp/imgs/preset-kernel" microos.kround=p2c --test once --maxcpus 7 > /dev/null
tbake ninitrd.img "$D" 2 "$(c 2)" "$tmp/imgs/kernel" microos.kround=p2c --test once --maxcpus 7 > /dev/null
tbake ndeploy.img "$NDIR" 1 "$(c 2)" "$tmp/imgs/kernel" microos.kround=p2c --test once --maxcpus 7 > /dev/null
cp "$tmp/imgs/once.img" "$tmp/imgs/big.img"
truncate -s $(( size + 4096 )) "$tmp/imgs/big.img"
oimg=$tmp/imgs/once.img
[[ $tid =~ ^[0-9a-f]{12}$ && $tid != "$RUN" ]] || fail "test image id '$tid'"

reset
st "$A bp" "$N"
printf '\005' | put "$MICROOS_NVMEM_ROOT/spmi_sdam1/nvmem" 72
trun --test "$oimg" || fail "test: $(cat "$tmp/out")"
[[ $(cat "$FAKE_STATE/inhibit.log") == "--what=sleep:shutdown --mode=block --who=microos-bootimg-update --why=writing boot_b $dtool --tree ${TREE:-$D} --test $oimg" ]] \
  || fail "test sleep block: $(cat "$FAKE_STATE/inhibit.log")"
same "$MICROOS_BOOT_B" "$oimg" || fail "test: boot_b is not the test image"
same "$MICROOS_ESP/microos/boot-prev.img" "$runimg" || fail "test: boot-prev.img is not the running image"
[[ $(cat "$MICROOS_ESP/microos/boot-prev.id") == "$RUN $(sha "$runimg")" ]] || fail "test: boot-prev.id $(cat "$MICROOS_ESP/microos/boot-prev.id")"
[[ $(cat "$MICROOS_STATEDIR/testboot") == "test=$tid"$'\n'"prev=$RUN"$'\n'"deploy=$A" ]] \
  || fail "test record: $(cat "$MICROOS_STATEDIR/testboot")"
[[ $(cat "$MICROOS_ESP/microos/testboot.id") == "$tid $RUN" ]] || fail "testboot.id: $(cat "$MICROOS_ESP/microos/testboot.id")"
[[ ! -e $MICROOS_STATEDIR/bootimg-update ]] || fail "test wrote bootimg-update: $(cat "$MICROOS_STATEDIR/bootimg-update")"
[[ $(armed) == 1 && $(sdam) == 01 ]] || fail "test: arm calls $(armed), SDAM byte $(sdam)"
[[ -z $(find "$MICROOS_ESP" -name '*.tmp') ]] || fail "test left tmp files: $(find "$MICROOS_ESP" -name '*.tmp')"
want="mv -f boot-prev.img.tmp
mv -f boot-prev.id.tmp
record testboot
mv -f testboot.id.tmp
microos-slot arm
dd if=/dev/zero of=B
dd if=once.img of=B
dd if=once.img of=B"
[[ $(tworder) == "$want" ]] || fail "test save, record, arm and write order: $(tworder)"
trun --status || fail "test status: $(cat "$tmp/out")"
for l in "boot_b $tid" "prev $RUN" "testboot test=$tid" "testboot prev=$RUN" "testboot deploy=$A" "testboot.id $tid $RUN"; do
  grep -qxF "$l" "$tmp/out" || fail "test status lacks '$l': $(cat "$tmp/out")"
done
: > "$FAKE_STATE/slot.log"
trun --restore-prev || fail "test undo before the reboot: $(cat "$tmp/out")"
same "$MICROOS_BOOT_B" "$runimg" || fail "test undo: boot_b is not boot-prev.img"

reset
st "$A bp" "$N"
printf 'target=%s\narmed=ba86ce5bf551\nprev=%s\n' "$A" "$RUN" > "$MICROOS_STATEDIR/bootimg-update"
cp "$MICROOS_STATEDIR/bootimg-update" "$tmp/drill.rec"
trun --test "$oimg" || fail "test after a drill record: $(cat "$tmp/out")"
same "$MICROOS_STATEDIR/bootimg-update" "$tmp/drill.rec" || fail "test after a drill record changed bootimg-update"
same "$MICROOS_BOOT_B" "$oimg" || fail "test after a drill record: boot_b is not the test image"

reset
st "$A bp" "$N"
printf 'target=%s\narmed=%s\nprev=%s\n' "$A" "$RUN" "$RUN" > "$MICROOS_STATEDIR/bootimg-update"
trefused "armed running image never confirmed" "has armed=$RUN without confirmed=$RUN" --test "$oimg"
reset
st "$A bp" "$N"
printf 'target=%s\narmed=%s\nprev=%s\nconfirmed=%s\n' "$A" "$RUN" "$RUN" "$RUN" > "$MICROOS_STATEDIR/bootimg-update"
trun --test "$oimg" || fail "test after a confirmed record: $(cat "$tmp/out")"

reset
st "$A bp" "$N"
cp "$runimg" "$tmp/other-prev.img"
printf 'bbbbbbbbbbbb' | put "$tmp/other-prev.img" 4096
mkdir -p "$MICROOS_ESP/microos"
cp "$tmp/other-prev.img" "$MICROOS_ESP/microos/boot-prev.img"
echo "bbbbbbbbbbbb $(sha "$tmp/other-prev.img")" > "$MICROOS_ESP/microos/boot-prev.id"
trun_rc --test "$oimg"
(( r != 0 )) && [[ $(cat "$tmp/out") == *"boot-prev.img holds bbbbbbbbbbbb, not the running image, --replace-prev replaces it"* ]] \
  || fail "prev naming another id: $(cat "$tmp/out")"
tuntouched "prev naming another id" "$runimg" keep
same "$MICROOS_ESP/microos/boot-prev.img" "$tmp/other-prev.img" || fail "prev naming another id: boot-prev.img changed"
trun --test "$oimg" --replace-prev || fail "--replace-prev: $(cat "$tmp/out")"
[[ $(cat "$MICROOS_ESP/microos/boot-prev.id") == "$RUN $(sha "$runimg")" ]] || fail "--replace-prev: boot-prev.id $(cat "$MICROOS_ESP/microos/boot-prev.id")"
reset
st "$A bp" "$N"
mkdir -p "$MICROOS_ESP/microos"
cp "$runimg" "$MICROOS_ESP/microos/boot-prev.img"
echo "$RUN $(sha "$runimg")" > "$MICROOS_ESP/microos/boot-prev.id"
trun --test "$oimg" || fail "prev naming the running id: $(cat "$tmp/out")"

for c in "test1.img|needs one microos.test=, and it is once" "both.img|needs one microos.test=, and it is once" \
  "twice.img|needs one microos.test=, and it is once" "nokround.img|needs one microos.kround=" \
  "maxcpus1.img|has no maxcpus=7" "preset.img|is not the preset free stub" "ninitrd.img|ramdisk is not the initrd of $A" \
  "ndeploy.img|has microos.deploy=$N, not $A" "big.img|is not $size bytes"; do
  reset
  st "$A bp" "$N"
  trefused "test ${c%%|*}" "${c#*|}" --test "$tmp/imgs/${c%%|*}"
done
reset
st "$A b" "$N"
trefused "test unpinned" "$A is not pinned" --test "$oimg"
reset
st "$A bp" "$N s"
trefused "test staged" "a deployment is staged" --test "$oimg"
grep -q finalize-staged "$FAKE_STATE/ostree.log" && fail "test staged ran finalize-staged"
reset
st "$A bp" "$N"
rm "$MICROOS_RUNDIR/boot-confirmed"
trefused "test unconfirmed" "is not confirmed" --test "$oimg"
reset
st "$A bp" "$N"
echo "root=PARTLABEL=microos ro microos.id=ba9876543210 $panel" > "$MICROOS_CMDLINE"
trefused "test boot_b not running" "boot_b does not hold the running image" --test "$oimg"
reset
st "$A bp" "$N"
cp "$oimg" "$MICROOS_BOOT_B"
echo "root=PARTLABEL=microos ro microos.id=$tid $panel" > "$MICROOS_CMDLINE"
trun_rc --test "$oimg"
(( r != 0 )) && [[ $(cat "$tmp/out") == *"microos.id '$tid' is not a new image id"* ]] || fail "test same id: $(cat "$tmp/out")"
tuntouched "test same id" "$oimg"
reset
st "$A bp" "$N"
echo "root=PARTLABEL=microos ro microos.id=$RUN msm_drm.dsi_display0=qcom,mdss_dsi_kirby_nt36523_csot_dsc_vid:" > "$MICROOS_CMDLINE"
trefused "test csot panel" "carry the BOE DTB" --test "$oimg"
reset
st "$A bp" "$N"
rm "$MICROOS_NVMEM_ROOT/spmi_sdam1/of_node"
trefused "test no SDAM" "no SDAM nvram@7100" --test "$oimg"
reset
st "$A bp" "$N"
( exec 7> "$MICROOS_RUNDIR/update.lock"; flock 7; exec sleep 5 ) &
holder=$!
sleep 0.3
trefused "test lock busy" "update.lock is busy" --test "$oimg"
kill "$holder" 2> /dev/null || true
wait "$holder" 2> /dev/null || true
reset
st "$A bp" "$N"
TREE=$t trefused "test tree not a deployment" "is not a deployment dir" --test "$oimg"
for a in "--test $oimg --deployment $A" "--replace-prev" "--deployment $A --replace-prev" "--test $oimg --drill" "--test"; do
  reset
  st "$A bp" "$N"
  trefused "test usage '$a'" "" $a
done

reset
st "$A bp" "$N"
FAKE_ARM_RC=1 trun_rc --test "$oimg"
(( r != 0 )) && [[ $(cat "$tmp/out") == *"microos-slot arm failed, boot_b untouched"* ]] || fail "test arm failure: $(cat "$tmp/out")"
same "$MICROOS_BOOT_B" "$runimg" && [[ $(writes) == 0 && -e $MICROOS_STATEDIR/testboot ]] \
  || fail "test arm failure: boot_b written or no record before the arm"
reset
st "$A bp" "$N"
echo 2 > "$FAKE_STATE/dd-bad"
trun_rc --test "$oimg"
(( r != 0 )) && [[ $(cat "$tmp/out") == *"boot_b holds boot-prev.img ($RUN) again"* ]] || fail "test two write mismatches: $(cat "$tmp/out")"
same "$MICROOS_BOOT_B" "$runimg" && [[ $(writes) == 9 ]] || fail "test two write mismatches: $(writes) writes"

if (( rc == 0 )); then
  echo "bootimg-update: ok"
fi
exit "$rc"
