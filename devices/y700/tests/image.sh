#!/usr/bin/env bash
set -euo pipefail

fail() { echo "image: $*" >&2; exit 1; }
usage="usage: MICROOS_IMAGE=<device image> MICROOS_DEVICE=<device> MICROOS_REPO=<checkout> image.sh"
image=${MICROOS_IMAGE:?$usage}
dev=${MICROOS_DEVICE:?$usage}
repo=${MICROOS_REPO:?$usage}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mods=(/usr/lib/modules/*)
[[ ${#mods[@]} -eq 1 && -d ${mods[0]} ]] || fail "expected one modules dir, found ${mods[*]}"
kver=${mods[0]##*/}
rpm -q microos-kernel >/dev/null || fail "microos-kernel not installed"
[[ -z $(rpm -qa 'kernel*') ]] || fail "Fedora kernel rpms left: $(rpm -qa 'kernel*' | tr '\n' ' ')"
[[ -z $(rpm -qa 'fedora-release*') ]] || fail "fedora-release rpms left"
rpm -q generic-release generic-logos >/dev/null || fail "generic-release or generic-logos missing"

for kv in ID=microos NAME=MicroOS ID_LIKE=fedora VERSION_ID=44 DEFAULT_HOSTNAME=microos \
  HOME_URL=https://github.com/seilent/microos-y700; do
  grep -qx "$kv" /usr/lib/os-release || fail "os-release lacks $kv"
done
grep -qx "$(cat /usr/lib/microos/version)" /usr/lib/os-release || fail "version file and os-release differ"
[[ $(readlink /etc/os-release) == ../usr/lib/os-release ]] || fail "/etc/os-release is not the relative symlink"

rpm -q android-tools btrfs-progs dosfstools jq util-linux rsync dnsmasq python3 >/dev/null || fail "base rpms missing"
rpm -q bluez e2fsprogs >/dev/null || fail "bluez or e2fsprogs missing"
rpm -q libcamera libcamera-ipa libcamera-tools libcamera-qcam >/dev/null || fail "libcamera rpms missing"
[[ -f /usr/share/applications/qcam.desktop ]] || fail "qcam.desktop missing"
rpm -q python3-gobject-base >/dev/null || fail "python3-gobject-base missing"
python3 -c 'import gi; gi.require_version("Gio", "2.0"); from gi.repository import Gio, GLib' || fail "python3 gi has no Gio"
rpm -q chrony NetworkManager-wifi wpa_supplicant wireless-regdb atheros-firmware qcom-firmware linux-firmware mesa-dri-drivers \
  mesa-vulkan-drivers mesa-libgbm mesa-libEGL mesa-libGL vulkan-loader vulkan-tools sddm sddm-wayland-generic steam-devices \
  dbus-tools gtk2 gtk3 openal-soft sdl2-compat libXcomposite libXdamage libXfixes libXi libXinerama libXrandr libXrender \
  libXtst libSM libICE at-spi2-atk cups-libs libssh2 libva libvdpau google-noto-sans-cjk-vf-fonts \
  google-noto-color-emoji-fonts google-noto-sans-arabic-vf-fonts google-noto-sans-hebrew-vf-fonts \
  google-noto-sans-thai-vf-fonts google-noto-sans-devanagari-vf-fonts google-noto-sans-mono-vf-fonts upower procps-ng \
  zstd pipewire pipewire-pulseaudio pipewire-alsa wireplumber alsa-ucm >/dev/null || fail "Steam path rpms missing"
for c in mkbootimg unpack_bootimg avbtool skopeo jq flock python3 btrfs mkfs.vfat rsync dnsmasq sshd NetworkManager sudo \
  chronyd wpa_supplicant gamescope gamescope-session-plus vulkaninfo pgrep zstd start-hyprland; do
  command -v "$c" >/dev/null || fail "$c missing"
done
[[ $(rpm -qf "$(command -v hyprland-dialog)" 2>/dev/null) == hyprland-guiutils-* ]] || fail "hyprland-dialog is not on PATH from hyprland-guiutils"
grep -qx 'install_weak_deps=False' /etc/dnf/libdnf5.conf.d/10-microos.conf || fail "10-microos.conf does not turn off weak deps"
[[ -z $(rpm -qa '*-debuginfo' '*-debugsource') ]] || fail "debug rpms installed: $(rpm -qa '*-debuginfo' '*-debugsource' | tr '\n' ' ')"
own=$(rpm -qa --qf '%{NAME}\t%{VENDOR}\n' | awk -F'\t' '$2 == "MicroOS" { print $1 }' | LC_ALL=C sort | paste -sd' ')
[[ $own == 'aquamarine audioreach-topology gamescope gamescope-session gamescope-session-steam hexagonrpc hyprcursor hyprgraphics hyprgrass hyprland hyprland-guiutils hyprlang hyprpicker hyprsunset hyprtoolkit hyprutils hyprwire microos-android microos-android-guest-apks microos-android-guestos microos-fonts microos-kernel microset microset-fonts microset-settings xdg-desktop-portal-hyprland' ]] ||
  fail "MicroOS rpms: $own"
for p in qbootctl inputplumber steamos-manager mangohud lsfg-vk microos-eq libfreeaptx \
  pipewire-codec-aptx microos-steam-seed; do
  ! rpm -q "$p" >/dev/null 2>&1 || fail "$p is installed"
done

for u in bootloader-update.service systemd-repart.service systemd-backlight@.service systemd-hibernate.service systemd-hybrid-sleep.service \
  systemd-suspend-then-hibernate.service bootc-fetch-apply-updates.timer bootc-generic-growpart.service; do
  [[ $(readlink "/etc/systemd/system/$u") == /dev/null ]] || fail "$u is not masked"
done
[[ -z $(compgen -G '/usr/lib/repart.d/*') ]] || fail "repart.d holds definitions: $(ls /usr/lib/repart.d)"
[[ $(readlink /etc/systemd/user/mpris-proxy.service) == /dev/null ]] || fail "user mpris-proxy.service is not masked"

tests=(microos-test-bootloader.service microos-test-emergency.service microos-test-gptdump.service microos-test-panic.service
  microos-test-wdhang.service)
want=$(printf '%s\n' microos-boot-ok.service microos-provision.service microos-update-applied.service microos-update.service \
  microos-update-check.service microos-update-check.timer microos-boot-deadline.service microos-boot-deadline.timer \
  microos-bootlog-efi.path microos-bootlog-efi.service microos-grow-root.service microos-usb-console.service microos-vpad.service \
  microos-remoteproc.service microos-groups.service microos-etc-carry.service microos-update-boot.path \
  microos-update-boot.service microos-bdaddr@.service microos-sleep-gate.service microos-adsp-sensors.service \
  microos-hexagonrpcd-adsp.service microos-session-switch@.service \
  microos-session-up@.service microos-session-fallback@.service microos-session-switcher.service \
  microos-session-switcher.path microos-session-boot.service microos-session-watch.service microos-session-attempt.service \
  "${tests[@]}")
units=()
for u in /usr/lib/systemd/system/microos-*; do
  [[ -f $u ]] && units+=("$u")
done
got=$(printf '%s\n' "${units[@]##*/}" | LC_ALL=C sort)
[[ $got == "$(LC_ALL=C sort <<< "$want")" ]] || fail "MicroOS units: $(tr '\n' ' ' <<< "$got")"
for u in microos-boot-ok.service microos-provision.service microos-update-applied.service microos-boot-deadline.timer \
  microos-bootlog-efi.path microos-grow-root.service microos-usb-console.service microos-vpad.service microos-remoteproc.service \
  microos-groups.service microos-etc-carry.service microos-update-check.timer microos-update-boot.path microos-sleep-gate.service \
  microos-session-boot.service microos-session-attempt.service microos-session-switcher.path microos-session-watch.service \
  microsetd.service "${tests[@]}"; do
  [[ $(systemctl is-enabled "$u") == enabled ]] || fail "$u is not enabled"
done
for u in microos-groups.service microos-etc-carry.service; do
  [[ -L /etc/systemd/system/sysinit.target.wants/$u ]] || fail "$u is not wanted by sysinit.target"
done
systemctl cat microos-etc-carry.service | grep -qx 'After=local-fs.target systemd-sysusers.service microos-groups.service' ||
  fail "microos-etc-carry.service is not ordered after sysusers"
systemctl cat microos-groups.service | grep -qx 'Before=systemd-sysusers.service systemd-update-done.service sysinit.target shutdown.target' ||
  fail "microos-groups.service is not ordered before systemd-sysusers.service"
