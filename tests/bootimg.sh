#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
conf=$tree/usr/lib/microos/bootimg.conf
build=$tree/usr/libexec/microos/microos-bootimg-build
update=$tree/usr/libexec/microos/microos-bootimg-update
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
same() { [[ $(sha256sum < "$1") == $(sha256sum < "$2") ]]; }

. "$conf"

csum_a=$(printf a%.0s {1..64})
csum_b=$(printf b%.0s {1..64})
bootcsum=$(printf c%.0s {1..64})
deploy=$csum_a.0

cmd_is() {
  local got
  got=$(microos_cmdline "$1" "$deploy" 2>/dev/null) || { fail "cmdline failed: $1"; return; }
  [[ $got == "$2" ]] || fail "cmdline: $1"$'\n'"  got:  $got"$'\n'"  want: $2"
}
cmd_fails() {
  if microos_cmdline "$1" "$deploy" >/dev/null 2>&1; then
    fail "cmdline accepted: $1"
  fi
}

cmd_is "root=UUID=r rw boot=UUID=b rootflags=subvol=root ostree=/o rootflags=noatime,compress=zstd:1" \
  "ostree=/o root=UUID=r rw boot=UUID=b rootflags=subvol=root,noatime,compress=zstd:1 microos.deploy=$deploy"
cmd_is "ostree=/o rw quiet rw console=tty0 console=ttyMSM0 quiet rootflags=a,b rootflags=b,c ostree=/o console=ttyS0" \
  "ostree=/o rw quiet console=tty0 console=ttyMSM0 rootflags=a,b,c microos.deploy=$deploy"
