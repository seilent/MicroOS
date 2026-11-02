#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)

top=$(mktemp -d)
chmod 755 "$top"
trap 'rm -rf "${top:?}"' EXIT
mkdir -p "$top/SOURCES" "$top/assets"

tar -C "$src/data" --owner=0 --group=0 --mode=go-w --transform 's,^\.,microos-android-data,' \
  -czf "$top/SOURCES/microos-android-data.tar.gz" .
tar -C "$src/restrictions-stub" --owner=0 --group=0 --mode=go-w --transform 's,^\.,microos-android-stub,' \
  -czf "$top/SOURCES/microos-android-stub.tar.gz" .
cp "$src/build/stub.sh" "$top/SOURCES/"

MICROOS_STUB_CACHE=$top/stub-cache "$src/build/stub.sh" "$top/stub-cache" "$top/assets" "$src/restrictions-stub" > /dev/null
tar -C "$top/assets" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
  -czf "$top/SOURCES/microos-android-assets.tar.gz" usr

for t in "$top"/SOURCES/microos-android-*.tar.gz; do
  list=$(tar -tzf "$t")
  sdk=$(grep -E '(^|/)(android\.jar|platform-[^/]*\.zip|r8-[^/]*\.jar)$' <<<"$list" || true)
  if [[ -n $sdk ]]; then
    echo "build.sh: ${t##*/} holds an Android SDK file: $sdk" >&2
    exit 1
  fi
done

rpmbuild -ba \
  --define "_topdir $top" \
  "$src/microos-android.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
