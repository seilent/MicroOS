#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: pkg-kernel-y700.sh <rpmdir>}
here=$(cd "$(dirname "$0")" && pwd)
rpm=$(find "$out" -name 'microos-kernel-[0-9]*.aarch64.rpm' | head -1)
[[ -n $rpm ]] || { echo "pkg-kernel-y700: no microos-kernel rpm in $out" >&2; exit 1; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
rpm2cpio "$rpm" > "$root/kernel.cpio"
(cd "$root" && cpio -idm --quiet < kernel.cpio)
rm "$root/kernel.cpio"

mods=("$root"/usr/lib/modules/*)
[[ ${#mods[@]} -eq 1 && -d ${mods[0]} ]] || { echo "pkg-kernel-y700: expected one modules dir" >&2; exit 1; }
kdir=${mods[0]}
[[ $(basename "$kdir") == *-microos ]] || { echo "pkg-kernel-y700: modules dir $(basename "$kdir")" >&2; exit 1; }
[[ $(head -c 64 "$kdir/vmlinuz" | tail -c 8 | od -An -c | tr -d ' ') == ARMd* ]] || { echo "pkg-kernel-y700: vmlinuz is not a raw arm64 Image" >&2; exit 1; }
dtbs=$(find "$kdir/dtb" -name '*.dtb' | sort)
want=$(printf '%s\n' "$kdir/dtb/qcom/sm8650-lenovo-tb321fu-abl.dtb" "$kdir/dtb/qcom/sm8650-lenovo-tb321fu-csot.dtb" "$kdir/dtb/qcom/sm8650-lenovo-tb321fu.dtb")
[[ $dtbs == "$want" ]] || { echo "pkg-kernel-y700: unexpected dtb set: $dtbs" >&2; exit 1; }

builtin=(
  PINCTRL_SM8650 SM_GCC_8650 SM_TCSRCC_8650 SM_DISPCC_8550 SM_GPUCC_8650 USB_ROLES_GPIO_USB2_PORT_MUX INTERCONNECT_QCOM_SM8650 QCOM_LLCC
  DRM DRM_KMS_HELPER DRM_DISPLAY_HELPER DRM_SCHED DRM_GPUVM DRM_EXEC DRM_MIPI_DSI
  DRM_MSM DRM_MSM_MDSS DRM_MSM_DPU DRM_MSM_DSI DRM_MSM_DSI_7NM_PHY DRM_MSM_DP DRM_DISPLAY_DSC_HELPER
  DRM_PANEL_NOVATEK_NT36523 BACKLIGHT_CLASS_DEVICE BACKLIGHT_KTZ8866 REGULATOR_AW37503 FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER
  I2C_QCOM_GENI QCOM_GPI_DMA SCSI_UFS_QCOM PHY_QCOM_QMP_UFS QCOM_PMIC_GLINK UCSI_PMIC_GLINK
  PHY_QCOM_QMP_COMBO DRM_AUX_BRIDGE DRM_AUX_HPD_BRIDGE TYPEC TYPEC_MUX_PS5169 TYPEC_MUX_FSA4480
  FTRACE TRACING EVENT_TRACING TRACEPOINTS PM_DEBUG PM_SLEEP_DEBUG HIDRAW NTSYNC LRU_GEN_ENABLED
  SECURITY_YAMA HOTPLUG_PCI_PCIE UCLAMP_TASK UCLAMP_TASK_GROUP CGROUP_BPF BPF_SYSCALL
  NETFILTER_NETLINK IP_ADVANCED_ROUTER IP_MULTIPLE_TABLES IPV6_MULTIPLE_TABLES FIB_RULES
  EFI EFI_STUB PANIC_ON_OOPS DEVMEM NVMEM_SYSFS
  USB_CONFIGFS USB_LIBCOMPOSITE USB_F_ACM USB_F_NCM USB_CONFIGFS_ACM PHY_SNPS_EUSB2 PHY_NXP_PTN3222
)
for s in "${builtin[@]}"; do
  grep -qx "CONFIG_$s=y" "$kdir/config" || { echo "pkg-kernel-y700: CONFIG_$s is not built in" >&2; exit 1; }
done

grep -qE '^CONFIG_LSM="([^"]*,)?yama(,[^"]*)?"$' "$kdir/config" || { echo "pkg-kernel-y700: CONFIG_LSM lacks yama: $(grep '^CONFIG_LSM=' "$kdir/config")" >&2; exit 1; }
grep -qx 'CONFIG_PANIC_TIMEOUT=10' "$kdir/config" || { echo "pkg-kernel-y700: CONFIG_PANIC_TIMEOUT is not 10: $(grep '^CONFIG_PANIC_TIMEOUT=' "$kdir/config")" >&2; exit 1; }
grep -qx '# CONFIG_RTC_DRV_EFI is not set' "$kdir/config" || { echo "pkg-kernel-y700: CONFIG_RTC_DRV_EFI is set" >&2; exit 1; }
grep -qx '# CONFIG_RTC_HCTOSYS is not set' "$kdir/config" || { echo "pkg-kernel-y700: CONFIG_RTC_HCTOSYS is set" >&2; exit 1; }
grep -qx 'CONFIG_GUNYAH_WATCHDOG=y' "$kdir/config" || { echo "pkg-kernel-y700: CONFIG_GUNYAH_WATCHDOG is not built in" >&2; exit 1; }

for m in snd-seq joydev hid-playstation hid-sony hid-nintendo xpad zram exfat ntfs3 nfnetlink_log btrfs nvmem_qcom-spmi-sdam \
  snd-soc-wcd939x novatek-nt36523 aw86927 snd-soc-aw88261 snd-soc-sc8280xp \
  qcom_battmgr snd-soc-wcd939x-sdw soundwire-qcom snd-soc-lpass-rx-macro snd-soc-lpass-tx-macro rtc-pm8xxx; do
  find "$kdir" -name "$m.ko*" | grep -q . || { echo "pkg-kernel-y700: module $m missing" >&2; exit 1; }
done

for d in $dtbs; do
  "$here/pkg-kernel-y700/dts-drivers.sh" "$d" "$kdir/config"
done

abl=$kdir/dtb/qcom/sm8650-lenovo-tb321fu-abl.dtb
[[ $(fdtget -t x "$abl" / qcom,msm-id) == "241 20000" ]] || { echo "pkg-kernel-y700: abl dtb msm-id" >&2; exit 1; }
[[ $(fdtget -t x "$abl" / qcom,board-id) == "0 0" ]] || { echo "pkg-kernel-y700: abl dtb board-id" >&2; exit 1; }
[[ $(fdtget "$abl" / region_country) == PRC ]] || { echo "pkg-kernel-y700: abl dtb region_country" >&2; exit 1; }
[[ $(fdtget -t x "$abl" /reserved-memory/splash_region reg) == "0 d5100000 0 2b00000" ]] || { echo "pkg-kernel-y700: abl dtb splash_region" >&2; exit 1; }
[[ $(fdtget -t x "$abl" /reserved-memory/ramoops@a2000000 record-size) == 80000 && $(fdtget -t x "$abl" /reserved-memory/ramoops@a2000000 console-size) == 200000 && $(fdtget -t x "$abl" /reserved-memory/ramoops@a2000000 mem-type) == 1 ]] || { echo "pkg-kernel-y700: abl dtb ramoops sizes or mem-type" >&2; exit 1; }
! fdtget "$abl" /reserved-memory/ramoops@a2000000 pmsg-size > /dev/null 2>&1 || { echo "pkg-kernel-y700: abl dtb ramoops has pmsg-size" >&2; exit 1; }
[[ $(fdtget "$abl" /chosen/framebuffer@d5100000 status) == okay ]] || { echo "pkg-kernel-y700: abl dtb framebuffer" >&2; exit 1; }
[[ $(fdtget "$abl" /soc@0/spmi@c400000/pmic@0/nvram@7100 compatible) == qcom,spmi-sdam ]] || { echo "pkg-kernel-y700: abl dtb sdam nvram@7100" >&2; exit 1; }
[[ $(fdtget "$abl" /aliases serial1) == /soc@0/geniqup@8c0000/serial@898000 ]] || { echo "pkg-kernel-y700: abl dtb serial1 alias" >&2; exit 1; }
[[ $(fdtget -p "$abl" /__symbols__ | wc -l) -ge 1634 ]] || { echo "pkg-kernel-y700: abl dtb symbols" >&2; exit 1; }
mdss=$(fdtget -t x "$abl" /soc@0/display-subsystem@ae00000 phandle)
splash=$(fdtget -t x "$abl" /reserved-memory/splash_region phandle)
[[ $(fdtget -t x "$abl" /reserved-memory/splash_region iommu-addresses) == "$mdss 0 d5100000 0 2b00000" ]] || { echo "pkg-kernel-y700: abl dtb splash iommu-addresses" >&2; exit 1; }
[[ $(fdtget -t x "$abl" /soc@0/display-subsystem@ae00000 memory-region) == "$splash" ]] || { echo "pkg-kernel-y700: abl dtb mdss memory-region" >&2; exit 1; }

for s in lenovo,tb321fu-boe-nt36523 lenovo,tb321fu-csot-nt36523 kinetic,ovp-microvolt kinetic,inductor-nanohenry; do
  grep -qaF "$s" "$kdir/vmlinuz" || { echo "pkg-kernel-y700: vmlinuz lacks $s" >&2; exit 1; }
done

main=$kdir/dtb/qcom/sm8650-lenovo-tb321fu.dtb
csot=$kdir/dtb/qcom/sm8650-lenovo-tb321fu-csot.dtb
bl=/soc@0/geniqup@8c0000/i2c@888000/backlight@11
disp=/soc@0/display-subsystem@ae00000
panel=$disp/dsi@ae94000/panel@0
for d in "$main" "$csot" "$abl"; do
  n=$(basename "$d")
  [[ $(fdtget "$d" /soc@0/crypto@1dfa000 status) == disabled ]] || { echo "pkg-kernel-y700: $n crypto engine not disabled" >&2; exit 1; }
  for dsi in dsi@ae94000 dsi@ae96000; do
    fdtget "$d" "$disp/$dsi" qcom,dual-dsi-mode > /dev/null && fdtget "$d" "$disp/$dsi" qcom,sync-dual-dsi > /dev/null ||
      { echo "pkg-kernel-y700: $n $dsi is not dual sync DSI" >&2; exit 1; }
    [[ $(fdtget "$d" "$disp/$dsi/ports/port@1/endpoint" data-lanes) == "0 1 2" ]] || { echo "pkg-kernel-y700: $n $dsi data-lanes" >&2; exit 1; }
  done
  fdtget "$d" "$disp/dsi@ae94000" qcom,master-dsi > /dev/null || { echo "pkg-kernel-y700: $n dsi0 is not the master" >&2; exit 1; }
  ! fdtget "$d" "$disp/dsi@ae96000" qcom,master-dsi > /dev/null 2>&1 || { echo "pkg-kernel-y700: $n dsi1 is a master" >&2; exit 1; }
  for phy in phy@ae95000 phy@ae97000; do
    [[ $(fdtget "$d" "$disp/$phy" phy-type) == 11 ]] || { echo "pkg-kernel-y700: $n $phy is not C-PHY" >&2; exit 1; }
  done
  for sup in vddio-supply vci-supply vdd-supply; do
    fdtget "$d" "$panel" "$sup" > /dev/null || { echo "pkg-kernel-y700: $n panel has no $sup" >&2; exit 1; }
  done
  [[ $(fdtget -t x "$d" "$panel" vddio-supply) == "$(fdtget -t x "$d" /regulator-panel-iovdd phandle)" ]] ||
    { echo "pkg-kernel-y700: $n panel vddio is not the IOVDD switch" >&2; exit 1; }
  for node in /soc@0/clock-controller@af00000 /soc@0/display-subsystem@ae00000 "$bl" /soc@0/geniqup@8c0000/i2c@888000/regulator@3e; do
    [[ $(fdtget -d okay "$d" "$node" status) == okay ]] || { echo "pkg-kernel-y700: $n $node is off" >&2; exit 1; }
  done
  v="$(fdtget "$d" "$bl" kinetic,ovp-microvolt) $(fdtget "$d" "$bl" kinetic,inductor-nanohenry)"
  v+=" $(fdtget "$d" "$bl" led-max-microamp) $(fdtget "$d" "$bl" current-num-sinks)"
  [[ $v == "34000000 4700 15600 4" ]] || { echo "pkg-kernel-y700: $n ktz8866 settings $v" >&2; exit 1; }
done
[[ $(fdtget "$main" "$panel" compatible) == "lenovo,tb321fu-boe-nt36523 novatek,nt36523" ]] || { echo "pkg-kernel-y700: main dtb panel" >&2; exit 1; }
[[ $(fdtget "$abl" "$panel" compatible) == "lenovo,tb321fu-boe-nt36523 novatek,nt36523" ]] || { echo "pkg-kernel-y700: abl dtb panel" >&2; exit 1; }
[[ $(fdtget "$csot" "$panel" compatible) == "lenovo,tb321fu-csot-nt36523 novatek,nt36523" ]] || { echo "pkg-kernel-y700: csot dtb panel" >&2; exit 1; }

spi=/soc@0/geniqup@ac0000/spi@a90000
ts=$spi/touchscreen@0
for d in "$main" "$csot" "$abl"; do
  n=$(basename "$d")
  [[ $(fdtget -d okay "$d" "$spi" status) == okay ]] || { echo "pkg-kernel-y700: $n spi4 is off" >&2; exit 1; }
  [[ $(fdtget "$d" "$ts" compatible) == novatek,nt36523-ts ]] || { echo "pkg-kernel-y700: $n touchscreen compatible" >&2; exit 1; }
  [[ $(fdtget -t x "$d" "$ts" panel) == "$(fdtget -t x "$d" "$panel" phandle)" ]] || { echo "pkg-kernel-y700: $n touchscreen panel" >&2; exit 1; }
  v="$(fdtget "$d" "$ts" touchscreen-size-x) $(fdtget "$d" "$ts" touchscreen-size-y) $(fdtget "$d" "$ts" touchscreen-x-mm)"
  v+=" $(fdtget "$d" "$ts" touchscreen-y-mm) $(fdtget "$d" "$ts" spi-max-frequency)"
  [[ $v == "16000 25600 118 190 9600000" ]] || { echo "pkg-kernel-y700: $n touchscreen settings $v" >&2; exit 1; }
  fdtget "$d" "$ts" touchscreen-inverted-x > /dev/null && fdtget "$d" "$ts" touchscreen-swapped-x-y > /dev/null ||
    { echo "pkg-kernel-y700: $n touchscreen orientation" >&2; exit 1; }
  ! fdtget "$d" "$ts" touchscreen-inverted-y > /dev/null 2>&1 || { echo "pkg-kernel-y700: $n touchscreen inverts y" >&2; exit 1; }
done
fw=qcom/sm8650/lenovo/tb321fu/novatek_ts
[[ $(fdtget "$main" "$ts" firmware-name) == "${fw}_boe_fw.bin" ]] || { echo "pkg-kernel-y700: main dtb touch firmware" >&2; exit 1; }
[[ $(fdtget "$abl" "$ts" firmware-name) == "${fw}_boe_fw.bin" ]] || { echo "pkg-kernel-y700: abl dtb touch firmware" >&2; exit 1; }
[[ $(fdtget "$csot" "$ts" firmware-name) == "${fw}_csot_fw.bin" ]] || { echo "pkg-kernel-y700: csot dtb touch firmware" >&2; exit 1; }

i2c7=/soc@0/geniqup@ac0000/i2c@a9c000
i2c6=/soc@0/geniqup@ac0000/i2c@a98000
mux=$i2c6/typec-mux@30
glink=/pmic-glink/connector@0/ports
qmp=/soc@0/phy@88e8000/ports/port@0/endpoint
for d in "$main" "$csot" "$abl"; do
  n=$(basename "$d")
  [[ $(fdtget -d okay "$d" "$i2c7" status) == okay && $(fdtget "$d" "$i2c7" clock-frequency) == 1000000 ]] ||
    { echo "pkg-kernel-y700: $n i2c7" >&2; exit 1; }
  for v in "5a 92 127" "5b 88 119"; do
    read -r a irq rst <<<"$v"
    h=$i2c7/vibrator@$a
    [[ $(fdtget "$d" "$h" compatible) == "awinic,aw86937 awinic,aw86927" ]] || { echo "pkg-kernel-y700: $n vibrator@$a compatible" >&2; exit 1; }
    [[ $(fdtget "$d" "$h" interrupts-extended | cut -d' ' -f2-) == "$irq 2" ]] || { echo "pkg-kernel-y700: $n vibrator@$a irq" >&2; exit 1; }
    [[ $(fdtget "$d" "$h" reset-gpios | cut -d' ' -f2-) == "$rst 1" ]] || { echo "pkg-kernel-y700: $n vibrator@$a reset" >&2; exit 1; }
  done
  [[ $(fdtget -d okay "$d" "$mux" status) == okay && $(fdtget "$d" "$mux" compatible) == parade,ps5169 ]] ||
    { echo "pkg-kernel-y700: $n ps5169 is off" >&2; exit 1; }
  fdtget "$d" "$mux" orientation-switch > /dev/null && fdtget "$d" "$mux" retimer-switch > /dev/null ||
    { echo "pkg-kernel-y700: $n ps5169 switches" >&2; exit 1; }
  ep() { fdtget -t x "$d" "$1" phandle; }
  [[ $(fdtget -t x "$d" "$glink/port@1/endpoint" remote-endpoint) == "$(ep "$mux/ports/port@0/endpoint")" &&
    $(fdtget -t x "$d" "$mux/ports/port@1/endpoint" remote-endpoint) == "$(ep "$qmp")" &&
    $(fdtget -t x "$d" "$qmp" remote-endpoint) == "$(ep "$mux/ports/port@1/endpoint")" ]] ||
    { echo "pkg-kernel-y700: $n ps5169 graph" >&2; exit 1; }
  sbu=$i2c6/typec-mux@43
  [[ $(fdtget -d okay "$d" "$sbu" status) == okay && $(fdtget "$d" "$sbu" compatible) == fcs,fsa4480 &&
    $(fdtget -t x "$d" "$glink/port@2/endpoint@0" remote-endpoint) == "$(ep "$sbu/port/endpoint")" ]] ||
    { echo "pkg-kernel-y700: $n fsa4480 sbu graph" >&2; exit 1; }
  hs=/usb2-port-mux
  [[ $(fdtget "$d" $hs compatible) == gpio-usb2-port-mux && $(fdtget "$d" $hs select-gpios | cut -d' ' -f2-) == "58 0" ]] ||
    { echo "pkg-kernel-y700: $n usb2 port mux" >&2; exit 1; }
  [[ $(fdtget -t x "$d" "$glink/port@0/endpoint" remote-endpoint) == "$(ep $hs/usb2-port@0/port/endpoint)" &&
    $(fdtget -t x "$d" $hs/usb2-port@0/port/endpoint remote-endpoint) == "$(ep "$glink/port@0/endpoint")" &&
    $(fdtget -t x "$d" /pmic-glink/connector@1/ports/port@0/endpoint remote-endpoint) == "$(ep $hs/usb2-port@1/port/endpoint)" &&
    $(fdtget -t x "$d" $hs/usb2-port@1/port/endpoint remote-endpoint) == "$(ep /pmic-glink/connector@1/ports/port@0/endpoint)" &&
    $(fdtget -t x "$d" $hs/port/endpoint remote-endpoint) == "$(ep /soc@0/usb@a600000/ports/port@0/endpoint)" &&
    $(fdtget -t x "$d" /soc@0/usb@a600000/ports/port@0/endpoint remote-endpoint) == "$(ep $hs/port/endpoint)" ]] ||
    { echo "pkg-kernel-y700: $n usb2 hs graph" >&2; exit 1; }
  fdtget "$d" $hs/usb2-port@0 usb-role-switch > /dev/null && fdtget "$d" $hs/usb2-port@1 usb-role-switch > /dev/null ||
    { echo "pkg-kernel-y700: $n usb2 port mux role switches" >&2; exit 1; }
  [[ $(fdtget "$d" /soc@0/usb@a600000 dr_mode) == otg ]] && fdtget "$d" /soc@0/usb@a600000 usb-role-switch > /dev/null ||
    { echo "pkg-kernel-y700: $n usb_1 otg role switch" >&2; exit 1; }
  [[ $(fdtget -d okay "$d" "$disp/displayport-controller@af54000" status) == disabled ]] || { echo "pkg-kernel-y700: $n dp0 is on" >&2; exit 1; }
done

i2c8=/soc@0/geniqup@8c0000/i2c@880000
dai=/soc@0/remoteproc@6800000/glink-edge/gpr/service@1/bedais/dai@28
link=/sound/speaker-tdm-dai-link
for d in "$main" "$csot" "$abl"; do
  n=$(basename "$d")
  [[ $(fdtget -d okay "$d" "$i2c8" status) == okay ]] || { echo "pkg-kernel-y700: $n i2c8 is off" >&2; exit 1; }
  for pa in "audio-codec@34 0 120 SpkrLeft" "audio-codec@37 1 128 SpkrRight"; do
    read -r node ch gpio prefix <<<"$pa"
    v="$(fdtget "$d" "$i2c8/$node" compatible) $(fdtget "$d" "$i2c8/$node" awinic,audio-channel)"
    v+=" $(fdtget "$d" "$i2c8/$node" firmware-name) $(fdtget "$d" "$i2c8/$node" sound-name-prefix)"
    v+=" $(fdtget "$d" "$i2c8/$node" reset-gpios | cut -d' ' -f2-)"
    [[ $v == "awinic,aw88461 $ch qcom/sm8650/lenovo/tb321fu/aw882xx_acf.bin $prefix $gpio 1" ]] || { echo "pkg-kernel-y700: $n $node $v" >&2; exit 1; }
  done
  [[ "$(fdtget "$d" /sound compatible) $(fdtget "$d" /sound model)" == "lenovo,tb321fu-sndcard Lenovo-Y700-TB321FU" ]] ||
    { echo "pkg-kernel-y700: $n sound card" >&2; exit 1; }
  v="$(fdtget "$d" "$link/cpu" sound-dai | cut -d' ' -f2) $(fdtget "$d" "$link/cpu" dai-tdm-slot-num)"
  v+=" $(fdtget "$d" "$link/cpu" dai-tdm-slot-width) $(fdtget "$d" "$link/cpu" dai-tdm-slot-rx-mask)"
  v+=" $(fdtget "$d" "$link/codec" dai-tdm-slot-rx-mask)"
  [[ $v == "40 8 32 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0" ]] || { echo "pkg-kernel-y700: $n speaker link $v" >&2; exit 1; }
  v="$(fdtget "$d" "$dai" reg) $(fdtget "$d" "$dai" clock-names) $(fdtget "$d" "$dai" clocks | cut -d' ' -f2-)"
  [[ $v == "40 bclk 37 1" ]] || { echo "pkg-kernel-y700: $n sec tdm dai $v" >&2; exit 1; }
done

codec=/audio-codec
rx=/soc@0/soundwire@6ad0000/codec@0,4
tx=/soc@0/soundwire@6d30000/codec@0,3
for d in "$main" "$csot" "$abl"; do
  n=$(basename "$d")
  v="$(fdtget "$d" "$codec" compatible) $(fdtget "$d" "$codec" reset-gpios | cut -d' ' -f2-)"
  for b in 1 2 3 4; do v+=" $(fdtget "$d" "$codec" "qcom,micbias$b-microvolt")"; done
  [[ $v == "qcom,wcd9390-codec 107 1 1800000 2700000 1800000 1800000" ]] || { echo "pkg-kernel-y700: $n wcd939x $v" >&2; exit 1; }
  fdtget "$d" "$codec" mode-switch > /dev/null || { echo "pkg-kernel-y700: $n wcd939x is not a mode switch" >&2; exit 1; }
  [[ $(fdtget -t x "$d" "$glink/port@2/endpoint@1" remote-endpoint) == "$(ep "$codec/port/endpoint")" &&
    $(fdtget -t x "$d" "$codec/port/endpoint" remote-endpoint) == "$(ep "$glink/port@2/endpoint@1")" ]] ||
    { echo "pkg-kernel-y700: $n wcd939x headset graph" >&2; exit 1; }
  for s in "$rx rx 1 2 3 4 5 9" "$tx tx 2 2 3 4"; do
    read -r node dir map <<<"$s"
    [[ $(fdtget -d okay "$d" "${node%/*}" status) == okay && $(fdtget "$d" "$node" compatible) == sdw20217010e00 &&
      $(fdtget "$d" "$node" "qcom,$dir-port-mapping") == "$map" &&
      $(fdtget -t x "$d" "$codec" "qcom,$dir-device") == "$(ep "$node")" ]] || { echo "pkg-kernel-y700: $n wcd939x $dir device" >&2; exit 1; }
  done
  v="$(fdtget "$d" /sound/wcd-playback-dai-link/cpu sound-dai | cut -d' ' -f2)"
  v+=" $(fdtget "$d" /sound/wcd-capture-dai-link/cpu sound-dai | cut -d' ' -f2)"
  [[ $v == "113 120" ]] || { echo "pkg-kernel-y700: $n wcd links $v" >&2; exit 1; }
done

dtbo=$kdir/dtb/qcom/sm8650-lenovo-tb321fu-dtbo.img
[[ -f $dtbo ]] || { echo "pkg-kernel-y700: dtbo image missing" >&2; exit 1; }
read -r magic _ hsize esize count eoff _ <<<"$(od -An -v -tx4 --endian=big -w28 -N28 "$dtbo")"
[[ "$magic $hsize $esize $count $eoff" == "d7b7ab1e 00000020 00000020 00000001 00000020" ]] || { echo "pkg-kernel-y700: dtbo header" >&2; exit 1; }
read -r dsize doff <<<"$(od -An -v -tu4 --endian=big -j32 -N8 "$dtbo")"
work=$root/dtbo
mkdir "$work"
dd if="$dtbo" of="$work/o.dtb" bs=1 skip="$doff" count="$dsize" status=none
[[ $(fdtget -t x "$work/o.dtb" / qcom,msm-id) == "22d 20000 22d 10000 241 20000 241 10000" ]] || { echo "pkg-kernel-y700: dtbo msm-id" >&2; exit 1; }
[[ $(fdtget -t x "$work/o.dtb" / qcom,board-id) == "3000b 0" ]] || { echo "pkg-kernel-y700: dtbo board-id" >&2; exit 1; }
! fdtget "$work/o.dtb" / compatible >/dev/null 2>&1 || { echo "pkg-kernel-y700: dtbo sets the root compatible" >&2; exit 1; }
! fdtget "$work/o.dtb" / model >/dev/null 2>&1 || { echo "pkg-kernel-y700: dtbo sets the root model" >&2; exit 1; }
fdtoverlay -i "$abl" -o "$work/applied.dtb" "$work/o.dtb"
[[ $(fdtget "$work/applied.dtb" / compatible) == "lenovo,tb321fu qcom,sm8650" ]] || { echo "pkg-kernel-y700: abl dtb compatible after the dtbo" >&2; exit 1; }
echo "pkg-kernel-y700: $(basename "$rpm") ok"
