#!/usr/bin/env bash
set -euo pipefail

work=${1:?usage: fetch.sh <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

fetch() {
  curl -fsSL --retry 3 -o "$work/$3" "$1"
  echo "$2  $work/$3" | sha256sum -c -
}
fetch "$MESA_URL" "$MESA_SHA256" "mesa-$MESA_VERSION.tar.xz"
fetch "$LIBDRM_URL" "$LIBDRM_SHA256" "libdrm-$LIBDRM_VERSION.tar.xz"
fetch "$FOSSILIZE_URL/archive/$FOSSILIZE_REF.tar.gz" "$FOSSILIZE_SHA256" "Fossilize-$FOSSILIZE_REF.tar.gz"
fetch "$RAPIDJSON_URL/archive/$RAPIDJSON_REF.tar.gz" "$RAPIDJSON_SHA256" "rapidjson-$RAPIDJSON_REF.tar.gz"
fetch "$ANGLE_LICENSE_URL" "$ANGLE_LICENSE_SHA256" "angle-$ANGLE_REF-LICENSE"
