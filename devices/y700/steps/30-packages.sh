#!/usr/bin/env bash
set -euo pipefail

install -d /etc/dnf/libdnf5.conf.d
printf '[main]\ninstall_weak_deps=False\n' > /etc/dnf/libdnf5.conf.d/10-microos.conf

own=(
  audioreach-topology/audioreach-topology
  gamescope/gamescope
  gamescope-session-y700/gamescope-session
  gamescope-session-y700/gamescope-session-steam
  microset/microset
  microset/microset-settings
  microset/microset-fonts
)

own_rpm() {
  local dir=/pkgs/${1%%/*} name=${1#*/} f found=()
  for f in "$dir"/*.rpm; do
    if [[ -f $f && $f != *.src.rpm && $(rpm -qp --qf '%{NAME}' "$f") == "$name" ]]; then
      found+=("$f")
    fi
  done
  (( ${#found[@]} == 1 )) || { echo "30-packages: expected one $name RPM in $dir, found ${#found[@]}" >&2; exit 1; }
  echo "${found[0]}"
}

rpms=()
for p in "${own[@]}"; do
  rpms+=("$(own_rpm "$p")")
done

dnf -y install \
  android-tools \
  btrfs-progs \
  dosfstools \
  jq \
  util-linux \
  rsync \
  dnsmasq \
  python3 \
  python3-gobject-base \
  chrony \
  NetworkManager-wifi \
  wpa_supplicant \
  wireless-regdb \
  atheros-firmware \
  qcom-firmware \
  linux-firmware \
  mesa-dri-drivers \
  mesa-vulkan-drivers \
  mesa-libgbm \
  mesa-libEGL \
  mesa-libGL \
  vulkan-loader \
  vulkan-tools \
  sddm \
  sddm-wayland-generic \
  steam-devices \
  dbus-tools \
  gtk2 \
  gtk3 \
  openal-soft \
  pipewire \
  pipewire-pulseaudio \
  pipewire-alsa \
  wireplumber \
  alsa-ucm \
  sdl2-compat \
  libXcomposite \
  libXdamage \
  libXfixes \
  libXi \
  libXinerama \
  libXrandr \
  libXrender \
  libXtst \
  libSM \
  libICE \
  at-spi2-atk \
  cups-libs \
  libssh2 \
  libva \
  libvdpau \
  google-noto-sans-cjk-vf-fonts \
  google-noto-color-emoji-fonts \
  google-noto-sans-arabic-vf-fonts \
  google-noto-sans-hebrew-vf-fonts \
  google-noto-sans-thai-vf-fonts \
  google-noto-sans-devanagari-vf-fonts \
  google-noto-sans-mono-vf-fonts \
  upower \
  procps-ng \
  bluez \
  e2fsprogs \
  zstd \
  "${rpms[@]}"
