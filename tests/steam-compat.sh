#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

command -v python3 > /dev/null || { echo "FAIL: python3 missing" >&2; exit 1; }

MICROOS_TREE=$tree python3 "$here/steam-compat/module.py" || fail "module tests"

if (( rc == 0 )); then
  echo "steam-compat: ok"
fi
exit "$rc"
