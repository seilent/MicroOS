#!/usr/bin/env bash
set -euo pipefail

me=y700-install-images
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
helper=localhost/microos-y700-install
usage="usage: $me --image <repo@sha256:digest> --channel <tag> --vendor-fw <vendor-firmware.tar> --non-hlos <NON-HLOS.bin> --btfm <BTFM.bin> --authorized-keys <file> --work <dir> --out <dir> [--key <cosign.pub>] [--panel boe|csot] [--size <bytes>] [--f1] [--bootimg <spec>]... [--no-bootimg] [--wifi <name>.nmconnection] [--wlan-board bdwlan.e<xx>] [--dev-sudo] [--tplg <Lenovo-Y700-TB321FU-tplg.bin>] [--kround <round> --deployment <checksum>.<serial>]"
root_part=726392975360
efi_part=1073741824
f1_set=("stub1 1" "stub1f slota gptdump" "stub1f slota bootloader" "stub1f slota panic" "stub1f slota emergency"
  "stub1f slota noroot noguard" "stub7 1" "stub7 wdhang" "stub1 noroot noguard")
vendor_files=(gen70900_sqe.fw gmu_gen70900.bin gen70900_aqe.fw gen70900_zap.mbn novatek_ts_boe_fw.bin
  novatek_ts_csot_fw.bin)
gpu_files=(gen70900_sqe.fw gmu_gen70900.bin gen70900_aqe.fw)
root_files=(haptic_ram.bin)
pa_files=(aw882xx_acf.bin)
nonhlos_globs=("adsp*" "cdsp*" "ipa_fws*")
vpu_vendor=vpu33_4v.mbn
vpu_dts=vpu33_p4.mbn
bt_files=(hmtbtfw20.tlv hmtnv20_Kirby_row.bin)

die() { echo "$me: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }

image="" channel="" vendor="" nonhlos="" btfm="" wifi="" wlanbd="" tplg="" keys="" work="" out="" key=$repo/system_files/usr/share/microos/keys/microos.pub
panel=boe size=$((16 * 1024 * 1024 * 1024)) bootimg=1 devsudo=0 inner=0 owner="" kround="" bdeploy=""
specs=("")
while (( $# )); do
  case $1 in
    --image) image=${2:?$usage}; shift 2 ;;
    --channel) channel=${2:?$usage}; shift 2 ;;
    --vendor-fw) vendor=${2:?$usage}; shift 2 ;;
    --non-hlos) nonhlos=${2:?$usage}; shift 2 ;;
    --btfm) btfm=${2:?$usage}; shift 2 ;;
    --wifi) wifi=${2:?$usage}; shift 2 ;;
    --wlan-board) wlanbd=${2:?$usage}; shift 2 ;;
    --dev-sudo) devsudo=1; shift ;;
    --tplg) tplg=${2:?$usage}; shift 2 ;;
    --kround) kround=${2:?$usage}; shift 2 ;;
    --deployment) bdeploy=${2:?$usage}; shift 2 ;;
    --authorized-keys) keys=${2:?$usage}; shift 2 ;;
    --work) work=${2:?$usage}; shift 2 ;;
    --out) out=${2:?$usage}; shift 2 ;;
    --key) key=${2:?$usage}; shift 2 ;;
    --panel) panel=${2:?$usage}; shift 2 ;;
    --size) size=${2:?$usage}; shift 2 ;;
    --f1) specs+=("${f1_set[@]}"); shift ;;
    --bootimg) specs+=("${2:?$usage}"); shift 2 ;;
    --no-bootimg) bootimg=0; shift ;;
    --inner) inner=1; shift ;;
    --owner) owner=${2:?$usage}; shift 2 ;;
    *) die "$usage" ;;
  esac
