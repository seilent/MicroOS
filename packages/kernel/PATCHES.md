# Kernel patches

Base: kernel.org `v7.2.6` (`SOURCE.env`). `patches/series` applies in order with `patch -p1 -F0`, zero fuzz.
`00NN` are third party, `01NN` are my PM2 patches. The PM2 DTS is `dts/sm8250-ayaneo-pocket-micro2.dts`, copied into
`arch/arm64/boot/dts/qcom/` by `build.sh`.

Provenance traced 2026-10-12. ROCKNIX means `ROCKNIX/distribution` at `next` `d59bdaa28908`, ROCKNIX-old means
`ROCKNIX/distribution-old` before the 2025-07-13 squash import. Patchwork is `patchwork.kernel.org`.

## Provenance

| Patch | Earliest origin | Author | Chain | Confidence |
|---|---|---|---|---|
| 0001 input: add Qualcomm SPMI haptics driver | linux-arm-msm v3 2/6, 2021-08-16, `20210816221931.1998187-3-caleb@connolly.tech` (series v1 2021-06-12 to v7 2022-10-15, never merged); boost GPIO and relaxed actuator check `lineageos-on-retroid/android_kernel_retroid_sm8250_ack` `51ef2f2ed1da`, 2024-11-24 | Casey Connolly (the file says Caleb Connolly); Teguh Sobirin | patchwork v3, Teguh's Retroid kernel, ROCKNIX-old `SD865/0008` 2024-11-30, ROCKNIX `SM8250/0009` | CONFIRMED. The copy is v3 plus Teguh's commit plus a `void remove()` conversion by an unknown rebaser |
| 0002 power: supply: add Qualcomm SMB5 charger and PM8150B fuel gauge | `qcom_fg`: Joel Selvaraj, 2021-02-03, `map220v/sm8150-mainline` `27f8b500c7a6` (`MODULE_AUTHOR` Casey Connolly, Joel Selvaraj, Yassine Oudjana); pm8150b support map220v, 2023-08-02, `50cf85d48047`; SMB5 charger Teguh Sobirin, 2024-11-20, `android_kernel_retroid_sm8250_ack` `71fae666971c` (`MODULE_AUTHOR` Casey Connolly) | Teguh Sobirin, Casey Connolly, Joel Selvaraj, Yassine Oudjana, map220v; later Nefirim (ROCKNIX `0393a000d2`, 2025-10-24, capacity scale), Xenocideend (ROCKNIX `1dc63e1531`, 2026-09-25, float voltage and charge current, committed by Jacob Cook, credit line says "with Claude Opus 5.5"), sunshineinabox (ROCKNIX `7b4da83200`, 2026-09-29, charge status) | sm8150-mainline, Teguh's Retroid kernel, ROCKNIX-old `SD865/0010` 2024-11-30, ROCKNIX `SM8250/0011` | PLAUSIBLE. The SMB5 driver's relation to Casey's mainline `qcom_smbx.c` is not traced line by line. The Makefile hunk context is rebased to 7.2.6, no code change |
| 0003 arm64: dts: qcom: pm8150b: add charger, fuel gauge and haptics nodes | fg node map220v, 2023-08-02, `map220v/sm8150-mainline` `462e45bc434a`; charger node and ADC channels Teguh Sobirin, 2024-11-20, `android_kernel_retroid_sm8250_ack` `23f7c4590989`; haptics node Teguh Sobirin, 2024-11-24, `876b57545d04` | Teguh Sobirin, map220v | sm8150-mainline, Teguh's Retroid kernel, ROCKNIX-old `SD865/0004` 2024-11-30, ROCKNIX `SM8250/0004` | CONFIRMED (hunks compared with the three commits) |
| 0004 regulator: add qcom pm8150l lcdb | ROCKNIX `063e530e58`, 2026-09-15 | Philippe Simons, "Ported from the downstream qpnp-lcdb-regulator driver" | ROCKNIX `SM8250/0066` | CONFIRMED |
| 0005 arm64: dts: qcom: pm8150l: add LCDB node | ROCKNIX `063e530e58`, 2026-09-15 | Philippe Simons | ROCKNIX `SM8250/0067` | CONFIRMED |
| 0006 ASoC: codecs: wcd938x-sdw: handle interrupts only on the TX device | `batocera-linux/batocera.linux` `ea7bbd5c7f84`, 2026-03-14 | Daniel Martin | batocera, ROCKNIX `957ddf7216` 2026-03-17 (`SM8250/0300`, context whitespace damaged) | CONFIRMED. The batocera file has no `From:`, only `#Signed-off-by: Daniel Martin`; header added here |
| 0007 drm/display: add hw_params callback to drm_connector_hdmi_audio_ops | dri-devel and linux-arm-msm v2, 2025-09-25, `20250925040530.20731-1-liujianfeng1994@gmail.com` (v1 2025-09-24); patchwork state new on dri-devel | Jianfeng Liu | lore, ROCKNIX SM8550 `0006`, ROCKNIX SM8250 `0017` (bare diff, Edvard Pedersen `705f43d24e`) | CONFIRMED. Taken from the patchwork mbox |
| 0008 drm/msm/dp: return 0 from audio_prepare when cable is disconnected | dri-devel and linux-arm-msm v1, 2026-06-16, `20260616151252.3599089-2-kumar.singh@oss.qualcomm.com` | Kumar Anurag | lore, ROCKNIX `7.2/0016` (`7b4da83200`, sunshineinabox) | CONFIRMED. Taken from the patchwork mbox |
| 0009 scsi: ufs: ufs-qcom: enable only lane clocks in lane clock APIs | linux-scsi V2, 2026-09-09, `20260909053944.2827968-1-nitin.rawat@oss.qualcomm.com`, `mkp/scsi.git` `f07317a8d57f` | Nitin Rawat | lore, mkp/scsi | CONFIRMED. Taken from git.kernel.org |
| 0010 serial: qcom-geni: add force suspend/resume to system sleep callbacks | linux-arm-msm v2, 2026-07-02, `20260702-add_force_suspend_resume_to_system_sleep_callbacks-v2-1-b79e254a7015@oss.qualcomm.com`, torvalds `d0cd9c8d0fd5` | Praveen Talari | lore, mainline | CONFIRMED. Taken from git.kernel.org. The Armada copy keeps this header over a body with extra error handling (virtudude, Armada `493b4f7`); not taken |
| 0101 to 0111 | my Armada `pocket-micro-2-build` and ROCKNIX `pocket-micro2` trees | seilent; 0101 is based on danyi's AR16 driver (ROCKNIX SM8550 `0064`, `aa418ad72e`, 2026-08-13), 0102 on the Sitronix and Waveshare ST7123 driver (raspberrypi/linux `6d4adb6bfea6`, 2026-07-16), 0103 uses the rumble report format of the stock Android 4.19.157 `hid-ayaneo` | own | CONFIRMED |
| PM2 DTS | my Armada `pocket-micro-2-build` tree | seilent; block layout and many lines shared with mainline `qrb5165-rb5.dts`, `sm8250-retroidpocket-common.dtsi`, `sm8250-ayn-thorlite.dts`; the `gpio-sbu-mux` block follows Tom's Retroid routing (Armada `9741312`, 2026-09-19) with PM2 GPIOs | own | CONFIRMED. 403 of 677 non trivial lines also appear in mainline board files, 145 only in the sibling files |

