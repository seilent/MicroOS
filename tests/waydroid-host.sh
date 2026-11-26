#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

guard=$tree/usr/libexec/microos/microos-android-guard
images=$tree/usr/libexec/microos/microos-android-images
w=$tmp/img
pins=$w/images.env
mkdir -p "$w"
cp "$tree/usr/share/microos-android/images.env" "$pins"
. "$pins"
printf 'width=2560\ndensity=400\nubwc=0\n' > "$w/display"
printf 'lxc.cgroup2.devices.deny = b *:* rwm\n' > "$w/config_base"
st() { MICROOS_ANDROID_PINS=$pins MICROOS_DISPLAY_FILE=$w/display MICROOS_WAYDROID_BASE=$w/config_base "$images" --stamp; }
cfg=$tmp/config
devs=$tmp/devices
base=$'lxc.rootfs.path = /var/lib/waydroid/rootfs\nlxc.cgroup2.devices.allow = a\nlxc.cgroup2.devices.deny = b *:* rwm\nlxc.cgroup2.devices.deny = c 1:1 rwm\nlxc.cgroup2.devices.deny = c 1:4 rwm\nlxc.include = /var/lib/waydroid/lxc/waydroid/config_nodes'
printf 'Character devices:\n  1 mem\n 10 misc\n247 bsg\n\nBlock devices:\n  8 sd\n250 bsg\n' > "$devs"
gd() {
  MICROOS_LXC_CONFIG=$cfg MICROOS_PROC_DEVICES=$devs MICROOS_ANDROID_PINS=$pins MICROOS_DISPLAY_FILE=$w/display \
    MICROOS_WAYDROID_BASE=$w/config_base MICROOS_ANDROID_IMAGES=$w/images MICROOS_ANDROID_STATE=$w/state \
    MICROOS_ANDROID_INPUTS=$w/inputs MICROOS_ANDROID_IMAGES_BIN=$images "$guard"
}
mkdir -p "$w/images/$SET"
ln -s "$SET" "$w/images/current"
ready=$'state=ready\nset='"$SET"
printf '%s\n' "$ready" > "$w/state"
st > "$w/inputs"

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
old=$(st)
printf 'width=2560\ndensity=320\nubwc=0\n' > "$w/display"
rc2=0
gd > /dev/null 2> "$tmp/err" || rc2=$?
[[ $rc2 == 1 && $(< "$cfg") == "$base" ]] &&
  grep -qF "$w/inputs reads '$old', the booted OS needs '$(st)', microos-android-images.service applies it" "$tmp/err" ||
  fail "guard with a stale inputs file: rc $rc2: $(< "$tmp/err")"
printf 'width=2560\ndensity=400\nubwc=0\n' > "$w/display"
rm "$w/inputs"
rc2=0
gd > /dev/null 2> "$tmp/err" || rc2=$?
[[ $rc2 == 1 && $(< "$cfg") == "$base" ]] && grep -qF "$w/inputs reads '', the booted OS needs '$(st)'" "$tmp/err" ||
  fail "guard with no inputs file: rc $rc2: $(< "$tmp/err")"
st > "$w/inputs"
printf 'state=fetching\nset=%s\n' "$SET" > "$w/state"
rc2=0
gd > /dev/null 2> "$tmp/err" || rc2=$?
[[ $rc2 == 1 && $(< "$cfg") == "$base" ]] &&
  grep -qF "$w/state reads 'state=fetching set=$SET', the booted OS needs 'state=ready set=$SET', microos-android-images.service applies it" "$tmp/err" ||
  fail "guard with the images fetching: rc $rc2: $(< "$tmp/err")"
printf 'state=ready\nset=los20a-20260927-20261022\n' > "$w/state"
rc2=0
gd > /dev/null 2> "$tmp/err" || rc2=$?
[[ $rc2 == 1 ]] && grep -qF "$w/state reads 'state=ready set=los20a-20260927-20261022', the booted OS needs 'state=ready set=$SET'" "$tmp/err" ||
  fail "guard with a ready state of another set: rc $rc2: $(< "$tmp/err")"
