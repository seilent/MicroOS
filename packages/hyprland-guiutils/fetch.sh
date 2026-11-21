#!/usr/bin/env bash
set -euo pipefail

work=${1:?usage: fetch.sh <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

fetch() {
  curl -fsSL --retry 3 -o "$work/$3" "$1"
  echo "$2  $work/$3" | sha256sum -c -
}
fetch "$HYPRTOOLKIT_REPO/archive/$HYPRTOOLKIT_COMMIT.tar.gz" "$HYPRTOOLKIT_SHA256" "hyprtoolkit-$HYPRTOOLKIT_COMMIT.tar.gz"
fetch "$GUIUTILS_REPO/archive/$GUIUTILS_COMMIT.tar.gz" "$GUIUTILS_SHA256" "hyprland-guiutils-$GUIUTILS_COMMIT.tar.gz"
fetch "$HYPRWSCANNER_REPO/archive/$HYPRWSCANNER_COMMIT.tar.gz" "$HYPRWSCANNER_SHA256" "hyprwayland-scanner-$HYPRWSCANNER_COMMIT.tar.gz"
