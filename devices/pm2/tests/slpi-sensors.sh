#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
script=$tree/usr/libexec/microos/microos-slpi-sensors
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

[[ -x $script ]] || fail "microos-slpi-sensors is not executable"
(( $(id -u) == 0 )) || { echo "FAIL: needs root in the container for the ownership cases" >&2; exit 1; }

root=$tmp/root
fix=$tmp/fix
state=$root/var/lib/microos/slpi
export STUB_LOG=$tmp/log SLPI_FIX=$fix SLPI_UDEV=$root/udev SYSTEMCTL_STATE=$tmp/unit

mkdir -p "$root/dev/disk/by-partlabel" "$root/sys/class/block" "$root/udev" "$state" "$root/run/microos"
part() {
  local disk=$1 name=$2 bus=$3 id=$4
  mkdir -p "$root/sys/devices/platform/$bus/block/$disk/$name"
  : > "$root/sys/devices/platform/$bus/block/$disk/$name/partition"
  ln -sfn "../../devices/platform/$bus/block/$disk/$name" "$root/sys/class/block/$name"
  : > "$root/dev/$name"
  printf '%s\n' "$id" > "$root/udev/$disk"
}
part sda sda2 soc@0/1d84000.ufshc/host0/target0:0:0/0:0:0:0 platform-1d84000.ufshc-scsi-0:0:0:0
for p in sde4 sde9 sde27 sde32; do
  part sde "$p" soc@0/1d84000.ufshc/host0/target0:0:0/0:0:0:4 platform-1d84000.ufshc-scsi-0:0:0:4
done
part mmcblk0 mmcblk0p1 soc@0/8804000.mmc/mmc_host/mmc0/mmc0:aaaa platform-8804000.mmc
link() { ln -sfn "../../$2" "$root/dev/disk/by-partlabel/$1"; }
links() { link persist sda2; link modem_a sde4; link dsp_a sde9; link modem_b sde27; link dsp_b sde32; }
links

for s in sde4 sde27; do
  mkdir -p "$fix/$s/image" "$fix/$s/verinfo"
  echo "mdt $s" > "$fix/$s/image/slpi.mdt"
  for b in 00 01 20; do echo "b$b $s" > "$fix/$s/image/slpi.b$b"; done
  echo jsn > "$fix/$s/image/slpir.jsn"
  echo other > "$fix/$s/image/adsp.mdt"
done
for s in sde9 sde32; do
  mkdir -p "$fix/$s/sdsp/sub" "$fix/$s/adsp"
  mkfifo "$fix/$s/sdsp/sub/fifo"
  echo "core $s" > "$fix/$s/sdsp/libcore.so"
  echo deep > "$fix/$s/sdsp/sub/deep.bin"
  echo wigig > "$fix/$s/sdsp/wigig_sensing.so"
  echo ear > "$fix/$s/sdsp/sns_bring_to_ear.so"
  ln -s libcore.so "$fix/$s/sdsp/alias.so"
  ln -s /etc/shadow "$fix/$s/sdsp/sub/escape"
  echo adsp > "$fix/$s/adsp/a.so"
  chmod 0755 "$fix/$s/sdsp/libcore.so"
