#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

if [[ -n ${CCACHE_DIR:-} ]]; then
  top=/var/tmp/microos-kernel
  rm -rf "$top"
  mkdir -p "$top"
else
  top=$(mktemp -d)
fi
trap 'rm -rf "$top"' EXIT

tarball=$top/linux-$KERNEL_VERSION.tar.xz
curl -fsSL --retry 3 -o "$tarball" "$KERNEL_URL"
echo "$KERNEL_SHA256  $tarball" | sha256sum -c -
tar -xf "$tarball" -C "$top"
tree=$top/linux-$KERNEL_VERSION

while read -r p; do
  patch -d "$tree" -p1 -F0 -N -s --no-backup-if-mismatch < "$src/patches/$p"
done < "$src/patches/series"

dts=sm8250-ayaneo-pocket-micro2
cp "$src/dts/$dts.dts" "$tree/arch/arm64/boot/dts/qcom/"

export ARCH=arm64 KBUILD_BUILD_USER=microos KBUILD_BUILD_HOST=microos
if [[ $(uname -m) != aarch64 ]]; then
  export CROSS_COMPILE=aarch64-linux-gnu-
fi
cc=${CROSS_COMPILE:-}gcc
if [[ -n ${CCACHE_DIR:-} ]] && command -v ccache >/dev/null; then
  ccache -M 5G >/dev/null
  cc="ccache $cc"
fi
mk=(make -C "$tree" --no-print-directory -j"$(nproc)" CC="$cc")

"${mk[@]}" -s defconfig
"$tree/scripts/kconfig/merge_config.sh" -m -O "$tree" "$tree/.config" "$src/pm2.config" >/dev/null
"${mk[@]}" -s olddefconfig
lost=$(grep -vxF -f "$tree/.config" "$src/pm2.config" || true)
if [[ -n $lost ]]; then
  echo "pm2.config lines missing from .config:" >&2
  echo "$lost" >&2
  exit 1
fi

"${mk[@]}" Image modules "qcom/$dts.dtb"

kver=$("${mk[@]}" -s kernelrelease)
if [[ $kver != "$KERNEL_VERSION-microos" ]]; then
  echo "kernelrelease is $kver, expected $KERNEL_VERSION-microos" >&2
  exit 1
fi

stage=$top/stage
moddir=$stage/usr/lib/modules/$kver
"${mk[@]}" -s INSTALL_MOD_PATH="$stage/usr" INSTALL_MOD_STRIP=1 modules_install
rm -f "$moddir/build" "$moddir/source"
install -Dm644 "$tree/arch/arm64/boot/Image" "$moddir/vmlinuz"
install -Dm644 "$tree/arch/arm64/boot/dts/qcom/$dts.dtb" "$moddir/dtb/qcom/$dts.dtb"
install -Dm644 "$tree/.config" "$moddir/config"
install -Dm644 "$tree/System.map" "$moddir/System.map"
install -Dm644 "$src/LICENSE.kernel" "$stage/usr/share/licenses/microos-kernel/LICENSE.kernel"

rpmbuild -bb --target aarch64 \
  --define "_topdir $top/rpm" \
  --define "kversion $KERNEL_VERSION" \
  --define "kver $kver" \
  --define "stage $stage" \
  "$src/microos-kernel.spec"

find "$top/rpm/RPMS" -name '*.rpm' -exec cp -t "$out" {} +
