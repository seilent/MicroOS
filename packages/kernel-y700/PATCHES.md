# Kernel patches

Base: mainline `v7.4-rc2` (`7475ea8b5861`), set in `SOURCE.env`. `build.sh` fetches the tag from kernel.org git and
exports it with `git archive`; a stable base is the kernel.org tarball with its sha256. `patches/series` applies in
order with `patch -p1 -F0`. The patches are made with `git format-patch` from a kernel tree on the base tag. The DTS
files in `dts/` are copied into `arch/arm64/boot/dts/qcom/` by `build.sh`.

Config: `tb321fu.config` holds the board lines, `microos.config` the image level lines.

## Patches

| Patch | Origin | Check |
|---|---|---|
| `0001-dt-bindings-arm-qcom-Add-Lenovo-Legion-Y700-2025.patch` | mine | `dt-validate` on the TB321FU DTBs |
| `0002-dt-bindings-display-panel-novatek-nt36523-Add-Lenovo.patch` | mine | `dt-validate` on the TB321FU DTBs |
| `0003-drm-panel-novatek-nt36523-Remove-the-panel-when-prob.patch` | mine | panel probes after a deferred DSI attach, no list corruption in dmesg |
| `0004-drm-panel-novatek-nt36523-Add-Lenovo-Legion-Y700-202.patch` | mine | `card1-DSI-1` connected, 1600x2560 at 120 Hz, picture without DSC or underrun errors, panel back after 10 DPMS cycles |
| `0005-dt-bindings-backlight-kinetic-ktz8866-Add-boost-and-.patch` | mine | `dt-validate` on the TB321FU DTBs |
| `0006-backlight-ktz8866-Set-boost-OVP-inductor-and-LED-cur.patch` | mine | KTZ8866 regs 0x02 0xda, 0x11 0x37, 0x15 0x68; brightness steps even |
| `0013-iommu-arm-smmu-qcom-Add-SM8650-MDSS-compatible-to-cl.patch` | mine | no `Unhandled context fault` on SID 0x1c00 at the splash addresses during boot; MDSS group default domain identity |
| `0014-drm-msm-dsi-Run-bonded-links-on-their-own-PLLs-when-.patch` | mine | with `mdss_dsi1` clocked from its own PHY both DSI PHYs run standalone, each PLL at the link rate; high speed reads answer on both links and the TB321FU panel shows the full picture; both PLL states saved on disable, so after a `pm_test devices` suspend both links come back with no `dsi_err_worker` lines |
| `0007-dt-bindings-input-touchscreen-Add-Novatek-NT36523-SP.patch` | mine | `dt-validate` on the TB321FU DTBs |
| `0008-Input-add-Novatek-NT36523-SPI-touchscreen-driver.patch` | mine | the firmware version logged after the panel enable, no 0xfe resets with the full picture; 10 fingers matching the landscape panel; the pen input device and its absinfo; firmware reload after a DPMS cycle; reloads stop after five watchdog resets in a row |
| `0009-dt-bindings-input-awinic-aw86927-Add-AW86937.patch` | mine | `dt-validate` on the TB321FU DTBs |
| `0010-Input-aw86927-add-support-for-AW86937.patch` | mine | both motors probe with chip ID 0x9370; `fftest` rumble and stop on both, felt, 170 Hz from the 141 sample SRAM waveform |
| `0011-dt-bindings-usb-Add-Parade-PS5169-USB-C-redriver.patch` | mine | `dt-validate` on the TB321FU DTBs |
| `0012-usb-typec-mux-Add-Parade-PS5169-redriver-driver.patch` | mine | typec switch and retimer registered; DP alt mode picture on a monitor; SuperSpeed link on the USB-C port |
| `0020-ASoC-dt-bindings-awinic-aw88395-Add-AW88461.patch` | mine | `dt-validate` on the TB321FU DTBs |
| `0021-ASoC-codecs-aw88261-Enable-I2S-TX-in-I2SCTRL3.patch` | mine | AW88261 boards: TX feedback on I2SCTRL3 bit 6 during a stream; the register comes from the vendor PID 0x2113 table, no datasheet (unverified) |
| `0022-ASoC-codecs-aw88261-Keep-the-volume-across-profile-c.patch` | mine | `Profile Set` to Receiver and back keeps `PCM Playback Volume` |
| `0023-ASoC-codecs-aw88261-Add-AW88461-support.patch` | mine | chip ID 0x2308 in the probe log of both PAs, ACF loaded with its Music and Receiver profiles, `SpkrLeft` and `SpkrRight` controls, `PCM Playback Volume` 360 leaves SYSCTRL2 at the ACF level 0x19; both PAs heard |
| `0024-ASoC-codecs-aw88261-Enable-TX-feedback-only-with-a-T.patch` | mine | SYSCTRL bit 13 clear on both PAs while the speaker stream runs (no TX slot in the DT) |
| `0025-ASoC-qcom-q6prm-Add-TDM-bit-clocks.patch` | mine | SEC TDM bit clock on at 12.288 MHz while the speaker stream runs, no PRM error |
| `0026-ASoC-qcom-audioreach-Add-legacy-TDM-sink-and-source.patch` | mine | topology loads with the legacy TDM sink, the Secondary TDM0 graph opens and starts with no APM error; both PAs play |
| `0027-ASoC-dt-bindings-qcom-sm8250-Add-Lenovo-Legion-Y700-.patch` | mine | `dt-validate` on the TB321FU DTBs |
| `0028-ASoC-qcom-sc8280xp-Add-Lenovo-Legion-Y700-2025-sound.patch` | mine | card `Lenovo-Y700-TB321FU` registers, `/proc/asound/pcm` lists the MultiMedia PCMs, UCM HiFi Speaker plays on `hw:0,1` |
| `0029-ASoC-soc-core-reset-rtd-num_components-after-allocat.patch` | upstream, broonie/sound.git for-next `d00ba321499c` (Emanuele Ghidoli), https://patch.msgid.link/20261109102536.357134-1-ghidoliemanuele@gmail.com | the card probes its components: component directories under the card in `/sys/kernel/debug/asoc`, the AW88261 and topology controls, `MultiMedia` PCMs in `/proc/asound/pcm` |
| `0030-ASoC-codecs-aw88261-Start-the-amplifier-from-a-work.patch` | mine | no `start failure` on either PA when the speaker stream starts; both PAs heard |
| `0040-ASoC-qcom-sc8280xp-Set-up-the-Lenovo-Legion-Y700-202.patch` | mine | `Headphone Jack` and `Mic Jack` controls on the card; a headset in the USB-C port sets both, its removal clears them; a failed jack setup leaves the card up with one warning |
| `0050-dt-bindings-usb-Add-GPIO-controlled-USB-2.0-port-mul.patch` | mine | `dt_binding_check` of the binding; `dt-validate` on the TB321FU DTBs |
| `0051-usb-roles-Add-GPIO-controlled-USB-2.0-port-multiplex.patch` | mine | two `usb2-port-mux` role switches and the controller role follow UCSI: a host on the bottom port alone gets the gadget, a device on the side port alone enumerates, the bottom port wins with both, gpio58 in `/sys/kernel/debug/gpio` matches |
| `0053-usb-typec-ucsi-debugfs-Fix-GET-commands-on-UCSI-2.0.patch` | upstream, gregkh/usb.git usb-linus and linux-next `next-20261113` `7cfb037005c0` (Ali Ahmet Memiş), https://patch.msgid.link/20261024174441.878903-1-aliamemis@disroot.org | `echo 0x6 > command` in the `pmic_glink.ucsi.0` debugfs directory returns the capability in `response` instead of EINVAL |
| `0054-usb-dwc3-qcom-Defer-the-VBUS-override-while-suspende.patch` | mine | a plug into the side USB-C port during s2idle, with the cable in the bottom port before the sleep, logs `role change to device while suspended` and no reset, and the gadget enumerates over the side port after the wake |
| `0060-serial-qcom-geni-Clear-pending-IRQs-while-suspended.patch` | upstream, posted v1 (Praveen Talari), not in tty.git or linux-next `next-20261113`, https://patch.msgid.link/20261021-ack-interrupts-on-suspended-port-v1-1-2747a58ca7cb@oss.qualcomm.com | 40 `pm_test devices` suspends with Bluetooth up, no `nobody cared` or `Disabling IRQ` for the `898000.serial` IRQ and `hci0` up (flags 0x5) after each resume |
| `0065-media-iris-Preserve-timestamps-on-error-buffers.patch` | upstream, posted v1 4/5 (Xilin Wu), not in media.git or linux-next, https://patch.msgid.link/20261029-iris-va-fixes-v1-4-44a2783f782b@radxa.com | with 0066: a libvpx VP9 clip with altref frames decodes through `vp9_v4l2m2m` with no `driver decode error`, every frame equal to the software decode by pts |
| `0066-media-iris-Recycle-decoder-buffers-for-non-display.patch` | upstream, posted v1 5/5 (Xilin Wu), not in media.git or linux-next, https://patch.msgid.link/20261029-iris-va-fixes-v1-5-44a2783f782b@radxa.com | as 0065 |
| `0070-power-supply-qcom_battmgr-Invert-the-battery-current.patch` | mine | `tests/battery.sh` on the tablet: `current_now` above 0 while it charges from a PD charger and at most 0 on battery, UPower `DisplayDevice` State 1 and 2 |
| `0090-regulator-dt-bindings-willsemi-wl2868c-add-the-WL286.patch` | upstream, broonie/regulator.git for-next `84e67d2ee13f` and linux-next `next-20261118` (Qianhui Xu), https://patch.msgid.link/20261117052257.34849-2-xiaqinghuan@mail.ustc.edu.cn | `dt_binding_check` of the binding; `dt-validate` on the TB321FU DTBs |
| `0091-regulator-willsemi-wl2868c-add-the-WL2868C-camera-PM.patch` | upstream, broonie/regulator.git for-next `602f57223457` and linux-next `next-20261118` (Qianhui Xu), https://patch.msgid.link/20261117052257.34849-3-xiaqinghuan@mail.ustc.edu.cn | the CCI1 `pmic@2f` binds with ID 0x82 and no LDO on; each LDO at its voltage in `regulator_summary` only while its sensor is powered: LDO6 2.8 V and LDO7 1.856 V for the SC202CS, LDO1 1.216 V, LDO4 and LDO5 2.8 V and LDO7 for the GC13A0, LDO2 1.216 V, LDO3 2.8 V and LDO7 for the SC820CS |
| `0092-dt-bindings-vendor-prefixes-Add-SmartSens-Technology.patch` | mine | `dt_binding_check` of the SC202CS and SC820CS bindings |
| `0093-media-dt-bindings-i2c-Add-SmartSens-SC202CS-image-se.patch` | mine | `dt_binding_check` of the binding; `dt-validate` on the TB321FU DTBs |
| `0094-media-i2c-Add-SmartSens-SC202CS-image-sensor-driver.patch` | mine | chip ID 0xeb52 at probe on CCI0 master 1; `cam -l` lists the sensor; one 1600x1200 capture with no CSID errors in dmesg |
| `0095-media-dt-bindings-i2c-Add-GalaxyCore-GC13A0-image-se.patch` | mine | `dt_binding_check` of the binding; `dt-validate` on the TB321FU DTBs |
| `0096-media-i2c-Add-GalaxyCore-GC13A0-image-sensor-driver.patch` | mine | chip ID 0x13a0 at probe on CCI0 master 0; `cam -l` lists the sensor; one 4208x3120 capture at 30 fps with no CSID or CSIPHY errors in dmesg |
| `0097-media-dt-bindings-i2c-Add-SmartSens-SC820CS-image-se.patch` | mine | `dt_binding_check` of the binding; `dt-validate` on the TB321FU DTBs |
| `0098-media-i2c-Add-SmartSens-SC820CS-image-sensor-driver.patch` | mine | chip ID 0xd154 at probe on CCI1 master 0; `cam -l` lists the sensor; one 3264x2448 capture at 30 fps with no CSID or CSIPHY errors in dmesg |
