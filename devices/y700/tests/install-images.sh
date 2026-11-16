#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
helper=localhost/microos-y700-install
usage="usage: install-images.sh --image <repo@sha256:digest> --channel <tag> --vendor-fw <tar> --non-hlos <NON-HLOS.bin> --btfm <BTFM.bin> --work <dir> --out <dir> [--authorized-keys <file>] [--wifi <name>.nmconnection] [--dtbo <dtbo_b readback>] [--no-build] [build args...]"
root_part=726392975360
efi_part=1073741824
vendor_files=(gen70900_sqe.fw gmu_gen70900.bin gen70900_aqe.fw gen70900_zap.mbn novatek_ts_boe_fw.bin
  novatek_ts_csot_fw.bin)
gpu_files=(gen70900_sqe.fw gmu_gen70900.bin gen70900_aqe.fw)
root_files=(haptic_ram.bin)
pa_files=(aw882xx_acf.bin)
bt_files=(hmtbtfw20.tlv hmtnv20_Kirby_row.bin)

rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
die() { echo "install-images: $*" >&2; exit 1; }

image="" channel="" vendor="" nonhlos="" btfm="" wifi="" work="" out="" keys="" dtbo="" inner=0 nobuild=0
build=()
while (( $# )); do
  case $1 in
    --image) image=${2:?$usage}; build+=("$1" "$2"); shift 2 ;;
    --channel) channel=${2:?$usage}; build+=("$1" "$2"); shift 2 ;;
    --vendor-fw) vendor=${2:?$usage}; build+=("$1" "$2"); shift 2 ;;
    --non-hlos) nonhlos=${2:?$usage}; build+=("$1" "$2"); shift 2 ;;
    --btfm) btfm=${2:?$usage}; build+=("$1" "$2"); shift 2 ;;
    --wifi) wifi=${2:?$usage}; build+=("$1" "$2"); shift 2 ;;
    --work) work=${2:?$usage}; build+=("$1" "$2"); shift 2 ;;
    --out) out=${2:?$usage}; build+=("$1" "$2"); shift 2 ;;
    --authorized-keys) keys=${2:?$usage}; shift 2 ;;
    --dtbo) dtbo=${2:?$usage}; shift 2 ;;
    --no-build) nobuild=1; shift ;;
    --inner) inner=1; shift ;;
    *) build+=("$1"); shift ;;
  esac
done
[[ -n $image && -n $channel && -n $vendor && -n $nonhlos && -n $btfm && -n $work && -n $out ]] || die "$usage"

if (( ! inner )); then
  z=$(printf '%064d' 0)
  for c in "stub7f once|cannot read" "stub7f once noroot|cannot read" "stub1 1|cannot read" "stub7f|has no test case" \
    "once|has no stub" "stub7f once bogus|unknown boot image word"; do
    e=$("$repo/build/y700-install-images.sh" --image "x/y@sha256:$z" --channel t --vendor-fw /nonexistent --non-hlos /nonexistent \
      --btfm /nonexistent --authorized-keys /nonexistent --work /nonexistent --out /nonexistent --kround p2c \
      --deployment "$z.0" --bootimg "${c%%|*}" 2>&1) && die "--kround --bootimg '${c%%|*}' exit 0"
    [[ $e == *"${c#*|}"* ]] || die "--kround --bootimg '${c%%|*}': $e"
  done
  mkdir -p "$work"
  t=$(mktemp -d "$(realpath "$work")/check.XXXXXX")
  trap 'rm -rf "${t:?}"' EXIT
  if [[ -z $keys ]]; then
    (( ! nobuild )) || die "--no-build needs the --authorized-keys file of the build"
    keys=$t/keys
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIInstallImagesTestKeyInstallImagesTestKey0 install-images-test\n' > "$keys"
  fi
  (( nobuild )) || "$repo/build/y700-install-images.sh" "${build[@]}" --authorized-keys "$keys"
  out=$(realpath "$out") work=$(realpath "$work")
  mounts=(-v "$repo:/repo:ro" -v "$work:/work" -v "$out:/out:ro" -v "$(realpath "$vendor"):/in/vendor-firmware.tar:ro"
    -v "$(realpath "$nonhlos"):/in/NON-HLOS.bin:ro" -v "$(realpath "$btfm"):/in/BTFM.bin:ro" -v "$(realpath "$keys"):/in/keys:ro")
  args=(--inner --image "$image" --channel "$channel" --vendor-fw /in/vendor-firmware.tar --non-hlos /in/NON-HLOS.bin
    --btfm /in/BTFM.bin --work /work --out /out)
  if [[ -n $wifi ]]; then
    mounts+=(-v "$(realpath "$wifi"):/in/wifi.nmconnection:ro")
    args+=(--wifi /in/wifi.nmconnection)
  fi
  if [[ -n $dtbo ]]; then
    mounts+=(-v "$(realpath "$dtbo"):/in/dtbo.img:ro")
    args+=(--dtbo /in/dtbo.img)
  fi
  sudo -n podman run --rm --privileged --memory=14g --cpus=6 -v /dev:/dev "${mounts[@]}" "$helper" \
    /repo/tests/install-images.sh "${args[@]}"
  exit