rm "$w/state"
rc2=0
gd > /dev/null 2> "$tmp/err" || rc2=$?
[[ $rc2 == 1 ]] && grep -qF "$w/state reads '', the booted OS needs" "$tmp/err" || fail "guard with no images state: rc $rc2: $(< "$tmp/err")"
printf '%s\n' "$ready" > "$w/state"
ln -sfn los20a-20260927-20261022 "$w/images/current"
rc2=0
gd > /dev/null 2> "$tmp/err" || rc2=$?
[[ $rc2 == 1 && $(< "$cfg") == "$base" ]] &&
  grep -qF "$w/images/current is 'los20a-20260927-20261022', the booted OS needs $SET, microos-android-images.service applies it" "$tmp/err" ||
  fail "guard with current on another set: rc $rc2: $(< "$tmp/err")"
ln -sfn "$SET" "$w/images/current"
gd > /dev/null || fail "guard exited $? once the state, the inputs and current match again"
grep -v 'devices.deny = b' <<< "$base" > "$cfg"
rc2=0
gd > /dev/null 2> "$tmp/err" || rc2=$?
[[ $rc2 == 1 ]] && grep -q 'has no block guard' "$tmp/err" || fail "guard on a config without the block guard: rc $rc2"
rm -f "$cfg"
rc2=0
gd > /dev/null 2> "$tmp/err" || rc2=$?
[[ $rc2 == 1 ]] && grep -q 'waydroid init comes first' "$tmp/err" || fail "guard with no config: rc $rc2"

bin=$w/bin
calls=$w/calls
mkdir -p "$bin"
cat > "$bin/systemctl" <<EOF
#!/bin/sh
if [ "\$*" = "stop waydroid-container.service" ]; then
  echo "systemctl \$*" >> "$calls"
  echo inactive > "$w/unit"
  exit 0
