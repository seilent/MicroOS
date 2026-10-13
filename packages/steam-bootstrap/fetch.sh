#!/usr/bin/env bash
set -euo pipefail

work=${1:?usage: fetch.sh <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

vdf=$src/manifests/$STEAM_MANIFEST.$STEAM_CLIENT_VERSION.vdf
echo "$STEAM_MANIFEST_SHA256  $vdf" | sha256sum -c -
mkdir -p "$work/feed"
cp "$vdf" "$work/feed/$STEAM_MANIFEST"

fetch() {
  curl -fsSL --retry 3 -o "$2" "$1"
  echo "$3  $2" | sha256sum -c --quiet -
}

bins=
while IFS=$'\t' read -r name file _ sha2 zipvz sha2vz; do
  if [[ -n $zipvz ]]; then
    fetch "$STEAM_CDN/$zipvz" "$work/feed/$zipvz" "$sha2vz"
  else
    fetch "$STEAM_CDN/$file" "$work/feed/$file" "$sha2"
  fi
  if [[ $name == bins_linuxarm64_linuxarm64 ]]; then
    bins=$work/bins.zip
    fetch "$STEAM_CDN/$file" "$bins" "$sha2"
  fi
done < <(python3 "$src/manifest.py" packages "$vdf" "$STEAM_CLIENT_VERSION")
[[ -n $bins ]] || { echo "fetch.sh: no bins_linuxarm64_linuxarm64 in the manifest" >&2; exit 1; }
fetch "$STEAM_RUNTIME_URL" "$work/runtime.tar.xz" "$STEAM_RUNTIME_SHA256"