cmd_is "ostree=/o root=UUID=r root=UUID=r" "ostree=/o root=UUID=r microos.deploy=$deploy"
cmd_is "ostree=/o microos.deploy=old quiet" "ostree=/o quiet microos.deploy=$deploy"
cmd_is "ostree=/o rootflags= quiet" "ostree=/o quiet microos.deploy=$deploy"
touch "$tmp/glob1" "$tmp/glob2"
[[ $(cd "$tmp" && microos_cmdline "ostree=/o *" "$deploy") == "ostree=/o * microos.deploy=$deploy" ]] || fail "cmdline expanded a glob"
cmd_fails "ostree=/o root=UUID=a root=UUID=b"
cmd_fails "ostree=/o rootflags=subvol=root rootflags=noatime,subvol=other"
cmd_is "ostree=/o rootflags=subvol=root rootflags=subvol=root,noatime" "ostree=/o rootflags=subvol=root,noatime microos.deploy=$deploy"
cmd_fails "ostree=/o boot=UUID=a boot=UUID=b"
cmd_fails "ostree=/o ostree=/p"
cmd_fails "root=UUID=r rw quiet"
if microos_cmdline "ostree=/o" "" >/dev/null 2>&1; then fail "cmdline accepted an empty deploy id"; fi
pad() { printf 'x%.0s' $(seq 1 "$1"); }
fixed=$(( ${#deploy} + 26 ))
n=$(microos_cmdline "ostree=/o $(pad $((511 - fixed)))" "$deploy" 2>/dev/null | tr -d '\n' | wc -c) || true
[[ $n == 511 ]] || fail "511 bytes not accepted ($n)"
cmd_fails "ostree=/o $(pad $((512 - fixed)))"

toml=$tree/usr/lib/bootc/kargs.d/10-microos.toml
if [[ -f $toml ]]; then
  kargs=$(sed -n '/^kargs/,/]/p' "$toml" | grep -o '"[^"]*"' | tr -d '"' | tr '\n' ' ')
  ksrc=${toml#"$tree"}
else
  kargs=$(cat "$here/bootimg/kargs.txt")
  ksrc=tests/bootimg/kargs.txt
fi
opts_a="$(cat "$here/bootimg/options.txt") $kargs ostree=/ostree/boot.1/default/$bootcsum/0"
opts_b=${opts_a%/0}/1
extra=$(cat "$here/bootimg/kargs-extra.txt")
c=$(microos_cmdline "$opts_a" "$deploy") || fail "image options rejected"
echo "bootimg: cmdline ${#c} bytes (kargs from $ksrc)"
if c=$(microos_cmdline "$opts_a $extra" "$deploy" 2>/dev/null); then
  echo "bootimg: with extra kargs ${#c} bytes, $((MICROOS_CMDLINE_MAX - ${#c})) left"
else
  echo "bootimg: with extra kargs it does not fit: $(microos_cmdline "$opts_a $extra" "$deploy" 2>&1 >/dev/null)"
fi

sys=$tmp/sysroot
boot=$tmp/boot
esp=$tmp/esp
run=$tmp/run
kver=7.2.6-microos
bdir=$boot/ostree/default-$bootcsum
mkdir -p "$bdir/dtb/qcom" "$boot/loader/entries" "$esp" "$sys/ostree/boot.1/default/$bootcsum"
for c in "$csum_a" "$csum_b"; do
  d=$sys/ostree/deploy/default/deploy/$c.0
  mkdir -p "$d/usr/lib/microos" "$d/usr/libexec/microos"
  cp "$conf" "$d/usr/lib/microos/"
  cp "$build" "$d/usr/libexec/microos/"
  echo "IMAGE_VERSION=20261012.3d49490" > "$d/usr/lib/microos/version"
done
ln -s "../../../deploy/default/deploy/$csum_a.0" "$sys/ostree/boot.1/default/$bootcsum/0"
ln -s "../../../deploy/default/deploy/$csum_b.0" "$sys/ostree/boot.1/default/$bootcsum/1"

kernel=$bdir/vmlinuz-$kver
initrd=$bdir/initramfs-$kver.img
dtb=$bdir/dtb/$MICROOS_DTB
{ head -c 56 /dev/zero; printf 'ARMd'; seq 1 300000; } > "$kernel"
seq 1 50000 | sed 's/^/initrd /' > "$initrd"
{ printf '\xd0\x0d\xfe\xed'; seq 1 500; } > "$dtb"

entry() {
  printf 'title MicroOS\nversion %s\noptions %s\nlinux %s\ninitrd %s\nfdtdir %s\n' \
    "$2" "$3" "/boot/ostree/default-$bootcsum/vmlinuz-$kver" \
    "/boot/ostree/default-$bootcsum/initramfs-$kver.img" "/boot/ostree/default-$bootcsum/dtb" \
    > "$boot/loader/entries/$1.conf"
}

droot=$sys/ostree/deploy/default/deploy/$csum_a.0
bake=(--root "$droot" --kernel "$kernel" --initrd "$initrd" --dtb "$dtb" --options "$opts_a" --sysroot "$sys")
id1=$("$build" "${bake[@]}" --out "$tmp/k1") || fail "bake failed"
id2=$("$build" "${bake[@]}" --out "$tmp/k2") || fail "second bake failed"
idonly=$("$build" "${bake[@]}" --id) || fail "--id failed"
[[ $id1 =~ ^[0-9a-f]{64}$ ]] || fail "id format: $id1"
[[ $id1 == "$id2" && $id1 == "$idonly" ]] || fail "id not stable: $id1 $id2 $idonly"
same "$tmp/k1" "$tmp/k2" || fail "two bakes differ"

info=$(unpack_bootimg --boot_img "$tmp/k1" --out "$tmp/u")
field() { sed -n "s/^$1: \{0,1\}//p" <<< "$info"; }
want=(
  "boot magic=ANDROID!"
  "boot image header version=0"
  "page size=2048"
  "kernel load address=0x10008000"
  "ramdisk load address=0x16000000"
  "kernel tags load address=0x10000100"
  "second bootloader size=0"
  "second bootloader load address=0x00000000"
  "os version=12.0.0"
  "os patch level=2026-10"
  "product name="
  "additional command line args="
)
for w in "${want[@]}"; do
  [[ $(field "${w%%=*}") == "${w#*=}" ]] || fail "header ${w%%=*}: '$(field "${w%%=*}")', want '${w#*=}'"
done
hcmd=$(field "command line args")
[[ $hcmd == "ostree=/ostree/boot.1/default/$bootcsum/0 "* ]] || fail "ostree= is not first: $hcmd"
[[ $hcmd == *" microos.deploy=$csum_a.0" ]] || fail "microos.deploy is not last or wrong: $hcmd"
[[ $(grep -o 'rootflags=[^ ]*' <<< "$hcmd") == rootflags=subvol=root,noatime,compress=zstd:1 ]] || fail "rootflags: $hcmd"
(( ${#hcmd} <= MICROOS_CMDLINE_MAX )) || fail "cmdline ${#hcmd} bytes"
same "$tmp/u/ramdisk" "$initrd" || fail "ramdisk differs from the initrd"
python3 - "$tmp/u/kernel" "$kernel" "$dtb" <<'EOF' || fail "kernel payload"
import sys, zlib
blob, image, dtb = (open(p, "rb").read() for p in sys.argv[1:])
d = zlib.decompressobj(31)
out = d.decompress(blob) + d.flush()
assert d.eof, "gzip stream not terminated"
assert out == image, "gunzip does not give the Image"
assert out[0x38:0x3c] == b"ARMd", "no arm64 magic"
tail = d.unused_data
assert tail == dtb, "bytes after the gzip stream are not exactly the DTB"
assert tail.count(b"\xd0\x0d\xfe\xed") == 1, "DTB count"
EOF

bad=$tmp/bad
mkdir -p "$bad/usr/lib/microos"
cp "$conf" "$bad/usr/lib/microos/"
echo "IMAGE_VERSION=dev" > "$bad/usr/lib/microos/version"
if "$build" --root "$bad" --kernel "$kernel" --initrd "$initrd" --dtb "$dtb" --options "$opts_a" --sysroot "$sys" --out "$tmp/x" 2>/dev/null; then
  fail "bad IMAGE_VERSION accepted"
fi
if "$build" "${bake[@]:0:2}" --kernel "$initrd" "${bake[@]:4}" --out "$tmp/x" 2>/dev/null; then
  fail "non Image kernel accepted"
fi
if "$build" "${bake[@]:0:8}" --options "ostree=/ostree/deploy" --sysroot "$sys" --out "$tmp/x" 2>/dev/null; then
  fail "bootlink outside a deployment accepted"
fi
[[ ! -e $tmp/x ]] || fail "failed bake left an output"

export MICROOS_ESP=$esp MICROOS_BOOT=$boot MICROOS_SYSROOT=$sys MICROOS_RUNDIR=$run
export PATH=$here/bootimg/bin:$PATH
up() { "$update" "$@" 2>&1; }

up --check >/dev/null || fail "check rejected a good ESP"
FAKE_SYS_BRACKET=1 up --check >/dev/null || fail "check rejected a bracketed subvol source"
FAKE_ESP_MOUNTED=0 up --check >/dev/null && fail "check accepted an unmounted ESP"
FAKE_ESP_OPTS=ro,relatime up --check >/dev/null && fail "check accepted a ro ESP"
FAKE_ESP_FSTYPE=ext4 up --check >/dev/null && fail "check accepted an ext4 ESP"
FAKE_ESP_SOURCE=/dev/sdY1 up --check >/dev/null && fail "check accepted an ESP on another disk"

up >/dev/null && fail "update ran with no BLS entry"

entry ostree-2 2 "$opts_a"
entry ostree-1 1 "$opts_b"
echo stale > "$esp/KERNEL.TMP"
out=$(up) || fail "update failed: $out"
[[ ! -e $esp/KERNEL.TMP ]] || fail "stale KERNEL.TMP left"
same "$esp/KERNEL" "$tmp/k1" || fail "KERNEL is not the bake of the highest version entry"
[[ $(cat "$esp/.microos-bootimg.id") == "$id1" ]] || fail "stamp is not the bake id"
[[ -e $run/bootimg.lock ]] || fail "no lock file"

before=$(stat -c '%i %Y' "$esp/KERNEL")
out=$(up) || fail "second update failed: $out"
[[ $out == *"skip, "* ]] || fail "second update did not skip: $out"
[[ $(stat -c '%i %Y' "$esp/KERNEL") == "$before" ]] || fail "second update rewrote KERNEL"

echo "old /ostree/boot.0/default/x/0 new /ostree/boot.1/default/x/0" > "$run/remapped"
out=$(up) || fail "update failed on a remapped boot: $out"
[[ $out == *remapped* ]] || fail "remap not logged: $out"
[[ $out == *"baked "* ]] || fail "remapped boot did not rebake over a matching stamp: $out"
[[ -e $run/remap-baked ]] || fail "no remap-baked marker"
out=$(up) || fail "second update on a remapped boot failed: $out"
[[ $out == *"skip, "* ]] || fail "second update on a remapped boot did not skip: $out"
rm "$run/remapped" "$run/remap-baked"

entry ostree-2 1 "$opts_a"
entry ostree-1 2 "$opts_b"
cp "$esp/KERNEL" "$tmp/kold"
FAKE_FREE=1000 up >/dev/null && fail "update ran without free space"
same "$esp/KERNEL" "$tmp/kold" || fail "KERNEL changed on a space failure"
[[ $(cat "$esp/.microos-bootimg.id") == "$id1" ]] || fail "stamp changed on a space failure"

FAKE_MV_FAIL=1 up >/dev/null && fail "update ignored a failed rename"
same "$esp/KERNEL" "$tmp/kold" || fail "KERNEL changed on a failed rename"
[[ ! -e $esp/.microos-bootimg.id ]] || fail "stamp kept while KERNEL.TMP was written"
[[ ! -e $esp/KERNEL.TMP ]] || fail "KERNEL.TMP left after a failed rename"

out=$(up) || fail "rollback update failed: $out"
unpack_bootimg --boot_img "$esp/KERNEL" --out "$tmp/u2" | grep -q "microos.deploy=$csum_b.0\$" || fail "rollback KERNEL does not name deploy b"
[[ $(cat "$esp/.microos-bootimg.id") == $("$build" --root "$sys/ostree/deploy/default/deploy/$csum_b.0" --kernel "$kernel" --initrd "$initrd" --dtb "$dtb" --options "$opts_b" --sysroot "$sys" --id) ]] || fail "rollback stamp"

if (( rc == 0 )); then
  echo "bootimg: ok"
fi
exit "$rc"