fi
[ "\$*" = "show -P ActiveState waydroid-container.service" ] || exit 9
cat "$w/unit"
EOF
cat > "$bin/lxc-info" <<EOF
#!/bin/sh
[ "\$*" = "-P $w/lxcp -n waydroid -sH" ] || exit 9
cat "$w/container"
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
[ ! -e "$w/term" ] || kill -TERM \$PPID
cp "$w/src/\${4##*/}" "\$4"
EOF
chmod 755 "$bin"/* "$w/fetch"
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
  rm -rf "$w/images" "$w/cache" "$w/state" "$w/inputs" "$w/waydroid.cfg" "$w/lxcp" "$calls"
  mkdir -p "$w/images/los20a-20260927-20261022" "$w/cache"
  : > "$w/lock"
  echo inactive > "$w/unit"
  echo STOPPED > "$w/container"
  printf 'ro.product.cpu.abilist=arm64-v8a\nro.system.product.cpu.abilist32=\n' > "$w/build.prop"
  printf 'width=2560\ndensity=400\nubwc=0\n' > "$w/display"
}
im() {
  PATH=$bin:$PATH MICROOS_ANDROID_PINS=$pins MICROOS_DISPLAY_FILE=$w/display MICROOS_ANDROID_IMAGES=$w/images MICROOS_ANDROID_CACHE=$w/cache \
    MICROOS_ANDROID_STATE=$w/state MICROOS_ANDROID_INPUTS=$w/inputs MICROOS_ANDROID_LOCK=$w/lock MICROOS_WAYDROID_CFG=$w/waydroid.cfg \
    MICROOS_WAYDROID_BASE=$w/config_base MICROOS_WAYDROID_LXC=$w/lxcp \
    MICROOS_FETCH=$w/fetch MICROOS_SPACE_FLOOR=0 "$images" "$@" > "$w/out" 2> "$w/err"
}
props() { python3 -c 'import configparser, sys; c = configparser.ConfigParser(interpolation=None); c.optionxform = str; c.read(sys.argv[1]); print(" ".join(k + "=" + v for k, v in c["properties"].items()))' "$w/waydroid.cfg"; }
base='persist.waydroid.multi_windows=true ro.sf.lcd_density=400 ro.adb.secure=1 ro.debuggable=1 persist.waydroid.suspend=false persist.waydroid.fake_wifi=com.android.systemui'

reset
rm "$w/lock"
s1=$(st)
im --stamp || fail "images --stamp exited $? with no lock: $(< "$w/err")"
[[ $(< "$w/out") == "$s1" && $s1 =~ ^[0-9a-f]{64}$ && $(st) == "$s1" ]] || fail "--stamp printed $(< "$w/out"), then $(st), not one sha256"
[[ ! -e $w/state && ! -e $w/inputs && ! -e $calls && ! -e $w/lock ]] || fail "--stamp wrote the state or the inputs, ran a tool or made the lock"
printf 'width=2560\ndensity=320\nubwc=0\n' > "$w/display"
[[ $(st) != "$s1" ]] || fail "--stamp did not change with the display file"
printf 'width=2560\ndensity=400\nubwc=0\n' > "$w/display"
[[ $(st) == "$s1" ]] || fail "--stamp did not come back with the display file"
printf 'SET=other\n' >> "$pins"
[[ $(st) != "$s1" ]] || fail "--stamp did not change with the pins file"
cp "$tree/usr/share/microos-android/images.env" "$pins"
printf 'lxc.cgroup2.devices.allow = a\n' >> "$w/config_base"
[[ $(st) != "$s1" ]] || fail "--stamp did not change with Waydroid's config_base"
printf 'lxc.cgroup2.devices.deny = b *:* rwm\n' > "$w/config_base"
cp "$images" "$w/apply"
printf '\n' >> "$w/apply"
[[ $(MICROOS_ANDROID_PINS=$pins MICROOS_DISPLAY_FILE=$w/display MICROOS_WAYDROID_BASE=$w/config_base "$w/apply" --stamp) != "$s1" ]] ||
  fail "--stamp did not change with the script"

reset
im || fail "images exited $? on a new set: $(< "$w/err")"
[[ $(< "$calls") == "fetch $SYSTEM_URL $SYSTEM_SIZE $SYSTEM_SHA256 $w/cache/$sysz"$'\n'"fetch $VENDOR_URL $VENDOR_SIZE $VENDOR_SHA256 $w/cache/$venz"$'\n'"debugfs $w/images/$SET.tmp/system.img"$'\nwaydroid init -f\nwaydroid upgrade -o' ]] \
  || fail "new set calls: $(< "$calls")"
[[ $(readlink "$w/images/current") == "$SET" && $(ls "$w/images") == $'current\n'"$SET" ]] || fail "new set images dir: $(ls "$w/images")"
[[ $(cat "$w/images/$SET/system.img" "$w/images/$SET/vendor.img") == system.imgvendor.img ]] || fail "new set images not unpacked"
[[ -z $(find "$w/images/$SET" -perm /222) ]] || fail "the set is writable"
[[ -z $(ls -A "$w/cache") ]] || fail "zips left in the cache: $(ls "$w/cache")"
[[ $(< "$w/state") == $'state=ready\nset='"$SET" && $(< "$w/inputs") == "$s1" && ! -e $w/inputs.new ]] ||
  fail "state and inputs after a new set: $(< "$w/state"), $(< "$w/inputs")"
[[ $(props) == "$base debug.mesa.fd.mesa.debug=noubwc debug.mesa.tu.debug=noubwc" ]] || fail "props after a new set: $(props)"
printf 'lxc.cgroup2.devices.deny = b *:* rwm\n' > "$cfg"
gd > /dev/null 2> "$tmp/err" || fail "guard exited $? on the state a new set wrote: $(< "$tmp/err")"

rm "$w/inputs"
: > "$calls"
im || fail "images exited $? on a ready state with no inputs file: $(< "$w/err")"
[[ $(< "$calls") == 'waydroid upgrade -o' && $(< "$w/state") == $'state=ready\nset='"$SET" && $(< "$w/inputs") == "$s1" ]] ||
  fail "a ready state with no inputs file: calls $(< "$calls"), state $(< "$w/state")"

: > "$calls"
printf 'width=2560\ndensity=320\nubwc=1\n' > "$w/display"
sed -i 's/^persist.waydroid.fake_wifi = .*/persist.waydroid.fake_wifi = com.example.app/' "$w/waydroid.cfg"
grep -qxF 'persist.waydroid.fake_wifi = com.example.app' "$w/waydroid.cfg" || fail "no fake Wi-Fi line to replace in $w/waydroid.cfg"
im || fail "images exited $? on a ready set: $(< "$w/err")"
[[ $(< "$calls") == 'waydroid upgrade -o' ]] || fail "ready set calls: $(< "$calls")"
[[ $(props) == "${base/400/320}" ]] || fail "props with UBWC on, density 320 and another fake Wi-Fi list: $(props)"
[[ $(st) != "$s1" && $(< "$w/state") == $'state=ready\nset='"$SET" && $(< "$w/inputs") == "$(st)" ]] ||
  fail "state and inputs after a props only run: $(< "$w/state"), $(< "$w/inputs")"
