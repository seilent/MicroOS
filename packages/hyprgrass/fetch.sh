#!/usr/bin/env bash
set -euo pipefail

work=${1:?usage: fetch.sh <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

fetch() {
  curl -fsSL --retry 3 -o "$work/$3" "$1"
  echo "$2  $work/$3" | sha256sum -c -
}
fetch "$HYPRGRASS_REPO/archive/$HYPRGRASS_COMMIT.tar.gz" "$HYPRGRASS_SHA256" "hyprgrass-$HYPRGRASS_COMMIT.tar.gz"
fetch "$WFTOUCH_REPO/archive/$WFTOUCH_COMMIT.tar.gz" "$WFTOUCH_SHA256" "wf-touch-$WFTOUCH_COMMIT.tar.gz"
fetch "https://raw.githubusercontent.com/horriblename/hyprgrass/$HYPRGRASS_PINS_REF/hyprpm.toml" "$HYPRGRASS_PINS_SHA256" "hyprpm.toml"
