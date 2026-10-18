#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: pkg-kernel.sh <rpmdir>}
here=$(cd "$(dirname "$0")" && pwd)
rpm=$(find "$out" -name 'microos-kernel-[0-9]*.aarch64.rpm' | head -1)
[[ -n $rpm ]] || { echo "pkg-kernel: no microos-kernel rpm in $out" >&2; exit 1; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
rpm2cpio "$rpm" | (cd "$root" && cpio -idm --quiet)

mods=("$root"/usr/lib/modules/*)
[[ ${#mods[@]} -eq 1 && -d ${mods[0]} ]] || { echo "pkg-kernel: expected one modules dir" >&2; exit 1; }
kdir=${mods[0]}
[[ $(basename "$kdir") == *-microos ]] || { echo "pkg-kernel: modules dir $(basename "$kdir")" >&2; exit 1; }
[[ $(head -c 64 "$kdir/vmlinuz" | tail -c 8 | od -An -c | tr -d ' ') == ARMd* ]] || { echo "pkg-kernel: vmlinuz is not a raw arm64 Image" >&2; exit 1; }
dtbs=$(find "$kdir/dtb" -name '*.dtb')
[[ $dtbs == "$kdir/dtb/qcom/sm8250-ayaneo-pocket-micro2.dtb" ]] || { echo "pkg-kernel: unexpected dtb set: $dtbs" >&2; exit 1; }

builtin=(
  PINCTRL_SM8250 SM_DISPCC_8250 INTERCONNECT_QCOM_SM8250 QCOM_LLCC
  DRM DRM_KMS_HELPER DRM_DISPLAY_HELPER DRM_SCHED DRM_GPUVM DRM_EXEC DRM_MIPI_DSI
  DRM_MSM DRM_MSM_MDSS DRM_MSM_DPU DRM_MSM_DSI DRM_MSM_DSI_7NM_PHY DRM_MSM_DP
  DRM_PANEL_AYANEO_AR18 REGULATOR_QCOM_LCDB REGULATOR_QCOM_REFGEN
  BACKLIGHT_CLASS_DEVICE BACKLIGHT_QCOM_WLED FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER
  LEDS_CLASS_MULTICOLOR QCOM_PBS LEDS_QCOM_LPG SENSORS_PWM_FAN
  PHY_QCOM_QMP_COMBO DRM_AUX_BRIDGE DRM_AUX_HPD_BRIDGE
  TYPEC TYPEC_TCPM TYPEC_QCOM_PMIC TYPEC_MUX_GPIO_SBU REGULATOR_QCOM_USB_VBUS
  FTRACE TRACING EVENT_TRACING TRACEPOINTS PM_DEBUG PM_SLEEP_DEBUG HIDRAW NTSYNC LRU_GEN_ENABLED
  SECURITY_YAMA HOTPLUG_PCI_PCIE
)
for s in "${builtin[@]}"; do
  grep -qx "CONFIG_$s=y" "$kdir/config" || { echo "pkg-kernel: CONFIG_$s is not built in" >&2; exit 1; }
done

grep -qE '^CONFIG_LSM="([^"]*,)?yama(,[^"]*)?"$' "$kdir/config" || { echo "pkg-kernel: CONFIG_LSM lacks yama: $(grep '^CONFIG_LSM=' "$kdir/config")" >&2; exit 1; }

for m in snd-seq joydev hid-playstation hid-sony hid-nintendo hid-microsoft xpad zram exfat ntfs3; do
  find "$kdir" -name "$m.ko*" | grep -q . || { echo "pkg-kernel: module $m missing" >&2; exit 1; }
done

"$here/pkg-kernel/dts-drivers.sh" "$dtbs" "$kdir/config"
"$here/pkg-kernel/gpu-opp.sh" "$dtbs" >/dev/null
"$here/pkg-kernel/fan-trips.sh" "$dtbs"
echo "pkg-kernel: $(basename "$rpm") ok"
