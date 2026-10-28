#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-lsfg-vk.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"
arch=$(uname -m)
lib=/usr/lib64/liblsfg-vk-layer.so
manifest=/usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.$arch.json
licenses=/usr/share/licenses/lsfg-vk
exports=vkNegotiateLoaderLayerInterfaceVersion

one() {
  local f
  f=$(find "$dir" -maxdepth 1 -name "$1")
  if [[ -z $f || $(wc -l <<<"$f") -ne 1 ]]; then
    echo "FAIL: expected one $1 in $dir" >&2
    exit 1
  fi
  echo "$f"
}
rpm=$(one "lsfg-vk-2.0.0~${LSFGVK_DATE}git${LSFGVK_REF::10}-*.microos.$arch.rpm")
tests=$(one "lsfg-vk-tests-2.0.0~${LSFGVK_DATE}git${LSFGVK_REF::10}-*.microos.noarch.rpm")
srpm=$(one "lsfg-vk-2.0.0~${LSFGVK_DATE}git${LSFGVK_REF::10}-*.microos.src.rpm")
others=$(find "$dir" -maxdepth 1 -name '*.rpm' ! -samefile "$rpm" ! -samefile "$tests" ! -samefile "$srpm")
if [[ -n $others ]]; then fail "other RPMs: $others"; fi

files() { rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$1" | awk 'substr($1, 1, 1) != "d" { print $2 }' | LC_ALL=C sort; }
for r in "$rpm" "$tests"; do
  name=$(rpm -qp --qf '%{NAME}' "$r")
  if [[ $(rpm -qp --qf '%{VENDOR}' "$r") != MicroOS ]]; then fail "$name: vendor"; fi
  if [[ $(rpm -qp --qf '%{SOURCERPM}' "$r") != "${srpm##*/}" ]]; then fail "$name: SOURCERPM"; fi
  writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$r" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
  if [[ -n $writable ]]; then fail "$name: group or other writable: $writable"; fi
done
want=$(printf '%s\n' "$lib" "$manifest" "$licenses/LICENSE.md" "$licenses/LICENSE-MIT.md" "$licenses/LICENSE-tomlplusplus" | LC_ALL=C sort)
got=$(files "$rpm")
if [[ $got != "$want" ]]; then fail "lsfg-vk files: $got"; fi
want=$(printf '%s\n' /usr/share/licenses/lsfg-vk-tests/LICENSE.md /usr/share/lsfg-vk/tests/good.dll /usr/share/lsfg-vk/tests/not-spirv.dll | LC_ALL=C sort)
got=$(files "$tests")
if [[ $got != "$want" ]]; then fail "lsfg-vk-tests files: $got"; fi
big=$(rpm -qp --qf '[%{FILESIZES} %{FILENAMES}\n]' "$tests" | awk '$2 ~ /\.dll$/ && $1 >= 65536')
if [[ -n $big ]]; then fail "fixture DLL of 64 KiB or more: $big"; fi
if rpm -qlp "$rpm" "$tests" | grep -iE '(^|/)(lossless\.dll|conf\.toml)$'; then fail "a Lossless.dll or conf.toml is packaged"; fi
listing=$(rpm2archive -n - <"$srpm" | tar -xO --wildcards '*.tar.gz' | tar -tz)
if ! grep -qx "lsfg-vk-arm64-$LSFGVK_REF/CMakeLists.txt" <<<"$listing"; then fail "no source tarball in the SRPM"; fi
if grep -iE '\.dll$' <<<"$listing"; then fail "the source tarball carries a DLL"; fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rpm2archive -n - <"$rpm" | tar -x -C "$work" --no-same-owner
so=$work$lib

python3 - "$work$manifest" "$lib" <<'PY' || fail "manifest"
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
layer = manifest["layer"]
want = {
    "name": "VK_LAYER_LSFGVK_frame_generation",
    "type": "GLOBAL",
    "library_path": sys.argv[2],
    "enable_environment": {"LSFGVK_ENV": "1"},
    "disable_environment": {"DISABLE_LSFGVK": "1"},
}
bad = {k: layer.get(k) for k, v in want.items() if layer.get(k) != v}
if bad or not sys.argv[2].startswith("/"):
    sys.exit(f"manifest fields {bad}")
PY

names=$(nm -D --defined-only "$so" | awk '{ print $NF }' | LC_ALL=C sort -u)
echo "pkg-lsfg-vk: exports $(tr '\n' ' ' <<<"$names")"
if grep -E '^_Z' <<<"$names"; then fail "C++ names exported"; fi
if grep -E '^(_ZSt|_ZNSt|_ZN9__gnu_cxx|__cxa_|__gxx_)' <<<"$names"; then fail "libstdc++ or libgcc names exported"; fi
if [[ $names != "$exports" ]]; then fail "exports differ from the recorded set: $exports"; fi
versions=$(readelf --version-info "$so")
if grep -q 'GLIBCXX_' <<<"$versions"; then fail "needs GLIBCXX_ versions"; fi
dynamic=$(readelf -d "$so")
if grep -qE 'Shared library: \[(libstdc\+\+|libgcc_s)' <<<"$dynamic"; then fail "needs a dynamic libstdc++ or libgcc_s"; fi
symbols=$(nm "$so")
if ! grep -q myvkWaitForPresent2KHR <<<"$symbols"; then fail "no vkWaitForPresent2KHR handling in the layer"; fi

if (( rc == 0 )); then echo "pkg-lsfg-vk: ok"; fi
exit "$rc"
