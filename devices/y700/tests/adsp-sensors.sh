#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
script=$tree/usr/libexec/microos/microos-adsp-sensors
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

[[ -x $script ]] || fail "microos-adsp-sensors is not executable"
(( $(id -u) == 0 )) || { echo "FAIL: needs root in the container for the ownership cases" >&2; exit 1; }

root=$tmp/root
fix=$tmp/fix
state=$root/run/microos/adsp
u=microos-hexagonrpcd-adsp.service
export STUB_LOG=$tmp/log ADSP_FIX=$fix ADSP_UDEV=$root/udev SYSTEMCTL_STATE=$tmp/unit

mkdir -p "$root/dev/disk/by-partlabel" "$root/sys/class/block" "$root/udev" "$root/proc"
part() {
  local disk=$1 name=$2 bus=$3 id=$4
  mkdir -p "$root/sys/devices/platform/$bus/block/$disk/$name"
  : > "$root/sys/devices/platform/$bus/block/$disk/$name/partition"
  ln -sfn "../../devices/platform/$bus/block/$disk/$name" "$root/sys/class/block/$name"
  : > "$root/dev/$name"
  printf '%s\n' "$id" > "$root/udev/$disk"
}
part sda sda2 soc@0/1d84000.ufshc/host0/target0:0:0/0:0:0:0 platform-1d84000.ufshc-scsi-0:0:0:0
for p in sde9 sde32; do
  part sde "$p" soc@0/1d84000.ufshc/host0/target0:0:0/0:0:0:4 platform-1d84000.ufshc-scsi-0:0:0:4
done
part mmcblk0 mmcblk0p1 soc@0/8804000.mmc/mmc_host/mmc0/mmc0:aaaa platform-8804000.mmc
ln -sfn ../../devices/platform/soc@0/1d84000.ufshc/host0/target0:0:0/0:0:0:4/block/sde "$root/sys/class/block/sde"
: > "$root/dev/sde"
link() { ln -sfn "../../$2" "$root/dev/disk/by-partlabel/$1"; }
links() { link persist sda2; link dsp_a sde9; link dsp_b sde32; }
links

for s in sde9 sde32; do
  mkdir -p "$fix/$s/adsp/sub" "$fix/$s/adsp/empty" "$fix/$s/sdsp" "$fix/$s/cdsp"
  mkfifo "$fix/$s/adsp/sub/fifo"
  echo "core $s" > "$fix/$s/adsp/libcore.so"
  echo deep > "$fix/$s/adsp/sub/deep.bin"
  ln -s libcore.so "$fix/$s/adsp/alias.so"
  ln -s /etc/shadow "$fix/$s/adsp/sub/escape"
  echo sdsp > "$fix/$s/sdsp/s.so"
  echo cdsp > "$fix/$s/cdsp/c.so"
  chmod 0755 "$fix/$s/adsp/libcore.so"
