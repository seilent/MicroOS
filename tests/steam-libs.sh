#!/usr/bin/env bash
set -euo pipefail

seed=${1:-/usr/share/microos-seed/steam-seed.tar.zst}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
zstd -dcq "$seed" | tar -x -C "$tmp"
steam=$tmp/.local/share/Steam
export LD_LIBRARY_PATH=$steam/steamrtarm64:$steam/lib/aarch64-linux-gnu
valve_only="libavcodec.so.61 libavutil.so.59 libbz2.so.1.0"

aarch64_elf() {
  [[ $(od -An -tx1 -N20 "$1" 2>/dev/null | tr -d ' \n') == 7f454c46020101*b700 ]]
}

dirs=("$steam/steamrtarm64" "$steam/linuxarm64" "$steam/steam-runtime-steamrt-arm64/pressure-vessel")
for d in "${dirs[@]}"; do
  [[ -d $d ]] || { echo "FAIL: ${d#"$steam"/} missing" >&2; exit 1; }
done

elves=0
: > "$tmp/missing"
while IFS= read -r -d '' f; do
  aarch64_elf "$f" || continue
  [[ $f != */pressure-vessel/* || ${f##*/} != *.so* ]] || continue
  elves=$((elves + 1))
  ldd "$f" 2>/dev/null | awk -v f="${f#"$steam"/}" -v skip=" $valve_only " \
    '/not found/ && index(skip, " " $1 " ") == 0 {print $1 "\t" f}' >> "$tmp/missing" || true
done < <(find "${dirs[@]}" -type f -print0)

echo "steam-libs: $elves arm64 ELF files"
(( elves > 0 )) || { echo "FAIL: no arm64 ELF files scanned" >&2; exit 1; }
if [[ -s $tmp/missing ]]; then
  sort -u "$tmp/missing" | awk -F'\t' '{n[$1] = n[$1] " " $2} END {for (l in n) print "FAIL: " l " not found, needed by" n[l]}' | sort >&2
  exit 1
fi