## Why and test

| Patch | Why on the PM2 | Test |
|---|---|---|
| 0001 | `pm8150b_haptics` driver and `qcom,spmi-haptics.h`, which 0003 includes | `qcom_spmi_haptics` binds `c000.haptics` |
| 0002 | battery and charging (`pm8150b_charger`, `pm8150b_fg`) | battery capacity and status in `/sys/class/power_supply`, charging on the charger |
| 0003 | the charger, fuel gauge and haptics nodes the DTS uses | DTB builds, `dts-drivers.sh` |
| 0004, 0005 | `panel_bias` (lab supply of the AR18 panel) | panel lights up |
| 0006 | wcd938x SoundWire IRQ only on the TX device; headphone jack detection | plug and unplug switches between speaker and headphones |
| 0007 | DP audio: hdmi-codec runs `hw_params` before prepare | audio over USB-C DP |
| 0008 | a failed DP prepare makes PipeWire drop the whole card profile | speaker and headphones stay with DP unplugged |
| 0009 | s2idle: the lane clock refcount leak kept `gpll0` and XO on | s2idle residency |
| 0010 | s2idle: QUP clocks held across system sleep | s2idle residency |
| 0101 | AR18 panel | panel lights up |
| 0102 | ST7123 touch | touch input |
| 0103 | pad rumble | rumble in a game |
| 0104 | headphone impedance detect | headphones detected |
| 0105 | backlight | brightness changes |
| 0106 | boot with the dock attached | boot docked |
| 0107 | DP start after a clean stop | DP audio after a replug |
| 0108 to 0111 | s2idle drain, each gated on `ayaneo,pocket-micro2` | s2idle residency |
| PM2 DTS | the board | `dts-drivers.sh`, `gpu-opp.sh` |

## patch-id

`git patch-id --stable` of the diff each copy produces on a clean 7.2.6 tree (`patch -p1 -F3`, staged, diffed), so
header and context differences drop out. Run 2026-10-12.

