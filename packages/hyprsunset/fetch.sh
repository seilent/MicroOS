#!/usr/bin/env bash
set -euo pipefail

work=${1:?usage: fetch.sh <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

fetch() {
  curl -fsSL --retry 3 -o "$work/$3" "$1"
  echo "$2  $work/$3" | sha256sum -c -
}
fetch "$HYPRSUNSET_REPO/archive/$HYPRSUNSET_COMMIT.tar.gz" "$HYPRSUNSET_SHA256" "hyprsunset-$HYPRSUNSET_COMMIT.tar.gz"
