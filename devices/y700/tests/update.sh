#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
tool=$tree/usr/bin/microos-update
policy=$tree/etc/containers/policy.json
bin=$here/update/bin
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

fake=$tmp/fake
state=$tmp/state
run=$tmp/run
rootfs=$tmp/rootfs
power=$tmp/power
mkdir -p "$tmp/home"
rid=0123456789ab
nid=ba9876543210

repo=ghcr.io/seilent/microos-y700
R=$repo:testing
csum_b=$(printf b%.0s {1..64})
csum_s=$(printf 5%.0s {1..64})
dig_b=sha256:$(printf 1%.0s {1..64})
dig_c=sha256:$(printf 2%.0s {1..64})
dig_x=sha256:$(printf 3%.0s {1..64})
ver_b=20261012.bbbbbbb
ver_c=20261013.ccccccc
ver_x=20261013.xxxxxxx

mk() {
  jq -n --arg oi "$o_image" --arg os "$o_sig" --arg bd "$b_dig" --arg bv "$b_ver" --arg sd "$s_dig" \
    --arg sv "$s_ver" --arg si "$s_img" --arg cb "$csum_b" --arg cs "$csum_s" --argjson p "$pinned" '{
      spec: {image: ({image: $oi, transport: "registry"} + (if $os == "" then {} else {signature: $os} end))},
      status: {
        booted: {image: {image: {image: "\($oi)", transport: "registry"}, version: $bv, imageDigest: $bd},
                 pinned: $p, ostree: {checksum: $cb, deploySerial: 0}},
        staged: (if $sd == "" then null else
                 {image: {image: {image: $si, transport: "registry"}, version: $sv, imageDigest: $sd},
                  pinned: false, ostree: {checksum: $cs, deploySerial: 0}} end)
      }
    }' > "$fake/bootc$1.json"
  jq -n --arg sd "$s_dig" --arg cb "$csum_b" --arg cs "$csum_s" --argjson p "$pinned" '{
      deployments: ((if $sd == "" then [] else [{checksum: $cs, serial: 0, stateroot: "default", staged: true, booted: false,
          pinned: false}] end)
        + [{checksum: $cb, serial: 0, stateroot: "default", staged: false, booted: true, pinned: $p}])
        | to_entries | map(.value + {index: .key})
    }' > "$fake/ostree$1.json"
}

bootimg() {
  rm -f "$tmp/boot_b"
  truncate -s 1M "$tmp/boot_b"
  printf 'ANDROID!' | dd of="$tmp/boot_b" conv=notrunc status=none
  printf '\x02\x00\x00\x00' | dd of="$tmp/boot_b" bs=1 seek=40 conv=notrunc status=none
  printf 'root=PARTLABEL=microos microos.deploy=%s microos.id=%s' "$1" "$2" | dd of="$tmp/boot_b" bs=1 seek=64 conv=notrunc status=none
}

pdir=$tmp/ostree/deploy/default/deploy/$csum_s.0
initrd() {
  local d=$tmp/initrd.d
  rm -rf "$d"
  mkdir -p "$d/usr/lib64" "$d/usr/bin" "$d/usr/lib" "$d/etc"
  echo "$2" > "$d/etc/microos-initrd-id"
  touch "$d/usr/lib64/libc.so.6" "$d/usr/bin/sh" "$d/etc/udev.conf" "$d/usr/lib/os-release"
  (cd "$d" && printf '%s\n' . usr usr/lib64 usr/lib64/libc.so.6 usr/bin usr/bin/sh usr/lib usr/lib/os-release etc etc/microos-initrd-id etc/udev.conf |
    cpio -o -H newc --quiet 2> /dev/null | zstd -q -c > "$1")
}

tree_files() {
  mkdir -p "$1/usr/lib/modules/7.2.12-microos" "$1/usr/lib/dracut/modules.d/92microos-y700-guard" "$1/usr/libexec/microos" \
    "$1/usr/lib64" "$1/usr/bin" "$1/usr/etc" "$1/usr/lib/systemd"
  echo "vmlinuz" > "$1/usr/lib/modules/7.2.12-microos/vmlinuz"
  initrd "$1/usr/lib/modules/7.2.12-microos/initramfs.img" "$2"
  echo "guard" > "$1/usr/lib/dracut/modules.d/92microos-y700-guard/microos-guard"
  echo "prepare-root" > "$1/usr/libexec/microos/prepare-root"
  echo "libc" > "$1/usr/lib64/libc.so.6"
  echo "sh" > "$1/usr/bin/sh"
  echo "udev.conf" > "$1/usr/etc/udev.conf"
  echo "IMAGE_VERSION=$2" > "$1/usr/lib/os-release"
  echo "udevadm" > "$1/usr/bin/udevadm"
  ln -s ../../bin/udevadm "$1/usr/lib/systemd/systemd-udevd"
}

