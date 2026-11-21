#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
bootok=$tree/usr/libexec/microos/microos-boot-ok
bootlog=$tree/usr/libexec/microos/microos-bootlog
applied=$tree/usr/libexec/microos/microos-update-applied
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

export MICROOS_RUNDIR=$tmp/run MICROOS_STATEDIR=$tmp/state MICROOS_ESP=$tmp/esp FAKE_STATE=$tmp/fake
export MICROOS_BOOT_OK_CONF=$tree/usr/lib/microos/boot-ok.conf
export MICROOS_CMDLINE=$tmp/proc-cmdline MICROOS_BOOT_B=$tmp/boot_b MICROOS_NVMEM_ROOT=$tmp/nvmem MICROOS_SDAM_TRIES=1
export MICROOS_SDAM_LIB=$tree/usr/libexec/microos/microos-sdam MICROOS_STUB_CONF=$tree/usr/lib/microos/stub.conf
export MICROOS_BOOTB_LIB=$tree/usr/libexec/microos/microos-bootb MICROOS_STUB_LIB=$tree/usr/libexec/microos/microos-stub
export MICROOS_DEVMEM=$tmp/mem MICROOS_DEVMEM_BASE=0xd60a0000 MICROOS_STUB_WAIT=2
export MICROOS_SLOT_CONF=$tmp/slot.conf MICROOS_SLOT=$here/bootok/bin/microos-slot
export MICROOS_BOOT_OK_HOLD=0 MICROOS_BOOT_OK_STEP=1 MICROOS_BOOT_OK_WAIT=2
export MICROOS_UDC=$tmp/sys/udc MICROOS_NET=$tmp/sys/net MICROOS_DRM=$tmp/sys/drm MICROOS_INPUT=$tmp/sys/input
export PATH=$here/bootok/bin:$PATH
export MICROOS_UPTIME=$tmp/uptime MICROOS_DEADLINE_TIMER=$tree/usr/lib/systemd/system/microos-boot-deadline.timer
echo "100.00 200.00" > "$MICROOS_UPTIME"

c() { local s; s=$(printf '%064d' 0); echo "${s//0/$1}"; }
P=$(c a).0
B=$(c b).0
H=$(c 9).0
C=$(c c).0
D=$(c d).0

