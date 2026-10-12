#!/usr/bin/env bash
set -euo pipefail

raw=${1:?usage: disk.sh <raw> <image ref>}
ref=${2:?usage: disk.sh <raw> <image ref>}

fail() { echo "disk: $*" >&2; exit 1; }

(( EUID == 0 )) || fail "run as root"

work=$(mktemp -d)
loop=
cleanup() {
  local m
  for m in "$work"/mnt/*; do
    if mountpoint -q "$m"; then
      umount "$m" || return 0
    fi
  done
  if [[ -n $loop ]]; then
    losetup -d "$loop" || true
  fi
  rm -rf --one-file-system "$work"
}
trap cleanup EXIT

esp=$work/mnt/esp
boot=$work/mnt/boot
root=$work/mnt/root
mkdir -p "$esp" "$boot" "$root" "$work/bake"

loop=$(losetup -rfP --show "$raw")
for _ in $(seq 50); do
  [[ -b ${loop}p3 ]] && break
  sleep 0.1
done

sfdisk -J "$loop" | jq -e '
  .partitiontable.label == "dos"
  and (.partitiontable.partitions | length) == 3
  and ([.partitiontable.partitions[] | .type] == ["c", "da", "da"])
  and .partitiontable.partitions[0].bootable == true' > /dev/null || fail "not an MBR with p1 c bootable, p2 and p3 da"
sectors=$(blockdev --getsz "$loop")
[[ $(dd if="$loop" bs=512 skip=1 count=1 status=none | head -c 8 | tr -d "\0") != "EFI PART" ]] || fail "primary GPT header left"
[[ $(dd if="$loop" bs=512 skip=$(( sectors - 1 )) count=1 status=none | head -c 8 | tr -d "\0") != "EFI PART" ]] || fail "backup GPT header left"
[[ $(blkid -o value -s LABEL "${loop}p1") == MICROOS ]] || fail "p1 label is not MICROOS"

mount -o ro "${loop}p1" "$esp"
mount -o ro,noload "${loop}p2" "$boot"
[[ ! -e $esp/EFI ]] || fail "EFI dir on p1"
[[ ! -e $boot/bootupd-state.json ]] || fail "bootupd-state.json on p2"
[[ -f $esp/KERNEL ]] || fail "no KERNEL on p1"

entries=("$boot"/loader/entries/*.conf)
[[ ${#entries[@]} == 1 && -f ${entries[0]} ]] || fail "expected one BLS entry"
bls() { sed -n "s/^$1[[:space:]]\+//p" "${entries[0]}"; }
bootpath() {
  if [[ $1 == /boot/* && -e $boot${1#/boot} ]]; then
    printf '%s\n' "${1#/boot}"
  else
    printf '%s\n' "$1"
  fi
}
options=$(bls options)
[[ $options != *PARTUUID=* ]] || fail "PARTUUID= in the BLS options"
subvol=$(grep -o 'rootflags=[^ ]*' <<< "$options" | tr , '\n' | sed -n 's/^\(rootflags=\)\?subvol=//p' | head -1 || true)
[[ -n $subvol ]] || fail "no rootflags subvol= in the BLS options"
mount -o "ro,subvol=$subvol" "${loop}p3" "$root"

kernel=$(bootpath "$(bls linux)")
initrd=$(bootpath "$(bls initrd)")
fdtdir=$(bootpath "$(bls fdtdir)")
link=$(grep -o '\bostree=[^ ]*' <<< "$options" | head -1 || true)
link=${link#ostree=}
[[ -n $link ]] || fail "no ostree= in the BLS options"
deploy=$(realpath -e "$root$link") || fail "$link does not resolve on p3"
[[ $deploy == "$root"/ostree/deploy/*/deploy/* ]] || fail "$link does not resolve to a deployment"
dtb=$(sed -n 's/^MICROOS_DTB=//p' "$deploy/usr/lib/microos/bootimg.conf") || fail "the deployment has no bootimg.conf"
version=$(sed -n 's/^IMAGE_VERSION=//p' "$deploy/usr/lib/microos/version") || fail "the deployment has no version file"
[[ $version =~ ^([0-9]{4})([0-9]{2})[0-9]{2}\. ]] || fail "IMAGE_VERSION $version"
patch=${BASH_REMATCH[1]}-${BASH_REMATCH[2]}

cmdline=$(python3 - "$esp/KERNEL" "$boot$kernel" "$boot$initrd" "$boot$fdtdir/$dtb" "$patch" <<'EOF'
import hashlib, struct, sys, zlib

img, vmlinuz, initrd, dtb = (open(p, 'rb').read() for p in sys.argv[1:5])
year, month = map(int, sys.argv[5].split('-'))

def fail(msg):
    sys.exit('disk: KERNEL ' + msg)

(magic, ksize, kaddr, rsize, raddr, ssize, saddr, taddr, psize, hver,
 osv) = struct.unpack_from('<8s10I', img, 0)
if magic != b'ANDROID!':
    fail('magic')
want = dict(header_version=(hver, 0), page_size=(psize, 2048), kernel_addr=(kaddr, 0x10008000),
            ramdisk_addr=(raddr, 0x16000000), tags_addr=(taddr, 0x10000100), second_size=(ssize, 0),
            second_addr=(saddr, 0), os_version=(osv >> 11, 12 << 14),
            os_patch_level=(osv & 0x7ff, ((year - 2000) << 4) | month))
for k, (got, exp) in want.items():
    if got != exp:
        fail(f'{k} {got:#x}, expected {exp:#x}')
if any(img[48:64]):
    fail('name is not empty')
cmd = img[64:576]
if cmd[511] != 0:
    fail('cmdline is longer than 511 bytes')
if any(img[608:1632]):
    fail('extra_cmdline is not empty')

pages = lambda n: (n + psize - 1) // psize * psize
k = img[psize:psize + ksize]
r = img[psize + pages(ksize):psize + pages(ksize) + rsize]
sha = hashlib.sha1()
for part in (k, r, b''):
    sha.update(part)
    sha.update(struct.pack('<I', len(part)))
if img[576:596] != sha.digest() or any(img[596:608]):
    fail('id does not match the payload')
if r != initrd:
    fail('ramdisk differs from the BLS initrd')

d = zlib.decompressobj(31)
image = d.decompress(k)
if not d.eof:
    fail('kernel is not one complete gzip stream')
if image[0x38:0x3c] != b'ARM\x64':
    fail('kernel does not gunzip to an arm64 Image')
if image != vmlinuz:
    fail('kernel differs from the BLS linux')
tail = d.unused_data
if tail[:4] != b'\xd0\x0d\xfe\xed' or struct.unpack_from('>I', tail, 4)[0] != len(tail):
    fail('payload after the gzip stream is not exactly one DTB')
if tail != dtb:
    fail('appended DTB differs from the deployment DTB')

print(cmd.split(b'\0', 1)[0].decode())
EOF
)

read -ra words <<< "$cmdline"
(( ${#cmdline} <= 511 )) || fail "cmdline is ${#cmdline} bytes"
[[ ${words[0]} == "ostree=$link" ]] || fail "cmdline does not start with ostree=$link"
[[ ${words[-1]} == "microos.deploy=$(basename "$deploy")" ]] || fail "microos.deploy is not $(basename "$deploy")"
[[ $cmdline != *PARTUUID=* ]] || fail "PARTUUID= in the cmdline"
rootflags=$(grep -o '\brootflags=[^ ]*' <<< "$cmdline" || true)
[[ -n $rootflags ]] || fail "no rootflags= in the cmdline"
[[ $(wc -l <<< "$rootflags") == 1 ]] || fail "more than one rootflags="
for f in "subvol=$subvol" noatime compress=zstd:1; do
  [[ ,${rootflags#rootflags=}, == *",$f,"* ]] || fail "rootflags has no $f"
done

fstab=$deploy/etc/fstab
! grep -q PARTUUID= "$fstab" || fail "PARTUUID= in /etc/fstab"
awk -v u="UUID=$(blkid -o value -s UUID "${loop}p2")" '$1 == u && $2 == "/boot" { f = 1 } END { exit !f }' "$fstab" \
  || fail "/etc/fstab does not mount /boot by UUID"
awk -v u="UUID=$(blkid -o value -s UUID "${loop}p1")" '$1 == u && $2 == "/boot/efi" { f = 1 } END { exit !f }' "$fstab" \
  || fail "/etc/fstab does not mount /boot/efi by UUID"
awk '$2 == "/boot/efi" { n = split($4, o, ","); for (i = 1; i <= n; i++) if (o[i] == "umask=0077" || o[i] == "umask=077") f = 1 } END { exit !f }' "$fstab" \
  || fail "/etc/fstab does not mount /boot/efi with umask=0077"

keys=("$deploy"/etc/ssh/ssh_host_*)
[[ ! -e ${keys[0]} ]] || fail "SSH host keys in the deployment: ${keys[*]##*/}"
if [[ -s $deploy/etc/machine-id ]]; then
  [[ $(cat "$deploy/etc/machine-id") == uninitialized ]] || fail "machine-id is set in the deployment"