done
sr=$fix/sda2/sensors/registry
reg=$sr/registry
mkdir -p "$reg" "$fix/sda2/sensors/config"
echo lsm > "$reg/lsm6dso_0_platform.config"
echo mmc > "$reg/mmc56x3_0_platform.config"
echo v1 > "$sr/sns_reg_version"
echo lsm6dso_0_platform.config > "$sr/parsed_file_list.csv"
echo json > "$fix/sda2/sensors/config/x.json"
chown -R 1000:1000 "$fix/sda2/sensors"
chmod 0700 "$sr" "$reg"
chmod 0600 "$reg"/* "$sr/sns_reg_version" "$sr/parsed_file_list.csv"

dbg=$root/sys/kernel/debug/qcom_socinfo
mkdir -p "$root/sys/devices/soc0" "$dbg"
printf 'Snapdragon\n' > "$root/sys/devices/soc0/family"
printf 'Lenovo Legion Y700 (2025) / TB321FU\n' > "$root/sys/devices/soc0/machine"
printf '2.0\n' > "$root/sys/devices/soc0/revision"
printf '577\n' > "$root/sys/devices/soc0/soc_id"
printf '1234567890\n' > "$root/sys/devices/soc0/serial_number"
printf '3\n' > "$dbg/hardware_platform_subtype"
printf '131072\n' > "$dbg/platform_version"

cat > "$tmp/sns_reg.conf" << 'EOF'
version=1
file=hw_platform=/sys/devices/soc0/hw_platform
file=platform_subtype=/sys/devices/soc0/platform_subtype
file=platform_subtype_id=/sys/devices/soc0/platform_subtype_id
file=platform_version=/sys/devices/soc0/platform_version
file=soc_id=/sys/devices/soc0/soc_id
file=revision=/sys/devices/soc0/revision
file=output=/mnt/vendor/persist/sensors/registry/registry
property=persist.vendor.sensors.enable.property=/mnt/vendor/persist/sensors/registry/file1
property=persist.vendor.sensors.enable.property1=/mnt/vendor/persist/sensors/registry/file2
EOF

run() {
  local s=${1:-$script}
  : > "$STUB_LOG"
  r=0
  (umask 000; env MICROOS_ADSP_ROOT="$root" PATH="$here/adsp-sensors:$PATH" bash "$s") > "$tmp/out" 2>&1 || r=$?
}
cur() { readlink "$state/current" 2> /dev/null || true; }
ht() { echo "$state/current/hexagonfs"; }
names() { find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd' '; }
dirs() { names "$state"; }
held() { [[ $(dirs) == "$(printf '%s\n' "$@" | sort | paste -sd' ')" ]]; }
work() { find "$root/run/microos" -mindepth 1 -maxdepth 1 ! -name adsp -printf '%f\n' | paste -sd' '; }
calls() { grep '^systemctl' "$STUB_LOG" | paste -sd'|'; }
logged() { grep -qxF "microos-adsp-sensors: $1" "$tmp/out"; }
noslot() { rm -f "$root/proc/cmdline" "$root/proc/bootconfig"; }
umounts() { [[ $(grep -c '^umount ' "$STUB_LOG") == "$1" ]] || fail "$2: $(grep -c '^umount ' "$STUB_LOG") umounts, want $1"; }

run
(( r == 0 )) || fail "first run: exit $r: $(cat "$tmp/out")"
h1=$(cur)
[[ $h1 =~ ^[0-9a-f]{64}$ ]] || fail "first run: current is '$h1'"
held "$h1" current || fail "first run: state holds $(dirs)"
logged "using slot _a" || fail "first run: slot log: $(cat "$tmp/out")"
logged "tree $h1 installed" || fail "first run: install not logged"
[[ $(names "$state/current/") == hexagonfs ]] || fail "current holds $(names "$state/current/")"
[[ $(names "$(ht)") == "dsp sensors socinfo" ]] || fail "hexagonfs holds $(names "$(ht)")"
[[ $(names "$(ht)/dsp") == adsp ]] || fail "dsp holds $(names "$(ht)/dsp")"
[[ $(names "$(ht)/sensors") == "persist sns_reg.conf" ]] || fail "sensors holds $(names "$(ht)/sensors")"
[[ $(names "$(ht)/sensors/persist") == "parsed_file_list.csv registry sns_reg_version" ]] ||
  fail "persist holds $(names "$(ht)/sensors/persist")"
[[ $(< "$(ht)/sensors/persist/sns_reg_version") == v1 &&
  $(< "$(ht)/sensors/persist/parsed_file_list.csv") == lsm6dso_0_platform.config ]] ||
  fail "registry version and list not copied"
[[ $(< "$(ht)/dsp/adsp/libcore.so") == "core sde9" && -f $(ht)/dsp/adsp/sub/deep.bin && -d $(ht)/dsp/adsp/empty ]] ||
  fail "adsp not copied from dsp_a"
[[ $(< "$(ht)/sensors/persist/registry/lsm6dso_0_platform.config") == lsm ]] || fail "registry not copied"
[[ $(< "$(ht)/sensors/sns_reg.conf") == "$(< "$tmp/sns_reg.conf")" ]] || fail "sns_reg.conf: $(cat "$(ht)/sensors/sns_reg.conf")"
for kv in hw_platform=QRD platform_subtype=QRD platform_subtype_id=3 platform_version=131072 soc_id=577 revision=2.0 \
  family=Snapdragon 'machine=Lenovo Legion Y700 (2025) / TB321FU' serial_number=1234567890; do
  [[ $(< "$(ht)/socinfo/${kv%%=*}") == "${kv#*=}" ]] || fail "socinfo ${kv%%=*} is $(cat "$(ht)/socinfo/${kv%%=*}")"
done
links_in=$(find "$state" -type l -printf '%P\n')
[[ $links_in == current ]] || fail "symlinks in the tree: $links_in"
for f in alias.so sub/escape sub/fifo; do
  [[ ! -e $(ht)/dsp/adsp/$f && ! -L $(ht)/dsp/adsp/$f ]] || fail "adsp/$f copied"
done
bad=$(find "$state/$h1" \( -type d ! -perm 0755 \) -o \( -type f ! -perm 0644 \) -o ! -user 0 -o ! -group 0 -o \
  \( ! -type d ! -type f \))
[[ -z $bad ]] || fail "modes or owners: $bad"
for d in sda2 sde9; do
  grep -qx "blockdev --setro $root/dev/$d" "$STUB_LOG" || fail "no setro on $d"
  grep -qx "mount -t ext4 -o ro,nosuid,nodev,noexec,noload $root/dev/$d .*" "$STUB_LOG" || fail "$d mount options"
done
[[ $(grep -c '^mount ' "$STUB_LOG") == 2 ]] || fail "mounts: $(grep '^mount ' "$STUB_LOG")"
umounts 2 "first run"
[[ -z $(work) ]] || fail "work dir left: $(work)"
[[ $(calls) == "systemctl -q is-active $u" ]] || fail "first run: systemctl calls: $(calls)"

echo active > "$SYSTEMCTL_STATE"
ino=$(stat -c %i "$state/$h1")
mkdir -p "$state/.deadbeef.tmp/x" "$state/0123abcd/hexagonfs"
ln -s nowhere "$state/.current.tmp"
run
(( r == 0 )) || fail "unchanged: exit $r: $(cat "$tmp/out")"
[[ $(cur) == "$h1" && $(stat -c %i "$state/$h1") == "$ino" ]] || fail "unchanged: tree rebuilt"
logged "tree $h1 in place" || fail "unchanged: $(cat "$tmp/out")"
[[ -z $(calls) ]] || fail "unchanged: hexagonrpcd touched: $(calls)"
held "$h1" current || fail "unchanged: stale trees left: $(dirs)"
umounts 2 "unchanged"

sed 's/^layout=2$/layout=3/' "$script" > "$tmp/layout2"
grep -qx 'layout=3' "$tmp/layout2" || fail "layout constant not found"
echo active > "$SYSTEMCTL_STATE"
run "$tmp/layout2"
(( r == 0 )) || fail "layout: exit $r: $(cat "$tmp/out")"
h2=$(cur)
[[ $h2 =~ ^[0-9a-f]{64}$ && $h2 != "$h1" ]] || fail "layout change kept hash $h2"
held "$h2" current || fail "layout: old dir kept: $(dirs)"
[[ $(calls) == "systemctl -q is-active $u|systemctl stop $u|systemctl --no-block start $u" ]] ||
  fail "layout: systemctl calls: $(calls)"
logged "tree $h2 installed" || fail "layout: $(cat "$tmp/out")"

echo mmc2 > "$reg/mmc56x3_0_platform.config"
echo inactive > "$SYSTEMCTL_STATE"
run
(( r == 0 )) || fail "input change: exit $r"
h3=$(cur)
[[ $h3 != "$h1" && $h3 != "$h2" ]] || fail "input change: hash $h3 kept"
held "$h3" current || fail "input change: state holds $(dirs)"
[[ $(< "$(ht)/sensors/persist/registry/mmc56x3_0_platform.config") == mmc2 ]] || fail "input change: new registry not in current"
[[ $(calls) == "systemctl -q is-active $u" ]] || fail "input change: inactive hexagonrpcd: $(calls)"

mv "$dbg" "$tmp/dbg"
run
(( r == 0 )) || fail "no debugfs: exit $r: $(cat "$tmp/out")"
[[ $(cur) != "$h3" ]] || fail "no debugfs: hash kept"
[[ $(< "$(ht)/socinfo/platform_subtype_id") == 0 && $(< "$(ht)/socinfo/platform_version") == 65536 ]] ||
  fail "no debugfs: socinfo $(cat "$(ht)/socinfo/platform_subtype_id") $(cat "$(ht)/socinfo/platform_version")"
mv "$tmp/dbg" "$dbg"
run
[[ $(cur) == "$h3" ]] || fail "debugfs back: hash $(cur), want $h3"

slot() {
  local name=$1 want=$2 core=$3
  run
  (( r == 0 )) || fail "$name: exit $r: $(cat "$tmp/out")"
  logged "using slot $want" || fail "$name: $(cat "$tmp/out")"
  [[ $(< "$(ht)/dsp/adsp/libcore.so") == "core $core" ]] || fail "$name: adsp not from $core"
}
printf 'console=ttyMSM0 androidboot.slot_suffix=_b root=PARTLABEL=root\n' > "$root/proc/cmdline"
slot "cmdline _b" "_b (booted _b)" sde32
umounts 2 "cmdline _b"
grep -qx "mount -t ext4 -o ro,nosuid,nodev,noexec,noload $root/dev/sde32 .*" "$STUB_LOG" || fail "cmdline _b: dsp_b not mounted"
noslot
printf 'androidboot.slot_suffix = "_b"\nandroidboot.mode = "normal"\n' > "$root/proc/bootconfig"
slot "bootconfig _b" "_b (booted _b)" sde32
printf 'console=ttyMSM0\n' > "$root/proc/cmdline"
slot "cmdline without a slot, bootconfig _b" "_b (booted _b)" sde32
printf 'androidboot.slot_suffix=_a\n' > "$root/proc/cmdline"
slot "cmdline _a over bootconfig _b" "_a (booted _a)" sde9
noslot
printf 'androidboot.slot_suffix=_c\n' > "$root/proc/cmdline"
slot "cmdline _c" "_a" sde9
printf 'androidboot.slot_suffix=_b\n' > "$root/proc/cmdline"
rm "$root/dev/disk/by-partlabel/dsp_b"
slot "booted _b without dsp_b" "_a (booted _b)" sde9
links
noslot
rm "$root/dev/disk/by-partlabel/dsp_a"
slot "dsp_a missing" "_b" sde32
link dsp_a mmcblk0p1
slot "dsp_a on microSD" "_b" sde32
! grep -q "$root/dev/mmcblk0p1" "$STUB_LOG" || fail "dsp_a on microSD: microSD touched"
links
run
[[ $(cur) == "$h3" ]] || fail "back on _a: hash $(cur), want $h3"

mv "$sr/sns_reg_version" "$tmp/sns_reg_version"
ln -s parsed_file_list.csv "$sr/sns_reg_version"
run
(( r == 0 )) || fail "symlinked sns_reg_version: exit $r: $(cat "$tmp/out")"
[[ $(cur) != "$h3" ]] || fail "symlinked sns_reg_version: hash kept"
[[ $(names "$(ht)/sensors/persist") == "parsed_file_list.csv registry" ]] ||
  fail "symlinked sns_reg_version: persist holds $(names "$(ht)/sensors/persist")"
[[ $(< "$(ht)/sensors/persist/parsed_file_list.csv") == lsm6dso_0_platform.config ]] ||
  fail "symlinked sns_reg_version: list not copied"
[[ $(find "$state" -type l -printf '%P\n') == current ]] || fail "symlinked sns_reg_version: symlinks in the tree"
rm "$sr/sns_reg_version"
mv "$sr/parsed_file_list.csv" "$tmp/parsed_file_list.csv"
run
(( r == 0 )) || fail "no version or list: exit $r: $(cat "$tmp/out")"
h4=$(cur)
logged "tree $h4 installed" || fail "no version or list: $(cat "$tmp/out")"
held "$h4" current || fail "no version or list: state holds $(dirs)"
[[ $(names "$(ht)/sensors/persist") == registry ]] ||
  fail "no version or list: persist holds $(names "$(ht)/sensors/persist")"
[[ $(< "$(ht)/sensors/persist/registry/lsm6dso_0_platform.config") == lsm && $(< "$(ht)/dsp/adsp/libcore.so") == "core sde9" ]] ||
  fail "no version or list: tree incomplete"
[[ $(< "$(ht)/sensors/sns_reg.conf") == "$(< "$tmp/sns_reg.conf")" ]] || fail "no version or list: sns_reg.conf"
mv "$tmp/sns_reg_version" "$tmp/parsed_file_list.csv" "$sr/"
echo v2 > "$sr/sns_reg_version"
run
(( r == 0 )) || fail "version change: exit $r: $(cat "$tmp/out")"
h5=$(cur)
[[ $h5 != "$h3" && $h5 != "$h4" ]] || fail "version change: hash $h5 kept"
[[ $(< "$(ht)/sensors/persist/sns_reg_version") == v2 ]] || fail "version change: new version not in current"
echo v1 > "$sr/sns_reg_version"
run
[[ $(cur) == "$h3" ]] || fail "version back: hash $(cur), want $h3"

h=$(cur)
waits() {
  local name=$1 why=$2 tries=${3:-} start took
  start=$(date +%s)
  if [[ -n $tries ]]; then
    MICROOS_ADSP_TRIES=$tries run
  else
    run
  fi
  took=$(( $(date +%s) - start ))
  (( r == 0 )) || fail "$name: exit $r: $(cat "$tmp/out")"
  if [[ -n $tries ]]; then
    (( took <= 2 )) || fail "$name: waited $took s with $tries tries"
  else
    (( took >= 9 )) || fail "$name: no wait for the links"
  fi
  logged "$why, no sensor tree" || fail "$name: $(cat "$tmp/out")"
  ! grep -q 'provisioning failed' "$tmp/out" || fail "$name: logged as a failure"
  ! grep -q '^mount\|^blockdev' "$STUB_LOG" || fail "$name: a partition was touched"
  [[ $(cur) == "$h" && -z $(calls) ]] || fail "$name: acted"
  held "$h" current || fail "$name: state holds $(dirs)"
  [[ -z $(work) ]] || fail "$name: work dir left"
}
link persist mmcblk0p1
waits "microSD persist" "persist is on mmcblk0 (platform-8804000.mmc), not UFS"
links
rm "$root/dev/disk/by-partlabel/dsp_a"
link dsp_b sde
waits "dsp_b a whole disk" "dsp_b is sde, not a partition" 1
links

nosource() {
  (( r == 0 )) || fail "$1: exit $r: $(cat "$tmp/out")"
  logged "$2" || fail "$1: log: $(cat "$tmp/out")"
  ! grep -q 'provisioning failed' "$tmp/out" || fail "$1: logged as a failure"
  [[ $(cur) == "$h" && -z $(calls) ]] || fail "$1: acted"
  held "$h" current || fail "$1: state holds $(dirs)"
  [[ -z $(work) ]] || fail "$1: work dir left: $(work)"
  umounts 2 "$1"
}

mkdir -p "$root/run/microos/adsp-sensors.Xk3q9Z/dsp/adsp"
echo stale > "$root/run/microos/adsp-sensors.Xk3q9Z/dsp/adsp/libcore.so"
run
(( r == 0 )) || fail "stale work dir: exit $r: $(cat "$tmp/out")"
[[ -z $(work) ]] || fail "stale work dir: left: $(work)"
[[ $(cur) == "$h" ]] || fail "stale work dir: current is $(cur), want $h"

mv "$fix/sde9/adsp" "$tmp/adsp"
run
nosource "adsp missing" 'no adsp on dsp_a, no sensor tree'
mkdir -p "$tmp/outside/sub"
echo secret > "$tmp/outside/secret"
echo secret > "$tmp/outside/sub/deeper"
ln -s "$tmp/outside" "$fix/sde9/adsp"
run
nosource "symlinked adsp" 'no adsp on dsp_a, no sensor tree'
rm "$fix/sde9/adsp"
mv "$state" "$tmp/state"
mkdir "$state"
run
(( r == 0 )) || fail "adsp missing without a tree: exit $r: $(cat "$tmp/out")"
logged 'no adsp on dsp_a, no sensor tree' || fail "adsp missing without a tree: $(cat "$tmp/out")"
[[ -z $(dirs) ]] || fail "adsp missing without a tree: state holds $(dirs)"
rm -rf "${state:?}"
mv "$tmp/state" "$state"
mv "$tmp/adsp" "$fix/sde9/adsp"

mv "$reg" "$tmp/reg"
run
nosource "registry missing" 'no sensors registry on persist, no sensor tree'
ln -s "$tmp/outside" "$reg"
run
nosource "symlinked registry" 'no sensors registry on persist, no sensor tree'
rm "$reg"
mv "$tmp/reg" "$reg"
mv "$fix/sda2/sensors" "$tmp/sensors"
mkdir -p "$tmp/outside2/registry"
cp -a "$tmp/sensors/registry/registry" "$tmp/outside2/registry/"
ln -s "$tmp/outside2" "$fix/sda2/sensors"
run
nosource "symlinked sensors dir" 'no sensors registry on persist, no sensor tree'
rm "$fix/sda2/sensors"
mv "$tmp/sensors" "$fix/sda2/sensors"
! grep -rq secret "$state" 2> /dev/null || fail "outside files reached the tree"
[[ $(cur) == "$h" ]] || fail "symlinked sources: current is $(cur), want $h"

echo mmc3 > "$reg/mmc56x3_0_platform.config"
echo active > "$SYSTEMCTL_STATE"
CP_FAIL=1 run
(( r == 0 )) || fail "failed rebuild: exit $r: $(cat "$tmp/out")"
grep -q "provisioning failed ([0-9]*), $u serves the tree in place ($h)" "$tmp/out" || fail "failed rebuild: $(cat "$tmp/out")"
[[ $(cur) == "$h" ]] || fail "failed rebuild: current is $(cur)"
held "$h" current || fail "failed rebuild: state holds $(dirs)"
[[ $(calls) == "" ]] || fail "failed rebuild: systemctl calls: $(calls)"
umounts 2 "failed rebuild"
[[ -z $(work) ]] || fail "failed rebuild: work dir left: $(work)"

MOUNT_FAIL=sda2 run
(( r == 0 )) || fail "persist mount failure: exit $r"
logged "provisioning failed (32), $u serves the tree in place ($h)" || fail "persist mount failure: $(cat "$tmp/out")"
[[ $(cur) == "$h" ]] || fail "persist mount failure: current is $(cur)"
held "$h" current || fail "persist mount failure: state holds $(dirs)"
umounts 1 "persist mount failure"
[[ -z $(work) ]] || fail "persist mount failure: work dir left: $(work)"

mv "$state" "$tmp/state"
MOUNT_FAIL=sda2 run
(( r == 32 )) || fail "persist mount failure without a tree: exit $r"
logged 'provisioning failed (32) and no tree in place' || fail "no tree: $(cat "$tmp/out")"
[[ -z $(dirs) ]] || fail "no tree: state holds $(dirs)"
rm -rf "${state:?}"
mv "$tmp/state" "$state"

if command -v udevadm > /dev/null; then
  udevadm verify --no-summary --resolve-names=never "$tree/usr/lib/udev/rules.d/70-microos-adsp-sensors.rules" ||
    fail "adsp rules do not verify"
else
  fail "udevadm missing, adsp rules unchecked"
fi

if (( rc == 0 )); then
  echo "adsp-sensors: ok"
fi
exit "$rc"