done
reg=$fix/sda2/sensors/registry/registry
mkdir -p "$reg" "$fix/sda2/sensors/config"
echo icm > "$reg/icm4x6xx_0_platform.config"
echo qmc > "$reg/qmc630x_0_platform.config"
echo json > "$fix/sda2/sensors/config/x.json"
chown -R 1000:1000 "$fix/sda2/sensors"
chmod 0700 "$fix/sda2/sensors/registry" "$reg"
chmod 0600 "$reg"/*

mkdir -p "$root/sys/devices/soc0" "$root/sys/kernel/debug/qcom_socinfo" "$root/sys/module/firmware_class/parameters" \
  "$root/sys/class/remoteproc/remoteproc0" "$root/sys/class/remoteproc/remoteproc1"
printf 'Snapdragon\n' > "$root/sys/devices/soc0/family"
printf 'SM8250\n' > "$root/sys/devices/soc0/machine"
printf '2.1\n' > "$root/sys/devices/soc0/revision"
printf '356\n' > "$root/sys/devices/soc0/soc_id"
printf '599856448\n' > "$root/sys/devices/soc0/serial_number"
printf '0\n' > "$root/sys/kernel/debug/qcom_socinfo/hardware_platform_subtype"
printf '65536\n' > "$root/sys/kernel/debug/qcom_socinfo/platform_version"
printf 'slpi\n' > "$root/sys/class/remoteproc/remoteproc0/name"
printf 'adsp\n' > "$root/sys/class/remoteproc/remoteproc1/name"
fwpath=$root/sys/module/firmware_class/parameters/path
boot() {
  printf '\n' > "$fwpath"
  printf 'offline\n' > "$root/sys/class/remoteproc/remoteproc0/state"
  printf 'running\n' > "$root/sys/class/remoteproc/remoteproc1/state"
}

run() {
  local s=${1:-$script}
  : > "$STUB_LOG"
  r=0
  (umask 000; env MICROOS_SLPI_ROOT="$root" PATH="$here/slpi-sensors:$PATH" bash "$s") > "$tmp/out" 2>&1 || r=$?
}
cur() { readlink "$state/current" 2> /dev/null || true; }
ht() { echo "$state/current/hexagonfs"; }
fwd() { echo "$state/current/firmware/qcom/sm8250/ayaneo/pocketmicro2"; }
started() { [[ $(< "$root/sys/class/remoteproc/remoteproc0/state") == start ]]; }
dirs() { find "$state" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd' '; }

boot
run
(( r == 0 )) || fail "first run: exit $r: $(cat "$tmp/out")"
h1=$(cur)
[[ $h1 =~ ^[0-9a-f]{64}$ ]] || fail "first run: current is '$h1'"
[[ $(dirs) == "$h1 current" ]] || fail "first run: state holds $(dirs)"
[[ $(ls "$(fwd)" | paste -sd' ') == "slpi.b00 slpi.b01 slpi.b20 slpi.mdt" ]] || fail "firmware dir: $(ls "$(fwd)" | paste -sd' ')"
[[ $(< "$(fwd)/slpi.mdt") == "mdt sde4" ]] || fail "firmware not from modem_a"
[[ $(< "$(ht)/dsp/sdsp/libcore.so") == "core sde9" && -f $(ht)/dsp/sdsp/sub/deep.bin ]] || fail "sdsp not copied from dsp_a"
[[ ! -e $(ht)/dsp/sdsp/wigig_sensing.so && ! -e $(ht)/dsp/sdsp/sns_bring_to_ear.so ]] || fail "an excluded .so was copied"
[[ ! -e $(ht)/dsp/adsp && ! -e $(ht)/sensors/config ]] || fail "adsp or sensors/config in the tree"
[[ $(< "$(ht)/sensors/registry/icm4x6xx_0_platform.config") == icm ]] || fail "registry not copied"
grep -qx 'file=output=/mnt/vendor/persist/sensors/registry/registry' "$(ht)/sensors/sns_reg.conf" || fail "sns_reg.conf"
for kv in hw_platform=QRD platform_subtype=QRD platform_subtype_id=0 platform_version=65536 soc_id=356 revision=2.1 \
  family=Snapdragon machine=SM8250; do
  [[ $(< "$(ht)/socinfo/${kv%%=*}") == "${kv#*=}" ]] || fail "socinfo ${kv%%=*} is $(cat "$(ht)/socinfo/${kv%%=*}")"
done
links_in=$(find "$state" -type l -printf '%P\n')
[[ $links_in == current ]] || fail "symlinks in the tree: $links_in"
for f in alias.so sub/escape sub/fifo; do
  [[ ! -e $(ht)/dsp/sdsp/$f && ! -L $(ht)/dsp/sdsp/$f ]] || fail "sdsp/$f copied"
done
bad=$(find "$state/$h1" \( -type d ! -perm 0755 \) -o \( -type f ! -perm 0644 \) -o ! -user 0 -o ! -group 0 -o \
  \( ! -type d ! -type f \))
[[ -z $bad ]] || fail "modes or owners: $bad"
[[ $(< "$fwpath") == "$state/current/firmware" ]] || fail "firmware path is '$(< "$fwpath")'"
started || fail "slpi remoteproc not started"
[[ $(< "$root/sys/class/remoteproc/remoteproc1/state") == running ]] || fail "adsp remoteproc touched"
for d in sda2 sde4 sde9; do grep -qx "blockdev --setro $root/dev/$d" "$STUB_LOG" || fail "no setro on $d"; done
grep -qx "mount -t vfat -o ro,nosuid,nodev,noexec $root/dev/sde4 .*" "$STUB_LOG" || fail "modem mount: $(grep mount "$STUB_LOG")"
for d in sde9 sda2; do
  grep -qx "mount -t ext4 -o ro,nosuid,nodev,noexec,noload $root/dev/$d .*" "$STUB_LOG" || fail "$d mount options"
done
[[ $(grep -c '^umount ' "$STUB_LOG") == 3 ]] || fail "umount count"
[[ -z $(ls -A "$root/run/microos") ]] || fail "work dir left: $(ls -A "$root/run/microos")"
! grep -q '^systemctl stop' "$STUB_LOG" || fail "first run stopped hexagonrpcd"
grep -q 'using slot _a' "$tmp/out" || fail "slot not logged"

boot
echo active > "$SYSTEMCTL_STATE"
ino=$(stat -c %i "$state/$h1")
mkdir -p "$state/.deadbeef.tmp/x"
ln -s nowhere "$state/.current.tmp"
run
(( r == 0 )) || fail "unchanged: exit $r: $(cat "$tmp/out")"
[[ $(cur) == "$h1" && $(stat -c %i "$state/$h1") == "$ino" ]] || fail "unchanged: tree rebuilt"
! grep -q '^systemctl \(stop\|--no-block start\)' "$STUB_LOG" || fail "unchanged: hexagonrpcd touched: $(cat "$STUB_LOG")"
[[ $(dirs) == "$h1 current" ]] || fail "unchanged: stale .tmp left: $(dirs)"
[[ $(< "$fwpath") == "$state/current/firmware" ]] || fail "unchanged: firmware path not written"
printf 'offline\n' > "$root/sys/class/remoteproc/remoteproc0/state"
run
(( r == 0 )) && ! grep -q 'left as is' "$tmp/out" || fail "own firmware path logged as foreign: $(cat "$tmp/out")"
started || fail "unchanged: remoteproc not started"

boot
sed 's/^layout=1$/layout=2/' "$script" > "$tmp/layout2"
grep -qx 'layout=2' "$tmp/layout2" || fail "layout constant not found"
echo active > "$SYSTEMCTL_STATE"
run "$tmp/layout2"
(( r == 0 )) || fail "layout: exit $r: $(cat "$tmp/out")"
h2=$(cur)
[[ $h2 =~ ^[0-9a-f]{64}$ && $h2 != "$h1" ]] || fail "layout change kept hash $h2"
[[ $(dirs) == "$h2 current" ]] || fail "layout: old dir kept: $(dirs)"
[[ $(grep '^systemctl' "$STUB_LOG" | paste -sd'|') == "systemctl -q is-active microos-hexagonrpcd.service|systemctl stop microos-hexagonrpcd.service|systemctl --no-block start microos-hexagonrpcd.service" ]] \
  || fail "layout: systemctl calls: $(grep '^systemctl' "$STUB_LOG" | paste -sd'|')"

boot
echo qmc2 > "$reg/qmc630x_0_platform.config"
echo inactive > "$SYSTEMCTL_STATE"
run
(( r == 0 )) || fail "input change: exit $r"
h3=$(cur)
[[ $h3 != "$h1" && $h3 != "$h2" && $(dirs) == "$h3 current" ]] || fail "input change: $(dirs)"
[[ $(< "$(ht)/sensors/registry/qmc630x_0_platform.config") == qmc2 ]] || fail "input change: new registry not in current"
! grep -q '^systemctl stop' "$STUB_LOG" || fail "input change: inactive hexagonrpcd stopped"

boot
rm "$root/dev/disk/by-partlabel/modem_a"
run
(( r == 0 )) && grep -q 'using slot _b' "$tmp/out" || fail "_a missing: $(cat "$tmp/out")"
[[ $(< "$(fwd)/slpi.mdt") == "mdt sde27" && $(< "$(ht)/dsp/sdsp/libcore.so") == "core sde32" ]] || fail "_a missing: not from _b"
started || fail "_b: remoteproc not started"
links

boot
link persist mmcblk0p1
start=$(date +%s)
run
(( r == 0 )) || fail "microSD persist: exit $r"
(( $(date +%s) - start >= 9 )) || fail "microSD persist: no wait for the links"
grep -q 'persist is on mmcblk0 (platform-8804000.mmc), not UFS' "$tmp/out" || fail "microSD persist: $(cat "$tmp/out")"
! grep -q '^mount\|^blockdev' "$STUB_LOG" || fail "microSD persist: a partition was touched"
! started || fail "microSD persist: remoteproc started"
links

boot
mv "$fix/sde4/image/slpi.mdt" "$tmp/mdt"
h=$(cur)
run
(( r == 0 )) || fail "no slpi.mdt: exit $r"
grep -q 'no slpi.mdt on modem_a, SLPI not started' "$tmp/out" || fail "no slpi.mdt: $(cat "$tmp/out")"
! started && [[ $(< "$fwpath") == "" && $(cur) == "$h" ]] || fail "no slpi.mdt: acted"
[[ -z $(ls -A "$root/run/microos") ]] || fail "no slpi.mdt: work dir left"
mv "$tmp/mdt" "$fix/sde4/image/slpi.mdt"

boot
printf '/usr/lib/firmware/updates\n' > "$fwpath"
run
(( r == 0 )) || fail "foreign path: exit $r"
[[ $(< "$fwpath") == /usr/lib/firmware/updates ]] || fail "foreign path replaced"
grep -q 'firmware path is /usr/lib/firmware/updates, left as is' "$tmp/out" || fail "foreign path not logged"
started || fail "foreign path: remoteproc not started"

umounts() { [[ $(grep -c '^umount ' "$STUB_LOG") == "$1" ]] || fail "$2: $(grep -c '^umount ' "$STUB_LOG") umounts, want $1"; }
nostart() {
  (( r == 0 )) || fail "$1: exit $r: $(cat "$tmp/out")"
  grep -q "$2" "$tmp/out" || fail "$1: log: $(cat "$tmp/out")"
  ! started && [[ $(< "$fwpath") == "" ]] || fail "$1: SLPI started or path written"
  [[ -z $(ls -A "$root/run/microos") ]] || fail "$1: work dir left"
  umounts 3 "$1"
}

boot
rm "$root/dev/disk/by-partlabel/dsp_a"
run
(( r == 0 )) && grep -q 'using slot _b' "$tmp/out" || fail "dsp_a missing: $(cat "$tmp/out")"
[[ $(< "$(ht)/dsp/sdsp/libcore.so") == "core sde32" ]] || fail "dsp_a missing: sdsp not from _b"
links

h=$(cur)
boot
mv "$fix/sde9/sdsp" "$tmp/sdsp"
run
nostart "sdsp missing" 'no sdsp on dsp_a, SLPI not started'
mkdir -p "$tmp/outside/sub"
echo secret > "$tmp/outside/secret"
echo secret > "$tmp/outside/sub/deeper"
ln -s "$tmp/outside" "$fix/sde9/sdsp"
boot
run
nostart "symlinked sdsp" 'no sdsp on dsp_a, SLPI not started'
rm "$fix/sde9/sdsp"
mv "$tmp/sdsp" "$fix/sde9/sdsp"

mv "$reg" "$tmp/reg"
boot
run
nostart "registry missing" 'no sensors registry on persist, SLPI not started'
ln -s "$tmp/outside" "$reg"
boot
run
nostart "symlinked registry" 'no sensors registry on persist, SLPI not started'
rm "$reg"
mv "$tmp/reg" "$reg"
mv "$fix/sda2/sensors" "$tmp/sensors"
mkdir -p "$tmp/outside2/registry"
cp -a "$tmp/sensors/registry/registry" "$tmp/outside2/registry/"
ln -s "$tmp/outside2" "$fix/sda2/sensors"
boot
run
nostart "symlinked sensors dir" 'no sensors registry on persist, SLPI not started'
rm "$fix/sda2/sensors"
mv "$tmp/sensors" "$fix/sda2/sensors"
[[ -z $(grep -rl secret "$state" 2> /dev/null) && $(cur) == "$h" ]] || fail "outside files reached the tree"

boot
echo qmc3 > "$reg/qmc630x_0_platform.config"
CP_FAIL=1 run
(( r == 0 )) || fail "failed rebuild: exit $r: $(cat "$tmp/out")"
grep -q "provisioning failed ([0-9]*), starting from the tree in place ($h)" "$tmp/out" || fail "failed rebuild: $(cat "$tmp/out")"
[[ $(cur) == "$h" && $(dirs) == "$h current" ]] || fail "failed rebuild: state holds $(dirs)"
[[ $(< "$fwpath") == "$state/current/firmware" ]] && started || fail "failed rebuild: SLPI not started"
umounts 3 "failed rebuild"
[[ -z $(ls -A "$root/run/microos") ]] || fail "failed rebuild: work dir left"

boot
MOUNT_FAIL=sda2 run
(( r == 0 )) || fail "persist mount failure: exit $r"
grep -q "provisioning failed (32), starting from the tree in place ($h)" "$tmp/out" || fail "persist mount failure: $(cat "$tmp/out")"
[[ $(< "$fwpath") == "$state/current/firmware" ]] && started || fail "persist mount failure: SLPI not started"
umounts 2 "persist mount failure"

mv "$state" "$tmp/state"
mkdir "$state"
boot
MOUNT_FAIL=sda2 run
(( r == 32 )) || fail "persist mount failure without a tree: exit $r"
grep -q 'provisioning failed (32) and no tree in place, SLPI not started' "$tmp/out" || fail "no tree: $(cat "$tmp/out")"
! started && [[ $(< "$fwpath") == "" ]] || fail "no tree: SLPI started"
rm -rf "$state"
mv "$tmp/state" "$state"

boot
printf 'cdsp\n' > "$root/sys/class/remoteproc/remoteproc0/name"
run
(( r == 1 )) && grep -q 'no slpi remoteproc' "$tmp/out" || fail "no slpi remoteproc: exit $r: $(cat "$tmp/out")"
printf 'slpi\n' > "$root/sys/class/remoteproc/remoteproc0/name"

if command -v udevadm > /dev/null; then
  udevadm verify --no-summary --resolve-names=never "$tree/usr/lib/udev/rules.d/70-microos-slpi.rules" || fail "slpi rules do not verify"
else
  fail "udevadm missing, slpi rules unchecked"
fi

if (( rc == 0 )); then
  echo "slpi-sensors: ok"
fi
exit "$rc"