fi

bootloader=$(awk -F' *= *' '/^\[/ { s = $0 } s == "[sysroot]" && $1 == "bootloader" { print $2 }' "$root/ostree/repo/config")
[[ $bootloader == none ]] || fail "sysroot.bootloader is ${bootloader:-unset}"

origin=$(sed -n 's/^container-image-reference=//p' "$deploy.origin")
[[ $origin == *":$ref" ]] || fail "origin is ${origin:-unset}, expected $ref"

id=$(podman run --rm --pull=never --net=none --security-opt label=disable \
  -v "$boot:/run/disk/boot:ro" \
  -v "$root:/run/disk/root:ro" \
  -v "$work/bake:/run/disk/out" \
  --entrypoint /usr/libexec/microos/microos-bootimg-build \
  "$ref" \
  --root "/run/disk/root${deploy#"$root"}" \
  --kernel "/run/disk/boot$kernel" \
  --initrd "/run/disk/boot$initrd" \
  --dtb "/run/disk/boot$fdtdir/$dtb" \
  --options "$options" \
  --sysroot /run/disk/root \
  --out /run/disk/out/KERNEL)
[[ $(cat "$esp/.microos-bootimg.id") == "$id" ]] || fail "stamp differs from a rebake ($id)"
cmp -s "$esp/KERNEL" "$work/bake/KERNEL" || fail "KERNEL differs from a rebake"

echo "disk: ok, KERNEL $(stat -c %s "$esp/KERNEL") bytes, cmdline ${#cmdline} bytes"
