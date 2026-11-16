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
mkdir -p "$tmp/home"

repo=ghcr.io/seilent/microos
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
      deployments: ((if $sd == "" then [] else [{checksum: $cs, serial: 0, staged: true, booted: false, pinned: false}] end)
        + [{checksum: $cb, serial: 0, staged: false, booted: true, pinned: $p}])
        | to_entries | map(.value + {index: .key})
    }' > "$fake/ostree$1.json"
}

reset() {
  name=$1
  rm -rf "$fake" "$state" "$run"
  mkdir -p "$fake" "$state" "$run"
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
    "$fake/ostree.reads" "$fake/skopeo.reads"
  out=$(cd "$tmp" && env "${homeenv[@]}" PATH="$bin:$PATH" FAKE_DIR="$fake" MICROOS_RUNDIR="$run" \
    MICROOS_STATEDIR="$state" MICROOS_SYSROOT="$tmp" MICROOS_ETC_POLICY="$etcpol" "$tool" "$@" 2>&1) && code=0 || code=$?
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
jq 'del(.transports.docker["ghcr.io/seilent/microos"])' "$policy" > "$tmp/noscope.json"
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
jq --arg k "$repo:testing" '.transports.docker[$k] = .transports.docker["ghcr.io/seilent/microos"]' "$policy" > "$tmp/override.json"
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