fi

(( EUID == 0 )) || die "run as root"
w=$(mktemp -d "$work/check.XXXXXX")
loop=""
cleanup() {
  local m
  for m in "$w/mnt/root" "$w/mnt/top"; do
    if mountpoint -q "$m"; then
      umount "$m" || return 0
    fi
  done
  [[ -z $loop ]] || losetup -d "$loop" || true
  rm -rf --one-file-system "${w:?}"
}
trap cleanup EXIT
top=$w/mnt/top
T=$w/mnt/root
mkdir -p "$top" "$T" "$w/fw/nh" "$w/fw/bt"
imgrepo=${image%@*}
. "$out/build.env"
[[ $IMAGE == "$image" ]] || fail "build.env IMAGE $IMAGE, expected $image"

(cd "$out" && sha256sum --quiet -c SHA256SUMS) || fail "output SHA256SUMS"
for f in "$out"/*; do
  case ${f##*/} in
    SHA256SUMS|build.env|bootimg.ids|efi.img|efi.simg|fw.SHA256SUMS|root.simg|boot*.img|boot*.img.info) ;;
    *) fail "unexpected output ${f##*/}" ;;
  esac
done

if [[ -n ${KROUND:-} ]]; then
  for f in root.simg efi.img efi.simg fw.SHA256SUMS; do
    [[ ! -e $out/$f ]] || fail "--kround set has $f"
  done
  [[ $DEPLOYMENT == "$COMMIT.0" ]] || fail "DEPLOYMENT $DEPLOYMENT is not $COMMIT.0"
  n=0
  while read -r name id; do
    info=$(unpack_bootimg --boot_img "$out/$name" --out "$w/unpack" --format=info)
    c=$(sed -n 's/^command line args: //p' <<< "$info")
    cw=" $c "
    (( ${#c} <= 440 )) || fail "$name: cmdline ${#c} bytes"
    [[ $name =~ ^boot-$KROUND-stub[17]f?- ]] || fail "$name: not a $KROUND stub image"
    for k in "microos.kround=$KROUND" "microos.deploy=$DEPLOYMENT" "microos.id=${id:0:12}"; do
      [[ $cw == *" $k "* ]] || fail "$name: no $k in the cmdline"
    done
    [[ $cw =~ \ ostree=/ostree/boot\.[01]/default/[0-9a-f]{64}/[0-9]+\  ]] || fail "$name: ostree= is not a boot link"
    [[ $cw == *" microos.test="* ]] || fail "$name: no microos.test"
    [[ $cw == *" maxcpus="[17]" "* ]] || fail "$name: no stub maxcpus"
    case $name in
      *-once*) [[ $(grep -o ' microos\.test=[^ ]*' <<< "$cw" | paste -sd' ') == " microos.test=once" ]] || fail "$name: microos.test is not once alone" ;;
    esac
    case $name in
      *-noroot*) [[ $cw == *" root=PARTLABEL=microos_missing "* ]] || fail "$name: root= not replaced" ;;
      *) [[ $cw == *" root=PARTLABEL=microos "* ]] || fail "$name: no root=PARTLABEL=microos" ;;
    esac
    avb=$(avbtool info_image --image "$out/$name")
    grep -q 'Partition Name: *boot$' <<< "$avb" || fail "$name: AVB partition name"
    (( $(stat -c %s "$out/$name") == 100663296 )) || fail "$name: size is not 100663296"
    margin=$(python3 "$repo/build/y700-abl-budget" "$out/$name" | sed -n 's/^margin //p')
    (( margin >= 4 * 1024 * 1024 )) || fail "$name: ABL budget margin $margin"
    echo "install-images: $name cmdline ${#c} bytes, margin $margin"
    rm -rf "${w:?}/unpack"
    n=$((n + 1))
  done < "$out/bootimg.ids"
  (( n )) || fail "no boot images in the --kround set"
  echo "install-images: SKIP kernel, ramdisk and DTB comparison: a --kround set has no root image"
  if (( rc )); then
    echo "install-images: FAIL"
  else
    echo "install-images: PASS"
  fi
  exit "$rc"