reset() {
  name=$1
  rm -rf "$fake" "$state" "$run" "$rootfs" "$power" "$tmp/ostree"
  mkdir -p "$fake" "$state" "$run" "$power/battery" "$pdir/usr/libexec/microos"
  tree_files "$rootfs" running
  tree_files "$pdir" pending
  cat > "$pdir/usr/libexec/microos/microos-bootimg-update" <<'TOOL'
#!/usr/bin/env bash
if flock -n "$MICROOS_RUNDIR/update.lock" true; then l=free; else l=held; fi
w=$(sed -n 's/^deploy=//p' "$MICROOS_STATEDIR/update-written" 2> /dev/null)
echo "lock=$l inhibit=${FAKE_INHIBITED:-0} written=$w $*" >> "$FAKE_DIR/tool.calls"
if [[ ${FAKE_TOOL_WRITES:-1} == 1 ]]; then
  printf 'root=PARTLABEL=microos microos.deploy=%s microos.id=ba9876543210' "$4" |
    dd of="$MICROOS_BOOT_B" bs=1 seek=64 conv=notrunc status=none
fi
[[ ${FAKE_TOOL_RC:-0} == 0 ]] || { echo "fake tool failure" >&2; exit 1; }
TOOL
  chmod 755 "$pdir/usr/libexec/microos/microos-bootimg-update"
  touch -d @5000 "$pdir.origin"
  printf 'Battery\n' > "$power/battery/type"
  printf '80\n' > "$power/battery/capacity"
  printf 'Discharging\n' > "$power/battery/status"
  bootimg "$csum_b.0" "$rid"
  echo "root=PARTLABEL=microos ro microos.deploy=$csum_b.0 microos.id=$rid" > "$tmp/cmdline"
  echo "$csum_b.0" > "$run/boot-confirmed"
  o_image=$R o_sig=containerPolicy b_dig=$dig_b b_ver=$ver_b s_dig="" s_ver="" s_img="" pinned=true
  export FAKE_CHANNEL_DIGEST=$dig_c FAKE_CHANNEL_VERSION=$ver_c FAKE_FREE=$((8 << 30))
  unset FAKE_REGISTRY_DOWN FAKE_TAG_MISSING FAKE_CHANNEL_DIGEST_LATER FAKE_BOOTC_FAIL FAKE_CHECK_FAIL FAKE_PASSWD_HOME
  unset CONTAINERS_POLICY_JSON XDG_CONFIG_HOME
  etcpol=$policy
  homeenv=(HOME="$tmp/home")
}

staged_after() {
  o_image=$1 o_sig=containerPolicy s_dig=$2 s_ver=$3 s_img=$1
  mk .after
}

t() {
  rm -f "$fake/bootc.calls" "$fake/ostree.calls" "$fake/inhibit.calls" "$fake/skopeo.calls" "$fake/prio.calls" \
    "$fake/ostree.reads" "$fake/skopeo.reads" "$fake/run.calls" "$fake/tool.calls" "$fake/systemctl.calls"
  out=$(cd "$tmp" && env "${homeenv[@]}" PATH="$bin:$PATH" FAKE_DIR="$fake" MICROOS_RUNDIR="$run" \
    MICROOS_STATEDIR="$state" MICROOS_SYSROOT="$tmp" MICROOS_ETC_POLICY="$etcpol" MICROOS_ROOT="$rootfs" \
    MICROOS_CMDLINE="$tmp/cmdline" MICROOS_BOOT_B="$tmp/boot_b" MICROOS_BOOTB_LIB="$tree/usr/libexec/microos/microos-bootb" \
    MICROOS_POWER="$power" MICROOS_UPDATE_LOCK_WAIT=1 "$tool" "$@" 2>&1) && code=0 || code=$?
  if [[ -f $fake/bootc.calls ]]; then
    cat "$fake/bootc.calls" >> "$tmp/bootc.all"
  fi
  if [[ ${1:-} == --check ]]; then
    [[ ! -e $fake/inhibit.calls ]] || fail "$name: --check ran under the inhibitor"
    if grep -q undeploy "$fake/ostree.calls" 2>/dev/null; then fail "$name: --check undeployed"; fi
  fi
}

want() { [[ $code == "$1" ]] || fail "$name: exit $code, want $1"$'\n'"$out"; }
has() { grep -qF -- "$1" <<< "$out" || fail "$name: output lacks '$1'"$'\n'"$out"; }
called() { grep -qE -- "$2" "$fake/$1.calls" 2>/dev/null || fail "$name: no $1 call matching '$2'"; }
not_called() {
  if grep -qE -- "$2" "$fake/$1.calls" 2>/dev/null; then fail "$name: $1 call matching '$2'"; fi
}
val() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -1; }
is() { [[ $(val "$1" "$2") == "$3" ]] || fail "$name: $2 $1=$(val "$1" "$2"), want $3"; }
gone() { [[ ! -e $1 ]] || fail "$name: $1 still exists"; }
there() { [[ -e $1 ]] || fail "$name: $1 missing"; }
stale() {
  printf 'deploy=old.0\ndigest=%s\nversion=%s\n' "$dig_x" "$ver_x" > "$state/expected-deployment"
  printf 'expected=old.0\nbooted=%s.0\ndigest=%s\nversion=%s\n' "$csum_b" "$dig_x" "$ver_x" > "$run/update-not-applied"
}

