#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
bootok=$tree/usr/libexec/microos/microos-boot-ok
bootlog=$tree/usr/libexec/microos/microos-bootlog
applied=$tree/usr/libexec/microos/microos-update-applied
update=$tree/usr/libexec/microos/microos-bootimg-update
conf=$tree/usr/lib/microos/bootimg.conf
build=$tree/usr/libexec/microos/microos-bootimg-build
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

export MICROOS_RUNDIR=$tmp/run MICROOS_STATEDIR=$tmp/state MICROOS_ESP=$tmp/esp FAKE_STATE=$tmp/fake
export MICROOS_BOOT_OK_CONF=$tree/usr/lib/microos/boot-ok.conf
export MICROOS_BOOTIMG_UPDATE=$here/bootok/bin/fake-bootimg-update
export MICROOS_BOOT_OK_HOLD=0 MICROOS_BOOT_OK_STEP=1 MICROOS_BOOT_OK_WAIT=2
export PATH=$here/bootok/bin:$here/bootimg/bin:$PATH

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
reset() {
  rm -rf "$MICROOS_RUNDIR" "$MICROOS_STATEDIR" "$MICROOS_ESP" "$FAKE_STATE/status.json" "$FAKE_STATE/reads" \
    "$FAKE_STATE/events" "$FAKE_STATE/ostree.log" "$FAKE_STATE/lockprobe" "$FAKE_STATE/shifted" "$FAKE_STATE/shifted-pin" "$FAKE_STATE/stages" \
    "$FAKE_STATE/bak-sleeping" "$FAKE_STATE/user.log" "$FAKE_STATE/user-reads" "$FAKE_STATE/setpriv.log" \
    "$FAKE_STATE/setpriv-fds.log" "$FAKE_STATE/late-reads"
  mkdir -p "$MICROOS_RUNDIR" "$MICROOS_STATEDIR" "$MICROOS_ESP" "$FAKE_STATE"
  echo "steam gamescope-session-plus@steam.service 1" > "$MICROOS_RUNDIR/session-current"
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
[[ ${ev[1]:-} == "bak $B confirmed=$B" ]] || fail "second event is not --bak after confirmed: ${ev[1]:-}"
[[ ${ev[2]:-} == "unpin 1 $P" ]] || fail "third event is not the unpin of the listed id: ${ev[2]:-}"
(( ${#ev[@]} == 3 )) || fail "extra events: $(events)"
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
FAKE_FAILED=NetworkManager.service MICROOS_BOOT_OK_HOLD=2 run_rc
(( r == 1 )) || fail "failed unit exit $r"
[[ -z $(writes) && -z $(events) ]] || fail "a failed unit still pinned or baked: $(events)"

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
FAKE_INACTIVE=multi-user.target run_rc
(( r == 1 )) || fail "target never active: exit $r"
(( SECONDS - t0 >= 2 )) || fail "target wait shorter than MICROOS_BOOT_OK_WAIT"

S=gamescope-session-plus@steam.service
reset
st "$B b"
t0=$SECONDS
MICROOS_BOOT_OK_USER_ACTIVE=$S FAKE_USER_INACTIVE=$S run_rc
(( r == 1 )) || fail "session never active: exit $r"
(( SECONDS - t0 >= 2 )) || fail "session wait shorter than MICROOS_BOOT_OK_WAIT"
grep -q "not confirmed: $S not active after 2 s" "$tmp/out" || fail "session never active message: $(cat "$tmp/out")"
[[ -z $(writes) && -z $(events) ]] || fail "pinned with the session never active: $(events)"
reset
st "$B b"
MICROOS_BOOT_OK_USER_ACTIVE=$S FAKE_USER_RESTART_AFTER=2 MICROOS_BOOT_OK_HOLD=3 run_rc
(( r == 1 )) || fail "session restarted: exit $r"
grep -q "not confirmed: $S restarted" "$tmp/out" || fail "session restarted message: $(cat "$tmp/out")"
[[ -z $(writes) && -z $(events) ]] || fail "pinned with a restarted session: $(events)"
reset
st "$B b"
(
  for n in $(seq 3 64); do eval "exec $n>&-"; done
  MICROOS_BOOT_OK_USER_ACTIVE=$S FAKE_USER_ACTIVE_AFTER=1 MICROOS_BOOT_OK_HOLD=3 run
) || fail "session active through the hold: $(cat "$tmp/out")"
is_pinned "$B" || fail "booted not pinned with the session active through the hold"
(( $(cat "$FAKE_STATE/user-reads") >= 5 )) || fail "session read $(cat "$FAKE_STATE/user-reads") times in the wait and hold"
[[ $(sort -u "$FAKE_STATE/user.log") == "systemctl --user show -p ActiveState,InvocationID,FragmentPath,DropInPaths $S" ]] ||
  fail "session query: $(sort -u "$FAKE_STATE/user.log")"
[[ $(sort -u "$FAKE_STATE/setpriv.log") == "setpriv --reuid=1000 --regid=1001 --init-groups --no-new-privs env -i XDG_RUNTIME_DIR=/run/user/1000 systemctl --user show -p ActiveState,InvocationID,FragmentPath,DropInPaths $S" ]] ||
  fail "session query user: $(sort -u "$FAKE_STATE/setpriv.log")"
[[ $(sort -u "$FAKE_STATE/setpriv-fds.log") == /dev/null ]] || fail "session query stdin or extra fds: $(sort -u "$FAKE_STATE/setpriv-fds.log")"
reset
st "$B b"
rm -f "$MICROOS_RUNDIR/session-current"
MICROOS_BOOT_OK_USER_ACTIVE=foo.service run || fail "listed user unit with no session-current: $(cat "$tmp/out")"
is_pinned "$B" || fail "booted not pinned with a listed user unit"
[[ $(sort -u "$FAKE_STATE/user.log") == "systemctl --user show -p ActiveState,InvocationID,FragmentPath,DropInPaths foo.service" ]] ||
  fail "session-current read with MICROOS_BOOT_OK_USER_ACTIVE set: $(sort -u "$FAKE_STATE/user.log")"
reset
st "$B b"
MICROOS_BOOT_OK_USER_ACTIVE=$S FAKE_USER_DOWN=1 FAKE_INACTIVE_LATE=multi-user.target run_rc
(( r == 1 )) || fail "target down after the session: exit $r"
grep -q "not confirmed: multi-user.target not active after 2 s" "$tmp/out" || fail "target down after the session message: $(cat "$tmp/out")"
reset
st "$B b"
FAKE_ID_G_FAIL=1 run_rc
(( r == 1 )) || fail "no group for the user: exit $r"
grep -q "^id:" "$tmp/out" && fail "id stderr in the output: $(cat "$tmp/out")"
reset
st "$B b"
FAKE_USER_DOWN=2 run || fail "user manager up late: $(cat "$tmp/out")"
is_pinned "$B" || fail "booted not pinned after the user manager came up"
(( $(cat "$FAKE_STATE/user-reads") >= 3 )) || fail "user manager down: read $(cat "$FAKE_STATE/user-reads") times"
reset
st "$B b"
FAKE_USER_DOWN=100 run_rc
(( r == 1 )) || fail "user manager never up: exit $r"
grep -q "not confirmed: $S not active after 2 s" "$tmp/out" || fail "user manager never up message: $(cat "$tmp/out")"
[[ -z $(writes) && -z $(events) ]] || fail "pinned with no user manager: $(events)"


N=gamescope-session-plus@dap.service
reset
st "$B b" "$P p"
echo "dap $N 4" > "$MICROOS_RUNDIR/session-current"
MICROOS_BOOT_OK_HOLD=3 run || fail "current session held: $(cat "$tmp/out")"
is_pinned "$B" || fail "booted not pinned with the current session held"
[[ $(sort -u "$FAKE_STATE/user.log") == "systemctl --user show -p ActiveState,InvocationID,FragmentPath,DropInPaths $N" ]] ||
  fail "current session unit query: $(sort -u "$FAKE_STATE/user.log")"
(( $(cat "$FAKE_STATE/user-reads") >= 4 )) || fail "current session read $(cat "$FAKE_STATE/user-reads") times in the hold"
[[ $(cat "$MICROOS_RUNDIR/deployments") == "booted=$B"$'\n'"confirmed=yes"$'\n'"rollback=yes" ]] ||
  fail "deployments with a rollback: $(cat "$MICROOS_RUNDIR/deployments")"
[[ $(stat -c %a "$MICROOS_RUNDIR/deployments") == 644 ]] || fail "deployments mode $(stat -c %a "$MICROOS_RUNDIR/deployments")"
reset
st "$B b"
run || fail "pass with no rollback: $(cat "$tmp/out")"
[[ $(cat "$MICROOS_RUNDIR/deployments") == "booted=$B"$'\n'"confirmed=yes"$'\n'"rollback=no" ]] ||
  fail "deployments with no rollback: $(cat "$MICROOS_RUNDIR/deployments")"
reset
st "$B b"
echo "recovery gamescope-session-plus@recovery.service 2" > "$MICROOS_RUNDIR/session-current"
run_rc
(( r == 1 )) || fail "recovery current: exit $r"
grep -q "not confirmed: recovery is the current session after 2 s" "$tmp/out" || fail "recovery message: $(cat "$tmp/out")"
[[ -z $(writes) && -z $(events) ]] || fail "pinned with recovery current: $(events)"
[[ ! -e $FAKE_STATE/user-reads ]] || fail "recovery unit read"
reset
st "$B b"
t0=$SECONDS
FAKE_SWITCH_AT=3 FAKE_SWITCH_TO="steam $S 2" MICROOS_BOOT_OK_HOLD=4 MICROOS_BOOT_OK_WAIT=0 run || fail "switch in the hold: $(cat "$tmp/out")"
grep -q "hold restarted: current session changed to steam" "$tmp/out" || fail "switch in the hold message: $(cat "$tmp/out")"
(( SECONDS - t0 >= 6 )) || fail "hold not restarted after a switch: $((SECONDS - t0)) s"
(( $(cat "$FAKE_STATE/user-reads") >= 8 )) || fail "switch in the hold: read $(cat "$FAKE_STATE/user-reads") times"
is_pinned "$B" || fail "booted not pinned after a switch in the hold"
reset
st "$B b"
FAKE_SWITCH_AT=2 FAKE_SWITCH_TO="recovery gamescope-session-plus@recovery.service 2" MICROOS_BOOT_OK_HOLD=4 run_rc
(( r == 1 )) || fail "switch to recovery in the hold: exit $r"
grep -q "hold restarted: recovery is the current session" "$tmp/out" || fail "switch to recovery message: $(cat "$tmp/out")"
[[ -z $(writes) && -z $(events) ]] || fail "pinned after a switch to recovery: $(events)"
reset
st "$B b"
FAKE_USER_RESTART_AFTER=2 MICROOS_BOOT_OK_HOLD=3 run || fail "current session restarted in the hold: $(cat "$tmp/out")"
grep -q "hold restarted: $S restarted" "$tmp/out" || fail "current session restart message: $(cat "$tmp/out")"
(( $(cat "$FAKE_STATE/user-reads") >= 6 )) || fail "restart did not restart the hold: read $(cat "$FAKE_STATE/user-reads") times"
is_pinned "$B" || fail "booted not pinned after a restart in the hold"
reset
st "$B b"
rm -f "$MICROOS_RUNDIR/session-current"
run_rc
(( r == 1 )) || fail "no session-current: exit $r"
grep -q "not confirmed: no session-current after 2 s" "$tmp/out" || fail "no session-current message: $(cat "$tmp/out")"
[[ -z $(writes) && -z $(events) ]] || fail "pinned with no session-current: $(events)"
( sleep 1.5; echo "steam $S 1" > "$MICROOS_RUNDIR/session-current" ) &
MICROOS_BOOT_OK_WAIT=5 run || fail "session-current written late: $(cat "$tmp/out")"
wait
is_pinned "$B" || fail "booted not pinned after session-current came up"
reset
st "$B b"
echo "steam $S 1 2" > "$MICROOS_RUNDIR/session-current"
run || fail "session-current with the monotonic stamp: $(cat "$tmp/out")"
is_pinned "$B" || fail "booted not pinned with the monotonic stamp"
reset
st "$B b"
echo "steam $S 1" > "$tmp/current-target"
ln -sf "$tmp/current-target" "$MICROOS_RUNDIR/session-current"
run_rc
(( r == 1 )) || fail "symlinked session-current: exit $r"
grep -q "not confirmed: no session-current after 2 s" "$tmp/out" || fail "symlinked session-current message: $(cat "$tmp/out")"
[[ ! -e $FAKE_STATE/user-reads ]] || fail "symlinked session-current followed"
for bad in "steam ../x.service 1" "steam $S" "steam $S 1 x" "steam $S 1 2 3" "Steam $S 1"; do
  reset
  st "$B b"
  echo "$bad" > "$MICROOS_RUNDIR/session-current"
  run_rc
  (( r == 1 )) || fail "session-current '$bad': exit $r"
  [[ ! -e $FAKE_STATE/user-reads ]] || fail "session-current '$bad' used"
done
reset
st "$B b"
FAKE_USER_FRAGMENT=/home/micro/.config/systemd/user/gamescope-session-plus@.service run_rc
(( r == 1 )) || fail "user fragment: exit $r"
[[ $(grep -c "$S refused: FragmentPath '/home/micro/.config/systemd/user/gamescope-session-plus@.service'" "$tmp/out") == 1 ]] ||
  fail "user fragment refusal not logged once: $(cat "$tmp/out")"
grep -q "not confirmed: $S refused, unit not from /usr/lib or /etc after 2 s" "$tmp/out" || fail "user fragment message: $(cat "$tmp/out")"
[[ -z $(writes) && -z $(events) ]] || fail "pinned with a user fragment: $(events)"
reset
st "$B b"
FAKE_USER_DROPINS="/usr/lib/systemd/user/gamescope-session-plus@.service.d/10-microos-track.conf /home/micro/.config/systemd/user/gamescope-session-plus@steam.service.d/override.conf" run_rc
(( r == 1 )) || fail "user drop-in: exit $r"
grep -q "$S refused: .*DropInPaths '.*/home/micro/" "$tmp/out" || fail "user drop-in refusal: $(cat "$tmp/out")"
[[ -z $(writes) && -z $(events) ]] || fail "pinned with a user drop-in: $(events)"
reset
st "$B b"
FAKE_USER_HOME_READS=2 MICROOS_BOOT_OK_WAIT=4 run || fail "user fragment removed in the wait: $(cat "$tmp/out")"
grep -q "$S refused" "$tmp/out" || fail "user fragment in the wait not logged: $(cat "$tmp/out")"
is_pinned "$B" || fail "booted not pinned after the user fragment went away"
reset
st "$B b"
FAKE_USER_FRAGMENT="" run_rc
(( r == 1 )) || fail "no fragment: exit $r"
reset
st "$B b"
FAKE_USER_DROPINS="/usr/lib/systemd/user/gamescope-session-plus@.service.d/10-microos-track.conf /etc/systemd/user/gamescope-session-plus@steam.service.d/10-x.conf" run ||
  fail "drop-ins under /usr/lib and /etc: $(cat "$tmp/out")"
is_pinned "$B" || fail "booted not pinned with drop-ins under /usr/lib and /etc"
reset
st "$B b"
FAKE_USER_DROPINS="" run || fail "no drop-ins: $(cat "$tmp/out")"
reset
st "$B b"
FAKE_USER_FRAGMENT=/home/micro/.config/systemd/user/foo.service MICROOS_BOOT_OK_USER_ACTIVE=foo.service run_rc
(( r == 1 )) || fail "listed user unit with a user fragment: exit $r"
grep -q "foo.service refused" "$tmp/out" || fail "listed user unit refusal: $(cat "$tmp/out")"
reset
st "$B b"
FAKE_INACTIVE=display-manager.service run_rc
(( r == 1 )) || fail "display manager inactive: exit $r"
grep -q "not confirmed: display-manager.service not active after 2 s" "$tmp/out" || fail "display manager message: $(cat "$tmp/out")"
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
[[ -z $(writes) && -z $(events) ]] || fail "pinned or baked on a skip: $(events)"
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
st "$B b" "$P p"
echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
FAKE_BAK_FAIL=1 run_rc
(( r == 1 )) || fail "BAK failure exit $r"
is_pinned "$P" || fail "old pin dropped on a BAK failure"
grep -q '^unpin' "$FAKE_STATE/events" && fail "unpin after a BAK failure"
[[ $(pins) == "$P,$B" ]] || fail "boot-ok-pins after a BAK failure: $(pins)"
: > "$FAKE_STATE/events"
run || fail "pass after a BAK failure: $(cat "$tmp/out")"
grep -q '^pin booted' "$FAKE_STATE/events" && fail "already pinned booted pinned again"
is_pinned "$P" && fail "old pin kept after the pass"
[[ $(pins) == "$B" ]] || fail "boot-ok-pins after the pass: $(pins)"

reset
st "$B b" "$P p"
echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
FAKE_BAK_WRONG=1 run_rc
(( r == 1 )) || fail "wrong bake id exit $r"
is_pinned "$P" || fail "unpinned after a wrong bake id"
grep -q '^unpin' "$FAKE_STATE/events" && fail "unpin after a wrong bake id"

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
st "$B b" "$P p" "$H p"
echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
FAKE_BAK_SLEEP=10 "$bootok" > "$tmp/out" 2>&1 &
pid=$!
for _ in $(seq 1 100); do
  [[ -e $FAKE_STATE/bak-sleeping ]] && break
  sleep 0.1
done
[[ -e $FAKE_STATE/bak-sleeping ]] || fail "the bake did not start"
kill -TERM "$pid"
wait "$pid" 2> /dev/null || true
kill "$(cat "$FAKE_STATE/bak-sleeping")" 2> /dev/null || true
{ is_pinned "$P" && is_pinned "$B" && is_pinned "$H"; } || fail "pins changed by a stop during the bake"
[[ $(pins) == "$P,$B" ]] || fail "boot-ok-pins after a stop during the bake: $(pins)"
st "$C b" "$B p" "$P p" "$H p"
run || fail "pass after a stop: $(cat "$tmp/out")"
is_pinned "$P" && fail "P still pinned after the next pass"
is_pinned "$B" && fail "B still pinned after the next pass"
is_pinned "$H" || fail "hand pin dropped after the next pass"
is_pinned "$C" || fail "C not pinned"
[[ $(pins) == "$C" ]] || fail "boot-ok-pins after the next pass: $(pins)"

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
[[ $(events) == "bak $B confirmed=$B" ]] || fail "--bak not called with nothing to do: $(events)"

sys=$tmp/sysroot
boot=$tmp/boot
bootcsum=$(c f)
kver=7.2.12-microos
bdir=$boot/ostree/default-$bootcsum
. "$conf"
fixture() {
  local i=0 id d
  rm -rf "$sys" "$boot"
  mkdir -p "$bdir/dtb/qcom" "$boot/loader/entries" "$sys/ostree/boot.1/default/$bootcsum"
  { head -c 56 /dev/zero; printf 'ARMd'; seq 1 3000; } > "$bdir/vmlinuz-$kver"
  seq 1 500 > "$bdir/initramfs-$kver.img"
  { printf '\xd0\x0d\xfe\xed'; seq 1 50; } > "$bdir/dtb/$MICROOS_DTB"
  for id; do
    d=$sys/ostree/deploy/default/deploy/$id
    mkdir -p "$d/usr/lib/microos" "$d/usr/libexec/microos"
    cp "$conf" "$d/usr/lib/microos/"
    cp "$build" "$d/usr/libexec/microos/"
    echo "IMAGE_VERSION=20261013.1234567" > "$d/usr/lib/microos/version"
    ln -s "../../../deploy/default/deploy/$id" "$sys/ostree/boot.1/default/$bootcsum/$i"
    printf 'title MicroOS\nversion %s\noptions root=UUID=r rw ostree=/ostree/boot.1/default/%s/%s\nlinux %s\ninitrd %s\nfdtdir %s\n' \
      "$(( 9 - i ))" "$bootcsum" "$i" "/boot/ostree/default-$bootcsum/vmlinuz-$kver" \
      "/boot/ostree/default-$bootcsum/initramfs-$kver.img" "/boot/ostree/default-$bootcsum/dtb" \
      > "$boot/loader/entries/ostree-$i.conf"
    i=$((i + 1))
  done
}
finalize() {
  local id e l
  for id in $(jq -r '.deployments[] | select((.pinned or .booted) | not) | "\(.checksum).\(.serial)"' "$FAKE_STATE/status.json"); do
    rm -rf "$sys/ostree/deploy/default/deploy/$id"
  done
  for l in "$sys"/ostree/boot.1/default/"$bootcsum"/*; do
    [[ -e $l ]] || rm -f "$l"
  done
  for e in "$boot"/loader/entries/*.conf; do
    l=$(sed -n 's/^options .*ostree=\([^ ]*\).*/\1/p' "$e")
    [[ -e $sys$l ]] || rm -f "$e"
  done
  jq '.deployments |= map(select(.pinned or .booted)) | .deployments |= (to_entries | map(.value.index = .key | .value))' \
    "$FAKE_STATE/status.json" > "$FAKE_STATE/status.new"
  mv -f "$FAKE_STATE/status.new" "$FAKE_STATE/status.json"
}
bak_ok() {
  local name l t
  [[ -e $MICROOS_ESP/KERNEL.BAK ]] || return 0
  name=$(head -c 576 "$MICROOS_ESP/KERNEL.BAK" | tail -c 512 | tr -d '\0' | grep -o 'microos.deploy=[^ ]*' | cut -d= -f2)
  for l in "$sys"/ostree/boot.{0,1}/*/*/*; do
    t=$(realpath -e "$l" 2> /dev/null) || continue
    [[ ${t##*/} != "$name" ]] || return 0
  done
  return 1
}
real() { MICROOS_BOOT=$boot MICROOS_SYSROOT=$sys "$update" "$@" > "$tmp/uout" 2>&1; }

reset
fixture "$B" "$P" "$D"
st "$B b" "$P p" "$D"
echo "$P" > "$MICROOS_STATEDIR/boot-ok-pins"
echo "$P" > "$MICROOS_STATEDIR/confirmed"
real --bak "$P" || fail "fixture bake of P: $(cat "$tmp/uout")"
{ FAKE_KILL_AFTER_PIN=1 run_rc; } 2> /dev/null
[[ $(cat "$MICROOS_STATEDIR/confirmed") == "$P" ]] || fail "confirmed written before the kill"
finalize
real || fail "default run after a killed boot ok: $(cat "$tmp/uout")"
bak_ok || fail "KERNEL.BAK names a deployment with no bootlink after a killed boot ok"
reset
fixture "$B" "$P" "$D"
st "$B b" "$P p" "$D"
real --bak "$P" || fail "fixture bake of P: $(cat "$tmp/uout")"
st "$B b" "$P" "$D"
{ FAKE_KILL_AFTER_PIN=1 run_rc; } 2> /dev/null
finalize
real || fail "default run after a killed first boot ok: $(cat "$tmp/uout")"
bak_ok || fail "KERNEL.BAK names a deployment with no bootlink after a killed first boot ok"
[[ -e $sys/ostree/deploy/default/deploy/$P ]] && fail "fixture finalize kept the unpinned P"
echo "quiet microos.deploy=$B" > "$tmp/cmdline"
rm -f "$MICROOS_ESP/.microos-bootimg.id"
MICROOS_BOOT=$boot MICROOS_SYSROOT=$sys MICROOS_CMDLINE=$tmp/cmdline "$bootlog" run finalize -- "$update" > /dev/null 2>&1 ||
  fail "bootlog run of the bake"
[[ $(tail -n 1 "$boot/microos/shutdown.log") == *" step=finalize rc=0 booted=$B microos-bootimg-update: KERNEL $B baked, KERNEL.BAK $B kept" ]] ||
  fail "finalize log line: $(tail -n 1 "$boot/microos/shutdown.log")"
out=$(MICROOS_BOOT=$boot MICROOS_SYSROOT=$sys MICROOS_CMDLINE=$tmp/cmdline "$bootlog" run bak -- "$update" --bak "$B" 2> /dev/null) ||
  fail "bootlog run of --bak"
[[ $(grep '^bak ' <<< "$out") == "bak $B $(cat "$MICROOS_ESP/.microos-bootimg-bak.id")" ]] || fail "--bak line through bootlog: $out"
[[ $(tail -n 1 "$boot/microos/shutdown.log") == *" step=bak rc=0 booted=$B microos-bootimg-update: KERNEL $B kept, KERNEL.BAK $B kept" ]] ||
  fail "--bak log line: $(tail -n 1 "$boot/microos/shutdown.log")"

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
printf 'deploy=%s\ndigest=%s\nversion=20261013.abc\nimage=ghcr.io/seilent/microos:testing\nstaged=2026-10-13T00:00:00Z\n' "$B" "$other" > "$exp"
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
