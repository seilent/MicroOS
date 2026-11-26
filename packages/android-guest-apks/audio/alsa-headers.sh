#!/usr/bin/env bash
set -euo pipefail

src=${1:?usage: alsa-headers.sh <alsa dir> <include dir>}
out=${2:?usage: alsa-headers.sh <alsa dir> <include dir>}
ver=$(sed -n '/^AC_INIT.* \([0-9.]*\))/s//\1/p' "$src/configure.ac")
IFS=. read -r major minor sub <<<"$ver"
[[ -n $major && -n $minor && -n $sub ]] || { echo "alsa-headers.sh: no version in $src/configure.ac" >&2; exit 1; }
mkdir -p "$out/alsa"
printf '%s\n' "#define SND_LIB_MAJOR $major" "#define SND_LIB_MINOR $minor" "#define SND_LIB_SUBMINOR $sub" \
  '#define SND_LIB_EXTRAVER 1000000' '#define SND_LIB_VER(maj, min, sub) (((maj)<<16)|((min)<<8)|(sub))' \
  '#define SND_LIB_VERSION SND_LIB_VER(SND_LIB_MAJOR, SND_LIB_MINOR, SND_LIB_SUBMINOR)' \
  "#define SND_LIB_VERSION_STR \"$ver\"" > "$out/alsa/version.h"
{
  cat "$src/asoundlib-head.h"
  sed -n '/.*\(#include <[ae].*.h>\).*/s//\1/p' "$src/configure.ac"
  cat "$src/asoundlib-tail.h"
} > "$out/alsa/asoundlib.h"