fi

simg_size() {
  python3 - "$1" <<'PY'
import struct, sys
h = open(sys.argv[1], "rb").read(28)
magic, _, _, _, _, blk, total = struct.unpack_from("<IHHHHII", h)
print(blk * total if magic == 0xed26ff3a else -1)
PY
}
rootsize=$(simg_size "$out/root.simg")
(( rootsize > 0 )) || fail "root.simg is not an Android sparse image"
(( rootsize <= root_part )) || fail "root.simg expands to $rootsize bytes, the microos partition holds $root_part"
efisize=$(stat -c %s "$out/efi.img")
(( efisize <= efi_part )) || fail "efi.img is $efisize bytes, microos_efi holds $efi_part"
(( $(simg_size "$out/efi.simg") == efisize )) || fail "efi.simg does not expand to the size of efi.img"
simg2img "$out/efi.simg" "$w/efi.img"
cmp -s "$w/efi.img" "$out/efi.img" || fail "efi.simg differs from efi.img"
rm -f "$w/efi.img"
[[ $(stat -c %a "$out/efi.simg") == 600 ]] || fail "efi.simg mode is not 600"
echo "install-images: root $rootsize bytes of $root_part, efi $efisize bytes of $efi_part"

simg2img "$out/root.simg" "$w/root.img"
(( $(stat -c %s "$w/root.img") == rootsize )) || fail "root.simg does not expand to its header size"
btrfs check --readonly "$w/root.img" > /dev/null 2>&1 || fail "btrfs check root.img"
[[ $(blkid -o value -s LABEL "$w/root.img") == microos ]] || fail "root label is not microos"
loop=$(losetup -r -f --show "$w/root.img")
mount -o ro,subvolid=5 "$loop" "$top"
mount -o ro "$loop" "$T"
[[ $(findmnt -no FSROOT "$T") == /root ]] || fail "default subvolume is $(findmnt -no FSROOT "$T"), expected /root"
[[ $(btrfs property get "$top/root" compression) == compression=zstd ]] || fail "root subvolume compression property"
mapfile -t subvols < <(btrfs subvolume list -o "$top" | awk '{ print $NF }')
[[ ${subvols[*]} == root ]] || fail "subvolumes: ${subvols[*]}"

deps=("$T"/ostree/deploy/*/deploy/*)
deps=("${deps[@]%.origin}")
mapfile -t deps < <(printf '%s\n' "${deps[@]}" | sort -u)
(( ${#deps[@]} == 1 )) && [[ -d ${deps[0]} ]] || fail "expected one deployment, found ${deps[*]}"
dep=${deps[0]}
[[ $dep == "$T/ostree/deploy/default/deploy/"* ]] || fail "deployment is not in stateroot default"
[[ ${dep##*/} == "$COMMIT.0" ]] || fail "deployment ${dep##*/}, expected $COMMIT.0"
grep -qxF "container-image-reference=ostree-image-signed:docker://$imgrepo:$channel" "$dep.origin" \
  || fail "origin: $(cat "$dep.origin")"
