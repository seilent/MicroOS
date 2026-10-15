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
[[ $(rpm -q --qf '%{VENDOR}' inputplumber) == MicroOS ]] || fail "inputplumber is not the MicroOS build"
[[ -z $(rpm -qa '*-debuginfo' '*-debugsource') ]] || fail "debug rpms installed: $(rpm -qa '*-debuginfo' '*-debugsource' | tr '\n' ' ')"
[[ $(systemctl is-enabled inputplumber.service) == enabled ]] || fail "inputplumber.service is not enabled"

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
for r in 'RUN+="/usr/bin/chgrp wheel /sys%p/brightness"' 'RUN+="/usr/bin/chmod g+w /sys%p/brightness"'; do
  grep -qF "$r" /usr/lib/udev/rules.d/60-microos-backlight.rules || fail "60-microos-backlight.rules lacks $r"
done
grep -qE 'session\.dont-restore-off-profile"? *[=:] *true' /usr/share/wireplumber/wireplumber.conf.d/52-microos-pm2.conf \
  || fail "52-microos-pm2.conf does not set session.dont-restore-off-profile"
grep -qE 'api\.alsa\.soft-mixer"? *[=:] *true' /usr/share/wireplumber/wireplumber.conf.d/50-microos-soft-mixer.conf \
  || fail "50-microos-soft-mixer.conf does not set api.alsa.soft-mixer"

rpm -q python3-gobject python3-evdev upower >/dev/null || fail "steam service rpms missing"
[[ $(rpm -q --qf '%{VENDOR}' steamos-manager) == MicroOS ]] || fail "steamos-manager is not the MicroOS build"
! rpm -q iwd >/dev/null 2>&1 || fail "iwd is installed"
for u in steamos-manager.service upower.service microos-powerd.service microos-vpower.service microsetd.service; do
  [[ $(systemctl is-enabled "$u") == enabled ]] || fail "$u is not enabled"
done
for u in steamos-manager.service microos-audio-sleep.service microos-audio.service; do
  [[ $(systemctl --global is-enabled "$u") == enabled ]] || fail "user $u is not enabled"
done
[[ $(systemctl --global is-enabled steamos-manager-session-cleanup.service) != enabled ]] \
  || fail "user steamos-manager-session-cleanup.service is enabled"
[[ -f /usr/share/steamos-manager/devices/microos-pm2.toml ]] || fail "microos-pm2.toml missing"
for f in /usr/lib/hwsupport/format-device.sh /usr/lib/hwsupport/trim-devices.sh /usr/lib/hwsupport/format-sdcard.sh \
  /usr/bin/steamos-polkit-helpers/steamos-format-device /usr/bin/steamos-polkit-helpers/steamos-format-sdcard \
  /usr/bin/steamos-polkit-helpers/steamos-trim-devices /usr/libexec/microos/microos-storage; do
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
rpm -q f3 udisks2 exfatprogs dosfstools e2fsprogs >/dev/null || fail "storage rpms missing"
for c in f3probe pkexec wipefs sfdisk mkfs.ext4 mkfs.exfat fsck.ext4 fstrim flock jq busctl blkid findmnt; do
  command -v "$c" >/dev/null || fail "$c is not on PATH"
done
[[ -x /usr/libexec/microos/microos-powerd ]] || fail "microos-powerd missing"
[[ -x /usr/libexec/microos/microos-vpower ]] || fail "microos-vpower missing"
! grep -qE 'pwm|hwmon|thermal' /usr/libexec/microos/microos-powerd || fail "microos-powerd names a pwm, hwmon or thermal path"
[[ $(rpm -q --qf '%{VENDOR}' microset) == MicroOS ]] || fail "microset is not the MicroOS build"
! rpm -q microset-devel >/dev/null 2>&1 || fail "microset-devel is installed"
schema=/usr/share/microset/schema.d/10-microset.json
enum() { jq -er --arg k "$1" '.keys[$k].enum | sort | join(" ")' "$schema" || fail "$schema has no enum for $1"; }
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
rpm -q sddm sddm-wayland-generic steam-devices gtk2 openal-soft sdl2-compat libXcomposite libXdamage libXfixes libXi \
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
while read -r u p; do
  [[ $p == -* ]] && continue
  grep -qE "^d $p [0-7]+ " /usr/lib/tmpfiles.d/*.conf || fail "${u##*/} ReadWritePaths=$p has no tmpfiles line"
done < <(awk -F= '/^ReadWritePaths=/ { n = split($2, a, " "); for (i = 1; i <= n; i++) print FILENAME, a[i] }' \
  /usr/lib/systemd/system/microos-*)
leak=$(find / -xdev \( -path '*/qcom/sm8250/ayaneo/*' -o -type d \( -name slpi -o -name hexagonfs \) \
  -o -name slpi.mdt -o -name 'slpi.b[0-9][0-9]' \) -print -quit 2>/dev/null || true)
