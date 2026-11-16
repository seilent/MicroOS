#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
tool=$tree/usr/libexec/microos/microos-etc-carry
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

A=$(printf a%.0s {1..64}).0
N=$(printf c%.0s {1..64}).0
sys=$tmp/sysroot
state=$tmp/state
d=$sys/ostree/deploy/default/deploy
calls=$tmp/calls

mk() {
  rm -rf "$sys" "$state" "$calls"
  mkdir -p "$d/$A/etc/NetworkManager/system-connections" "$d/$N/etc" "$state"
  for f in hostname .updated machine-id ld.so.cache group group- passwd NetworkManager/system-connections/home.nmconnection; do
    echo "a $f" > "$d/$A/etc/$f"
  done
  echo "n hostname" > "$d/$N/etc/hostname"
  sleep 1
  printf 'deploy=%s\ndigest=sha256:x\nfrom=%s\nstamp=%s\nwritten=ba9876543210\n' "$N" "$A" "$(date +%s)" > "$state/update-written"
  sleep 1
  printf '#!/bin/sh\necho "$0" >> %s\n' "$calls" > "$tmp/fake"
  chmod 755 "$tmp/fake"
}
edit() { echo "a $1 later" > "$d/$A/etc/$1"; }
run() {
  out=$(env MICROOS_STATEDIR="$state" MICROOS_SYSROOT="$sys" MICROOS_ETC="${1:-$d/$N/etc}" MICROOS_GROUPS="$tmp/fake" \
    MICROOS_SYSUSERS="$tmp/fake" "$tool" 2>&1) && code=0 || code=$?
}
val() { sed -n "s/^$1=//p" "$state/update-written" | head -1; }

[[ -x $tool ]] || { echo "FAIL: $tool missing"; exit 1; }

mk
mkdir -p "$d/$A/etc/NetworkManager/system-connections"
echo "a new wifi" > "$d/$A/etc/NetworkManager/system-connections/away.nmconnection"
chmod 600 "$d/$A/etc/NetworkManager/system-connections/away.nmconnection"
edit hostname
for f in .updated machine-id ld.so.cache group-; do edit "$f"; done
run
[[ $code == 0 ]] || fail "exit $code: $out"
[[ $(< "$d/$N/etc/hostname") == "a hostname later" ]] || fail "hostname not carried"
[[ -f $d/$N/etc/NetworkManager/system-connections/away.nmconnection ]] || fail "new connection not carried"
[[ $(stat -c %a "$d/$N/etc/NetworkManager/system-connections/away.nmconnection") == 600 ]] || fail "mode not kept"
[[ ! -e $d/$N/etc/NetworkManager/system-connections/home.nmconnection ]] || fail "file older than stamp carried"
for f in .updated machine-id ld.so.cache group-; do
  [[ ! -e $d/$N/etc/$f ]] || fail "$f carried"
done
[[ $(val carried) == 2 ]] || fail "carried=$(val carried), want 2"
[[ ! -e $calls ]] || fail "groups or sysusers run without an account file"

cp "$d/$N/etc/hostname" "$tmp/h"
edit hostname
echo "a hostname again" > "$d/$A/etc/hostname"
run
[[ $code == 0 ]] || fail "second run exit $code"
cmp -s "$d/$N/etc/hostname" "$tmp/h" || fail "second run carried again"

mk
edit group
run
[[ $(< "$d/$N/etc/group") == "a group later" ]] || fail "group not carried"
[[ $(wc -l < "$calls") == 2 ]] || fail "groups and sysusers not run after an account file: $(cat "$calls" 2>/dev/null)"

mk
edit hostname
mkdir -p "$tmp/other"
run "$tmp/other"
[[ $code == 0 ]] || fail "not booted N: exit $code"
[[ $(< "$d/$N/etc/hostname") == "n hostname" ]] || fail "carried while N is not the running /etc"
[[ -z $(val carried) ]] || fail "carried= written while N is not booted"

mk
rm "$state/update-written"
run
[[ $code == 0 ]] || fail "no record: exit $code"

mk
sed -i '/^stamp=/d' "$state/update-written"
edit hostname
run
[[ $code == 0 ]] || fail "no stamp: exit $code, want 0"
[[ $(< "$d/$N/etc/hostname") == "n hostname" ]] || fail "no stamp: carried"

mk
sed -i '/^written=/d' "$state/update-written"
edit hostname
run
[[ $(< "$d/$N/etc/hostname") == "a hostname later" ]] || fail "booted N without written=: not carried"

mk
printf 'garbage\n' > "$state/update-written"
run
[[ $code == 0 ]] || fail "malformed record: exit $code, want 0"

mk
edit hostname
touch -d @1000 "$d/$A/etc/hostname"
mv "$d/$A/etc/hostname" "$d/$A/etc/hostname.x" && mv "$d/$A/etc/hostname.x" "$d/$A/etc/hostname"
run
[[ $(< "$d/$N/etc/hostname") == "a hostname later" ]] || fail "old mtime, new ctime: not carried"

mk
edit hostname
mkdir -p "$d/$N/etc/passwd"
edit passwd
run
[[ $code == 0 ]] || fail "one copy fails: exit $code, want 0"
[[ $(< "$d/$N/etc/hostname") == "a hostname later" ]] || fail "one copy fails: the others not carried"
grep -q "passwd not carried" <<< "$out" || fail "one copy fails: no message: $out"

if (( rc == 0 )); then
  echo "etc-carry: all cases passed"
fi
exit "$rc"
