#!/usr/bin/env bash
set -euo pipefail

install -d /etc/dnf/libdnf5.conf.d
printf '[main]\ninstall_weak_deps=False\n' > /etc/dnf/libdnf5.conf.d/10-microos.conf
printf '[main]\nexcludepkgs=openh264\n' > /etc/dnf/libdnf5.conf.d/20-microos-openh264.conf

own=(
  inputplumber/inputplumber
  gamescope/gamescope
  gamescope-session/gamescope-session
  gamescope-session/gamescope-session-steam
  steamos-manager/steamos-manager
  mangohud/mangohud
  microset/microset
  microset/microset-recovery
  microset/microset-fonts
  hexagonrpc/hexagonrpc
  es-de/es-de
  microemu/microemu
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

pin=$(mktemp -d)
. /ctx/pins/pipewire-aptx.env
arch=$(uname -m)

pinned=("$(own_rpm pipewire-aptx/libfreeaptx)" "$(own_rpm pipewire-aptx/pipewire-codec-aptx)")
pin_rpms() {
  local pkg=$1 evr=$2 list=$3 name sum f have
  local -a want=()
  while read -r name sum; do
    if [[ -n $name ]]; then want+=("$name-$evr.$arch"); fi
  done <<<"$list"
  have=$(dnf -q repoquery --qf '%{name}-%{evr}.%{arch}\n' "${want[@]}")
  while read -r name sum; do
    [[ -n $name ]] || continue
    if grep -qxF "$name-$evr.$arch" <<<"$have"; then
      pinned+=("$name-$evr.$arch")
      continue
    fi
    [[ $arch == aarch64 ]] || { echo "30-packages: $name-$evr.$arch is not in the repos and SOURCE.env pins aarch64 RPMs only" >&2; exit 1; }
    f=$pin/$name-$evr.$arch.rpm
    curl -fsSL --retry 5 --retry-all-errors -o "$f" "$KOJI_URL/$pkg/${evr%%-*}/${evr#*-}/data/signed/$KOJI_KEY/$arch/$name-$evr.$arch.rpm"
    echo "$sum  $f" | sha256sum -c --quiet - || { echo "30-packages: $name-$evr.$arch from koji fails sha256" >&2; exit 1; }
    pinned+=("$f")
  done <<<"$list"
}
pin_rpms pipewire "$PIPEWIRE_EVR" "$PIPEWIRE_RPMS"
pin_rpms wireplumber "$WIREPLUMBER_EVR" "$WIREPLUMBER_RPMS"
dnf -y install "${pinned[@]}"
rm -rf "$pin"
printf '[main]\nexcludepkgs=pipewire*,wireplumber*\n' > /etc/dnf/libdnf5.conf.d/20-microos-pipewire.conf

if ! dnf -y install \
  android-tools \
  NetworkManager-wifi \
  wpa_supplicant \
  wireless-regdb \
  qcom-firmware \
  atheros-firmware \
  linux-firmware \
  cloud-utils-growpart \
  btrfs-progs \
  dosfstools \
  f3 \
  jq \
  noopenh264 \
  mesa-dri-drivers \
  mesa-vulkan-drivers \
  mesa-libgbm \
  mesa-libEGL \
  mesa-libGL \
  vulkan-loader \
  vulkan-tools \
  pulseaudio-utils \
  alsa-ucm \
  alsa-ucm-utils \
  alsa-utils \
  sddm \
  sddm-wayland-generic \
  plymouth \
  plymouth-scripts \
  plymouth-plugin-script \
  steam-devices \
  gtk2 \
  openal-soft \
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
  python3-gobject \
  python3-evdev \
  upower \
  rsync \
  retroarch \
  libretro-beetle-ngp \
  libretro-beetle-pce-fast \
  libretro-beetle-vb \
  libretro-beetle-wswan \
  libretro-bsnes-mercury \
  libretro-gambatte \
  libretro-gw \
  libretro-handy \
  libretro-mgba \
  libretro-nestopia \
  libretro-pcsx-rearmed \
  libretro-prosystem \
  libretro-stella2014 \
  gtk3 \
  python3-cairo \
  xprop \
  "${rpms[@]}"; then
  echo "30-packages: pipewire is pinned at $PIPEWIRE_EVR and wireplumber at $WIREPLUMBER_EVR; if a package needs newer ones, run packages/pipewire-aptx/bump.sh <pipewire EVR> <wireplumber EVR>" >&2
  exit 1
fi
