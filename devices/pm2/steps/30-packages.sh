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
  lsfg-vk/lsfg-vk
  microset/microset
  microset/microset-recovery
  microset/microset-settings
  microset/microset-launcher
  microset/microset-store
  microset/microset-fonts
  hexagonrpc/hexagonrpc
  microos-eq/microos-eq
  microdap/microdap
  es-de/es-de
  microemu/microemu
  plymouth/plymouth
  plymouth/plymouth-core-libs
  plymouth/plymouth-graphics-libs
  plymouth/plymouth-plugin-script
  plymouth/plymouth-scripts
  android-guest-apks/microos-android-guest-apks
  android-guestos/microos-android-guestos
  microos-android/microos-android
  rocknix-abl/rocknix-abl
  hyprland/hyprland
  hyprland/hyprutils
  hyprland/hyprlang
  hyprland/hyprgraphics
  hyprland/hyprwire
  hyprland/aquamarine
  hyprland/hyprcursor
  hyprgrass/hyprgrass
  wvkbd/wvkbd
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
  steam-devices \
  dbus-tools \
  bluez-obexd \
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
  gstreamer1 \
  gstreamer1-plugins-base \
  gstreamer1-plugins-good \
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
  mako \
  foot \
  grim \
  flatpak \
  xdg-desktop-portal \
  xdg-desktop-portal-wlr \
  xdg-desktop-portal-gtk \
  podman \
  passt \
  catatonit \
  attr \
  util-linux \
  util-linux-core \
  procps-ng \
  ncurses \
  iproute \
  inotify-tools \
  which \
  e2fsprogs \
  unzip \
  waydroid \
  "${rpms[@]}"; then
  echo "30-packages: pipewire is pinned at $PIPEWIRE_EVR and wireplumber at $WIREPLUMBER_EVR; if a package needs newer ones, run packages/pipewire-aptx/bump.sh <pipewire EVR> <wireplumber EVR>" >&2
  exit 1
fi

rm /usr/share/applications/Waydroid.desktop /usr/share/applications/waydroid.market.desktop \
  /usr/share/applications/waydroid.app.install.desktop
install -d /usr/share/waydroid-extra
ln -s /var/lib/microos-android/images/current /usr/share/waydroid-extra/images
printf '%s\n' 'lxc.cgroup2.devices.allow = a' 'lxc.cgroup2.devices.deny = b *:* rwm' \
  'lxc.cgroup2.devices.deny = c 1:1 rwm' 'lxc.cgroup2.devices.deny = c 1:4 rwm' >> /usr/lib/waydroid/data/configs/config_base
python3 - /usr/lib/waydroid/tools/interfaces/IHardware.py <<'PY'
import sys

path = sys.argv[1]
reply = "        reader = req.init_reader()\n        local_response = response.new_reply()\n"
gate = ("        euid = req.sender_euid()\n"
        "        if euid not in (0, 1000) or code in (TRANSACTION_upgrade, TRANSACTION_upgrade2):\n"
        "            logging.warning(\"{}: refused call {} from uid {}\".format(SERVICE_NAME, code, euid))\n"
        "            return local_response, -1\n")
with open(path) as handle:
    text = handle.read()
if text.count(reply) != 1:
    sys.exit(f"{path}: the reply lines are not there once")
with open(path, "w") as handle:
    handle.write(text.replace(reply, reply + gate))
PY
rm /usr/lib/waydroid/tools/interfaces/__pycache__/IHardware.*.pyc

printf '[main]\nexcludepkgs=hyprland,hyprutils,hyprlang,hyprgraphics,hyprwire,hyprcursor,aquamarine,hyprgrass,udis86\n' \
  > /etc/dnf/libdnf5.conf.d/20-microos-hyprland.conf
