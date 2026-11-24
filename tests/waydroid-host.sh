#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

guard=$tree/usr/libexec/microos/microos-android-guard
cfg=$tmp/config
devs=$tmp/devices
base=$'lxc.rootfs.path = /var/lib/waydroid/rootfs\nlxc.cgroup2.devices.allow = a\nlxc.cgroup2.devices.deny = b *:* rwm\nlxc.cgroup2.devices.deny = c 1:1 rwm\nlxc.cgroup2.devices.deny = c 1:4 rwm\nlxc.include = /var/lib/waydroid/lxc/waydroid/config_nodes'
printf 'Character devices:\n  1 mem\n 10 misc\n247 bsg\n\nBlock devices:\n  8 sd\n250 bsg\n' > "$devs"
gd() { MICROOS_LXC_CONFIG=$cfg MICROOS_PROC_DEVICES=$devs "$guard"; }

printf '%s\n' "$base" > "$cfg"
out=$(gd) || fail "guard exited $? on a guarded config"
[[ $out == 'microos-android-guard: bsg 247' ]] || fail "guard printed: $out"
[[ $(< "$cfg") == "$base"$'\nlxc.cgroup2.devices.deny = c 247:* rwm' ]] || fail "guard did not deny the char bsg major: $(< "$cfg")"
sed -i 's/^247 bsg/239 bsg/' "$devs"
gd > /dev/null || fail "guard exited $? on its second run"
[[ $(< "$cfg") == "$base"$'\nlxc.cgroup2.devices.deny = c 239:* rwm' ]] || fail "guard kept the old bsg major: $(< "$cfg")"
printf 'Character devices:\n  1 mem\n\nBlock devices:\n  8 sd\n' > "$devs"
out=$(gd) || fail "guard exited $? with no bsg major"
[[ $out == 'microos-android-guard: bsg absent' && $(< "$cfg") == "$base" ]] || fail "guard with no bsg: $out: $(< "$cfg")"
grep -v 'devices.deny = b' <<< "$base" > "$cfg"
rc2=0
gd > /dev/null 2> "$tmp/err" || rc2=$?
[[ $rc2 == 1 ]] && grep -q 'has no block guard' "$tmp/err" || fail "guard on a config without the block guard: rc $rc2"
rm -f "$cfg"
rc2=0
gd > /dev/null 2> "$tmp/err" || rc2=$?
[[ $rc2 == 1 ]] && grep -q 'waydroid init comes first' "$tmp/err" || fail "guard with no config: rc $rc2"

images=$tree/usr/libexec/microos/microos-android-images
w=$tmp/img
bin=$w/bin
calls=$w/calls
mkdir -p "$bin"
cat > "$bin/systemctl" <<EOF
#!/bin/sh
[ "\$*" = "show -P ActiveState waydroid-container.service" ] || exit 9
cat "$w/unit"
EOF
cat > "$bin/waydroid" <<EOF
#!/bin/sh
echo "waydroid \$*" >> "$calls"
if [ "\$*" = "init -f" ]; then
  printf '[waydroid]\nimages_path = /usr/share/waydroid-extra/images\n\n[properties]\npersist.waydroid.multi_windows = true\n' > "$w/waydroid.cfg"