R=$T/ostree/repo
mapfile -t irefs < <(ostree refs --repo="$R" ostree/container/image)
(( ${#irefs[@]} == 1 )) || fail "expected one ostree/container/image ref, found ${#irefs[@]}"
[[ $(ostree rev-parse --repo="$R" "ostree/container/image/${irefs[0]}") == "$COMMIT" ]] || fail "image ref is not $COMMIT"
! ostree ls --repo="$R" -R -X "$COMMIT" /usr/lib/bootc 2>/dev/null | grep -q "btrfs\." || fail "the commit carries btrfs.* xattrs"
ostree fsck --repo="$R" > "$w/fsck" 2>&1 || fail "ostree fsck: $(grep -c Corrupted "$w/fsck") corrupted objects"
for k in bootloader:none bootprefix:true readonly:true; do
  v=$(awk -F' *= *' -v k="${k%%:*}" '/^\[/ { s = $0 } s == "[sysroot]" && $1 == k { print $2 }' "$R/config")
  [[ $v == "${k#*:}" ]] || fail "sysroot.${k%%:*} is ${v:-unset}"
done

entries=("$T"/boot/loader/entries/*.conf)
(( ${#entries[@]} == 1 )) && [[ -f ${entries[0]} ]] || fail "expected one BLS entry"
options=$(sed -n 's/^options[[:space:]]\+//p' "${entries[0]}")
words=" $options "
[[ $words == *" root=PARTLABEL=microos "* ]] || fail "no root=PARTLABEL=microos in the BLS options"
link=$(grep -o '\bostree=[^ ]*' <<< "$options" | head -1)
[[ $(realpath -e "$T${link#ostree=}") == "$dep" ]] || fail "$link does not resolve to the deployment"
mapfile -t want < <(python3 - "$dep/usr/lib/bootc/kargs.d" <<'PY'
import pathlib, sys, tomllib
for p in sorted(pathlib.Path(sys.argv[1]).glob("*.toml")):
    d = tomllib.loads(p.read_text())
    if "aarch64" in d.get("match-architectures", ["aarch64"]):
        print("\n".join(d.get("kargs", [])))
PY
)
(( ${#want[@]} )) || fail "no aarch64 kargs in usr/lib/bootc/kargs.d"
for k in "${want[@]}"; do
  [[ $words == *" $k "* ]] || fail "karg $k missing from the BLS options"
done
echo "install-images: BLS options: $options"

grep -qxF 'PARTLABEL=microos_efi /boot/efi vfat nofail,x-systemd.device-timeout=10s,umask=0077 0 2' "$dep/etc/fstab" \
  || fail "no /boot/efi line by PARTLABEL in the deployment's fstab"
(( $(awk '$1 !~ /^#/ && $2 == "/boot/efi"' "$dep/etc/fstab" | wc -l) == 1 )) || fail "more than one /boot/efi line"
[[ -d $T/boot/efi ]] || fail "no /boot/efi mount point in the sysroot"
sudo=$dep/etc/sudoers.d/90-micro-nopasswd
if [[ ${DEV_SUDO:-0} == 1 ]]; then
  [[ $(stat -c '%a %U' "$sudo" 2>/dev/null) == '440 root' && $(< "$sudo") == 'micro ALL=(ALL) NOPASSWD: ALL' ]] \
    || fail "--dev-sudo: $sudo missing or wrong"
else
  [[ ! -e $sudo ]] || fail "$sudo without --dev-sudo"
fi

fw=$T/ostree/deploy/default/var/lib/microos/fw
dev=$fw/qcom/sm8650/lenovo/tb321fu
tar -x -f "$vendor" -C "$w/fw" "${vendor_files[@]/#/firmware/}" "${root_files[@]/#/firmware/}" "${pa_files[@]/#/firmware/}" \
  firmware/vpu33_4v.mbn
mcopy -n -i "$nonhlos" "::/image/adsp*" "::/image/cdsp*" "::/image/ipa_fws*" "$w/fw/nh/"
mcopy -n -i "$btfm" "${bt_files[@]/#/::/image/}" "$w/fw/bt/"
expect=(qcom/sm8650/lenovo/tb321fu/vpu33_p4.mbn)
cmp -s "$w/fw/firmware/vpu33_4v.mbn" "$dev/vpu33_p4.mbn" || fail "$dev/vpu33_p4.mbn differs from the vendor vpu33_4v.mbn"
for f in "${bt_files[@]}"; do
  cmp -s "$w/fw/bt/$f" "$fw/qca/$f" || fail "$fw/qca/$f differs from BTFM.bin"
  expect+=("qca/$f")
done
if [[ -n ${WLAN_BOARD:-} ]]; then
  mcopy -n -i "$nonhlos" "::/image/kiwi/$WLAN_BOARD" "$w/fw/$WLAN_BOARD"
  cmp -s "$w/fw/$WLAN_BOARD" "$fw/ath12k/WCN7850/hw2.0/board.bin" || fail "ath12k board.bin differs from $WLAN_BOARD"
  expect+=(ath12k/WCN7850/hw2.0/board.bin)
fi
for f in "${vendor_files[@]}"; do
  cmp -s "$w/fw/firmware/$f" "$dev/$f" || fail "$dev/$f differs from the vendor copy"
  expect+=("qcom/sm8650/lenovo/tb321fu/$f")
done
for f in "${gpu_files[@]}"; do
  cmp -s "$w/fw/firmware/$f" "$fw/qcom/$f" || fail "$fw/qcom/$f differs from the vendor copy"
  expect+=("qcom/$f")
done
for f in "${root_files[@]}"; do
  cmp -s "$w/fw/firmware/$f" "$fw/$f" || fail "$fw/$f differs from the vendor copy"
  expect+=("$f")
done
for f in "${pa_files[@]}"; do
  cmp -s "$w/fw/firmware/$f" "$fw/$f" || fail "$fw/$f differs from the vendor copy"
  cmp -s "$w/fw/firmware/$f" "$dev/$f" || fail "$dev/$f differs from the vendor copy"
  expect+=("$f" "qcom/sm8650/lenovo/tb321fu/$f")
done
[[ -z ${TPLG:-} ]] || expect+=(qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin)
nnh=0
for f in "$w"/fw/nh/*; do
  cmp -s "$f" "$dev/${f##*/}" || fail "$dev/${f##*/} differs from NON-HLOS.bin"
  expect+=("qcom/sm8650/lenovo/tb321fu/${f##*/}")
  nnh=$((nnh + 1))
done
(( nnh )) || fail "no adsp, cdsp or ipa_fws files in NON-HLOS.bin"
for p in adsp.mdt cdsp.mdt ipa_fws.mdt; do
  [[ -f $dev/$p ]] || fail "no $p in $dev"
done
diff <(printf '%s\n' "${expect[@]}" SHA256SUMS | LC_ALL=C sort) <(cd "$fw" && find . -type f -printf '%P\n' | LC_ALL=C sort) \
  > "$w/fw.diff" || fail "firmware files differ from the planned set: $(cat "$w/fw.diff")"
(cd "$fw" && sha256sum --quiet -c SHA256SUMS) || fail "firmware SHA256SUMS"
cmp -s "$fw/SHA256SUMS" "$out/fw.SHA256SUMS" || fail "fw.SHA256SUMS differs from the image copy"
[[ -z $(find "$T" -name wlan_mac.bin) ]] || fail "wlan_mac.bin in the root image"
echo "install-images: firmware ${#expect[@]} files, $nnh from NON-HLOS.bin"

selinux=$(sed -n 's/^SELINUXTYPE=//p' "$dep/etc/selinux/config")
fc=$dep/etc/selinux/${selinux:-targeted}/contexts/files/file_contexts
for d in "$dep:$dep/usr" "$dep:$dep/etc" "$T/ostree/deploy/default:$T/ostree/deploy/default/var"; do
  n=$(setfiles -n -v -r "${d%%:*}" "$fc" "${d#*:}" 2>&1 | grep -c '^Would relabel' || true)
  (( n == 0 )) || fail "$n files under ${d#*:} do not match file_contexts"
done
[[ $(getfattr --absolute-names --only-values -n security.selinux "$dev/adsp.mdt" | tr -d '\0') == system_u:object_r:*:s0 ]] \
  || fail "firmware has no SELinux label"

fsck.fat -n "$out/efi.img" > /dev/null || fail "fsck.fat efi.img"
[[ $(od -An -tu2 -j11 -N2 "$out/efi.img" | tr -d ' ') == 4096 ]] || fail "efi.img sector size is not 4096"
[[ $(od -An -c -j82 -N5 "$out/efi.img" | tr -d ' ') == FAT32 ]] || fail "efi.img is not FAT32"
[[ $(blkid -o value -s LABEL "$out/efi.img") == MICROOS ]] || fail "efi.img label is not MICROOS"
[[ $(stat -c %a "$out/efi.img") == 600 ]] || fail "efi.img mode is not 600"
mapfile -t efils < <(mdir -/ -b -i "$out/efi.img" :: | sed 's|^::||' | LC_ALL=C sort)
efiwant=(/logs/ /microos/ /microos/authorized_keys /microos/boot-attempts)
(( BOOTIMG )) && efiwant+=(/.microos-bootimg.id /boot.img)
[[ -z $WIFI ]] || efiwant+=("/microos/$WIFI")
mapfile -t efiwant < <(printf '%s\n' "${efiwant[@]}" | LC_ALL=C sort)
[[ ${efils[*]} == "${efiwant[*]}" ]] || fail "efi.img holds ${efils[*]}, expected ${efiwant[*]}"
mcopy -n -i "$out/efi.img" ::/microos/authorized_keys "$w/keys"
cmp -s "$w/keys" /in/keys || fail "efi.img authorized_keys differs"
if [[ -n $WIFI ]]; then
  [[ -n $wifi ]] || fail "efi.img holds a Wi-Fi keyfile, the test got no --wifi"
  mcopy -n -i "$out/efi.img" "::/microos/$WIFI" "$w/wifi"
  [[ -z $wifi ]] || cmp -s "$w/wifi" /in/wifi.nmconnection || fail "efi.img Wi-Fi keyfile differs"
  rm -f "$w/wifi"
  sed -n 's/^psk=//p' /in/wifi.nmconnection > "$w/psk"
  if [[ -s $w/psk ]]; then
    ! grep -qaF -f "$w/psk" "$out"/*.info "$out"/build.env "$out"/bootimg.ids "$out"/SHA256SUMS "$out"/fw.SHA256SUMS \
      || fail "the Wi-Fi psk is in an output text file"
    ! grep -rqaF -f "$w/psk" "$dep/etc" "$T/ostree/deploy/default/var" || fail "the Wi-Fi psk is in the root image"
  fi
  rm -f "$w/psk"
elif [[ -n $wifi ]]; then
  fail "the test got --wifi, efi.img holds no keyfile"
fi
mcopy -n -i "$out/efi.img" ::/microos/boot-attempts "$w/attempts"
[[ ! -s $w/attempts ]] || fail "boot-attempts is not empty"

conf=$dep/usr/lib/microos/bootimg.conf
dtbo_img=$(ls "$dep"/usr/lib/modules/*/dtb/qcom/sm8650-lenovo-tb321fu-dtbo.img 2>/dev/null | head -1 || true)
if [[ -n $dtbo ]]; then
  [[ -n $dtbo_img ]] && cmp -s "$dtbo_img" "$dtbo" || fail "the image's dtbo differs from the dtbo_b readback"
elif [[ -n $dtbo_img ]]; then
  echo "install-images: image dtbo $(sha256sum < "$dtbo_img" | cut -d' ' -f1), no readback given"
else
  echo "install-images: SKIP dtbo: the deployment has no sm8650-lenovo-tb321fu-dtbo.img"
fi

if (( BOOTIMG )); then
  mcopy -n -i "$out/efi.img" ::/boot.img "$w/efi-boot.img"
  cmp -s "$w/efi-boot.img" "$out/boot.img" || fail "efi.img boot.img differs from boot.img"
  mcopy -n -i "$out/efi.img" ::/.microos-bootimg.id "$w/id"
  [[ $(cat "$w/id") == "$(awk '$1 == "boot.img" { print $2 }' "$out/bootimg.ids")" ]] || fail "efi.img id is not boot.img's"
  dtbvar=MICROOS_DTB
  [[ $PANEL == boe ]] || dtbvar=MICROOS_DTB_${PANEL^^}
  dtbrel=$(sed -n "s/^$dtbvar=//p" "$conf" | tr -d "\"'")
  kver=$(sed -n 's/^linux[[:space:]]\+.*vmlinuz-//p' "${entries[0]}")
  get() { sed -n "s/^$1: //p" <<< "$info"; }
  while read -r name id; do
    info=$(unpack_bootimg --boot_img "$out/$name" --out "$w/unpack" --format=info)
    c=$(get 'command line args')
    cw=" $c "
    [[ $(get 'boot image header version') == 2 ]] || fail "$name: header version $(get 'boot image header version')"
    [[ $(get 'page size') == 4096 ]] || fail "$name: page size $(get 'page size')"
    [[ $(get 'os patch level') == 2026-05* ]] || fail "$name: os patch level $(get 'os patch level')"
    (( ${#c} <= 440 )) || fail "$name: cmdline ${#c} bytes"
    for k in root= ostree= microos.deploy= microos.id= firmware_class.path=; do
      [[ $cw == *" $k"* ]] || fail "$name: no $k in the cmdline"
    done
    [[ $cw == *" microos.deploy=${dep##*/} "* ]] || fail "$name: microos.deploy is not ${dep##*/}"
    case $name in
      *-noroot*) [[ $cw == *" root=PARTLABEL=microos_missing "* ]] || fail "$name: root= not replaced" ;;
      *) [[ $cw == *" root=PARTLABEL=microos "* ]] || fail "$name: no root=PARTLABEL=microos" ;;
    esac
    case $name in
      *-slota*) [[ $cw == *" initcall_blacklist=msm_drm_register "* ]] || fail "$name: no initcall_blacklist" ;;
    esac
    case $name in
      *-stub1*) [[ $cw == *" maxcpus=1 "* ]] || fail "$name: no maxcpus=1" ;;
      *-stub7*) [[ $cw == *" maxcpus=7 "* ]] || fail "$name: no maxcpus=7" ;;
      *) [[ $cw != *" maxcpus="* ]] || fail "$name: maxcpus without a stub" ;;
    esac
    case $name in
      boot.img|boot-csot.img) [[ $cw != *" microos.test="* ]] || fail "$name: production image has microos.test" ;;
      *) [[ $cw == *" microos.test="* ]] || fail "$name: test image without microos.test" ;;
    esac
    [[ $cw == *" microos.id=${id:0:12} "* ]] || fail "$name: microos.id is not ${id:0:12}"
    cmp -s "$w/unpack/ramdisk" "$T$(sed -n 's/^initrd[[:space:]]\+//p' "${entries[0]}")" || fail "$name: ramdisk is not the deployment's initramfs"
    gzip -dc "$w/unpack/kernel" > "$w/kernel"
    vmlinuz=$T$(sed -n 's/^linux[[:space:]]\+//p' "${entries[0]}")
    case $name in
      *-stub*)
        payload=$(( $(. "$dep/usr/lib/microos/stub.conf"; echo "$MICROOS_STUB_PAYLOAD") ))
        cmp -s <(tail -c +$((payload + 1)) "$w/kernel") "$vmlinuz" || fail "$name: stub payload is not the deployment's kernel"
        isz() { od -An -tu8 -j16 -N8 --endian=little "$1" | tr -d ' '; }
        (( $(isz "$w/kernel") == $(isz "$vmlinuz") + payload )) || fail "$name: stub image_size"
        ;;
      *) cmp -s "$w/kernel" "$vmlinuz" || fail "$name: kernel is not the deployment's" ;;
    esac
    [[ -f $w/unpack/dtb ]] && cmp -s "$w/unpack/dtb" "$dep/usr/lib/modules/$kver/dtb/$dtbrel" \
      || fail "$name: DTB is not the deployment's $dtbrel"
    avb=$(avbtool info_image --image "$out/$name")
    grep -qx 'Image size: *100663296 bytes' <<< "$avb" || fail "$name: AVB image size"
    grep -q 'Partition Name: *boot$' <<< "$avb" || fail "$name: AVB partition name"
    grep -q 'Rollback Index: *1777939200$' <<< "$avb" || fail "$name: AVB rollback index"
    (( $(stat -c %s "$out/$name") == 100663296 )) || fail "$name: size is not 100663296"
    margin=$(python3 "$repo/build/y700-abl-budget" "$out/$name" | sed -n 's/^margin //p')
    (( margin >= 4 * 1024 * 1024 )) || fail "$name: ABL budget margin $margin"
    echo "install-images: $name cmdline ${#c} bytes, margin $margin"
    rm -rf "${w:?}/unpack"
  done < "$out/bootimg.ids"
else
  echo "install-images: SKIP boot images: built with --no-bootimg"
fi

if (( rc )); then
  echo "install-images: FAIL"
else
  echo "install-images: PASS"
fi
exit "$rc"
