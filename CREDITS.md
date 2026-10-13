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

`gamescope-session` carries my PM2 `device-quirks` entry and `gamescope` carries Fedora's packaging patches (`PATCHES.md`
in each package); the others are built as is. License texts in `packages/gamescope/`, `packages/gamescope-session/` and
`packages/inputplumber/`.

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
| Base image | [Fedora bootc](https://gitlab.com/fedora/bootc/base-images) `quay.io/fedora/fedora-bootc:44` | Fedora Project | per package (Fedora 44) |
| bootc | [bootc-dev/bootc](https://github.com/bootc-dev/bootc), Fedora `bootc` | bootc contributors | Apache-2.0 OR MIT |
| OSTree | [ostreedev/ostree](https://github.com/ostreedev/ostree), Fedora `ostree` | OSTree contributors | LGPL-2.0-or-later |
| bootc-image-builder | [osbuild/bootc-image-builder](https://github.com/osbuild/bootc-image-builder) `quay.io/centos-bootc/bootc-image-builder` | osbuild contributors | Apache-2.0 |
| PM2 UCM layout and the `Speakers Volume` remap | [alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf) `Qualcomm/sm8250/HiFi.conf` `f4f0a97eb3`, `codecs/wsa883x/init.conf` `489b9a1406` | Srinivas Kandagatla (Linaro) | BSD-3-Clause |
| `mkbootimg`, `unpack_bootimg` | AOSP `platform/system/tools/mkbootimg`, Fedora `android-tools` | The Android Open Source Project | Apache-2.0 |