printf 'width=2560\ndensity=400\nubwc=0\nlight_sensor=1\norientation=landscape:0,landscape-flipped:2,portrait:1,portrait-flipped:3\n' > "$w/display"
im || fail "images exited $? with a light sensor: $(< "$w/err")"
[[ $(props) == "$base debug.mesa.fd.mesa.debug=noubwc debug.mesa.tu.debug=noubwc ro.vendor.microos.light_sensor=1" ]] ||
  fail "props with a light sensor: $(props)"
printf 'width=2560\ndensity=400\nubwc=0\n' > "$w/display"
im || fail "images exited $? after the light sensor went: $(< "$w/err")"
[[ $(props) == "$base debug.mesa.fd.mesa.debug=noubwc debug.mesa.tu.debug=noubwc" ]] ||
  fail "props after the light sensor went: $(props)"

printf 'width=2560\ndensity=320\nubwc=0\n' > "$w/display"
before=$(< "$w/state")
had=$(< "$w/inputs")
: > "$calls"
exec 8< "$w/lock"
flock -s 8
rc2=0
im || rc2=$?
exec 8<&-
[[ $rc2 == 1 && $(< "$w/state") == "$before" && $(< "$w/inputs") == "$had" && ! -s $calls ]] &&
  grep -qF "the Android session holds $w/lock" "$w/err" || fail "a held lock on a ready set: rc $rc2: $(< "$w/err")"

reset
printf 'old\n' > "$w/inputs"
printf 'ro.system.product.cpu.abilist32=armeabi-v7a,armeabi\n' > "$w/build.prop"
rc2=0
im || rc2=$?
[[ $rc2 == 1 ]] && grep -q 'it needs AArch32' "$w/err" || fail "a 64_32 set: rc $rc2: $(< "$w/err")"
[[ ! -e $w/images/current && $(< "$w/state") == $'state=failed\nset='"$SET" && $(< "$w/inputs") == old ]] ||
  fail "a 64_32 set flipped current or left state $(< "$w/state"), inputs $(< "$w/inputs")"
! grep -q '^waydroid init' "$calls" || fail "a 64_32 set ran waydroid init"

reset
printf 'old\n' > "$w/inputs"
mv "$w/src/$sysz" "$w/src/$sysz.off"
rc2=0
im || rc2=$?
mv "$w/src/$sysz.off" "$w/src/$sysz"
[[ $rc2 == 1 && ! -e $w/images/current && $(< "$w/state") == $'state=failed\nset='"$SET" && $(< "$w/inputs") == old ]] ||
  fail "a failed fetch: rc $rc2, state $(< "$w/state"), inputs $(< "$w/inputs")"
! grep -q '^waydroid\|^debugfs' "$calls" || fail "a failed fetch ran: $(< "$calls")"

reset
mkdir -p "$w/lxcp/waydroid"
echo RUNNING > "$w/container"
rc2=0
im || rc2=$?
[[ $rc2 == 1 && ! -e $w/images/current && $(< "$w/state") == $'state=failed\nset='"$SET" && ! -e $w/inputs ]] &&
  grep -qF 'the Waydroid container is RUNNING, stop Android first' "$w/err" || fail "a running container: rc $rc2: $(< "$w/err")"
