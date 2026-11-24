#!/usr/bin/env bash
set -euo pipefail

install -d /etc/dnf/libdnf5.conf.d
printf '[main]\ninstall_weak_deps=False\n' > /etc/dnf/libdnf5.conf.d/10-microos.conf

own=(
  audioreach-topology/audioreach-topology
  gamescope/gamescope
  gamescope-session-y700/gamescope-session
  gamescope-session-y700/gamescope-session-steam
  hexagonrpc/hexagonrpc
  microset/microset
  microset/microset-settings
  microset/microset-fonts
  hyprland/hyprland
  hyprland/hyprutils
  hyprland/hyprlang
  hyprland/hyprgraphics
  hyprland/hyprwire
  hyprland/aquamarine
  hyprland/hyprcursor
  hyprland-guiutils/hyprtoolkit
  hyprland-guiutils/hyprland-guiutils
  hyprgrass/hyprgrass
  hyprsunset/hyprsunset
  hyprpicker/hyprpicker
  xdg-desktop-portal-hyprland/xdg-desktop-portal-hyprland
  microos-fonts/microos-fonts
  android-guest-apks/microos-android-guest-apks
  android-guestos/microos-android-guestos
  microos-android/microos-android
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
  pipewire-utils \
  wireplumber \
  alsa-ucm \
  libcamera \
  libcamera-ipa \
  libcamera-tools \
  libcamera-qcam \
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
  quickshell \
  qt6-qtbase \
  qt6-qtdeclarative \
  qt6-qtwayland \
  qt6-qt5compat \
  qt6-qtsvg \
  qt6-qtimageformats \
  qt6-qtmultimedia \
  qt6-qtpositioning \
  qt6-qtshadertools \
  qt6-qtquicktimeline \
  qt6-qtsensors \
  qt6-qttools \
  qt6-qttranslations \
  qt6-qtvirtualkeyboard \
  kf6-kirigami \
  kf6-syntax-highlighting \
  kf6-kimageformats \
  kdialog \
  matugen \
  cava \
  cliphist \
  wl-clipboard \
  ydotool \
  wtype \
  brightnessctl \
  ddcutil \
  geoclue2 \
  grim \
  slurp \
  swappy \
  tesseract \
  tesseract-langpack-eng \
  fuzzel \
  ImageMagick \
  translate-shell \
  wlogout \
  qalculate \
  playerctl \
  pavucontrol-qt \
  NetworkManager \
  plasma-nm \
  bluedevil \
  gnome-keyring \
  polkit-kde \
  dolphin \
  plasma-systemsettings \
  xdg-desktop-portal \
  xdg-desktop-portal-gtk \
  xdg-desktop-portal-kde \
  adw-gtk3-theme \
  breeze-icon-theme \
  breeze-cursor-theme \
  kvantum \
  qt6ct \
  python3.12 \
  python3.12-devel \
  uv \
  python3-opencv \
  python3-pillow \
  python3-numpy \
  python3-cairo \
  python3-gobject \
  python3-dbus \
  python3-libsass \
  python3-pywayland \
  python3-psutil \
  yq \
  ripgrep \
  kitty \
  firefox \
  loupe \
  fish \
  eza \
  ffmpeg-free \
  cmake \
  ninja-build \
  glib2 \
  bc \
  xdg-user-dirs \
  curl \
  wget2 \
  unzip \
  waydroid \
  "${rpms[@]}"

rm /usr/share/applications/Waydroid.desktop /usr/share/applications/waydroid.market.desktop \
  /usr/share/applications/waydroid.app.install.desktop
install -d /usr/share/waydroid-extra
ln -s /var/lib/microos-android/images/current /usr/share/waydroid-extra/images

printf '[main]\nexcludepkgs=hyprland,hyprutils,hyprlang,hyprgraphics,hyprwire,hyprcursor,aquamarine,hyprgrass,hyprsunset,hyprpicker,xdg-desktop-portal-hyprland,hyprtoolkit,hyprland-guiutils,udis86\n' \
  > /etc/dnf/libdnf5.conf.d/20-microos-hyprland.conf
