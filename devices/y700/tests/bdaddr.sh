#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
script=$tree/usr/libexec/microos/microos-bdaddr
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

export FAKE_STATE=$tmp/fake PATH=$here/bdaddr/bin:$PATH
fake=02:00:00:00:00:01

persist() {
  rm -rf "$tmp/root"
  mkdir "$tmp/root"
  [[ -z $1 ]] || printf '%s\0' "$1" > "$tmp/root/bd_addr.bin"
  rm -f "$tmp/persist.img"
  mkfs.ext4 -q -F -d "$tmp/root" "$tmp/persist.img" 4M
}
run() {
  rm -rf "$FAKE_STATE"
  mkdir -p "$FAKE_STATE"
  env MICROOS_PERSIST="${dev:-$tmp/persist.img}" MICROOS_BDADDR_TRIES=2 "$script" "$@" > "$tmp/out" 2> "$tmp/err"
}
calls() { cat "$FAKE_STATE/btmgmt" 2>/dev/null || true; }
refused() {
  if run "$1"; then fail "$2: rc 0"; fi
  [[ -z $(calls) ]] || fail "$2: btmgmt called: $(calls)"
  grep -q "stays unconfigured" "$tmp/err" || fail "$2: no log line"
}

persist "$fake"
run hci0 || fail "valid: rc $?"
[[ $(calls) == "--index 0 public-addr $fake" ]] || fail "valid: btmgmt $(calls)"
! grep -q "$fake" "$tmp/out" "$tmp/err" || fail "valid: the address is logged"
run hci1 || fail "hci1: rc $?"
[[ $(calls) == "--index 1 public-addr $fake" ]] || fail "hci1: btmgmt $(calls)"

refused foo "bad name"
refused "" "no name"
persist ""
refused hci0 "no bd_addr.bin"
persist "not an address"
refused hci0 "garbage"
persist "00:00:00:00:00:00"
refused hci0 "zero address"
persist "FF:FF:FF:FF:FF:FF"
refused hci0 "broadcast address"
persist "$fake"
dev=$tmp/missing refused hci0 "no persist device"

if FAKE_BTMGMT_FAIL=1 run hci0; then fail "btmgmt failing: rc 0"; fi
[[ $(calls | wc -l) == 2 ]] || fail "btmgmt failing: $(calls | wc -l) calls"
grep -q "stays unconfigured" "$tmp/err" || fail "btmgmt failing: no log line"

if (( rc == 0 )); then
  echo "bdaddr: ok"
fi
exit "$rc"
