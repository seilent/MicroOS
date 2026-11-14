#!/usr/bin/env bash
set -euo pipefail

src=${1:?usage: dp-dither.sh <kernel source dir>}
dp=$src/drivers/gpu/drm/msm/dp/dp_display.c
enc=$src/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c
[[ -f $dp ]] || { echo "dp-dither: no $dp" >&2; exit 1; }
[[ -f $enc ]] || { echo "dp-dither: no $enc" >&2; exit 1; }

body=$(awk '/^u32 msm_dp_get_mode_bpc\(/ { on = 1 } on { print } on && /^}/ { exit }' "$dp" | tr -s ' \t\n' ' ')
[[ -n $body ]] || { echo "dp-dither: msm_dp_get_mode_bpc not found" >&2; exit 1; }

need=(
  'return msm_dp_panel_get_mode_bpp(dp->panel, bpc ? bpc * 3 : 24, mode->clock) / 3;'
  'dp->msm_dp_display.connector->display_info.bpc;'
)
for s in "${need[@]}"; do
  [[ $body == *"$s"* ]] || { echo "dp-dither: msm_dp_get_mode_bpc missing '$s'" >&2; exit 1; }
done
[[ $body != *'msm_dp_mode.bpp'* ]] || { echo "dp-dither: msm_dp_get_mode_bpc reads msm_dp_mode.bpp" >&2; exit 1; }

helper=$(awk '/^static void _dpu_encoder_virt_enable_helper\(/ { on = 1 } on { print } on && /^}/ { exit }' "$enc")
[[ -n $helper ]] || { echo "dp-dither: _dpu_encoder_virt_enable_helper not found" >&2; exit 1; }

dpbranch=$(printf '%s\n' "$helper" | awk '/intf_type == INTF_DP\) \{/ { on = 1 } on { print } on && /^\t}$/ { exit }' | tr -s ' \t\n' ' ')
[[ -n $dpbranch ]] || { echo "dp-dither: no INTF_DP branch in _dpu_encoder_virt_enable_helper" >&2; exit 1; }

need=(
  'msm_dp_get_mode_bpc('
  '&dpu_enc->cur_master->cached_mode'
  '_dpu_encoder_setup_dither(dpu_enc->hw_pp[i], bpc);'
)
for s in "${need[@]}"; do
  [[ $dpbranch == *"$s"* ]] || { echo "dp-dither: INTF_DP branch missing '$s'" >&2; exit 1; }
done

dsibranch=$(printf '%s\n' "$helper" | awk '/intf_type == INTF_DSI/ { on = 1 } on { print } on && /^\t}$/ { exit }' | tr -s ' \t\n' ' ')
[[ $dsibranch == *'unsigned bpc = dpu_enc->connector->display_info.bpc;'* ]] \
  || { echo "dp-dither: INTF_DSI branch no longer reads display_info.bpc" >&2; exit 1; }
[[ $dsibranch == *'_dpu_encoder_setup_dither(dpu_enc->hw_pp[i], bpc);'* ]] \
  || { echo "dp-dither: INTF_DSI branch no longer dithers from bpc" >&2; exit 1; }
