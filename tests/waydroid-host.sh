#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

guard=$tree/usr/libexec/microos/microos-android-guard
cfg=$tmp/config
devs=$tmp/devices
base=$'lxc.rootfs.path = /var/lib/waydroid/rootfs\nlxc.cgroup2.devices.allow = a\nlxc.cgroup2.devices.deny = b *:* rwm\nlxc.cgroup2.devices.deny = c 1:1 rwm\nlxc.cgroup2.devices.deny = c 1:4 rwm\nlxc.include = /var/lib/waydroid/lxc/waydroid/config_nodes'
printf 'Character devices:\n  1 mem\n 10 misc\n247 bsg\n\nBlock devices:\n  8 sd\n250 bsg\n' > "$devs"
gd() { MICROOS_LXC_CONFIG=$cfg MICROOS_PROC_DEVICES=$devs "$guard"; }

printf '%s\n' "$base" > "$cfg"
out=$(gd) || fail "guard exited $? on a guarded config"
[[ $out == 'microos-android-guard: bsg 247' ]] || fail "guard printed: $out"
[[ $(< "$cfg") == "$base"$'\nlxc.cgroup2.devices.deny = c 247:* rwm' ]] || fail "guard did not deny the char bsg major: $(< "$cfg")"
sed -i 's/^247 bsg/239 bsg/' "$devs"
gd > /dev/null || fail "guard exited $? on its second run"
[[ $(< "$cfg") == "$base"$'\nlxc.cgroup2.devices.deny = c 239:* rwm' ]] || fail "guard kept the old bsg major: $(< "$cfg")"
printf 'Character devices:\n  1 mem\n\nBlock devices:\n  8 sd\n' > "$devs"
out=$(gd) || fail "guard exited $? with no bsg major"
[[ $out == 'microos-android-guard: bsg absent' && $(< "$cfg") == "$base" ]] || fail "guard with no bsg: $out: $(< "$cfg")"
grep -v 'devices.deny = b' <<< "$base" > "$cfg"
rc2=0
gd > /dev/null 2> "$tmp/err" || rc2=$?
[[ $rc2 == 1 ]] && grep -q 'has no block guard' "$tmp/err" || fail "guard on a config without the block guard: rc $rc2"
rm -f "$cfg"
rc2=0
gd > /dev/null 2> "$tmp/err" || rc2=$?
[[ $rc2 == 1 ]] && grep -q 'waydroid init comes first' "$tmp/err" || fail "guard with no config: rc $rc2"

exit "$rc"
