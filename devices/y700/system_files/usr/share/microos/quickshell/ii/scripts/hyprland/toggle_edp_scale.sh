#!/usr/bin/env bash
set -uo pipefail

export PATH="$HOME/hyprland/prefix/bin:$HOME/.local/bin:$PATH"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
: "${HYPRLAND_INSTANCE_SIGNATURE:=$(ls -t "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | grep -v '\.lock' | head -1)}"
export HYPRLAND_INSTANCE_SIGNATURE

mon="eDP-1"
scaled="0.75"
native="1"
state="$HOME/.config/hypr/.edp-portable-scale"
regen="$HOME/.config/hypr/custom/scripts/mirror-to-external.sh"
log="${XDG_STATE_HOME:-$HOME/.local/state}/edp-scale-toggle.log"
mkdir -p "$(dirname "$log")"
logmsg() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$log"; }

logmsg "--- invoke (HIS=$HYPRLAND_INSTANCE_SIGNATURE) ---"

mof=$(hyprctl monitors all -j 2>>"$log" | jq -r --arg m "$mon" '.[] | select(.name==$m) | .mirrorOf // "none"')
if [ "$mof" != "none" ]; then
    logmsg "SKIP: eDP-1 mirrors $mof; per-output scale is ignored while mirroring"
    exit 0
fi

cur=$(cat "$state" 2>/dev/null || echo 1)
case "$cur" in 0.75) next="$native" ;; *) next="$scaled" ;; esac
printf '%s\n' "$next" >"$state"
logmsg "portable scale $cur -> $next"

if [ ! -x "$regen" ]; then
    logmsg "ERROR: regen script missing/non-executable: $regen"
    exit 1
fi
"$regen" --force >>"$log" 2>&1
logmsg "regen rc=$?"

sleep 0.5
logmsg "after: $(hyprctl -j monitors all 2>/dev/null | jq -r --arg m "$mon" '.[] | select(.name==$m) | "scale=\(.scale) logical=\((.width/.scale)|floor)x\((.height/.scale)|floor)"') (target scale=$next)"
