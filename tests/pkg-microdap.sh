#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-microdap.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

srpm=$(find "$dir" -maxdepth 1 -name 'microdap-0^*.src.rpm')
if [[ -z $srpm || $(wc -l <<<"$srpm") -ne 1 ]]; then fail "expected one SRPM in $dir"; fi
if [[ -n $(find "$dir" -maxdepth 1 \( -name '*-debuginfo-*' -o -name '*-debugsource-*' \)) ]]; then fail "debug RPM present"; fi
rpm=$(find "$dir" -maxdepth 1 -name 'microdap-0^*.rpm' ! -name '*.src.rpm')
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 ]]; then
  echo "FAIL: expected one microdap RPM in $dir" >&2
  exit 1
fi
if [[ -n $(find "$dir" -maxdepth 1 -name '*.rpm' ! -name 'microdap-0^*') ]]; then fail "RPMs other than microdap in $dir"; fi

if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "release"; fi
if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi
if [[ $(rpm -qp --qf '%{LICENSE}' "$rpm") != GPL-2.0-or-later ]]; then fail "license tag"; fi
if [[ -n $srpm && $(rpm -qp --qf '%{SOURCERPM}' "$rpm") != "${srpm##*/}" ]]; then fail "SOURCERPM"; fi
writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi

requires=$(rpm -qp --requires "$rpm" | awk '{ print $1 }')
for r in microset microset-fonts qt6-qtbase qt6-qtbase-gui qt6-qtdeclarative gstreamer1 gstreamer1-plugins-base \
  gstreamer1-plugins-good gstreamer1-plugin-libav taglib pulseaudio-libs pulseaudio-libs-glib2 alsa-lib libxcb \
  python3-dbus python3-gobject NetworkManager gamescope-session; do
  if ! grep -qxE "$r(\(.*\))?" <<<"$requires"; then fail "does not require $r"; fi
done

files=$(rpm -qlp "$rpm")
for f in \
  /usr/share/licenses/microdap/LICENSE \
  /usr/bin/microdap-player \
  /usr/libexec/microdap/microdap-bt \
  /usr/libexec/microdap/microdap-fiio \
  /usr/libexec/microdap/microdap-keep \
  /usr/libexec/microdap/microdap-radio \
  /usr/libexec/microdap/microdap-stopped \
  /usr/libexec/microdap/microdap-usb-audio \
  /usr/libexec/microdap/microdap-wait-x \
  /usr/share/dbus-1/interfaces/net.seilent.MicroDap.Player.xml \
  /usr/share/microset/schema.d/50-microdap.json \
  /usr/share/wayland-sessions/microdap.desktop \
  /usr/share/gamescope-session-plus/sessions.d/microdap \
  /usr/lib/microos/sessions.d/microdap.conf \
  /usr/lib/microos/hotkeys.d/microdap.conf \
  /usr/lib/microos/hotkeys.d/steam.conf.d/50-microdap.conf \
  /usr/lib/microos/hotkeys.d/microemu.conf.d/50-microdap.conf \
  /usr/lib/systemd/user/gamescope-session-plus@microdap.service.d/05-microdap-fiio.conf \
  /usr/lib/systemd/user/gamescope-session-plus@microdap.service.d/50-microdap.conf \
  /usr/lib/systemd/user/gamescope-session-plus@steam.service.d/40-microdap-fiio.conf \
  /usr/lib/systemd/user/microdap-overlay.service \
  /usr/lib/systemd/user/microdap-bt.service \
  /usr/lib/systemd/user/microdap-fiio-reset.service \
  /usr/lib/systemd/user-preset/70-microdap.preset \
  /usr/lib/systemd/system/microdap-radio.service \
  /usr/lib/systemd/system/microdap-usb-audio.service \
  /usr/lib/systemd/system-preset/70-microdap.preset \
  /usr/lib/udev/rules.d/70-microdap-usb-audio.rules; do
  if ! grep -qx "$f" <<<"$files"; then fail "missing $f"; fi
done
bad=$(grep -E '^/usr/lib/extension-release\.d/|^/var/lib/extensions|^/usr/lib/armada|/usr/libexec/microdap/microdap-(priv|guard|hotkeyd|powerd|power|pad|intercept|switch|codec)$|^/usr/share/(polkit-1|pipewire|wireplumber)/|^/usr/share/fonts/' <<<"$files" || true)
if [[ -n $bad ]]; then fail "files that MicroOS or MicroSET own, or that left MicroDAP: $bad"; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rpm2cpio "$rpm" > "$tmp/microdap.cpio"
(cd "$tmp" && cpio -idm --quiet < microdap.cpio)
rm "$tmp/microdap.cpio"

hits=$(grep -rlisI armada "$tmp" || true)
if [[ -n $hits ]]; then fail "armada named in text file ${hits//$tmp/}"; fi
hits=$(grep -rls set-default-sink "$tmp" || true)
if [[ -n $hits ]]; then fail "set-default-sink in ${hits//$tmp/}"; fi
hits=$(grep -rlsE 'EPOCHREALTIME|date \+%s' "$tmp/usr/libexec" || true)
if [[ -n $hits ]]; then fail "wall clock in ${hits//$tmp/}"; fi

