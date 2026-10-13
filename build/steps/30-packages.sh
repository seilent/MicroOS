#!/usr/bin/env bash
set -euo pipefail

install -d /etc/dnf/libdnf5.conf.d
printf '[main]\ninstall_weak_deps=False\n' > /etc/dnf/libdnf5.conf.d/10-microos.conf

own=(
  inputplumber/inputplumber
)

rpms=()
for p in "${own[@]}"; do
  dir=/pkgs/${p%%/*}
  name=${p#*/}
  found=()
  for f in "$dir"/*.rpm; do
    if [[ -f $f && $f != *.src.rpm && $(rpm -qp --qf '%{NAME}' "$f") == "$name" ]]; then
      found+=("$f")
    fi
  done
  (( ${#found[@]} == 1 )) || { echo "30-packages: expected one $name RPM in $dir, found ${#found[@]}" >&2; exit 1; }
  rpms+=("${found[0]}")
done

dnf -y install \
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
  mesa-dri-drivers \
  mesa-vulkan-drivers \
  mesa-libgbm \
  mesa-libEGL \
  mesa-libGL \
  vulkan-loader \
  vulkan-tools \
  pipewire \
  pipewire-alsa \
  pipewire-pulseaudio \
  pipewire-utils \
  pulseaudio-utils \
  wireplumber \
  alsa-ucm \
  alsa-ucm-utils \
  alsa-utils \
  "${rpms[@]}"
