#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir> <workdir>}
work=${2:?usage: build.sh <outdir> <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

[[ $(uname -m) == aarch64 ]] || { echo "build.sh: the Steam seed builds on aarch64" >&2; exit 1; }

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
home=$top/home
steam=$home/.local/share/Steam
mkdir -p "$steam/package" "$home/.steam" "$top/SOURCES"

vdf=$src/manifests/$STEAM_MANIFEST.$STEAM_CLIENT_VERSION.vdf
echo "$STEAM_MANIFEST_SHA256  $vdf" | sha256sum -c -
cp "$vdf" "$steam/package/$STEAM_MANIFEST.manifest"

ln -s ../.local/share/Steam "$home/.steam/steam"
ln -s ../.local/share/Steam "$home/.steam/root"
ln -s ../.local/share/Steam/linux32 "$home/.steam/sdk32"
ln -s ../.local/share/Steam/linux64 "$home/.steam/sdk64"
ln -s ../.local/share/Steam/linuxarm64 "$home/.steam/sdkarm64"
ln -s ../.local/share/Steam/ubuntu12_32 "$home/.steam/bin32"
ln -s ../.local/share/Steam/ubuntu12_64 "$home/.steam/bin64"

unzip -q "$work/bins.zip" -d "$steam"
while IFS= read -r f; do
  p=$steam/$f
  [[ -f $p && ! -L $p ]] || continue
  case $(file -b "$p") in
    *"interpreter /lib/ld-linux"* | "POSIX shell script"* | "Python script"*) chmod a+x "$p" ;;
  esac
done < <(unzip -Z1 "$work/bins.zip")

tar -xJf "$work/runtime.tar.xz" -C "$steam"
ibus=$(cd "$steam" && find steam-runtime-steamrt-arm64 -path '*/files/lib/aarch64-linux-gnu/libibus-1.0.so.5.*' -type f | sort -V | tail -n1)
[[ -n $ibus ]] || { echo "build.sh: no libibus in the runtime" >&2; exit 1; }
mkdir -p "$steam/lib/aarch64-linux-gnu"
ln -s "../../$ibus" "$steam/lib/aarch64-linux-gnu/libibus-1.0.so.5"
[[ -x $steam/steamrtarm64/steam ]] || { echo "build.sh: bins package has no steamrtarm64/steam" >&2; exit 1; }

installed=$steam/package/$STEAM_MANIFEST.installed
"$src/bootstrap.sh" "$home" "$work/feed" "$installed" "$top/log"

rm -rf "$steam/logs" "$steam/package/steam_client_metrics.bin" "$home/.steam/registry.vdf" \
  "$home/.steam/steam.pid" "$home/.steam/steam.token"
find "$steam" -name '*\\*' -prune -exec rm -rf {} +
find "$home" \( -type s -o -type p \) -delete
python3 "$src/manifest.py" installed "$installed" "$steam"
printf '%b\n' '"Registry"' '{' '\t"HKCU"' '\t{' '\t\t"Software"' '\t\t{' '\t\t\t"Valve"' '\t\t\t{' \
  '\t\t\t\t"Steam"' '\t\t\t\t{' '\t\t\t\t\t"CompletedOOBEStage1"\t\t"0"' '\t\t\t\t\t"CompletedOOBE"\t\t"0"' \
  '\t\t\t\t}' '\t\t\t}' '\t\t}' '\t}' '}' > "$home/.steam/registry.vdf"

tar --sort=name --owner=1000 --group=1000 --numeric-owner -C "$home" -cf - .local/share/Steam .steam \
  | zstd -q -T0 -19 --long=27 -o "$top/SOURCES/steam-seed.tar.zst"
cp "$steam/steam_subscriber_agreement.txt" "$top/SOURCES/"

rpmbuild -bb \
  --define "_topdir $top" \
  --define "client_version $STEAM_CLIENT_VERSION" \
  --define "runtime_version $STEAM_RUNTIME_VERSION" \
  "$src/microos-steam-seed.spec"

find "$top/RPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$vdf" "$out/"
