#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tool=$here/../build/y700-dtb-repack
key=$here/../system_files/usr/share/microos/avb/testkey_rsa4096.pem
export MICROOS_AVB_KEY=$key
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

mkdtb() {
  printf '/dts-v1/;\n/ {\n\tcompatible = "%s", "qcom,sm8650";\n\tqcom,msm-id = <0x241 0x20000>;\n\tqcom,board-id = <0 0>;\n\tmodel = "%s";\n};\n' \
    "$1" "$2" | dtc -q -I dts -O dtb -o "$3" -
}
mkdtb lenovo,tb321fu old "$tmp/old.dtb"
mkdtb lenovo,tb321fu new "$tmp/new.dtb"
mkdtb other,board new "$tmp/other.dtb"
head -c 65536 /dev/urandom > "$tmp/Image"
printf 'ARMd' | dd of="$tmp/Image" bs=1 seek=56 conv=notrunc status=none
gzip -n -9 -c "$tmp/Image" > "$tmp/kernel"
head -c 4096 /dev/urandom > "$tmp/ramdisk"
cmdline="ostree=/ostree/boot.1/default/0/0 root=PARTLABEL=microos microos.test=1 maxcpus=1 microos.id=0123456789ab"
mkbootimg --header_version 2 --pagesize 4096 --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
  --dtb_offset 0x01f00000 --tags_offset 0x00000100 --os_version 14.0.0 --os_patch_level 2026-05-05 --dtb "$tmp/old.dtb" \
  --kernel "$tmp/kernel" --ramdisk "$tmp/ramdisk" --cmdline "$cmdline" --output "$tmp/round.img"
avbtool add_hash_footer --image "$tmp/round.img" --partition_name boot --partition_size 16777216 --algorithm SHA256_RSA4096 \
  --key "$key" --rollback_index 1777939200 --salt 0123456789ab0123456789ab0123456789ab0123456789ab0123456789ab0123 \
  --prop com.android.build.boot.os_version:14 --prop com.android.build.boot.security_patch:2026-05-05

id=$("$tool" "$tmp/round.img" "$tmp/new.dtb" "$tmp/out.img") || fail "repack: exit $?"
[[ $id =~ ^[0-9a-f]{64}$ ]] || fail "repack printed no id: $id"
unpack_bootimg --boot_img "$tmp/out.img" --out "$tmp/u" > "$tmp/info"
cmp -s "$tmp/u/kernel" "$tmp/kernel" || fail "kernel changed"
cmp -s "$tmp/u/ramdisk" "$tmp/ramdisk" || fail "ramdisk changed"
cmp -s "$tmp/u/dtb" "$tmp/new.dtb" || fail "dtb not replaced"
want=${cmdline/microos.id=0123456789ab/microos.id=${id:0:12}}
[[ $(sed -n 's/^command line args: //p' "$tmp/info") == "$want" ]] || fail "cmdline: $(sed -n 's/^command line args: //p' "$tmp/info")"
grep -qx 'os patch level: 2026-05' "$tmp/info" || fail "os patch level: $(grep 'os patch level' "$tmp/info")"
avbtool info_image --image "$tmp/out.img" > "$tmp/avb"
grep -q "Salt: *$id" "$tmp/avb" || fail "avb salt is not the new id"
grep -q "Rollback Index: *1777939200" "$tmp/avb" || fail "rollback index"
grep -q "com.android.build.boot.security_patch -> '2026-05-05'" "$tmp/avb" || fail "security patch prop"
[[ $(stat -c %s "$tmp/out.img") == 16777216 ]] || fail "image size $(stat -c %s "$tmp/out.img")"
pk() { avbtool info_image --image "$1" | sed -n 's/^Public key (sha1): *//p'; }
[[ $(pk "$tmp/out.img") == "$(pk "$tmp/round.img")" ]] || fail "public key differs from the round image"

if "$tool" "$tmp/round.img" "$tmp/other.dtb" "$tmp/bad.img" 2> "$tmp/err"; then
  fail "repack accepted a DTB of another board"
fi
grep -q "root compatible differs" "$tmp/err" || fail "board mismatch not reported: $(cat "$tmp/err")"
if "$tool" "$tmp/round.img" "$tmp/ramdisk" "$tmp/bad.img" 2> /dev/null; then
  fail "repack accepted a file that is not a DTB"
fi
[[ ! -e $tmp/bad.img ]] || fail "a refused repack wrote an image"

if (( rc == 0 )); then
  echo "dtb-repack: ok"
fi
exit "$rc"
