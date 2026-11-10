#!/usr/bin/env bash
set -euo pipefail

work=${1:?usage: fetch.sh <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

mkdir -p "$work"

tarball=$work/rocknix-abl-v$ABL_VERSION.tar.gz
curl -fsSL --retry 3 -o "$tarball" "$ABL_URL"
echo "$ABL_SHA256  $tarball" | sha256sum -c --quiet -

tree=$work/abl
rm -rf "$tree"
git clone -q "$ABL_REPO_URL" "$tree"
[[ $(git -C "$tree" rev-parse "refs/tags/v$ABL_VERSION^{commit}") == "$ABL_REPO_COMMIT" ]] \
  || { echo "fetch.sh: tag v$ABL_VERSION is not $ABL_REPO_COMMIT" >&2; exit 1; }
git -C "$tree" checkout -q "$ABL_REPO_COMMIT"
[[ $(git -C "$tree" rev-parse HEAD) == "$ABL_REPO_COMMIT" ]] \
  || { echo "fetch.sh: HEAD is not $ABL_REPO_COMMIT" >&2; exit 1; }
rm -rf "$tree/.git"
