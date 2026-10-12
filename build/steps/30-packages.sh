#!/usr/bin/env bash
set -euo pipefail

install -d /etc/dnf/libdnf5.conf.d
printf '[main]\ninstall_weak_deps=False\n' > /etc/dnf/libdnf5.conf.d/10-microos.conf

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
  dosfstools
