#!/usr/bin/env bash
set -euo pipefail

fedora=registry.fedoraproject.org/fedora:44@sha256:1ff9eb02e4e2d7fb1175becac7139b2960c4fdcccedce81c86ec25b98ef3124d

(( $# == 2 )) || { echo "usage: bump.sh <pipewire EVR> <wireplumber EVR>" >&2; exit 2; }
pw=$1
wp=$2
for evr in "$pw" "$wp"; do
  [[ $evr =~ ^[0-9][0-9.]*-[0-9][A-Za-z0-9._]*$ ]] || { echo "bump.sh: $evr is not <version>-<release>" >&2; exit 2; }
done
src=$(cd "$(dirname "$0")" && pwd)
if [[ -z ${BUMP_IN_FEDORA:-} ]]; then
  eqdir=$(cd "$src/../microos-eq" && pwd)
  exec podman run --rm -e BUMP_IN_FEDORA=1 -e BUMP_EQ_DIR=/eq -v "$src:/src:Z" -v "$eqdir:/eq:Z" "$fedora" \
    /src/bump.sh "$pw" "$wp"
fi
env=$src/SOURCE.env
eqenv=${BUMP_EQ_DIR:?}/SOURCE.env
. "$src/SOURCE.env"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rpmkeys --dbpath "$tmp/db" --import /etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-44-primary
fpr=$(rpm --dbpath "$tmp/db" -q gpg-pubkey --qf '%{VERSION}\n')
[[ $fpr =~ ^[0-9a-f]{40}$ ]] || { echo "bump.sh: Fedora 44 key fingerprint is '$fpr'" >&2; exit 1; }
key=${fpr: -8}

sha() {
  local f=$tmp/${1##*/}
  curl -fsSL --retry 3 -o "$f" "$1"
  [[ $(rpmkeys --dbpath "$tmp/db" --checksig "$f") == "$f: digests signatures OK" ]] \
    || { echo "bump.sh: ${1##*/} is not signed by the Fedora 44 key $key" >&2; exit 1; }
  sha256sum < "$f" | cut -d' ' -f1
  rm -f "$f"
}

rpms() {
  local pkg=$1 evr=$2 list=$3 name sum
  for name in $list; do
    sum=$(sha "$KOJI_URL/$pkg/${evr%%-*}/${evr#*-}/data/signed/$key/aarch64/$name-$evr.aarch64.rpm")
    printf '%s %s\n' "$name" "$sum"
  done
}

pwnames=$(awk 'NF == 2 { print $1 }' <<<"$PIPEWIRE_RPMS")
wpnames=$(awk 'NF == 2 { print $1 }' <<<"$WIREPLUMBER_RPMS")
srpm=$(sha "$KOJI_URL/pipewire/${pw%%-*}/${pw#*-}/data/signed/$key/src/pipewire-$pw.src.rpm")
pwlist=$(rpms pipewire "$pw" "$pwnames")
wplist=$(rpms wireplumber "$wp" "$wpnames")

out=$(mktemp "$env.XXXXXX")
cat > "$out" <<END
LIBFREEAPTX_URL=$LIBFREEAPTX_URL
LIBFREEAPTX_VERSION=$LIBFREEAPTX_VERSION
LIBFREEAPTX_REF=$LIBFREEAPTX_REF
LIBFREEAPTX_SHA256=$LIBFREEAPTX_SHA256

KOJI_URL=$KOJI_URL
KOJI_KEY=$key

PIPEWIRE_EVR=$pw
PIPEWIRE_SRPM_SHA256=$srpm
PIPEWIRE_RPMS="
$pwlist
"

WIREPLUMBER_EVR=$wp
WIREPLUMBER_RPMS="
$wplist
"
END
chmod 644 "$out"
eqout=$(mktemp "$eqenv.XXXXXX")
cat > "$eqout" <<END
KOJI_URL=$KOJI_URL
KOJI_KEY=$key
PIPEWIRE_EVR=$pw
PIPEWIRE_SRPM_SHA256=$srpm
END
chmod 644 "$eqout"
mv "$out" "$env"
mv "$eqout" "$eqenv"
echo "SOURCE.env: pipewire $pw, wireplumber $wp, signed by $key; microos-eq SOURCE.env pipewire $pw"
