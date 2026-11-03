#!/usr/bin/env bash
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"
. "$src/extent.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

printf 'order\tversion\tsoc\tlength\tsha256\n'
order=0
for tag in $(curl -fsSL --retry 3 "$ABL_RELEASES" | sed -n 's,.*<title>\(v[0-9][^<]*\)</title>.*,\1,p' | sort -V); do
  dir=$work/$tag
  mkdir -p "$dir"
  if ! curl -fsSL --retry 3 -o "$dir/rocknix-abl-$tag.tar.gz" \
      "$ABL_REPO_URL/releases/download/$tag/rocknix-abl-$tag.tar.gz" 2> "$dir/curl.err"; then
    printf 'catalog: skipping %s: %s\n' "$tag" "$(tail -n 1 "$dir/curl.err")" >&2
    rm -rf "$dir"
    continue
  fi
  if ! tar -xzf "$dir/rocknix-abl-$tag.tar.gz" -C "$dir" --strip-components=1 --no-same-owner \
      "rocknix-abl-$tag/abl_signed-SM8250.elf" 2> "$dir/tar.err"; then
    printf 'catalog: skipping %s: %s\n' "$tag" "$(tail -n 1 "$dir/tar.err")" >&2
    rm -rf "$dir"
    continue
  fi
  length=$(extent "$dir/abl_signed-SM8250.elf")
  order=$((order + 1))
  printf '%s\t%s\tSM8250\t%s\t%s\n' "$order" "${tag#v}" "$length" \
    "$(head -c "$length" "$dir/abl_signed-SM8250.elf" | sha256sum | cut -d' ' -f1)"
  rm -rf "$dir"
done
