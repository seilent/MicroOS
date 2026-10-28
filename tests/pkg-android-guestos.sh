#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-android-guestos.sh <rpmdir>}
here=$(cd "$(dirname "$0")" && pwd)
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"
version=${MESA_VERSION:?SOURCE.env has no MESA_VERSION}
ndk=/opt/android-ndk-$NDK_VERSION
readelf=$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf
sysroot=$ndk/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/$ANDROID_API
guestos=/usr/share/guestos/android
licdir=/usr/share/licenses/microos-android-guestos
layer=$guestos/vendor/vulkan_layers/libVkLayer_fossilize.so
json=/usr/share/vulkan/guestos-android/VkLayer_fossilize.json

rpm=$(find "$dir" -maxdepth 1 -name "microos-android-guestos-$version-*.microos.aarch64.rpm")
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 ]]; then
  echo "FAIL: expected one microos-android-guestos aarch64 RPM in $dir" >&2
  exit 1
fi
srpm=$(find "$dir" -maxdepth 1 -name "microos-android-guestos-$version-*.src.rpm")
if [[ -z $srpm || $(wc -l <<<"$srpm") -ne 1 ]]; then
  echo "FAIL: expected one microos-android-guestos SRPM in $dir" >&2
  exit 1
fi
others=$(find "$dir" -maxdepth 1 -name '*.rpm' ! -samefile "$rpm" ! -samefile "$srpm")
if [[ -n $others ]]; then fail "other RPMs: $others"; fi

if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi
if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "release"; fi
if [[ $(rpm -qp --qf '%{SOURCERPM}' "$rpm") != "${srpm##*/}" ]]; then fail "SOURCERPM"; fi
if requires=$(rpm -qp --requires "$rpm" | grep -v '^rpmlib('); then fail "requires: $requires"; fi

sources=$(rpm -qp --qf '[%{SOURCE}\n]' "$srpm" | sort)
want=$(printf '%s\n' "mesa-$version.tar.xz" "Fossilize-$FOSSILIZE_REF.tar.gz" "rapidjson-$RAPIDJSON_REF.tar.gz" \
  "libdrm-$LIBDRM_VERSION.tar.xz" "angle-$ANGLE_REF-LICENSE" microos-noubwc.rc build.sh fetch.sh licenses.py SOURCE.env | sort)
if [[ $sources != "$want" ]]; then fail "SRPM sources: $(tr '\n' ' ' <<<"$sources")"; fi

writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi

mesa=(
  "$guestos/vendor/lib64/hw/vulkan.freedreno.so"
  "$guestos/vendor/lib64/egl/libEGL_mesa.so"
  "$guestos/vendor/lib64/egl/libGLESv1_CM_mesa.so"
  "$guestos/vendor/lib64/egl/libGLESv2_mesa.so"
  "$guestos/vendor/lib64/libgallium_dri.so"
)
libs=("${mesa[@]}" "$layer")
files=$(rpm -qlp "$rpm" | grep -v -e "^$licdir$" -e "^$licdir/")
expected=$(printf '%s\n' /usr/share/guestos "$guestos" "$guestos/vendor" "$guestos/vendor/etc" "$guestos/vendor/etc/init" \
  "$guestos/vendor/etc/init/microos-noubwc.rc" "$guestos/vendor/lib64" "$guestos/vendor/lib64/egl" "$guestos/vendor/lib64/hw" \
  "$guestos/vendor/vulkan_layers" "${libs[@]}" /usr/share/vulkan/guestos-android "$json" | sort)
if [[ $files != "$expected" ]]; then fail "file list: $(diff <(echo "$expected") <(echo "$files") | grep '^[<>]' | tr '\n' ' ')"; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/root" "$tmp/src"
rpm2cpio "$rpm" > "$tmp/rpm.cpio"
rpm2cpio "$srpm" > "$tmp/srpm.cpio"
(cd "$tmp/root" && cpio -idm --quiet < "$tmp/rpm.cpio")
(cd "$tmp/src" && cpio -idm --quiet < "$tmp/srpm.cpio")
root=$tmp/root