! grep -q '^waydroid\|^systemctl' "$calls" || fail "a running container ran: $(< "$calls")"

reset
mkdir -p "$w/lxcp/waydroid"
echo active > "$w/unit"
im || fail "images exited $? with the container stopped and its manager active: $(< "$w/err")"
[[ $(grep -v '^fetch \|^debugfs ' "$calls") == $'systemctl stop waydroid-container.service\nwaydroid init -f\nwaydroid upgrade -o' ]] ||
  fail "a stopped container with its manager active: $(< "$calls")"

reset
ln -s los20a-20260927-20261022 "$w/images/current"
printf 'old\n' > "$w/inputs"
exec 8< "$w/lock"
flock -s 8
rc2=0
im || rc2=$?
exec 8<&-
[[ $rc2 == 1 && $(< "$w/state") == $'state=failed\nset='"$SET" && $(< "$w/inputs") == old ]] &&
  grep -qF "the Android session holds $w/lock, $SET is fetched and applies on the next run" "$w/err" ||
  fail "a held lock after the fetch: rc $rc2: $(< "$w/err")"
[[ $(readlink "$w/images/current") == los20a-20260927-20261022 ]] && ! grep -q '^waydroid' "$calls" ||
  fail "a held lock after the fetch flipped current or ran waydroid: $(< "$calls")"
chmod -R u+w "$w/images"
im || fail "images exited $? once the lock was free: $(< "$w/err")"
[[ $(readlink "$w/images/current") == "$SET" && $(< "$w/state") == $'state=ready\nset='"$SET" && $(< "$w/inputs") == "$s1" ]] ||
  fail "the run after a held lock: current $(readlink "$w/images/current"), state $(< "$w/state"), inputs $(< "$w/inputs")"

reset
printf 'old\n' > "$w/inputs"
: > "$w/term"
rc2=0
{ im || rc2=$?; } 2> /dev/null
rm "$w/term"
[[ $rc2 == 143 && $(< "$w/state") == $'state=failed\nset='"$SET" && $(< "$w/inputs") == old ]] ||
  fail "a run stopped during the fetch: rc $rc2, state $(< "$w/state"), inputs $(< "$w/inputs")"

reset
printf 'density=400\n' > "$w/display"
rc2=0
im || rc2=$?
[[ $rc2 == 1 ]] && grep -q 'ubwc= in' "$w/err" || fail "a display file without ubwc: rc $rc2: $(< "$w/err")"

reset
printf 'density=400\nubwc=0\nlight_sensor=yes\n' > "$w/display"
rc2=0
im || rc2=$?
[[ $rc2 == 1 && ! -e $w/state ]] && grep -q 'light_sensor=yes in' "$w/err" ||
  fail "a display file with light_sensor=yes: rc $rc2: $(< "$w/err")"

