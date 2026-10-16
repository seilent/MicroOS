#!/usr/bin/env bash
set -euo pipefail

src=$1
shift
. "$src"
arch=$(uname -m)
pin=$(mktemp -d)
trap 'rm -rf "$pin"' EXIT
want=()

add() {
  local pkg=$1 evr=$2 list=$3 name sum f have
  local -a names=()
  while read -r name sum; do
    if [[ -n $name ]]; then names+=("$name-$evr.$arch"); fi
  done <<< "$list"
  have=$(dnf -q repoquery --qf '%{name}-%{evr}.%{arch}\n' "${names[@]}")
  while read -r name sum; do
    [[ -n $name ]] || continue
    if grep -qxF "$name-$evr.$arch" <<< "$have"; then
      want+=("$name-$evr.$arch")
      continue
    fi
    [[ $arch == aarch64 ]] || { echo "pin-pipewire: $name-$evr.$arch is not in the repos and $src pins aarch64 RPMs only" >&2; exit 1; }
    f=$pin/$name-$evr.$arch.rpm
    curl -fsSL --retry 5 --retry-all-errors -o "$f" "$KOJI_URL/$pkg/${evr%%-*}/${evr#*-}/data/signed/$KOJI_KEY/$arch/$name-$evr.$arch.rpm"
    echo "$sum  $f" | sha256sum -c --quiet - || { echo "pin-pipewire: $name-$evr.$arch from koji fails sha256" >&2; exit 1; }
    want+=("$f")
  done <<< "$list"
}

add pipewire "$PIPEWIRE_EVR" "$PIPEWIRE_RPMS"
add wireplumber "$WIREPLUMBER_EVR" "$WIREPLUMBER_RPMS"
dnf -yq --setopt=install_weak_deps=False install "${want[@]}" "$@"
