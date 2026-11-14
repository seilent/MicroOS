#!/usr/bin/env bash
set -euo pipefail

src=${1:?usage: dp-mode-valid.sh <kernel source dir>}
f=$src/drivers/gpu/drm/msm/dp/dp_display.c
[[ -f $f ]] || { echo "dp-mode-valid: no $f" >&2; exit 1; }

body=$(awk '/^enum drm_mode_status msm_dp_bridge_mode_valid\(/ { on = 1 } on { print } on && /^}/ { exit }' "$f" | tr -s ' \t\n' ' ')
[[ -n $body ]] || { echo "dp-mode-valid: msm_dp_bridge_mode_valid not found" >&2; exit 1; }

need=(
  'link_pclk_khz = is_yuv_420 ? mode_pclk_khz / 2 : mode_pclk_khz;'
  'mode_bpp, link_pclk_khz);'
  'mode_rate_khz = link_pclk_khz * mode_bpp;'
)
for s in "${need[@]}"; do
  [[ $body == *"$s"* ]] || { echo "dp-mode-valid: missing '$s'" >&2; exit 1; }
done
[[ $body != *'mode_rate_khz = mode_pclk_khz'* ]] || { echo "dp-mode-valid: link rate uses the halved mode clock" >&2; exit 1; }
