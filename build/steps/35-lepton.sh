#!/usr/bin/env bash
set -euo pipefail

rpms=(/lepton/rpms/lepton-guestos-*.aarch64.rpm /lepton/rpms/lepton-armada-*.aarch64.rpm)
for f in "${rpms[@]}"; do
  [[ -f $f ]] || { echo "35-lepton: missing $f" >&2; exit 1; }
done
dnf -y install "${rpms[@]}" patch which
systemctl enable usr-share-guestos-android.mount