declare -A shipped sphal ndklibs
for lib in "${libs[@]}"; do shipped[${lib##*/}]=1; done
while read -r name; do sphal[$name]=1; done < "$here/pkg-android-guestos/sphal-libs"
while read -r name; do ndklibs[$name]=1; done < <(find "$sysroot" -maxdepth 1 -name '*.so' -printf '%f\n')
for lib in "${libs[@]}"; do
  f=$root$lib
  head=$("$readelf" -h "$f" 2>&1) || { fail "$lib is not an ELF file"; continue; }
  grep -q 'Class: *ELF64' <<<"$head" || fail "$lib is not ELF64"
  grep -q 'Machine: *AArch64' <<<"$head" || fail "$lib is not AArch64"
  grep -q 'Type: *DYN' <<<"$head" || fail "$lib is not a shared object"
  notes=$("$readelf" -n "$f")
  api=$(awk '/NT_ANDROID_TYPE_IDENT/ { getline; print strtonum("0x" $3) }' <<<"$notes")
  if [[ $api != "$ANDROID_API" ]]; then fail "$lib has no Android $ANDROID_API ABI note"; fi
  sections=$("$readelf" -S "$f")
  if grep -q ' \.symtab ' <<<"$sections"; then fail "$lib is not stripped"; fi
  dyn=$("$readelf" -d "$f")
  if grep -qE '\((RUNPATH|RPATH)\)' <<<"$dyn"; then fail "$lib has a RUNPATH or RPATH"; fi
  soname=$(sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p' <<<"$dyn")
  if [[ $soname != "${lib##*/}" ]]; then fail "$lib has SONAME $soname"; fi
  while read -r need; do
    [[ -n $need && -z ${shipped[$need]:-} ]] || continue
    if [[ $lib == "$layer" ]]; then
      [[ -n ${ndklibs[$need]:-} ]] || fail "$lib needs $need, which is neither in the package nor an NDK API $ANDROID_API library"
    else
      [[ -n ${sphal[$need]:-} ]] || fail "$lib needs $need, which is neither in the package nor an Android 11 LLNDK or VNDK-SP library"
    fi
  done < <(sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' <<<"$dyn")
done

python3 - "$root$json" "$layer" <<'EOF' || fail "$json"
import json, sys
d = json.load(open(sys.argv[1]))
assert d['layer']['name'] == 'VK_LAYER_fossilize', d['layer']['name']
assert d['layer']['library_path'] == sys.argv[2], d['layer']['library_path']
EOF

if [[ $(cat "$root$guestos/vendor/etc/init/microos-noubwc.rc") != $'on early-init\n    setprop debug.mesa.tu.debug noubwc' ]]; then fail "microos-noubwc.rc content"; fi

lic=$root$licdir
if [[ ! -s $lic/SOURCES.tsv ]]; then
  fail "no $licdir/SOURCES.tsv"
else
  python3 - "$lic" "$(rpm -qp --qf '%{LICENSE}' "$rpm")" <<'EOF' || fail "license files differ from the compiled list"
import os, re, sys
lic, tag = sys.argv[1], sys.argv[2]
rows = [line.rstrip('\n').split('\t') for line in open(os.path.join(lic, 'SOURCES.tsv'))]
assert all(len(r) == 2 and r[0] and r[1] for r in rows), 'bad SOURCES.tsv row'
paths = [r[1] for r in rows]
for want in ('mesa-', 'Fossilize-', 'rapidjson-', 'libdrm-', 'libc++_static.a', 'libc++abi.a', 'crtbegin_so.o'):
    assert any(want in p for p in paths), f'no compiled file from {want}'
atoms = set()
for expr, _ in rows:
    for a in re.split(r' AND (?![^(]*\))', expr):
        atoms.add(a.strip().strip('()'))
texts = {f[:-4] for f in os.listdir(os.path.join(lic, 'LICENSES')) if f.endswith('.txt')}
used = set()
for a in atoms:
    alts = [[p.strip() for p in alt.split(' WITH ')] for alt in a.split(' OR ')]
    ok = [alt for alt in alts if all(i in texts for i in alt)]
    assert ok, f'no license text for {a}'
    used.update(ok[0])
assert used == texts, f'texts not used by the compiled list: {sorted(texts - used)}'
want = ' AND '.join(sorted(a if ' OR ' not in a else f'({a})' for a in atoms))
assert tag == want, f'License tag {tag}, compiled list {want}'
EOF
  python3 - "$lic" "$tmp/src" "$version" "$LIBDRM_VERSION" "$NDK_VERSION" <<'EOF' || fail "license rows differ from the source text"
import glob, os, re, sys, tarfile
lic, src, version, libdrm, ndk = sys.argv[1:]
rows = {}
for line in open(os.path.join(lic, 'SOURCES.tsv')):
    expr, path = line.rstrip('\n').split('\t')
    rows[path] = expr
mesa = f'mesa-{version}/'
drm = f'{mesa}subprojects/libdrm-{libdrm}/'
known = {
    'src/c11/threads.h': 'BSL-1.0',
    'src/c11/impl/time.c': 'BSL-1.0',
    'src/loader/loader_dri_helper.c': 'HPND-sell-variant',
    'src/loader/loader_dri_helper.h': 'HPND-sell-variant',
    'src/loader/loader_dri_helper_screen.h': 'HPND-sell-variant',
    'src/util/xxhash.h': 'BSD-2-Clause',
    'src/util/softfloat.c': 'BSD-3-Clause',
    'src/util/blake3/blake3.c': 'CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception',
    'src/vulkan/runtime/radix_sort/radix_sort_vk.c': 'BSD-2-Clause',
    'include/EGL/eglext_angle.h': 'BSD-3-Clause',
    'include/GLES3/gl3ext.h': 'SGI-B-2.0',
    'include/drm-uapi/dma-buf.h': 'GPL-2.0-only WITH Linux-syscall-note',
    'include/android_stub/system/graphics-base-v1.0.h': 'Apache-2.0',
    'src/gallium/auxiliary/pipebuffer/pb_bufmgr_slab.c': 'MIT',
}
for path, expr in known.items():
    assert rows.get(mesa + path) == expr, f'{path}: {rows.get(mesa + path)}, want {expr}'
for suffix, expr in (('/libc++_static.a', 'Apache-2.0 WITH LLVM-exception'), ('/crtbegin_so.o', 'LicenseRef-NDK-sysroot')):
    hits = [e for p, e in rows.items() if p.startswith(f'android-ndk-{ndk}/') and p.endswith(suffix)]
    assert hits == [expr], f'{suffix}: {hits}'
names = {}
for path, expr in rows.items():
    if expr == 'MIT' and not path.startswith(('build-', 'android-ndk-')):
        names[f'libdrm-{libdrm}/{path[len(drm):]}' if path.startswith(drm) else path] = path
other = re.compile(r'Boost Software License|distribute, and sell this software|Mozilla Public|ISC License'
                   r'|GNU (Lesser |Library )?General Public|(?-i:\bL?GPL)|Redistribution and use in source and binary forms'
                   r'|Apache License|and/or distribute this software for any purpose|Permission is granted to anyone'
                   r'|Creative Commons', re.I)
dedicated = re.compile(r'mesa-[^/]+/src/util/(fast_idiv_by_const|rand_xor)\.c|Fossilize-[0-9a-f]+/miniz/miniz\.h')
pipeline = re.compile(r'mesa-[^/]+/src/gallium/drivers/zink/zink_program\.h')
seen = 0
for ball in glob.glob(os.path.join(src, '*.tar.*')):
    with tarfile.open(ball) as t:
        for m in t:
            if m.isfile() and m.name in names:
                head = t.extractfile(m).read(16384).decode('utf-8', 'replace')
                text = re.sub(r'\s+', ' ', re.sub(r'(?m)^[ \t]*(?:/\*+|\*+/|\*+|//+|#+)?[ \t]?', '', head))
                if pipeline.fullmatch(names[m.name]):
                    text = text.replace('TODO: is sample shading even possible to handle with GPL?', '')
                hit = other.search(text)
                if not hit and not dedicated.fullmatch(names[m.name]):
                    hit = re.search(r'public domain|Unlicense', text, re.I)
                assert not hit, f'{names[m.name]} is MIT in SOURCES.tsv, its text has {hit.group(0)}'
                seen += 1
assert seen == len(names), f'{seen} of {len(names)} MIT rows found in the SRPM tarballs'
EOF
fi

if grep -rqia armada "$root" "$tmp/src"; then fail "armada in $(grep -rlia armada "$root" "$tmp/src" | head -n3 | tr '\n' ' ')"; fi

exit "$rc"
