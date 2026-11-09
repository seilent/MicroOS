#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
units=$tree/usr/lib/systemd/user
target=$units/microos-desktop-ready.target
home=$units/microos-desktop-home.service
desktop=$units/microos-desktop.service
env=$tree/usr/libexec/microos/microos-desktop-env
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
at() { grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1 || true; }

grep -qxF 'Requisite=microos-desktop.service' "$target" || fail "the ready target has no Requisite"
grep -qxF 'After=microos-desktop.service' "$target" || fail "the ready target has no After"
grep -qxF 'Wants=microos-desktop-home.service microset-launcher.service' "$target" || fail "the ready target does not want the home and the launcher"
! grep -q '^BindsTo=' "$target" || fail "the ready target binds to the desktop"

grep -qxF 'Type=simple' "$home" || fail "the home unit is not Type=simple"
grep -qxF 'Requisite=microos-desktop-ready.target' "$home" || fail "the home unit has no Requisite"
grep -qxF 'After=microos-desktop-ready.target' "$home" || fail "the home unit has no After"
grep -qxF 'PartOf=microos-desktop-ready.target' "$home" || fail "the home unit has no PartOf"
grep -qxF 'ExecStart=/usr/libexec/microos/microos-desktop-home' "$home" || fail "the home unit start line"
grep -qxF 'Restart=on-failure' "$home" || fail "the home unit restart line"

a=$(at "$env" 'dbus-update-activation-environment --systemd')
b=$(at "$env" 'systemctl --user --no-block start microos-desktop-ready.target')
[[ -n $a && -n $b ]] && (( a < b )) || fail "the ready target start is not after the activation env import"

s=$(at "$desktop" 'ExecStopPost=-/usr/bin/systemctl --user stop --no-block microos-desktop-ready.target')
u=$(at "$desktop" 'unset-environment WAYLAND_DISPLAY')
[[ -n $s && -n $u ]] && (( s < u )) || fail "the ready target stop is not before the env unset"

repo=$tree/usr/share/microos/flatpak/flathub.flatpakrepo
[[ -f $repo ]] || fail "the flathub repo file is missing"
[[ $(sha256sum < "$repo" | cut -d' ' -f1) == 3371dd250e61d9e1633630073fefda153cd4426f72f4afa0c3373ae2e8fea03a ]] ||
  fail "the flathub repo file sha256"

remote=$units/microos-flatpak-remote.service
grep -qxF 'Type=oneshot' "$remote" || fail "the flatpak remote unit is not Type=oneshot"
grep -qxF 'Before=microset-launcher.service' "$remote" || fail "the flatpak remote unit is not before the launcher"
grep -qxF 'ExecStart=/usr/bin/flatpak remote-add --user --if-not-exists flathub /usr/share/microos/flatpak/flathub.flatpakrepo' \
  "$remote" || fail "the flatpak remote add line"
grep -qxF 'ExecStart=/usr/bin/mkdir -p %h/.local/share/flatpak/exports/share/applications' "$remote" ||
  fail "the flatpak exports line"
grep -qxF 'Wants=microos-flatpak-remote.service' "$units/microos-desktop-ready.target.d/30-microos-flatpak-remote.conf" ||
  fail "the ready target does not want the flatpak remote unit"

keys=$tree/usr/lib/microos/hotkeys.d/desktop.conf
launcher="call net.seilent.MicroSet.Launcher /net/seilent/MicroSet/Launcher net.seilent.MicroSet.Launcher1"
grep -qxF "lc tap $launcher Toggle" "$keys" || fail "the lc tap row"
grep -qxF "power hold $launcher ShowPower" "$keys" || fail "the power hold row"

if ((rc == 0)); then
  echo "desktop-ready: ok"
fi
exit "$rc"