[[ -L /etc/systemd/system/multi-user.target.wants/microos-bootlog-efi.path ]] || fail "microos-bootlog-efi.path is not wanted by multi-user.target"
[[ $(systemctl is-enabled microos-bootlog-efi.service) == static ]] || fail "microos-bootlog-efi.service is not static"
[[ $(systemctl is-enabled microos-bdaddr@.service) == static ]] || fail "microos-bdaddr@.service is not static"
for u in "${tests[@]}"; do
  w=${u#microos-test-}
  systemctl cat "$u" | grep -qx "ConditionKernelCommandLine=microos.test=${w%.service}" || fail "$u has no microos.test condition"
done
[[ -L /etc/systemd/system/multi-user.target.wants/microos-update-boot.path ]] || fail "microos-update-boot.path is not wanted by multi-user.target"
[[ $(systemctl is-enabled microos-update-boot.service) == static ]] || fail "microos-update-boot.service is not static"
systemctl cat microos-update-check.service | grep -qx 'ExecStart=/usr/bin/microos-update --auto' || fail "microos-update-check.service does not run --auto"
for c in zstd cpio systemd-run systemd-inhibit; do
  command -v "$c" > /dev/null || fail "$c missing, microos-update --auto needs it"
done
[[ ! -e /usr/lib/systemd/user-preset/50-microos.preset ]] || fail "user 50-microos.preset in the image"
for u in pipewire.socket pipewire-pulse.socket wireplumber.service microos-android-status.service; do
  [[ $(systemctl --global is-enabled "$u") == enabled ]] || fail "user $u is not enabled"
done
null=/usr/share/pipewire/pipewire.conf.d/90-microos-null-sink.conf
grep -qF 'factory.name = support.null-audio-sink' "$null" && grep -qF 'priority.session = 1' "$null" || fail "$null"
[[ $(compgen -G '/usr/lib/systemd/user/microos-*' | LC_ALL=C sort) == $'/usr/lib/systemd/user/microos-android-battery.service\n/usr/lib/systemd/user/microos-android-gapps-setup.service\n/usr/lib/systemd/user/microos-android-gapps.service\n/usr/lib/systemd/user/microos-android-status.service\n/usr/lib/systemd/user/microos-android.service\n/usr/lib/systemd/user/microos-desktop.service\n/usr/lib/systemd/user/microos-desktop.service.d\n/usr/lib/systemd/user/microos-gameidle.service\n/usr/lib/systemd/user/microos-ii-seed.service\n/usr/lib/systemd/user/microos-lepton-prepare.service\n/usr/lib/systemd/user/microos-powerkey.service\n/usr/lib/systemd/user/microos-powerkey.service.d\n/usr/lib/systemd/user/microos-session-alive-desktop.timer\n/usr/lib/systemd/user/microos-session-alive@.service\n/usr/lib/systemd/user/microos-session-alive@.timer\n/usr/lib/systemd/user/microos-session-install@.service\n/usr/lib/systemd/user/microos-steam-seed.service\n/usr/lib/systemd/user/microos-ydotoold.service' ]] \
  || fail "MicroOS user units: $(compgen -G '/usr/lib/systemd/user/microos-*' | tr '\n' ' ')"
[[ $(< /usr/lib/systemd/system-preset/50-microos.preset) == 'enable microos-*' ]] || fail "50-microos.preset"

kept=(
  /etc/containers/policy.json
  /etc/containers/registries.d/ghcr-microos.yaml
  /etc/selinux/targeted/active/modules/400/microos/cil
  /etc/selinux/targeted/active/modules/400/microos/lang_ext
  /etc/ssh/sshd_config.d/10-microos.conf
  /usr/bin/microos-session
  /usr/bin/microos-update
  /usr/lib/NetworkManager/conf.d/10-microos.conf
  /usr/lib/bootc/install/00-microos.toml
  /usr/lib/bootc/kargs.d/10-microos.toml
  /usr/lib/udev/rules.d/60-microos-backlight.rules
  /usr/lib/udev/rules.d/60-microos-y700-pcie-wakeup.rules
  /usr/lib/udev/rules.d/60-microos-y700-touch.rules
  /usr/lib/systemd/user-preset/60-microos-android.preset
  /usr/lib/systemd/user-preset/60-microos-audio.preset
  /usr/share/pipewire/pipewire.conf.d/90-microos-null-sink.conf
  /usr/lib/dracut/dracut.conf.d/90-microos.conf
  /usr/lib/dracut/modules.d/91microos-ostree-remap/module-setup.sh
  /usr/lib/dracut/modules.d/91microos-ostree-remap/prepare-root.conf
  /usr/lib/dracut/modules.d/92microos-y700-guard/cmdline.conf
  /usr/lib/dracut/modules.d/92microos-y700-guard/efi-device.conf
  /usr/lib/dracut/modules.d/92microos-y700-guard/emergency.conf
  /usr/lib/dracut/modules.d/92microos-y700-guard/microos-guard
  /usr/lib/dracut/modules.d/92microos-y700-guard/microos-guard.service
  /usr/lib/dracut/modules.d/92microos-y700-guard/microos-initrd-log
  /usr/lib/dracut/modules.d/92microos-y700-guard/module-setup.sh
  /usr/lib/dracut/modules.d/92microos-y700-guard/switch-root.conf
  /usr/lib/dracut/modules.d/93microos-y700-usbcon/microos-initrd-usbcon
  /usr/lib/dracut/modules.d/93microos-y700-usbcon/microos-initrd-usbcon.service
  /usr/lib/dracut/modules.d/93microos-y700-usbcon/module-setup.sh
  /usr/lib/dracut/modules.d/94microos-selinux-label/microos-selinux-label
  /usr/lib/dracut/modules.d/94microos-selinux-label/microos-selinux-label-etc.service
  /usr/lib/dracut/modules.d/94microos-selinux-label/microos-selinux-label-var.service
  /usr/lib/dracut/modules.d/94microos-selinux-label/module-setup.sh
  /usr/lib/microos/boot-ok.conf
  /usr/lib/microos/bootimg.conf
  /usr/lib/microos/sessions.d/steam.conf
  /usr/lib/microos/slot.conf
  /usr/lib/microos/stub.conf
  /usr/lib/microos/stub/stub-preset-free.bin
  /usr/lib/microos/stub/stub-preset-free.conf
  /usr/lib/microos/version
  /usr/lib/modules-load.d/microos-y700.conf
  /usr/lib/sddm/sddm.conf.d/zz-microos.conf
  /usr/lib/sysctl.d/60-microos-yama.conf
  /usr/lib/systemd/journald.conf.d/10-microos.conf
  /usr/lib/systemd/logind.conf.d/50-microos.conf
  /usr/lib/systemd/sleep.conf.d/50-microos.conf
  /usr/lib/systemd/system.conf.d/50-microos.conf
  /usr/lib/systemd/system-preset/50-microos.preset
  /usr/lib/systemd/system-preset/60-microos-microset.preset
  /usr/lib/systemd/system-preset/60-microos-steam.preset
  /usr/lib/systemd/system-preset/60-microos-waydroid.preset
  /usr/lib/systemd/system/dev-binderfs.mount
  /usr/lib/systemd/system/emergency.service.d/10-microos.conf
  /usr/lib/systemd/system/microos-adsp-sensors.service
  /usr/lib/systemd/system/microos-bdaddr@.service
  /usr/lib/systemd/system/microos-boot-deadline.service
  /usr/lib/systemd/system/microos-boot-deadline.timer
  /usr/lib/systemd/system/microos-boot-ok.service
  /usr/lib/systemd/system/microos-bootlog-efi.path
  /usr/lib/systemd/system/microos-bootlog-efi.service
  /usr/lib/systemd/system/microos-grow-root.service
  /usr/lib/systemd/system/microos-etc-carry.service
  /usr/lib/systemd/system/microos-groups.service
  /usr/lib/systemd/system/microos-hexagonrpcd-adsp.service
  /usr/lib/systemd/system/microos-provision.service
  /usr/lib/systemd/system/microos-session-attempt.service
  /usr/lib/systemd/system/microos-session-boot.service
  /usr/lib/systemd/system/microos-session-fallback@.service
  /usr/lib/systemd/system/microos-session-switch@.service
  /usr/lib/systemd/system/microos-session-switcher.path
  /usr/lib/systemd/system/microos-session-switcher.service
  /usr/lib/systemd/system/microos-session-up@.service
  /usr/lib/systemd/system/microos-session-watch.service
  /usr/lib/systemd/system/microos-update-applied.service
  /usr/lib/systemd/system/microos-update-boot.path
  /usr/lib/systemd/system/microos-update-boot.service
  /usr/lib/systemd/system/microos-update-check.service
  /usr/lib/systemd/system/microos-update-check.timer
  /usr/lib/systemd/system/microos-test-bootloader.service
  /usr/lib/systemd/system/microos-test-emergency.service
  /usr/lib/systemd/system/microos-test-gptdump.service
  /usr/lib/systemd/system/microos-test-panic.service
  /usr/lib/systemd/system/microos-test-wdhang.service
  /usr/lib/systemd/system/microos-update.service
  /usr/lib/systemd/system/microos-usb-console.service
  /usr/lib/systemd/system/microos-vpad.service
  /usr/lib/systemd/system/microos-remoteproc.service
  /usr/lib/systemd/system/microos-sleep-gate.service
  /usr/lib/systemd/system/microos-vpad.service.d/50-microos-microset.conf
  /usr/lib/systemd/system/microsetd.service.d/50-microos-y700.conf
  /usr/lib/systemd/system/serial-getty@ttyGS0.service.d/10-microos.conf
  /usr/lib/systemd/system/sshd.service.d/10-microos.conf
  /usr/lib/systemd/system-sleep/microos-hexagonrpcd-adsp
  /usr/lib/systemd/system-sleep/microos-sleep-log
  /usr/lib/systemd/system-sleep/microos-wake-reason
  /usr/lib/systemd/user/gamescope-session-plus@.service.d/10-microos-track.conf
  /usr/lib/systemd/user/gamescope-session-plus@android.service.d/20-microos-powerkey.conf
  /usr/lib/systemd/user/gamescope-session-plus@steam.service.d/10-microos.conf
  /usr/lib/systemd/user/gamescope-session-plus@steam.service.d/20-microos-powerkey.conf
  /usr/lib/systemd/user/gamescope-session-plus@steam.service.d/30-microos-gameidle.conf
  /usr/lib/systemd/user/microos-gameidle.service
  /usr/lib/systemd/user/microos-powerkey.service
  /usr/lib/systemd/user/microos-powerkey.service.d/50-microos-microset.conf
  /usr/lib/systemd/user/microos-session-alive@.service
  /usr/lib/systemd/user/microos-session-alive@.timer
  /usr/lib/systemd/user/microos-session-install@.service
  /usr/lib/systemd/user/microos-steam-seed.service
  /usr/lib/microos/sessions.d/desktop.conf
  /usr/lib/microos/sessions.d/android.conf
  /usr/lib/microos/sessions.d/waydroid.conf
  /usr/lib/systemd/user/microos-desktop.service.d/10-microos-track.conf
  /usr/lib/systemd/user/microos-desktop.service.d/20-microos-ii-seed.conf
  /usr/lib/systemd/user/microos-desktop.service.d/30-hypr-config.conf
  /usr/lib/systemd/user/microos-desktop.service.d/40-microos-powerkey.conf
  /usr/lib/systemd/user/microos-desktop.service.d/50-microos-ydotoold.conf
  /usr/lib/systemd/user/microos-ii-seed.service
  /usr/lib/systemd/user/microos-ydotoold.service
  /usr/lib/systemd/user/microos-session-alive-desktop.timer
  /usr/lib/systemd/user/xdg-desktop-portal.service.d/50-microos-desktop.conf
  /etc/dnf/libdnf5.conf.d/20-microos-hyprland.conf
  /usr/lib/systemd/user/microos-desktop.service
  /usr/libexec/microos/microos-desktop-env
  /usr/libexec/microos/microos-desktop-session
  /usr/libexec/microos/microos-hyprland
  /usr/libexec/microos/microos-ii-seed
  /usr/share/wayland-sessions/microos-desktop.desktop
  /usr/share/wayland-sessions/microos-waydroid-probe.desktop
  /usr/lib/sysusers.d/microos-hexagonrpc.conf
  /usr/lib/sysusers.d/microos.conf
  /usr/lib/tmpfiles.d/microos-session.conf
  /usr/lib/tmpfiles.d/microos.conf
  /usr/lib/tmpfiles.d/microos-waydroid.conf
  /usr/lib/udev/rules.d/70-microos-adsp-sensors.rules
  /usr/lib/udev/rules.d/90-microos-usb-console.rules
  /usr/lib/udev/rules.d/91-microos-y700-bdaddr.rules
  /usr/libexec/microos/microos-adsp-sensors
  /usr/libexec/microos/microos-bdaddr
  /usr/libexec/microos/microos-boot-ok
  /usr/libexec/microos/microos-bootb
  /usr/libexec/microos/microos-bootimg-build
  /usr/libexec/microos/microos-bootimg-update
  /usr/libexec/microos/microos-bootlog
  /usr/libexec/microos/microos-efi-log
  /usr/libexec/microos/microos-etc-carry
  /usr/libexec/microos/microos-fail
  /usr/libexec/microos/microos-gameidle
  /usr/libexec/microos/microos-grow-root
  /usr/libexec/microos/microos-groups
  /usr/libexec/microos/microos-irq
  /usr/libexec/microos/microos-lp-extent
  /usr/libexec/microos/microos-powerkey
  /usr/libexec/microos/microos-provision
  /usr/libexec/microos/microos-sdam
  /usr/libexec/microos/microos-session-boot
  /usr/libexec/microos/microos-session-track
  /usr/libexec/microos/microos-session-watch
  /usr/libexec/microos/microos-sleep-gate
  /usr/libexec/microos/microos-slot
  /usr/libexec/microos/microos-steam-seed
  /usr/libexec/microos/microos-stub
  /usr/libexec/microos/microos-stub-pack
  /usr/libexec/microos/microos-test
  /usr/libexec/microos/microos-update-applied
  /usr/libexec/microos/microos-usb-console
  /usr/libexec/microos/microos-vpad
  /usr/libexec/microos/microos-remoteproc
  /usr/libexec/microos/prepare-root
  /usr/libexec/microos/wd-session
  /usr/libexec/microos/wd-stop
  /usr/share/microos/avb/testkey_rsa4096.pem
  /usr/share/microos/keys/microos-backup.pub
  /usr/share/microos/keys/microos-next.pub
  /usr/share/microos/keys/microos.pub
  /usr/share/microos-android/display
  /usr/share/licenses/microos-steam-seed/steam_subscriber_agreement.txt
  /usr/share/microos-seed/steam-seed.tar.zst
  /usr/share/microos-seed/steam-seed.version
  /usr/share/polkit-1/rules.d/50-microos-session.rules
  /usr/share/polkit-1/rules.d/50-microos-steam.rules
  /usr/share/polkit-1/rules.d/50-microos-timezone.rules
  /usr/share/selinux/packages/microos.cil
)
for f in "${kept[@]}"; do
  [[ -f $f ]] || fail "$f missing"
done
ours=()
while IFS= read -r f; do
  rpm -qf "$f" >/dev/null 2>&1 || ours+=("$f")
done < <(find /usr /etc -xdev -path /usr/lib/modules -prune -o -path /usr/share/microos/quickshell -prune -o \
  -path /usr/share/microos/matugen -prune -o -path /usr/share/microos/hypr -prune -o -path '*microos*' -type f -print \
  | grep -vxF /etc/dnf/libdnf5.conf.d/10-microos.conf | LC_ALL=C sort)
extra=$(LC_ALL=C comm -23 <(printf '%s\n' "${ours[@]}") <(printf '%s\n' "${kept[@]}" | LC_ALL=C sort))
[[ -z $extra ]] || fail "MicroOS files outside the M2 set: $(tr '\n' ' ' <<< "$extra")"
[[ -f /usr/share/microos/quickshell/ii/shell.qml && -d /usr/share/microos/matugen \
  && -f /usr/share/microos/hypr/hyprland.lua ]] || fail "ii shell, matugen, or hypr tree not shipped"
for f in /usr/lib/hwsupport /usr/share/inputplumber /usr/share/steamos-manager \
  /usr/share/gamescope-session-plus/sessions.d/recovery /usr/libexec/microos/microos-steam-compat \
  /usr/libexec/microos/microos-pad-lib /usr/share/plymouth/themes/microos \
  /usr/lib/udev/rules.d/59-microos-y700-input.rules; do
  [[ ! -e $f ]] || fail "$f is in the image"
done
ucm=$(compgen -G '/usr/share/alsa/ucm2/*/sm8250/PocketMICRO2*' || true)
grep -qxF '	File "/Qualcomm/sm8650/TB321FU/HiFi.conf"' /usr/share/alsa/ucm2/conf.d/sm8650/Lenovo-Y700-TB321FU.conf \
  || fail "TB321FU UCM card file"
grep -qF "cset \"name='SEC_TDM_RX_0 Audio Mixer MultiMedia2' 1\"" /usr/share/alsa/ucm2/Qualcomm/sm8650/TB321FU/HiFi.conf \
  || fail "TB321FU UCM speaker route"
grep -qF "cset \"name='SpkrRight Playback Switch' 1\"" /usr/share/alsa/ucm2/Qualcomm/sm8650/TB321FU/HiFi.conf \
  || fail "TB321FU UCM speaker amplifier controls"
grep -qF "cset \"name='RX_CODEC_DMA_RX_0 Audio Mixer MultiMedia1' 1\"" /usr/share/alsa/ucm2/Qualcomm/sm8650/TB321FU/HiFi.conf \
  || fail "TB321FU UCM headphone route"
for f in $(sed -n 's/^[[:space:]]*Include\.[a-z-]*\.File "\(.*\)"$/\1/p' /usr/share/alsa/ucm2/conf.d/sm8650/Lenovo-Y700-TB321FU.conf \
  /usr/share/alsa/ucm2/Qualcomm/sm8650/TB321FU/HiFi.conf); do
  [[ -f /usr/share/alsa/ucm2$f ]] || fail "TB321FU UCM includes missing $f"
done
[[ $(rpm -qf /usr/lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin 2>/dev/null) == audioreach-topology-* ]] \
  || fail "TB321FU topology is not from audioreach-topology"
[[ -z $ucm ]] || fail "PM2 UCM files in the image: $ucm"
for f in /etc/subuid /etc/subgid; do
  [[ $(< "$f") == micro:524288:65536 ]] || fail "$f is not micro:524288:65536"
  [[ $(stat -c '%a %U %G' "$f") == '644 root root' ]] || fail "$f mode or owner"
done
words=$(grep -lIiE 'PocketMICRO2|sm8250|ayaneo|aya-keys|fastrpc-sdsp|mmcblk' "${ours[@]}" || true)
[[ -z $words ]] || fail "MicroOS files name PM2 hardware: $(tr '\n' ' ' <<< "$words")"
for c in jq setpriv flock python3 loginctl busctl; do
  command -v "$c" > /dev/null || fail "$c missing, the session switcher needs it"
done
grep -qxF $'steam\tSteam OS\tyes' <<< "$(microos-session list)" || fail "microos-session list lacks steam as Steam OS"
grep -qxF $'android\tAndroid\tyes' <<< "$(microos-session list)" || fail "microos-session list lacks android"
[[ $(< /usr/lib/microos/sessions.d/android.conf) == $'LABEL=Android\nDESKTOP=microos-android.desktop\nUNIT=gamescope-session-plus@android.service\nSTOP=unit\nDEFAULT=yes\nCHECK=/usr/libexec/microos/microos-android-check' ]] \
  || fail "android.conf is not the Y700 entry with no install action"
[[ $(readlink /etc/sddm.conf.d/zzz-microos-autologin.conf) == /run/microos/sddm-autologin.conf ]] ||
  fail "zzz-microos-autologin.conf is not the link to /run/microos/sddm-autologin.conf"
getent passwd microset > /dev/null || fail "user microset missing"
schema=$(sed -n 's/^Environment=MICROSET_SCHEMA_DIR=//p' /usr/lib/systemd/system/microsetd.service.d/50-microos-y700.conf)
[[ -f $schema/10-microset.json ]] || fail "microsetd drop-in names no schema: '$schema'"
! grep -q '"power\.' "$schema/10-microset.json" || fail "$schema/10-microset.json holds power keys"
[[ $(< /usr/lib/systemd/system/microos-vpad.service.d/50-microos-microset.conf) == $'[Service]\nEnvironment=MICROOS_VPAD_MICROSET=1' ]] ||
  fail "microos-vpad 50-microos-microset.conf"
[[ $(< /usr/lib/systemd/user/microos-powerkey.service.d/50-microos-microset.conf) == $'[Service]\nEnvironment=MICROOS_POWERKEY_OVERLAY=1' ]] ||
  fail "microos-powerkey 50-microos-microset.conf"
[[ $(< /usr/share/microos-android/display) == $'width=2560\nheight=1600\ndensity=400\nhz=165\ntouch_mode=4\ngamepads=joystick\nnavbar=1\nadb=remote' ]] ||
  fail "/usr/share/microos-android/display is not the TB321FU landscape panel"
product=/usr/share/guestos/android/system/product
for f in overlay/NavigationBarModeGestural/NavigationBarModeGesturalOverlay.apk overlay/NavigationBarMode3Button/NavigationBarMode3ButtonOverlay.apk \
  overlay/NavigationBarNoHintSystemUI/NavigationBarNoHintSystemUIOverlay.apk \
  app/LineagePartsStub/LineagePartsStub.apk; do
  [[ -f $product/$f && ! -L $product/$f ]] || fail "$product/$f missing"
  [[ $(rpm -qf --qf '%{NAME}' "$product/$f" 2>/dev/null) == microos-android-guest-apks ]] || fail "$product/$f is not microos-android-guest-apks's"
done
[[ $(find /usr/share/guestos/android/system -type f | wc -l) == 4 ]] || fail "/usr/share/guestos/android/system holds more than the four guest APKs"
rpm -q podman passt catatonit attr android-tools inotify-tools >/dev/null || fail "Lepton host rpms missing"
for c in podman pasta setpgid flock pgrep pkill tput setfattr inotifywait which jq ip adb; do
  command -v "$c" >/dev/null || fail "$c is not on PATH (Lepton)"
done
adb=/usr/lib/android-sdk/platform-tools/adb
[[ -L $adb && $adb -ef /usr/bin/adb ]] || fail "$adb does not resolve to /usr/bin/adb"
[[ $(stat -c '%a %U %G' /usr/bin/steamvr) == '755 root root' ]] || fail "/usr/bin/steamvr mode or owner"
[[ -f /usr/share/microos-lepton/reviewed/25772114 ]] || fail "no reviewed list for Lepton build 25772114"
command -v xprop >/dev/null || fail "xprop missing, the Android client sets the touch mode with it"
[[ ! -e /usr/lib/systemd/user/gamescope-session-plus@android.service.d/20-microos-android-pad.conf ]] \
  || fail "the PM2 pad target drop-in is in the image"
grep -q MICROOS_VPAD_MICROSET /usr/libexec/microos/microos-vpad || fail "microos-vpad has no MICROOS_VPAD_MICROSET knob"
grep -q MICROOS_POWERKEY_OVERLAY /usr/libexec/microos/microos-powerkey || fail "microos-powerkey has no MICROOS_POWERKEY_OVERLAY knob"

rpm -q waydroid waydroid-selinux lxc >/dev/null || fail "waydroid, waydroid-selinux or lxc missing"
for c in waydroid lxc-start gdbus; do
  command -v "$c" >/dev/null || fail "$c missing, the Waydroid probe session needs it"
done
for f in Waydroid.desktop waydroid.market.desktop waydroid.app.install.desktop; do
  [[ ! -e /usr/share/applications/$f ]] || fail "/usr/share/applications/$f is in the image"
done
[[ $(readlink /usr/share/waydroid-extra/images) == /var/lib/microos-android/images/current ]] ||
  fail "/usr/share/waydroid-extra/images is not the link to /var/lib/microos-android/images/current"
[[ $(< /usr/lib/tmpfiles.d/microos-waydroid.conf) == $'d /var/cache/lxc 0755 root root -\nd /var/lib/lxc 0755 root root -\nd /var/lib/lxcfs 0755 root root -\nd /var/lib/waydroid 0755 root root -' ]] \
  || fail "tmpfiles microos-waydroid.conf"
[[ $(systemctl is-enabled dev-binderfs.mount) == enabled ]] || fail "dev-binderfs.mount is not enabled"
grep -qx 'Type=binder' /usr/lib/systemd/system/dev-binderfs.mount || fail "dev-binderfs.mount is not a binder mount"
[[ ! -e /var/lib/waydroid ]] || fail "/var/lib/waydroid is in the image, tmpfiles makes it"
[[ $(systemctl is-enabled waydroid-container.service) == disabled ]] ||
  fail "waydroid-container.service is $(systemctl is-enabled waydroid-container.service), D-Bus activation starts it"
grep -qx 'SystemdService=waydroid-container.service' /usr/share/dbus-1/system-services/id.waydro.Container.service ||
  fail "id.waydro.Container.service does not activate waydroid-container.service"
[[ $(< /usr/lib/microos/sessions.d/waydroid.conf) == $'LABEL=Waydroid\nDESKTOP=microos-waydroid-probe.desktop\nUNIT=gamescope-session-plus@waydroid.service\nSTOP=unit' ]] \
  || fail "waydroid.conf is not the probe entry with no default and no check"
grep -qxF $'waydroid\tWaydroid\tno' <<< "$(microos-session list)" || fail "microos-session list lacks waydroid as a hidden session"
[[ $(< /usr/share/wayland-sessions/microos-waydroid-probe.desktop) == $'[Desktop Entry]\nName=Waydroid\nExec=gamescope-session-plus waydroid\nType=Application\nDesktopNames=waydroid\nNoDisplay=true' ]] \
  || fail "microos-waydroid-probe.desktop"
[[ $(< /usr/share/gamescope-session-plus/sessions.d/waydroid) == $'export GAMESCOPE_BIN=/usr/libexec/microos/microos-gamescope-plain\nexport CLIENTCMD=/usr/libexec/microos/wd-session' ]] \
  || fail "/usr/share/gamescope-session-plus/sessions.d/waydroid"
[[ -x /usr/libexec/microos/microos-gamescope-plain ]] || fail "microos-gamescope-plain missing, the Waydroid probe session runs it"
for f in wd-session wd-stop; do
  [[ $(stat -c %a "/usr/libexec/microos/$f") == 755 ]] || fail "$f is not 755"
done
grep -qF -- '-p ExecStop=/usr/libexec/microos/wd-stop' /usr/libexec/microos/wd-session || fail "wd-session does not stop wd-android through wd-stop"

yama=/usr/lib/sysctl.d/60-microos-yama.conf
grep -qx 'kernel.yama.ptrace_scope = 1' "$yama" || fail "$yama does not set ptrace_scope 1"
last=$(/usr/lib/systemd/systemd-sysctl --cat-config | awk '/^# \/[^ ]*\.conf( -> |$)/ { f = $2 } /^-?kernel[.\/]yama[.\/]ptrace_scope[[:space:]]*=/ { l = f " " $0 } END { print l }')
[[ $last == "$yama kernel.yama.ptrace_scope = 1" ]] || fail "the last ptrace_scope setting is not $yama: $last"

[[ $(< /usr/lib/bootc/kargs.d/10-microos.toml) == 'match-architectures = ["aarch64"]
kargs = [
  "firmware_class.path=/var/lib/microos/fw",
  "loglevel=4",
  "reboot=cold,panic_warm",
]' ]] || fail "10-microos.toml kargs"
[[ $(< /usr/lib/microos/slot.conf) == $'MICROOS_SLOT_WRITE=1\nMICROOS_BOOT_TRIES=3' ]] || fail "slot.conf does not turn slot writes on"
stub=/usr/lib/microos/stub
[[ $(sha256sum < "$stub/stub-preset-free.conf") == $(sha256sum < /usr/lib/microos/stub.conf) ]] || fail "stub-preset-free.conf differs from stub.conf"
payload=$(( $(sed -n 's/^MICROOS_STUB_PAYLOAD=//p' /usr/lib/microos/stub.conf) ))
[[ $(stat -c %s "$stub/stub-preset-free.bin") == "$payload" ]] || fail "stub-preset-free.bin is not $payload bytes"
[[ $(dd if="$stub/stub-preset-free.bin" bs=1 skip=56 count=4 status=none) == ARMd ]] || fail "stub-preset-free.bin has no arm64 Image header"
{ head -c 16 /dev/zero; printf '\x00\x10\x00\x00\x00\x00\x00\x00'; head -c 32 /dev/zero; printf 'ARMd'; head -c 4036 /dev/zero; } > "$tmp/Image"
/usr/libexec/microos/microos-stub-pack "$tmp/Image" "$tmp/packed" > /dev/null || fail "microos-stub-pack failed on a dummy Image"
[[ $(stat -c %s "$tmp/packed") == $(( payload + 4096 )) ]] || fail "microos-stub-pack output size $(stat -c %s "$tmp/packed")"
[[ $(od -An -tu8 -j16 -N8 "$tmp/packed" | tr -d ' ') == $(( payload + 4096 )) ]] || fail "microos-stub-pack image_size"
[[ $(tail -c 4096 "$tmp/packed" | sha256sum) == $(sha256sum < "$tmp/Image") ]] || fail "microos-stub-pack payload bytes differ"
[[ $(sha256sum < /usr/share/microos/avb/testkey_rsa4096.pem) == "6a224754880a57ab9cbd308267cd157d94cf05a1c8cb851aec4090e045d24121  -" ]] \
  || fail "AVB test key sha256"
[[ $(< /usr/lib/systemd/journald.conf.d/10-microos.conf) == $'[Journal]\nStorage=persistent' ]] || fail "journald 10-microos.conf"
[[ $(< /usr/lib/bootc/install/00-microos.toml) == $'[install.filesystem.root]\ntype = "btrfs"' ]] || fail "00-microos.toml"
[[ $(< /usr/lib/NetworkManager/conf.d/10-microos.conf) == $'[keyfile]\npath=/var/lib/NetworkManager/system-connections' ]] \
  || fail "NetworkManager 10-microos.conf"
[[ ! -e /usr/lib/NetworkManager/system-connections/microos-usb0.nmconnection ]] || fail "microos-usb0.nmconnection ships"
for f in microos-slot microos-usb-console microos-vpad microos-powerkey microos-gameidle microos-remoteproc microos-bootimg-update microos-stub-pack; do
  [[ $(stat -c %a "/usr/libexec/microos/$f") == 755 ]] || fail "$f is not 755"
done
vpad=/usr/libexec/microos/microos-vpad
python3 -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
  "$vpad" "$tmp/vpad.pyc" || fail "microos-vpad does not compile"
[[ $(grep -E '^\s*(import|from) ' "$vpad" | LC_ALL=C sort | paste -sd' ') == \
  'import fcntl import math import os import pwd import select import signal import socket import struct import sys import time' ]] || fail "microos-vpad imports"
! grep -q ctypes "$vpad" || fail "microos-vpad uses ctypes"
vp() { MICROOS_VPAD_DRYRUN=$1 "$vpad" "${@:2}"; }
evioc() { echo $(( ($1 << 30) | ($3 << 16) | (0x45 << 8) | $2 )); }
desc=06ffff0901a10109020903150026ff00750895408102090609071500
desc+=26ff0075089540b102c0
[[ $(vp 1) == "$((4 + 128 + 64 + 64 + 2 + 2 + 4 * 4 + 4096)) $(evioc 1 0x80 48) $(evioc 1 0x90 4) $(evioc 2 0x18 96) $(evioc 1 0xa0 4) 48 24 $desc" ]] \
  || fail "microos-vpad event sizes, ioctl numbers or descriptor: $(vp 1)"
c=$(vp uhid create)
[[ ${c:0:8} == 0b000000 && ${c:520:4} == 2600 && ${c:524:4} == 0300 && ${c:528:8} == de280000 && ${c:536:8} == f0120000 \
  && ${c:560} == "$desc" ]] || fail "microos-vpad CREATE2 event: $c"
serial=4d4943524f4f5359373030
[[ $(vp uhid 0d000000070000000000040000ae1501 09000000080000000000) == \
  "$(printf '0e000000070000000000%0140d' 0)"$'\n'"$(printf '0a000000080000000000410000ae0c01%s00%0104d' "$serial" 0)" ]] \
  || fail "microos-vpad SET_REPORT and GET_REPORT replies: $(vp uhid 0d000000070000000000040000ae1501 09000000080000000000)"
mapfile -t fr < <(vp feature ae1501 8300 8703080700)
[[ ${fr[0]} == "$(printf '00ae0c01%s00%098d' "$serial" 0)" ]] || fail "microos-vpad serial reply: ${fr[0]}"
recs=" "
for ((i = 6; i < 6 + 2 * 16#${fr[1]:4:2}; i += 10)); do
  recs+="${fr[1]:i:10} "
done
[[ ${fr[1]:0:4} == 0083 && $recs == *' 01f0120000 '* && $recs == *' 0ba00f0000 '* ]] || fail "microos-vpad attributes reply: ${fr[1]}"
[[ ${fr[2]} == "$(printf '008703080700%0118d' 0)" ]] || fail "microos-vpad settings echo: ${fr[2]}"
[[ $(vp haptic 8f0801a00f0000010000) == 'left 8 40960' && $(vp haptic 8f0801a00f0000000000) == 'left 8 40960' \
  && $(vp haptic 8f0800a00f0000010000) == 'right 8 40960' && $(vp haptic 8f0802a00f0000010000) == $'left 8 40960\nright 8 40960' \
  && $(vp haptic 8f0801a00f00000100fa) == 'left 8 20529' && $(vp haptic 8f0801a00fa00f050000) == 'left 40 40960' \
  && $(vp haptic 8f0801a00fa00f640000) == 'left 200 40960' ]] || fail "microos-vpad 0x8f pulses"
[[ $(vp haptic ea0402010000) == $'left 12 40960\nright 12 40960' && $(vp haptic ea0402010400) == $'left 24 40960\nright 24 40960' \
  && $(vp haptic ea0402020100) == $'left 13 40960\nright 13 40960' && $(vp haptic ea0400000000) == 'left 0 0' \
  && -z $(vp haptic eb09000000000000000000 ec0a0000000000000000) ]] || fail "microos-vpad 0xea, 0xeb or 0xec"
[[ $(vp keys '0:1 80:0') == $'down 0 0\nsingle 380 0' && $(vp keys '0:1 80:0 200:1 260:0') == $'down 0 0\ndown 200 200\ndouble 200 200' \
  && $(vp keys '0:1 700:0') == 'down 0 0' && $(vp keys '0:1 1500:0') == $'down 0 0\nhold 1000 0' ]] \
  || fail "microos-vpad power key taps"
off=$'save 1200\nbl 0'
for t in "single|$off"$'\ngrab' "single bl=800 single|$off"$'\ngrab\nbl 0\nbl 1200\nungrab' \
  "single double|$off"$'\ngrab\nbl 1200\nungrab' 'double|qam' "touch=1 single|$off" "touch=1 single touch=0|$off"$'\ngrab' \
  "touch=1 single wait=1999 touch=0|$off"$'\ngrab' "touch=1 single wait=2000|$off"$'\nnograb' "ebusy single|$off"$'\nnograb'; do
  [[ $(vp screen 1200 "${t%%|*}") == "${t#*|}" ]] || fail "microos-vpad screen ${t%%|*}: $(vp screen 1200 "${t%%|*}" | tr '\n' ' ')"
done
[[ $(vp screen 0 'single single') == $'save 0\nbl 0\ngrab\nbl 512\nungrab' ]] || fail "microos-vpad screen restore of 0"
[[ $(vp restore 0 1200) == 1200 && $(vp restore 0 none) == 512 && $(vp restore 0 0) == 512 && -z $(vp restore 900 1200) ]] \
  || fail "microos-vpad restore values"
unit=/usr/lib/systemd/system/microos-vpad.service
for l in 'DeviceAllow=/dev/uhid rw' 'DeviceAllow=char-input rw' 'ReadWritePaths=-/sys/class/backlight/ktz8866-backlight/' \
  'StartLimitIntervalSec=0' 'RuntimeDirectory=microos-vpad' 'RuntimeDirectoryPreserve=yes' \
  'ExecStopPost=/usr/libexec/microos/microos-vpad restore' 'MemoryDenyWriteExecute=yes' 'CapabilityBoundingSet=' \
  'RestrictAddressFamilies=AF_UNIX'; do
  grep -qxF "$l" "$unit" || fail "microos-vpad.service lacks $l"
done
! grep -q uinput "$unit" || fail "microos-vpad.service still allows uinput"
[[ $(< /usr/lib/systemd/logind.conf.d/50-microos.conf) == $'[Login]\nHandlePowerKey=ignore\nHandlePowerKeyLongPress=ignore' ]] \
  || fail "logind 50-microos.conf"
grep -qxF 'SUBSYSTEM=="hidraw", KERNELS=="000[356]:28DE:*", MODE="0660", TAG+="uaccess"' /usr/lib/udev/rules.d/60-steam-input.rules \
  || fail "60-steam-input.rules has no hidraw rule for 28DE"
compgen -G "/usr/lib/modules/$kver/kernel/drivers/hid/hid-steam.ko*" >/dev/null || fail "hid-steam module missing"
[[ $(< /usr/lib/udev/rules.d/90-microos-usb-console.rules) == \
  'SUBSYSTEM=="tty", KERNEL=="ttyGS0", ENV{SYSTEMD_WANTS}+="serial-getty@ttyGS0.service"' ]] || fail "90-microos-usb-console.rules"
[[ $(< /usr/lib/tmpfiles.d/microos.conf) == $'d /run/microos 0755 root root -\nd /run/microos/adsp 0755 root root -\nf /run/microos/system-card 0644 root root - internal\nd /var/home/micro 0700 micro micro -\nd /var/lib/microos 0755 root root -\nd /var/cache/libX11 0755 root root -\nd /var/cache/libX11/compose 0755 root root -\nd /var/lib/geoclue 0755 geoclue geoclue -\nw /sys/power/pm_freeze_timeout - - - - 5000' ]] \
  || fail "tmpfiles microos.conf"
[[ $(< /usr/lib/systemd/sleep.conf.d/50-microos.conf) == $'[Sleep]\nAllowHibernation=no\nAllowSuspendThenHibernate=no\nAllowHybridSleep=no\nMemorySleepMode=s2idle' ]] \
  || fail "sleep.conf.d 50-microos.conf"
last=$(systemd-analyze cat-config systemd/sleep.conf | awk -F= '/^MemorySleepMode=/ { v = $2 } END { print v }')
[[ $last == s2idle ]] || fail "effective MemorySleepMode is $last"
[[ $(< /usr/lib/systemd/system.conf.d/50-microos.conf) == $'[Manager]\nRuntimeWatchdogSec=30s\nRebootWatchdogSec=30s' ]] \
  || fail "system.conf.d 50-microos.conf"
for k in RuntimeWatchdogSec RebootWatchdogSec; do
  last=$(systemd-analyze cat-config systemd/system.conf | awk -F= -v k="$k" '$1 == k { v = $2 } END { print v }')
  [[ $last == 30s ]] || fail "effective $k is $last"
done
for f in microos-sleep-log microos-wake-reason microos-hexagonrpcd-adsp; do
  [[ $(stat -c %a "/usr/lib/systemd/system-sleep/$f") == 755 ]] || fail "system-sleep/$f is not 755"
done
dtb=/usr/lib/modules/$kver/dtb/$(sed -n 's/^MICROOS_DTB=//p' /usr/lib/microos/bootimg.conf)
[[ $(od -An -tx1 -N4 "$dtb" | tr -d ' \n') == d00dfeed ]] || fail "MICROOS_DTB $dtb is not a DTB"

[[ $(< /usr/lib/sddm/sddm.conf.d/zz-microos.conf) == $'[General]\nDisplayServer=wayland\n\n[Autologin]\nUser=micro\nRelogin=true\nSession=gamescope-session-steam.desktop' ]] \
  || fail "sddm zz-microos.conf is not the micro autologin into gamescope-session-steam"
[[ $(readlink /etc/systemd/system/display-manager.service) == */sddm.service ]] || fail "display-manager.service is not sddm"
[[ $(systemctl get-default) == graphical.target ]] || fail "default target is $(systemctl get-default)"
grep -qx 'Exec=gamescope-session-plus steam' /usr/share/wayland-sessions/gamescope-session-steam.desktop \
  || fail "gamescope-session-steam.desktop does not start gamescope-session-plus steam"
for u in sddm.service upower.service chronyd.service NetworkManager.service; do
  [[ $(systemctl is-enabled "$u") == enabled ]] || fail "$u is not enabled"
done
y700='if [[ ":Lenovo Legion Y700 (2025) / TB321FU:" =~ ":$SYS_ID:" ]]; then'
quirk=$(grep -A4 -xF "$y700" /usr/share/gamescope-session-plus/device-quirks || true)
[[ $quirk == "$y700"$'\n'"  OUTPUT_CONNECTOR='*,DSI-1'"$'\n  ORIENTATION=right\n  GAMESCOPE_STARTUP_TIMEOUT=30\nfi' ]] \
  || fail "device-quirks Y700 entry: $quirk"
python3 - "$dtb" <<'PY' || fail "MICROOS_DTB has no model the quirk matches"
import sys
sys.exit(b"Lenovo Legion Y700 (2025) / TB321FU\0" not in open(sys.argv[1], "rb").read())
PY
[[ $(< /etc/gamescope-session-plus/sessions.d/steam) == $'short_session_recover() {\n  echo "microos: short Steam session, recovery is off" >&2\n}' ]] \
  || fail "/etc/gamescope-session-plus/sessions.d/steam"
for h in steamos-update steamos-select-branch jupiter-biosupdate steamos-set-timezone steamos-priv-write; do
  [[ -x /usr/bin/steamos-polkit-helpers/$h ]] || fail "steamos-polkit-helpers/$h missing"
done
for h in steam steamos-update steamos-select-branch steamos-session-select steamos-mandatory-update jupiter-biosupdate \
  jupiter-initial-firmware-update; do
  [[ -x /usr/bin/$h && $(rpm -qf "/usr/bin/$h" 2>/dev/null) != *gamescope-session-steam* ]] || fail "/usr/bin/$h missing or from gamescope-session-steam"
done
steamrules=/usr/share/polkit-1/rules.d/50-microos-steam.rules
for a in inhibit-handle-power-key inhibit-handle-suspend-key suspend reboot power-off; do
  grep -qF "\"org.freedesktop.login1.$a\"" "$steamrules" || fail "$steamrules lacks org.freedesktop.login1.$a"
done
[[ $(< /usr/lib/systemd/system-preset/60-microos-steam.preset) == 'enable upower.service' ]] || fail "60-microos-steam.preset"

seedrpm=(/seed-rpm/microos-steam-seed-*.aarch64.rpm)
[[ ${#seedrpm[@]} -eq 1 && -f ${seedrpm[0]} ]] || fail "expected one microos-steam-seed RPM in /seed-rpm"
[[ $(rpm -qp --qf '%{FILEDIGESTALGO}' "${seedrpm[0]}") == 8 ]] || fail "seed RPM file digests are not sha256"
seedfiles=$(rpm -qp --qf '[%{FILENAMES}|%{FILEDIGESTS}|%{FILEMODES:octal}\n]' "${seedrpm[0]}") || fail "rpm -qp of the seed RPM"
grep -q '^/usr/share/microos-seed/steam-seed.tar.zst|' <<< "$seedfiles" || fail "seed RPM file list: $seedfiles"
while IFS='|' read -r path digest mode; do
  if [[ $mode == 100* ]]; then
    [[ $(sha256sum < "$path" | cut -d' ' -f1) == "$digest" ]] || fail "$path differs from the seed RPM"
    [[ $(stat -c '%a' "$path") == "${mode: -3}" ]] || fail "$path mode differs from the seed RPM"
  else
    [[ -d $path ]] || fail "$path missing"
  fi
done <<< "$seedfiles"
[[ $(find /usr/share/microos-seed -mindepth 1 | sort) == "$(rpm -qlp "${seedrpm[0]}" | grep '^/usr/share/microos-seed/' | sort)" ]] \
  || fail "/usr/share/microos-seed holds files outside the seed RPM"

ls /usr/share/vulkan/icd.d/freedreno_icd.*.json >/dev/null 2>&1 || fail "no Turnip (freedreno) Vulkan ICD"
[[ $(< /usr/lib/modules-load.d/microos-y700.conf) == $'pci-pwrctrl-pwrseq\nqrtr' ]] || fail "modules-load.d microos-y700.conf"
! modprobe -c | grep -qE '^(blacklist|install) rtc[_-]pm8xxx( |$)' || fail "modprobe.d blacklists rtc_pm8xxx"
find "/usr/lib/modules/$kver/kernel" -name "rtc-pm8xxx.ko*" | grep -q . || fail "rtc-pm8xxx module missing"
grep -qx '# CONFIG_RTC_HCTOSYS is not set' "/usr/lib/modules/$kver/config" || fail "the image kernel sets RTC_HCTOSYS, rtc_pm8xxx would set the clock"
[[ $(readlink /etc/systemd/system-generators/systemd-gpt-auto-generator) == /dev/null ]] || fail "systemd-gpt-auto-generator is not masked"
udevadm verify --no-style /usr/lib/udev/rules.d/60-microos-backlight.rules >/dev/null 2>&1 || fail "60-microos-backlight.rules does not verify"
rules=/usr/lib/udev/rules.d/60-microos-y700-pcie-wakeup.rules
[[ $(< "$rules") == 'ACTION=="add", SUBSYSTEM=="pci", ATTR{class}=="0x060400", KERNELS=="1c00000.pcie", ATTR{power/wakeup}="disabled"' ]] \
  || fail "60-microos-y700-pcie-wakeup.rules"
udevadm verify --no-style "$rules" >/dev/null 2>&1 || fail "$rules does not verify"
rules=/usr/lib/udev/rules.d/60-microos-y700-touch.rules
[[ $(< "$rules") == 'SUBSYSTEM=="input", KERNEL=="event*", DEVPATH!="/devices/virtual/*", ATTRS{id/bustype}=="001c", ATTRS{name}=="Novatek NT36523 Touchscreen|Novatek NT36523 Pen", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 -1 1 1 0 0"' ]] \
  || fail "60-microos-y700-touch.rules"
udevadm verify --no-style "$rules" >/dev/null 2>&1 || fail "$rules does not verify"
rules=/usr/lib/udev/rules.d/91-microos-y700-bdaddr.rules
[[ $(< "$rules") == 'SUBSYSTEM=="bluetooth", KERNEL=="hci[0-9]*", ENV{DEVTYPE}=="host", TAG+="systemd", ENV{SYSTEMD_WANTS}+="microos-bdaddr@%k.service"' ]] \
  || fail "91-microos-y700-bdaddr.rules"
udevadm verify --no-style "$rules" >/dev/null 2>&1 || fail "$rules does not verify"
[[ -x /usr/bin/btmgmt && -x /usr/bin/debugfs ]] || fail "btmgmt or debugfs missing"
for f in /usr/libexec/microos/microos-adsp-sensors /usr/libexec/microos/microos-lp-extent \
  /usr/lib/systemd/system-sleep/microos-hexagonrpcd-adsp; do
  [[ -f $f && ! -L $f && $(stat -c '%a %U %G' "$f") == '755 root root' ]] || fail "$f missing, mode or owner"
done
[[ -x /usr/bin/python3 ]] || fail "/usr/bin/python3 missing, microos-lp-extent needs it"
python3 -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
  /usr/libexec/microos/microos-lp-extent "$tmp/lp-extent.pyc" || fail "microos-lp-extent does not compile"
command -v hexagonrpcd >/dev/null || fail "hexagonrpcd is not on PATH"
adsprules=/usr/lib/udev/rules.d/70-microos-adsp-sensors.rules
for r in 'SUBSYSTEM=="remoteproc", ATTR{name}=="adsp", TAG+="systemd", ENV{SYSTEMD_WANTS}+="microos-adsp-sensors.service"' \
  'SUBSYSTEM=="misc", KERNEL=="fastrpc-adsp", TAG+="systemd", ENV{SYSTEMD_WANTS}+="microos-hexagonrpcd-adsp.service"'; do
  grep -qxF "$r" "$adsprules" || fail "$adsprules lacks $r"
done
hexunit=/usr/lib/systemd/system/microos-hexagonrpcd-adsp.service
grep -qx 'ExecStart=/usr/bin/hexagonrpcd -f /dev/fastrpc-adsp -d adsp -s -R /run/microos/adsp/current/hexagonfs' \
  "$hexunit" || fail "microos-hexagonrpcd-adsp.service ExecStart"
grep -qx 'DynamicUser=yes' "$hexunit" || fail "microos-hexagonrpcd-adsp.service is not DynamicUser"
for l in 'ExecStartPre=+/usr/bin/chown root:hexagonrpc /dev/fastrpc-adsp' 'ExecStartPre=+/usr/bin/chmod 0660 /dev/fastrpc-adsp' \
  'ExecStartPre=+/usr/bin/chgrp -R hexagonrpc /run/microos/adsp/current/hexagonfs/sensors/persist' \
  'ExecStartPre=+/usr/bin/chmod -R g+rwX /run/microos/adsp/current/hexagonfs/sensors/persist' \
  'ReadWritePaths=/run/microos/adsp' 'UMask=0007'; do
  grep -qxF "$l" "$hexunit" || fail "microos-hexagonrpcd-adsp.service lacks $l"
done
grep -qx 'Wants=microos-adsp-sensors.service' "$hexunit" || fail "microos-hexagonrpcd-adsp.service does not want microos-adsp-sensors.service"
grep -qx 'ConditionPathIsDirectory=/run/microos/adsp/current/hexagonfs' "$hexunit" ||
  fail "microos-hexagonrpcd-adsp.service does not need the hexagonfs tree"
pw=/usr/bin/steamos-polkit-helpers/steamos-priv-write
[[ $(stat -c %a "$pw") == 755 ]] || fail "$pw is not 755"
! "$pw" /etc/passwd 1 2>/dev/null || fail "$pw writes outside backlight brightness"
! "$pw" /sys/class/backlight/none/brightness 1 2>/dev/null || fail "$pw accepts a missing backlight"
for m in drivers/pci/pwrctrl/pci-pwrctrl-pwrseq drivers/net/wireless/ath/ath12k/ath12k \
  drivers/net/wireless/ath/ath12k/wifi7/ath12k_wifi7 drivers/power/supply/qcom_battmgr \
  drivers/input/touchscreen/novatek-nt36523 sound/soc/codecs/snd-soc-aw88261 sound/soc/qcom/snd-soc-sc8280xp; do
  compgen -G "/usr/lib/modules/$kver/kernel/$m.ko*" >/dev/null || fail "module $m missing"
done
alias=/usr/lib/modules/$kver/modules.alias
grep -qx 'alias of:N\*T\*Cpci17cb,1107 pci_pwrctrl_pwrseq' "$alias" || fail "no WCN7850 alias for pci_pwrctrl_pwrseq"
grep -qx 'alias of:N\*T\*Cnovatek,nt36523-ts novatek_nt36523' "$alias" || fail "no NT36523 touchscreen alias for novatek_nt36523"
grep -qx 'alias of:N\*T\*Cawinic,aw88461 snd_soc_aw88261' "$alias" || fail "no AW88461 alias for snd_soc_aw88261"
grep -qx 'alias of:N\*T\*Clenovo,tb321fu-sndcard snd_soc_sc8280xp' "$alias" || fail "no TB321FU sound card alias for snd_soc_sc8280xp"
grep -qx 'alias of:N\*T\*Cqcom,wcd9390-codec snd_soc_wcd939x' "$alias" || fail "no WCD9390 alias for snd_soc_wcd939x"
for f in amss m3 board-2; do
  compgen -G "/usr/lib/firmware/ath12k/WCN7850/hw2.0/$f.bin*" >/dev/null || fail "ath12k WCN7850 $f.bin missing"
done
dtbs=$(tr -d '\0' < "$dtb")
for f in gen70900_zap.mbn novatek_ts_boe_fw.bin vpu33_p4.mbn adsp.mdt cdsp.mdt aw882xx_acf.bin; do
  [[ $dtbs == *"qcom/sm8650/lenovo/tb321fu/$f"* ]] || fail "MICROOS_DTB does not ask for qcom/sm8650/lenovo/tb321fu/$f"
done
for f in gen70900_sqe.fw gmu_gen70900.bin; do
  compgen -G "/usr/lib/firmware/qcom/$f*" >/dev/null || fail "Fedora qcom/$f missing"
done
blobs=$(find /usr /etc /var -xdev \( -path '*/qcom/sm8650/lenovo*' -o -name wlan_mac.bin -o -name 'novatek_ts_*' \
  -o -name 'bdwlan*' \) -print 2>/dev/null || true)
[[ -z $blobs ]] || fail "device firmware in the image: $(tr '\n' ' ' <<< "$blobs")"
[[ ! -e /var/lib/microos/fw ]] || fail "/var/lib/microos/fw is in the image, install time only"

execs() {
  systemctl cat "$1" | awk -v k="$2=" 'index($0, k) == 1 { v = substr($0, length(k) + 1); if (v == "") n = 0; else l[++n] = v }
    END { for (i = 1; i <= n; i++) print l[i] }'
}
[[ $(execs ostree-finalize-staged.service ExecStop) == '/usr/bin/ostree admin finalize-staged' ]] \
  || fail "effective ostree-finalize-staged.service ExecStop: $(execs ostree-finalize-staged.service ExecStop)"
[[ -z $(execs ostree-finalize-staged.service ExecStartPre) ]] || fail "ostree-finalize-staged.service has an ExecStartPre"
[[ $(execs microos-boot-ok.service After) == 'multi-user.target ostree-finalize-staged.service' ]] \
  || fail "microos-boot-ok.service After: $(execs microos-boot-ok.service After)"
[[ $(execs emergency.service ExecStart) == '-/usr/libexec/microos/microos-fail emergency' ]] \
  || fail "effective emergency.service ExecStart: $(execs emergency.service ExecStart)"
systemctl cat microos-boot-deadline.timer | grep -qx 'OnBootSec=900' || fail "microos-boot-deadline.timer is not 900 s"
systemctl cat serial-getty@ttyGS0.service | grep -qx 'ConditionKernelCommandLine=microos.test' \
  || fail "serial-getty@ttyGS0.service has no microos.test condition"
[[ $(execs serial-getty@ttyGS0.service ExecStart) == '-/usr/sbin/agetty --autologin root '* ]] \
  || fail "serial-getty@ttyGS0.service ExecStart: $(execs serial-getty@ttyGS0.service ExecStart)"
systemctl cat sshd.service | grep -qx 'ConditionPathExists=/var/home/micro/.ssh/authorized_keys' \
  || fail "sshd.service has no ConditionPathExists on micro's authorized_keys"
while read -r u p; do
  [[ $p == -* || $p == /sys/* ]] && continue
  grep -qE "^d $p [0-7]+ " /usr/lib/tmpfiles.d/*.conf || fail "${u##*/} ReadWritePaths=$p has no tmpfiles line"
done < <(awk -F= '/^ReadWritePaths=/ { n = split($2, a, " "); for (i = 1; i <= n; i++) print FILENAME, a[i] }' "${units[@]}")
SYSTEMD_LOG_LEVEL=warning systemd-analyze verify --man=no "${units[@]}" /usr/lib/systemd/system/sshd.service \
  /usr/lib/systemd/system/ostree-finalize-staged.service || fail "systemd-analyze verify"

pol=/etc/containers/policy.json
keys=(/usr/share/microos/keys/microos.pub /usr/share/microos/keys/microos-backup.pub /usr/share/microos/keys/microos-next.pub)
jq -e '.default == [{"type": "reject"}]' "$pol" >/dev/null || fail "policy default is not reject"
[[ $(sed -n 's/^repo=//p' /usr/bin/microos-update) == "$image" ]] || fail "microos-update repo= is not $image"
jq -e --arg i "$image" '.transports.docker[$i] == [{"type": "sigstoreSigned", "keyPaths": $ARGS.positional,
  "signedIdentity": {"type": "matchRepository"}}]' --args "${keys[@]}" < "$pol" >/dev/null || fail "policy scope $image"
jq -e --arg i "$image" '[.transports.docker | to_entries[] | select(any(.value[]; .type == "sigstoreSigned")) | .key] == [$i]' "$pol" >/dev/null \
  || fail "policy has a signed scope other than $image"
[[ $(sed -n 's/^IMAGE=//p' "$repo/devices/$dev/device.env") == "$image" ]] || fail "devices/$dev/device.env IMAGE is not $image"
for e in "$repo"/devices/*/device.env; do
  [[ $e != "$repo/devices/$dev/device.env" ]] || continue
  o=$(sed -n 's/^IMAGE=//p' "$e")
  [[ -n $o ]] || fail "no IMAGE in ${e#"$repo/"}"
  jq -e --arg o "$o" '.transports.docker[$o] == [{"type": "reject"}]' "$pol" >/dev/null || fail "policy does not reject $o"
done
for k in "${keys[@]}"; do
  openssl pkey -pubin -noout -in "$k" 2>/dev/null || fail "$k is not a public key"
done
[[ $(< /etc/containers/registries.d/ghcr-microos.yaml) == $'docker:\n  '"$image"$':\n    use-sigstore-attachments: true' ]] \
  || fail "registries.d ghcr-microos.yaml is not for $image"

owned=$(rpm -qa --qf '[%{FILENAMES}\n]' | LC_ALL=C sort -u)
declare -A src=()
for t in "$repo/system_files" "$repo/devices/$dev/system_files"; do
  while IFS= read -r -d '' f; do
    src[/${f#"$t/"}]=$f
  done < <(find "$t" ! -type d -print0)
done
for p in "${!src[@]}"; do
  f=${src[$p]}
  if [[ -L $f ]]; then
    [[ -L $p && $(readlink "$p") == "$(readlink "$f")" ]] || fail "$p is not the link of ${f#"$repo/"}"
  elif [[ ! -f $p || -L $p ]]; then
    fail "$p of ${f#"$repo/"} is not in the image"
  elif [[ $(sha256sum < "$p") != "$(sha256sum < "$f")" ]]; then
    fail "$p differs from ${f#"$repo/"}"
  fi
done
for t in "$repo"/devices/*/system_files; do
  [[ $t != "$repo/devices/$dev/system_files" ]] || continue
  while IFS= read -r -d '' f; do
    p=/${f#"$t/"}
    [[ -z ${src[$p]:-} && ( -e $p || -L $p ) ]] || continue
    grep -qxF -- "$p" <<< "$owned" || fail "$p of ${f#"$repo/"} is in the $dev image and no rpm owns it"
    [[ -L $f || -L $p || ! -f $p || $(sha256sum < "$p") != "$(sha256sum < "$f")" ]] || fail "$p in the $dev image is ${f#"$repo/"}"
  done < <(find "$t" ! -type d -print0)
done

mkdir -p "$tmp/etc/ssh"
ssh-keygen -A -f "$tmp" >/dev/null
hk=()
for k in "$tmp"/etc/ssh/ssh_host_*_key; do hk+=(-h "$k"); done
sshd -T "${hk[@]}" > "$tmp/sshd"
for kv in 'passwordauthentication no' 'kbdinteractiveauthentication no' 'permitrootlogin no' 'allowusers micro' \
  'authenticationmethods publickey' 'x11forwarding no' 'gssapiauthentication no'; do
  grep -qx "$kv" "$tmp/sshd" || fail "sshd -T lacks '$kv'"
done

grep -q '^micro:x:1000:1000:' /etc/passwd || fail "micro is not in the image /etc/passwd"
[[ $(id -u micro):$(id -g micro) == 1000:1000 ]] || fail "micro is not 1000:1000"
groups=$(id -nG micro)
for g in wheel systemd-journal video; do
  [[ " $groups " == *" $g "* ]] || fail "micro is not in $g"
done
[[ $(getent passwd micro | cut -d: -f6,7) == /var/home/micro:/bin/bash ]] || fail "micro home or shell"
for u in microos-openh264; do
  ! getent passwd "$u" >/dev/null || fail "user $u exists"
done
hexgid=$(getent group hexagonrpc | cut -d: -f3) || fail "group hexagonrpc missing"
(( hexgid < 1000 )) || fail "hexagonrpc is not a system group"
rules=$(sudo -l -U micro)
grep -q '(ALL) ALL' <<< "$rules" || fail "micro has no wheel sudo rule"
! grep -q NOPASSWD <<< "$rules" || fail "micro has a NOPASSWD rule"
! grep -qE '/tee( |,|$)' <<< "$rules" || fail "micro has a sudo rule for tee"

img=/usr/lib/modules/$kver/initramfs.img
list=$(lsinitrd "$img")
for m in erofs overlay btrfs ufs-qcom; do
  grep -qE "/$m\.ko" <<< "$list" || grep -qE "/$m\.ko$" "/usr/lib/modules/$kver/modules.builtin" || fail "initramfs lacks $m"
done
grep -qE "/kernel/net/qrtr/qrtr\.ko( |$)" <<< "$list" || fail "initramfs lacks qrtr"
[[ $(lsinitrd -f usr/lib/modules-load.d/microos-y700.conf "$img") == $'pci-pwrctrl-pwrseq\nqrtr' ]] \
  || fail "initramfs modules-load.d microos-y700.conf"
grep -qE "/sysinit\.target\.wants/systemd-modules-load\.service( |$)" <<< "$list" \
  || fail "initramfs does not enable systemd-modules-load.service"
dropin=usr/lib/systemd/system/ostree-prepare-root.service.d/10-microos-remap.conf
for f in usr/lib/ostree/ostree-prepare-root usr/libexec/microos/prepare-root usr/bin/sh usr/bin/realpath usr/bin/mkdir "$dropin"; do
  grep -qE " $f( |$)" <<< "$list" || fail "initramfs lacks $f"
done
! grep -qE "/kernel/drivers/gpu/" <<< "$list" || fail "initramfs has a GPU module"
(( $(stat -c %s "$img") <= 15728640 )) || fail "initramfs is $(stat -c %s "$img") bytes, over 15728640"
[[ $(lsinitrd -f "$dropin" "$img") == $'[Service]\nExecStart=\nExecStart=/usr/libexec/microos/prepare-root' ]] || fail "remap drop-in content"
for f in usr/libexec/microos/microos-guard usr/libexec/microos/microos-initrd-log usr/libexec/microos/microos-sdam \
  usr/lib/systemd/system/microos-guard.service etc/microos-initrd-id usr/lib/systemd/system/emergency.service.d/10-microos.conf \
  usr/lib/systemd/system/dracut-emergency.service.d/10-microos.conf; do
  grep -qE " $f( |$)" <<< "$list" || fail "initramfs lacks $f"
done
grep -qE "/initrd\.target\.wants/microos-guard\.service( |$)" <<< "$list" || fail "initramfs does not enable microos-guard.service"
for f in usr/libexec/microos/microos-usb-console usr/libexec/microos/microos-initrd-usbcon usr/lib/systemd/system/microos-initrd-usbcon.service; do
  grep -qE " $f( |$)" <<< "$list" || fail "initramfs lacks $f"
done
grep -qE "/sysinit\.target\.wants/microos-initrd-usbcon\.service( |$)" <<< "$list" || fail "initramfs does not enable microos-initrd-usbcon.service"
unpack=$(mktemp -d)
(cd "$unpack" && lsinitrd --unpack "$img" usr/lib/systemd/system/emergency.service.d/10-microos.conf \
  usr/lib/systemd/system/dracut-emergency.service.d/10-microos.conf)
for u in emergency dracut-emergency; do
  [[ $(< "$unpack/usr/lib/systemd/system/$u.service.d/10-microos.conf") == \
    $'[Unit]\nAfter=microos-guard.service\n\n[Service]\nExecStartPre=-/usr/libexec/microos/microos-initrd-log' ]] ||
    fail "initramfs $u drop-in content"
done
rm -rf "${unpack:?}"
grep -qE "/nvmem_qcom-spmi-sdam\.ko" <<< "$list" || fail "initramfs lacks nvmem_qcom-spmi-sdam"
for f in usr/libexec/microos/microos-bootb usr/lib/microos/slot.conf usr/bin/sha256sum usr/bin/stat usr/bin/readlink "usr/s?bin/blockdev"; do
  grep -qE " $f( |$)" <<< "$list" || fail "initramfs lacks $f"
done
unpack=$(mktemp -d)
d='usr/lib/systemd/system/dev-disk-by?x2dpartlabel'
(cd "$unpack" && lsinitrd --unpack "$img" "$d-microos_efi.device.d/10-microos.conf" "$d-boot_b.device.d/10-microos.conf" \
  "$d-boot_a.device.d/10-microos.conf")
for p in microos_efi boot_b boot_a; do
  [[ $(< "$unpack/usr/lib/systemd/system/dev-disk-by\\x2dpartlabel-$p.device.d/10-microos.conf") == \
    $'[Unit]\nJobRunningTimeoutSec=45' ]] || fail "initramfs $p device timeout"
done
rm -rf "${unpack:?}"
lsinitrd -f usr/lib/systemd/system/microos-guard.service "$img" | grep -qx 'TimeoutStartSec=180' || fail "microos-guard.service timeout"
[[ $(lsinitrd -f usr/lib/systemd/system.conf.d/50-microos.conf "$img") == $'[Manager]\nRuntimeWatchdogSec=30s\nRebootWatchdogSec=30s' ]] \
  || fail "initramfs system.conf.d 50-microos.conf"
[[ $(lsinitrd -f etc/cmdline.d/90-microos.conf "$img") == 'rd.shell=0 rd.emergency=reboot rd.timeout=90' ]] || fail "initramfs cmdline.d/90-microos.conf"
[[ $(lsinitrd -f usr/lib/systemd/system/initrd-switch-root.service.d/10-microos.conf "$img") == \
  $'[Service]\nExecStart=\nExecStart=systemctl --no-block switch-root /sysroot /usr/lib/systemd/systemd' ]] || fail "initramfs switch-root drop-in"
[[ $(lsinitrd -f etc/microos-initrd-id "$img") =~ ^$kver\ [0-9]{8}T[0-9]{6}Z$ ]] || fail "initramfs microos-initrd-id"
lsinitrd -f usr/lib/systemd/system/ostree-prepare-root.service "$img" | grep -qx 'ExecStart=/usr/lib/ostree/ostree-prepare-root /sysroot' \
  || fail "ostree-prepare-root.service ExecStart changed"
grep -qx microos-selinux-label <<< "$(lsinitrd -m "$img")" || fail "initramfs lacks the microos-selinux-label module"
grep -qE " usr/s?bin/setfiles( |$)" <<< "$list" || fail "initramfs lacks setfiles"
label=/usr/lib/dracut/modules.d/94microos-selinux-label/microos-selinux-label
[[ $(lsinitrd -f usr/libexec/microos/microos-selinux-label "$img" | sha256sum) == $(sha256sum < "$label") ]] \
  || fail "initramfs microos-selinux-label is not $label"
for l in 'unmount "$lmnt"' 'unmount "$emnt"'; do
  grep -qF "$l" "$label" || fail "$label has no $l"
done
grep -qx 'cap=270' "$label" || fail "$label /var cap is not 270 s"
st=$tmp/setfiles
sfc=/etc/selinux/targeted/contexts/files/file_contexts
mkdir -p "$st/dep/etc" "$st/var/lib/microos" "$st/var/log" "$st/boot/loader/entries"
cp /etc/passwd "$st/dep/etc/passwd"
: > "$st/var/lib/microos/state"
: > "$st/var/log/boot.log"
: > "$st/boot/loader/entries/ostree-1.conf"
setfiles -m -n -v -T 0 -r "$st/dep" "$sfc" "$st/dep/etc" > /dev/null || fail "setfiles refuses the /etc pass flags"
setfiles -m -n -v -r "$st/dep" "$sfc" "$st/dep/etc/passwd" > /dev/null || fail "setfiles refuses the /etc check flags"
setfiles -m -n -v -T 0 -r "$st" "$sfc" "$st/var/lib" > /dev/null || fail "setfiles refuses the /var path flags"
setfiles -m -n -v -T 0 -r "$st" -e "$st/var/lib" -e "$st/var/log" "$sfc" "$st/var" > /dev/null \
  || fail "setfiles refuses the /var walk flags"
setfiles -m -n -v -T 0 -r "$st" "$sfc" "$st/boot" > /dev/null || fail "setfiles refuses the /boot walk flags"
for u in etc var; do
  unit=$(lsinitrd -f "usr/lib/systemd/system/microos-selinux-label-$u.service" "$img")
  lines=(Type=oneshot DefaultDependencies=no 'After=ostree-prepare-root.service microos-guard.service' Before=initrd.target
    Conflicts=shutdown.target Before=shutdown.target WantedBy=initrd.target "ExecStart=/usr/libexec/microos/microos-selinux-label $u")
  if [[ $u == etc ]]; then
    lines+=(OnFailure=emergency.target OnFailureJobMode=replace-irreversibly TimeoutStartSec=120 RemainAfterExit=yes)
  else
    lines+=(After=microos-selinux-label-etc.service ConditionPathExists=/run/microos/selinux-label.env TimeoutStartSec=330
      TimeoutStopSec=60 RemainAfterExit=no 'ExecStopPost=/usr/libexec/microos/microos-selinux-label result')
    ! grep -q '^OnFailure' <<< "$unit" || fail "initramfs microos-selinux-label-var.service has an OnFailure= line"
  fi
  for l in "${lines[@]}"; do
    grep -qxF "$l" <<< "$unit" || fail "initramfs microos-selinux-label-$u.service lacks $l"
  done
  grep -qE "/initrd\.target\.wants/microos-selinux-label-$u\.service( |$)" <<< "$list" \
    || fail "initramfs does not enable microos-selinux-label-$u.service"
done

mod=/etc/selinux/targeted/active/modules/400/microos
[[ $(< "$mod/lang_ext") == cil ]] || fail "$mod is not a CIL module"
python3 -c 'import bz2, sys; sys.exit(bz2.decompress(open(sys.argv[1], "rb").read()) != open(sys.argv[2], "rb").read())' \
  "$mod/cil" /usr/share/selinux/packages/microos.cil || fail "$mod/cil is not /usr/share/selinux/packages/microos.cil"
[[ $(matchpathcon -n /run/microos/sddm-autologin.conf) == system_u:object_r:xdm_var_run_t:s0 ]] \
  || fail "file_contexts labels /run/microos/sddm-autologin.conf $(matchpathcon -n /run/microos/sddm-autologin.conf)"
[[ $(matchpathcon -n /run/microos/session-current) == system_u:object_r:var_run_t:s0 ]] \
  || fail "file_contexts labels /run/microos/session-current $(matchpathcon -n /run/microos/session-current)"
wmod=(/etc/selinux/targeted/active/modules/*/waydroid)
[[ ${#wmod[@]} == 1 && -f ${wmod[0]}/cil ]] || fail "the module store holds no single waydroid module: ${wmod[*]}"
for p in /var/lib/waydroid:waydroid_data_t /usr/lib/waydroid/waydroid.py:waydroid_exec_t /var/lib/microos-android:var_lib_t \
  /var/lib/microos-android/images:waydroid_data_t /var/lib/microos-android/images/current:waydroid_data_t \
  /var/lib/microos-android/images/los20-20260927-20261022/system.img:waydroid_data_t \
  /var/lib/misc/dnsmasq.waydroid0.leases:container_var_lib_t; do
  fc=$(matchpathcon -n "${p%%:*}")
  [[ $fc == "system_u:object_r:${p#*:}:s0" ]] || fail "file_contexts labels ${p%%:*} $fc"
done

[[ -x /usr/bin/microos-update ]] || fail "/usr/bin/microos-update missing"
scripts=()
for f in /usr/libexec/microos/* /usr/lib/microos/* /usr/lib/dracut/modules.d/91microos-ostree-remap/* /usr/bin/microos-*; do
  [[ -f $f ]] && scripts+=("$f")
done
etc=$(grep -nE '(^|[^[:alnum:]_.}-])/etc/' "${scripts[@]}" \
  | grep -vxE '/usr/bin/microos-update:[0-9]+:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/etc/containers/policy\.json' \
  | grep -vE '== /etc/\*' || true)
[[ -z $etc ]] || fail "MicroOS scripts reference /etc: $etc"

chmod 711 "$tmp"
esp=$tmp/esp
mkdir -p "$esp/microos"
printf '[connection]\nid=home\ntype=wifi\n' > "$esp/microos/home.nmconnection"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA test\n' > "$esp/microos/authorized_keys"
env MICROOS_ESP="$esp" MICROOS_RUNDIR="$tmp/run" MICROOS_NMDIR="$tmp/nm" MICROOS_HOME="$tmp/home" \
  /usr/libexec/microos/microos-provision >/dev/null || fail "provision failed"
[[ -z $(ls -A "$esp/microos") ]] || fail "provision left files on the ESP: $(ls -A "$esp/microos")"
[[ $(stat -c '%a %U' "$tmp/nm/home.nmconnection") == '600 root' ]] || fail "nmconnection mode"
[[ $(stat -c '%a %U' "$tmp/home/.ssh") == '700 micro' ]] || fail ".ssh mode"
[[ $(stat -c '%a %U' "$tmp/home/.ssh/authorized_keys") == '600 micro' ]] || fail "authorized_keys mode"
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
[[ ! -e $s/ostree/root.a && ! -e $s/ostree/root.b ]] || fail "no androidboot: aboot links written"

abl="androidboot.serialno=x androidboot.dtbo_idx=0"
remap "$ipath" "ostree=$good $base microos.deploy=$a $abl"
expect_unchanged "androidboot match"
for x in a b; do
  [[ $(readlink "$s/ostree/root.$x") == "deploy/default/deploy/$a" ]] || fail "androidboot match: root.$x is $(readlink "$s/ostree/root.$x")"
done
remap "$ipath" "ostree=/ostree/boot.1/default/$cb/1 $base microos.deploy=$a $abl"
expect_remap "androidboot remap" "ostree=$good $base microos.deploy=$a $abl" "/ostree/boot.1/default/$cb/1" "$good"
[[ $(readlink "$s/ostree/root.a") == "deploy/default/deploy/$a" ]] || fail "androidboot remap: root.a is $(readlink "$s/ostree/root.a")"
remap "$ipath" "ostree=/ostree/boot.1/default/$cb/1 $base $abl"
expect_unchanged "androidboot other deployment"
for x in a b; do
  [[ $(readlink "$s/ostree/root.$x") == "deploy/default/deploy/$b" ]] || fail "androidboot other: root.$x is $(readlink "$s/ostree/root.$x")"
done
[[ ! -e $s/ostree/root.a.tmp && ! -e $s/ostree/root.b.tmp ]] || fail "androidboot: tmp link left"
rm -f "$s/ostree/root.a" "$s/ostree/root.b"

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