[[ -x $tool ]] || { echo "FAIL: $tool missing"; exit 1; }
[[ -f $policy ]] || { echo "FAIL: $policy missing"; exit 1; }

reset usage
mk ""
t --bogus
want 2

reset s1-c1
mk ""
exec 8> "$run/update.lock"
flock -n 8
for m in "" --check; do
  t ${m:+"$m"}
  want 3
  has "already running (microos-update or microos-boot-ok)"
  not_called bootc .
done
exec 8>&-
units=$tree/usr/lib/systemd/system
for u in microos-update.service microos-update-check.service microos-update-boot.service; do
  [[ " $(sed -n 's/^SuccessExitStatus=//p' "$units/$u") " == *" 3 "* ]] || fail "$name: $u does not count exit 3 (lock busy) as success"
done

reset s2-c2
mk ""
echo beta > "$state/update-channel"
for m in "" --check; do
  t ${m:+"$m"}
  want 1
  has "beta"
  not_called bootc .
done
rm "$state/update-channel"
jq '.default = [{"type": "insecureAcceptAnything"}]' "$policy" > "$tmp/insecure.json"
etcpol=$tmp/insecure.json
for m in "" --check; do
  t ${m:+"$m"}
  want 1
  has "$tmp/insecure.json"
  not_called bootc .
done
etcpol=$policy
mkdir -p "$tmp/home/.config/containers"
cp "$tmp/insecure.json" "$tmp/home/.config/containers/policy.json"
for m in "" --check; do
  t ${m:+"$m"}
  want 1
  has "$tmp/home/.config/containers/policy.json"
done
rm -r "$tmp/home/.config"
mkdir -p "$tmp/roothome/.config/containers"
cp "$tmp/insecure.json" "$tmp/roothome/.config/containers/policy.json"
homeenv=(-u HOME)
export FAKE_PASSWD_HOME=$tmp/roothome
t --check
want 1
has "$tmp/roothome/.config/containers/policy.json"
rm -r "$tmp/roothome/.config"
t --check
want 0
homeenv=(HOME="$tmp/home")
unset FAKE_PASSWD_HOME
export CONTAINERS_POLICY_JSON=$tmp/insecure.json XDG_CONFIG_HOME=$tmp/xdg
mkdir -p "$tmp/xdg/containers"
cp "$tmp/insecure.json" "$tmp/xdg/containers/policy.json"
t --check
want 0
unset CONTAINERS_POLICY_JSON XDG_CONFIG_HOME
jq 'del(.transports.docker["ghcr.io/seilent/microos-y700"])' "$policy" > "$tmp/noscope.json"
etcpol=$tmp/noscope.json
t
want 1
for k in "$repo:testing" "$repo@$dig_c"; do
  jq --arg k "$k" '.transports.docker[$k] = [{"type": "insecureAcceptAnything"}]' "$policy" > "$tmp/override.json"
  etcpol=$tmp/override.json
  t --check
  want 1
  has "every $repo scope"
done
jq --arg k "$repo:testing" '.transports.docker[$k] = .transports.docker["ghcr.io/seilent/microos-y700"]' "$policy" > "$tmp/override.json"
t --check
want 0
etcpol=$policy

reset tag-missing
mk ""
export FAKE_TAG_MISSING=1
for m in "" --check; do
  t ${m:+"$m"}
  want 1
  has "$R does not exist"
  not_called bootc .
done

reset s3-c3
mk ""
export FAKE_REGISTRY_DOWN=1
for m in "" --check; do
  t ${m:+"$m"}
  want 4
  not_called bootc .
done

reset s4
mk ""
export FAKE_FREE=$((1 << 30))
t
want 1
has "$((1 << 30)) bytes free, needs 2147483648"
not_called bootc .

reset s5
o_image=$repo:dev-434434b o_sig=""
mk ""
staged_after "$R" "$dig_c" "$ver_c"
t
want 0
called bootc "^inhibit=1 switch --enforce-container-sigpolicy $R\$"
called inhibit "^--what=sleep --mode=block --who=microos-update --why=staging an update bootc switch"
not_called bootc upgrade
is deploy "$state/expected-deployment" "$csum_s.0"
is digest "$state/expected-deployment" "$dig_c"
is version "$state/expected-deployment" "$ver_c"
is image "$state/expected-deployment" "$R"
has "staged $ver_c $dig_c, applies on the next reboot"

name=s6-after-s5
t
want 0
not_called bootc "switch|upgrade"
has "staged $ver_c $dig_c"

name=s6-rewrite
rm "$state/expected-deployment"
t
want 0
not_called bootc "switch|upgrade"
is deploy "$state/expected-deployment" "$csum_s.0"
is digest "$state/expected-deployment" "$dig_c"

reset s5-unsigned-testing
o_sig=""
mk ""
staged_after "$R" "$dig_c" "$ver_c"
t
want 0
called bootc "^inhibit=1 switch --enforce-container-sigpolicy $R\$"