while read -r mode f; do
  if [[ ($f == /usr/bin/* || $f == /usr/libexec/microdap/*) && ${mode: -3} != 755 ]]; then fail "$f is not 755"; fi
done < <(rpm -qp --qf '[%{FILEMODES:octal} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 2) == "10"')

conf=$tmp/usr/lib/microos/sessions.d/microdap.conf
for kv in LABEL=MicroDAP DESKTOP=microdap.desktop UNIT=gamescope-session-plus@microdap.service STOP=unit DEFAULT=yes; do
  if ! grep -qx "$kv" "$conf"; then fail "sessions.d/microdap.conf lacks $kv"; fi
done
if ! grep -qx 'Exec=gamescope-session-plus microdap' "$tmp/usr/share/wayland-sessions/microdap.desktop"; then fail "microdap.desktop Exec"; fi
client=$tmp/usr/share/gamescope-session-plus/sessions.d/microdap
for kv in CLIENTCMD=/usr/bin/microdap-player QT_QPA_PLATFORM=xcb ORIENTATION=normal; do
  if ! grep -qE "^(export )?$kv\$" "$client"; then fail "sessions.d/microdap lacks $kv"; fi
done
if sed -n '/^short_session_recover()/,/^}/p' "$client" | grep -qE 'systemctl|switch'; then fail "short_session_recover in sessions.d/microdap switches"; fi

player=net.seilent.MicroDap.Player
table=$tmp/usr/lib/microos/hotkeys.d/microdap.conf
for row in 'guide tap none' 'guide hold none' \
  "power tap call $player /net/seilent/MicroDap/Player $player ToggleScreen" \
  "power hold call $player /net/seilent/MicroDap/Player $player ShowPowerMenu"; do
  if ! grep -qxF "$row" "$table"; then fail "hotkeys.d/microdap.conf lacks '$row'"; fi
done
if grep -qE '^(volup|voldown)[[:space:]]' "$table"; then fail "hotkeys.d/microdap.conf has volume rows"; fi
steam=$tmp/usr/lib/microos/hotkeys.d/steam.conf.d/50-microdap.conf
for row in "guide tap call $player /net/seilent/MicroDap/Player $player ToggleOverlay" 'guide hold switch microdap confirm-in-game'; do
  if ! grep -qxF "$row" "$steam"; then fail "steam.conf.d/50-microdap.conf lacks '$row'"; fi
done
if ! grep -qxF 'guide hold switch microdap confirm-in-game' "$tmp/usr/lib/microos/hotkeys.d/microemu.conf.d/50-microdap.conf"; then
  fail "microemu.conf.d/50-microdap.conf lacks the guide hold switch"
fi

dropin=$tmp/usr/lib/systemd/user/gamescope-session-plus@microdap.service.d/50-microdap.conf
if ! grep -qx 'ExecStopPost=-/usr/libexec/microdap/microdap-stopped' "$dropin"; then fail "session drop-in lacks the microdap-stopped ExecStopPost"; fi
radio=$tmp/usr/lib/systemd/system/microdap-radio.service
for kv in Type=oneshot After=NetworkManager.service; do
  if ! grep -qx "$kv" "$radio"; then fail "microdap-radio.service lacks $kv"; fi
done
for u in microdap-radio.service microdap-usb-audio.service; do
  if ! grep -qx "enable $u" "$tmp/usr/lib/systemd/system-preset/70-microdap.preset"; then fail "system preset does not enable $u"; fi
done
for u in microdap-overlay.service microdap-bt.service; do
  if ! grep -qx "enable $u" "$tmp/usr/lib/systemd/user-preset/70-microdap.preset"; then fail "user preset does not enable $u"; fi
  if ! grep -q '^\[Install\]' "$tmp/usr/lib/systemd/user/$u"; then fail "$u has no [Install]"; fi
done
if ! grep -qx 'WantedBy=gamescope-session-plus@steam.service' "$tmp/usr/lib/systemd/user/microdap-overlay.service"; then
  fail "microdap-overlay.service is not wanted by the Steam session"
fi

python3 - "$tmp/usr/share/microset/schema.d/50-microdap.json" <<'PY' || rc=1
import json, re, sys

path = sys.argv[1]
rc = 0
types = {"s": str, "b": bool, "u": int, "i": int, "d": (int, float), "as": list}
with open(path) as f:
    doc = json.load(f)
if doc.get("owner") != "microdap":
    print(f"FAIL: {path}: owner {doc.get('owner')!r}", file=sys.stderr)
    rc = 1
keys = doc.get("keys")
if not isinstance(keys, dict) or not keys:
    print(f"FAIL: {path}: no keys", file=sys.stderr)
    sys.exit(1)
for key, k in keys.items():
    if not re.fullmatch(r"microdap(\.[A-Za-z0-9_]+)+", key) or not re.fullmatch(r"[a-z][a-z0-9]*(\.[A-Za-z0-9_]+)+", key):
        print(f"FAIL: {path}: key {key} outside microdap.*", file=sys.stderr)
        rc = 1
    t = k.get("type")
    if t not in types:
        print(f"FAIL: {path}: {key} type {t}", file=sys.stderr)
        rc = 1
        continue
    d = k.get("default")
    if d is None or not isinstance(d, types[t]) or (t != "b" and isinstance(d, bool)):
        print(f"FAIL: {path}: {key} default {d!r} is not {t}", file=sys.stderr)
        rc = 1
    if "enum" in k and d not in k["enum"]:
        print(f"FAIL: {path}: {key} default {d!r} not in enum", file=sys.stderr)
        rc = 1
    if "min" in k and "max" in k and not k["min"] <= d <= k["max"]:
        print(f"FAIL: {path}: {key} default {d!r} out of range", file=sys.stderr)
        rc = 1
rgb = keys.get("microdap.rgb", {})
if sorted(rgb.get("enum", [])) != ["accent", "off", "system"]:
    print(f"FAIL: {path}: microdap.rgb enum {rgb.get('enum')}", file=sys.stderr)
    rc = 1
sys.exit(rc)
PY

exit "$rc"
