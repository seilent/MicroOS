#!/usr/bin/env bash
set -euo pipefail

work=${1:?usage: fetch.sh <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

fetch() {
  curl -fsSL --retry 3 -o "$work/$3" "$1"
  echo "$2  $work/$3" | sha256sum -c -
}
fetch "$WVKBD_URL/archive/$WVKBD_COMMIT.tar.gz" "$WVKBD_SHA256" "wvkbd-$WVKBD_COMMIT.tar.gz"
fetch "$WVKBD_LICENSE_URL" "$WVKBD_LICENSE_SHA256" "LICENSE"
fetch "$WVKBD_COPYING_URL" "$WVKBD_COPYING_SHA256" "COPYING"
fetch "$WVKBD_WESTON_URL" "$WVKBD_WESTON_SHA256" "COPYING_WESTON"
