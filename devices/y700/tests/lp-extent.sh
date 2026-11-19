#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
lpx=$tree/usr/libexec/microos/microos-lp-extent
mk=$here/lp-extent/mksuper
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

[[ -x $lpx ]] || fail "microos-lp-extent is not executable"
command -v python3 > /dev/null || { echo "FAIL: python3 missing" >&2; exit 1; }

img=$tmp/super.img
parts=(system_a=2048+4194304 vendor_a=17979392+2943840 system_b=4196352+4194304 vendor_b=20923232+2943840)
slot1=(--slot=1 system_a=2048+4194304 vendor_a=17979392+2943840 system_b=4196352+4194304 vendor_b=21000000+2943840)

good() {
  local name=$1 part=$2 want=$3 out
  shift 3
  python3 "$mk" "$img" "$@"
  out=$("$lpx" "$img" "$part" 2> "$tmp/err") || { fail "$name: exit $?: $(cat "$tmp/err")"; return; }
  [[ $out == "$want" ]] || fail "$name: printed '$out', want '$want'"
  [[ ! -s $tmp/err ]] || fail "$name: stderr $(cat "$tmp/err")"
}
bad() {
  local name=$1 part=$2 want=$3 r=0
  shift 3
  python3 "$mk" "$img" "$@"
  "$lpx" "$img" "$part" > "$tmp/out" 2> "$tmp/err" || r=$?
  (( r != 0 )) || fail "$name: exit 0"
  [[ ! -s $tmp/out ]] || fail "$name: printed $(cat "$tmp/out")"
  [[ $(< "$tmp/err") == "microos-lp-extent: $want" ]] || fail "$name: stderr '$(cat "$tmp/err")', want '$want'"
}

good "vendor_a, version 10.2" vendor_a "17979392 2943840" "${parts[@]}"
good "vendor_b, version 10.2" vendor_b "20923232 2943840" "${parts[@]}"
good "vendor_a, version 10.0" vendor_a "17979392 2943840" --minor=0 "${parts[@]}"
good "vendor_a, version 10.1" vendor_a "17979392 2943840" --minor=1 "${parts[@]}"
good "prefix name" vendor "4096 8" vendor=4096+8 vendor_a=8192+8
good "vendor_b from slot 1" vendor_b "21000000 2943840" "${parts[@]}" "${slot1[@]}"
good "vendor_a from slot 0 when slot 1 differs" vendor_a "17979392 2943840" "${parts[@]}" --slot=1 vendor_a=4096+8
good "no suffix reads slot 0" vendor "4096 8" vendor=4096+8 --slot=1 vendor=8192+8
good "two slots" vendor_b "20923232 2943840" --slot-count=2 "${parts[@]}"

bad "geometry magic" vendor_a "bad geometry magic 0x616c4466" --corrupt=geometry-magic "${parts[@]}"
bad "geometry checksum" vendor_a "bad geometry checksum" --corrupt=geometry-sum "${parts[@]}"
bad "header magic" vendor_a "bad metadata magic 0x414c5031" --corrupt=header-magic "${parts[@]}"
bad "header checksum" vendor_a "bad metadata header checksum" --corrupt=header-sum "${parts[@]}"
bad "tables checksum" vendor_a "bad metadata tables checksum" --corrupt=tables-sum "${parts[@]}"
bad "major version" vendor_a "metadata version 11.2" --major=11 "${parts[@]}"
bad "minor version" vendor_a "metadata version 10.3" --minor=3 "${parts[@]}"
bad "missing name" vendor_a "no vendor_a in the metadata" system_a=2048+4194304 vendor_b=20923232+2943840
bad "name prefix only" vendor_a "no vendor_a in the metadata" vendor=4096+8
bad "vendor_b in slot 0 only" vendor_b "no vendor_b in the metadata" "${parts[@]}" --slot=1 vendor_a=17979392+2943840
bad "slot 1 past the slot count" vendor_b "vendor_b needs metadata slot 1, the geometry has 1" --slot-count=1 "${parts[@]}"
bad "slot 1 tables checksum" vendor_b "bad metadata tables checksum" --corrupt=tables-sum "${parts[@]}"
bad "metadata over 1 MiB" vendor_a "metadata size 1049088 over 1048576" --max-size=1049088 "${parts[@]}"
bad "before the first logical sector" vendor_a "vendor_a extent starts at sector 100, before the first logical sector 2048" \
  vendor_a=100+8
bad "two extents" vendor_a "vendor_a has 2 extents" vendor_a=17979392+1000000,19000000+1943840
bad "no extents" vendor_a "vendor_a has 0 extents" "vendor_a=" system_a=2048+8
bad "zero target" vendor_a "vendor_a extent is of target type 1, not linear" vendor_a=zero+2943840
bad "second block device" vendor_a "vendor_a extent is on block device 1, not 0" vendor_a=2048+8@1
bad "past the device" vendor_a "vendor_a extent 33554430+4 is outside the 17179869184 byte super" vendor_a=33554430+4
bad "file shorter than the device" vendor_b "vendor_b extent 20923232+2943840 is outside the 10737418240 byte super" \
  --truncate=10737418240 "${parts[@]}"
bad "short geometry" vendor_a "short read of the geometry" --truncate=4100 "${parts[@]}"
bad "short header" vendor_a "short read of the metadata header" --truncate=12300 "${parts[@]}"
bad "short expanded header" vendor_a "short read of the metadata header" --truncate=12500 "${parts[@]}"
bad "short tables" vendor_a "short read of the metadata tables" --truncate=12600 "${parts[@]}"

r=0
"$lpx" "$tmp/none" vendor_a > "$tmp/out" 2> "$tmp/err" || r=$?
(( r != 0 )) && [[ ! -s $tmp/out && $(wc -l < "$tmp/err") == 1 && $(< "$tmp/err") == "microos-lp-extent: "* ]] ||
  fail "missing image: exit $r, stderr $(cat "$tmp/err")"
r=0
"$lpx" "$img" > /dev/null 2>&1 || r=$?
(( r == 2 )) || fail "no partition name: exit $r"

if command -v lpmake > /dev/null; then
  head -c 1048576 /dev/urandom > "$tmp/v.img"
  lpmake --metadata-size 65536 --super-name super --metadata-slots 3 --device super:16777216 \
    --group main_a:12582912 --group main_b:0 --partition system_a:readonly:4194304:main_a \
    --partition vendor_a:readonly:1048576:main_a --image vendor_a="$tmp/v.img" --partition vendor_b:readonly:0:main_b \
    --sparse=false --output "$tmp/lp.img" > "$tmp/lpmake" 2>&1 || fail "lpmake: $(cat "$tmp/lpmake")"
  out=$("$lpx" "$tmp/lp.img" vendor_a 2>&1) || fail "lpmake image: $out"
  read -r first count <<< "$out"
  [[ $count == 2048 ]] || fail "lpmake image: vendor_a is '$out', want 2048 sectors"
  cmp -s -n 1048576 -i "$(( first * 512 )):0" "$tmp/lp.img" "$tmp/v.img" || fail "lpmake image: vendor_a extent does not hold its image"
  out=$("$lpx" "$tmp/lp.img" vendor_b 2>&1) && fail "lpmake image: empty vendor_b printed $out"
  [[ $out == "microos-lp-extent: vendor_b has 0 extents" ]] || fail "lpmake image: vendor_b: $out"
else
  fail "lpmake missing, no check against an AOSP written super image"
fi

if (( rc == 0 )); then
  echo "lp-extent: ok"
fi
exit "$rc"
