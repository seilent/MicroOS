#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

command -v python3 > /dev/null || { echo "FAIL: python3 missing" >&2; exit 1; }

MICROOS_TREE=$tree python3 "$here/steam-compat/module.py" || fail "module tests"
MICROOS_TREE=$tree python3 "$here/steam-compat/helper.py" || fail "helper tests"
MICROOS_TREE=$tree python3 "$here/steam-compat/vk.py" || fail "vk features tests"

unit=$tree/usr/lib/systemd/system/microos-vk-features.service
grep -q '^ReadWritePaths=' "$unit" && fail "microos-vk-features.service has ReadWritePaths"
for line in Type=oneshot RemainAfterExit=yes Before=display-manager.service \
  ExecStart=/usr/libexec/microos/microos-vk-features Environment=MESA_SHADER_CACHE_DISABLE=true ProtectSystem=strict \
  RuntimeDirectory=microos/vk NoNewPrivileges=yes CapabilityBoundingSet= DevicePolicy=closed 'DeviceAllow=/dev/char/226:128 rw' \
  WantedBy=multi-user.target; do
  grep -qxF "$line" "$unit" || fail "microos-vk-features.service lacks $line"
done

path=$tree/usr/lib/systemd/user/microos-steam-compat-refresh.path
for line in DefaultDependencies=no BindsTo=gamescope-session-plus@steam.service After=gamescope-session-plus@steam.service \
  PathChanged=%h/.local/share/Steam/appcache/appinfo.vdf Unit=microos-steam-compat-refresh.service; do
  grep -qxF "$line" "$path" || fail "microos-steam-compat-refresh.path lacks $line"
done
grep -q '^PartOf=' "$path" && fail "microos-steam-compat-refresh.path has PartOf="
refresh=$tree/usr/lib/systemd/user/microos-steam-compat-refresh.service
for line in StartLimitIntervalSec=0 Type=oneshot TimeoutStartSec=90 Nice=10 IOSchedulingClass=idle \
  'ExecStart=/usr/libexec/microos/microos-steam-compat refresh'; do
  grep -qxF "$line" "$refresh" || fail "microos-steam-compat-refresh.service lacks $line"
done
grep -qxF Wants=microos-steam-compat-refresh.path "$tree/usr/lib/systemd/user/gamescope-session-plus@steam.service.d/10-microos.conf" \
  || fail "the Steam session does not want microos-steam-compat-refresh.path"

if (( rc == 0 )); then
  echo "steam-compat: ok"
fi
exit "$rc"