[[ -z $leak ]] || fail "SLPI firmware or HexagonFS tree in the image: $leak"
SYSTEMD_LOG_LEVEL=warning systemd-analyze verify --man=no "${units[@]}" /usr/lib/systemd/system/steamos-manager.service \
  /usr/lib/systemd/system/sshd.service /usr/lib/systemd/system/bootc-generic-growpart.service \
  /usr/lib/systemd/system/ostree-finalize-staged.service || fail "systemd-analyze verify"
mkdir -p "$tmp/xdg"
XDG_RUNTIME_DIR=$tmp/xdg SYSTEMD_LOG_LEVEL=warning systemd-analyze verify --user --man=no \
  /usr/lib/systemd/user/microos-*.service /usr/lib/systemd/user/steamos-manager.service gamescope-session-plus@steam.service \
  || fail "systemd-analyze verify --user"
[[ -f /usr/lib/systemd/user/microos-steam-seed.service ]] || fail "microos-steam-seed.service missing"
[[ $(< /usr/lib/systemd/user/gamescope-session-plus@.service.d/20-microos-hotkeyd.conf) == $'[Unit]\nWants=microos-hotkeyd@%i.service' ]] \
  || fail "hotkeyd drop-in"
[[ -e /usr/lib/systemd/user/microos-hotkeyd.service || -e /usr/lib/systemd/user/gamescope-session-plus@steam.service.d/20-microos-hotkeyd.conf ]] \
  && fail "Steam only hotkeyd unit or drop-in present"
grep -qx 'ExecStart=/usr/libexec/microos/microos-hotkeyd %i' /usr/lib/systemd/user/microos-hotkeyd@.service || fail "hotkeyd unit ExecStart"
grep -qx 'BindsTo=gamescope-session-plus@%i.service' /usr/lib/systemd/user/microos-hotkeyd@.service || fail "hotkeyd unit BindsTo"
grep -qx 'After=gamescope-session-plus@%i.service' /usr/lib/systemd/user/microos-hotkeyd@.service || fail "hotkeyd unit After"
[[ -f /usr/lib/microos/hotkeys.d/steam.conf && -f /usr/lib/microos/hotkeys.d/recovery.conf ]] || fail "hotkeys.d tables missing"
[[ -f /usr/lib/systemd/user/gamescope-session-plus@steam.service.d/10-microos.conf ]] || fail "gamescope-session-plus@steam drop-in missing"

[[ $(grep '^ExecStop=' /usr/lib/systemd/system/ostree-finalize-staged.service) == 'ExecStop=/usr/bin/ostree admin finalize-staged' ]] \
  || fail "ostree-finalize-staged.service ExecStop changed"
stops=$(systemctl cat ostree-finalize-staged.service \
  | awk '/^ExecStop=/ { sub(/^ExecStop=/, ""); if ($0 == "") n = 0; else l[++n] = $0 } END { for (i = 1; i <= n; i++) print l[i] }') \
  || fail "systemctl cat ostree-finalize-staged.service"
[[ $stops == '/usr/libexec/microos/microos-bootlog run finalize-staged -- /usr/bin/ostree admin finalize-staged'$'\n''-/usr/libexec/microos/microos-bootlog run finalize -- /usr/libexec/microos/microos-bootimg-update' ]] \
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
microset=$(getent passwd microset) || fail "user microset missing"
(( $(cut -d: -f3 <<< "$microset") < 1000 )) || fail "microset is not a system user"
[[ $(cut -d: -f7 <<< "$microset") == */nologin ]] || fail "microset has a login shell"
hexgid=$(getent group hexagonrpc | cut -d: -f3) || fail "group hexagonrpc missing"
(( hexgid < 1000 )) || fail "hexagonrpc is not a system group"
rules=$(sudo -l -U micro)
grep -q '(ALL) ALL' <<< "$rules" || fail "micro has no wheel sudo rule"
! grep -q NOPASSWD <<< "$rules" || fail "micro has a NOPASSWD rule"

img=/usr/lib/modules/$kver/initramfs.img
list=$(lsinitrd "$img")
for m in erofs overlay btrfs sdhci-msm ufs-qcom; do
  grep -qE "/$m\.ko" <<< "$list" || grep -qE "/$m\.ko$" "/usr/lib/modules/$kver/modules.builtin" || fail "initramfs lacks $m"
done
dropin=usr/lib/systemd/system/ostree-prepare-root.service.d/10-microos-remap.conf
for f in usr/lib/ostree/ostree-prepare-root usr/libexec/microos/prepare-root usr/bin/sh usr/bin/realpath usr/bin/mkdir "$dropin"; do
  grep -qE " $f( |$)" <<< "$list" || fail "initramfs lacks $f"
done
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
