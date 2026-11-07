#!/usr/bin/env bash
set -euo pipefail

work=${1:?usage: fetch.sh <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

fetch() {
  curl -fsSL --retry 3 -o "$work/$3" "$1"
  echo "$2  $work/$3" | sha256sum -c -
}
fetch "$HYPR_STACK_REPO/hyprutils/archive/$HYPRUTILS_COMMIT.tar.gz" "$HYPRUTILS_SHA256" "hyprutils-$HYPRUTILS_COMMIT.tar.gz"
fetch "$HYPR_STACK_REPO/hyprlang/archive/$HYPRLANG_COMMIT.tar.gz" "$HYPRLANG_SHA256" "hyprlang-$HYPRLANG_COMMIT.tar.gz"
fetch "$HYPR_STACK_REPO/hyprgraphics/archive/$HYPRGRAPHICS_COMMIT.tar.gz" "$HYPRGRAPHICS_SHA256" "hyprgraphics-$HYPRGRAPHICS_COMMIT.tar.gz"
fetch "$HYPR_STACK_REPO/hyprwire/archive/$HYPRWIRE_COMMIT.tar.gz" "$HYPRWIRE_SHA256" "hyprwire-$HYPRWIRE_COMMIT.tar.gz"
fetch "$HYPR_STACK_REPO/hyprland-protocols/archive/$HYPRPROTOCOLS_COMMIT.tar.gz" "$HYPRPROTOCOLS_SHA256" "hyprland-protocols-$HYPRPROTOCOLS_COMMIT.tar.gz"
fetch "$HYPR_STACK_REPO/aquamarine/archive/$AQUAMARINE_COMMIT.tar.gz" "$AQUAMARINE_SHA256" "aquamarine-$AQUAMARINE_COMMIT.tar.gz"
fetch "$HYPR_STACK_REPO/hyprcursor/archive/$HYPRCURSOR_COMMIT.tar.gz" "$HYPRCURSOR_SHA256" "hyprcursor-$HYPRCURSOR_COMMIT.tar.gz"
fetch "$HYPRLAND_URL" "$HYPRLAND_SHA256" "source-v$HYPRLAND_VERSION.tar.gz"
fetch "https://github.com/stephenberry/glaze/archive/$GLAZE_COMMIT.tar.gz" "$GLAZE_SHA256" "glaze-$GLAZE_COMMIT.tar.gz"
fetch "$HYPR_STACK_REPO/hyprwayland-scanner/archive/$HYPRWSCANNER_COMMIT.tar.gz" "$HYPRWSCANNER_SHA256" "hyprwayland-scanner-$HYPRWSCANNER_COMMIT.tar.gz"