reset s5-stable
echo stable > "$state/update-channel"
mk ""
staged_after "$repo:stable" "$dig_c" "$ver_c"
t
want 0
called skopeo "docker://$repo:stable\$"
called bootc "^inhibit=1 switch --enforce-container-sigpolicy $repo:stable\$"

reset s5-foreign
o_image=quay.io/x:y o_sig="" s_dig=$dig_x s_ver=1 s_img=quay.io/x:y
mk ""
staged_after "$R" "$dig_c" "$ver_c"
t
want 0
has "quay.io/x:y"
called bootc "^inhibit=1 switch --enforce-container-sigpolicy $R\$"
is deploy "$state/expected-deployment" "$csum_s.0"

reset s5-no-stage
o_sig=""
mk ""
t
want 1
has "no staged deployment after bootc switch"
gone "$state/expected-deployment"

reset s7
export FAKE_CHANNEL_DIGEST=$dig_b
s_dig=$dig_x s_ver=$ver_x s_img=$R
mk ""
stale
t
want 7
called ostree "^admin undeploy 0\$"
not_called bootc upgrade
gone "$state/expected-deployment"
gone "$run/update-not-applied"
has "removed staged $dig_x, the channel is back at the booted image"
[[ $(cat "$fake/skopeo.reads") == 2 ]] || fail "$name: channel read $(cat "$fake/skopeo.reads") times, want 2"

reset s7-second-read-differs
export FAKE_CHANNEL_DIGEST=$dig_b FAKE_CHANNEL_DIGEST_LATER=$dig_c
s_dig=$dig_x s_ver=$ver_x s_img=$R
mk ""
staged_after "$R" "$dig_c" "$ver_c"
t
want 0
not_called ostree undeploy
called bootc "^inhibit=1 upgrade\$"
is digest "$state/expected-deployment" "$dig_c"

reset s7-index-moved
export FAKE_CHANNEL_DIGEST=$dig_b
s_dig=$dig_x s_ver=$ver_x s_img=$R
mk ""
jq '.deployments |= (map(select(.staged | not)) + [{checksum: "r", serial: 0, staged: false, booted: false, pinned: false}] | reverse | to_entries | map(.value + {index: .key}))' \
  "$fake/ostree.json" > "$fake/ostree.json.2"
stale
t
want 1
not_called ostree undeploy
there "$state/expected-deployment"

reset s8
export FAKE_CHANNEL_DIGEST=$dig_b
mk ""
stale
t
want 7
gone "$state/expected-deployment"
gone "$run/update-not-applied"
not_called bootc "switch|upgrade"

prio() {
  called prio "^ionice -c 3 -p [0-9]+\$"
  called prio "^chrt -i -p 0 [0-9]+\$"
  called prio "^renice -n 19 -p [0-9]+\$"
}

reset s9
mk ""
staged_after "$R" "$dig_c" "$ver_c"
t
want 0
prio
called bootc "^inhibit=1 upgrade\$"
called inhibit "^--what=sleep .* bootc upgrade\$"
is deploy "$state/expected-deployment" "$csum_s.0"
is digest "$state/expected-deployment" "$dig_c"
is version "$state/expected-deployment" "$ver_c"

reset s9-mismatch
mk ""
staged_after "$R" "$dig_x" "$ver_x"
t
want 1
called ostree "^admin undeploy 0\$"
gone "$state/expected-deployment"
has "staged $dig_x is not the channel digest $dig_c, removed it"
if grep -q "applies on the next reboot" <<< "$out"; then fail "$name: announced a removed stage"; fi

reset s9-mismatch-index-moved
mk ""
staged_after "$R" "$dig_x" "$ver_x"
jq '.deployments |= (map(select(.staged | not)) | to_entries | map(.value + {index: .key}))' \
  "$fake/ostree.after.json" > "$fake/ostree.json.3"
t
want 1
not_called ostree undeploy
is digest "$state/expected-deployment" "$dig_x"

reset s9-moved-again
export FAKE_CHANNEL_DIGEST_LATER=$dig_x
mk ""
staged_after "$R" "$dig_x" "$ver_x"
t
want 0
is digest "$state/expected-deployment" "$dig_x"

reset downgrade
mk ""
staged_after "$R" "$dig_c" 20261001.xxxxxxx
t
want 0
has "microos-update: 20261001.xxxxxxx is older than the booted $ver_b"

reset not-pinned
pinned=false
mk ""
staged_after "$R" "$dig_c" "$ver_c"
t
want 0
has "booted deployment is not confirmed yet"
called bootc "^inhibit=1 upgrade\$"

reset s10
export FAKE_BOOTC_FAIL=1
mk ""
staged_after "$R" "$dig_c" "$ver_c"
t
want 1
has "fake bootc failure"
gone "$state/expected-deployment"
o_sig=""
mk ""
t
want 1
gone "$state/expected-deployment"