flag() { if [[ $1 == *$2* ]]; then echo true; else echo false; fi; }
st() {
  local e id fl i=0 sep=""
  {
    printf '{"deployments":['
    for e; do
      id=${e%% *}
      fl=${e#"$id"}
      printf '%s{"checksum":"%s","serial":%s,"index":%d,"booted":%s,"pinned":%s,"staged":%s}' "$sep" \
        "${id%.*}" "${id##*.}" "$i" "$(flag "$fl" b)" "$(flag "$fl" p)" "$(flag "$fl" s)"
      sep=,
      i=$((i + 1))
    done
    printf ']}\n'
  } > "$FAKE_STATE/status.json"
}
ID=0123456789ab
le32() { printf "$(printf '\\x%02x' $(( $1 & 0xff )) $(( $1 >> 8 & 0xff )) $(( $1 >> 16 & 0xff )) $(( $1 >> 24 & 0xff )))"; }
put() { dd of="$1" bs=1 seek="$(( $2 ))" conv=notrunc status=none; }
mem32() { le32 "$2" | put "$MICROOS_DEVMEM" "$1"; }
memword() { od -An -tu4 -j "$(( $1 ))" -N4 "$MICROOS_DEVMEM" | tr -d ' '; }
sdam() { od -An -tx1 -j72 -N1 "$MICROOS_NVMEM_ROOT/spmi_sdam1/nvmem" | tr -d ' \n'; }
attempts() { cat "$MICROOS_ESP/microos/boot-attempts" 2> /dev/null || echo none; }
slotlog() { cat "$FAKE_STATE/slot.log" 2> /dev/null || true; }
has() { grep -qF -- "$1" "$tmp/out"; }
bootimg() {
  local cmd=$1 ver=${2:-2}
  rm -f "$MICROOS_BOOT_B"
  truncate -s 4096 "$MICROOS_BOOT_B"
  printf 'ANDROID!' | put "$MICROOS_BOOT_B" 0
  le32 "$ver" | put "$MICROOS_BOOT_B" 40
  printf '%s' "${cmd:0:511}" | put "$MICROOS_BOOT_B" 64
  printf '%s' "${cmd:511}" | put "$MICROOS_BOOT_B" 608
}
stub() { mem32 0x2004 "$2"; mem32 0x2000 $(( 0x5744 << 16 | $1 )); }
responder() {
  for _ in $(seq 1 50); do
    if [[ $(memword 0x2040) == $(( 0x4449534d )) ]]; then
      stub 3 9
      return
    fi
    sleep 0.1
  done
}
reset() {
  rm -rf "$MICROOS_RUNDIR" "$MICROOS_STATEDIR" "$MICROOS_ESP" "$FAKE_STATE/status.json" "$FAKE_STATE/reads" \
    "$FAKE_STATE/events" "$FAKE_STATE/ostree.log" "$FAKE_STATE/lockprobe" "$FAKE_STATE/shifted" "$FAKE_STATE/shifted-pin" \
    "$FAKE_STATE/stages" "$FAKE_STATE/system-reads" "$FAKE_STATE/slot.log" "$FAKE_STATE/gate.n" "$MICROOS_NVMEM_ROOT" "$MICROOS_DEVMEM" \
    "$MICROOS_BOOT_B"
  mkdir -p "$MICROOS_RUNDIR" "$MICROOS_STATEDIR" "$MICROOS_ESP/microos" "$FAKE_STATE" "$MICROOS_NVMEM_ROOT/spmi_sdam1" "$tmp/dt/nvram@7100"
  head -c 256 /dev/zero > "$MICROOS_NVMEM_ROOT/spmi_sdam1/nvmem"
  printf '\005' | put "$MICROOS_NVMEM_ROOT/spmi_sdam1/nvmem" 72
  ln -sfn "$tmp/dt/nvram@7100" "$MICROOS_NVMEM_ROOT/spmi_sdam1/of_node"
  truncate -s $(( 0x3000 )) "$MICROOS_DEVMEM"
  echo "root=PARTLABEL=microos rootwait ro init=/init microos.id=$ID" > "$tmp/proc-cmdline"
  echo "$ID 2" > "$MICROOS_ESP/microos/boot-attempts"
  bootimg "root=PARTLABEL=microos microos.id=ba9876543210"
  echo MICROOS_SLOT_WRITE=0 > "$MICROOS_SLOT_CONF"
}
is_pinned() { jq -e --arg id "$1" 'any(.deployments[]; .pinned and "\(.checksum).\(.serial)" == $id)' "$FAKE_STATE/status.json" > /dev/null; }
pins() { paste -sd, "$MICROOS_STATEDIR/boot-ok-pins" 2> /dev/null || true; }
events() { cat "$FAKE_STATE/events" 2> /dev/null || true; }
writes() { grep -E '^ostree admin (pin|undeploy)' "$FAKE_STATE/ostree.log" 2> /dev/null || true; }
run() { "$bootok" > "$tmp/out" 2>&1; }
run_rc() { r=0; run || r=$?; }

mkdir -p "$FAKE_STATE"

reset
st "$B b" "$P p"
echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
echo "$P" > "$MICROOS_STATEDIR/confirmed"
MICROOS_BOOT_OK_HOLD=2 run || fail "criterion pass: $(cat "$tmp/out")"
mapfile -t ev < <(events)
[[ ${ev[0]:-} == "pin booted pins=$P,$B confirmed=$P" ]] || fail "first event is not the pin after the append: ${ev[0]:-}"
[[ ${ev[1]:-} == "unpin 1 $P" ]] || fail "second event is not the unpin of the listed id: ${ev[1]:-}"
(( ${#ev[@]} == 2 )) || fail "extra events: $(events)"
[[ $(pins) == "$B" ]] || fail "boot-ok-pins after a pass: $(pins)"
[[ $(cat "$MICROOS_STATEDIR/confirmed") == "$B" ]] || fail "confirmed after a pass"
is_pinned "$B" || fail "booted not pinned after a pass"
is_pinned "$P" && fail "listed id still pinned after a pass"
[[ $(cat "$FAKE_STATE/lockprobe") == held ]] || fail "update.lock was free while ostree ran"
[[ $(tail -n 1 "$tmp/out") == "microos-boot-ok: confirmed $B" ]] || fail "last line: $(tail -n 1 "$tmp/out")"

reset
st "$B b"
( exec 7> "$MICROOS_RUNDIR/update.lock"; flock 7; exec sleep 4 ) &
holder=$!
sleep 0.3
run &
pid=$!
sleep 2
[[ -z $(writes) ]] || fail "ostree pin while update.lock was held"
wait "$pid" || fail "boot ok after the lock was released: $(cat "$tmp/out")"
wait "$holder" || true
is_pinned "$B" || fail "booted not pinned after the lock wait"
reset
st "$B b"
( exec 7> "$MICROOS_RUNDIR/update.lock"; flock 7; exec sleep 5 ) &
holder=$!
sleep 0.3
r=0
MICROOS_BOOT_OK_LOCK_WAIT=1 run || r=$?
(( r == 3 )) || fail "lock timeout exit $r"
grep -q "not confirmed: update.lock busy" "$tmp/out" || fail "lock timeout message: $(cat "$tmp/out")"
[[ -z $(writes) ]] || fail "ostree write on a lock timeout"
kill "$holder" 2> /dev/null || true
wait "$holder" 2> /dev/null || true

reset
st "$B b" "$P p"
echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
FAKE_SYSTEM=degraded FAKE_FAILED_UNITS="NetworkManager.service foo.service" MICROOS_BOOT_OK_HOLD=2 run_rc
(( r == 1 )) || fail "failed unit exit $r"
has "not confirmed: failed: NetworkManager.service foo.service after 2 s" || fail "failed unit message: $(cat "$tmp/out")"
[[ -z $(writes) && -z $(events) ]] || fail "a failed unit still pinned: $(events)"
[[ ! -e $MICROOS_RUNDIR/boot-confirmed ]] || fail "boot-confirmed written with a failed unit"
reset
st "$B b"
FAKE_SYSTEM=degraded FAKE_FAILED_UNITS="foo.service" MICROOS_BOOT_OK_ALLOW="bar.service foo.service" MICROOS_BOOT_OK_HOLD=2 run \
  || fail "degraded with an allowed failure: $(cat "$tmp/out")"
reset
st "$B b"
FAKE_STARTING=2 run || fail "system running after a wait: $(cat "$tmp/out")"
reset
st "$B b"
FAKE_DEGRADED_AFTER=2 FAKE_FAILED_UNITS=sshd.service MICROOS_BOOT_OK_HOLD=3 run_rc
(( r == 1 )) || fail "failure in the hold: exit $r"
has "not confirmed: failed: sshd.service after 2 s of the hold" || fail "hold failure message: $(cat "$tmp/out")"

reset
st "$B b"
FAKE_INACTIVE=sshd.service FAKE_COND_NO=sshd.service MICROOS_BOOT_OK_HOLD=2 run || fail "sshd with ConditionResult=no: $(cat "$tmp/out")"
reset
st "$B b"
FAKE_INACTIVE=sshd.service MICROOS_BOOT_OK_HOLD=2 run_rc
(( r == 1 )) || fail "sshd inactive with ConditionResult=yes: exit $r"
[[ -z $(writes) ]] || fail "inactive sshd still pinned"

reset
st "$B b"
t0=$SECONDS
FAKE_SYSTEM=starting run_rc
(( r == 1 )) || fail "system never running: exit $r"
(( SECONDS - t0 >= 2 )) || fail "system wait shorter than MICROOS_BOOT_OK_WAIT"
has "not confirmed: system starting after 2 s" || fail "gate timeout message: $(cat "$tmp/out")"
stub 2 7
[[ ! -e $MICROOS_RUNDIR/boot-confirmed && $(attempts) == "$ID 2" && $(sdam) == 05 && $(memword 0x2040) == 0 ]] \
  || fail "gate timeout acted: counter $(attempts), sdam $(sdam), disarm $(memword 0x2040)"

reset
st "$B b" "$P p"
echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
for f in "$MICROOS_RUNDIR/deployments" "$MICROOS_STATEDIR/confirmed" "$MICROOS_STATEDIR/boot-ok-pins"; do
  echo keep > "$tmp/target-${f##*/}"
  echo keep > "$tmp/target-${f##*/}.tmp"
  ln -s "$tmp/target-${f##*/}.tmp" "$f.tmp"
done
ln -s "$tmp/target-deployments" "$MICROOS_RUNDIR/deployments"
ln -s "$tmp/target-confirmed" "$MICROOS_STATEDIR/confirmed"
run || fail "pass with planted links: $(cat "$tmp/out")"
for f in "$MICROOS_RUNDIR/deployments" "$MICROOS_STATEDIR/confirmed" "$MICROOS_STATEDIR/boot-ok-pins"; do
  [[ $(cat "$tmp/target-${f##*/}") == keep && $(cat "$tmp/target-${f##*/}.tmp") == keep ]] || fail "planted link at $f followed"
  [[ -f $f && ! -L $f ]] || fail "$f not replaced by a file"
done
[[ $(cat "$MICROOS_STATEDIR/confirmed") == "$B" ]] || fail "confirmed after planted links"
[[ $(head -n 1 "$MICROOS_RUNDIR/deployments") == "booted=$B" ]] || fail "deployments after planted links"
[[ -z $(find "$MICROOS_RUNDIR" "$MICROOS_STATEDIR" -name '*.??????' -type f) ]] || fail "temp files left"

reset
st "$B b" "$P p"
echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
echo "$B" > "$MICROOS_STATEDIR/boot-ok-skip"
run_rc
(( r == 3 )) || fail "skip file naming the booted deployment: exit $r"
[[ $(tail -n 1 "$tmp/out") == "microos-boot-ok: skipped once" ]] || fail "skip message: $(cat "$tmp/out")"
[[ ! -e $MICROOS_STATEDIR/boot-ok-skip ]] || fail "skip file kept after a skip"
[[ -z $(writes) && -z $(events) ]] || fail "pinned on a skip: $(events)"
[[ ! -e $MICROOS_RUNDIR/boot-confirmed && $(attempts) == "$ID 2" ]] || fail "skip confirmed the boot"
[[ ! -e $MICROOS_STATEDIR/confirmed ]] || fail "confirmed written on a skip"
[[ $(pins) == "$P" ]] || fail "boot-ok-pins changed on a skip: $(pins)"
run || fail "pass after a skip: $(cat "$tmp/out")"
is_pinned "$B" || fail "booted not pinned after a skip"
is_pinned "$P" && fail "P still pinned after the pass after a skip"
reset
st "$B b" "$P p"
echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
echo "$C" > "$MICROOS_STATEDIR/boot-ok-skip"
run || fail "skip file naming another deployment: $(cat "$tmp/out")"
[[ ! -e $MICROOS_STATEDIR/boot-ok-skip ]] || fail "skip file kept after a mismatch"
grep -q "boot-ok-skip names '$C', booted $B, not skipped" "$tmp/out" || fail "skip mismatch message: $(cat "$tmp/out")"
is_pinned "$B" || fail "booted not pinned after a skip mismatch"
[[ $(pins) == "$B" ]] || fail "boot-ok-pins after a skip mismatch: $(pins)"

reset
st "$B b" "$P p" "$H p"
echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
run || fail "pass with a hand pin: $(cat "$tmp/out")"
is_pinned "$H" || fail "hand pin dropped"
grep -q "$H" "$MICROOS_STATEDIR/boot-ok-pins" && fail "hand pin listed"
reset
st "$H b p"
run || fail "pass with a hand pinned booted: $(cat "$tmp/out")"
[[ -z $(pins) ]] || fail "hand pinned booted listed: $(pins)"
st "$B b" "$H p"
run || fail "pass after a hand pinned booted: $(cat "$tmp/out")"
is_pinned "$H" || fail "hand pinned deployment unpinned by a later boot ok"
[[ $(pins) == "$B" ]] || fail "boot-ok-pins after the later boot ok: $(pins)"

reset
st "$B b" "$P p"
echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
FAKE_STAGE_ON_READ=3 run || fail "pass with a stage inside the window: $(cat "$tmp/out")"
grep -qE '^ostree admin pin [0-9]' "$FAKE_STATE/ostree.log" && fail "pin by index"
grep -q "^unpin [0-9]* $B" "$FAKE_STATE/events" && fail "booted unpinned"
is_pinned "$B" || fail "booted not pinned after a stage"
is_pinned "$P" && fail "P pinned after a stage"
reset
st "$B b" "$P p"
echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
FAKE_SHIFT_ON_UNPIN=1 run || fail "pass with an index shift: $(cat "$tmp/out")"
grep -q "^unpin 1 $B" "$FAKE_STATE/events" || fail "the shift did not hit booted: $(events)"
[[ $(grep -c '^pin booted' "$FAKE_STATE/events") == 2 ]] || fail "booted not pinned again after the shift: $(events)"
is_pinned "$B" || fail "booted not pinned after the shift"
is_pinned "$P" && fail "P pinned after the shift"
[[ $(pins) == "$B" ]] || fail "boot-ok-pins after the shift: $(pins)"
npinned() { jq '[.deployments[] | select(.pinned)] | length' "$FAKE_STATE/status.json"; }
U=$(c 8).0
reset
st "$B b" "$H p" "$P p"
echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
FAKE_SHIFT_ON_UNPIN=1 run || fail "pass with a shift onto a hand pin: $(cat "$tmp/out")"
grep -q "^unpin 2 $H" "$FAKE_STATE/events" || fail "the shift did not hit the hand pin: $(events)"
grep -q "^pin [0-9]* $H" "$FAKE_STATE/events" || fail "hand pin not pinned again by its id: $(events)"
{ is_pinned "$B" && is_pinned "$H"; } || fail "booted or hand pin lost after a shift"
is_pinned "$P" && fail "P pinned after a shift onto a hand pin"
[[ $(npinned) == 2 ]] || fail "extra pins after a shift onto a hand pin: $(npinned)"
[[ $(pins) == "$B" ]] || fail "boot-ok-pins after a shift onto a hand pin: $(pins)"
reset
st "$B b p" "$U" "$H p" "$P p"
echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
FAKE_SHIFT_ON_UNPIN=1 FAKE_SHIFT_ON_PIN=1 run || fail "pass with two shifts: $(cat "$tmp/out")"
grep -q "^pin [0-9]* $U" "$FAKE_STATE/events" || fail "the second shift did not pin U: $(events)"
grep -q "^unpin [0-9]* $U" "$FAKE_STATE/events" || fail "the leaked pin on U was not removed: $(events)"
{ is_pinned "$B" && is_pinned "$H"; } || fail "booted or hand pin lost after two shifts"
is_pinned "$U" && fail "pin leaked onto U"
is_pinned "$P" && fail "P pinned after two shifts"
[[ $(npinned) == 2 ]] || fail "extra pins after two shifts: $(npinned)"

reset
st "$B b p"
echo "$B" > "$MICROOS_STATEDIR/boot-ok-pins"
echo "$B" > "$MICROOS_STATEDIR/confirmed"
run || fail "pass with nothing to do: $(cat "$tmp/out")"
[[ -z $(writes) ]] || fail "pin or unpin with nothing to do: $(writes)"
[[ -z $(events) ]] || fail "events with nothing to do: $(events)"

reset
st "$B b"
run || fail "RAM boot: $(cat "$tmp/out")"
has "RAM boot of $ID" || fail "RAM boot not detected: $(cat "$tmp/out")"
[[ $(attempts) == "$ID 0" ]] || fail "RAM boot counter: $(attempts)"
[[ $(sdam) == 01 ]] || fail "RAM boot preset byte $(sdam)"
[[ $(cat "$MICROOS_RUNDIR/boot-confirmed") == "$B" ]] || fail "RAM boot boot-confirmed"
has "no stub, status word 0x0" || fail "missing stub not reported: $(cat "$tmp/out")"
[[ $(memword 0x2040) == 0 ]] || fail "disarm written with no stub"
[[ -z $(slotlog) ]] || fail "RAM boot ran microos-slot: $(slotlog)"
[[ $(tail -n 1 "$tmp/out") == "microos-boot-ok: confirmed $B" ]] || fail "RAM boot last line: $(tail -n 1 "$tmp/out")"
reset
st "$B b"
echo MICROOS_SLOT_WRITE=1 > "$MICROOS_SLOT_CONF"
run || fail "RAM boot with slot writes on: $(cat "$tmp/out")"
[[ -z $(slotlog) ]] || fail "RAM boot with slot writes on ran microos-slot: $(slotlog)"

reset
st "$B b"
bootimg "root=PARTLABEL=microos rootwait microos.id=$ID loglevel=4"
run || fail "flash boot: $(cat "$tmp/out")"
has "flash boot of $ID" || fail "flash boot not detected: $(cat "$tmp/out")"
has "slot writes are off, slot b not armed" || fail "slot writes off not reported: $(cat "$tmp/out")"
[[ $(slotlog) == "microos-slot status" && $(attempts) == "$ID 0" && $(sdam) == 01 ]] || fail "flash boot, slot off: $(slotlog), $(attempts), $(sdam)"
has "slot status: b boot_b: active 1 priority 3 retry 5 successful 0 unbootable 0 (0x2f)" || fail "slot status not logged: $(cat "$tmp/out")"
reset
st "$B b"
bootimg "root=PARTLABEL=microos microos.id=$ID"
echo MICROOS_SLOT_WRITE=1 > "$MICROOS_SLOT_CONF"
run || fail "flash boot with slot writes on: $(cat "$tmp/out")"
[[ $(slotlog) == $'microos-slot status\nmicroos-slot arm' ]] || fail "status then arm not run: $(slotlog)"
[[ $(grep -n "slot status: b boot_b" "$tmp/out" | cut -d: -f1) -lt $(grep -n "slot b armed" "$tmp/out" | cut -d: -f1) ]] \
  || fail "slot status not logged before the arm: $(cat "$tmp/out")"
has "slot b armed, retry 7" || fail "arm not reported: $(cat "$tmp/out")"
reset
st "$B b"
bootimg "root=PARTLABEL=microos microos.id=$ID"
echo MICROOS_SLOT_WRITE=1 > "$MICROOS_SLOT_CONF"
FAKE_SLOT_RC=1 run || fail "flash boot with a failing microos-slot: $(cat "$tmp/out")"
has "microos-slot arm failed" || fail "arm failure not reported: $(cat "$tmp/out")"
[[ -e $MICROOS_RUNDIR/boot-confirmed ]] || fail "no boot-confirmed after an arm failure"
reset
st "$B b"
bootimg "root=PARTLABEL=microos microos.id=$ID"
echo MICROOS_SLOT_WRITE=1 > "$MICROOS_SLOT_CONF"
MICROOS_SLOT=$tmp/missing run || fail "flash boot with no microos-slot: $(cat "$tmp/out")"
has "$tmp/missing is missing, slot b not armed" || fail "missing microos-slot not reported: $(cat "$tmp/out")"
reset
st "$B b"
long=$(printf 'x%.0s' {1..520})
bootimg "root=PARTLABEL=microos $long microos.id=$ID"
echo MICROOS_SLOT_WRITE=1 > "$MICROOS_SLOT_CONF"
run || fail "flash boot with extra_cmdline: $(cat "$tmp/out")"
[[ $(slotlog) == $'microos-slot status\nmicroos-slot arm' ]] || fail "id in extra_cmdline not found: $(cat "$tmp/out")"
reset
st "$B b"
bootimg "root=PARTLABEL=microos microos.id=$ID" 3
echo MICROOS_SLOT_WRITE=1 > "$MICROOS_SLOT_CONF"
run || fail "v3 boot_b: $(cat "$tmp/out")"
has "header version 3, cmdline not read" && has "RAM boot of $ID" || fail "v3 boot_b: $(cat "$tmp/out")"
[[ -z $(slotlog) ]] || fail "v3 boot_b ran microos-slot"
reset
st "$B b"
rm "$MICROOS_BOOT_B"
run || fail "no boot_b: $(cat "$tmp/out")"
has "RAM boot of $ID" || fail "no boot_b: $(cat "$tmp/out")"
reset
st "$B b"
echo "root=PARTLABEL=microos" > "$tmp/proc-cmdline"
run || fail "no microos.id: $(cat "$tmp/out")"
[[ $(attempts) == "$ID 2" ]] || fail "counter changed with no microos.id: $(attempts)"

reset
st "$B b"
stub 2 7
responder &
resp=$!
run || fail "stub present: $(cat "$tmp/out")"
wait "$resp" || true
[[ $(memword 0x2040) == $(( 0x4449534d )) ]] || fail "disarm word $(memword 0x2040)"
has "stub stopped at 9 s" || fail "stub stop not reported: $(cat "$tmp/out")"
reset
st "$B b"
echo "root=PARTLABEL=microos rootwait ro init=/init microos.id=$ID microos.test=1" > "$tmp/proc-cmdline"
stub 2 7
t0=$SECONDS
run || fail "stub that does not stop: $(cat "$tmp/out")"
(( SECONDS - t0 >= 2 )) || fail "stub wait shorter than MICROOS_STUB_WAIT"
has "stub still running at 7 s after the disarm, it resets at 1200 s" || fail "running stub not reported: $(cat "$tmp/out")"
[[ $(sdam) == 05 && -e $MICROOS_RUNDIR/boot-confirmed ]] || fail "running stub on a test image: sdam $(sdam), not confirmed"
reset
st "$B b"
echo "root=PARTLABEL=microos rootwait ro init=/init microos.id=$ID microos.test=1" > "$tmp/proc-cmdline"
stub 4 $(( 0xfffffffe ))
run || fail "stub refused: $(cat "$tmp/out")"
has "stub CPU_ON was refused, PSCI 4294967294" || fail "refused stub not reported: $(cat "$tmp/out")"
[[ $(memword 0x2040) == 0 ]] || fail "disarm written for a refused stub"
for c in "2 7 running" "4 4294967294 refused"; do
  read -r s1 s2 res <<< "$c"
  reset
  st "$B b" "$P p"
  echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
  bootimg "root=PARTLABEL=microos microos.id=$ID"
  echo MICROOS_SLOT_WRITE=1 > "$MICROOS_SLOT_CONF"
  stub "$s1" "$s2"
  run_rc
  (( r == 1 )) || fail "stub $res without microos.test: exit $r"
  has "not confirmed: the stub is $res on an image without microos.test" || fail "stub $res without microos.test: $(cat "$tmp/out")"
  [[ ! -e $MICROOS_RUNDIR/boot-confirmed && ! -e $MICROOS_STATEDIR/confirmed && $(attempts) == "$ID 2" && $(sdam) == 05 ]] \
    || fail "stub $res without microos.test acted: counter $(attempts), sdam $(sdam)"
  [[ -z $(writes) && -z $(slotlog) && $(pins) == "$P" ]] || fail "stub $res without microos.test pinned or marked: $(writes) $(slotlog)"
done

gate=$tmp/gate
cat > "$gate" << 'EOF'
n=$(( $(cat "$FAKE_STATE/gate.n" 2> /dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_STATE/gate.n"
(( n > ${FAKE_GATE_FAILS:-0} ))
EOF
gates() { cat "$FAKE_STATE/gate.n" 2> /dev/null || echo 0; }
rec=$MICROOS_STATEDIR/bootimg-update
armed() { printf 'target=%s\narmed=%s\nprev=ba9876543210\n' "$B" "$1" > "$rec"; }
reset
st "$B b"
armed "$ID"
MICROOS_BOOT_OK_GATE=$gate FAKE_GATE_FAILS=2 run || fail "gate passing on the third poll: $(cat "$tmp/out")"
[[ $(gates) == 3 ]] || fail "gate polls $(gates), want 3"
has "first boot of $ID: $gate passed" || fail "gate pass not reported: $(cat "$tmp/out")"
[[ $(cat "$rec") == "target=$B"$'\n'"armed=$ID"$'\n'"prev=ba9876543210"$'\n'"confirmed=$ID" ]] || fail "record after the gate: $(cat "$rec")"
[[ -e $MICROOS_RUNDIR/boot-confirmed ]] || fail "gate pass not confirmed"
rm -f "$MICROOS_RUNDIR/boot-confirmed"
MICROOS_BOOT_OK_GATE=$gate FAKE_GATE_FAILS=99 run || fail "boot after confirmed=: $(cat "$tmp/out")"
[[ $(gates) == 3 ]] || fail "gate ran after confirmed=: $(gates) polls"
[[ $(grep -c "^confirmed=$ID$" "$rec") == 1 ]] || fail "confirmed= written twice: $(cat "$rec")"
reset
st "$B b" "$P p"
echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
armed "$ID"
cp "$rec" "$tmp/rec.before"
t0=$SECONDS
MICROOS_BOOT_OK_GATE=$gate FAKE_GATE_FAILS=99 MICROOS_BOOT_OK_GATE_WAIT=2 run_rc
(( r == 1 )) || fail "gate timeout: exit $r"
(( SECONDS - t0 >= 2 )) || fail "gate timeout shorter than MICROOS_BOOT_OK_GATE_WAIT"
has "not confirmed: $gate failed for 2 s on the first boot of $ID" || fail "gate timeout message: $(cat "$tmp/out")"
(( $(gates) >= 2 && $(gates) <= 4 )) || fail "gate timeout polls $(gates), want 2 to 4"
[[ ! -e $MICROOS_RUNDIR/boot-confirmed && $(attempts) == "$ID 2" && $(sdam) == 05 && $(memword 0x2040) == 0 ]] \
  || fail "gate timeout acted: counter $(attempts), sdam $(sdam), disarm $(memword 0x2040)"
[[ -z $(writes) && $(pins) == "$P" ]] || fail "gate timeout pinned: $(writes)"
[[ $(< "$rec") == "$(< "$tmp/rec.before")" ]] || fail "gate timeout changed the record: $(cat "$rec")"
reset
st "$B b"
armed "$ID"
MICROOS_BOOT_OK_GATE=$tmp/missing MICROOS_BOOT_OK_GATE_WAIT=1 run_rc
(( r == 1 )) || fail "missing gate script: exit $r"
reset
st "$B b"
armed "$ID"
printf 'exec sleep 100\n' > "$tmp/hang"
t0=$SECONDS
MICROOS_BOOT_OK_GATE=$tmp/hang MICROOS_BOOT_OK_GATE_RUN=1 MICROOS_BOOT_OK_GATE_WAIT=3 run_rc
(( r == 1 )) || fail "hanging gate: exit $r"
(( SECONDS - t0 >= 3 && SECONDS - t0 <= 10 )) || fail "hanging gate took $((SECONDS - t0)) s"
has "not confirmed: $tmp/hang failed for 3 s on the first boot of $ID" || fail "hanging gate message: $(cat "$tmp/out")"
[[ ! -e $MICROOS_RUNDIR/boot-confirmed ]] || fail "hanging gate confirmed"
reset
st "$B b"
armed "$ID"
echo "845.50 900.00" > "$MICROOS_UPTIME"
MICROOS_BOOT_OK_GATE=$gate run_rc
(( r == 1 )) || fail "gate past the deadline margin: exit $r"
has "not confirmed: no time left for $gate before the 900 s deadline" || fail "gate past the margin: $(cat "$tmp/out")"
[[ $(gates) == 0 && ! -e $MICROOS_RUNDIR/boot-confirmed ]] || fail "gate past the margin ran or confirmed"
reset
st "$B b"
armed "$ID"
echo "801.10 900.00" > "$MICROOS_UPTIME"
t0=$SECONDS
MICROOS_BOOT_OK_GATE=$gate FAKE_GATE_FAILS=99 run_rc
(( r == 1 && SECONDS - t0 <= 8 )) || fail "gate capped by the deadline: exit $r after $((SECONDS - t0)) s"
has "not confirmed: $gate failed for 3 s on the first boot of $ID" || fail "gate cap message: $(cat "$tmp/out")"
echo "100.00 200.00" > "$MICROOS_UPTIME"
reset
st "$B b"
armed ba9876543210
MICROOS_BOOT_OK_GATE=$gate FAKE_GATE_FAILS=99 run || fail "armed for another id: $(cat "$tmp/out")"
[[ $(gates) == 0 ]] || fail "gate ran for another armed id"
grep -q '^confirmed=' "$rec" && fail "confirmed= written for another armed id"
reset
st "$B b"
armed "$ID"
run || fail "armed id with no gate: $(cat "$tmp/out")"
has "first boot of $ID, no MICROOS_BOOT_OK_GATE" || fail "no gate not reported: $(cat "$tmp/out")"
[[ $(tail -n 1 "$rec") == "confirmed=$ID" ]] || fail "record with no gate: $(cat "$rec")"
for c in devmem conf; do
  reset
  st "$B b"
  if [[ $c == devmem ]]; then
    env=(MICROOS_DEVMEM="$tmp/nomem")
  else
    env=(MICROOS_STUB_CONF="$tmp/nostub.conf")
  fi
  r=0
  env "${env[@]}" "$bootok" > "$tmp/out" 2>&1 || r=$?
  (( r == 1 )) || fail "no $c on a non test image: exit $r"
  has "not confirmed: the stub is in an unknown state on an image without microos.test" || fail "no $c: $(cat "$tmp/out")"
  [[ ! -e $MICROOS_RUNDIR/boot-confirmed && $(attempts) == "$ID 2" && $(sdam) == 05 ]] || fail "no $c on a non test image acted"
  reset
  st "$B b"
  echo "root=PARTLABEL=microos rootwait ro init=/init microos.id=$ID microos.test=1" > "$tmp/proc-cmdline"
  env "${env[@]}" "$bootok" > "$tmp/out" 2>&1 || fail "no $c on a test image: $(cat "$tmp/out")"
done
has "missing $tmp/nostub.conf, stub not disarmed" || fail "missing stub.conf not reported: $(cat "$tmp/out")"
reset
st "$B b"
echo "root=PARTLABEL=microos rootwait ro init=/init microos.id=$ID microos.test=1" > "$tmp/proc-cmdline"
MICROOS_DEVMEM=$tmp/nomem run || fail "no devmem: $(cat "$tmp/out")"
has "stub words not reachable through $tmp/nomem" || fail "devmem failure not reported: $(cat "$tmp/out")"
reset
st "$B b"
rm "$MICROOS_NVMEM_ROOT/spmi_sdam1/of_node"
run || fail "no SDAM: $(cat "$tmp/out")"
has "fastboot preset not cleared, no SDAM nvram@7100" || fail "missing SDAM not reported: $(cat "$tmp/out")"

indev() {
  mkdir -p "$tmp/sys/input/$1/capabilities"
  echo "$2" > "$tmp/sys/input/$1/properties"
  echo "$3" > "$tmp/sys/input/$1/capabilities/abs"
  echo "$4" > "$tmp/sys/input/$1/capabilities/key"
}
kround() {
  reset
  rm -rf "$tmp/sys"
  mkdir -p "$tmp/sys/udc/a600000.usb" "$tmp/sys/udc/dummy_udc.0" "$tmp/sys/net/wlp1s0/wireless" "$tmp/sys/drm/card1-DSI-1" "$tmp/sys/input"
  echo configured > "$tmp/sys/udc/a600000.usb/state"
  echo configured > "$tmp/sys/udc/dummy_udc.0/state"
  echo disconnected > "$tmp/sys/drm/card1-DSI-1/status"
  echo "root=PARTLABEL=microos rootwait ro init=/init microos.id=$ID microos.kround=$1" > "$tmp/proc-cmdline"
  st "$B b" "$P p"
  echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
  echo "$P" > "$MICROOS_STATEDIR/confirmed"
}
kept() {
  [[ -z $(writes) && -z $(events) ]] || fail "$1: ostree pin or unpin: $(writes)"
  [[ $(pins) == "$P" && $(cat "$MICROOS_STATEDIR/confirmed") == "$P" ]] || fail "$1: boot-ok-pins $(pins), confirmed changed"
  [[ ! -e $MICROOS_RUNDIR/deployments ]] || fail "$1: deployments written"
  is_pinned "$P" || fail "$1: P unpinned"
  ! is_pinned "$B" || fail "$1: booted pinned"
}
kfail() {
  run_rc
  (( r == 1 )) || fail "$1: exit $r"
  has "not confirmed: $2" || fail "$1: message: $(cat "$tmp/out")"
  kept "$1"
  [[ ! -e $MICROOS_RUNDIR/boot-confirmed && $(attempts) == "$ID 2" && $(sdam) == 05 ]] \
    || fail "$1: acted on a failed check: counter $(attempts), sdam $(sdam)"
}

kround p1a
echo "$B" > "$MICROOS_STATEDIR/boot-ok-skip"
stub 2 7
responder &
resp=$!
MICROOS_BOOT_OK_HOLD=2 run || fail "kround p1a pass: $(cat "$tmp/out")"
wait "$resp" || true
kept "kround p1a pass"
has "kround p1a: checks udc wlan0" || fail "kround checks not reported: $(cat "$tmp/out")"
[[ $(cat "$MICROOS_STATEDIR/boot-ok-skip" 2> /dev/null) == "$B" ]] || fail "kround consumed boot-ok-skip"
[[ $(cat "$MICROOS_RUNDIR/boot-confirmed") == "$B" ]] || fail "kround boot-confirmed"
[[ $(attempts) == "$ID 0" ]] || fail "kround counter: $(attempts)"
has "stub stopped at 9 s" || fail "kround stub stop: $(cat "$tmp/out")"
[[ $(sdam) == 01 ]] || fail "kround preset byte $(sdam)"
[[ $(tail -n 1 "$tmp/out") == "microos-boot-ok: confirmed $B" ]] || fail "kround last line: $(tail -n 1 "$tmp/out")"
kround p0
run || fail "kround p0 pass: $(cat "$tmp/out")"
kept "kround p0 pass"
for u in microos-usb-console.service NetworkManager-wait-online.service; do
  kround p1a
  FAKE_SYSTEM=degraded FAKE_FAILED_UNITS=$u kfail "kround with $u failed" "failed: $u after 2 s"
  reset
  st "$B b"
  FAKE_SYSTEM=degraded FAKE_FAILED_UNITS=$u run || fail "$u failed outside kround: $(cat "$tmp/out")"
done
kround p1a
FAKE_SYSTEM=degraded FAKE_FAILED_UNITS="chronyd.service sddm.service microos-vpad-gadget.service" run || fail "kround with allowed failures: $(cat "$tmp/out")"
kround p1a
echo "not attached" > "$tmp/sys/udc/a600000.usb/state"
kfail "kround p1a gadget down" "kround p1a: no UDC configured after 2 s"
kround p1a
rm -rf "$tmp/sys/udc/a600000.usb"
kfail "kround p1a no UDC" "kround p1a: no UDC configured after 2 s"
kround p1a
rmdir "$tmp/sys/net/wlp1s0/wireless"
kfail "kround p1a no wlan0" "kround p1a: no wireless interface after 2 s"
kround p1a
FAKE_INACTIVE=sshd.service kfail "kround p1a sshd down" "sshd.service is not active after 2 s"
kround p1b
kfail "kround p1b panel off" "kround p1b: no DSI-1 connected after 2 s"
kround p1b
echo connected > "$tmp/sys/drm/card1-DSI-1/status"
run || fail "kround p1b pass: $(cat "$tmp/out")"
kept "kround p1b pass"
kround p1c
echo connected > "$tmp/sys/drm/card1-DSI-1/status"
indev input1 0 "260800000000003" 0
indev input2 0 "3" "c03 0 0 0 0 0"
kfail "kround p1c no touch" "kround p1c: no touchscreen input device after 2 s"
kround p1c
echo connected > "$tmp/sys/drm/card1-DSI-1/status"
indev input3 2 "660800000000003" "400 0 0 0 0 0"
kfail "kround p1c no pen" "kround p1c: no pen input device after 2 s"
kround p1c
echo connected > "$tmp/sys/drm/card1-DSI-1/status"
indev input3 2 "660800000000003" "400 0 0 0 0 0"
indev input4 2 "1000003" "c03 0 0 0 0 0"
run || fail "kround p1c pass: $(cat "$tmp/out")"
kept "kround p1c pass"
kround p2a
echo connected > "$tmp/sys/drm/card1-DSI-1/status"
indev input3 2 "660800000000003" "400 0 0 0 0 0"
indev input4 2 "1000003" "c03 0 0 0 0 0"
run || fail "kround p2a pass: $(cat "$tmp/out")"
kept "kround p2a pass"
has "kround p2a: checks udc wlan0 dsi touch pen" || fail "kround p2a checks not reported: $(cat "$tmp/out")"
kround p2b
echo connected > "$tmp/sys/drm/card1-DSI-1/status"
indev input3 2 "660800000000003" "400 0 0 0 0 0"
indev input4 2 "1000003" "c03 0 0 0 0 0"
run || fail "kround p2b pass: $(cat "$tmp/out")"
kept "kround p2b pass"
has "kround p2b: checks udc wlan0 dsi touch pen" || fail "kround p2b checks not reported: $(cat "$tmp/out")"
kround p2c
echo connected > "$tmp/sys/drm/card1-DSI-1/status"
indev input3 2 "660800000000003" "400 0 0 0 0 0"
indev input4 2 "1000003" "c03 0 0 0 0 0"
run || fail "kround p2c pass: $(cat "$tmp/out")"
kept "kround p2c pass"
has "kround p2c: checks udc wlan0 dsi touch pen" || fail "kround p2c checks not reported: $(cat "$tmp/out")"
oncek() {
  kround "$1"
  echo "root=PARTLABEL=microos rootwait ro init=/init microos.id=$ID microos.kround=$1 microos.test=${2:-once}" > "$tmp/proc-cmdline"
  echo "not attached" > "$tmp/sys/udc/a600000.usb/state"
}
oncek p1a
stub 2 7
FAKE_SYSTEM=degraded FAKE_FAILED_UNITS="microos-usb-console.service microos-initrd-usbcon.service" run \
  || fail "once with no USB host, console units failed: $(cat "$tmp/out")"
kept "once with no USB host"
has "kround p1a: checks wlan0" || fail "once checks: $(cat "$tmp/out")"
has "microos.test=once: stub left armed" || fail "once stub not reported: $(cat "$tmp/out")"
[[ $(memword 0x2040) == 0 && -e $MICROOS_RUNDIR/boot-confirmed && $(attempts) == "$ID 0" ]] \
  || fail "once with no USB host: disarm $(memword 0x2040), counter $(attempts)"
[[ -z $(slotlog) ]] || fail "once RAM boot ran microos-slot: $(slotlog)"
oncek p1a
FAKE_SYSTEM=degraded FAKE_FAILED_UNITS=NetworkManager-wait-online.service \
  kfail "once, wait-online failed" "failed: NetworkManager-wait-online.service after 2 s"
oncek p1a
rmdir "$tmp/sys/net/wlp1s0/wireless"
kfail "once no wlan0" "kround p1a: no wireless interface after 2 s"
oncek p1a 1
kfail "test 1 kround with no USB host" "kround p1a: no UDC configured after 2 s"
oncek p1a
bootimg "root=PARTLABEL=microos microos.id=$ID microos.kround=p1a microos.test=once"
echo MICROOS_SLOT_WRITE=1 > "$MICROOS_SLOT_CONF"
armed "$ID"
cp "$rec" "$tmp/rec.before"
MICROOS_BOOT_OK_GATE=$gate FAKE_GATE_FAILS=99 run || fail "once flash boot: $(cat "$tmp/out")"
has "flash boot of $ID" && has "microos.test=once: slot b not armed" || fail "once flash boot: $(cat "$tmp/out")"
[[ -z $(slotlog) && $(gates) == 0 ]] || fail "once flash boot ran microos-slot or the gate: $(slotlog), gates $(gates)"
[[ $(cat "$rec") == "$(cat "$tmp/rec.before")" ]] || fail "once flash boot changed bootimg-update: $(cat "$rec")"
kept "once flash boot"
for k in p1a-hang p9 p1d; do
  kround "$k"
  echo "$B" > "$MICROOS_STATEDIR/boot-ok-skip"
  t0=$SECONDS
  kfail "kround $k" "kround $k has no checks"
  (( SECONDS - t0 < 2 )) || fail "kround $k waited"
  [[ $(cat "$MICROOS_STATEDIR/boot-ok-skip" 2> /dev/null) == "$B" ]] || fail "kround $k consumed boot-ok-skip"
done

export MICROOS_BOOT=$tmp/bootfs MICROOS_CMDLINE=$tmp/cmdline MICROOS_BOOTID=$tmp/bootid
log=$MICROOS_BOOT/microos/shutdown.log
echo "ostree=/ostree/boot.1/default/x/0 quiet microos.deploy=$B" > "$MICROOS_CMDLINE"
echo "0123456789abcdef-rest" > "$MICROOS_BOOTID"
rm -f "$FAKE_STATE/bootc.log.bootlog"
mkdir -p "$MICROOS_BOOT"
bootc_calls=$(wc -l < "$FAKE_STATE/bootc.log" 2> /dev/null || echo 0)

r=0
out=$(FAKE_MOUNT_FAIL=1 "$bootlog" run step1 -- sh -c 'echo hi; exit 5' 2>&1) || r=$?
(( r == 5 )) || fail "bootlog with ro /boot: exit $r"
[[ $out == *"warning: no "* ]] || fail "bootlog with ro /boot: no warning: $out"
[[ ! -e $log ]] || fail "bootlog wrote with ro /boot"

r=0
out=$("$bootlog" run step2 -- sh -c 'echo first; echo second; exit 4' 2> /dev/null) || r=$?
(( r == 4 )) || fail "bootlog exit $r"
[[ $out == $'first\nsecond' ]] || fail "bootlog output: $out"
line=$(tail -n 1 "$log")
[[ $line =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\ boot=01234567\ step=step2\ rc=4\ booted=$B\ second$ ]] || fail "bootlog line: $line"
echo "quiet" > "$MICROOS_CMDLINE"
"$bootlog" run step3 -- true || fail "bootlog of true"
[[ $(tail -n 1 "$log") == *" step=step3 rc=0 booted=unknown "* ]] || fail "bootlog without microos.deploy: $(tail -n 1 "$log")"

seq 1 200000 | sed 's/^/padding line /' > "$log"
"$bootlog" run trim -- echo trimmed > /dev/null || fail "bootlog trim run"
[[ $(wc -l < "$log") == 2000 ]] || fail "trimmed log has $(wc -l < "$log") lines"
[[ $(tail -n 1 "$log") == *" step=trim rc=0 "*" trimmed" ]] || fail "trimmed log last line"

: > "$log"
"$bootlog" run para1 -- sh -c 'sleep 0.5; echo one' > /dev/null &
p1=$!
"$bootlog" run para2 -- sh -c 'sleep 0.5; echo two' > /dev/null &
p2=$!
wait "$p1" "$p2"
{ grep -q ' step=para1 .* one$' "$log" && grep -q ' step=para2 .* two$' "$log"; } || fail "concurrent lines: $(cat "$log")"

r=0
"$bootlog" run killed -- sh -c 'kill -TERM $$' > /dev/null 2>&1 || r=$?
(( r == 143 )) || fail "command killed by SIGTERM: exit $r"
[[ $(tail -n 1 "$log") == *" step=killed rc=143 "* ]] || fail "SIGTERM status not logged: $(tail -n 1 "$log")"

out=$("$bootlog" run big -- seq 1 300000 2> /dev/null) || fail "big output run"
[[ $out == "$(seq 1 300000)" ]] || fail "big output not printed in full"

"$bootlog" run term -- sh -c 'echo early; exec sleep 30' > "$tmp/termout" 2>&1 &
pid=$!
sleep 1
t0=$SECONDS
kill -TERM "$pid"
r=0
wait "$pid" || r=$?
(( r == 143 )) || fail "bootlog under SIGTERM: exit $r"
(( SECONDS - t0 <= 5 )) || fail "bootlog under SIGTERM took $((SECONDS - t0)) s"
grep -qx early "$tmp/termout" || fail "bootlog under SIGTERM lost the output: $(cat "$tmp/termout")"
[[ $(tail -n 1 "$log") == *" step=term rc=143 "*" early" ]] || fail "bootlog under SIGTERM line: $(tail -n 1 "$log")"

"$bootlog" run abrt -- sh -c 'echo early; exec sleep 30' > "$tmp/abrtout" 2>&1 &
pid=$!
sleep 1
kill -ABRT "$pid"
r=0
wait "$pid" || r=$?
(( r == 134 )) || fail "bootlog under SIGABRT: exit $r"
grep -qx early "$tmp/abrtout" || fail "bootlog under SIGABRT lost the output: $(cat "$tmp/abrtout")"
[[ $(tail -n 1 "$log") == *" step=abrt rc=134 "*" early" ]] || fail "bootlog under SIGABRT line: $(tail -n 1 "$log")"

( exec 7> "$MICROOS_RUNDIR/bootlog.lock"; flock 7; exec sleep 10 ) &
holder=$!
sleep 0.3
t0=$SECONDS
r=0
"$bootlog" run held -- sh -c 'exit 6' > /dev/null 2>&1 || r=$?
(( r == 6 )) || fail "bootlog with a held lock: exit $r"
(( SECONDS - t0 <= 5 )) || fail "bootlog with a held lock took $((SECONDS - t0)) s"
grep -q ' step=held ' "$log" && fail "bootlog wrote under a held lock"
kill "$holder" 2> /dev/null || true
wait "$holder" 2> /dev/null || true

[[ $(wc -l < "$FAKE_STATE/bootc.log" 2> /dev/null || echo 0) == "$bootc_calls" ]] || fail "bootlog called bootc"
unset MICROOS_BOOT MICROOS_CMDLINE MICROOS_BOOTID

reset
st "$B b"
nap=$MICROOS_RUNDIR/update-not-applied
exp=$MICROOS_STATEDIR/expected-deployment
digest=sha256:$(c 1)
other=sha256:$(c 2)
"$applied" > /dev/null || fail "update applied with no expected file"
[[ ! -e $nap ]] || fail "not applied written with no expected file"
printf 'deploy=%s\ndigest=%s\nversion=20261013.abc\nimage=ghcr.io/seilent/microos-y700:testing\nstaged=2026-10-13T00:00:00Z\n' "$B" "$other" > "$exp"
echo stale > "$nap"
"$applied" > /dev/null || fail "update applied by id"
[[ ! -e $exp && ! -e $nap ]] || fail "files kept after an applied id"
printf 'deploy=%s\ndigest=%s\nversion=20261013.abc\n' "$C" "$digest" > "$exp"
echo stale > "$nap"
"$applied" > /dev/null || fail "update applied by digest"
[[ ! -e $exp && ! -e $nap ]] || fail "files kept after an applied digest"
printf 'deploy=%s\ndigest=%s\nversion=20261013.abc\n' "$C" "$other" > "$exp"
out=$("$applied" 2>&1) || fail "update not applied run"
[[ -e $exp ]] || fail "expected file removed when not applied"
[[ $(cat "$nap" 2> /dev/null) == "expected=$C"$'\n'"booted=$B"$'\n'"digest=$other"$'\n'"version=20261013.abc" ]] || fail "not applied file: $(cat "$nap" 2> /dev/null)"
[[ $out == *"microos-update-applied: expected $C, booted $B"* ]] || fail "not applied message: $out"

! grep -q rollback "$FAKE_STATE/bootc.log" 2> /dev/null || fail "bootc rollback was called"

if (( rc == 0 )); then
  echo "bootok: ok"
fi
exit "$rc"
