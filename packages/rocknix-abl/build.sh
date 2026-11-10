#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir> <workdir>}
work=${2:?usage: build.sh <outdir> <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"
. "$src/extent.sh"

die() { echo "build.sh: $*" >&2; exit 1; }

tarball=$work/rocknix-abl-v$ABL_VERSION.tar.gz
tree=$work/abl
[[ -f $tarball ]] || die "fetch.sh left no $tarball"
[[ -d $tree ]] || die "fetch.sh left no $tree"
echo "$ABL_SHA256  $tarball" | sha256sum -c --quiet -

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"

cp "$tarball" "$top/SOURCES/rocknix-abl-v$ABL_VERSION.tar.gz"
tar -xzf "$tarball" -C "$top/SOURCES" --strip-components=1 --no-same-owner \
  "rocknix-abl-v$ABL_VERSION/abl_signed-SM8250.elf" \
  "rocknix-abl-v$ABL_VERSION/abl_signed-SM8250.elf.sha256"
elf=$top/SOURCES/abl_signed-SM8250.elf
echo "$ABL_ELF_SHA256  $elf" | sha256sum -c --quiet -
( cd "$top/SOURCES" && sha256sum -c --quiet abl_signed-SM8250.elf.sha256 )
[[ $ABL_ADMITTED_SHA256 == "$ABL_ELF_SHA256" ]] \
  || die "ABL_ADMITTED_SHA256 is not the elf hash of v$ABL_VERSION"

[[ $(head -n 1 "$src/releases.tsv") == "$(printf 'order\tversion\tsoc\tlength\tsha256')" ]] \
  || die "releases.tsv header"
row=$(awk -F'\t' -v v="$ABL_VERSION" '$2 == v && $3 == "SM8250" { print $4 " " $5 }' "$src/releases.tsv")
length=$(extent "$elf")
[[ $row == "$length $ABL_ELF_SHA256" ]] \
  || die "releases.tsv has '$row' for SM8250 v$ABL_VERSION, the elf is '$length $ABL_ELF_SHA256'"

{
  printf 'MICROOS_ABL_FORMAT=1\n'
  printf 'MICROOS_ABL_VERSION=%s\n' "$ABL_VERSION"
  printf 'MICROOS_ABL_SOC=SM8250\n'
  printf 'MICROOS_ABL_LENGTH=%s\n' "$length"
  printf 'MICROOS_ABL_SHA256=%s\n' "$ABL_ELF_SHA256"
  printf 'MICROOS_ABL_ADMITTED=%s\n' "$ABL_ADMITTED_SHA256"
} > "$top/SOURCES/manifest"

tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
  --transform "s,^\.,rocknix-abl-$ABL_REPO_COMMIT," \
  -czf "$top/SOURCES/rocknix-abl-$ABL_REPO_COMMIT.tar.gz" -C "$tree" .
cp "$src/releases.tsv" "$src"/esp/* "$top/SOURCES/"

rpmbuild -ba \
  --define "_topdir $top" \
  --define "abl_version $ABL_VERSION" \
  --define "abl_commit $ABL_REPO_COMMIT" \
  "$src/rocknix-abl.spec"

find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp -t "$out" {} +
cp "$src/SOURCE.env" "$out/"