reset c4
o_sig=""
mk ""
t --check
want 0
is state "$run/update-available" switch
is image "$run/update-available" "$R"
is digest "$run/update-available" "$dig_c"
is version "$run/update-available" "$ver_c"
not_called bootc "upgrade"

reset c5
s_dig=$dig_c s_ver=$ver_c s_img=$R
mk ""
t --check
want 0
is state "$run/update-available" staged
is digest "$run/update-available" "$dig_c"
is version "$run/update-available" "$ver_c"

reset c6
export FAKE_CHANNEL_DIGEST=$dig_b
s_dig=$dig_x s_ver=$ver_x s_img=$R
mk ""
t --check
want 0
is state "$run/update-available" withdrawn
is digest "$run/update-available" "$dig_x"
not_called bootc "switch|upgrade"
not_called ostree undeploy

reset c7
export FAKE_CHANNEL_DIGEST=$dig_b
mk ""
stale
echo state=fetch > "$run/update-available"
t --check
want 7
gone "$run/update-available"
gone "$state/expected-deployment"
gone "$run/update-not-applied"

reset c8
mk ""
t --check
want 0
prio
called bootc "^inhibit=0 upgrade --check\$"
is state "$run/update-available" fetch
is digest "$run/update-available" "$dig_c"
is version "$run/update-available" "$ver_c"
[[ -z $(val missed "$run/update-available") ]] || fail "$name: missed set"
grep -q '^checked=' "$run/update-available" || fail "$name: no checked="
stale
t --check
want 0
is missed "$run/update-available" "$ver_x"

reset label-control
export FAKE_CHANNEL_VERSION=$'20261013.ccccccc\ndigest=sha256:evil\tx'
mk ""
t --check
want 0
is digest "$run/update-available" "$dig_c"
is version "$run/update-available" "20261013.cccccccdigest=sha256:evilx"
[[ $(grep -c '^digest=' "$run/update-available") == 1 ]] || fail "$name: injected a digest line"
staged_after "$R" "$dig_c" $'20261013.c\nimage=quay.io/evil'
t
want 0
[[ $(wc -l < "$state/expected-deployment") == 5 ]] || fail "$name: expected-deployment has injected lines"
is image "$state/expected-deployment" "$R"
if grep -q '^image=' <<< "$out"; then fail "$name: injected a log line"; fi

reset c9
export FAKE_CHECK_FAIL=1
mk ""
echo state=staged > "$run/update-available"
t --check
want 1
has "signature verification failed"
[[ $(cat "$run/update-available") == state=staged ]] || fail "$name: update-available changed"

reset discard
mk ""
stale
t --discard
want 0
gone "$state/expected-deployment"
gone "$run/update-not-applied"
s_dig=$dig_c s_ver=$ver_c s_img=$R
mk ""
stale
t --discard
want 1
there "$state/expected-deployment"
there "$run/update-not-applied"

pending_mk() {
  local img=$1 dig=$2 ver=$3
  jq --arg i "$img" --arg d "$dig" --arg v "$ver" --arg cs "$csum_s" '
    .status.staged = null | .status.rollbackQueued = true
    | .status.rollback = {image: {image: {image: $i, transport: "registry", signature: "containerPolicy"}, version: $v,
        imageDigest: $d}, pinned: false, ostree: {checksum: $cs, deploySerial: 0}}' "$fake/bootc.json" > "$fake/bootc.json.new"
  mv "$fake/bootc.json.new" "$fake/bootc.json"
  jq --arg cs "$csum_s" '.deployments = ([{checksum: $cs, serial: 0, stateroot: "default", staged: false, pending: true,
      booted: false, pinned: false}] + .deployments) | .deployments |= (to_entries | map(.value + {index: .key}))' \
    "$fake/ostree.json" > "$fake/ostree.json.new"
  mv "$fake/ostree.json.new" "$fake/ostree.json"
}
wrote() {
  called tool "^lock=free inhibit=1 written=$csum_s.0 --tree $pdir --deployment $csum_s.0\$"
  called run "^--unit=microos-bootb-write --wait --collect --quiet -p KillMode=mixed -p KillSignal=SIGCONT -p TimeoutStopSec=300 -p Nice=0 -p IOSchedulingClass=best-effort -p CPUSchedulingPolicy=other -p RequiresMountsFor=/boot /boot/efi /sysroot /var/lib/microos -p After=ostree-finalize-staged.service -p Environment=MICROOS_SLEEP_BLOCKED=1 systemd-inhibit --what=sleep:shutdown --mode=block"
  is written "$state/update-written" "$nid"
  is deploy "$state/update-written" "$csum_s.0"
  is digest "$state/update-written" "$1"
  is from "$state/update-written" "$csum_b.0"
  [[ $(val stamp "$state/update-written") =~ ^[0-9]+$ ]] || fail "$name: update-written stamp"
}
no_write() {
  [[ ! -e $fake/tool.calls ]] || fail "$name: microos-bootimg-update ran"
  gone "$state/update-written"
}

