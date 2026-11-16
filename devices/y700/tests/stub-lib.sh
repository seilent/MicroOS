#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

. "$tree/usr/lib/microos/stub.conf"
. "$tree/usr/libexec/microos/microos-stub"
export MICROOS_DEVMEM=$tmp/mem MICROOS_DEVMEM_BASE=0xd60a0000 MICROOS_STUB_WAIT=2

le32() { printf "$(printf '\\x%02x' $(( $1 & 0xff )) $(( $1 >> 8 & 0xff )) $(( $1 >> 16 & 0xff )) $(( $1 >> 24 & 0xff )))"; }
mem32() { le32 "$2" | dd of="$MICROOS_DEVMEM" bs=1 seek="$(( $1 ))" conv=notrunc status=none; }
memword() { od -An -tu4 -j "$(( $1 ))" -N4 "$MICROOS_DEVMEM" | tr -d ' '; }
stub() { mem32 0x2004 "$2"; mem32 0x2000 $(( ${3:-0x5744} << 16 | $1 )); }
fresh() {
  rm -f "$MICROOS_DEVMEM"
  truncate -s $(( 0x3000 )) "$MICROOS_DEVMEM"
}
responder() {
  for _ in $(seq 1 50); do
    if [[ $(memword 0x2040) == $(( 0x4449534d )) ]]; then
      stub 3 9
      return
    fi
    sleep 0.1
  done
}

for c in "0 0 absent 0x0 0" "2 7 running 2 7" "1 0 running 1 0" "3 9 stopped 3 9" "4 4294967294 refused 4 4294967294"; do
  read -r s n want <<< "$c"
  fresh
  [[ $s == 0 ]] || stub "$s" "$n"
  before=$(sha256sum < "$MICROOS_DEVMEM")
  got=$(stub_status 2>&1) || fail "status $want: exit $?: $got"
  [[ $got == "$want" ]] || fail "status of state $s: $got, want $want"
  [[ $(sha256sum < "$MICROOS_DEVMEM") == "$before" ]] || fail "status of state $s wrote to the stub words"
done
fresh
stub 2 7 0x1234
[[ $(stub_status) == "absent $(printf '0x%x' $(( 0x1234 << 16 | 2 ))) 7" ]] || fail "status with a wrong signature: $(stub_status)"

fresh
stub 2 7
responder &
resp=$!
got=$(stub_disarm) || fail "disarm: exit $?"
wait "$resp" || true
[[ $got == "stopped 3 9" ]] || fail "disarm of a running stub: $got"
[[ $(memword 0x2040) == $(( 0x4449534d )) ]] || fail "disarm word $(memword 0x2040)"
[[ $(stub_status) == "stopped 3 9" ]] || fail "status after the disarm: $(stub_status)"

fresh
stub 2 7
t0=$SECONDS
got=$(stub_disarm)
(( SECONDS - t0 >= 2 )) || fail "disarm wait shorter than MICROOS_STUB_WAIT"
[[ $got == "running 2 7" ]] || fail "disarm of a stub that does not stop: $got"
[[ $(memword 0x2040) == $(( 0x4449534d )) ]] || fail "disarm word not written for a running stub"

for c in "3 9 stopped" "4 4294967294 refused" "0 0 absent"; do
  read -r s n res <<< "$c"
  fresh
  [[ $s == 0 ]] || stub "$s" "$n"
  got=$(stub_disarm)
  [[ $got == "$res "* ]] || fail "disarm of a $res stub: $got"
  [[ $(memword 0x2040) == 0 ]] || fail "disarm word written for a $res stub"
done

MICROOS_DEVMEM=$tmp/nomem
! got=$(stub_status 2>&1) || fail "status without devmem: $got"
! got=$(stub_disarm 2>&1) || fail "disarm without devmem: $got"
[[ ! -e $tmp/nomem ]] || fail "status or disarm created $tmp/nomem"

if (( rc == 0 )); then
  echo "stub-lib: ok"
fi
exit "$rc"
