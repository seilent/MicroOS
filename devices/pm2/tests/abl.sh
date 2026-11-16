#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}

command -v python3 > /dev/null || { echo "FAIL: python3 missing" >&2; exit 1; }
root=()
if ((EUID == 0)) && [[ -e /dev/loop-control ]] && command -v losetup > /dev/null; then
  root=(--loop "$here/abl-loop.sh")
fi
exec python3 "$here/abl/harness.py" "$tree" "${root[@]}"
