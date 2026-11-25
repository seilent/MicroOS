# Credits

Projects MicroOS builds, with their authors and license.

## Built Upstream Projects

| What | Origin | Author | License |
|---|---|---|---|
| `gamescope-session` | [OpenGamingCollective/gamescope-session](https://github.com/OpenGamingCollective/gamescope-session) `08e65a62ed` | Joaquín Ignacio Aramendía, ChimeraOS and Open Gaming Collective contributors | MIT |
| `gamescope-session-steam` | [OpenGamingCollective/gamescope-session-steam](https://github.com/OpenGamingCollective/gamescope-session-steam) `82c45fc112` | ChimeraOS and Open Gaming Collective contributors | MIT |
| `gamescope` | [OpenGamingCollective/gamescope](https://github.com/OpenGamingCollective/gamescope) `3.16.31-ogc2` `76a1563a83` | Valve (Joshua Ashton and gamescope contributors), Open Gaming Collective contributors | BSD-2-Clause, BSD-3-Clause |
| `gamescope` RPM spec and packaging patches | Fedora [rpms/gamescope](https://src.fedoraproject.org/rpms/gamescope) `a846be4c` | František Zatloukal, Neal Gompa and Fedora packagers | MIT |
| `gamescope` one step vblank catch up | OGC `72ad630c018e`, first in `3b3cced787e3` | Matthew Schwartz | BSD-2-Clause |
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
| `mangohud` notifier cleanup | MangoHud `0c16392297ff` | flightlessmango | MIT |
| `libfreeaptx` | [regularhunter/libfreeaptx](https://github.com/regularhunter/libfreeaptx) `0.2.2` `6dee419f93`, a fork of libopenaptx 0.2.0, from the FFmpeg aptX codec | Aurelien Jacobs (FFmpeg aptX), Pali Rohár (libopenaptx), Hunter Wardlaw | LGPL-2.1-or-later |
| `pipewire-codec-aptx` | PipeWire `spa/plugins/bluez5/a2dp-codec-aptx.c` from Fedora's `pipewire-1.6.9-1.fc44.src.rpm` | Wim Taymans and PipeWire contributors | MIT |
| `pipewire-codec-aptx` build of the aptX target only (idea, spec written new) | [RPM Fusion pipewire-codec-aptx](https://github.com/rpmfusion/pipewire-codec-aptx) | Pauli Virtanen, Gergely Gombos | MIT |
| `hexagonrpc` | [linux-msm/hexagonrpc](https://github.com/linux-msm/hexagonrpc) `da7a3742ab` | Richard Acayan and hexagonrpc contributors | GPL-3.0-or-later, BSD-3-Clause (FastRPC error tables, The Linux Foundation and The Sensor Shell Contributors) |
| `hexagonrpc` file writes for the sensor registry | [hexagonrpc PR 27](https://github.com/linux-msm/hexagonrpc/pull/27) `40e5041281` (unmerged) | Fady Ackad | GPL-3.0-or-later |
| `es-de` | [ES-DE](https://gitlab.com/es-de/emulationstation-de) `v3.5.0` `50e4b600ae`, from RetroPie EmulationStation and EmulationStation | Leon Styhre, Northwestern Software AB, the RetroPie community, Alec Lofquist | MIT; built in from `external/`: CImg (CeCILL-C), glm (MIT), LunaSVG (MIT), RapidJSON (MIT), rlottie (MIT), UTF8-CPP (BSL-1.0); fonts, sounds and themes under their own licenses in `/usr/share/es-de/licenses/` |
| Art Book Next theme in `microemu` | [anthonycaccese/art-book-next-es-de](https://github.com/anthonycaccese/art-book-next-es-de) `d772d07109` | Anthony Caccese; system logos from Dan Patrick, ChangaOne font by Eduardo Tunni, artwork by nautipuss, tenlevels (with f8less), Joppa Fallston and theUnBurn, Phosphor Icons | CC-BY-NC-SA-2.0 |
| Mulish font in the Art Book Next theme, the `microemu` OSD text | [googlefonts/mulish](https://github.com/googlefonts/mulish) 3.603, carried in Art Book Next `_inc/fonts/` | Vernon Adams, The Mulish Project Authors | OFL-1.1 |
| `microemu` OSD speaker glyph | `_inc/images/menu-icon-sound.svg` of Art Book Next (Batocera Edition) [anthonycaccese/art-book-next-es](https://github.com/anthonycaccese/art-book-next-es) `9a50ef366e`; no earlier origin stated | Anthony Caccese | CC-BY-NC-SA-2.0 |
| CRT shaders in `microemu` (`crt-guest-advanced` fast and NTSC, `reshade` LUT) | [libretro/slang-shaders](https://github.com/libretro/slang-shaders) `e1d75632a2`, per file list and license in `/usr/share/licenses/microemu/slang-shaders/AUDIT` | guest(r), Dr. Venom, libretro slang-shaders contributors | GPL (version not stated) for the guest(r) files; 13 files state no license |
| Retro Crisis GDV-NTSC presets in `microemu` | [RetroCrisis/Retro-Crisis-GDV-NTSC](https://github.com/RetroCrisis/Retro-Crisis-GDV-NTSC) `20260321` `b7e2e26e1a`, presets for guest(r)'s Guest Advanced NTSC | Retro Crisis | GPL-3.0 |
| `plymouth` | [plymouth/plymouth](https://gitlab.freedesktop.org/plymouth/plymouth) `24.004.60` | Ray Strode, Kristian Høgsberg, Peter Jones and plymouth contributors | GPL-2.0-or-later |
| `plymouth` RPM spec | Fedora [rpms/plymouth](https://src.fedoraproject.org/rpms/plymouth) `1541161014` | Fedora packagers | MIT |
| `plymouth` Fedora only patches | Fedora rpms/plymouth, `e6f09b0570`, `36f45f9d11` | Adam Williamson, Hans de Goede | GPL-2.0-or-later |
| `plymouth` CloseFB on retain | SteamOS plymouth `22.02.122-7.7` `0010` | Robert Beckett (Collabora) | GPL-2.0-or-later |
| `microos-android-guestos` Turnip, zink, EGL and GLES for Android | [Mesa](https://gitlab.freedesktop.org/mesa/mesa) `26.2.5` | Brian Paul and Mesa contributors; Turnip: Red Hat, Bas Nieuwenhuizen and freedreno contributors; ir3: Rob Clark; zink: Collabora; Android EGL: Chia-I Wu, LunarG | MIT; single files BSL-1.0 (`src/c11`), HPND-sell-variant (`src/loader/loader_dri_helper*`), SGI-B-2.0 (`include/GLES3/gl3ext.h`), Apache-2.0 (the Khronos EGL, GLES and Vulkan headers and the code generated from Khronos `gl.xml`, the AOSP headers in `include/android_stub` and `include/vulkan/vk_android_native_buffer.h`), Apache-2.0 OR MIT (the code generated from Khronos `vk.xml`); built in: BLAKE3 1.8.2 (Jack O'Connor, Samuel Neves, Jean-Philippe Aumasson, Zooko, CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception), xxHash 0.8.3 (Yann Collet, BSD-2-Clause), Berkeley SoftFloat 3e in `src/util/softfloat.{c,h}`, `src/compiler/glsl/float32.glsl` and `float64.glsl` (John R. Hauser, The Regents of the University of California, BSD-3-Clause), radix_sort from Fuchsia (The Fuchsia Authors, BSD-2-Clause), the Linux UAPI header `include/drm-uapi/dma-buf.h` (Intel, GPL-2.0-only WITH Linux-syscall-note); the GLSL, GLSL preprocessor, ARB program and ir3 parsers are GNU Bison 3.8.2 output (Bison skeleton by the Free Software Foundation, GPL-3.0-or-later WITH Bison-exception-2.2); public domain code in `src/util/fast_idiv_by_const.c` (ridiculous_fish) and `src/util/rand_xor.c` (Sebastiano Vigna); the license of every compiled file in `/usr/share/licenses/microos-android-guestos/SOURCES.tsv` |
| `eglext_angle.h` in Mesa's EGL headers, built into `microos-android-guestos` | [ANGLE](https://chromium.googlesource.com/angle/angle), license text at `a7ae33a195` | The ANGLE Project Authors | BSD-3-Clause |
| libdrm in `microos-android-guestos`, linked into Mesa | [libdrm](https://gitlab.freedesktop.org/mesa/drm) `2.4.133`, the tarball of Mesa's `libdrm.wrap` | libdrm contributors | MIT |
| `microos-android-guestos` Fossilize layer | [ValveSoftware/Fossilize](https://github.com/ValveSoftware/Fossilize) `556da9ff7d` | Hans-Kristian Arntzen and Fossilize contributors | MIT; built in: miniz 2.0.8 (Rich Geldreich, RAD Game Tools and Valve Software, MIT), Khronos Vulkan headers (Apache-2.0, `vulkan_core.h` Apache-2.0 OR MIT) |
| RapidJSON in the Fossilize layer, Fossilize's `rapidjson` submodule | [Tencent/rapidjson](https://github.com/Tencent/rapidjson) `8f4c021fa2` | THL A29 Limited (Tencent), Milo Yip | MIT |
| C++ runtime, startup objects and system headers in `microos-android-guestos` | Android NDK r30 (30.0.16248370): `libc++_static`, `libc++abi`, `libunwind` and compiler-rt builtins linked statically, `crtbegin_so.o`, `crtend_so.o`, the sysroot headers | LLVM project contributors; The Android Open Source Project, the University of California and the other authors in the NDK sysroot `NOTICE` | Apache-2.0 WITH LLVM-exception; the sysroot headers per the NDK sysroot `NOTICE` |
| `lsfg-vk`, the lsfg-vk layer in `microos-android-guestos` | [PancakeTAS/lsfg-vk](https://github.com/PancakeTAS/lsfg-vk), built from my fork [seilent/lsfg-vk-arm64](https://github.com/seilent/lsfg-vk-arm64), `bd4b8201e7` for `lsfg-vk`, `d4ab7fb2c1` for `microos-android-guestos` | PancakeTAS and lsfg-vk contributors | GPL-3.0-or-later; the code from before `5bedd8d` MIT |
| ARM64 descriptor fallbacks in `lsfg-vk` and `microos-android-guestos` | [FrankBarretta/lsfg-vk-android](https://github.com/FrankBarretta/lsfg-vk-android) `a9edb2f515`, `48bf76348a`, ported to v2 in [xXJSONDeruloXx/lsfg-vk-arm64](https://github.com/xXJSONDeruloXx/lsfg-vk-arm64) `337788901e` | FrankBarretta, xXJSONDeruloXx | MIT, GPL-3.0-or-later |
| `lsfg-vk` glibc layer build | xXJSONDeruloXx/lsfg-vk-arm64 `d2498550e7` | xXJSONDeruloXx | GPL-3.0-or-later |
| toml++ in `lsfg-vk` and `microos-android-guestos` | [marzer/tomlplusplus](https://github.com/marzer/tomlplusplus) `v3.4.0` | Mark Gillard | MIT |
| `ILights` V1 descriptor, hash and parcel layout in the `microos-android-guest-apks` lights HAL (written new) | AOSP [platform/hardware/interfaces](https://android.googlesource.com/platform/hardware/interfaces) `android-13.0.0_r1` `ad2871f7d2`, `light/aidl/aidl_api/android.hardware.light/1` | The Android Open Source Project | Apache-2.0 |
| Startup objects and system headers in the `microos-android-guest-apks` lights HAL | Android NDK r30 (30.0.16248370): `crtbegin_dynamic.o`, `crtend_android.o`, the sysroot headers | The Android Open Source Project and the other authors in the NDK sysroot `NOTICE` | per the NDK sysroot `NOTICE` |
| Internet and Bluetooth tile icons in the `microos-android-guest-apks` helper | AOSP [platform/frameworks/base](https://android.googlesource.com/platform/frameworks/base) `android-13.0.0_r75` `292f896457`, `core/res/res/drawable/ic_wifi_signal_4.xml` and `ic_qs_bluetooth.xml` | The Android Open Source Project | Apache-2.0 |
| `vendor/etc/audio_policy_volumes.xml` in `microos-android-guest-apks` (the music stream curves made flat) | the Waydroid LineageOS 20 vendor image `lineage-20.0-20261022-MAINLINE-waydroid_arm64_only-vendor.zip`, `/etc/audio_policy_volumes.xml` | The Android Open Source Project | Apache-2.0 |
| Telephony and display overlays in `microos-android-guest-apks`, signed with the AOSP test key | [platform/build](https://android.googlesource.com/platform/build) `a744cb600e`, `target/product/security/testkey` | The Android Open Source Project | Apache-2.0 |
| `vendor/lib64/hw/hwcomposer.waydroid.so` in `microos-android-guest-apks`, with my roundtrip queue patch | [WayDroid/android_hardware_waydroid](https://github.com/WayDroid/android_hardware_waydroid) `5af0c114a1`, `hwcomposer/`, built in a LineageOS 20 tree with Waydroid's patches, pins in `packages/android-guest-apks/hwc/hwc.env` | The Android Open Source Project, the Waydroid Project, Benjamin Franzke, Intel Corporation, Collabora | Apache-2.0 (`extension.cpp`, `hwcomposer.cpp`, `WaydroidClipboard.cpp`, `WaydroidWindow.cpp`), MIT (the other sources), HPND-sell-variant (`wayland-android.xml`); texts in `packages/android-guest-apks/hwc/licenses/LICENSE.hardware-waydroid` and `NOTICE.hardware-waydroid` |
| Linked statically into the `microos-android-guest-apks` composer | AOSP [platform/external/wayland](https://android.googlesource.com/platform/external/wayland) `21f44c8186` (`libwayland_client_static`, the core protocol), [platform/external/wayland-protocols](https://android.googlesource.com/platform/external/wayland-protocols) `3a0e5d628e` with Waydroid's fractional scale patch, [platform/external/libffi](https://android.googlesource.com/platform/external/libffi) `a8011b453b`, [platform/external/libxkbcommon](https://android.googlesource.com/platform/external/libxkbcommon) `1edee3451a`; the crt objects (`crtbegin_so.c`, `crtbrand.S`, `crtend_so.S`) from [LineageOS/android_bionic](https://github.com/LineageOS/android_bionic) `998f94cdcd` | Kristian Høgsberg, Intel Corporation and Wayland contributors; wayland-protocols contributors, Alessandro Astone; Anthony Green, Red Hat and libffi contributors; Daniel Stone, Ran Benita, Dan Nicholson, Silicon Graphics, The Open Group and the other authors in libxkbcommon's `LICENSE`; The Android Open Source Project | MIT (Wayland, wayland-protocols, libffi, libxkbcommon, `src/keysym.c` with The Open Group's notice), HPND (the Silicon Graphics files of libxkbcommon), public domain (libxkbcommon `src/keysym-utf.c`), GPL-3.0-or-later WITH Bison-exception-2.2 (libxkbcommon's parser, GNU Bison 3.8.2 output), BSD-2-Clause and Apache-2.0 (bionic's crt files, `pthread_atfork.h`), BSD-3-Clause (bionic `bionic_asm_arm64.h`); texts in `packages/android-guest-apks/hwc/licenses/` |
| `rocknix-abl` SM8250 elf | [ROCKNIX/abl](https://github.com/ROCKNIX/abl) `v1.2` `0e755e15`, built from [ROCKNIX/LinuxLoader](https://github.com/ROCKNIX/LinuxLoader) `e9d37131` (not public) | ROCKNIX contributors | not stated (no LICENSE in ROCKNIX/abl) |
| `hyprland` | [hyprwm/Hyprland](https://github.com/hyprwm/Hyprland) `v0.57.0` `0aa6745f70` | vaxerski and Hyprland contributors | BSD-3-Clause; `subprojects/udis86` (Vivek Thampi) BSD-2-Clause |
| `hyprland` stack libraries and tools: `hyprutils` 0.14.3, `hyprgraphics` 0.6.0, `hyprwire` 0.3.1, `hyprland-protocols` 0.8.0, `aquamarine` 0.15.1, `hyprcursor` 0.1.11, `hyprwayland-scanner` 0.4.6 (build only) | `github.com/hyprwm`, the archive of each pinned commit (`packages/hyprland/SOURCE.env`) | Hypr Development | BSD-3-Clause |
| `hyprlang` in the `hyprland` stack | [hyprwm/hyprlang](https://github.com/hyprwm/hyprlang) `v0.6.8` `3a1c1b25b0` | Hypr Development | LGPL-3.0-only |
| `glaze` in the `hyprland` stack, `glaze-devel` | [stephenberry/glaze](https://github.com/stephenberry/glaze) `v7.2.0` `b518eec7a2` | Stephen Berry | MIT |
| `hyprgrass` | [horriblename/hyprgrass](https://github.com/horriblename/hyprgrass) `hl-0.57.0` `8ca1af717d` | Ching Pei Yang | BSD-3-Clause; `LICENSE.aosp` Apache-2.0 |
| `hyprgrass` wf-touch subproject | [WayfireWM/wf-touch](https://github.com/WayfireWM/wf-touch) `8974eb0f6a` | Wayfire | MIT |
| `hyprsunset` | [hyprwm/hyprsunset](https://github.com/hyprwm/hyprsunset) `v0.4.0` `25f704346e` | Hypr Development | BSD-3-Clause |
| `hyprpicker` | [hyprwm/hyprpicker](https://github.com/hyprwm/hyprpicker) `v0.4.8` `838147963f` | Hypr Development | BSD-3-Clause |
| `xdg-desktop-portal-hyprland` | [hyprwm/xdg-desktop-portal-hyprland](https://github.com/hyprwm/xdg-desktop-portal-hyprland) `v1.4.1` `cc8e5ef8fb` | Hypr Development | BSD-3-Clause |
| `hyprland-guiutils` | [hyprwm/hyprland-guiutils](https://github.com/hyprwm/hyprland-guiutils) `v0.2.2` `a16ad89ed5` | Hypr Development | BSD-3-Clause |
| `hyprtoolkit` in the `hyprland-guiutils` package | [hyprwm/hyprtoolkit](https://github.com/hyprwm/hyprtoolkit) `v0.6.0` `f8cbaf42e1` | Hypr Development | BSD-3-Clause |
| illogical-impulse desktop config on the Y700 (`usr/share/microos/{quickshell/ii,hypr}`) | [end-4/dots-hyprland](https://github.com/end-4/dots-hyprland) | end-4 and dots-hyprland contributors | GPL-3.0 |
| Material shapes in the Quickshell config (`modules/common/widgets/shapes`) | QML port of [Knugel/rounded-polygon-ts](https://github.com/Knugel/rounded-polygon-ts), Androidx shape library | The Android Open Source Project | Apache-2.0 |
| Material Symbols (Outlined, Rounded, Sharp) in `microos-fonts` | [google/material-design-icons](https://github.com/google/material-design-icons) `10ecc14790` | Google | Apache-2.0 |
| Google Sans Flex in `microos-fonts` | [google/fonts](https://github.com/google/fonts) `cc39c4c2c3` `ofl/googlesansflex` | The Google Sans Flex Authors | OFL-1.1 |
| Space Grotesk in `microos-fonts` | [google/fonts](https://github.com/google/fonts) `cc39c4c2c3` `ofl/spacegrotesk` | The Space Grotesk Project Authors | OFL-1.1 |
| Readex Pro in `microos-fonts` | [google/fonts](https://github.com/google/fonts) `cc39c4c2c3` `ofl/readexpro` | The Readex Pro Project Authors | OFL-1.1 |
| Rubik in `microos-fonts` | [google/fonts](https://github.com/google/fonts) `cc39c4c2c3` `ofl/rubik` | The Rubik Project Authors | OFL-1.1 |
| JetBrains Mono Nerd Font in `microos-fonts` | [ryanoasis/nerd-fonts](https://github.com/ryanoasis/nerd-fonts) `v3.4.0`, JetBrains Mono `2.304` patched | The JetBrains Mono Project Authors, Ryan L McIntyre and Nerd Fonts contributors | OFL-1.1 (JetBrains Mono); MIT (Nerd Fonts patcher) |
| `audioreach-topology` m4 macros | [Linaro audioreach-topology](https://git.codelinaro.org/linaro/qcomlt/audioreach-topology) `1d4c4e337d` | Linaro Ltd | BSD-3-Clause |
| `wvkbd` | [jjsullivan5196/wvkbd](https://github.com/jjsullivan5196/wvkbd) `v0.21` `f7e9ea3a75` | John Sullivan | GPL-3.0-only; MIT for Wayland's `os-compatibility` (Kristian Høgsberg, Intel and Wayland contributors) and `wld` (Michael Forney); HPND-sell-variant for the `wlr-layer-shell` description (Drew DeVault) |

`gamescope-session` carries my PM2 `device-quirks` entry, `gamescope-session-y700` the same upstream with my Y700
`device-quirks` entry and my startup timeout patch, `steamos-manager` carries my five patches, `gamescope` carries
Fedora's packaging patches, six of mine and an OGC patch backported by me (`0003` to `0009`, `0006` from OGC),
`mangohud` carries ten upstream MangoHud patches, five of them backported by me, and five of mine, `plymouth` carries
Fedora's patches, the SteamOS CloseFB patch rebased by me and two of mine, `es-de` carries my launch path escape
patch, `inputplumber` carries three of mine and my polkit rule, `wvkbd` carries two of mine, `audioreach-topology`
carries my legacy TDM module and subgraph and my Y700 topology, `hexagonrpc` carries the five commits of
hexagonrpc PR 27 and seven of mine, the composer in `microos-android-guest-apks` carries my roundtrip queue patch
(`packages/android-guest-apks/hwc/`), and `lsfg-vk` and the lsfg-vk layer in `microos-android-guestos` are my
fork's `microos-layer` branch (`PATCHES.md` in each package); the others are built as is. License texts in
`packages/android-guest-apks/hwc/licenses/`, `packages/audioreach-topology/`, `packages/gamescope/`,
`packages/gamescope-session/`, `packages/gamescope-session-y700/`, `packages/es-de/`, `packages/hexagonrpc/`,
`packages/inputplumber/`, `packages/lsfg-vk/`, `packages/mangohud/`, `packages/plymouth/` and
`packages/steamos-manager/`.


## Kernel

Pocket MICRO 2: Linux 7.2.12 from [kernel.org](https://www.kernel.org/), GPL-2.0-only WITH Linux-syscall-note. Patches
and their origins in `packages/kernel-pm2/PATCHES.md`.

Legion Y700: Linux 7.4-rc2 from [kernel.org](https://www.kernel.org/), GPL-2.0-only WITH Linux-syscall-note. Patches
and their origins in `packages/kernel-y700/PATCHES.md`.

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
| qce runtime PM and interconnect scaling | Linux `6f5569203bb6` | Udit Tiwari | GPL-2.0-only |
| D3 for native hotplug Root Ports on non-x86 | Linux `d4c79b63d82d` | Manivannan Sadhasivam | GPL-2.0 |
| qrtr HELLO on endpoint register | Linux `544d85de4dc2` | Chris Lew | GPL-2.0-only |
| qrtr resend HELLO on MHI resume | Linux `6a5719cc3ef2` | Daniel J Blueman | GPL-2.0-only |
| qrtr HELLO gate for control packets | lore `20261019-upstream-qrtr-hello-gate-fix_b4-v1` | Igor Opaniuk | GPL-2.0-only |
| lpass rx and tx macro PM clocks for runtime PM, clk_set_rate() check, wsa macro MCLK output with devm | Linux `b9b23e72abef`, `b05482e7ce1b`, `b8ca90fafe6a`, `541735571578` | Ajay Kumar Nandam, Ravi Hothi | GPL-2.0-only |
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
| AVB test key `usr/share/microos/avb/testkey_rsa4096.pem` (Y700) | [AOSP external/avb](https://android.googlesource.com/platform/external/avb) `test/data/testkey_rsa4096.pem` | The Android Open Source Project | Apache-2.0 |
| OSTree | [ostreedev/ostree](https://github.com/ostreedev/ostree), Fedora `ostree` | OSTree contributors | LGPL-2.0-or-later |
| bootc-image-builder | [osbuild/bootc-image-builder](https://github.com/osbuild/bootc-image-builder) `quay.io/centos-bootc/bootc-image-builder` | osbuild contributors | Apache-2.0 |
| PM2 UCM layout and the `Speakers Volume` remap | [alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf) `Qualcomm/sm8250/HiFi.conf` `f4f0a97eb3`, `codecs/wsa883x/init.conf` `489b9a1406` | Srinivas Kandagatla (Linaro) | BSD-3-Clause |
| PM2 UCM `Headset` mic sequences | [alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf) `codecs/wcd938x/HeadphoneMic*Seq.conf` `fa40b703b3`, `codecs/qcom-lpass/tx-macro/HeadphoneMic*Seq.conf` `9856a0a55a` | Srinivas Kandagatla (Linaro), Krzysztof Kozlowski, Mohammad Rafi Shaik | BSD-3-Clause |
| Steam client and Steam Runtime (steamrt3c arm64) | Valve `steam_client_steamdeck_stable_linuxarm64` `1788652215`, `steam-runtime-steamrt-arm64` `3c.0.20260729.253765` | Valve Corporation | Steam Subscriber Agreement |
| SDDM `TZ=UTC0` drop-in (idea, written new) | Armada `cf87a12` | virtudude | GPL-2.0-or-later |
| hexagonrpcd stopped across suspend (idea, written new) | [postmarketOS pmaports](https://gitlab.postmarketos.org/postmarketOS/pmaports) `fe0002784` | Richard Acayan | GPL-3.0 |
| Bluetooth address from the SoC serial (idea, written new) | [ROCKNIX/distribution-old](https://github.com/ROCKNIX/distribution-old) `779c788321` | spycat88 | GPL-2.0 |
| Stick LED frame in `microsetd` (format, written new) | [ROCKNIX](https://github.com/ROCKNIX/distribution) `57cf10c23e` AYANEO Pocket EVO `analog_sticks_ledcontrol` (MCU envelope); AYANEO RGB app on stock Android (PM2 frame body) | tiopex, AYANEO | GPL-2.0 (ROCKNIX); format only from the app |
| SSC wire format in the InputPlumber SSC source, `microsetd` and `waydroid-sensord` (format, written new) | [libssc](https://codeberg.org/DylanVanAssche/libssc) `54dd13e` | Dylan Van Assche | GPL-3.0-or-later |
| `ISensors` 1.0 types and calls in `waydroid-sensord` (written new) | AOSP [platform/hardware/interfaces](https://android.googlesource.com/platform/hardware/interfaces) `android13-release` `fa455d80b5`, `sensors/1.0/types.hal` and `ISensors.hal` | The Android Open Source Project | Apache-2.0 |
| `waydroid-sensord` as a host side sensors HAL on the Waydroid hwbinder (idea, written new) | [waydroid/waydroid-sensors](https://github.com/waydroid/waydroid-sensors) `88c3536b99` | Erfan Abdi | GPL-3.0 |
| Adaptive brightness curve in the `microos-android-guest-apks` display overlay (values, converted to the guest scale) | Lenovo TB321FU ROW ZUI `17.5.10.272`: `product/overlay/KirbyRowFrameworksOverlay.apk` lux levels and nits, `vendor/etc/displayconfig/display_id_4630947039571902851.xml` nits map | Lenovo | values only |
| Crossfeed design in the `microos-eq` plugin (bs2b `init` formulas, written new) | [libbs2b](https://github.com/alexmarsev/libbs2b) `3.1.0` `src/bs2b.c` | Boris Mikhaylov | MIT |
| Matched peak band design in the `microos-eq` plugin (method, written new) | M. Vicanek, "Matched Second Order Digital Filters" (2016) | Martin Vicanek | paper |
| RBJ band designs in the `microos-eq` plugin (ported) | [PipeWire](https://gitlab.freedesktop.org/pipewire/pipewire) `1.6.9` `spa/plugins/audioconvert/biquad.c` | The Chromium OS Authors, Google | BSD-3-Clause |
| Selawik font in `microset-fonts`, for the recovery screen and MicroDAP | [microsoft/Selawik](https://github.com/microsoft/Selawik) `1.01` | Microsoft Corporation | OFL-1.1 |
| Doto font, rendered into the boot splash wordmark (font not shipped) | [oliverlalan/Doto](https://github.com/oliverlalan/Doto) `1.000` | Óliver Lalan | OFL-1.1 |
| `mkbootimg`, `unpack_bootimg` | AOSP `platform/system/tools/mkbootimg`, Fedora `android-tools` | The Android Open Source Project | Apache-2.0 |
| OpenH264, fetched on the device by `microos-openh264`, not in the image | Cisco's `openh264` RPM from Fedora's `fedora-cisco-openh264` repo, binary built and served by Cisco | Cisco Systems | BSD-2-Clause |
