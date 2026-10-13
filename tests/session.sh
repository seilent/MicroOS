#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
root=${MICROOS_SESSION_ROOT:-/}
share=$root/usr/share/gamescope-session-plus
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

[[ -f $share/gamescope-session-plus && -f $share/device-quirks && -f $share/sessions.d/steam ]] ||
  { echo "FAIL: no gamescope-session-plus under $root" >&2; exit 1; }
[[ -f $tree/etc/gamescope-session-plus/sessions.d/steam ]] || fail "no MicroOS sessions.d/steam under $tree/etc"
[[ ! -e $tree/etc/first-boot/bootstraplinux_ubuntu12_32.tar.xz ]] || fail "the x86 bootstrap archive is present"

mkdir -p "$tmp/bin" "$tmp/t" "$tmp/noetc"
sed -e "s|^DMI_PATH=.*|DMI_PATH=$tmp/none|" -e "s|^DT_PATH=.*|DT_PATH=$tmp/model|" \
  "$share/device-quirks" > "$tmp/device-quirks"
grep -qx "DT_PATH=$tmp/model" "$tmp/device-quirks" || fail "DT_PATH not found in device-quirks"
grep -qx "DMI_PATH=$tmp/none" "$tmp/device-quirks" || fail "DMI_PATH not found in device-quirks"

launcher() {
  sed -e "s|/tmp/|$tmp/t/|g" \
    -e "s|/usr/share/gamescope-session-plus/device-quirks|$tmp/device-quirks|g" \
    -e "s|^declare -r CLIENT_CONFIG_DIR_USR=.*|declare -r CLIENT_CONFIG_DIR_USR=$share/sessions.d|" \
    -e "s|^declare -r CLIENT_CONFIG_DIR_ETC=.*|declare -r CLIENT_CONFIG_DIR_ETC=$1|" \
    "$share/gamescope-session-plus" > "$2"
  grep -qF ". $tmp/device-quirks" "$2" || fail "device-quirks source line not found in the launcher"
  grep -qx "declare -r CLIENT_CONFIG_DIR_ETC=$1" "$2" || fail "CLIENT_CONFIG_DIR_ETC not found in the launcher"
  grep -q "^short_session_tracker_file=\"$tmp/t/" "$2" || fail "short session tracker not found in the launcher"
}
launcher "$tree/etc/gamescope-session-plus/sessions.d" "$tmp/gsp"
launcher "$tmp/noetc" "$tmp/gsp-noetc"

cat > "$tmp/bin/gamescope" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --help ]]; then
  cat >&2 <<'HELP'
usage: gamescope [options...] -- [command...]
  --prefer-output                list of connectors in order of preference
  --force-orientation            rotate the internal display (left, right, normal, upsidedown)
  --force-panel-type             force gamescope to treat the display as either internal or external
  --custom-refresh-rates         set custom refresh rates for the output
  --fake-output-mm               set the physical size of the output in millimeters (WxH)
  --touch-gestures               enable touch gestures
HELP
  exit 0
fi
printf '%s\n' "$@" > "$STUB_DIR/gamescope.argv"
while (( $# )); do
  [[ $1 == -R ]] && sock=$2
  shift
done
sleep "${STUB_DELAY:-0}"
echo ":9 gamescope-9" > "$sock"
exec sleep 30
EOF
cat > "$tmp/bin/steam" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_DIR/steam.argv"
echo "${STEAM_DISPLAY_REFRESH_LIMITS:-}" > "$STUB_DIR/steam.limits"
EOF
for t in tar steamosctl; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_DIR/%s.log"\n' "$t" "$t" > "$tmp/bin/$t"
done
printf '#!/usr/bin/env bash\nexec sleep 1\n' > "$tmp/bin/mangoapp"
chmod +x "$tmp/bin/"*

session() {
  local gsp=$1 model=$2
  rm -rf "$tmp/out" "$tmp/home" "$tmp/run"
  mkdir -p "$tmp/out" "$tmp/home" "$tmp/run"
  chmod 700 "$tmp/run"
  printf '%s\0' "$model" > "$tmp/model"
  r=0
  env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" GAMESCOPE_BIN="$tmp/bin/gamescope" \
    STUB_DIR="$tmp/out" STUB_DELAY="${delay:-0}" timeout 60 bash "$gsp" steam > "$tmp/log" 2>&1 || r=$?
}
args() { echo " $(paste -sd' ' "$tmp/out/gamescope.argv" 2> /dev/null) "; }

session "$tmp/gsp" "AYANEO Pocket MICRO 2"
a=$(args)
for want in "--fake-output-mm 177x118" "--prefer-output *,DSI-1"; do
  [[ $a == *" $want "* ]] || fail "gamescope argv lacks '$want': $a"
done
for no in --force-orientation --custom-refresh-rates; do
  [[ $a != *" $no "* ]] || fail "gamescope argv has $no: $a"
done
[[ $(cat "$tmp/out/steam.argv" 2> /dev/null) == "-gamepadui -steamos3 -steampal -steamdeck" ]] ||
  fail "steam argv: $(cat "$tmp/out/steam.argv" 2> /dev/null)"
[[ -e $tmp/out/steam.limits && -z $(cat "$tmp/out/steam.limits") ]] || fail "STEAM_DISPLAY_REFRESH_LIMITS set for steam"
[[ ! -e $tmp/out/tar.log ]] || fail "tar ran: $(cat "$tmp/out/tar.log")"

session "$tmp/gsp" "Some Other Board"
a=$(args)
[[ $a == *" --prefer-output *,eDP-1 "* ]] || fail "default connector on another model: $a"
[[ $a != *"--fake-output-mm"* ]] || fail "PM2 values on another model: $a"

delay=7 session "$tmp/gsp" "AYANEO Pocket MICRO 2"
[[ -e $tmp/out/steam.argv ]] || fail "PM2 session gave up on a gamescope that is ready after 7 s: $(tail -n 3 "$tmp/log")"
delay=7 session "$tmp/gsp" "Some Other Board"
[[ ! -e $tmp/out/steam.argv ]] || fail "the 5 s default did not apply on another model, the case proves nothing"

printf 'steam failed\n%.0s' 1 2 3 4 5 > "$tmp/t/chimeraos-short-session-tracker"
session "$tmp/gsp" "AYANEO Pocket MICRO 2"
(( r == 1 )) || fail "short session exit $r"
grep -qx "microos: short Steam session, recovery is off" "$tmp/log" || fail "no recovery off line: $(tail -n 5 "$tmp/log")"
[[ ! -e $tmp/out/steamosctl.log ]] || fail "steamosctl ran with the override: $(cat "$tmp/out/steamosctl.log")"
[[ ! -e $tmp/out/tar.log ]] || fail "tar ran in the recovery: $(cat "$tmp/out/tar.log")"
[[ ! -e $tmp/out/gamescope.argv ]] || fail "gamescope started after the short session limit"
[[ ! -e $tmp/t/chimeraos-short-session-tracker ]] || fail "tracker not rearmed"

printf 'steam failed\n%.0s' 1 2 3 4 5 > "$tmp/t/chimeraos-short-session-tracker"
session "$tmp/gsp-noetc" "AYANEO Pocket MICRO 2"
grep -q "steamosctl switch-to-desktop-mode" "$tmp/out/steamosctl.log" 2> /dev/null ||
  fail "upstream recovery did not run without the override, the case proves nothing"

if (( rc == 0 )); then
  echo "session: ok"
fi
exit "$rc"
