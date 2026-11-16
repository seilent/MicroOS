#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
gate=$tree/usr/libexec/microos/microos-sleep-gate
unit=$tree/usr/lib/systemd/system/microos-sleep-gate.service
tmp=$(mktemp -d)
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done
  rm -rf "${tmp:?}"
}
trap cleanup EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

export MICROOS_RUNDIR=$tmp/run MICROOS_CMDLINE=$tmp/cmdline MICROOS_SLEEP_GATE_STEP=0.1
export MICROOS_STUB_CONF=$tree/usr/lib/microos/stub.conf MICROOS_STUB_LIB=$tree/usr/libexec/microos/microos-stub
export MICROOS_DEVMEM=$tmp/mem MICROOS_DEVMEM_BASE=0xd60a0000

le32() { printf "$(printf '\\x%02x' $(( $1 & 0xff )) $(( $1 >> 8 & 0xff )) $(( $1 >> 16 & 0xff )) $(( $1 >> 24 & 0xff )))"; }
mem32() { le32 "$2" | dd of="$MICROOS_DEVMEM" bs=1 seek="$(( $1 ))" conv=notrunc status=none; }
stub() { mem32 0x2004 7; mem32 0x2000 $(( 0x5744 << 16 | $1 )); }
fresh() {
  rm -rf "${MICROOS_RUNDIR:?}" "$MICROOS_DEVMEM" "$tmp/err"
  mkdir -p "$MICROOS_RUNDIR"
  truncate -s $(( 0x3000 )) "$MICROOS_DEVMEM"
  echo "root=x ${1:-}" > "$MICROOS_CMDLINE"
}
start() {
  "$gate" 2> "$tmp/err" & g=$!
  pids+=("$g")
}
ended() {
  for _ in {1..30}; do kill -0 "$g" 2> /dev/null || return 0; sleep 0.1; done
  return 1
}
said() { grep -qx "microos-sleep-gate: $1" "$tmp/err"; }

for s in 3 4 0; do
  fresh
  [[ $s == 0 ]] || stub "$s"
  start
  sleep 0.5
  kill -0 "$g" 2> /dev/null || fail "stub $s: gate ended before the boot was confirmed"
  touch "$MICROOS_RUNDIR/boot-confirmed"
  ended || fail "stub $s: gate still holds after the confirm"
  wait "$g" || fail "stub $s: gate exit $?"
done
said "boot confirmed, stub absent, sleep allowed" || fail "absent line: $(cat "$tmp/err")"

for s in 1 2; do
  fresh
  stub "$s"
  touch "$MICROOS_RUNDIR/boot-confirmed"
  start
  ! ended || fail "stub $s: gate dropped the block with the stub armed"
  said "boot confirmed, stub running, sleep stays blocked" || fail "stub $s: $(cat "$tmp/err")"
  [[ $(grep -c . "$tmp/err") == 1 ]] || fail "stub $s: repeated lines: $(cat "$tmp/err")"
  stub 3
  ended || fail "stub $s: gate still holds after the stub stopped"
  said "boot confirmed, stub stopped, sleep allowed" || fail "stub $s stopped: $(cat "$tmp/err")"
done

fresh
rm -f "$MICROOS_DEVMEM"
touch "$MICROOS_RUNDIR/boot-confirmed"
start
! ended || fail "no devmem: gate dropped the block"
said "boot confirmed, stub unreadable, sleep stays blocked" || fail "no devmem: $(cat "$tmp/err")"
kill "$g"

fresh "microos.test=once"
stub 3
touch "$MICROOS_RUNDIR/boot-confirmed"
start
! ended || fail "microos.test=once: gate dropped the block"
said "microos.test=once, sleep stays blocked this boot" || fail "once: $(cat "$tmp/err")"
kill "$g"

fresh
MICROOS_STUB_LIB=$tmp/none start
! ended || fail "missing lib: gate dropped the block"
grep -q "^microos-sleep-gate: missing .*, sleep stays blocked this boot$" "$tmp/err" || fail "missing lib: $(cat "$tmp/err")"
kill "$g"

fresh
MICROOS_SLEEP_GATE_STEP=bogus start
! ended || fail "unexpected error: gate dropped the block"
said "unexpected error, sleep stays blocked this boot" || fail "unexpected error: $(cat "$tmp/err")"
kill "$g"

grep -qxF 'ExecStart=/usr/bin/systemd-inhibit --what=sleep --mode=block --who=microos-sleep-gate "--why=boot not confirmed or stub armed" /usr/libexec/microos/microos-sleep-gate' "$unit" \
  || fail "microos-sleep-gate.service ExecStart"
for l in Restart=on-failure StartLimitIntervalSec=0 Before=display-manager.service After=systemd-logind.service WantedBy=multi-user.target; do
  grep -qxF "$l" "$unit" || fail "microos-sleep-gate.service lacks $l"
done

if (( rc == 0 )); then
  echo "sleep-gate: ok"
fi
exit "$rc"
