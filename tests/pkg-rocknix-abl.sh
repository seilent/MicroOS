#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-rocknix-abl.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"

one() {
  local f
  f=$(find "$dir" -maxdepth 1 -name "$1")
  if [[ -z $f || $(wc -l <<<"$f") -ne 1 ]]; then
    echo "FAIL: expected one $1 in $dir" >&2
    exit 1
  fi
  echo "$f"
}
rpm=$(one "rocknix-abl-${ABL_VERSION}-*.microos.noarch.rpm")
srpm=$(one "rocknix-abl-${ABL_VERSION}-*.microos.src.rpm")
others=$(find "$dir" -maxdepth 1 -name '*.rpm' ! -samefile "$rpm" ! -samefile "$srpm")
if [[ -n $others ]]; then fail "other RPMs: $others"; fi

[[ $(rpm -qp --qf '%{VENDOR}' "$rpm") == MicroOS ]] || fail "vendor"
[[ $(rpm -qp --qf '%{SOURCERPM}' "$rpm") == "${srpm##*/}" ]] || fail "SOURCERPM"
[[ $(rpm -qp --qf '%{ARCH}' "$rpm") == noarch ]] || fail "not noarch"
writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" \
  | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi
if rpm -qlp "$rpm" | grep -q '^/usr/share/licenses/'; then fail "a license file is packaged"; fi

files=$(rpm -qp --qf '[%{FILEMODES:octal} %{FILENAMES}\n]' "$rpm")
doc=$(awk '$1 == "100644" && $2 ~ /^\/usr\/share\/doc\/rocknix-abl[^\/]*\/README\.md$/ { print $2 }' <<<"$files")
if [[ $(grep -c . <<<"$doc") -ne 1 ]]; then fail "expected one README.md in the doc dir, got: $doc"; fi
want=$(printf '%s\n' \
  "100644 /usr/lib/microos/abl/abl_signed-SM8250.elf" \
  "100644 /usr/lib/microos/abl/abl_signed-SM8250.elf.sha256" \
  "100644 /usr/lib/microos/abl/manifest" \
  "100644 /usr/lib/microos/abl/releases.tsv" \
  "100644 /usr/lib/microos/abl/esp/README" \
  "100755 /usr/lib/microos/abl/esp/backup_abl.sh" \
  "100755 /usr/lib/microos/abl/esp/flash_abl.sh" \
  "100755 /usr/lib/microos/abl/esp/restore_backup_abl.sh" \
  "100644 $doc" | LC_ALL=C sort)
got=$(awk '$1 != "40755" { print }' <<<"$files" | LC_ALL=C sort)
if [[ $got != "$want" ]]; then fail "rocknix-abl files: $got"; fi
want=$(printf '%s\n' /usr/lib/microos/abl /usr/lib/microos/abl/esp "$(dirname "$doc")" | LC_ALL=C sort)
got=$(awk '$1 == "40755" { print $2 }' <<<"$files" | LC_ALL=C sort)
if [[ $got != "$want" ]]; then fail "rocknix-abl dirs: $got"; fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/rpm" "$work/src"
rpm2archive -n - < "$rpm" | tar -x -C "$work/rpm" --no-same-owner
rpm2archive -n - < "$srpm" | tar -x -C "$work/src" --no-same-owner
abl=$work/rpm/usr/lib/microos/abl

le32() { od -An -tu4 -j"$2" -N4 "$1" | tr -d ' \n'; }
le16() { od -An -tu2 -j"$2" -N2 "$1" | tr -d ' \n'; }

extent() {
  local f=$1 phoff phentsize phnum shoff shentsize shnum l i o e
  phoff=$(le32 "$f" 28)
  phentsize=$(le16 "$f" 42)
  phnum=$(le16 "$f" 44)
  shoff=$(le32 "$f" 32)
  shentsize=$(le16 "$f" 46)
  shnum=$(le16 "$f" 48)
  l=$((shoff + shnum * shentsize))
  for ((i = 0; i < phnum; i++)); do
    o=$((phoff + i * phentsize))
    e=$(( $(le32 "$f" $((o + 4))) + $(le32 "$f" $((o + 16))) ))
    (( e <= l )) || l=$e
  done
  printf '%s\n' "$l"
}

elf=$abl/abl_signed-SM8250.elf
length=$(extent "$elf")
got=$(sha256sum < "$elf" | cut -d' ' -f1)
if [[ $got != "$ABL_ELF_SHA256" ]]; then fail "elf hash is $got"; fi
mapfile -t manifest < "$abl/manifest"
want=(MICROOS_ABL_FORMAT=1 "MICROOS_ABL_VERSION=$ABL_VERSION" MICROOS_ABL_SOC=SM8250
  "MICROOS_ABL_LENGTH=$length" "MICROOS_ABL_SHA256=$ABL_ELF_SHA256" "MICROOS_ABL_ADMITTED=$ABL_ADMITTED_SHA256")
if [[ ${manifest[*]} != "${want[*]}" ]]; then fail "manifest: ${manifest[*]}"; fi

catalog=$abl/releases.tsv
if [[ $(head -n 1 "$catalog") != "$(printf 'order\tversion\tsoc\tlength\tsha256')" ]]; then fail "catalog header"; fi
bad=$(awk -F'\t' 'NR > 1 && (NF != 5 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9][0-9.]*$/ || $3 != "SM8250" \
  || $4 !~ /^[0-9]+$/ || $5 !~ /^[0-9a-f]{64}$/)' "$catalog")
if [[ -n $bad ]]; then fail "catalog rows: $bad"; fi
got=$(awk -F'\t' -v v="$ABL_VERSION" -v l="$length" -v s="$ABL_ELF_SHA256" \
  '$2 == v && $3 == "SM8250" && $4 == l && $5 == s' "$catalog")
if [[ $(grep -c . <<<"$got") -ne 1 ]]; then fail "catalog rows for the payload: $got"; fi
got=$(awk -F'\t' 'NR > 1 && $1 + 0 >= m { m = $1 + 0; v = $2 } END { print v }' "$catalog")
if [[ $got != "$ABL_VERSION" ]]; then fail "the highest order row is $got, not $ABL_VERSION"; fi

for s in backup_abl.sh flash_abl.sh restore_backup_abl.sh; do
  if [[ $(head -n 1 "$abl/esp/$s") != '#!/system/bin/sh' ]]; then fail "$s shebang"; fi
  if ! mksh -n "$abl/esp/$s"; then fail "mksh -n $s"; fi
done

release=$work/src/rocknix-abl-v$ABL_VERSION.tar.gz
got=$(sha256sum < "$release" | cut -d' ' -f1)
if [[ $got != "$ABL_SHA256" ]]; then fail "release tarball in the SRPM hashes to $got"; fi
tree=$work/src/rocknix-abl-$ABL_REPO_COMMIT.tar.gz
[[ -f $tree ]] || fail "no ROCKNIX/abl tree in the SRPM"
listing=$(tar -tzf "$tree")
for f in README.md update.sh .github/workflows/release-abl.yaml; do
  if ! grep -qx "rocknix-abl-$ABL_REPO_COMMIT/$f" <<<"$listing"; then fail "tree has no $f"; fi
done
if grep -qE "^rocknix-abl-$ABL_REPO_COMMIT/\.git/" <<<"$listing"; then fail "the tree tar carries .git"; fi
if [[ ! -f $work/src/rocknix-abl.spec ]]; then fail "no spec in the SRPM"; fi

if (( rc == 0 )); then echo "pkg-rocknix-abl: ok"; fi
exit "$rc"
