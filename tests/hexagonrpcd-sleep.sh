#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
hook=$tree/usr/lib/systemd/system-sleep/microos-hexagonrpcd
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

[[ -x $hook ]] || fail "microos-hexagonrpcd hook is not executable"
export STUB_LOG=$tmp/log SYSTEMCTL_STATE=$tmp/unit
run_dir=$tmp/run
marker=$run_dir/hexagonrpcd-sleep
u=microos-hexagonrpcd.service
run() {
  : > "$STUB_LOG"
  MICROOS_RUN_DIR=$run_dir PATH="$here/slpi-sensors:$PATH" bash "$hook" "$@" 2> "$tmp/err" || fail "$*: exit $?"
}
calls() { grep '^systemctl' "$STUB_LOG" | paste -sd'|'; }

for s in active activating; do
  echo "$s" > "$SYSTEMCTL_STATE"
  run pre suspend
  [[ -e $marker ]] || fail "pre with $s unit: no marker"
  [[ $(calls) == "systemctl is-active $u|systemctl stop $u" ]] || fail "pre with $s unit: $(calls)"
  run post suspend
  [[ $(calls) == "systemctl reset-failed $u|systemctl --no-block start $u" ]] || fail "post: $(calls)"
  [[ ! -e $marker ]] || fail "post left the marker"
done

for s in inactive failed; do
  echo "$s" > "$SYSTEMCTL_STATE"
  run pre suspend
  [[ ! -e $marker ]] || fail "pre with $s unit wrote the marker"
  [[ $(calls) == "systemctl is-active $u" ]] || fail "pre with $s unit: $(calls)"
  run post suspend
  [[ -z $(calls) ]] || fail "post without a marker: $(calls)"
done

echo active > "$SYSTEMCTL_STATE"
: > "$tmp/notadir"
: > "$STUB_LOG"
MICROOS_RUN_DIR=$tmp/notadir/run PATH="$here/slpi-sensors:$PATH" bash "$hook" pre suspend 2> "$tmp/err" || fail "unwritable marker: exit $?"
[[ $(calls) == "systemctl is-active $u" ]] || fail "unwritable marker: $(calls)"
grep -q "writing $tmp/notadir/run/hexagonrpcd-sleep failed, $u left running" "$tmp/err" || fail "unwritable marker not logged: $(cat "$tmp/err")"

echo active > "$SYSTEMCTL_STATE"
run pre hibernate
[[ -z $(calls) && ! -e $marker ]] || fail "pre hibernate acted: $(calls)"
for verb in suspend-then-hibernate hybrid-sleep; do
  echo active > "$SYSTEMCTL_STATE"
  run pre "$verb"
  [[ -e $marker ]] || fail "pre $verb: no marker"
  run post "$verb"
  [[ $(calls) == "systemctl reset-failed $u|systemctl --no-block start $u" ]] || fail "post $verb: $(calls)"
done

if (( rc == 0 )); then
  echo "hexagonrpcd-sleep: ok"
fi
exit "$rc"