reset auto-not-confirmed
mk ""
rm "$run/boot-confirmed"
t --auto
want 3
has "$csum_b.0 is not confirmed yet"
not_called skopeo .
not_called bootc .
echo "$csum_s.0" > "$run/boot-confirmed"
t --auto
want 3
not_called skopeo .

reset auto-paused
mk ""
touch "$state/update-pause"
t --auto
want 3
has "paused, $state/update-pause exists"
is state "$run/update-available" paused
not_called skopeo .
rm "$state/update-pause"
for w in microos.test=1 microos.kround=p1c; do
  echo "root=PARTLABEL=microos microos.id=$rid $w" > "$tmp/cmdline"
  t --auto
  want 3
  has "paused, $w"
  not_called skopeo .
done
staged_after "$R" "$dig_c" "$ver_c"
t
want 0
called bootc "^inhibit=1 upgrade\$"

reset auto-lock
mk ""
exec 8> "$run/update.lock"
flock -n 8
t --auto
want 3
not_called skopeo .
exec 8>&-

reset auto-c4
o_image=$repo:dev-434434b o_sig=""
mk ""
t --auto
want 0
is state "$run/update-available" switch
not_called bootc "switch|upgrade"
no_write

reset auto-c7
export FAKE_CHANNEL_DIGEST=$dig_b
mk ""
t --auto
want 7
no_write

reset auto-fetch
mk ""
staged_after "$R" "$dig_c" "$ver_c"
t --auto
want 0
not_called bootc "upgrade --check"
called bootc "^inhibit=1 upgrade\$"
wrote "$dig_c"
is state "$run/update-available" staged
is digest "$run/update-available" "$dig_c"
has "staged $ver_c $dig_c, applies on the next reboot"

reset auto-fetch-no-space
export FAKE_FREE=$((1 << 30))
mk ""
t --auto
want 1
is state "$run/update-available" fetch
not_called bootc "upgrade"

reset pending-s6
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
for m in "" --auto; do
  t ${m:+"$m"}
  want 0
  not_called bootc "switch|upgrade"
  wrote "$dig_c"
  rm "$state/update-written"
  bootimg "$csum_b.0" "$rid"
done
t --check
want 0
is state "$run/update-available" staged

reset pending-after-switch
o_image=$repo:dev-434434b o_sig=""
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
t --auto
want 0
not_called bootc "switch|upgrade"
wrote "$dig_c"

reset w-waiting
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
bootimg "$csum_s.0" "$nid"
for m in "" --auto; do
  t ${m:+"$m"}
  want 0
  has "staged $ver_c $dig_c, applies on the next reboot"
  not_called bootc "switch|upgrade"
  no_write
done
is state "$run/update-available" staged

reset w-channel-moved
export FAKE_CHANNEL_DIGEST=$dig_x FAKE_CHANNEL_VERSION=$ver_x
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
bootimg "$csum_s.0" "$nid"
t --auto
want 0
has "nothing is staged before a reboot"
not_called bootc "switch|upgrade"
no_write
is state "$run/update-available" staged
is digest "$run/update-available" "$dig_c"
t
want 0
not_called bootc "switch|upgrade"

reset w-ram-boot
mk ""
staged_after "$R" "$dig_c" "$ver_c"
echo "root=PARTLABEL=microos microos.id=$nid" > "$tmp/cmdline"
for m in "" --auto; do
  t ${m:+"$m"}
  want 0
  has "boot_b holds $rid for $csum_b.0, the running image is $nid"
  not_called bootc "switch|upgrade"
  no_write
done
echo "root=PARTLABEL=microos" > "$tmp/cmdline"
t
want 0
has "the running image is unknown"
not_called bootc "switch|upgrade"

reset refused
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
echo "$dig_c" > "$state/update-failed"
t --auto
want 0
is state "$run/update-available" refused
no_write
t
want 0
wrote "$dig_c"

reset held
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
printf '%s\n' "$dig_x" "sha256:$(printf 4%.0s {1..64})" > "$state/update-failed"
t --auto
want 0
is state "$run/update-available" held
no_write
t
want 0
wrote "$dig_c"

reset attended
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
echo "new kernel" > "$pdir/usr/lib/modules/7.2.12-microos/vmlinuz"
t --auto
want 0
is state "$run/update-available" attended
has "changes usr/lib/modules/7.2.12-microos/vmlinuz"
no_write
t
want 0
wrote "$dig_c"
for f in usr/lib/microos/stub.conf usr/libexec/microos/microos-bootb usr/lib/systemd/systemd; do
  reset "attended $f"
  mk ""
  pending_mk "$R" "$dig_c" "$ver_c"
  mkdir -p "$pdir/${f%/*}"
  echo "new" > "$pdir/$f"
  t --auto
  want 0
  is state "$run/update-available" attended
  no_write
done
reset attended-initramfs-only
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
initrd "$pdir/usr/lib/modules/7.2.12-microos/initramfs.img" other
t --auto
want 0
wrote "$dig_c"

reset battery
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
echo 20 > "$power/battery/capacity"
for m in "" --auto; do
  t ${m:+"$m"}
  want 0
  has "battery 20%, boot_b is written on the next run"
  no_write