| Patch | MicroOS | ROCKNIX | Armada `b995457` | Upstream |
|---|---|---|---|---|
| 0001 | `fc2d104401f7` | `fc2d104401f7` (`SM8250/0009`) | `fc2d104401f7` (`0009`) | |
| 0002 | `e63021c1f752` | `e63021c1f752` (`SM8250/0011`) | `1817951590cb` (`0011`, older copy) | |
| 0003 | `d3fff4d73a66` | `d3fff4d73a66` (`SM8250/0004`) | `d3fff4d73a66` (`0004`) | |
| 0004 | `08628045a80d` | `08628045a80d` (`SM8250/0066`) | `08628045a80d` (`0066`) | |
| 0005 | `77d4b344ddc3` | `77d4b344ddc3` (`SM8250/0067`) | `77d4b344ddc3` (`0067`) | |
| 0006 | `ed59ad9b6b7d` | `ed59ad9b6b7d` (`SM8250/0300`) | `3738bd42494f` (`0300`, gated on `qcom,sm8250`) | `ed59ad9b6b7d` (batocera) |
| 0007 | `4079a90313f3` | `4079a90313f3` (`SM8250/0017`) | `4079a90313f3` (`0006`) | `4079a90313f3` (v2 mbox) |
| 0008 | `f9f70a7829e5` | `f9f70a7829e5` (`7.2/0016`) | `f21364e61939` (`0618`, same change, no author) | `f9f70a7829e5` (v1 mbox) |
| 0009 | `3a560368f8dc` | | `3a560368f8dc` (`0533`) | `3a560368f8dc` (`f07317a8d57f`) |
| 0010 | `d4b3ea706b2c` | | `64eba2c0ebec` (`0534`, modified) | `d4b3ea706b2c` (`d0cd9c8d0fd5`) |
| 0101 | `ac0bf37aa420` | `fe316f1d41ff` (`pocket-micro2` `0068`, older) | `ac0bf37aa420` (`0301`) | |
| 0102 | `c4f2698387a8` | `c4f2698387a8` (`pocket-micro2` `0069`) | `c4f2698387a8` (`0302`) | |
| 0103 | `bae827a9b120` | `32d7b3149e64` (`pocket-micro2` `0070`, older) | `bae827a9b120` (`0303`) | |
| 0105 | `adc3d10ff754` | `adc3d10ff754` (`pocket-micro2` `0073`) | `adc3d10ff754` (`0305`) | |

0104 and 0106 to 0111 exist only in my Armada tree; the MicroOS files are byte identical to it.

## Author check for my files

Run 2026-10-12 against Armada `b995457`, one `git log b995457 --format='%an <%ae>' -- <path>` per file (no
`--follow`), then `grep -ciE 'armada|device-env'` on the file:

```
packages/kernel/dts/sm8250-ayaneo-pocket-micro2.dts
      1 seilent <88354811+seilent@users.noreply.github.com>
      6 seilent <github@seilent.net>
  hits: 0
packages/kernel/patches/0301-drm-panel-add-ayaneo-ar18-panel.patch
      1 seilent <88354811+seilent@users.noreply.github.com>
  hits: 0
packages/kernel/patches/0302-input-touchscreen-add-sitronix-st7123.patch
      1 seilent <88354811+seilent@users.noreply.github.com>
  hits: 0
packages/kernel/patches/0303-hid-add-ayaneo-pocket-micro2-force-feedback.patch
      1 seilent <88354811+seilent@users.noreply.github.com>
  hits: 0
packages/kernel/patches/0304-ASoC-wcd938x-treat-failed-zdet-ramp-as-floating.patch
      1 seilent <88354811+seilent@users.noreply.github.com>
  hits: 0
packages/kernel/patches/0305-backlight-qcom-wled-always-disable-ovp-irq-at-probe.patch
      1 seilent <88354811+seilent@users.noreply.github.com>
  hits: 0
packages/kernel/patches/0306-usb-typec-qcom-pmic-typec-open-cc-on-set_cc-open.patch
      1 seilent <github@seilent.net>
  hits: 0
packages/kernel/patches/0307-ASoC-q6afe-dai-stop-hdmi-port-in-hw_free.patch
      1 seilent <github@seilent.net>
  hits: 0
packages/kernel/patches/0309-ASoC-qcom-q6afe-keep-the-lpass-core-hw-vote-handle.patch
      1 seilent <github@seilent.net>
  hits: 0
packages/kernel/patches/0310-ASoC-codecs-lpass-macro-release-core-hw-votes-in-runtime-suspend.patch
      1 seilent <github@seilent.net>
  hits: 0
packages/kernel/patches/0311-clk-qcom-camcc-sm8250-keep-gdsc-clk-on-outside-ccf.patch
      1 seilent <github@seilent.net>
  hits: 0
packages/kernel/patches/0312-drm-msm-dsi-phy-unprepare-iface-clk-across-system-sleep.patch
      1 seilent <github@seilent.net>
  hits: 0
```

ROCKNIX `pocket-micro2` `d4aaf4b235`, `0068`, `0069`, `0070`, `0073`: 5 commits, all `seilent <github@seilent.net>`.

Armada `0301` to `0312` map to `0101` to `0111` in order (there is no `0308`). The DTS adds
`&gpu_opp_table { /delete-node/ opp-670000000; };`, so no GPU OPP is above 587 MHz.
