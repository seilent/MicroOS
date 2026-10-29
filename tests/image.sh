#!/usr/bin/env bash
set -euo pipefail

fail() { echo "image: $*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mods=(/usr/lib/modules/*)
[[ ${#mods[@]} -eq 1 && -d ${mods[0]} ]] || fail "expected one modules dir, found ${mods[*]}"
kver=${mods[0]##*/}
rpm -q microos-kernel >/dev/null || fail "microos-kernel not installed"
[[ -z $(rpm -qa 'kernel*') ]] || fail "Fedora kernel rpms left: $(rpm -qa 'kernel*' | tr '\n' ' ')"
[[ -z $(rpm -qa 'fedora-release*') ]] || fail "fedora-release rpms left"
rpm -q generic-release generic-logos >/dev/null || fail "generic-release or generic-logos missing"

for kv in ID=microos NAME=MicroOS ID_LIKE=fedora VERSION_ID=44 DEFAULT_HOSTNAME=microos; do
  grep -qx "$kv" /usr/lib/os-release || fail "os-release lacks $kv"
done
grep -qx "$(cat /usr/lib/microos/version)" /usr/lib/os-release || fail "version file and os-release differ"
[[ $(readlink /etc/os-release) == ../usr/lib/os-release ]] || fail "/etc/os-release is not the relative symlink"

for u in bootloader-update.service systemd-backlight@.service systemd-hibernate.service systemd-hybrid-sleep.service \
  systemd-suspend-then-hibernate.service bootc-fetch-apply-updates.timer; do
  [[ $(readlink "/etc/systemd/system/$u") == /dev/null ]] || fail "$u is not masked"
done
[[ $(readlink /etc/systemd/user/mpris-proxy.service) == /dev/null ]] || fail "user mpris-proxy.service is not masked"

for u in microos-boot-ok.service microos-update-applied.service microos-update.service microos-update-check.service \
  microos-update-check.timer; do
  [[ -f /usr/lib/systemd/system/$u ]] || fail "$u missing"
done
units=()
for u in /usr/lib/systemd/system/microos-*; do
  [[ -f $u ]] || continue
  units+=("$u")
  if grep -q '^\[Install\]' "$u"; then
    [[ $(systemctl is-enabled "${u##*/}") == enabled ]] || fail "${u##*/} is not enabled"
  fi
done
(( ${#units[@]} )) || fail "no MicroOS units"

rpm -q mesa-dri-drivers mesa-vulkan-drivers mesa-libgbm mesa-libEGL mesa-libGL vulkan-loader vulkan-tools pipewire \
  pipewire-alsa pipewire-pulseaudio pipewire-utils pulseaudio-utils wireplumber alsa-ucm alsa-ucm-utils alsa-utils >/dev/null || fail "base stack rpms missing"
[[ -f /usr/share/vulkan/icd.d/freedreno_icd.aarch64.json ]] || fail "Turnip ICD missing"
for p in libfreeaptx pipewire-codec-aptx; do
  [[ $(rpm -q --qf '%{VENDOR}' "$p") == MicroOS ]] || fail "$p is not the MicroOS build"
done
[[ -f /usr/lib64/spa-0.2/bluez5/libspa-codec-bluez5-aptx.so ]] || fail "aptX codec module missing"
! ldd /usr/lib64/spa-0.2/bluez5/libspa-codec-bluez5-aptx.so | grep -q 'not found' || fail "aptX codec module has unresolved libraries"
[[ $(rpm -q --qf '%{VENDOR}' microos-eq) == MicroOS ]] || fail "microos-eq is not the MicroOS build"
[[ -f /usr/lib64/ladspa/microos-eq.so ]] || fail "EQ plugin /usr/lib64/ladspa/microos-eq.so missing"
! ldd /usr/lib64/ladspa/microos-eq.so | grep -q 'not found' || fail "EQ plugin has unresolved libraries"
rpm -q bluez bluez-obexd >/dev/null || fail "bluez or bluez-obexd missing"
grep -qx 'SystemdService=dbus-org.bluez.obex.service' /usr/share/dbus-1/services/org.bluez.obex.service \
  || fail "obexd is not activated through dbus-org.bluez.obex.service"
[[ $(readlink /usr/lib/systemd/user/dbus-org.bluez.obex.service) == obex.service ]] || fail "dbus-org.bluez.obex.service is not obex.service"
obexd=$(systemctl --global cat obex.service | awk 'index($0, "ExecStart=") == 1 { v = substr($0, 11); if (v == "") n = 0; else l[++n] = v }
  END { for (i = 1; i <= n; i++) print l[i] }') || fail "systemctl --global cat obex.service"
[[ $obexd == "/usr/libexec/bluetooth/obexd -P opp,ftp,pcsuite,irmc,pbap,mas,filesystem" ]] || fail "effective obex.service ExecStart: $obexd"
pwevr=$(rpm -q --requires pipewire-codec-aptx | awk '$1 == "pipewire-libs(aarch-64)" && $2 == "=" { print $3 }')
[[ -n $pwevr ]] || fail "pipewire-codec-aptx has no exact pipewire-libs(aarch-64) Requires"
while read -r p evr; do
  [[ $p == pipewire-codec-aptx || $evr == "$pwevr" ]] || fail "$p is $evr, pipewire is pinned at $pwevr"
done < <(rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' 'pipewire*')
[[ $(rpm -q --qf '%{VERSION}-%{RELEASE}\n' wireplumber) == "$(rpm -q --qf '%{VERSION}-%{RELEASE}\n' wireplumber-libs)" ]] \
  || fail "wireplumber and wireplumber-libs differ"
grep -qx 'excludepkgs=pipewire\*,wireplumber\*' /etc/dnf/libdnf5.conf.d/20-microos-pipewire.conf \
  || fail "20-microos-pipewire.conf does not exclude pipewire and wireplumber"
! rpm -q openh264 >/dev/null 2>&1 || fail "Cisco's openh264 is installed in the image"
grep -qx 'excludepkgs=openh264' /etc/dnf/libdnf5.conf.d/20-microos-openh264.conf || fail "20-microos-openh264.conf does not exclude openh264"
[[ $(rpm -qf --qf '%{NAME}' /usr/lib64/libopenh264.so.8) == noopenh264 ]] || fail "libopenh264.so.8 is not the noopenh264 stub"
[[ $(rpm -q --qf '%{VENDOR}' inputplumber) == MicroOS ]] || fail "inputplumber is not the MicroOS build"
[[ -z $(rpm -qa '*-debuginfo' '*-debugsource') ]] || fail "debug rpms installed: $(rpm -qa '*-debuginfo' '*-debugsource' | tr '\n' ' ')"
[[ $(systemctl is-enabled inputplumber.service) == enabled ]] || fail "inputplumber.service is not enabled"
yama=/usr/lib/sysctl.d/60-microos-yama.conf
grep -qx 'kernel.yama.ptrace_scope = 1' "$yama" || fail "$yama does not set ptrace_scope 1"
last=$(/usr/lib/systemd/systemd-sysctl --cat-config | awk '/^# \/[^ ]*\.conf( -> |$)/ { f = $2 } /^-?kernel[.\/]yama[.\/]ptrace_scope[[:space:]]*=/ { l = f " " $0 } END { print l }')
[[ $last == "$yama kernel.yama.ptrace_scope = 1" ]] || fail "the last ptrace_scope setting is not $yama: $last"
mem=/usr/lib/sysctl.d/60-microos-memory.conf
for kv in 'vm.swappiness = 180' 'vm.page-cluster = 0' 'vm.watermark_boost_factor = 0' 'vm.watermark_scale_factor = 125'; do
  grep -qxF "$kv" "$mem" || fail "$mem does not set $kv"
  re=${kv%% =*}
  re=${re//./[./]}
  last=$(/usr/lib/systemd/systemd-sysctl --cat-config | awk -v re="^-?${re}[[:space:]]*=" '/^# \/[^ ]*\.conf( -> |$)/ { f = $2 } $0 ~ re { l = f " " $0 } END { print l }')
  [[ $last == "$mem $kv" ]] || fail "the last ${kv%% =*} setting is not $mem: $last"
done
zram=/usr/lib/systemd/zram-generator.conf
rpm -q zram-generator >/dev/null || fail "zram-generator is not installed"
[[ $(<"$zram") == $'[zram0]\nzram-size = ram\ncompression-algorithm = zstd\nswap-priority = 100' ]] || fail "$zram is not the zram0 zstd swap"
[[ ! -e /etc/systemd/zram-generator.conf ]] || fail "/etc/systemd/zram-generator.conf overrides $zram"
drirc=/usr/share/drirc.d/01-microos-turnip.conf
grep -q '<engine engine_name_match="vkd3d">' "$drirc" || fail "$drirc has no vkd3d engine entry"
grep -q '<option name="tu_dont_reserve_descriptor_set" value="true" />' "$drirc" || fail "$drirc does not keep every descriptor set"
grep -qx '  "audit=0",' /usr/lib/bootc/kargs.d/10-microos.toml || fail "10-microos.toml does not set audit=0"
uhid=$(grep -rsnE 'KERNEL=="[^"]*uhid|/dev/uhid' /usr/lib/udev/rules.d /etc/udev/rules.d || true)
[[ -z $uhid ]] || fail "a udev rule names uhid, InputPlumber's uhid adoption needs /dev/uhid root only: $uhid"

for h in steamos-update steamos-select-branch jupiter-biosupdate jupiter-dock-updater steamos-set-timezone \
  steamos-priv-write steamos-devkit-mode; do
  [[ -x /usr/bin/steamos-polkit-helpers/$h ]] || fail "steamos-polkit-helpers/$h missing"
done
for h in steamos-mandatory-update jupiter-initial-firmware-update; do
  [[ -x /usr/bin/$h ]] || fail "/usr/bin/$h missing"
done
[[ -f /usr/share/polkit-1/rules.d/50-microos-timezone.rules ]] || fail "timezone polkit rule missing"
steamrules=/usr/share/polkit-1/rules.d/50-microos-steam.rules
[[ -f $steamrules ]] || fail "$steamrules missing"
for a in inhibit-handle-power-key inhibit-handle-suspend-key suspend reboot power-off; do
  grep -qF "\"org.freedesktop.login1.$a\"" "$steamrules" || fail "$steamrules lacks org.freedesktop.login1.$a"
done
for r in 'RUN+="/usr/bin/chgrp wheel /sys%p/bl_power"' 'RUN+="/usr/bin/chmod g+w /sys%p/bl_power"'; do
  grep -qF "$r" /usr/lib/udev/rules.d/60-microos-backlight.rules || fail "60-microos-backlight.rules lacks $r"
done
! grep -qF '/sys%p/brightness' /usr/lib/udev/rules.d/60-microos-backlight.rules \
  || fail "60-microos-backlight.rules still opens brightness"
grep -qxF 'z /sys/class/backlight/backlight/brightness 0664 root microset -' /usr/lib/tmpfiles.d/microos-backlight.conf \
  || fail "microos-backlight.conf does not give brightness to group microset"
dtb=/usr/lib/modules/$kver/dtb/$(sed -n 's/^MICROOS_DTB=//p' /usr/lib/microos/bootimg.conf)
light=$(python3 - "$dtb" <<'PY'
import struct
import sys

data = open(sys.argv[1], "rb").read()
magic, _, off_struct, off_strings = struct.unpack(">IIII", data[:16])
assert magic == 0xD00DFEED, "not a DTB"


def cstr(at):
    end = data.index(b"\0", at)
    return data[at:end].decode(), end


pos, path, found = off_struct, [], None
while True:
    (token,) = struct.unpack(">I", data[pos:pos + 4])
    pos += 4
    if token == 1:
        name, end = cstr(pos)
        pos = (end + 4) & ~3
        path.append(name)
    elif token == 2:
        path.pop()
    elif token == 3:
        size, nameoff = struct.unpack(">II", data[pos:pos + 8])
        pos += 8
        value = data[pos:pos + size]
        pos = (pos + size + 3) & ~3
        if cstr(off_strings + nameoff)[0] == "compatible" and b"qcom,pm8150l-wled" in value.split(b"\0"):
            found = path[1:]
    elif token == 9:
        break
soc, spmi, pmic, leds = found
bus = spmi.split("@")[1] + "." + spmi.split("@")[0]
print(f"/sys/devices/platform/{soc}/{bus}/spmi-0/0-05/{bus}:{pmic}:{leds}/backlight/backlight/brightness")
PY
) || fail "no WLED backlight node in $dtb"
[[ $(< /usr/lib/systemd/system/microsetd.service.d/50-microos-backlight.conf) == $'[Service]\nReadWritePaths=-'"$light" ]] \
  || fail "50-microos-backlight.conf does not open $light"
grep -qE 'session\.dont-restore-off-profile"? *[=:] *true' /usr/share/wireplumber/wireplumber.conf.d/52-microos-pm2.conf \
  || fail "52-microos-pm2.conf does not set session.dont-restore-off-profile"
grep -qE 'api\.alsa\.soft-mixer"? *[=:] *true' /usr/share/wireplumber/wireplumber.conf.d/50-microos-soft-mixer.conf \
  || fail "50-microos-soft-mixer.conf does not set api.alsa.soft-mixer"
grep -qE 'dither\.method"? *[=:] *"?triangular' /usr/share/wireplumber/wireplumber.conf.d/55-microos-bt.conf \
  || fail "55-microos-bt.conf does not set dither.method triangular"
ucm=$(mktemp -d)/ucm2
cp -a /usr/share/alsa/ucm2 "$ucm"
sed -i 's/[$]{CardId}/0/g' "$ucm/Qualcomm/sm8250/PocketMICRO2-HiFi.conf"
mkdir -p "$ucm/conf.virt.d"
ln -s ../conf.d/sm8250/PocketMICRO2.conf "$ucm/conf.virt.d/PocketMICRO2.conf"
ucmdevs=$(ALSA_CONFIG_UCM2=$ucm alsaucm -c PocketMICRO2 list _devices/HiFi 2>/dev/null) || fail "alsaucm cannot list the PocketMICRO2 devices"
for d in Headphones Speaker Headset; do
  grep -qE "^ +[0-9]+: $d\$" <<< "$ucmdevs" || fail "alsaucm lists no $d device"
done
rm -rf "${ucm%/ucm2}"
for f in /usr/libexec/microos/microos-dp-audio /usr/libexec/microos/microos-dp-audio-sleep; do
  [[ -f $f && ! -L $f && $(stat -c '%a %U %G' "$f") == '755 root root' ]] || fail "$f missing, mode or owner"
done
dprules=/usr/lib/udev/rules.d/70-microos-dp-audio.rules
grep -qE '^ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card0", RUN\+="/usr/bin/systemd-run .* -p TimeoutStopSec=2 /usr/libexec/microos/microos-dp-audio hotplug"$' \
  "$dprules" || fail "$dprules lacks the card0 change rule through systemd-run"
! grep -q HOTPLUG "$dprules" || fail "$dprules matches HOTPLUG"
[[ -f /usr/share/wireplumber/scripts/microos/dp-sink.lua ]] || fail "wireplumber dp-sink.lua missing"
grep -qE '^ *provides *= *monitor\.microos\.dp-sink$' /usr/share/wireplumber/wireplumber.conf.d/53-microos-dp.conf \
  || fail "53-microos-dp.conf does not provide monitor.microos.dp-sink"
grep -qE '^ *monitor\.microos\.dp-sink *= *optional$' /usr/share/wireplumber/wireplumber.conf.d/53-microos-dp.conf \
  || fail "53-microos-dp.conf does not add monitor.microos.dp-sink to the main profile as optional"

rpm -q python3-gobject python3-evdev upower gstreamer1 gstreamer1-plugins-base gstreamer1-plugins-good pipewire-gstreamer \
  >/dev/null || fail "steam service or USB display rpms missing"
[[ $(rpm -q --qf '%{VENDOR}' steamos-manager) == MicroOS ]] || fail "steamos-manager is not the MicroOS build"
! rpm -q iwd >/dev/null 2>&1 || fail "iwd is installed"
for u in steamos-manager.service upower.service microos-powerd.service microos-vpower.service microsetd.service; do
  [[ $(systemctl is-enabled "$u") == enabled ]] || fail "$u is not enabled"
done
for u in steamos-manager.service microos-audio-sleep.service microos-audio.service microos-bt-reconnect.service; do
  [[ $(systemctl --global is-enabled "$u") == enabled ]] || fail "user $u is not enabled"
done
[[ $(systemctl --global is-enabled steamos-manager-session-cleanup.service) != enabled ]] \
  || fail "user steamos-manager-session-cleanup.service is enabled"
[[ -f /usr/share/steamos-manager/devices/microos-pm2.toml ]] || fail "microos-pm2.toml missing"
for f in /usr/lib/hwsupport/format-device.sh /usr/lib/hwsupport/trim-devices.sh /usr/lib/hwsupport/format-sdcard.sh \
  /usr/bin/steamos-polkit-helpers/steamos-format-device /usr/bin/steamos-polkit-helpers/steamos-format-sdcard \
  /usr/bin/steamos-polkit-helpers/steamos-trim-devices /usr/libexec/microos/microos-storage \
  /usr/libexec/microos/microos-pad-hold; do
  [[ -f $f && ! -L $f && -x $f ]] || fail "$f is not a regular executable"
  [[ $(stat -c '%a %U %G' "$f") == '755 root root' ]] || fail "$f mode or owner"
done
for f in /usr/share/polkit-1/actions/net.seilent.MicroOs.storage.policy /usr/share/polkit-1/rules.d/50-microos-storage.rules; do
  [[ $(stat -c '%a %U %G' "$f") == '644 root root' ]] || fail "$f missing, mode or owner"
done
for h in format-device format-sdcard trim-devices; do
  grep -qF "<action id=\"net.seilent.MicroOs.storage.$h\">" /usr/share/polkit-1/actions/net.seilent.MicroOs.storage.policy \
    || fail "storage policy lacks net.seilent.MicroOs.storage.$h"
  grep -qF ">/usr/bin/steamos-polkit-helpers/steamos-$h</annotate>" /usr/share/polkit-1/actions/net.seilent.MicroOs.storage.policy \
    || fail "storage policy lacks the steamos-$h exec.path"
  grep -qF "\"net.seilent.MicroOs.storage.$h\"" /usr/share/polkit-1/rules.d/50-microos-storage.rules \
    || fail "50-microos-storage.rules lacks net.seilent.MicroOs.storage.$h"
done
for a in eject-media filesystem-unmount-others; do
  grep -qF "\"org.freedesktop.udisks2.$a\"" /usr/share/polkit-1/rules.d/50-microos-storage.rules \
    || fail "50-microos-storage.rules lacks org.freedesktop.udisks2.$a"
done
grep -qF 'udisks.indexOf(action.id) >= 0 && device && device.indexOf("/dev/mmcblk") == 0' \
  /usr/share/polkit-1/rules.d/50-microos-storage.rules || fail "50-microos-storage.rules udisks2 actions not limited to /dev/mmcblk"
python3 - /usr/share/polkit-1/rules.d/50-microos-storage.rules <<'PY' || fail "50-microos-storage.rules udisks2 NO lines"
import re, sys
rule = open(sys.argv[1]).read()
m = re.search(r"var deny = \[(.*?)\];", rule, re.S)
deny = re.findall(r'"([^"]+)"', m.group(1)) if m else []
want = ["org.freedesktop.udisks2." + a for a in ("modify-device", "modify-device-system", "modify-device-other-seat",
                                               "open-device", "open-device-system", "loop-setup", "manage-md-raid",
                                               "filesystem-take-ownership")]
no = rule.find("if (deny.indexOf(action.id) >= 0) {\n    return polkit.Result.NO;")
user = rule.find('if (subject.user != "micro") {')
yes = rule.find("polkit.Result.YES")
if sorted(deny) != sorted(want) or not 0 <= user < no < yes:
    sys.exit("deny %s, user check at %d, NO at %d, first YES at %d" % (deny, user, no, yes))
PY
grep -qx 'd /run/microos/hold 0755 root root -' /usr/lib/tmpfiles.d/microos.conf || fail "tmpfiles lacks /run/microos/hold"
grep -qx 'f /run/microos/hold/.lock 0600 root root -' /usr/lib/tmpfiles.d/microos.conf || fail "tmpfiles lacks the root 0600 hold lock"
grep -qx 'f /run/microos/hold/.lock-keys 0600 root root -' /usr/lib/tmpfiles.d/microos.conf \
  || fail "tmpfiles lacks the root 0600 keys hold lock"
inputro=/usr/lib/udev/rules.d/72-microos-input-ro.rules
[[ $(stat -c '%a %U %G' "$inputro") == '644 root root' ]] || fail "$inputro missing, mode or owner"
udevadm verify --resolve-names=never "$inputro" > /dev/null 2>&1 || fail "$inputro does not verify"
python3 - "$inputro" <<'PY' || fail "$inputro sets a mode outside the root trusted nodes"
import re, sys
v20 = {
    "AYANEO Controller": ("0003", "4001", "0428", "!="),
    "aya-keys": ("0019", "0001", "0001", "!="),
    "gpio-keys": ("0019", "0001", "0001", "!="),
    "pm8941_pwrkey": ("0000", "0000", "0000", "!="),
    "pm8941_resin": ("0000", "0000", "0000", "!="),
    "InputPlumber Keyboard": ("0003", "1234", "5678", "=="),
}
bad, seen = [], []
for n, line in enumerate(open(sys.argv[1]).read().splitlines(), 1):
    if not line.strip():
        continue
    kv = re.findall(r'([A-Z_]+(?:\{[^}]*\})?)(==|!=|-=|\+=|:=|=)"([^"]*)"', line)
    d = {k: (op, v) for k, op, v in kv}
    if ", ".join('%s%s"%s"' % t for t in kv) != line.strip():
        bad.append("line %d does not parse: %s" % (n, line))
        continue
    name = d.get("ATTRS{name}", ("", ""))[1]
    ids = v20.get(name)
    pad = name == "AYANEO Controller"
    ok = (ids is not None and len(kv) == len(d)
          and d.get("SUBSYSTEM") == ("==", "input") and d.get("KERNEL") == ("==", "event*|js*" if pad else "event*")
          and d.get("DEVPATH") == (ids[3], "/devices/virtual/*")
          and d.get("ATTRS{id/bustype}") == ("==", ids[0]) and d.get("ATTRS{id/vendor}") == ("==", ids[1])
          and d.get("ATTRS{id/product}") == ("==", ids[2])
          and d.get("MODE") == ("=", "0600" if pad else "0640")
          and d.get("GROUP", (None, None)) == (("=", "root") if pad else (None, None))
          and d.get("TAG", (None, None)) == (("-=", "uaccess") if pad else (None, None))
          and d.get("ENV{ID_SEAT}", (None, None)) == (("=", "seat-none") if pad else (None, None))
          and set(d) <= {"SUBSYSTEM", "KERNEL", "DEVPATH", "ATTRS{name}", "ATTRS{id/bustype}", "ATTRS{id/vendor}",
                         "ATTRS{id/product}", "MODE", "GROUP", "TAG", "ENV{ID_SEAT}"})
    if not ok:
        bad.append("line %d: %s" % (n, line))
    seen.append(name)
if sorted(seen) != sorted(v20):
    bad.append("nodes %s" % seen)
if bad:
    sys.exit("\n".join(bad))
PY
python3 - <<'PY' || fail "udev rule order around 72-microos-input-ro.rules"
import os, sys
eff = {}
for d in ("/usr/lib/udev/rules.d", "/run/udev/rules.d", "/etc/udev/rules.d"):
    if os.path.isdir(d):
        for f in os.listdir(d):
            if f.endswith(".rules"):
                eff[f] = os.path.join(d, f)
names = sorted(eff)
ours, late = "72-microos-input-ro.rules", "73-seat-late.rules"
bad = [f for f in ("70-uaccess.rules", "71-seat.rules", ours, late) if f not in eff]
if not bad:
    if eff[ours] != "/usr/lib/udev/rules.d/" + ours:
        bad.append("%s overridden by %s" % (ours, eff[ours]))
    if not names.index("70-uaccess.rules") < names.index("71-seat.rules") < names.index(ours) < names.index(late):
        bad.append("order")
    if 'RUN{builtin}+="uaccess"' not in open(eff[late]).read():
        bad.append("%s does not apply the uaccess ACL" % late)
    for f in names[names.index(ours) + 1:names.index(late)]:
        if 'TAG+="uaccess"' in open(eff[f]).read():
            bad.append("%s adds uaccess after %s" % (eff[f], ours))
    for f in names[names.index(late) + 1:]:
        for n, line in enumerate(open(eff[f]).read().splitlines(), 1):
            if 'TAG+="uaccess"' not in line or line.lstrip().startswith("#"):
                continue
            if not any(g in line for g in ('SUBSYSTEM=="hidraw"', 'KERNEL=="hidraw*"', 'ENV{USE_INPUTPLUMBER}=="1"')):
                bad.append("%s:%d adds uaccess after %s: %s" % (eff[f], n, late, line))
    for d in ("/usr/lib/udev/rules.d", "/run/udev/rules.d", "/etc/udev/rules.d"):
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if "ENV{USE_INPUTPLUMBER}=" in open(os.path.join(d, f)).read().replace("ENV{USE_INPUTPLUMBER}==", ""):
                bad.append("%s/%s sets USE_INPUTPLUMBER" % (d, f))
    for d in ("/usr/lib/udev/hwdb.d", "/etc/udev/hwdb.d"):
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            match = []
            for line in open(os.path.join(d, f)).read().splitlines():
                if not line.strip() or line.startswith("#"):
                    match = []
                elif not line[0].isspace():
                    match.append(line)
                elif line.strip().startswith("USE_INPUTPLUMBER=") and any(not m.startswith("dmi:") for m in match):
                    bad.append("%s/%s sets USE_INPUTPLUMBER on %s" % (d, f, [m for m in match if not m.startswith("dmi:")]))
if bad:
    sys.exit("\n".join(bad))
PY
rpm -q f3 udisks2 exfatprogs dosfstools e2fsprogs >/dev/null || fail "storage rpms missing"
for c in f3probe pkexec wipefs sfdisk mkfs.ext4 mkfs.exfat fsck.ext4 fstrim flock jq busctl blkid findmnt iconv; do
  command -v "$c" >/dev/null || fail "$c is not on PATH"
done
cu=/usr/lib/systemd/system/microos-content.service
[[ $(systemctl is-enabled microos-content.service) == enabled ]] || fail "microos-content.service is not enabled"
grep -qxF 'ExecStartPre=/usr/libexec/microos/microos-storage content' "$cu" || fail "microos-content.service ExecStartPre is not content"
grep -qxF 'ExecStart=/usr/libexec/microos/microos-storage content-watch' "$cu" || fail "microos-content.service ExecStart is not content-watch"
SYSTEMD_LOG_LEVEL=warning systemd-analyze verify --man=no "$cu" || fail "systemd-analyze verify microos-content.service"
for l in ProtectSystem=strict ReadWritePaths=/run/microos ProtectHome=yes PrivateNetwork=yes RestrictAddressFamilies=AF_UNIX \
  NoNewPrivileges=yes CapabilityBoundingSet=; do
  grep -qxF "$l" "$cu" || fail "microos-content.service lacks $l"
done
for d in ROMs BIOS BIOS/retroarch Saves States Screenshots Media Music PC; do
  grep -qxF "d %h/$d 0755 - - -" /usr/share/user-tmpfiles.d/microos-content.conf || fail "microos-content.conf lacks $d 0755"
done
[[ -x /usr/libexec/microos/microos-powerd ]] || fail "microos-powerd missing"
[[ -x /usr/libexec/microos/microos-vpower ]] || fail "microos-vpower missing"
! grep -qE 'pwm|hwmon|thermal' /usr/libexec/microos/microos-powerd || fail "microos-powerd names a pwm, hwmon or thermal path"
pu=/usr/lib/systemd/system/microos-powerd.service
for l in CapabilityBoundingSet=CAP_DAC_OVERRIDE DevicePolicy=closed "DeviceAllow=char-input r" ProtectKernelTunables=yes \
  "ReadWritePaths=/sys/devices/system/cpu -/sys/class/devfreq/3d00000.gpu /sys/fs/cgroup /run/microos/hold -/sys/devices/platform/soc@0/3d00000.gpu/gpu_levels" \
  RuntimeDirectory=microos/gpu-undervolt RuntimeDirectoryPreserve=restart StateDirectory=microos/gpu-undervolt \
  "InaccessiblePaths=-/dev/shm -/dev/mqueue" ProtectKernelModules=yes ProtectKernelLogs=yes ProtectClock=yes \
  RestrictNamespaces=yes LockPersonality=yes SystemCallArchitectures=native; do
  grep -qxF "$l" "$pu" || fail "microos-powerd.service lacks $l"
done
! grep -q '^PrivateDevices=' "$pu" || fail "microos-powerd.service sets PrivateDevices"
uvconf=/usr/lib/microos/gpu-undervolt.conf
[[ $(stat -c '%a %U %G' "$uvconf") == '644 root root' ]] || fail "$uvconf missing, mode or owner"
python3 - "$uvconf" /usr/lib/modules/*/dtb/qcom/sm8250-ayaneo-pocket-micro2.dtb <<'PY' || fail "$uvconf rows break the level rules"
import struct
import sys

gfx = {0, 48, 64, 128, 144, 192, 224, 256, 320, 384, 416}
blob = open(sys.argv[2], "rb").read()
off_struct, off_strings = struct.unpack(">II", blob[8:16])
nodes, stack, pos = {}, [], off_struct
while True:
    token = struct.unpack(">I", blob[pos:pos + 4])[0]
    pos += 4
    if token == 1:
        end = blob.index(b"\0", pos)
        stack.append(blob[pos:end].decode())
        nodes["/".join(stack)] = {}
        pos = (end + 4) & ~3
    elif token == 2:
        stack.pop()
    elif token == 3:
        size, name = struct.unpack(">II", blob[pos:pos + 8])
        key = blob[off_strings + name:blob.index(b"\0", off_strings + name)].decode()
        nodes["/".join(stack)][key] = blob[pos + 8:pos + 8 + size]
        pos = (pos + 8 + size + 3) & ~3
    elif token == 9:
        break
phandles = {struct.unpack(">I", p["phandle"])[0]: n for n, p in nodes.items() if "phandle" in p}
gpus = [p for p in nodes.values() if b"qcom,adreno\0" in p.get("compatible", b"")]
if len(gpus) != 1:
    sys.exit(f"{len(gpus)} GPU nodes")
table = phandles[struct.unpack(">I", gpus[0]["operating-points-v2"])[0]]
opps = sorted((struct.unpack(">Q", p["opp-hz"])[0], struct.unpack(">I", p["opp-level"])[0])
              for n, p in nodes.items() if n.startswith(table + "/") and "opp-hz" in p)
names = set()
for raw in open(sys.argv[1]):
    fields = raw.split()
    if not fields:
        continue
    if len(fields) != 3 or fields[0] in names | {"off"}:
        sys.exit(f"bad row {raw.strip()}")
    names.add(fields[0])
    row = [tuple(int(v) for v in pair.split(":")) for pair in fields[2].split(",")]
    if [f for f, _ in row] != [f for f, _ in opps]:
        sys.exit(f"{fields[0]}: frequencies {[f for f, _ in row]} are not the GPU OPPs {[f for f, _ in opps]}")
    levels = [l for _, l in row]
    for (f, l), (_, dt) in zip(row, opps):
        if l not in gfx or l > dt:
            sys.exit(f"{fields[0]}: {f}:{l} not a gfx.lvl level at most the DT level {dt}")
    if levels != sorted(levels) or levels[0] < opps[0][1]:
        sys.exit(f"{fields[0]}: levels {levels} decrease or drop below {opps[0][1]}")
if not names:
    sys.exit("no rows")
PY
grep -qxF "low Low 305000000:64,400000000:128,441600000:128,490000000:128,525000000:144,587000000:192" "$uvconf" ||
  fail "$uvconf lacks the measured low row"
uvrules=/usr/lib/udev/rules.d/70-microos-gpu-undervolt.rules
udevadm verify --resolve-names=never "$uvrules" > /dev/null 2>&1 || fail "$uvrules does not verify"
for e in 'ENV{GPU_LEVELS_FALLBACK}=="?*"' 'ENV{GPU_LEVELS_APPLIED}=="1"'; do
  grep -F 'ACTION=="change", SUBSYSTEM=="platform", KERNEL=="3d00000.gpu", '"$e"', RUN+="/usr/bin/busctl --timeout=5 call net.seilent.MicroOs.Power /net/seilent/MicroOs/Power net.seilent.MicroOs.Power1 Reload"' \
    "$uvrules" > /dev/null || fail "$uvrules lacks the $e rule"
done
uvclean=/usr/lib/systemd/system/microos-gpu-undervolt-clean.service
for l in DefaultDependencies=no Conflicts=shutdown.target \
  "Before=shutdown.target display-manager.service user@1000.service systemd-user-sessions.service" \
  "After=systemd-tmpfiles-setup.service microos-powerd.service" Type=oneshot RemainAfterExit=yes \
  ExecStop=/usr/libexec/microos/microos-gpu-undervolt-clean ProtectSystem=strict \
  ReadWritePaths=-/var/lib/microos/gpu-undervolt CapabilityBoundingSet=; do
  grep -qxF "$l" "$uvclean" || fail "microos-gpu-undervolt-clean.service lacks $l"
done
f=/usr/libexec/microos/microos-gpu-undervolt-clean
[[ -f $f && ! -L $f && $(stat -c '%a %U %G' "$f") == '755 root root' ]] || fail "$f is not a regular executable"
! grep -q '/recorded' /usr/libexec/microos/microos-powerd "$f" || fail "the undervolt recorded marker is still named"
[[ $(rpm -q --qf '%{VENDOR}' microset) == MicroOS ]] || fail "microset is not the MicroOS build"
! rpm -q microset-devel >/dev/null 2>&1 || fail "microset-devel is installed"
[[ $(rpm -qf /usr/share/fonts/microset/selawk.ttf) == microset-fonts-* ]] || fail "Selawik is not in microset-fonts"
schema=/usr/share/microset/schema.d/10-microset.json
enum() { jq -er --arg k "$1" '.keys[$k].enum | sort | join(" ")' "$schema" || fail "$schema has no enum for $1"; }
[[ $(jq -r '.keys["display.brightness"].applier' "$schema") == backlight ]] \
  || fail "$schema has no display.brightness with applier backlight"
for k in audio.bt_codec audio.bt_codec_headphones; do
  codecs=$(python3 -c 'import re
s = open("/usr/libexec/microos/microos-audio").read()
print(" ".join(sorted(re.findall(r"\"(\w+)\": \"[^\"]+\"", re.search(r"^CODECS = \{(.*)\}$", s, re.M).group(1))) + ["auto"]))') \
    || fail "no CODECS table in microos-audio"
  for c in $(enum "$k"); do
    [[ " $codecs " == *" $c "* ]] || fail "$k value $c is not in microos-audio CODECS ($codecs)"
  done
done
profiles=$(sed -n 's/^\[\(.*\)\]$/\1/p' /usr/lib/microos/power-profiles.conf | grep -vx tdp | sort | paste -sd' ')
schemaprofiles=$(enum power.profile)
[[ $schemaprofiles == "$profiles" ]] || fail "power.profile enum $schemaprofiles, power-profiles.conf $profiles"
read -ra offered < "$(dirname "$0")/fixtures/pm2-scaling-available-governors.txt"
governors=$(enum power.governor)
for g in $governors; do
  [[ " ${offered[*]} " == *" $g "* ]] || fail "power.governor $g is not offered by the PM2"
done
tdps=$(sed -n '/^\[tdp\]$/,/^\[/s/^\([0-9]\+\)=.*/\1/p' /usr/lib/microos/power-profiles.conf | sort -n)
[[ $(jq -r '.keys["power.tdp"] | "\(.min) \(.max)"' "$schema") == "$(head -1 <<< "$tdps") $(tail -1 <<< "$tdps")" ]] \
  || fail "power.tdp range differs from the [tdp] table"
clocks="$(sed -n 's/^CLOCK_MIN = \([0-9]\+\)$/\1/p' /usr/libexec/microos/microos-powerd) $(sed -n 's/^CLOCK_MAX = \([0-9]\+\)$/\1/p' /usr/libexec/microos/microos-powerd)"
[[ $(jq -r '.keys["power.gpu_clock"] | "\(.min) \(.max)"' "$schema") == "$clocks" ]] \
  || fail "power.gpu_clock range differs from microos-powerd CLOCK_MIN CLOCK_MAX $clocks"
floors="$(sed -n 's/^FLOOR_MIN = \([0-9]\+\)$/\1/p' /usr/libexec/microos/microos-powerd) $(sed -n 's/^FLOOR_MAX = \([0-9]\+\)$/\1/p' /usr/libexec/microos/microos-powerd)"
[[ $(jq -r '.keys["power.game_floor"] | "\(.min) \(.max)"' "$schema") == "$floors" ]] \
  || fail "power.game_floor range differs from microos-powerd FLOOR_MIN FLOOR_MAX $floors"
rpm -q sddm sddm-wayland-generic steam-devices dbus-tools gtk2 openal-soft sdl2-compat libXcomposite libXdamage libXfixes libXi \
  libXinerama libXrandr libXrender libXtst libSM libICE at-spi2-atk cups-libs libssh2 libva libvdpau \
  google-noto-sans-cjk-vf-fonts google-noto-color-emoji-fonts google-noto-sans-arabic-vf-fonts \
  google-noto-sans-hebrew-vf-fonts google-noto-sans-thai-vf-fonts google-noto-sans-devanagari-vf-fonts \
  google-noto-sans-mono-vf-fonts >/dev/null \
  || fail "game mode rpms missing"
[[ $(rpm -q --qf '%{VENDOR}' mangohud) == MicroOS ]] || fail "mangohud is not the MicroOS build"
command -v mangoapp >/dev/null || fail "mangoapp is not on PATH"
! rpm -q mangohud-mangoplot >/dev/null 2>&1 || fail "mangohud-mangoplot is installed"
for p in gamescope gamescope-session gamescope-session-steam; do
  [[ $(rpm -q --qf '%{VENDOR}' "$p") == MicroOS ]] || fail "$p is not the MicroOS build"
done
[[ -z $(rpm -qa 'kwin*' 'plasma*' xorg-x11-server-Xorg fedora-logos) ]] \
  || fail "desktop rpms installed: $(rpm -qa 'kwin*' 'plasma*' xorg-x11-server-Xorg fedora-logos | tr '\n' ' ')"
[[ $(readlink /etc/systemd/system/display-manager.service) == */sddm.service ]] || fail "display-manager.service is not sddm"
for f in /etc/subuid /etc/subgid; do
  [[ $(< "$f") == micro:524288:65536 ]] || fail "$f is not micro:524288:65536"
  [[ $(stat -c '%a %U %G' "$f") == '644 root root' ]] || fail "$f mode or owner"
done

for p in es-de microemu; do
  [[ $(rpm -q --qf '%{VENDOR}' "$p") == MicroOS ]] || fail "$p is not the MicroOS build"
done
for b in /usr/bin/es-de /usr/bin/es-pdf-convert /usr/bin/retroarch; do
  ! ldd "$b" | grep -q 'not found' || fail "$b has unresolved libraries"
done
[[ $(rpm -qf --qf '%{VENDOR}' /usr/bin/retroarch) == 'Fedora Project' ]] || fail "retroarch is not Fedora's"
rpm -q gtk3 python3-gobject python3-cairo pango xprop >/dev/null || fail "MicroEMU OSD rpms missing"
[[ $(stat -c '%a %U' /usr/libexec/microos/microos-openh264) == '755 root' ]] || fail "microos-openh264 mode"
for c in curl rpmkeys rpm rpm2cpio cpio python3; do
  command -v "$c" >/dev/null || fail "$c is not on PATH (microos-openh264)"
done
python3 -c 'from compression import zstd' || fail "python3 has no compression.zstd (microos-openh264)"
grep -qx 'ExecStart=/usr/libexec/microos/microos-openh264' /usr/lib/systemd/system/microos-openh264.service || fail "microos-openh264.service ExecStart"
for kv in User=microos-openh264 Group=microos-openh264 StateDirectory=microos/openh264 StateDirectoryMode=0755 MemoryMax=512M; do
  grep -qx "$kv" /usr/lib/systemd/system/microos-openh264.service || fail "microos-openh264.service lacks $kv"
done
grep -qx 'u microos-openh264 - "MicroOS openh264 fetch" /var/lib/microos/openh264 /usr/sbin/nologin' /usr/lib/sysusers.d/microos-openh264.conf \
  || fail "sysusers has no microos-openh264"
grep -qx 'CapabilityBoundingSet=' /usr/lib/systemd/system/microos-openh264.service || fail "microos-openh264.service keeps capabilities"
[[ $(systemctl is-enabled microos-openh264.timer) == enabled ]] || fail "microos-openh264.timer is not enabled"
h264db=$(mktemp -d)
rpmkeys --dbpath "$h264db" --import /usr/share/microos/openh264/RPM-GPG-KEY-fedora-44-primary || fail "openh264 key does not import"
[[ $(rpm --dbpath "$h264db" -q gpg-pubkey --qf '%{VERSION}\n') == 36f612dcf27f7d1a48a835e4dbfcf71c6d9f90a6 ]] \
  || fail "openh264 key is not the Fedora 44 primary key"
cmp -s /usr/share/microos/openh264/RPM-GPG-KEY-fedora-44-primary /etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-44-primary \
  || fail "openh264 key differs from fedora-gpg-keys"
rm -rf "$h264db"
[[ ! -e /usr/lib/microemu && ! -e /usr/lib/armada && ! -e /usr/lib/extension-release.d/extension-release.microemu ]] \
  || fail "MicroEMU sysext or bundled tree left"
elf=$(rpm -ql microemu | python3 -c '
import os, sys
for p in sys.stdin.read().splitlines():
    if os.path.isfile(p) and not os.path.islink(p) and open(p, "rb").read(4) == b"\x7fELF":
        print(p)
')
[[ -z $elf ]] || fail "microemu ships ELF files: $elf"
emucores=$(python3 - <<'PY'
import xml.etree.ElementTree as ET
text = open("/usr/share/microemu/es-de/es_systems.xml").read()
for c in ET.fromstring("<root>" + text.split("?>", 1)[-1] + "</root>").iter("command"):
    w = (c.text or "").split()
    if w and w[0] == "/usr/libexec/microemu/bin/retroarch" and "-L" in w:
        print(w[w.index("-L") + 1])
    elif w:
        print(w[0])
PY
) || fail "cannot read es_systems.xml"
[[ -n $emucores ]] || fail "es_systems.xml has no commands"
while read -r f; do
  [[ -f $f && ( $f == *.so || -x $f ) ]] || fail "es_systems.xml runs $f, which is missing"
  [[ $f != /usr/lib64/libretro/* || $(rpm -qf --qf '%{VENDOR}' "$f") == 'Fedora Project' ]] || fail "$f is not from a Fedora core package"
done < <(sort -u <<< "$emucores")
hits=$(grep -rlE 'armada|/run/armada|session-control|date \+%s|EPOCHREALTIME' /usr/libexec/microemu /usr/lib/microos/sessions.d/microemu.conf \
  /usr/lib/microos/hotkeys.d/microemu.conf /usr/share/gamescope-session-plus/sessions.d/microemu /usr/share/microemu/retroarch || true)
[[ -z $hits ]] || fail "Armada names or wall clock waits in MicroEMU files: $hits"

seedrpm=(/seed-rpm/microos-steam-seed-*.aarch64.rpm)
[[ ${#seedrpm[@]} -eq 1 && -f ${seedrpm[0]} ]] || fail "expected one microos-steam-seed RPM in /seed-rpm"
! rpm -q microos-steam-seed >/dev/null 2>&1 || fail "microos-steam-seed is installed as an RPM"
[[ $(rpm -qp --qf '%{FILEDIGESTALGO}' "${seedrpm[0]}") == 8 ]] || fail "seed RPM file digests are not sha256"
[[ -f /usr/share/microos-seed/steam-seed.tar.zst ]] || fail "seed tar missing"
while IFS='|' read -r path digest mode; do
  if [[ $mode == 100* ]]; then
    [[ $(sha256sum < "$path" | cut -d' ' -f1) == "$digest" ]] || fail "$path differs from the seed RPM"
    [[ $(stat -c '%a' "$path") == "${mode: -3}" ]] || fail "$path mode differs from the seed RPM"
  else
    [[ -d $path ]] || fail "$path missing"
  fi
done < <(rpm -qp --qf '[%{FILENAMES}|%{FILEDIGESTS}|%{FILEMODES:octal}\n]' "${seedrpm[0]}")
[[ $(find /usr/share/microos-seed -mindepth 1 | sort) == "$(rpm -qlp "${seedrpm[0]}" | grep '^/usr/share/microos-seed/' | sort)" ]] \
  || fail "/usr/share/microos-seed holds files outside the seed RPM"
for f in /usr/libexec/microos/microos-slpi-sensors /usr/lib/systemd/system-sleep/microos-hexagonrpcd; do
  [[ -f $f && ! -L $f && $(stat -c '%a %U %G' "$f") == '755 root root' ]] || fail "$f missing, mode or owner"
done
command -v hexagonrpcd >/dev/null || fail "hexagonrpcd is not on PATH"
slpirules=/usr/lib/udev/rules.d/70-microos-slpi.rules
for r in 'SUBSYSTEM=="remoteproc", ATTR{name}=="slpi", TAG+="systemd", ENV{SYSTEMD_WANTS}+="microos-slpi-sensors.service"' \
  'SUBSYSTEM=="misc", KERNEL=="fastrpc-sdsp", GROUP="hexagonrpc", MODE="0660", TAG+="systemd", ENV{SYSTEMD_WANTS}+="microos-hexagonrpcd.service"'; do
  grep -qxF "$r" "$slpirules" || fail "$slpirules lacks $r"
done
grep -qx 'ExecStart=/usr/bin/hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -s -R /var/lib/microos/slpi/current/hexagonfs' \
  /usr/lib/systemd/system/microos-hexagonrpcd.service || fail "microos-hexagonrpcd.service ExecStart"
grep -qx 'DynamicUser=yes' /usr/lib/systemd/system/microos-hexagonrpcd.service || fail "microos-hexagonrpcd.service is not DynamicUser"
grep -qx 'd /var/lib/microos/slpi 0755 root root -' /usr/lib/tmpfiles.d/microos.conf || fail "tmpfiles lacks /var/lib/microos/slpi"
f=/usr/libexec/microos/microos-bt-address
[[ -f $f && ! -L $f && $(stat -c '%a %U %G' "$f") == '755 root root' ]] || fail "$f missing, mode or owner"
command -v btmgmt >/dev/null || fail "btmgmt is not on PATH"
grep -qxF 'SUBSYSTEM=="bluetooth", KERNEL=="hci0", TAG+="systemd", ENV{SYSTEMD_WANTS}+="microos-bt-address.service"' \
  /usr/lib/udev/rules.d/70-microos-bt.rules || fail "70-microos-bt.rules lacks the hci0 rule"
grep -qx 'Before=bluetooth.service' /usr/lib/systemd/system/microos-bt-address.service || fail "microos-bt-address.service is not before bluetooth.service"
rpm -q plymouth plymouth-scripts plymouth-plugin-script >/dev/null || fail "plymouth rpms missing"
while read -r n r; do
  [[ $r == *.microos ]] || fail "$n release $r is not ours"
done < <(rpm -qa --qf '%{NAME} %{RELEASE}\n' 'plymouth*')
retain='Closing FB %u (retaining)'
grep -qaF "$retain" /usr/lib64/plymouth/renderers/drm.so || fail "renderers/drm.so lacks '$retain'"
for f in microos.plymouth microos.script wordmark.png starting.png updating.png micro-dap.png micro-emu.png steam-os.png; do
  [[ -f /usr/share/plymouth/themes/microos/$f ]] || fail "plymouth theme lacks $f"
done
while read -r h f; do
  [[ $(sha256sum "/usr/share/plymouth/themes/microos/$f" | cut -d' ' -f1) == "$h" ]] || fail "plymouth theme $f sha256"
done <<'EOF'
58bcb04911a993446f2c66125a5bcebff53cb77793729dde5137b790c8def530 wordmark.png
66710e9609fc93ca3c4beb90f72fabb561979f5118ab5b392f38b60602eabef4 starting.png
bcdf7ae9b099ff425628cce9233e68b88fc738d83f6690fae2f91535ba4510c8 updating.png
fc260da897c77c7f6cadedb5778a6cad3e9ffdd096e8e08ff660c58a23d2a316 micro-dap.png
1707d4b1dd3b21080243c5c1aaf3c5f69dabea01b34b94ba16645f07bfeab83b micro-emu.png
99de3f2ed66b6cba2a343ecba55c7a3c8ee50322c7f4ac856386e5ac4b30825c steam-os.png
EOF
[[ $(< /etc/plymouth/plymouthd.conf) == $'[Daemon]\nTheme=microos\nShowDelay=0\nDeviceScale=1' ]] || fail "plymouthd.conf"
[[ $(plymouth-set-default-theme) == microos ]] || fail "plymouth default theme is $(plymouth-set-default-theme)"
for f in /usr/libexec/microos/microos-splash-quit /usr/libexec/microos/microos-splash-update \
  /usr/libexec/microos/microos-splash-switch /usr/libexec/microos/microos-splash-gate /usr/libexec/microos/microos-shm-reap; do
  [[ -f $f && ! -L $f && $(stat -c '%a %U %G' "$f") == '755 root root' ]] || fail "$f missing, mode or owner"
done
[[ -L /etc/systemd/system/display-manager.service.wants/microos-splash-quit.service ]] \
  || fail "microos-splash-quit.service is not wanted by display-manager.service"
[[ -f /usr/lib/systemd/system/microos-splash-switch.service ]] || fail "microos-splash-switch.service missing"
grep -qxF 'f /run/microos/splash.lock 0644 root root -' /usr/lib/tmpfiles.d/microos.conf || fail "tmpfiles lacks /run/microos/splash.lock"
pre=$(systemctl --global cat gamescope-session-plus@microdap.service | awk 'index($0, "ExecStartPre=") == 1 { v = substr($0, 14); if (v == "") n = 0; else l[++n] = v }
  END { for (i = 1; i <= n; i++) print l[i] }') || fail "systemctl --global cat gamescope-session-plus@microdap.service"
grep -qxF -- '-/usr/libexec/microos/microos-splash-gate' <<< "$pre" \
  || fail "effective gamescope-session-plus@microdap.service ExecStartPre lacks the splash gate: $pre"
for s in steam microdap microemu; do
  for k in ExecStartPre ExecStopPost; do
    v=$(systemctl --global cat "gamescope-session-plus@$s.service" | awk -v k="$k=" 'index($0, k) == 1 { v = substr($0, length(k) + 1); if (v == "") n = 0; else l[++n] = v }
      END { for (i = 1; i <= n; i++) print l[i] }') || fail "systemctl --global cat gamescope-session-plus@$s.service"
    grep -qxF -- '-/usr/bin/systemctl --user start --no-block microos-shm-reap-request.service' <<< "$v" \
      || fail "effective gamescope-session-plus@$s.service $k lacks the shm reap request with the - prefix: $v"
  done
done
for s in steam microdap microemu recovery; do
  unit=$(systemctl --global cat "gamescope-session-plus@$s.service") || fail "systemctl --global cat gamescope-session-plus@$s.service"
  for k in ExecStart ExecStartPre ExecStopPost; do
    v=$(awk -v k="$k=" 'index($0, k) == 1 { v = substr($0, length(k) + 1); if (v == "") n = 0; else l[++n] = v }
      END { for (i = 1; i <= n; i++) print l[i] }' <<< "$unit")
    if [[ $k == ExecStart ]]; then
      [[ $v == '/usr/share/gamescope-session-plus/gamescope-session-plus %i' ]] \
        || fail "effective gamescope-session-plus@$s.service ExecStart does not pass the instance as the client: $v"
    else
      grep -qxF -- '-/usr/bin/rm -f %t/gamescope-session-plus/%i.env' <<< "$v" \
        || fail "effective gamescope-session-plus@$s.service $k lacks the Wayland display file removal: $v"
    fi
  done
done
on=$'[Unit]\nOnSuccess=microos-shm-reap-request.service\nOnFailure=microos-shm-reap-request.service'
for d in app-steam-.scope.d microemu-game.scope.d; do
  [[ $(< "/usr/lib/systemd/user/$d/50-microos-shm-reap.conf") == "$on" ]] || fail "$d shm reap drop-in"
done
reaper=$(systemctl cat microos-shm-reap@1000.service) || fail "systemctl cat microos-shm-reap@1000.service"
for l in 'CapabilityBoundingSet=CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_SETUID' NoNewPrivileges=yes \
  ProtectSystem=strict TimeoutStartSec=30 ProtectHome=yes PrivateNetwork=yes RestrictAddressFamilies=AF_UNIX \
  ProtectKernelTunables=yes ProtectKernelModules=yes ProtectKernelLogs=yes ProtectControlGroups=yes RestrictNamespaces=yes \
  LockPersonality=yes SystemCallArchitectures=native RestrictSUIDSGID=yes; do
  grep -qxF "$l" <<< "$reaper" || fail "microos-shm-reap@.service lacks $l"
done
! grep -qE '^(PrivateDevices|ProtectProc|AmbientCapabilities|User)=' <<< "$reaper" || fail "microos-shm-reap@.service hides /dev/shm or /proc or drops CAP_SETUID"
[[ $(< /usr/share/polkit-1/rules.d/50-microos-shm-reap.rules) == 'polkit.addRule(function(action, subject) {
  if (action.id != "org.freedesktop.systemd1.manage-units" || subject.user != "micro") {
    return;
  }
  if (action.lookup("verb") == "start" && action.lookup("unit") == "microos-shm-reap@1000.service") {
    return polkit.Result.YES;
  }
});' ]] || fail "50-microos-shm-reap.rules"
quit="-/bin/sh -c '/usr/bin/plymouth deactivate || /usr/bin/plymouth quit'"
execs() {
  systemctl cat "$1" | awk -v k="$2=" 'index($0, k) == 1 { v = substr($0, length(k) + 1); if (v == "") n = 0; else l[++n] = v }
    END { for (i = 1; i <= n; i++) print l[i] }'
}
[[ $(execs bluetooth.service ExecStart) == "/usr/libexec/bluetooth/bluetoothd -P admin" ]] \
  || fail "effective bluetooth.service ExecStart: $(execs bluetooth.service ExecStart)"
[[ $(execs bluetooth.service ConfigurationDirectory) == bluetooth ]] || fail "bluetooth.service ConfigurationDirectory is not bluetooth"
btd=$(timeout 5 /usr/libexec/bluetooth/bluetoothd -n -d 2>&1 || true)
grep -qF 'parsing /etc/bluetooth/main.conf' <<< "$btd" && grep -qF 'General.Experimental = true' <<< "$btd" \
  || fail "bluetoothd does not read Experimental = true from /etc/bluetooth/main.conf"
! grep -qE 'Unknown (key|group)' <<< "$btd" || fail "bluetoothd rejects a key in /etc/bluetooth/main.conf: $(grep -E 'Unknown (key|group)' <<< "$btd")"
attempts=$(python3 -c 'from gi.repository import GLib
k = GLib.KeyFile()
k.load_from_file("/etc/bluetooth/main.conf", GLib.KeyFileFlags.NONE)
print(k.get_integer("Policy", "ReconnectAttempts"))') || fail "no Policy.ReconnectAttempts in /etc/bluetooth/main.conf"
[[ $attempts == 0 ]] || fail "Policy.ReconnectAttempts is $attempts"
! grep -rqs 'bluez5\.auto-connect' /usr/share/wireplumber /etc/wireplumber || fail "a WirePlumber config sets bluez5.auto-connect"
systemd-analyze cat-config systemd/logind.conf | grep -qx 'UserStopDelaySec=infinity' || fail "logind.conf lacks UserStopDelaySec=infinity"
starting="-/bin/sh -c '/usr/bin/plymouth display-message --text=microos-starting; /usr/bin/plymouth deactivate || /usr/bin/plymouth quit'"
[[ $(execs plymouth-quit.service ExecStart) == "$starting" ]] || fail "effective plymouth-quit.service ExecStart: $(execs plymouth-quit.service ExecStart)"
execs sddm.service ExecStartPre | grep -qxF -- "$quit" || fail "sddm.service has no plymouth deactivate ExecStartPre"
for u in plymouth-reboot plymouth-poweroff plymouth-halt; do
  [[ $(execs $u.service ExecStartPost) == $'-/usr/libexec/microos/microos-splash-update\n-/usr/bin/plymouth show-splash' ]] \
    || fail "effective $u.service ExecStartPost: $(execs $u.service ExecStartPost)"
done
while read -r u p; do
  [[ $p == -* || $p == /sys/* ]] && continue
  grep -qE "^d $p [0-7]+ " /usr/lib/tmpfiles.d/*.conf || fail "${u##*/} ReadWritePaths=$p has no tmpfiles line"
done < <(awk -F= '/^ReadWritePaths=/ { n = split($2, a, " "); for (i = 1; i <= n; i++) print FILENAME, a[i] }' \
  /usr/lib/systemd/system/microos-*)
leak=$(find / -xdev \( -path '*/qcom/sm8250/ayaneo/*' -o -type d \( -name slpi -o -name hexagonfs \) \
  -o -name slpi.mdt -o -name 'slpi.b[0-9][0-9]' \) -print -quit 2>/dev/null || true)
[[ -z $leak ]] || fail "SLPI firmware or HexagonFS tree in the image: $leak"
SYSTEMD_LOG_LEVEL=warning systemd-analyze verify --man=no "${units[@]}" /usr/lib/systemd/system/steamos-manager.service \
  /usr/lib/systemd/system/sshd.service /usr/lib/systemd/system/bootc-generic-growpart.service \
  /usr/lib/systemd/system/ostree-finalize-staged.service /usr/lib/systemd/system/sddm.service \
  /usr/lib/systemd/system/plymouth-quit.service /usr/lib/systemd/system/plymouth-reboot.service \
  /usr/lib/systemd/system/plymouth-poweroff.service /usr/lib/systemd/system/plymouth-halt.service || fail "systemd-analyze verify"
mkdir -p "$tmp/xdg"
XDG_RUNTIME_DIR=$tmp/xdg SYSTEMD_LOG_LEVEL=warning systemd-analyze verify --user --man=no \
  /usr/lib/systemd/user/microos-*.service /usr/lib/systemd/user/steamos-manager.service gamescope-session-plus@steam.service \
  /usr/lib/systemd/user/game.slice || fail "systemd-analyze verify --user"
SYSTEMD_LOG_LEVEL=warning systemd-analyze verify --man=no microos-shm-reap@1000.service || fail "systemd-analyze verify microos-shm-reap@1000.service"
XDG_RUNTIME_DIR=$tmp/xdg SYSTEMD_LOG_LEVEL=warning systemd-analyze verify --user --man=no microos-shm-reap-request.service \
  || fail "systemd-analyze verify --user microos-shm-reap-request.service"
[[ -f /usr/lib/systemd/user/microos-steam-seed.service ]] || fail "microos-steam-seed.service missing"
grep -qxF CPUWeight=100 /usr/lib/systemd/user/game.slice || fail "game.slice lacks CPUWeight=100"
[[ $(systemctl --global is-enabled game.slice) == enabled ]] || fail "user game.slice is not enabled"
[[ $(< /usr/lib/systemd/user/app-steam-.scope.d/50-microos-game-slice.conf) == $'[Scope]\nSlice=game.slice' ]] \
  || fail "Steam game scope drop-in"
[[ $(< /usr/lib/systemd/user/gamescope-session-plus@.service.d/20-microos-hotkeyd.conf) == $'[Unit]\nWants=microos-hotkeyd@%i.service' ]] \
  || fail "hotkeyd drop-in"
[[ -e /usr/lib/systemd/user/microos-hotkeyd.service || -e /usr/lib/systemd/user/gamescope-session-plus@steam.service.d/20-microos-hotkeyd.conf ]] \
  && fail "Steam only hotkeyd unit or drop-in present"
grep -qx 'ExecStart=/usr/libexec/microos/microos-hotkeyd %i' /usr/lib/systemd/user/microos-hotkeyd@.service || fail "hotkeyd unit ExecStart"
grep -qx 'BindsTo=gamescope-session-plus@%i.service' /usr/lib/systemd/user/microos-hotkeyd@.service || fail "hotkeyd unit BindsTo"
grep -qx 'After=gamescope-session-plus@%i.service' /usr/lib/systemd/user/microos-hotkeyd@.service || fail "hotkeyd unit After"
[[ -f /usr/lib/microos/hotkeys.d/steam.conf && -f /usr/lib/microos/hotkeys.d/recovery.conf ]] || fail "hotkeys.d tables missing"
[[ -f /usr/lib/systemd/user/gamescope-session-plus@steam.service.d/10-microos.conf ]] || fail "gamescope-session-plus@steam drop-in missing"
grep -qx 'ExecStartPre=-/usr/libexec/microos/microos-pad-target deck-uhid keyboard' \
  /usr/lib/systemd/user/gamescope-session-plus@steam.service.d/30-microos-pad.conf || fail "steam pad target drop-in"
[[ $(stat -c '%a %U' /usr/libexec/microos/microos-pad-target) == '755 root' ]] || fail "microos-pad-target mode"
[[ $(rpm -q --qf '%{VENDOR}' microset-settings) == MicroOS ]] || fail "microset-settings is not the MicroOS build"
ou=/usr/lib/systemd/user/microset-overlay@.service
grep -qxF 'ExecStart=/usr/bin/microset-settings --overlay' "$ou" || fail "microset-overlay@ ExecStart"
grep -qxF 'BindsTo=gamescope-session-plus@%i.service' "$ou" || fail "microset-overlay@ BindsTo"
XDG_RUNTIME_DIR=$tmp/xdg SYSTEMD_LOG_LEVEL=warning systemd-analyze verify --user --man=no microset-overlay@steam.service \
  || fail "systemd-analyze verify --user microset-overlay@steam.service"
for s in steam microdap microemu; do
  [[ $(< "/usr/lib/systemd/user/gamescope-session-plus@$s.service.d/30-microset-overlay.conf") == $'[Unit]\nWants=microset-overlay@'"$s"'.service' ]] \
    || fail "$s session overlay drop-in"
  [[ $(< "/usr/lib/microos/hotkeys.d/$s.conf.d/60-microset.conf") == 'rc tap call net.seilent.MicroSet.Overlay /net/seilent/MicroSet/Overlay net.seilent.MicroSet.Overlay1 Toggle' ]] \
    || fail "$s overlay hotkey drop-in"
done
python3 - <<'PY' || fail "hotkeyd rc tap is not the overlay toggle in every session"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("hotkeyd", "/usr/libexec/microos/microos-hotkeyd")
h = importlib.util.module_from_spec(importlib.util.spec_from_loader("hotkeyd", loader))
loader.exec_module(h)
want = ("call", "net.seilent.MicroSet.Overlay", "/net/seilent/MicroSet/Overlay", "net.seilent.MicroSet.Overlay1", "Toggle")
bad = [s for s in ("steam", "microdap", "microemu") if h.load_table(s).get(("rc", "tap")) != want]
if bad:
    print(f"FAIL: rc tap in {bad}", file=sys.stderr)
    sys.exit(1)
PY

[[ $(grep '^ExecStop=' /usr/lib/systemd/system/ostree-finalize-staged.service) == 'ExecStop=/usr/bin/ostree admin finalize-staged' ]] \
  || fail "ostree-finalize-staged.service ExecStop changed"
stops=$(systemctl cat ostree-finalize-staged.service \
  | awk '/^ExecStop=/ { sub(/^ExecStop=/, ""); if ($0 == "") n = 0; else l[++n] = $0 } END { for (i = 1; i <= n; i++) print l[i] }') \
  || fail "systemctl cat ostree-finalize-staged.service"
[[ $stops == '-/usr/libexec/microos/microos-splash-update --finalize'$'\n''/usr/libexec/microos/microos-bootlog run finalize-staged -- /usr/bin/ostree admin finalize-staged'$'\n''-/usr/libexec/microos/microos-bootlog run finalize -- /usr/libexec/microos/microos-bootimg-update' ]] \
  || fail "effective ostree-finalize-staged.service ExecStop: $stops"
after=$(systemctl cat microos-boot-ok.service | sed -n 's/^After=//p' | tr ' ' '\n') || fail "systemctl cat microos-boot-ok.service"
for u in ostree-finalize-staged.service microos-bootimg-regen.service; do
  grep -qx "$u" <<< "$after" || fail "microos-boot-ok.service is not After=$u"
done

pol=/etc/containers/policy.json
keys=(/usr/share/microos/keys/microos.pub /usr/share/microos/keys/microos-backup.pub /usr/share/microos/keys/microos-next.pub)
jq -e '.default == [{"type": "reject"}]' "$pol" >/dev/null || fail "policy default is not reject"
jq -e '.transports.docker["ghcr.io/seilent/microos"] == [{"type": "sigstoreSigned", "keyPaths": $ARGS.positional,
  "signedIdentity": {"type": "matchRepository"}}]' --args "${keys[@]}" < "$pol" >/dev/null || fail "policy scope ghcr.io/seilent/microos"
for k in "${keys[@]}"; do
  openssl pkey -pubin -noout -in "$k" 2>/dev/null || fail "$k is not a public key"
done
[[ $(< /etc/containers/registries.d/ghcr-microos.yaml) == $'docker:\n  ghcr.io/seilent/microos:\n    use-sigstore-attachments: true' ]] \
  || fail "registries.d ghcr-microos.yaml"

mkdir -p "$tmp/etc/ssh"
ssh-keygen -A -f "$tmp" >/dev/null
hk=()
for k in "$tmp"/etc/ssh/ssh_host_*_key; do hk+=(-h "$k"); done
sshd -T "${hk[@]}" > "$tmp/sshd"
for kv in 'passwordauthentication no' 'kbdinteractiveauthentication no' 'permitrootlogin no' 'allowusers micro' \
  'authenticationmethods publickey' 'x11forwarding no' 'gssapiauthentication no'; do
  grep -qx "$kv" "$tmp/sshd" || fail "sshd -T lacks '$kv'"
done

systemd-sysusers >/dev/null 2>&1
[[ $(id -u micro):$(id -g micro) == 1000:1000 ]] || fail "micro is not 1000:1000"
groups=$(id -nG micro)
for g in wheel systemd-journal input video render audio; do
  [[ " $groups " == *" $g "* ]] || fail "micro is not in $g"
done
[[ $(getent passwd micro | cut -d: -f6,7) == /var/home/micro:/bin/bash ]] || fail "micro home or shell"
h264user=$(getent passwd microos-openh264) || fail "user microos-openh264 missing"
(( $(cut -d: -f3 <<< "$h264user") < 1000 )) || fail "microos-openh264 is not a system user"
[[ $(cut -d: -f7 <<< "$h264user") == */nologin ]] || fail "microos-openh264 has a login shell"
microset=$(getent passwd microset) || fail "user microset missing"
(( $(cut -d: -f3 <<< "$microset") < 1000 )) || fail "microset is not a system user"
[[ $(cut -d: -f7 <<< "$microset") == */nologin ]] || fail "microset has a login shell"
hexgid=$(getent group hexagonrpc | cut -d: -f3) || fail "group hexagonrpc missing"
(( hexgid < 1000 )) || fail "hexagonrpc is not a system group"
rules=$(sudo -l -U micro)
grep -q '(ALL) ALL' <<< "$rules" || fail "micro has no wheel sudo rule"
! grep -q NOPASSWD <<< "$rules" || fail "micro has a NOPASSWD rule"
! grep -qE '/tee( |,|$)' <<< "$rules" || fail "micro has a sudo rule for tee"

[[ $(rpm -q --qf '%{VENDOR}' microdap) == MicroOS ]] || fail "microdap is not the MicroOS build"
[[ ! -e /usr/lib/extension-release.d && ! -e /var/lib/extensions ]] || fail "sysext tree in the image"
for p in microdap microemu; do
  rpm -q "$p" >/dev/null 2>&1 || continue
  while IFS= read -r f; do
    [[ -f $f && ! -L $f ]] || continue
    owners=$(rpm -qf --qf '%{NAME}\n' "$f" | sort -u | paste -sd' ')
    [[ $owners == "$p" ]] || fail "$f is owned by $owners"
    ! grep -qiI armada "$f" || fail "text file $f names armada"
    ! grep -q set-default-sink "$f" || fail "$f runs set-default-sink"
  done < <(rpm -ql "$p")
done
sessions=$(microos-session list) || fail "microos-session list"
grep -qxF $'microdap\tMicroDAP\tyes' <<< "$sessions" || fail "microos-session list lacks microdap: $(tr '\n' ' ' <<< "$sessions")"
for u in microdap-radio.service microdap-usb-audio.service; do
  [[ $(systemctl is-enabled "$u") == enabled ]] || fail "$u is not enabled"
done
for u in microdap-overlay.service microdap-bt.service; do
  [[ $(systemctl --global is-enabled "$u") == enabled ]] || fail "user $u is not enabled"
done
SYSTEMD_LOG_LEVEL=warning systemd-analyze verify --man=no /usr/lib/systemd/system/microdap-radio.service \
  /usr/lib/systemd/system/microdap-usb-audio.service || fail "systemd-analyze verify microdap system units"
mkdir -p "$tmp/xdg-microdap"
XDG_RUNTIME_DIR=$tmp/xdg-microdap SYSTEMD_LOG_LEVEL=warning systemd-analyze verify --user --man=no \
  /usr/lib/systemd/user/microdap-*.service gamescope-session-plus@microdap.service || fail "systemd-analyze verify --user microdap units"

img=/usr/lib/modules/$kver/initramfs.img
list=$(lsinitrd "$img")
for m in erofs overlay btrfs sdhci-msm ufs-qcom; do
  grep -qE "/$m\.ko" <<< "$list" || grep -qE "/$m\.ko$" "/usr/lib/modules/$kver/modules.builtin" || fail "initramfs lacks $m"
done
dropin=usr/lib/systemd/system/ostree-prepare-root.service.d/10-microos-remap.conf
for f in usr/lib/ostree/ostree-prepare-root usr/libexec/microos/prepare-root usr/bin/sh usr/bin/realpath usr/bin/mkdir "$dropin" \
  usr/bin/plymouthd usr/bin/plymouth etc/plymouth/plymouthd.conf usr/share/plymouth/themes/microos/microos.plymouth \
  usr/share/plymouth/themes/microos/microos.script usr/share/plymouth/themes/microos/wordmark.png \
  usr/share/plymouth/themes/microos/starting.png usr/share/plymouth/themes/microos/updating.png \
  usr/share/plymouth/themes/microos/micro-dap.png usr/share/plymouth/themes/microos/micro-emu.png \
  usr/share/plymouth/themes/microos/steam-os.png; do
  grep -qE " $f( |$)" <<< "$list" || fail "initramfs lacks $f"
done
grep -qE "/plymouth/script\.so( |$)" <<< "$list" || fail "initramfs lacks the plymouth script plugin"
grep -qE "/plymouth/renderers/drm\.so( |$)" <<< "$list" || fail "initramfs lacks the plymouth drm renderer"
! grep -qE "/kernel/drivers/(gpu|pwm|video/backlight)/.*\.ko" <<< "$list" || fail "initramfs has a GPU, PWM or backlight module"
[[ $(lsinitrd -f "$dropin" "$img") == $'[Service]\nExecStart=\nExecStart=/usr/libexec/microos/prepare-root' ]] || fail "remap drop-in content"
lsinitrd -f usr/lib/systemd/system/ostree-prepare-root.service "$img" | grep -qx 'ExecStart=/usr/lib/ostree/ostree-prepare-root /sysroot' \
  || fail "ostree-prepare-root.service ExecStart changed"

[[ -x /usr/bin/microos-update ]] || fail "/usr/bin/microos-update missing"
scripts=()
for f in /usr/libexec/microos/* /usr/lib/microos/* /usr/lib/dracut/modules.d/91microos-ostree-remap/* /usr/bin/microos-*; do
  [[ -f $f ]] && scripts+=("$f")
done
etc=$(grep -n '/etc/' "${scripts[@]}" \
  | grep -vxE '/usr/bin/microos-update:[0-9]+:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/etc/containers/policy\.json' \
  | grep -vE '== /etc/\*' || true)
[[ -z $etc ]] || fail "MicroOS scripts reference /etc: $etc"

chmod 711 "$tmp"
esp=$tmp/esp
mkdir -p "$esp/microos"
printf '[connection]\nid=home\ntype=wifi\n' > "$esp/microos/home.nmconnection"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA test\n' > "$esp/microos/authorized_keys"
printf 'pw:with colon\n' > "$esp/microos/password"
env MICROOS_ESP="$esp" MICROOS_RUNDIR="$tmp/run" MICROOS_NMDIR="$tmp/nm" MICROOS_HOME="$tmp/home" \
  /usr/libexec/microos/microos-provision >/dev/null || fail "provision failed"
[[ -z $(ls -A "$esp/microos") ]] || fail "provision left files on the ESP: $(ls -A "$esp/microos")"
[[ $(stat -c '%a %U' "$tmp/nm/home.nmconnection") == '600 root' ]] || fail "nmconnection mode"
[[ $(stat -c '%a %U' "$tmp/home/.ssh") == '700 micro' ]] || fail ".ssh mode"
[[ $(stat -c '%a %U' "$tmp/home/.ssh/authorized_keys") == '600 micro' ]] || fail "authorized_keys mode"
hash=$(getent shadow micro | cut -d: -f2)
[[ $hash == \$* ]] || fail "micro password not set"
[[ -e $tmp/run/bootimg.lock ]] || fail "provision did not take the bootimg lock"

printf '[connection]\nid=kept\n' > "$esp/microos/kept.nmconnection"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB test\n' > "$esp/microos/authorized_keys"
touch "$tmp/nmfile"
if env MICROOS_ESP="$esp" MICROOS_RUNDIR="$tmp/run" MICROOS_NMDIR="$tmp/nmfile/sub" MICROOS_HOME="$tmp/home" \
  /usr/libexec/microos/microos-provision >/dev/null 2>&1; then
  fail "provision passed with an unwritable connection dir"
fi
[[ -f $esp/microos/kept.nmconnection ]] || fail "failed import removed the file"
[[ ! -e $esp/microos/authorized_keys ]] || fail "authorized_keys not imported next to a failed import"

install -d -m 0755 "$tmp/victim"
for kind in symlink file; do
  rm -rf "$tmp/home2"
  install -d -m 0700 -o micro -g micro "$tmp/home2"
  if [[ $kind == symlink ]]; then
    ln -s "$tmp/victim" "$tmp/home2/.ssh"
  else
    touch "$tmp/home2/.ssh"
  fi
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC test\n' > "$esp/microos/authorized_keys"
  if env MICROOS_ESP="$esp" MICROOS_RUNDIR="$tmp/run" MICROOS_NMDIR="$tmp/nm" MICROOS_HOME="$tmp/home2" \
    /usr/libexec/microos/microos-provision >/dev/null 2>&1; then
    fail "provision passed with a $kind .ssh"
  fi
  [[ -f $esp/microos/authorized_keys ]] || fail "$kind .ssh: authorized_keys removed from the ESP"
done
[[ $(stat -c '%a %U %G' "$tmp/victim") == '755 root root' ]] || fail "symlinked .ssh changed its target"
[[ ! -e $tmp/victim/authorized_keys ]] || fail "symlinked .ssh: key written into the target"
rm -f "$esp/microos/authorized_keys" "$esp/microos/kept.nmconnection"

root=$tmp/initrd
mkdir -p "$root"
(cd "$root" && lsinitrd --unpack "$img")
[[ -x $root/usr/libexec/microos/prepare-root && -x $root/usr/bin/sh ]] || fail "unpacked initramfs lacks the wrapper"

s=$tmp/sysroot
a=$(printf 'a%.0s' {1..64}).0
b=$(printf 'b%.0s' {1..64}).0
ca=$(printf 'c%.0s' {1..64})
cb=$(printf 'd%.0s' {1..64})
mkdir -p "$s/ostree/deploy/default/deploy/$a" "$s/ostree/deploy/default/deploy/$b" "$s/ostree/boot.1.1/default/$ca" \
  "$s/ostree/boot.1.1/default/$cb"
ln -s boot.1.1 "$s/ostree/boot.1"
ln -s "../../../deploy/default/deploy/$a" "$s/ostree/boot.1.1/default/$ca/0"
ln -s "../../../deploy/default/deploy/$b" "$s/ostree/boot.1.1/default/$cb/1"

cat > "$tmp/prep" <<'PREP'
#!/bin/sh
printf '%s\n' "$#" "$@" > "$PREP_OUT"
PREP
chmod 755 "$tmp/prep"

remap() {
  local path=$1 cmdline=$2
  printf '%s\n' "$cmdline" > "$tmp/cmdline"
  rm -rf "$tmp/rrun" "$tmp/out"
  env -i PATH="$path" PREP_OUT="$tmp/out" MICROOS_PREPARE_ROOT="$tmp/prep" MICROOS_SYSROOT="$s" \
    MICROOS_CMDLINE="$tmp/cmdline" MICROOS_RUNDIR="$tmp/rrun" MICROOS_KMSG="$tmp/kmsg" \
    "$root/usr/bin/sh" "$root/usr/libexec/microos/prepare-root"
}
ipath=$root/usr/bin:$root/usr/sbin
base="root=UUID=x rw rootflags=subvol=root,noatime,compress=zstd:1 console=tty0"
expect_unchanged() {
  [[ $(cat "$tmp/out") == "1"$'\n'"$s" ]] || fail "$1: expected unchanged, got $(tr '\n' ' ' < "$tmp/out")"
  [[ ! -e $tmp/rrun/remapped ]] || fail "$1: remapped written"
}
expect_remap() {
  [[ $(cat "$tmp/out") == "2"$'\n'"$s"$'\n'"$2" ]] || fail "$1: got $(tr '\n' ' ' < "$tmp/out")"
  [[ $(cat "$tmp/rrun/remapped") == "$3 $4" ]] || fail "$1: remapped is $(cat "$tmp/rrun/remapped")"
}

good=/ostree/boot.1/default/$ca/0
remap "$ipath" "ostree=$good $base microos.deploy=$a"
expect_unchanged match

remap "$ipath" "ostree=$good $base"
expect_unchanged "no microos.deploy"

stale=/ostree/boot.0/default/$ca/0
remap "$ipath" "ostree=$stale $base microos.deploy=$a"
expect_remap "stale, one match" "ostree=$good $base microos.deploy=$a" "$stale" "$good"

remap "$ipath" "ostree=/ostree/boot.1/default/$cb/1 $base microos.deploy=$a"
expect_remap "link names another deployment" "ostree=$good $base microos.deploy=$a" "/ostree/boot.1/default/$cb/1" "$good"

remap "$ipath" "ostree=$stale $base microos.deploy=$(printf 'e%.0s' {1..64}).0"
expect_unchanged "stale, no match"

mkdir -p "$s/ostree/boot.0.1/default/$ca"
ln -s boot.0.1 "$s/ostree/boot.0"
ln -s "../../../deploy/default/deploy/$a" "$s/ostree/boot.0.1/default/$ca/0"
remap "$ipath" "ostree=/ostree/boot.1/default/$cb/1 $base microos.deploy=$a"
[[ $(sed -n 1p "$tmp/out") == 2 ]] || fail "same dir via both boot.N: not remapped"
grep -qE "^ostree=/ostree/boot\.[01]/default/$ca/0 " <(sed -n 3p "$tmp/out") || fail "same dir via both boot.N: wrong link"

mkdir -p "$s/ostree/deploy/other/deploy/$a" "$s/ostree/boot.1.1/other/$ca"
ln -s "../../../deploy/other/deploy/$a" "$s/ostree/boot.1.1/other/$ca/0"
remap "$ipath" "ostree=/ostree/boot.1/default/$cb/1 $base microos.deploy=$a"
expect_unchanged "two different dirs"
rm -rf "$s/ostree/boot.1.1/other" "$s/ostree/deploy/other"

mkdir -p "$tmp/broken"
cp -a "$root/usr/bin/." "$tmp/broken/"
printf '#!/bin/sh\nexit 1\n' > "$tmp/broken/realpath"
chmod 755 "$tmp/broken/realpath"
remap "$tmp/broken:$root/usr/sbin" "ostree=$stale $base microos.deploy=$a"
expect_unchanged "broken realpath"
printf '#!/bin/sh\necho\n' > "$tmp/broken/realpath"
remap "$tmp/broken:$root/usr/sbin" "ostree=$stale $base microos.deploy=$a"
expect_unchanged "empty realpath"

echo "image: ok ($kver)"