done
[[ -n $image && -n $channel && -n $vendor && -n $nonhlos && -n $btfm && -n $keys && -n $work && -n $out ]] || die "$usage"
[[ $image =~ ^([a-z0-9][a-z0-9./_-]*)@(sha256:[0-9a-f]{64})$ ]] || die "--image must be <repo>@sha256:<digest>, got $image"
imgrepo=${BASH_REMATCH[1]}
[[ $channel =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || die "bad --channel $channel"
[[ $panel == boe || $panel == csot ]] || die "--panel is boe or csot"
[[ $size =~ ^[0-9]+$ ]] || die "--size is a byte count"
[[ -z $wlanbd || $wlanbd =~ ^bdwlan\.e[0-9a-f]{2}$ ]] || die "--wlan-board is bdwlan.e<two hex digits>"
if [[ -n $kround || -n $bdeploy ]]; then
  [[ $kround =~ ^p[0-9][a-z]?(-[a-z]+)?$ ]] || die "--kround is a round name like p1a or p1a-hang, got '$kround'"
  [[ $bdeploy =~ ^[0-9a-f]{64}\.[0-9]+$ ]] || die "--deployment is <checksum>.<serial> from ostree admin status, got '$bdeploy'"
  (( bootimg )) || die "--kround builds boot images only, --no-bootimg leaves nothing"
  (( ${#specs[@]} > 1 )) || specs+=("stub1 1")
  re=' (1|once|noguard|bootloader|panic|emergency|wdhang|gptdump) '
  for s in "${specs[@]:1}"; do
    [[ " $s " =~ \ stub[17]f?\  ]] || die "--kround image '$s' has no stub"
    [[ " $s " =~ $re ]] || die "--kround image '$s' has no test case, ttyGS0 needs microos.test"
  done
fi

spec_name() {
  local x name=boot${kround:+-$kround}
  for x in $1; do
    case $x in
      1) name+=-test1 ;;
      *) name+=-$x ;;
    esac
  done
  [[ $panel == boe ]] || name+=-$panel
  printf '%s.img\n' "$name"
}
for s in "${specs[@]}"; do
  for x in $s; do
    case $x in
      stub1|stub7|stub1f|stub7f|slota|noroot|1|once|noguard|bootloader|panic|emergency|wdhang|gptdump) ;;
      *) die "unknown boot image word '$x' in '$s'" ;;
    esac
  done
done

if (( ! inner )); then
  for f in "$vendor" "$nonhlos" "$btfm" "$keys" "$key" ${wifi:+"$wifi"}; do
    [[ -f $f && -r $f ]] || die "cannot read $f"
  done
  vendor=$(realpath "$vendor") nonhlos=$(realpath "$nonhlos") btfm=$(realpath "$btfm") keys=$(realpath "$keys")
  wifimount=()
  if [[ -n $wifi ]]; then
    wifi=$(realpath "$wifi")
    [[ ${wifi##*/} =~ ^[A-Za-z0-9._-]+\.nmconnection$ ]] || die "--wifi must be a <name>.nmconnection file"
    [[ $(stat -c %a "$wifi") == 600 ]] || die "$wifi is not mode 600"
    wifimount=(-v "$wifi:/in/wifi/${wifi##*/}:ro")
  fi
  sums=$(dirname "$vendor")/SHA256SUMS
  [[ -r $sums ]] || die "no SHA256SUMS beside $vendor"
  want=$(awk -v f="${vendor##*/}" '$2 == f || $2 == "*" f { print $1 }' "$sums")
  [[ -n $want ]] || die "$sums has no line for ${vendor##*/}"
  [[ $(sha256sum < "$vendor" | cut -d' ' -f1) == "$want" ]] || die "${vendor##*/} does not match $sums"
  mkdir -p "$work"
  work=$(realpath "$work")
  avail=$(df --output=avail -B1 "$work" | tail -1)
  (( avail > 48 * 1024 * 1024 * 1024 )) || die "$work has $avail bytes free, need 48 GiB"
  if [[ -e $out ]]; then
    [[ -d $out && -z $(ls -A "$out") ]] || die "$out exists and is not an empty directory"
  fi
  install -d -m 0700 "$out"
  out=$(realpath "$out")
  log "cosign verify $image"
  cosign verify --key "$key" "$image" > /dev/null
  sudo -n podman build -q --memory=14g -t "$helper" -f "$here/install.Containerfile" "$here" > /dev/null
  args=(--inner --owner "$(id -u):$(id -g)" --image "$image" --channel "$channel" --vendor-fw /in/vendor-firmware.tar
    --non-hlos /in/NON-HLOS.bin --btfm /in/BTFM.bin --authorized-keys /in/authorized_keys --work /work --out /out
    --panel "$panel" --size "$size")
  (( bootimg )) || args+=(--no-bootimg)
  [[ -z $wifi ]] || args+=(--wifi "/in/wifi/${wifi##*/}")
  [[ -z $wlanbd ]] || args+=(--wlan-board "$wlanbd")
  (( ! devsudo )) || args+=(--dev-sudo)
  [[ -z $tplg ]] || { args+=(--tplg /in/tplg.bin); wifimount+=(-v "$(realpath "$tplg"):/in/tplg.bin:ro"); }
  [[ -z $kround ]] || args+=(--kround "$kround" --deployment "$bdeploy")
  for s in "${specs[@]:1}"; do
    args+=(--bootimg "$s")
  done
  exec sudo -n podman run --rm --privileged --memory=14g --cpus=6 -v /dev:/dev \
    -v "$repo:/repo:ro" -v "$work:/work" -v "$out:/out" -v "$vendor:/in/vendor-firmware.tar:ro" \
    -v "$nonhlos:/in/NON-HLOS.bin:ro" -v "$btfm:/in/BTFM.bin:ro" -v "$keys:/in/authorized_keys:ro" "${wifimount[@]}" \
    "$helper" /repo/build/y700-install-images.sh "${args[@]}"
fi

(( EUID == 0 )) || die "run as root"
w=$(mktemp -d "$work/install.XXXXXX")
loop=""
cleanup() {
  local m
  set +e
  for m in "$w/mnt/root" "$w/mnt/top"; do
    if mountpoint -q "$m"; then
      umount "$m" || return 0
    fi
  done
  [[ -z $loop ]] || losetup -d "$loop"
  rm -rf --one-file-system "${w:?}"
  [[ -z $owner ]] || chown -R "$owner" "$out"
}
trap cleanup EXIT
top=$w/mnt/top
T=$w/mnt/root
mkdir -p "$top" "$T" "$w/fw/nh" "$w/fw/bt"

log "root.img ($size bytes, btrfs)"
truncate -s "$size" "$w/root.img"
mkfs.btrfs -q -f -L microos "$w/root.img"
loop=$(losetup -f --show "$w/root.img")
mount -o noatime "$loop" "$top"
btrfs -q subvolume create "$top/root"
btrfs subvolume set-default "$top/root"
umount "$top"
mount -o noatime,compress=zstd:1 "$loop" "$T"
[[ $(findmnt -no FSROOT "$T") == /root ]] || die "the default subvolume is not root"

log "ostree sysroot"
ostree admin init-fs --modern "$T"
R=$T/ostree/repo
ostree config --repo="$R" set sysroot.bootloader none
ostree config --repo="$R" set sysroot.bootprefix true
ostree config --repo="$R" set sysroot.readonly true
ostree admin os-init --sysroot="$T" default

log "pull $image"
ostree container image pull "$R" "ostree-unverified-registry:$image" >&2
mapfile -t irefs < <(ostree refs --repo="$R" ostree/container/image)
(( ${#irefs[@]} == 1 )) || die "expected one image ref, found ${#irefs[@]}"
commit=$(ostree rev-parse --repo="$R" "ostree/container/image/${irefs[0]}")
ostree fsck --repo="$R" > /dev/null || die "ostree fsck failed on the pulled commit"

log "kernel arguments from usr/lib/bootc/kargs.d"
kargs=(--karg=root=PARTLABEL=microos)
if ostree ls --repo="$R" "$commit" /usr/lib/bootc/kargs.d > /dev/null 2>&1; then
  ostree checkout --repo="$R" --subpath=/usr/lib/bootc/kargs.d "$commit" "$w/kargs.d"
  while IFS= read -r a; do
    kargs+=("--karg=$a")
  done < <(python3 - "$w/kargs.d" <<'PY'
import pathlib, sys, tomllib
for p in sorted(pathlib.Path(sys.argv[1]).glob("*.toml")):
    d = tomllib.loads(p.read_text())
    if "match-architectures" in d and "aarch64" not in d["match-architectures"]:
        continue
    for v in d.get("kargs", []):
        if v.startswith(("root=", "ostree=")):
            sys.exit(f"{p.name}: {v} is set by the installer")
        print(v)
PY
  )
fi

log "deploy $commit"
printf '[origin]\ncontainer-image-reference=ostree-image-signed:docker://%s:%s\n' "$imgrepo" "$channel" > "$w/origin"
ostree admin deploy --sysroot="$T" --os=default --no-merge --origin-file="$w/origin" "${kargs[@]}" "$commit"
deps=("$T"/ostree/deploy/default/deploy/*.0)
(( ${#deps[@]} == 1 )) && [[ -d ${deps[0]} ]] || die "expected one deployment"
dep=${deps[0]}
[[ -z $kround || ${dep##*/} == "$bdeploy" ]] || die "$image deploys as ${dep##*/}, not as the device's $bdeploy"
var=$T/ostree/deploy/default/var
entries=("$T"/boot/loader/entries/*.conf)
(( ${#entries[@]} == 1 )) && [[ -f ${entries[0]} ]] || die "expected one BLS entry"
bls() { sed -n "s/^$1[[:space:]]\+//p" "${entries[0]}"; }
options=$(bls options)
[[ -z $kround ]] || options+=" microos.kround=$kround"

log "seed /var"
if ostree ls --repo="$R" "$commit" /var > /dev/null 2>&1; then
  ostree checkout --repo="$R" --force-copy --union --subpath=/var "$commit" "$var"
fi

log "fstab /boot/efi"
fstab=$dep/etc/fstab
[[ ! -s $fstab || -z $(tail -c1 "$fstab") ]] || echo >> "$fstab"
! awk '$1 !~ /^#/ && $2 == "/boot/efi" { f = 1 } END { exit !f }' "$fstab" 2>/dev/null || die "$fstab already mounts /boot/efi"
printf 'PARTLABEL=microos_efi /boot/efi vfat nofail,x-systemd.device-timeout=10s,umask=0077 0 2\n' >> "$fstab"
install -d -m 0755 "$T/boot/efi"
if (( devsudo )); then
  printf 'micro ALL=(ALL) NOPASSWD: ALL\n' > "$w/sudoers"
  install -D -m 0440 "$w/sudoers" "$dep/etc/sudoers.d/90-micro-nopasswd"
fi

log "firmware"
fw=$var/lib/microos/fw
dev=$fw/qcom/sm8650/lenovo/tb321fu
tar -x -f "$vendor" -C "$w/fw" "${vendor_files[@]/#/firmware/}" "${root_files[@]/#/firmware/}" "${pa_files[@]/#/firmware/}" \
  "firmware/$vpu_vendor"
install -D -m 0644 "$w/fw/firmware/$vpu_vendor" "$dev/$vpu_dts"
for f in "${vendor_files[@]}"; do
  install -D -m 0644 "$w/fw/firmware/$f" "$dev/$f"
done
for f in "${gpu_files[@]}"; do
  install -D -m 0644 "$w/fw/firmware/$f" "$fw/qcom/$f"
done
for f in "${root_files[@]}"; do
  install -D -m 0644 "$w/fw/firmware/$f" "$fw/$f"
done
for f in "${pa_files[@]}"; do
  install -D -m 0644 "$w/fw/firmware/$f" "$fw/$f"
  install -D -m 0644 "$w/fw/firmware/$f" "$dev/$f"
done
[[ -z $tplg ]] || install -D -m 0644 "$tplg" "$fw/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin"
mcopy -n -i "$nonhlos" "${nonhlos_globs[@]/#/::/image/}" "$w/fw/nh/"
for f in "$w"/fw/nh/*; do
  install -m 0644 "$f" "$dev/${f##*/}"
done
mcopy -n -i "$btfm" "${bt_files[@]/#/::/image/}" "$w/fw/bt/"
for f in "${bt_files[@]}"; do
  install -D -m 0644 "$w/fw/bt/$f" "$fw/qca/$f"
done
if [[ -n $wlanbd ]]; then
  mcopy -n -i "$nonhlos" "::/image/kiwi/$wlanbd" "$w/fw/$wlanbd"
  install -D -m 0644 "$w/fw/$wlanbd" "$fw/ath12k/WCN7850/hw2.0/board.bin"
fi
[[ -z $(find "$fw" -name wlan_mac.bin) ]] || die "wlan_mac.bin in $fw"
(cd "$fw" && find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum) > "$w/fw.sums"
install -m 0644 "$w/fw.sums" "$fw/SHA256SUMS"

log "SELinux labels"
selinux=$(sed -n 's/^SELINUXTYPE=//p' "$dep/etc/selinux/config" 2>/dev/null || true)
fc=$dep/etc/selinux/${selinux:-targeted}/contexts/files/file_contexts
[[ -r $fc ]] || die "no file_contexts in the deployment ($fc)"
relabel() {
  setfiles -n -v -r "$1" "$fc" "$2" 2>&1 | grep -c '^Would relabel' || true
}
n=$(relabel "$dep" "$dep/usr")
(( n == 0 )) || die "$n files under /usr do not match file_contexts"
for d in "$dep:$dep/etc" "${var%/var}:$var"; do
  n=$(relabel "${d%%:*}" "${d#*:}")
  if (( n )); then
    log "relabel ${d#*:} ($n files)"
    setfiles -r "${d%%:*}" "$fc" "${d#*:}"
  fi
done

mkbootimg_variant() {
  local spec=$1 name=$2 x kernel=$kern args=() pack=()
  for x in $spec; do
    case $x in
      stub1|stub7|stub1f|stub7f)
        [[ $x == *f ]] && pack=(--preset-free)
        x=${x#stub}
        args+=(--maxcpus "${x%f}")
        MICROOS_STUB_CONF=$dep/usr/lib/microos/stub.conf "$repo/build/y700-stub/pack" "${pack[@]}" "$kern" \
          "$w/stub-$name" >&2
        kernel=$w/stub-$name
        ;;
      slota) args+=(--slot-a) ;;
      noroot) args+=(--root-missing) ;;
      *) args+=(--test "$x") ;;
    esac
  done
  bash "$build" --root "$dep" --kernel "$kernel" --initrd "$initrd" --dtb "$dtb" --options "$options" \
    --sysroot "$T" --out "$out/$name" "${args[@]}"
}

ids=()
if (( bootimg )); then
  log "boot images"
  conf=$dep/usr/lib/microos/bootimg.conf
  build=$dep/usr/libexec/microos/microos-bootimg-build
  [[ -r $build ]] || die "the deployment has no microos-bootimg-build"
  grep -q '^MICROOS_AVB_PARTITION_SIZE=' "$conf" || die "the deployment's bootimg.conf has no AVB footer settings"
  [[ " ${specs[*]} " != *stub* || -r $dep/usr/lib/microos/stub.conf ]] || die "the deployment has no stub.conf"
  linux=$(bls linux)
  initrd=$T$(bls initrd)
  kern=$T$linux
  kver=${linux##*/vmlinuz-}
  dtbvar=MICROOS_DTB
  [[ $panel == boe ]] || dtbvar=MICROOS_DTB_${panel^^}
  dtbrel=$(sed -n "s/^$dtbvar=//p" "$conf" | tr -d "\"'")
  [[ -n $dtbrel ]] || die "the deployment's bootimg.conf has no $dtbvar"
  dtb=$dep/usr/lib/modules/$kver/dtb/$dtbrel
  [[ -f $dtb ]] || die "no $dtbrel in the deployment for kernel $kver"
  first=0
  [[ -z $kround ]] || first=1
  for s in "${specs[@]:first}"; do
    name=$(spec_name "$s")
    log "$name${s:+ ($s)}"
    id=$(mkbootimg_variant "$s" "$name")
    [[ $id =~ ^[0-9a-f]{64}$ ]] || die "$name: bootimg-build printed no id"
    ids+=("$name $id")
    {
      unpack_bootimg --boot_img "$out/$name" --out "$w/unpack" --format=info
      avbtool info_image --image "$out/$name"
      python3 "$repo/build/y700-abl-budget" "$out/$name"
    } > "$out/$name.info"
    c=$(sed -n 's/^command line args: //p' "$out/$name.info")
    log "$name: cmdline ${#c} bytes"
  done
  printf '%s\n' "${ids[@]}" > "$out/bootimg.ids"
fi

if [[ -n $kround ]]; then
  printf 'IMAGE=%q\nCHANNEL=%q\nCOMMIT=%q\nDEPLOYMENT=%q\nPANEL=%q\nBOOTIMG=1\nKROUND=%q\nOPTIONS=%q\n' \
    "$image" "$channel" "$commit" "${dep##*/}" "$panel" "$kround" "$options" > "$out/build.env"
  (cd "$out" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum) > "$w/sums"
  mv "$w/sums" "$out/SHA256SUMS"
  cat "$out/SHA256SUMS" >&2
  log "done: $out, $kround boot images for $bdeploy, no root.simg or efi.img"
  exit 0
fi

log "root free space"
free=$(btrfs filesystem usage -b "$T" | awk '/Free \(estimated\)/ { print $3 }')
if (( free < 2 * 1024 * 1024 * 1024 )); then
  size=$((24 * 1024 * 1024 * 1024))
  log "$free bytes free, growing root.img to $size"
  truncate -s "$size" "$w/root.img"
  losetup -c "$loop"
  btrfs filesystem resize max "$T" > /dev/null
fi

btrfs property set "$T" compression zstd
fstrim "$T" || true
umount "$T"
losetup -d "$loop"
loop=""
btrfs check --readonly "$w/root.img" > /dev/null 2>&1 || die "btrfs check failed on root.img"
(( $(stat -c %s "$w/root.img") <= root_part )) || die "root.img is larger than the microos partition"
img2simg "$w/root.img" "$out/root.simg"
rm -f "$w/root.img"

log "efi.img"
efi=$out/efi.img
truncate -s "$efi_part" "$efi"
chmod 0600 "$efi"
mkfs.vfat -F 32 -S 4096 -n MICROOS "$efi" > /dev/null
mmd -i "$efi" ::/microos ::/logs
mcopy -i "$efi" "$keys" ::/microos/authorized_keys
: > "$w/boot-attempts"
mcopy -i "$efi" "$w/boot-attempts" ::/microos/boot-attempts
[[ -z $wifi ]] || mcopy -i "$efi" "$wifi" "::/microos/${wifi##*/}"
if (( bootimg )); then
  mcopy -i "$efi" "$out/boot.img" ::/boot.img
  printf '%s\n' "${ids[0]#* }" > "$w/id"
  mcopy -i "$efi" "$w/id" ::/.microos-bootimg.id
fi

img2simg "$efi" "$out/efi.simg"
chmod 0600 "$out/efi.simg"

cp "$w/fw.sums" "$out/fw.SHA256SUMS"
printf 'IMAGE=%q\nCHANNEL=%q\nCOMMIT=%q\nDEPLOYMENT=%q\nPANEL=%q\nBOOTIMG=%q\nWIFI=%q\nWLAN_BOARD=%q\nDEV_SUDO=%q\nTPLG=%q\nOPTIONS=%q\n' \
  "$image" "$channel" "$commit" "${dep##*/}" "$panel" "$bootimg" "${wifi##*/}" "$wlanbd" "$devsudo" "$( [[ -n $tplg ]] && echo 1 )" "$options" > "$out/build.env"
(cd "$out" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum) > "$w/sums"
mv "$w/sums" "$out/SHA256SUMS"
cat "$out/SHA256SUMS" >&2
log "done: $out"