overlay=$tree/usr/libexec/microos/microos-android-overlay
o=$tmp/ovl
hal=android.hardware.lights-service.microos
halbin=system/bin/hw/$hal
initrc=system/etc/init/$hal.rc
vintf=system/etc/vintf/manifest/$hal.xml
gapp=$o/wd/system/priv-app/Phonesky/Phonesky.apk
mkdir -p "$o/ship/${halbin%/*}" "$o/ship/${initrc%/*}" "$o/ship/${vintf%/*}" "$o/wd/vendor" "${gapp%/*}" "$o/var"
printf 'elf\n' > "$o/ship/$halbin"
printf 'service\n' > "$o/ship/$initrc"
printf 'manifest\n' > "$o/ship/$vintf"
printf 'apk\n' > "$gapp"
mf() {
  while (( $# )); do
    printf '%s %s %s\n' "$(sha256sum < "$o/ship/$2" | cut -d' ' -f1)" "$1" "$2"
    shift 2
  done > "$o/manifest"
}
ov() {
  MICROOS_ANDROID_OVERLAY_MANIFEST=$o/manifest MICROOS_ANDROID_OVERLAY_DIR=$o/ship MICROOS_WAYDROID_OVERLAY=$o/wd \
    MICROOS_ANDROID_OVERLAY_STATE=$o/var/overlay.manifest "$overlay" > "$o/out" 2> "$o/err"
}
snap() { (cd "$o/wd" && find . -exec stat -c '%n %F %i %y %04a %u %g' {} + | LC_ALL=C sort); }
gstat=$(stat -c '%i %y' "$gapp")
untouched() {
  [[ $(stat -c '%i %y' "$gapp") == "$gstat" && $(< "$gapp") == apk ]] || fail "$1 touched the MindTheGapps file"
}

mf 0755 "$halbin" 0644 "$initrc" 0644 "$vintf"
ov || fail "overlay exited $? on a first apply: $(< "$o/err")"
[[ $(< "$o/out") == 'microos-android-overlay: 3 files, 3 copied, 0 removed' ]] ||
  fail "first apply printed: $(< "$o/out")"
for p in "$halbin" "$initrc" "$vintf"; do
  cmp -s "$o/ship/$p" "$o/wd/$p" || fail "first apply did not copy $p"
  [[ $(stat -c '%u %g' "$o/wd/$p") == "$(id -u) $(id -g)" ]] ||
    fail "first apply left $p owned by $(stat -c '%u %g' "$o/wd/$p")"
done
[[ $(stat -c %04a "$o/wd/$halbin" "$o/wd/$initrc" "$o/wd/$vintf" | paste -sd' ') == '0755 0644 0644' ]] ||
  fail "first apply modes: $(stat -c %04a "$o/wd/$halbin" "$o/wd/$initrc" "$o/wd/$vintf" | paste -sd' ')"
dirs=$(cd "$o/wd/system" && stat -c %04a bin bin/hw etc etc/init etc/vintf etc/vintf/manifest | sort -u)
[[ $dirs == 0755 ]] || fail "first apply parent modes: $dirs"
cmp -s "$o/manifest" "$o/var/overlay.manifest" || fail "first apply did not record the manifest"
[[ -z $(find "$o/wd" -name '.microos.*') ]] || fail "first apply left temp files: $(find "$o/wd" -name '.microos.*')"
untouched "first apply"

before=$(snap)
st=$(stat -c '%i %y' "$o/var/overlay.manifest")
ov || fail "overlay exited $? on a rerun: $(< "$o/err")"
[[ $(< "$o/out") == 'microos-android-overlay: 3 files, 0 copied, 0 removed' ]] || fail "rerun printed: $(< "$o/out")"
[[ $(snap) == "$before" ]] ||
  fail "a rerun rewrote the overlay: $(diff <(echo "$before") <(snap) | grep '^[<>]' | tr '\n' ' ')"
[[ $(stat -c '%i %y' "$o/var/overlay.manifest") == "$st" ]] || fail "a rerun rewrote the state"

printf 'service v2\n' > "$o/ship/$initrc"
mf 0755 "$halbin" 0644 "$initrc" 0644 "$vintf"
chmod 0600 "$o/wd/$vintf"
bstat=$(stat -c '%i %y' "$o/wd/$halbin")
ov || fail "overlay exited $? on a changed file: $(< "$o/err")"
[[ $(< "$o/out") == 'microos-android-overlay: 3 files, 2 copied, 0 removed' ]] ||
  fail "changed file printed: $(< "$o/out")"
[[ $(< "$o/wd/$initrc") == 'service v2' ]] || fail "the changed $initrc was not replaced"
[[ $(stat -c %04a "$o/wd/$vintf") == 0644 ]] || fail "the 0600 $vintf was not set back to 0644"
[[ $(stat -c '%i %y' "$o/wd/$halbin") == "$bstat" ]] || fail "an unchanged $halbin was rewritten"
cmp -s "$o/manifest" "$o/var/overlay.manifest" || fail "the changed manifest was not recorded"
untouched "a changed file"

mf 0755 "$halbin" 0644 "$initrc"
ov || fail "overlay exited $? on a dropped file: $(< "$o/err")"
[[ $(< "$o/out") == 'microos-android-overlay: 2 files, 0 copied, 1 removed' ]] ||
  fail "dropped file printed: $(< "$o/out")"
[[ ! -e $o/wd/$vintf && -f $o/wd/$halbin && -f $o/wd/$initrc ]] || fail "the dropped $vintf is still in the overlay"
cmp -s "$o/manifest" "$o/var/overlay.manifest" || fail "the manifest without $vintf was not recorded"
untouched "a dropped file"

mf 0755 "$halbin" 0644 "$initrc" 0644 "$vintf"
printf 'tampered\n' > "$o/ship/$halbin"
before=$(snap)
st=$(stat -c '%i %y' "$o/var/overlay.manifest")
rc2=0
ov || rc2=$?
err="microos-android-overlay: $o/ship/$halbin does not match its sha256 in $o/manifest"
[[ $rc2 == 1 && $(< "$o/err") == "$err" ]] ||
  fail "a corrupt shipped file: rc $rc2: $(< "$o/err")"
[[ $(snap) == "$before" && $(stat -c '%i %y' "$o/var/overlay.manifest") == "$st" ]] ||
  fail "a corrupt shipped file changed the overlay or the state"
printf 'elf\n' > "$o/ship/$halbin"

perm=system/etc/permissions/microos.xml
mkdir -p "$o/ship/${perm%/*}"
printf 'perm\n' > "$o/ship/$perm"
printf 'blocker\n' > "$o/wd/system/etc/permissions"
mf 0755 "$halbin" 0644 "$initrc" 0644 "$vintf" 0644 "$perm"
rc2=0
ov || rc2=$?
[[ $rc2 == 1 && $(< "$o/err") == "microos-android-overlay: $o/wd/system/etc/permissions is not a directory" ]] ||
  fail "a blocked copy: rc $rc2: $(< "$o/err")"
[[ $(stat -c '%i %y' "$o/var/overlay.manifest") == "$st" ]] || fail "a failed apply wrote the state"
[[ -z $(find "$o/wd" -name '.microos.*') ]] || fail "a failed apply left temp files: $(find "$o/wd" -name '.microos.*')"
left=2
[[ ! -f $o/wd/$vintf ]] || left=1
rm "$o/wd/system/etc/permissions"
ov || fail "overlay exited $? after the blocker went: $(< "$o/err")"
[[ $(< "$o/out") == "microos-android-overlay: 4 files, $left copied, 0 removed" ]] ||
  fail "after the blocker printed: $(< "$o/out")"
cmp -s "$o/ship/$perm" "$o/wd/$perm" && cmp -s "$o/ship/$vintf" "$o/wd/$vintf" ||
  fail "the apply after the blocker went did not copy every file"
cmp -s "$o/manifest" "$o/var/overlay.manifest" || fail "the apply after the blocker went did not record the manifest"
untouched "a blocked copy"

before=$(snap)
cp "$o/var/overlay.manifest" "$o/state.ok"
printf '%064d 0644 system/../../escape\n' 0 > "$o/manifest"
rc2=0
ov || rc2=$?
[[ $rc2 == 1 && $(< "$o/err") == "microos-android-overlay: line 1 of $o/manifest leaves the overlay" ]] ||
  fail "a manifest path out of the overlay: rc $rc2: $(< "$o/err")"
[[ $(snap) == "$before" ]] && cmp -s "$o/state.ok" "$o/var/overlay.manifest" ||
  fail "a manifest path out of the overlay changed the overlay or the state"

mf 0755 "$halbin"
mv "$o/wd" "$o/wd.off"
rc2=0
ov || rc2=$?
[[ $rc2 == 1 && $(< "$o/err") == "microos-android-overlay: no $o/wd, waydroid init comes first" ]] ||
  fail "no overlay dir: rc $rc2: $(< "$o/err")"
[[ ! -e $o/wd ]] && cmp -s "$o/state.ok" "$o/var/overlay.manifest" ||
  fail "no overlay dir made the dir or wrote the state"

exit "$rc"
