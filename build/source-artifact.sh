#!/usr/bin/env bash
set -euo pipefail

fedora=registry.fedoraproject.org/fedora:44@sha256:1ff9eb02e4e2d7fb1175becac7139b2960c4fdcccedce81c86ec25b98ef3124d
koji=https://kojipkgs.fedoraproject.org/packages
key=6d9f90a6
repo=https://github.com/seilent/MicroOS

fail() { echo "source-artifact: $*" >&2; exit 1; }

(( $# == 3 )) || { echo "usage: source-artifact.sh <srpms.tsv> <outdir> <full|base>" >&2; exit 2; }
tsv=$1
out=$2
mode=$3
[[ $mode == full || $mode == base ]] || fail "mode is $mode, not full or base"
[[ -s $tsv ]] || fail "$tsv is empty"

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/packages/kernel/SOURCE.env"

mkdir -p "$out"
out=$(cd "$out" && pwd)
[[ -z $(ls -A "$out") ]] || fail "$out is not empty"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

while IFS=$'\t' read -r name srpm vendor; do
  [[ $vendor == MicroOS ]] || continue
  case $name in
    microos-kernel) ;;
    *) fail "no source rule for the MicroOS package $name ($srpm)" ;;
  esac
done < "$tsv"

sha=$(git -C "$root" rev-parse HEAD)
short=${sha::7}
git -C "$root" archive --format=tar.gz --prefix=microos/ -o "$out/microos-$short.tar.gz" HEAD
printf '%s %s\n' "microos-$short.tar.gz" "$repo/tree/$sha" > "$tmp/origins"

kernel=linux-$KERNEL_VERSION.tar.xz
curl -fsSL --retry 5 --retry-all-errors -o "$out/$kernel" "$KERNEL_URL"
[[ $(sha256sum < "$out/$kernel" | cut -d' ' -f1) == "$KERNEL_SHA256" ]] || fail "$kernel sha256 mismatch"
printf '%s %s\n' "$kernel" "$KERNEL_URL" >> "$tmp/origins"

if [[ $mode == full ]]; then
  awk -F'\t' '$3 != "MicroOS" && $2 != "(none)" { print $2 }' "$tsv" | sort -u > "$tmp/srpms"
  [[ -s $tmp/srpms ]] || fail "no source rpms in $tsv"
  nevra='^([A-Za-z0-9][A-Za-z0-9._+~^-]*)-([A-Za-z0-9._+~^]+)-([A-Za-z0-9._+~^]+)\.src\.rpm$'
  get=()
  while read -r f; do
    [[ $f =~ $nevra && $f != *..* ]] || fail "bad source rpm name $f"
    url=$koji/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}/data/signed/$key/src/$f
    get+=(-o "$out/$f" "$url")
    printf '%s %s\n' "$f" "$url" >> "$tmp/origins"
  done < "$tmp/srpms"
  curl -fsSLg --retry 5 --retry-all-errors --parallel --parallel-max 8 "${get[@]}" || fail "source rpm download failed"
  while read -r f; do
    [[ -s $out/$f ]] || fail "$f missing"
  done < "$tmp/srpms"
  podman run --rm -v "$out:/src:ro" "$fedora" sh -c 'cd /src && rpm -K -- *.src.rpm' > "$tmp/rpmk" \
    || { grep -v ': digests signatures OK$' "$tmp/rpmk" >&2; fail "rpm -K failed"; }
  [[ $(grep -c ': digests signatures OK$' "$tmp/rpmk") == "$(wc -l < "$tmp/srpms")" ]] || fail "rpm -K did not pass every source rpm"
fi

sort "$tmp/origins" | while read -r f url; do
  printf '%s %s %s\n' "$f" "$(sha256sum < "$out/$f" | cut -d' ' -f1)" "$url"
done > "$tmp/SOURCES"
[[ $(find "$out" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort) == "$(cut -d' ' -f1 "$tmp/SOURCES")" ]] || fail "files in $out differ from SOURCES"
mv "$tmp/SOURCES" "$out/SOURCES"

echo "source-artifact: $mode, $(wc -l < "$out/SOURCES") files, $(du -sb "$out" | cut -f1) bytes"
