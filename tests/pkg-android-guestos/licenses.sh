#!/usr/bin/env bash
set -euo pipefail

licenses=${1:?usage: licenses.sh <licenses.py>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

for tool in python3 ninja; do
  command -v "$tool" > /dev/null || { echo "FAIL: $tool missing" >&2; exit 1; }
done
[[ -f /usr/share/licenses/bison/COPYING ]] || { echo "FAIL: /usr/share/licenses/bison/COPYING missing" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tmp=$(realpath "$tmp")
top=$tmp/top
mit='Permission is hereby granted, free of charge, to any person obtaining a copy of this software.'
mkdir -p "$top/mesa-1/licenses" "$top/mesa-1/subprojects/libdrm-1" "$top/mesa-1/src/vulkan/runtime/radix_sort" \
  "$top/mesa-1/include/android_stub/system" "$top/Fossilize-1/miniz" "$top/rapidjson-1" "$top/lsfg-vk-arm64-1/src" \
  "$top/lsfg-vk-arm64-1/include" "$top/build-lsfg/gen" "$top/build-fossilize/gen" "$tmp/ndk"
note() { printf 'Copyright %s fixture\n\n%s\n' "$2" "$mit" > "$1"; }
note "$top/mesa-1/licenses/MIT" mesa
note "$top/mesa-1/src/vulkan/runtime/radix_sort/LICENSE" radix
note "$top/mesa-1/include/android_stub/system/graphics.h" stub
note "$top/Fossilize-1/miniz/LICENSE" miniz
note "$top/Fossilize-1/LICENSE" fossilize
note "$tmp/port-LICENSE.md" port
note "$tmp/toml-LICENSE" toml
printf 'GNU GENERAL PUBLIC LICENSE\nVersion 3, 29 June 2007\n' > "$top/lsfg-vk-arm64-1/LICENSE.md"
printf '/* SPDX-License-Identifier: GPL-3.0-or-later */\nint a;\n' > "$top/lsfg-vk-arm64-1/src/a.cpp"
printf '/* SPDX-License-Identifier: GPL-3.0-or-later */\nint port;\n' > "$top/lsfg-vk-arm64-1/src/port.cpp"
printf '// SPDX-License-Identifier: MIT\nint toml;\n' > "$top/lsfg-vk-arm64-1/include/toml.hpp"
printf 'int gen;\n' > "$top/build-lsfg/gen/gen.cpp"
printf 'int gen;\n' > "$top/build-fossilize/gen/gen.cpp"
printf '#!/bin/sh\necho \x27 "ld.lld" "-o" "/dev/null"\x27 >&2\n' > "$tmp/clangxx"
chmod +x "$tmp/clangxx"
rules='rule cc
  command = printf "%s: %s\\n" $out "$in $extra" > $out.d && touch $out
  depfile = $out.d
  deps = gcc
rule link
  command = touch $out
'
cat > "$top/build-lsfg/build.ninja" <<EOF
$rules
build a.o: cc ../lsfg-vk-arm64-1/src/a.cpp
  extra = ../lsfg-vk-arm64-1/include/toml.hpp
build port.o: cc ../lsfg-vk-arm64-1/src/port.cpp
build gen.o: cc gen/gen.cpp
build lib.so: link a.o port.o gen.o
EOF
cat > "$top/build-fossilize/build.ninja" <<EOF
$rules
build gen.o: cc gen/gen.cpp
build lib.so: link gen.o
EOF
ninja -C "$top/build-lsfg" > /dev/null
ninja -C "$top/build-fossilize" > /dev/null

gate() {
  local out=$1
  shift
  (cd "$top" && python3 "$licenses" --ndk "$tmp/ndk" --clangxx "$tmp/clangxx" --out "$tmp/$out" "$@" \
    build-lsfg/lib.so build-fossilize/lib.so)
}
row() { grep -qxF "$2"$'\t'"$3" "$tmp/$1/SOURCES.tsv" || fail "$1: $3 is not $2"; }
has() { grep -qxF "Copyright $2 fixture" "$tmp/$1/LICENSES/MIT.txt" || fail "$1: MIT.txt lacks the $2 text"; }
lacks() { ! grep -qxF "Copyright $2 fixture" "$tmp/$1/LICENSES/MIT.txt" || fail "$1: MIT.txt has the $2 text"; }

tag=$(gate notice --notice lsfg-vk-arm64-1/include/toml.hpp="$tmp/toml-LICENSE" \
  --notice lsfg-vk-arm64-1/src/port.cpp="$tmp/port-LICENSE.md") || fail "gate with notices exited $?"
[[ $tag == 'GPL-3.0-or-later AND MIT' ]] || fail "notice: tag $tag"
row notice GPL-3.0-or-later lsfg-vk-arm64-1/src/a.cpp
row notice MIT lsfg-vk-arm64-1/include/toml.hpp
row notice 'GPL-3.0-or-later AND MIT' lsfg-vk-arm64-1/src/port.cpp
row notice GPL-3.0-or-later build-lsfg/gen/gen.cpp
row notice MIT build-fossilize/gen/gen.cpp
for text in mesa port toml fossilize; do has notice "$text"; done
[[ -f $tmp/notice/LICENSES/GPL-3.0-or-later.txt ]] || fail "notice: no GPL-3.0-or-later.txt"

tag=$(gate plain) || fail "gate without notices exited $?"
[[ $tag == 'GPL-3.0-or-later AND MIT' ]] || fail "plain: tag $tag"
row plain MIT lsfg-vk-arm64-1/include/toml.hpp
row plain GPL-3.0-or-later lsfg-vk-arm64-1/src/port.cpp
has plain fossilize
lacks plain port
lacks plain toml

if err=$(gate unused --notice lsfg-vk-arm64-1/src/missing.cpp="$tmp/port-LICENSE.md" 2>&1); then
  fail "a notice on no compiled file passed"
elif [[ $err != *'matches no compiled file'* ]]; then
  fail "unused notice: $err"
fi

exit "$rc"
