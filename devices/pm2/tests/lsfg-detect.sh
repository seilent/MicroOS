#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

command -v python3 > /dev/null || { echo "FAIL: python3 missing" >&2; exit 1; }

MICROOS_TREE=$tree python3 "$here/lsfg-detect/detect.py" || fail "detect tests"

user=$tree/usr/lib/systemd/user
session=(BindsTo=gamescope-session-plus@steam.service After=gamescope-session-plus@steam.service)
requisite=(Requisite=gamescope-session-plus@steam.service After=gamescope-session-plus@steam.service
  StopPropagatedFrom=gamescope-session-plus@steam.service)
has() {
  local unit=$1
  shift
  for line in "$@"; do
    grep -qxF "$line" "$user/$unit" || fail "$unit lacks $line"
  done
}
has microos-lsfg.service "${session[@]}" StartLimitIntervalSec=0 Type=oneshot StateDirectory=microos-lsfg \
  StateDirectoryMode=0700 'ExecStart=/usr/libexec/microos/microos-lsfg detect'
has microos-lsfg-send@.service "${requisite[@]}" StartLimitIntervalSec=0 Type=oneshot \
  StateDirectory=microos-lsfg StateDirectoryMode=0700 'ExecStart=/usr/libexec/microos/microos-lsfg send %i'
has microos-lsfg-retry.timer DefaultDependencies=no "${requisite[@]}" OnActiveSec=5min OnUnitActiveSec=5min \
  Unit=microos-lsfg-send@auto.service
has microos-lsfg.path DefaultDependencies=no "${session[@]}" Unit=microos-lsfg.service \
  PathChanged=%h/.local/share/Steam/config/loginusers.vdf PathChanged=%h/.local/share/Steam/userdata \
  PathChanged=%h/.local/share/Steam/appcache/packageinfo.vdf
has microos-lsfg-account@.path DefaultDependencies=no "${requisite[@]}" Unit=microos-lsfg.service \
  PathChanged=%h/.local/share/Steam/userdata/%i/config/licensecache
has microos-lsfg-library@.path DefaultDependencies=no "${requisite[@]}" Unit=microos-lsfg.service PathChanged=%f/steamapps
for u in microos-lsfg.service microos-lsfg-send@.service microos-lsfg-retry.timer microos-lsfg.path \
  microos-lsfg-account@.path microos-lsfg-library@.path; do
  grep -qE '^(PartOf|Persistent|OnCalendar|WantedBy)=' "$user/$u" && fail "$u has PartOf, Persistent, OnCalendar or WantedBy"
done
for u in microos-lsfg-send@.service microos-lsfg-retry.timer microos-lsfg-account@.path microos-lsfg-library@.path; do
  grep -q '^BindsTo=' "$user/$u" && fail "$u has BindsTo="
done
grep -qxF 'Wants=microos-lsfg.path microos-lsfg.service' "$user/gamescope-session-plus@steam.service.d/10-microos.conf" \
  || fail "the Steam session does not want microos-lsfg.path and microos-lsfg.service"

if (( rc == 0 )); then
  echo "lsfg-detect: ok"
fi
exit "$rc"
