# audioreach-topology patches

`audioreach-topology` applies `patches/` on top of the upstream commit in `SOURCE.env` and builds only
`Lenovo-Y700-TB321FU-tplg.bin` (`m4`, then `alsatplg`), installed as
`/usr/lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin`. q6apm loads `qcom/<driver>/<card model>-tplg.bin`;
the card model is `Lenovo-Y700-TB321FU` and the driver `sm8650`. `firmware_class.path=/var/lib/microos/fw` is
searched first, so a topology the installer puts there with `--tplg` replaces this one.

| Patch | Origin | Why on the Y700 | Test |
|---|---|---|---|
| 0001 audioreach: add legacy TDM sink module and device subgraph | mine, written for MicroOS, upstream style | the speaker PAs sit on Secondary TDM; the `pineapple_qrd` ACDB holds only the legacy TDM modules (0x0700100E/F) and upstream has no m4 for them: `module_tdm.m4`, `subgraph-device-tdm-playback.m4` ([MFC] -> [TDM EP]), `DEVICE_TDM_SG_ADD` with slots per frame, slot width and the frame sync setup, tokens `SYNC_SRC` (262), `CTRL_DATA_OUT_ENABLE` (263), `NSLOTS_PER_FRAME` (265), `SLOT_WIDTH` (266), `SYNC_MODE` (267), `CTRL_INVERT_SYNC_PULSE` (268), `CTRL_SYNC_DATA_DELAY` (269) | `tests/pkg-audioreach-topology.sh` |
| 0002 audioreach: add tplg for Lenovo Legion Y700 (2025) | mine, written for MicroOS, upstream style | `SM8650-LENOVO-TB321FU.m4`: SM8650-QRD's MultiMedia1 to 4, RX_CODEC_DMA_RX_0, VA_CODEC_DMA_TX_0 and TX_CODEC_DMA_TX_3, WSA replaced by `SEC_TDM_RX_0` (Secondary TDM0, 8 slots of 32 bit at 48 kHz, internal frame sync, data out on, short sync, no data delay: the ACDB TDM interface config); a CMake entry | `tests/pkg-audioreach-topology.sh` |

The graph matches the topology the unit runs today in widget, PCM, mixer, control and route names and in module,
instance, subgraph and container ids (`REF_TPLG=<that file> tests/pkg-audioreach-topology.sh <rpmdir>`). The TDM
module differs in its tokens only: it carries `NSLOTS_PER_FRAME` 8, `SLOT_WIDTH` 32 and the frame sync tokens
where that file has `SD_LINE_IDX` 1 and `FRAME_SZ_FACTOR` 8.

## Kernel

- 7.2.12 (`packages/kernel` of the integration line, patch 0808): the TDM sink loads through the I2S token parser
  (HW_IF_TYPE 0, HW_IF_IDX 1, FMT_DATA 1) and the slot layout comes from the DAI (`set_tdm_slot`, 8 slots of 32
  bit, slot mask 0x3, back end fixed at S24_LE stereo). It reads none of the tokens 262 to 269.
- Mainline 7.4 (`packages/kernel-y700` patch `0026`): the legacy TDM sink and source load through the Audio IF token
  parser (hardware interface type and index, data format, tokens 262 to 269) and send `PARAM_ID_TDM_INTF_CFG`
  (0x0800101B); the slot mask, slots per frame and slot width come from the DAI (`dai-tdm-slot-*` in the DT, slots
  0 and 1 of 8 at 32 bit), else from 264 to 266.

## Upstream

`SOURCE.env` is the Linaro tree on git.codelinaro.org (`1d4c4e3`, 2024-10-16). The project lives on at
[linux-msm/audioreach-topology](https://github.com/linux-msm/audioreach-topology) (`d6bb205`, checked 2026-11-11),
which builds SM8650-QRD from `SM8550-HDK.m4`, has the Audio IF module (0x0700117C) with tokens 262 to 276, and no
legacy TDM module. Sending 0001 there means a rebase onto that tree, where tokens 262 to 269 already exist.

`LICENSE.audioreach-topology` is upstream's `LICENSE.BSD-3-Clause` from `d6bb205`; the tree in `SOURCE.env` has
SPDX headers and no license file.
