#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
conf=$tree/usr/lib/microos/bootimg.conf
build=$tree/usr/libexec/microos/microos-bootimg-build
key=$tree/usr/share/microos/avb/testkey_rsa4096.pem
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
same() { [[ $(sha256sum < "$1") == $(sha256sum < "$2") ]]; }

. "$conf"

[[ $(sha256sum < "$key") == "6a224754880a57ab9cbd308267cd157d94cf05a1c8cb851aec4090e045d24121  -" ]] || fail "test key sha256"
[[ $MICROOS_ABL_BUDGET == 87547904 ]] || fail "MICROOS_ABL_BUDGET $MICROOS_ABL_BUDGET"

csum_a=$(printf a%.0s {1..64})
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

cmd_is "root=PARTLABEL=microos ostree=/o loglevel=4" "ostree=/o root=PARTLABEL=microos loglevel=4 microos.deploy=$deploy"
cmd_is "ostree=/o microos.deploy=old microos.id=0123456789ab quiet console=ttyS0" "ostree=/o quiet microos.deploy=$deploy"
cmd_is "ostree=/o root=UUID=r root=UUID=r" "ostree=/o root=UUID=r microos.deploy=$deploy"
cmd_is "ostree=/o rootflags=a,b rootflags=b,c" "ostree=/o rootflags=a,b,c microos.deploy=$deploy"
touch "$tmp/glob1" "$tmp/glob2"
[[ $(cd "$tmp" && microos_cmdline "ostree=/o *" "$deploy") == "ostree=/o * microos.deploy=$deploy" ]] || fail "cmdline expanded a glob"
cmd_fails "ostree=/o root=UUID=a root=UUID=b"
cmd_fails "ostree=/o ostree=/p"
cmd_fails "root=PARTLABEL=microos quiet"
if microos_cmdline "ostree=/o" "" >/dev/null 2>&1; then fail "cmdline accepted an empty deploy id"; fi
pad() { printf 'x%.0s' $(seq 1 "$1"); }
fixed=$(( ${#deploy} + 26 ))
n=$(microos_cmdline "ostree=/o $(pad $((440 - fixed)))" "$deploy" 2>/dev/null | tr -d '\n' | wc -c) || true
[[ $n == 440 ]] || fail "440 bytes not accepted ($n)"
cmd_fails "ostree=/o $(pad $((441 - fixed)))"

toml=$tree/usr/lib/bootc/kargs.d/10-microos.toml
if [[ -f $toml ]]; then
  kargs=$(sed -n '/^kargs/,/]/p' "$toml" | grep -o '"[^"]*"' | tr -d '"' | tr '\n' ' ')
  ksrc=${toml#"$tree"}
else
  kargs=$(cat "$here/bootimg/kargs.txt")
  ksrc=tests/bootimg/kargs.txt
fi
[[ $(echo $kargs) == "$(cat "$here/bootimg/kargs.txt")" ]] || fail "kargs from $ksrc: $kargs"
opts="$(cat "$here/bootimg/options.txt") $kargs ostree=/ostree/boot.1/default/$bootcsum/0"

sys=$tmp/sysroot
droot=$sys/ostree/deploy/default/deploy/$deploy
mkdir -p "$droot/usr/lib/microos" "$droot/usr/libexec/microos" "$droot/usr/share/microos/avb" "$sys/ostree/boot.1/default/$bootcsum"
cp "$conf" "$droot/usr/lib/microos/"
cp "$build" "$droot/usr/libexec/microos/"
cp "$key" "$droot/usr/share/microos/avb/"
echo "IMAGE_VERSION=20261012.3d49490" > "$droot/usr/lib/microos/version"
ln -s "../../../deploy/default/deploy/$deploy" "$sys/ostree/boot.1/default/$bootcsum/0"

le64() {
  local i
  for i in 0 1 2 3 4 5 6 7; do
    printf "\\$(printf %03o $(( ($1 >> (8 * i)) & 255 )))"
  done
}
image() {
  { head -c 16 /dev/zero; le64 "$2"; head -c 32 /dev/zero; printf 'ARMd'; seq 1 "$3"; } > "$1"
}
initrd=$tmp/initramfs.img
dtb=$tmp/board.dtb
seq 1 50000 | sed 's/^/initrd /' > "$initrd"
{ printf '\xd0\x0d\xfe\xed'; seq 1 500; } > "$dtb"
ram=$(( ($(stat -c %s "$initrd") + 4095) / 4096 * 4096 ))
kernel=$tmp/Image
stub=$tmp/stub
image "$kernel" 65339392 300000
image "$stub" 67436544 200000

bake() {
  local k=$kernel
  if [[ ${1:-} == --kernel ]]; then
    k=$2
    shift 2
  fi
  "$build" --root "$droot" --kernel "$k" --initrd "$initrd" --dtb "$dtb" --options "$opts" --sysroot "$sys" "$@"
}
field() { sed -n "s/^$1: \{0,1\}//p" <<< "$info"; }
avb() { sed -n "s/^ *$1: *//p" <<< "$ainfo" | head -1; }
prop() { sed -n "s/^ *Prop: $1 -> //p" <<< "$ainfo"; }

check() {
  local name=$1 img=$2 id=$3 k=$4 w
  shift 4
  rm -rf "$tmp/u"
  info=$(unpack_bootimg --boot_img "$img" --out "$tmp/u") || { fail "$name: unpack_bootimg"; return; }
  for w in "boot image header version=2" "page size=4096" "os version=14.0.0" "os patch level=2026-05" \
    "kernel load address=0x00008000" "ramdisk load address=0x01000000" "kernel tags load address=0x00000100" \
    "dtb address=0x0000000001f00000"; do
    [[ $(field "${w%%=*}") == "${w#*=}" ]] || fail "$name: header ${w%%=*} '$(field "${w%%=*}")', want '${w#*=}'"
  done
  same "$tmp/u/dtb" "$dtb" || fail "$name: dtb section is not the DTB"
  same "$tmp/u/ramdisk" "$initrd" || fail "$name: ramdisk differs from the initrd"
  gzip -dc < "$tmp/u/kernel" > "$tmp/u/Image" 2>/dev/null || fail "$name: kernel is not one gzip stream"
  same "$tmp/u/Image" "$k" || fail "$name: kernel payload is not the Image"
  hcmd=$(field "command line args")
  (( ${#hcmd} <= 440 )) || fail "$name: cmdline ${#hcmd} bytes"
  [[ $hcmd == "ostree=/ostree/boot.1/default/$bootcsum/0 "* ]] || fail "$name: ostree= is not first: $hcmd"
  [[ " $hcmd " == *" microos.deploy=$deploy "* ]] || fail "$name: no microos.deploy: $hcmd"
  [[ $hcmd == *" microos.id=${id:0:12}" ]] || fail "$name: microos.id is not last or not the bake id: $hcmd"
  for w in "$@"; do
    if [[ $w == !* ]]; then
      [[ " $hcmd " != *" ${w#!} "* ]] || fail "$name: cmdline has ${w#!}: $hcmd"
    else
      [[ " $hcmd " == *" $w "* ]] || fail "$name: cmdline lacks $w: $hcmd"
    fi
  done
  [[ $(stat -c %s "$img") == 100663296 ]] || fail "$name: size $(stat -c %s "$img")"
  ainfo=$(avbtool info_image --image "$img") || { fail "$name: avbtool info_image"; return; }
  [[ $(avb "Image size") == "100663296 bytes" ]] || fail "$name: footer image size $(avb "Image size")"
  [[ $(avb "Algorithm") == SHA256_RSA4096 ]] || fail "$name: algorithm $(avb Algorithm)"
  [[ $(avb "Rollback Index") == 1777939200 ]] || fail "$name: rollback index $(avb "Rollback Index")"
  [[ $(avb "Partition Name") == boot ]] || fail "$name: partition name $(avb "Partition Name")"
  [[ $(avb "Salt") == "$id" ]] || fail "$name: salt $(avb Salt)"
  [[ $(avb "Public key (sha1)") == 2597c218aae470a130f61162feaae70afd97f011 ]] || fail "$name: public key $(avb "Public key (sha1)")"
  [[ $(prop com.android.build.boot.os_version) == "'14'" ]] || fail "$name: os_version prop"
  [[ $(prop com.android.build.boot.security_patch) == "'2026-05-05'" ]] || fail "$name: security_patch prop"
  rm -rf "$tmp/v"
  mkdir "$tmp/v"
  ln "$img" "$tmp/v/boot.img"
  avbtool verify_image --image "$tmp/v/boot.img" --key "$key" >/dev/null 2>&1 || fail "$name: avbtool verify_image"
  rm -rf "$tmp/v"
  echo "bootimg: $name cmdline ${#hcmd} bytes"
}

variant() {
  local name=$1 k=$kernel id idonly
  shift
  local -a flags=()
  while (( $# )) && [[ $1 != -- ]]; do
    flags+=("$1")
    shift
  done
  shift
  if [[ ${flags[0]:-} == --kernel ]]; then
    k=${flags[1]}
  fi
  id=$(bake "${flags[@]}" --out "$out/$name.img") || { fail "$name: bake failed"; return; }
  idonly=$(bake "${flags[@]}" --id) || fail "$name: --id failed"
  [[ $id =~ ^[0-9a-f]{64}$ && $id == "$idonly" ]] || fail "$name: id $id, --id $idonly"
  check "$name" "$out/$name.img" "$id" "$k" "$@"
  ids[$name]=$id
}

declare -A ids=()
out=$tmp/out
mkdir -p "$out"
variant production -- root=PARTLABEL=microos cpuidle.off=1 firmware_class.path=/var/lib/microos/fw '!maxcpus=1'
id2=$(bake --out "$out/again.img")
[[ $id2 == "${ids[production]}" ]] || fail "id not stable"
same "$out/production.img" "$out/again.img" || fail "two bakes differ"
rm -f "$out/again.img"
for w in 1 once noguard bootloader panic emergency wdhang gptdump; do
  variant "test-$w" --test "$w" -- "microos.test=$w" root=PARTLABEL=microos
done
variant stub1 --kernel "$stub" --test 1 --maxcpus 1 -- microos.test=1 maxcpus=1 cpuidle.off=1
variant stub7 --kernel "$stub" --test 1 --maxcpus 7 -- microos.test=1 maxcpus=7
variant slota --kernel "$stub" --test gptdump --maxcpus 1 --slot-a -- microos.test=gptdump maxcpus=1 \
  initcall_blacklist=msm_drm_register cpuidle.off=1
variant rootmissing --kernel "$stub" --test noguard --maxcpus 1 --root-missing -- root=PARTLABEL=microos_missing '!root=PARTLABEL=microos'
rm -rf "${out:?}"

seen=$(printf '%s\n' "${ids[@]}" | cut -c1-12 | sort -u | wc -l)
(( seen == ${#ids[@]} )) || fail "variants share a microos.id"

base=$(microos_cmdline "$opts" "$deploy")
longest=$(( ${#base} + 21 + 10 + 36 + 24 ))
fill=$(pad $(( 440 - longest + 5 )))
opts0=$opts
opts="$opts0 $fill"
id=$(bake --kernel "$stub" --test gptdump --maxcpus 1 --slot-a --out "$tmp/drop.img") || fail "slot a over 440 not baked without cpuidle.off=1"
if [[ -f $tmp/drop.img ]]; then
  check slota-drop "$tmp/drop.img" "$id" "$stub" initcall_blacklist=msm_drm_register '!cpuidle.off=1' "$fill"
  rm -f "$tmp/drop.img"
fi
opts="$opts0 $(pad $(( 440 - ${#base} - 25 )))"
bake --out "$tmp/full.img" >/dev/null || fail "440 byte cmdline refused"
rm -f "$tmp/full.img"
opts="$opts0 $(pad $(( 441 - ${#base} - 25 )))"
if bake --out "$tmp/x" 2>/dev/null; then fail "441 byte cmdline accepted"; fi
opts="$opts0 $fill$(pad 10)"
if bake --kernel "$stub" --test gptdump --maxcpus 1 --slot-a --out "$tmp/x" 2>/dev/null; then
  fail "slot a over 440 without cpuidle.off=1 accepted"
fi
opts=$opts0

image "$tmp/edge" $(( MICROOS_ABL_BUDGET - ram - 1 )) 1000
bake --kernel "$tmp/edge" --out "$tmp/edge.img" >/dev/null || fail "kernel one byte under the budget refused"
rm -f "$tmp/edge.img"
image "$tmp/over" $(( MICROOS_ABL_BUDGET - ram )) 1000
out=$(bake --kernel "$tmp/over" --out "$tmp/x" 2>&1) && fail "kernel at the budget accepted"
[[ $out == *"ABL budget is $MICROOS_ABL_BUDGET"* ]] || fail "budget refusal message: $out"

if bake --test reboot --out "$tmp/x" 2>/dev/null; then fail "unknown --test word accepted"; fi
if bake --maxcpus 9 --out "$tmp/x" 2>/dev/null; then fail "--maxcpus 9 accepted"; fi
if bake --kernel "$initrd" --out "$tmp/x" 2>/dev/null; then fail "non Image kernel accepted"; fi
opts="root=UUID=r ostree=/ostree/deploy"
if bake --out "$tmp/x" 2>/dev/null; then fail "bootlink outside a deployment accepted"; fi
opts="ostree=/ostree/boot.1/default/$bootcsum/0 quiet"
if bake --root-missing --out "$tmp/x" 2>/dev/null; then fail "--root-missing accepted without root="; fi
opts=$opts0
mv "$droot/usr/share/microos/avb/testkey_rsa4096.pem" "$tmp/key"
if bake --out "$tmp/x" 2>/dev/null; then fail "bake without the test key accepted"; fi
mv "$tmp/key" "$droot/usr/share/microos/avb/testkey_rsa4096.pem"
[[ ! -e $tmp/x ]] || fail "failed bake left an output"

if (( rc == 0 )); then
  echo "bootimg: ok"
fi
exit "$rc"
