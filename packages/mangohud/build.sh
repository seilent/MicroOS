#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"

version=$(rpmspec -q --srpm --qf '%{VERSION}' --define "commit $MANGOHUD_REF" "$src/mangohud.spec")
[[ $version == "$MANGOHUD_VERSION" ]] || { echo "build.sh: spec Version $version, SOURCE.env $MANGOHUD_VERSION" >&2; exit 1; }

fetch() {
  local file=$top/SOURCES/$1 url=$2 sha256=$3
  curl -fsSL --retry 3 -o "$file" "$url"
  echo "$sha256  $file" | sha256sum -c -
}
fetch "mangohud-$MANGOHUD_REF.tar.gz" "$MANGOHUD_URL/archive/$MANGOHUD_REF.tar.gz" "$MANGOHUD_SHA256"
fetch "$IMGUI_FILE" "$IMGUI_URL" "$IMGUI_SHA256"
fetch "$VULKAN_HEADERS_FILE" "$VULKAN_HEADERS_URL" "$VULKAN_HEADERS_SHA256"
fetch "$VULKAN_UTILITY_LIBRARIES_FILE" "$VULKAN_UTILITY_LIBRARIES_URL" "$VULKAN_UTILITY_LIBRARIES_SHA256"
fetch "$IMPLOT_FILE" "$IMPLOT_URL" "$IMPLOT_SHA256"
fetch "$IMPLOT_PATCH_FILE" "$IMPLOT_PATCH_URL" "$IMPLOT_PATCH_SHA256"
cp "$src"/patches/*.patch "$top/SOURCES/"

rpmbuild -ba --define "_topdir $top" --define "commit $MANGOHUD_REF" "$src/mangohud.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$src/PATCHES.md" "$out/"
