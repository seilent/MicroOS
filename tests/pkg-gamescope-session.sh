#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-gamescope-session.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

check() {
  local name=$1 rpm
  shift
  rpm=$(find "$dir" -maxdepth 1 -name "$name-0^*.noarch.rpm")
  if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 ]]; then fail "$name: expected one noarch RPM in $dir"; return 0; fi

  local srpm
  srpm=$(find "$dir" -maxdepth 1 -name "$name-0^*.src.rpm")
  if [[ -z $srpm || $(wc -l <<<"$srpm") -ne 1 ]]; then fail "$name: expected one SRPM in $dir"
  elif [[ $(rpm -qp --qf '%{SOURCERPM}' "$rpm") != "${srpm##*/}" ]]; then fail "$name: SOURCERPM is not ${srpm##*/}"; fi

  if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "$name: release"; fi
  if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "$name: vendor"; fi
  if grep -qE '^steam( |$)' <<<"$(rpm -qp --requires "$rpm")"; then fail "$name: requires steam"; fi

  local writable
  writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
  if [[ -n $writable ]]; then fail "$name: group or other writable: $writable"; fi

  local files
  files=$(rpm -qlp "$rpm")
  if ! grep -qx "/usr/share/licenses/$name/LICENSE" <<<"$files"; then fail "$name: license file"; fi
  local f
  for f in "$@"; do
    if [[ $f == !* ]]; then
      if grep -q "^${f#!}" <<<"$files"; then fail "$name: ships ${f#!}"; fi
    elif ! grep -qx "$f" <<<"$files"; then
      fail "$name: missing $f"
    fi
  done
}

check gamescope-session \
  /usr/bin/export-gpu \
  /usr/bin/gamescope-session-plus \
  /usr/lib/systemd/user/gamescope-session-plus@.service \
  /usr/lib/systemd/user/gamescope-session.target \
  /usr/share/gamescope-session-plus/device-quirks \
  /usr/share/gamescope-session-plus/gamescope-session-plus \
  /usr/share/gamescope-session-plus/sessions.d \
  /usr/share/gamescope/scripts/50-custom/50-disable-explicit-sync.lua

check gamescope-session-steam \
  /usr/bin/steam-http-loader \
  /usr/share/applications/gamescope-mimeapps.list \
  /usr/share/applications/steam_http_loader.desktop \
  /usr/share/gamescope-session-plus/sessions.d/steam \
  /usr/share/wayland-sessions/gamescope-session-steam.desktop \
  '!/usr/bin/jupiter-biosupdate' \
  '!/usr/bin/steamos-update' \
  '!/usr/bin/steamos-select-branch' \
  '!/usr/bin/steamos-session-select' \
  '!/usr/bin/steamos-polkit-helpers' \
  '!/usr/share/polkit-1/actions/org.chimeraos.update.policy'

debug=$(find "$dir" -maxdepth 1 \( -name '*-debuginfo-*' -o -name '*-debugsource-*' \))
if [[ -n $debug ]]; then fail "debug RPMs: $debug"; fi

exit "$rc"