fi
EOF
cat > "$bin/debugfs" <<EOF
#!/bin/sh
[ "\$1 \$2" = "-R cat /system/build.prop" ] || exit 9
echo "debugfs \$3" >> "$calls"
cat "$w/build.prop"
EOF
cat > "$w/fetch" <<EOF
#!/bin/sh
echo "fetch \$1 \$2 \$3 \$4" >> "$calls"
cp "$w/src/\${4##*/}" "\$4"
EOF
chmod 755 "$bin"/* "$w/fetch"
. "$tree/usr/share/microos-android/images.env"
sysz=${SYSTEM_URL%/download}; sysz=${sysz##*/}
venz=${VENDOR_URL%/download}; venz=${venz##*/}
mkdir -p "$w/src"
python3 - "$w/src/$sysz" "$w/src/$venz" <<'PY2'
import sys, zipfile
for path, name in ((sys.argv[1], "system.img"), (sys.argv[2], "vendor.img")):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(name, name)
PY2
reset() {
  [[ ! -d $w/images ]] || chmod -R u+w "$w/images"
  rm -rf "$w/images" "$w/cache" "$w/state" "$w/waydroid.cfg" "$calls"
  mkdir -p "$w/images/los20a-20260927-20261022" "$w/cache"
  : > "$w/lock"
  echo inactive > "$w/unit"
  printf 'ro.product.cpu.abilist=arm64-v8a\nro.system.product.cpu.abilist32=\n' > "$w/build.prop"
  printf 'width=2560\ndensity=400\nubwc=0\n' > "$w/display"
}
im() {
  PATH=$bin:$PATH MICROOS_ANDROID_PINS=$tree/usr/share/microos-android/images.env MICROOS_DISPLAY_FILE=$w/display MICROOS_ANDROID_IMAGES=$w/images MICROOS_ANDROID_CACHE=$w/cache \
    MICROOS_ANDROID_STATE=$w/state MICROOS_ANDROID_LOCK=$w/lock MICROOS_WAYDROID_CFG=$w/waydroid.cfg \
    MICROOS_FETCH=$w/fetch MICROOS_SPACE_FLOOR=0 "$images" > "$w/out" 2> "$w/err"
}
props() { python3 -c 'import configparser, sys; c = configparser.ConfigParser(interpolation=None); c.optionxform = str; c.read(sys.argv[1]); print(" ".join(k + "=" + v for k, v in c["properties"].items()))' "$w/waydroid.cfg"; }
base='persist.waydroid.multi_windows=true ro.sf.lcd_density=400 ro.adb.secure=1 ro.debuggable=1 persist.waydroid.suspend=false'

reset
im || fail "images exited $? on a new set: $(< "$w/err")"
[[ $(< "$calls") == "fetch $SYSTEM_URL $SYSTEM_SIZE $SYSTEM_SHA256 $w/cache/$sysz"$'\n'"fetch $VENDOR_URL $VENDOR_SIZE $VENDOR_SHA256 $w/cache/$venz"$'\n'"debugfs $w/images/$SET.tmp/system.img"$'\nwaydroid init -f\nwaydroid upgrade -o' ]] \
  || fail "new set calls: $(< "$calls")"
[[ $(readlink "$w/images/current") == "$SET" && $(ls "$w/images") == $'current\n'"$SET" ]] || fail "new set images dir: $(ls "$w/images")"
[[ $(cat "$w/images/$SET/system.img" "$w/images/$SET/vendor.img") == system.imgvendor.img ]] || fail "new set images not unpacked"
[[ -z $(find "$w/images/$SET" -perm /222) ]] || fail "the set is writable"
[[ -z $(ls -A "$w/cache") ]] || fail "zips left in the cache: $(ls "$w/cache")"
[[ $(< "$w/state") == $'state=ready\nset='"$SET" ]] || fail "state after a new set: $(< "$w/state")"
[[ $(props) == "$base debug.mesa.fd.mesa.debug=noubwc debug.mesa.tu.debug=noubwc" ]] || fail "props after a new set: $(props)"

: > "$calls"
printf 'width=2560\ndensity=320\nubwc=1\n' > "$w/display"
im || fail "images exited $? on a ready set: $(< "$w/err")"
[[ $(< "$calls") == 'waydroid upgrade -o' ]] || fail "ready set calls: $(< "$calls")"
[[ $(props) == "${base/400/320}" ]] || fail "props with UBWC on and density 320: $(props)"

reset
printf 'ro.system.product.cpu.abilist32=armeabi-v7a,armeabi\n' > "$w/build.prop"
rc2=0
im || rc2=$?
[[ $rc2 == 1 ]] && grep -q 'it needs AArch32' "$w/err" || fail "a 64_32 set: rc $rc2: $(< "$w/err")"
[[ ! -e $w/images/current && $(< "$w/state") == $'state=failed\nset='"$SET" ]] || fail "a 64_32 set flipped current or left state $(< "$w/state")"
! grep -q 'waydroid init' "$calls" || fail "a 64_32 set ran waydroid init"

reset
echo active > "$w/unit"
rc2=0
im || rc2=$?
[[ $rc2 == 1 && ! -e $w/state && ! -e $calls ]] && grep -q 'waydroid-container.service is active' "$w/err" || fail "a running container: rc $rc2: $(< "$w/err")"

reset
exec 8< "$w/lock"
flock -s 8
rc2=0
im || rc2=$?
exec 8<&-
[[ $rc2 == 1 && ! -e $w/state && ! -e $calls ]] && grep -q 'the Android session holds' "$w/err" || fail "a held lock: rc $rc2: $(< "$w/err")"

reset
printf 'density=400\n' > "$w/display"
rc2=0
im || rc2=$?
[[ $rc2 == 1 ]] && grep -q 'ubwc= in' "$w/err" || fail "a display file without ubwc: rc $rc2: $(< "$w/err")"

exit "$rc"