done
is state "$run/update-available" deferred
echo Charging > "$power/battery/status"
t --auto
want 0
wrote "$dig_c"
rm "$state/update-written"
bootimg "$csum_b.0" "$rid"
echo Discharging > "$power/battery/status"
echo 80 > "$power/battery/capacity"
mkdir -p "$power/pen"
printf 'Battery\n' > "$power/pen/type"
printf 'Device\n' > "$power/pen/scope"
printf '5\n' > "$power/pen/capacity"
t --auto
want 0
wrote "$dig_c"

reset tool-fails
export FAKE_TOOL_RC=1 FAKE_TOOL_WRITES=0
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
t --auto
want 1
has "fake tool failure"
has "boot_b holds $rid after microos-bootimg-update (exit 1)"
gone "$state/update-written"
called tool "written=$csum_s.0 "
export FAKE_TOOL_WRITES=1
t --auto
want 0
has "microos-bootimg-update exited 1, boot_b holds $nid for $csum_s.0"
is written "$state/update-written" "$nid"
unset FAKE_TOOL_RC FAKE_TOOL_WRITES

reset stamp
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
t --auto
want 0
is stamp "$state/update-written" 5000
reset stamp-staged
mk ""
staged_after "$R" "$dig_c" "$ver_c"
before=$(date +%s)
t --auto
want 0
(( $(val stamp "$state/update-written") >= before )) || fail "$name: stamp $(val stamp "$state/update-written") before $before"
called ostree "^admin lock-finalization\$"

reset record-malformed
mk ""
printf 'deploy=x\n' > "$state/update-written"
export FAKE_CHANNEL_DIGEST=$dig_b
t
want 7
has "names no deployment and digest, removed"
gone "$state/update-written"

reset record-in-flight
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
bootimg "$csum_s.0" "$nid"
printf 'deploy=%s.0\ndigest=%s\nversion=%s\nfrom=%s.0\nstamp=1\n' "$csum_s" "$dig_c" "$ver_c" "$csum_b" > "$state/update-written"
export FAKE_WRITE_ACTIVE=1
t --auto
want 0
there "$state/update-written"
[[ -z $(val written "$state/update-written") ]] || fail "$name: written= added while the write runs"
unset FAKE_WRITE_ACTIVE
t --auto
want 0
is written "$state/update-written" "$nid"
gone "$state/update-failed"

reset record-never-written
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
printf 'deploy=%s.0\ndigest=%s\nversion=%s\nfrom=%s.0\nstamp=1\n' "$csum_s" "$dig_c" "$ver_c" "$csum_b" > "$state/update-written"
export FAKE_TOOL_WRITES=0 FAKE_TOOL_RC=1
t --auto
want 1
gone "$state/update-written"
gone "$state/update-failed"
called tool .
unset FAKE_TOOL_WRITES FAKE_TOOL_RC

reset record-booted-unmarked
export FAKE_CHANNEL_DIGEST=$dig_b
mk ""
printf 'deploy=%s.0\ndigest=%s\nversion=%s\nfrom=%s.0\nstamp=1\n' "$csum_b" "$dig_b" "$ver_b" "$csum_s" > "$state/update-written"
t
want 7
is written "$state/update-written" "$rid"

reset write-running
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
export FAKE_WRITE_ACTIVE=1
t
want 3
has "a boot_b write is running"
no_write
unset FAKE_WRITE_ACTIVE

u=$(id -u)
reset drift-renumbered
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
mkdir -p "$rootfs/etc"
printf 'root:x:0:\npolkitd:x:9999:\n' > "$rootfs/etc/group"
printf 'root:x:0:\npolkitd:x:%s:\n' "$u" > "$pdir/usr/etc/group"
t --auto
want 0
is state "$run/update-available" attended
has "group polkitd ($u in the update, 9999 here, owns files in /usr)"
no_write
printf 'root:x:0:\npolkitd:x:%s:\n' "$u" > "$rootfs/etc/group"
t --auto
want 0
wrote "$dig_c"
reset drift-taken
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
mkdir -p "$rootfs/etc"
printf 'root:x:0:\nother:x:%s:\n' "$u" > "$rootfs/etc/group"
printf 'newgrp:x:%s:\n' "$u" > "$pdir/usr/lib/group"
t --auto
want 0
is state "$run/update-available" attended
has "group newgrp ($u in the update, held by another name here"
no_write
reset drift-not-owned
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
mkdir -p "$rootfs/etc"
printf 'root:x:0:\nrtkit:x:973:\n' > "$rootfs/etc/group"
printf 'rtkit:x:975:\n' > "$pdir/usr/etc/group"
t --auto
want 0
wrote "$dig_c"

reset pending-switch-moved
o_image=$repo:dev-434434b o_sig=""
export FAKE_CHANNEL_DIGEST=$dig_x FAKE_CHANNEL_VERSION=$ver_x
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
staged_after "$R" "$dig_x" "$ver_x"
t
want 0
called bootc "^inhibit=1 switch --enforce-container-sigpolicy $R\$"
not_called bootc "^inhibit=1 upgrade"

