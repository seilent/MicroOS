# Credits

Projects MicroOS builds, with their authors and license.

## Built Upstream Projects

| What | Origin | Author | License |
|---|---|---|---|
| `gamescope-session` | [OpenGamingCollective/gamescope-session](https://github.com/OpenGamingCollective/gamescope-session) `08e65a62ed` | Joaquín Ignacio Aramendía, ChimeraOS and Open Gaming Collective contributors | MIT |
| `gamescope-session-steam` | [OpenGamingCollective/gamescope-session-steam](https://github.com/OpenGamingCollective/gamescope-session-steam) `82c45fc112` | ChimeraOS and Open Gaming Collective contributors | MIT |
| `gamescope` | [OpenGamingCollective/gamescope](https://github.com/OpenGamingCollective/gamescope) `3.16.31-ogc2` `76a1563a83` | Valve (Joshua Ashton and gamescope contributors), Open Gaming Collective contributors | BSD-2-Clause, BSD-3-Clause |
| `gamescope` RPM spec and packaging patches | Fedora [rpms/gamescope](https://src.fedoraproject.org/rpms/gamescope) `a846be4c` | František Zatloukal, Neal Gompa and Fedora packagers | MIT |
| `inputplumber` | [ShadowBlip/InputPlumber](https://github.com/ShadowBlip/InputPlumber) `v0.82.0` `d951ef9` | William Edwards, Derek J. Clark and InputPlumber contributors | GPL-3.0-or-later |
| `steamos-manager` | [holo/steamos-manager](https://gitlab.steamos.cloud/holo/steamos-manager) `8e2883d0d7` | Valve Software, Collabora, Igalia and steamos-manager contributors | MIT |
| `mangohud` | [flightlessmango/MangoHud](https://github.com/flightlessmango/MangoHud) `v0.8.4` `992103e4fb` | flightlessmango and MangoHud contributors | MIT |
| `mangohud` RPM spec | Fedora [rpms/mangohud](https://src.fedoraproject.org/rpms/mangohud) `83471e05` | Fedora packagers | MIT |
| `mangohud` msm_dpu GPU temp and load | MangoHud PR 2073 `0be0cacafb86`, `0b2badb56f87` | Victoria Brekenfeld | MIT |
| `mangohud` devfreq GPU clock, `/proc` walk fixes | MangoHud `eb72a0048f43`, `e2d0db030ef0`, `16d783b5d29a` | flightlessmango | MIT |
| `mangohud` devfreq GPU clock | MangoHud `eb72a0048f43` (co-author) | Antonino Maniscalco | MIT |
| `mangohud` `lib_loaded` fix | MangoHud `e2d0db030ef0` (co-author) | Gabe Rowe (Valve) | MIT |
| `mangohud` battery by sysfs type | MangoHud PR 2166 `e5d31119b521` | fromdisposition | MIT |
| `mangohud` mangoapp render per game frame | MangoHud `2c1dc5283c04` | Matthew Schwartz | MIT |
| `mangohud` msm_dpu GPU memory | MangoHud `f7d778a5e702` | 17314642 | MIT |
| `mangohud` msm_dpu GPU rows | MangoHud `7c95b67656d6`, `e57fa15`, `abc561d` | flightlessmango, Matthew Schwartz | MIT |
| `hexagonrpc` | [linux-msm/hexagonrpc](https://github.com/linux-msm/hexagonrpc) `da7a3742ab` | Richard Acayan and hexagonrpc contributors | GPL-3.0-or-later, BSD-3-Clause (FastRPC error tables, The Linux Foundation and The Sensor Shell Contributors) |
| `plymouth` | [plymouth/plymouth](https://gitlab.freedesktop.org/plymouth/plymouth) `24.004.60` | Ray Strode, Kristian Høgsberg, Peter Jones and plymouth contributors | GPL-2.0-or-later |
| `plymouth` RPM spec | Fedora [rpms/plymouth](https://src.fedoraproject.org/rpms/plymouth) `1541161014` | Fedora packagers | MIT |
| `plymouth` Fedora only patches | Fedora rpms/plymouth, `e6f09b0570`, `36f45f9d11` | Adam Williamson, Hans de Goede | GPL-2.0-or-later |
| `plymouth` CloseFB on retain | SteamOS plymouth `22.02.122-7.7` `0010` | Robert Beckett (Collabora) | GPL-2.0-or-later |

`gamescope-session` carries my PM2 `device-quirks` entry, `steamos-manager` carries my four patches, `gamescope`
carries Fedora's packaging patches, `mangohud` carries nine upstream MangoHud patches, five of them backported by
me, and three of mine, and `plymouth` carries Fedora's patches, the SteamOS CloseFB patch rebased by me and two of mine
(`PATCHES.md` in each package); the others are built as is. License texts in `packages/gamescope/`,
`packages/gamescope-session/`, `packages/hexagonrpc/`, `packages/inputplumber/`, `packages/mangohud/`, `packages/plymouth/`
and `packages/steamos-manager/`.

## Kernel

Linux 7.2.6 from [kernel.org](https://www.kernel.org/), GPL-2.0-only WITH Linux-syscall-note. Patches and their
origins in `packages/kernel/PATCHES.md`.

| What | Origin | Author | License |
|---|---|---|---|
| Qualcomm SPMI haptics driver | patchwork `20210816221931.1998187-3-caleb@connolly.tech`, Retroid kernel `51ef2f2ed1da` | Casey Connolly, Teguh Sobirin | GPL-2.0-only |
| Qualcomm SMB5 charger and PM8150B fuel gauge | [map220v/sm8150-mainline](https://github.com/map220v/sm8150-mainline) `27f8b500c7a6`, `50cf85d48047`; Retroid kernel `71fae666971c`; ROCKNIX `0393a000d2`, `1dc63e1531`, `7b4da83200` | The Linux Foundation (Qualcomm downstream fuel gauge), Teguh Sobirin, Casey Connolly, Joel Selvaraj, Yassine Oudjana, map220v, Nefirim, Xenocideend, sunshineinabox | GPL-2.0-only |
| PM8150B charger, fuel gauge and haptics nodes | map220v/sm8150-mainline `462e45bc434a`; Retroid kernel `23f7c4590989`, `876b57545d04` | Teguh Sobirin, map220v | BSD-3-Clause |
| PM8150L LCDB regulator and node | [ROCKNIX](https://github.com/ROCKNIX/distribution) `063e530e58`, ported from Qualcomm downstream `qpnp-lcdb-regulator` | Philippe Simons, The Linux Foundation (Qualcomm downstream) | GPL-2.0-only, BSD-3-Clause |
| wcd938x headphone jack detection | [batocera.linux](https://github.com/batocera-linux/batocera.linux) `ea7bbd5c7f84` | Daniel Martin | GPL-2.0 |
| HDMI audio `hw_params` callback | lore `20250925040530.20731-1-liujianfeng1994@gmail.com` | Jianfeng Liu | MIT |
| sm8250 backend format kept for PCM | [ROCKNIX/distribution-old](https://github.com/ROCKNIX/distribution-old) `f7b53cc4b244` (idea), Linux `89be3c15a58b` (S16_LE force) | rmake, Alexey Klimov | GPL-2.0 |
| msm DP `audio_prepare` unplugged | lore `20260616151252.3599089-2-kumar.singh@oss.qualcomm.com` | Kumar Anurag | GPL-2.0-only |
| ufs-qcom lane clocks | `mkp/scsi.git` `f07317a8d57f` | Nitin Rawat | GPL-2.0-only |
| qcom-geni force suspend in system sleep | Linux `d0cd9c8d0fd5` | Praveen Talari | GPL-2.0 |
| AR16 panel driver, base of the AR18 driver | ROCKNIX SM8550 `0064`, `aa418ad72e` | danyi | GPL-2.0-only |
| Sitronix ST7123 driver, base of the ST7123 driver | [raspberrypi/linux](https://github.com/raspberrypi/linux) `6d4adb6bfea6` | Waveshare, Sitronix | GPL-2.0 |
| Rumble report format in `hid-ayaneo` | stock Android 4.19.157 `hid-ayaneo` | AYANEO | GPL-2.0 |
| PM2 DTS layout shared with other SM8250 boards | Linux `qrb5165-rb5.dts`; `sm8250-retroidpocket-common.dtsi`; `sm8250-ayn-thorlite.dts`; SBU mux routing in Armada `9741312` | Linaro; Teguh Sobirin (Retroid Pocket); Philippe Simons; Tom | BSD-3-Clause |

Retroid kernel is [lineageos-on-retroid/android_kernel_retroid_sm8250_ack](https://github.com/lineageos-on-retroid/android_kernel_retroid_sm8250_ack).

## Base

| What | Origin | Author | License |
|---|---|---|---|
| Base image | [Fedora bootc](https://gitlab.com/fedora/bootc/base-images) `registry.fedoraproject.org/fedora-bootc:44` | Fedora Project | per package (Fedora 44) |
| bootc | [bootc-dev/bootc](https://github.com/bootc-dev/bootc), Fedora `bootc` | bootc contributors | Apache-2.0 OR MIT |
| OSTree | [ostreedev/ostree](https://github.com/ostreedev/ostree), Fedora `ostree` | OSTree contributors | LGPL-2.0-or-later |
| bootc-image-builder | [osbuild/bootc-image-builder](https://github.com/osbuild/bootc-image-builder) `quay.io/centos-bootc/bootc-image-builder` | osbuild contributors | Apache-2.0 |
| PM2 UCM layout and the `Speakers Volume` remap | [alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf) `Qualcomm/sm8250/HiFi.conf` `f4f0a97eb3`, `codecs/wsa883x/init.conf` `489b9a1406` | Srinivas Kandagatla (Linaro) | BSD-3-Clause |
| PM2 UCM `Headset` mic sequences | [alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf) `codecs/wcd938x/HeadphoneMic*Seq.conf` `fa40b703b3`, `codecs/qcom-lpass/tx-macro/HeadphoneMic*Seq.conf` `9856a0a55a` | Srinivas Kandagatla (Linaro), Krzysztof Kozlowski, Mohammad Rafi Shaik | BSD-3-Clause |
| Steam client and Steam Runtime (steamrt3c arm64) | Valve `steam_client_steamdeck_stable_linuxarm64` `1788652215`, `steam-runtime-steamrt-arm64` `3c.0.20260729.253765` | Valve Corporation | Steam Subscriber Agreement |
| SDDM `TZ=UTC0` drop-in (idea, written new) | Armada `cf87a12` | virtudude | GPL-2.0-or-later |
| hexagonrpcd stopped across suspend (idea, written new) | [postmarketOS pmaports](https://gitlab.postmarketos.org/postmarketOS/pmaports) `fe0002784` | Richard Acayan | GPL-3.0 |
| Bluetooth address from the SoC serial (idea, written new) | [ROCKNIX/distribution-old](https://github.com/ROCKNIX/distribution-old) `779c788321` | spycat88 | GPL-2.0 |
| Stick LED frame in `microsetd` (format, written new) | [ROCKNIX](https://github.com/ROCKNIX/distribution) `57cf10c23e` AYANEO Pocket EVO `analog_sticks_ledcontrol` (MCU envelope); AYANEO RGB app on stock Android (PM2 frame body) | tiopex, AYANEO | GPL-2.0 (ROCKNIX); format only from the app |
| SSC wire format in the InputPlumber SSC source and `microsetd` (format, written new) | [libssc](https://codeberg.org/DylanVanAssche/libssc) `54dd13e` | Dylan Van Assche | GPL-3.0-or-later |
| Selawik font in `microset-recovery` | [microsoft/Selawik](https://github.com/microsoft/Selawik) `1.01` | Microsoft Corporation | OFL-1.1 |
| Doto font, rendered into the boot splash wordmark (font not shipped) | [oliverlalan/Doto](https://github.com/oliverlalan/Doto) `1.000` | Óliver Lalan | OFL-1.1 |
| `mkbootimg`, `unpack_bootimg` | AOSP `platform/system/tools/mkbootimg`, Fedora `android-tools` | The Android Open Source Project | Apache-2.0 |
