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
export MICROOS_STATEDIR=$tmp/state FAKE_STATE=$tmp/fake
export PATH=$here/bootimg/bin:$PATH
mkdir -p "$MICROOS_STATEDIR" "$FAKE_STATE"
up() { "$update" "$@" 2>&1; }

A=$csum_a.0
B=$csum_b.0
csum_d=$(printf d%.0s {1..64})
D=$csum_d.0
flag() { if [[ $1 == *$2* ]]; then echo true; else echo false; fi; }
st() {
  local e id fl i=0 sep=""
  {
    printf '{"deployments":['
    for e; do
      id=${e%% *}
      fl=${e#"$id"}
      printf '%s{"checksum":"%s","serial":%s,"index":%d,"booted":%s,"pinned":%s,"staged":%s}' "$sep" \
        "${id%.*}" "${id##*.}" "$i" "$(flag "$fl" b)" "$(flag "$fl" p)" "$(flag "$fl" s)"
      sep=,
      i=$((i + 1))
    done
    printf ']}\n'
  } > "$FAKE_STATE/status.json"
}
st "$A b" "$B"

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

hdr() {
  local o
  o=$(mktemp -d)
  unpack_bootimg --boot_img "$1" --out "$o" | sed -n 's/^command line args: //p'
  rm -rf "$o"
}
deploy_of() { hdr "$1" | grep -o 'microos.deploy=[^ ]*' | cut -d= -f2; }
link_of() { hdr "$1" | grep -o 'ostree=[^ ]*' | cut -d= -f2; }
bid() { "$build" --root "$sys/ostree/deploy/default/deploy/$1" --kernel "$kernel" --initrd "$initrd" --dtb "$dtb" --options "$2" --sysroot "$sys" --id; }
bakstamp() { cat "$esp/.microos-bootimg-bak.id" 2>/dev/null; }
kstamp() { cat "$esp/.microos-bootimg.id" 2>/dev/null; }
resolves() { [[ $(realpath -e "$sys$1" 2>/dev/null) == */"$2" ]]; }

cp "$esp/KERNEL" "$tmp/kb"
st "$A b" "$B p"
out=$("$update" --bak "$B" 2>/dev/null) || fail "--bak of a pinned deployment failed"
[[ $(tail -n 1 <<< "$out") == "bak $B $(bid "$B" "$opts_b")" ]] || fail "--bak last line: $out"
[[ $(deploy_of "$esp/KERNEL.BAK") == "$B" ]] || fail "--bak KERNEL.BAK does not name $B"
[[ $(bakstamp) == "$(bid "$B" "$opts_b")" ]] || fail "--bak stamp is not the bake id"
same "$esp/KERNEL" "$tmp/kb" || fail "--bak touched KERNEL"
cp "$esp/KERNEL.BAK" "$tmp/bakb"

st "$A b" "$B"
up --bak "$A" >/dev/null && fail "--bak accepted an unpinned deployment"
st "$A b" "$B s p"
up --bak "$B" >/dev/null && fail "--bak accepted a staged deployment"
st "$A b" "$B" "$D p"
up --bak "$D" >/dev/null && fail "--bak accepted a deployment with no BLS entry"
up --bak "$B" extra >/dev/null && fail "--bak accepted an extra argument"
up --bak nonsense >/dev/null && fail "--bak accepted a bad id"
same "$esp/KERNEL.BAK" "$tmp/bakb" || fail "a refused --bak changed KERNEL.BAK"

st "$A b p" "$B"
echo "$A" > "$MICROOS_STATEDIR/confirmed"
rm -f "$esp/KERNEL.BAK" "$esp/.microos-bootimg-bak.id" "$esp/.microos-bootimg.id"
out=$(up) || fail "default run with confirmed failed: $out"
[[ $(deploy_of "$esp/KERNEL") == "$B" ]] || fail "KERNEL is not the highest version entry"
[[ $(deploy_of "$esp/KERNEL.BAK") == "$A" ]] || fail "KERNEL.BAK is not confirmed"
[[ $(bakstamp) == "$(bid "$A" "$opts_a")" ]] || fail "BAK stamp after the default run"
kb=$(stat -c '%i %Y' "$esp/KERNEL")
bb=$(stat -c '%i %Y' "$esp/KERNEL.BAK")
sleep 1
out=$(up) || fail "second default run failed: $out"
[[ $(grep -c "skip, " <<< "$out") == 2 ]] || fail "second default run did not skip both: $out"
[[ $(stat -c '%i %Y' "$esp/KERNEL") == "$kb" && $(stat -c '%i %Y' "$esp/KERNEL.BAK") == "$bb" ]] || fail "second default run rewrote an image"

rm -f "$MICROOS_STATEDIR/confirmed" "$esp/KERNEL.BAK" "$esp/.microos-bootimg-bak.id"
st "$A b" "$B"
up >/dev/null || fail "default run with no source failed"
[[ ! -e $esp/KERNEL.BAK ]] || fail "KERNEL.BAK created with no confirmed and no pin"

echo "$B" > "$MICROOS_STATEDIR/confirmed"
printf '%s\n' "$B" "$A" "$D" > "$MICROOS_STATEDIR/boot-ok-pins"
st "$A b p" "$B" "$D p"
out=$(up) || fail "default run from boot ok pins failed: $out"
[[ $out == *"KERNEL.BAK from boot ok pin $A"* ]] || fail "boot ok pin source not printed: $out"
[[ $(deploy_of "$esp/KERNEL.BAK") == "$A" ]] || fail "KERNEL.BAK is not the last pinned boot ok pin"
rm -f "$esp/KERNEL.BAK" "$esp/.microos-bootimg-bak.id"
: > "$MICROOS_STATEDIR/boot-ok-pins"
echo "$D" > "$MICROOS_STATEDIR/confirmed"
st "$A b p" "$B"
up >/dev/null || fail "default run with a hand pin failed"
[[ ! -e $esp/KERNEL.BAK ]] || fail "a hand pin fed KERNEL.BAK"

dd=$sys/ostree/deploy/default/deploy/$D
mkdir -p "$dd/usr/lib/microos" "$dd/usr/libexec/microos"
cp "$conf" "$dd/usr/lib/microos/"
cp "$build" "$dd/usr/libexec/microos/"
echo "IMAGE_VERSION=20261012.3d49490" > "$dd/usr/lib/microos/version"
ln -s "../../../deploy/default/deploy/$D" "$sys/ostree/boot.1/default/$bootcsum/2"
opts_d=${opts_a%/0}/2
entry ostree-3 0 "$opts_d"
st "$A b" "$B" "$D p"
up --bak "$D" >/dev/null || fail "--bak of deploy d failed"
cp "$esp/KERNEL.BAK" "$tmp/bakd"
cp "$esp/.microos-bootimg-bak.id" "$tmp/bakd.id"
rm -rf "$dd" "$sys/ostree/boot.1/default/$bootcsum/2" "$boot/loader/entries/ostree-3.conf"
st "$A b" "$B"
rm -f "$esp/.microos-bootimg.id"
out=$(up) || fail "default run with a dead confirmed failed: $out"
[[ ! -e $esp/KERNEL.BAK && ! -e $esp/.microos-bootimg-bak.id ]] || fail "dead KERNEL.BAK kept"
[[ $out == *"removed $esp/KERNEL.BAK"* ]] || fail "dead KERNEL.BAK removal not printed: $out"
[[ $(deploy_of "$esp/KERNEL") == "$B" && $(kstamp) == "$(bid "$B" "$opts_b")" ]] || fail "KERNEL not baked next to a dead KERNEL.BAK"

rm -f "$MICROOS_STATEDIR/confirmed"
cp "$tmp/bakb" "$esp/KERNEL.BAK"
up >/dev/null || fail "default run with a live KERNEL.BAK failed"
same "$esp/KERNEL.BAK" "$tmp/bakb" || fail "live KERNEL.BAK with no source not kept"
"${MKBOOTIMG:-/usr/bin/mkbootimg}" --header_version 0 --kernel "$kernel" --ramdisk "$initrd" --cmdline "console=tty0 quiet" --output "$tmp/bakhand"
cp "$tmp/bakhand" "$esp/KERNEL.BAK"
up >/dev/null || fail "default run with a hand KERNEL.BAK failed"
same "$esp/KERNEL.BAK" "$tmp/bakhand" || fail "KERNEL.BAK with no microos.deploy= not kept"
cp "$tmp/bakd" "$esp/KERNEL.BAK"
mv "$sys/ostree/boot.1" "$tmp/boot.1.aside"
up >/dev/null || true
same "$esp/KERNEL.BAK" "$tmp/bakd" || fail "KERNEL.BAK removed while no bootlink resolves the booted deployment"
mv "$tmp/boot.1.aside" "$sys/ostree/boot.1"

echo "$A" > "$MICROOS_STATEDIR/confirmed"
st "$A b p" "$B"
cp "$tmp/bakd" "$esp/KERNEL.BAK"
echo stale > "$esp/.microos-bootimg-bak.id"
FAKE_FREE=1000 up >/dev/null && fail "BAK bake ran without free space"
[[ ! -e $esp/KERNEL.BAK ]] || fail "dead KERNEL.BAK kept after a failed bake"

up >/dev/null || fail "BAK bake from confirmed failed"
cp "$esp/KERNEL.BAK" "$tmp/baka"
cp "$esp/KERNEL" "$tmp/kcur"
echo "$B" > "$MICROOS_STATEDIR/confirmed"
st "$A b" "$B p"
echo stale > "$esp/KBAK.TMP"
FAKE_MV_FAIL_BAK=1 up >/dev/null && fail "update ignored a failed BAK rename"
same "$esp/KERNEL.BAK" "$tmp/baka" || fail "KERNEL.BAK changed on a failed rename"
[[ ! -e $esp/.microos-bootimg-bak.id ]] || fail "BAK stamp kept while KBAK.TMP was written"
[[ ! -e $esp/KBAK.TMP ]] || fail "KBAK.TMP left"
same "$esp/KERNEL" "$tmp/kcur" || fail "KERNEL changed by a failed BAK rename"
[[ $(kstamp) == "$(bid "$B" "$opts_b")" ]] || fail "KERNEL stamp lost by a failed BAK rename"
rm -f "$esp/.microos-bootimg.id"
FAKE_MV_FAIL=1 up >/dev/null && fail "update ignored a failed KERNEL rename"
[[ $(deploy_of "$esp/KERNEL.BAK") == "$B" && $(bakstamp) == "$(bid "$B" "$opts_b")" ]] || fail "BAK not baked after a failed KERNEL bake"
up >/dev/null || fail "KERNEL rebake failed"

echo "$A" > "$MICROOS_STATEDIR/confirmed"
st "$A b p" "$B"
cp "$esp/KERNEL.BAK" "$tmp/bakcur"
bs=$(bakstamp)
FAKE_FREE=1000 up >/dev/null && fail "BAK bake ran without free space"
same "$esp/KERNEL.BAK" "$tmp/bakcur" || fail "KERNEL.BAK changed on a space failure"
[[ $(bakstamp) == "$bs" ]] || fail "BAK stamp changed on a space failure"

up >/dev/null || fail "BAK bake of confirmed a failed"
mkdir -p "$sys/ostree/boot.0/default"
mv "$sys/ostree/boot.1/default/$bootcsum" "$sys/ostree/boot.0/default/"
rmdir "$sys/ostree/boot.1/default" "$sys/ostree/boot.1"
opts_a0=${opts_a/boot.1/boot.0}
opts_b0=${opts_b/boot.1/boot.0}
entry ostree-2 1 "$opts_a0"
entry ostree-1 2 "$opts_b0"
out=$(up) || fail "update after a BLS flip failed: $out"
[[ $(grep -c "baked " <<< "$out") == 2 ]] || fail "BLS flip did not rebake both: $out"
[[ $(link_of "$esp/KERNEL.BAK") == "${opts_a0##*ostree=}" && $(deploy_of "$esp/KERNEL.BAK") == "$A" ]] || fail "KERNEL.BAK after a BLS flip: $(hdr "$esp/KERNEL.BAK")"
resolves "$(link_of "$esp/KERNEL.BAK")" "$A" || fail "KERNEL.BAK bootlink does not resolve to $A"

l=$sys/ostree/boot.0/default/$bootcsum
rm "$l/0" "$l/1"
ln -s "../../../deploy/default/deploy/$B" "$l/0"
ln -s "../../../deploy/default/deploy/$A" "$l/1"
entry ostree-2 1 "${opts_a0%/0}/1"
entry ostree-1 2 "$opts_a0"
out=$(up) || fail "update after a /0 /1 swap failed: $out"
[[ $(grep -c "baked " <<< "$out") == 2 ]] || fail "/0 /1 swap did not rebake both: $out"
{ [[ $(deploy_of "$esp/KERNEL") == "$B" ]] && resolves "$(link_of "$esp/KERNEL")" "$B"; } || fail "KERNEL after a /0 /1 swap: $(hdr "$esp/KERNEL")"
{ [[ $(deploy_of "$esp/KERNEL.BAK") == "$A" ]] && resolves "$(link_of "$esp/KERNEL.BAK")" "$A"; } || fail "KERNEL.BAK after a /0 /1 swap: $(hdr "$esp/KERNEL.BAK")"
opts_kb=$opts_a0
opts_bb=${opts_a0%/0}/1

rm -f "$esp/.microos-bootimg.id" "$esp/.microos-bootimg-bak.id"
( exec 7> "$run/bootimg.lock"; flock 7; exec sleep 3 ) &
holder=$!
sleep 0.5
t0=$SECONDS
out=$(up) || fail "update behind a 3 s lock holder failed: $out"
(( SECONDS - t0 >= 2 )) || fail "update did not wait for the lock"
wait "$holder"
[[ $(kstamp) == "$(bid "$B" "$opts_kb")" && $(bakstamp) == "$(bid "$A" "$opts_bb")" ]] || fail "stamps after a lock wait"
[[ $(deploy_of "$esp/KERNEL") == "$B" && $(deploy_of "$esp/KERNEL.BAK") == "$A" ]] || fail "images after a lock wait"
[[ ! -e $esp/KERNEL.TMP && ! -e $esp/KBAK.TMP ]] || fail "temp left after a lock wait"
rm -f "$esp/.microos-bootimg.id" "$esp/.microos-bootimg-bak.id"
cp "$esp/KERNEL" "$tmp/k70"
cp "$esp/KERNEL.BAK" "$tmp/b70"
( exec 7> "$run/bootimg.lock"; flock 7; exec sleep 70 ) &
holder=$!
sleep 0.5
out=$(up) && fail "update ran past a 70 s lock holder"
[[ $out == *"timed out waiting for $run/bootimg.lock"* ]] || fail "lock timeout message: $out"
{ same "$esp/KERNEL" "$tmp/k70" && same "$esp/KERNEL.BAK" "$tmp/b70"; } || fail "lock timeout changed an image"
[[ ! -e $esp/.microos-bootimg.id && ! -e $esp/.microos-bootimg-bak.id ]] || fail "lock timeout wrote a stamp"
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
up >/dev/null || fail "update after the lock timeout failed"

st "$A b" "$B p"
cp "$esp/KERNEL" "$tmp/kterm"
cp "$esp/KERNEL.BAK" "$tmp/bterm"
rm -f "$FAKE_STATE/cp-sleeping"
FAKE_CP_SLEEP=3 "$update" --bak "$B" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 100); do
  [[ -e $FAKE_STATE/cp-sleeping ]] && break
  sleep 0.1
done
[[ -e $FAKE_STATE/cp-sleeping ]] || fail "the BAK temp write did not start"
kill -TERM "$pid"
trc=0
wait "$pid" || trc=$?
(( trc == 143 )) || fail "SIGTERM during the BAK write: exit $trc"
[[ ! -e $esp/KBAK.TMP ]] || fail "KBAK.TMP left after SIGTERM"
[[ ! -e $esp/.microos-bootimg-bak.id ]] || fail "BAK stamp left after SIGTERM"
{ same "$esp/KERNEL" "$tmp/kterm" && same "$esp/KERNEL.BAK" "$tmp/bterm"; } || fail "SIGTERM changed an image"
st "$A b p" "$B"
out=$(up) || fail "default run after SIGTERM failed: $out"
[[ $(bakstamp) == "$(bid "$A" "$opts_bb")" ]] || fail "BAK not rebaked after SIGTERM"

! grep -q rollback "$FAKE_STATE/bootc.log" 2>/dev/null || fail "bootc rollback was called"

if (( rc == 0 )); then
  echo "bootimg: ok"
fi
exit "$rc"