reset declined-before-pull
mk ""
echo "$dig_c" > "$state/update-failed"
t --auto
want 0
is state "$run/update-available" refused
not_called bootc "upgrade"
printf '%s\n' "$dig_x" "sha256:$(printf 4%.0s {1..64})" > "$state/update-failed"
t --auto
want 0
is state "$run/update-available" held
not_called bootc "upgrade"
staged_after "$R" "$dig_c" "$ver_c"
t
want 0
called bootc "^inhibit=1 upgrade\$"

reset pause-stale
mk ""
staged_after "$R" "$dig_c" "$ver_c"
touch -d '2 days ago' "$state/update-pause"
t --auto
want 0
has "is older than a day, not paused"
called bootc "^inhibit=1 upgrade\$"

reset attended-initrd
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
echo "new libc" > "$pdir/usr/lib64/libc.so.6"
t --auto
want 0
is state "$run/update-available" attended
has "changes usr/lib64/libc.so.6"
no_write
reset attended-initrd-etc
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
echo "new" > "$pdir/usr/etc/udev.conf"
t --auto
want 0
has "changes usr/etc/udev.conf"
no_write
reset attended-udevd-link
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
echo "new udevadm" > "$pdir/usr/bin/udevadm"
t --auto
want 0
has "changes usr/lib/systemd/systemd-udevd"
no_write
reset initrd-unreadable
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
echo "not zstd" > "$pdir/usr/lib/modules/7.2.12-microos/initramfs.img"
t --auto
want 1
has "cannot list $pdir/usr/lib/modules/7.2.12-microos/initramfs.img"
no_write

reset written-booted
export FAKE_CHANNEL_DIGEST=$dig_b
mk ""
printf 'deploy=%s.0\ndigest=%s\nversion=%s\nfrom=%s.0\nstamp=1\nwritten=%s\n' "$csum_b" "$dig_b" "$ver_b" "$csum_s" "$rid" \
  > "$state/update-written"
echo "$dig_x" > "$state/update-failed"
rm "$run/boot-confirmed"
t
want 7
there "$state/update-failed"
echo "$csum_b.0" > "$run/boot-confirmed"
t
want 7
there "$state/update-written"
gone "$state/update-failed"

reset written-restored
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
printf 'deploy=%s.0\ndigest=%s\nversion=%s\nfrom=%s.0\nstamp=1\nwritten=%s\n' "$csum_s" "$dig_c" "$ver_c" "$csum_b" "$nid" \
  > "$state/update-written"
t --auto
want 0
has "$ver_c ($dig_c) was written to boot_b as $nid and $rid runs again"
[[ $(cat "$state/update-failed") == "$dig_c" ]] || fail "$name: update-failed $(cat "$state/update-failed")"
gone "$state/update-written"
is state "$run/update-available" refused
no_write

reset written-waiting
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
bootimg "$csum_s.0" "$nid"
printf 'deploy=%s.0\ndigest=%s\nversion=%s\nfrom=%s.0\nstamp=1\nwritten=%s\n' "$csum_s" "$dig_c" "$ver_c" "$csum_b" "$nid" \
  > "$state/update-written"
t --auto
want 0
there "$state/update-written"
gone "$state/update-failed"

reset channel-branch
echo branch-y700-ota-auto > "$state/update-channel"
mk ""
t --check
want 0
called skopeo "docker://$repo:branch-y700-ota-auto\$"
for c in branch-a/b "branch-$(printf x%.0s {1..122})" branch- branch-.x; do
  echo "$c" > "$state/update-channel"
  t --check
  want 1
  has "not testing, stable or branch-<name>"
done
echo "branch-$(printf x%.0s {1..121})" > "$state/update-channel"
t --check
want 0

reset s7-pending
export FAKE_CHANNEL_DIGEST=$dig_b
mk ""
pending_mk "$R" "$dig_x" "$ver_x"
t
want 7
called ostree "^admin undeploy 0\$"

reset discard-pending
mk ""
pending_mk "$R" "$dig_c" "$ver_c"
t --discard
want 1
has "a staged deployment exists ($csum_s.0)"

if grep -q rollback "$tmp/bootc.all"; then fail "a bootc rollback ran"; fi
if grep -E ' (switch|upgrade)( |$)' "$tmp/bootc.all" | grep -v -- '--check' | grep -v '^inhibit=1 '; then
  fail "bootc switch or upgrade outside the inhibitor"
fi
if grep -- 'upgrade --check' "$tmp/bootc.all" | grep -v '^inhibit=0 '; then
  fail "bootc upgrade --check under the inhibitor"
fi
grep -q '^inhibit=1 switch' "$tmp/bootc.all" || fail "no bootc switch recorded"
grep -q '^inhibit=1 upgrade$' "$tmp/bootc.all" || fail "no bootc upgrade recorded"

if (( rc == 0 )); then
  echo "update: all cases passed"
fi
exit "$rc"
