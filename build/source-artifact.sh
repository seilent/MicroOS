#!/usr/bin/env bash
set -euo pipefail

fedora=registry.fedoraproject.org/fedora:44@sha256:1ff9eb02e4e2d7fb1175becac7139b2960c4fdcccedce81c86ec25b98ef3124d
koji=https://kojipkgs.fedoraproject.org/packages
key=6d9f90a6
repo=https://github.com/seilent/MicroOS

fail() { echo "source-artifact: $*" >&2; exit 1; }

(( $# == 4 )) || { echo "usage: source-artifact.sh <srpms.tsv> <outdir> <full|base> <pkgdir>" >&2; exit 2; }
tsv=$1
out=$2
mode=$3
pkgs=$4
[[ $mode == full || $mode == base ]] || fail "mode is $mode, not full or base"
[[ -s $tsv ]] || fail "$tsv is empty"
[[ -d $pkgs ]] || fail "$pkgs is not a dir"

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/packages/${KERNEL:?}/SOURCE.env"

mkdir -p "$out"
out=$(cd "$out" && pwd)
[[ -z $(ls -A "$out") ]] || fail "$out is not empty"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

nevra='^([A-Za-z0-9][A-Za-z0-9._+~^-]*)-([A-Za-z0-9._+~^]+)-([A-Za-z0-9._+~^]+)\.src\.rpm$'
: > "$tmp/own"
while IFS=$'\t' read -r name srpm vendor; do
  [[ $vendor == MicroOS ]] || continue
  case $name in
    microos-kernel|microos-steam-seed) ;;
    *)
      [[ $srpm =~ $nevra && $srpm != *..* ]] || fail "bad source rpm name $srpm for the MicroOS package $name"
      found=("$pkgs"/*/"$srpm")
      [[ ${#found[@]} == 1 && -f ${found[0]} ]] || fail "no source rpm $srpm in $pkgs for the MicroOS package $name"
      pkg=${found[0]%/*}
      ref=$(awk -v n="${pkg##*/}" '$1 == n { print $2 }' "$pkgs/refs" 2>/dev/null || true)
      [[ $ref == *@sha256:* ]] || fail "no pkg image ref for ${pkg##*/} in $pkgs/refs"
      printf '%s %s %s\n' "$srpm" "${found[0]}" "$ref" >> "$tmp/own"
      ;;
  esac
done < "$tsv"

sha=$(git -C "$root" rev-parse HEAD)
short=${sha::7}
git -C "$root" archive --format=tar.gz --prefix=microos/ -o "$out/microos-$short.tar.gz" HEAD
printf '%s %s\n' "microos-$short.tar.gz" "$repo/tree/$sha" > "$tmp/origins"

if [[ -n ${KERNEL_URL:-} ]]; then
  kernel=${KERNEL_URL##*/}
  curl -fsSL --retry 5 --retry-all-errors -o "$out/$kernel" "$KERNEL_URL"
  [[ $(sha256sum < "$out/$kernel" | cut -d' ' -f1) == "$KERNEL_SHA256" ]] || fail "$kernel sha256 mismatch"
  printf '%s %s\n' "$kernel" "$KERNEL_URL" >> "$tmp/origins"
else
  kernel=linux-${KERNEL_TAG#v}.tar.gz
  git init -q "$tmp/linux"
  git -C "$tmp/linux" fetch -q --depth 1 "$KERNEL_GIT" "refs/tags/$KERNEL_TAG" || fail "fetch of $KERNEL_TAG failed"
  [[ $(git -C "$tmp/linux" rev-parse 'FETCH_HEAD^{commit}') == "$KERNEL_COMMIT" ]] || fail "$KERNEL_TAG is not $KERNEL_COMMIT"
  git -C "$tmp/linux" archive --format=tar.gz --prefix="linux-${KERNEL_TAG#v}/" -o "$out/$kernel" "$KERNEL_COMMIT"
  rm -rf "${tmp:?}/linux"
  printf '%s %s\n' "$kernel" "$KERNEL_GIT/tag/?h=$KERNEL_TAG" >> "$tmp/origins"
fi

if [[ $mode == full ]]; then
  sort -u "$tmp/own" | while read -r f path url; do
    cp "$path" "$out/$f"
    printf '%s %s\n' "$f" "$url" >> "$tmp/origins"
  done
  awk -F'\t' '$3 != "MicroOS" && $2 != "(none)" { print $2 }' "$tsv" | sort -u > "$tmp/srpms"
  [[ -s $tmp/srpms ]] || fail "no source rpms in $tsv"
  get=() fetched=() unsigned=()
  while read -r f; do
    [[ $f =~ $nevra && $f != *..* ]] || fail "bad source rpm name $f"
    if [[ -n ${MICROOS_SOURCE_CACHE:-} && -s $MICROOS_SOURCE_CACHE/$f ]]; then
      ln "$MICROOS_SOURCE_CACHE/$f" "$out/$f" 2> /dev/null || cp "$MICROOS_SOURCE_CACHE/$f" "$out/$f"
    else
      get+=(-o "$out/$f" "$koji/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}/data/signed/$key/src/$f")
      fetched+=("$f")
    fi
  done < "$tmp/srpms"
  echo "source-artifact: $(( $(wc -l < "$tmp/srpms") - ${#fetched[@]} )) source rpms from the cache, ${#fetched[@]} from koji"
  if (( ${#get[@]} )); then
    curl -fsSLg --retry 5 --parallel --parallel-max 8 "${get[@]}" || true
  fi
  for f in "${fetched[@]}"; do
    [[ ! -s $out/$f ]] || continue
    rm -f "$out/$f"
    [[ $f =~ $nevra ]]
    base=$koji/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}
    code=$(curl -sILg -o /dev/null -w '%{http_code}' --retry 5 --retry-all-errors "$base/data/signed/$key/src/$f") || code=000
    if [[ $code == 200 ]]; then
      curl -fsSLg --retry 5 --retry-all-errors -o "$out/$f" "$base/data/signed/$key/src/$f" || fail "$f: signed download failed"
      continue
    fi
    [[ $code == 404 ]] || fail "$f: the signed copy answered $code"
    curl -fsSLg --retry 5 --retry-all-errors -o "$out/$f" "$base/src/$f" || fail "$f: no signed copy and the unsigned download failed"
    unsigned+=("$f")
  done
  : > "$tmp/signed"
  while read -r f; do
    [[ -s $out/$f ]] || fail "$f missing"
    [[ $f =~ $nevra ]]
    base=$koji/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}
    if [[ " ${unsigned[*]} " == *" $f "* ]]; then
      printf '%s %s unsigned\n' "$f" "$base/src/$f" >> "$tmp/origins"
    else
      printf '%s %s\n' "$f" "$base/data/signed/$key/src/$f" >> "$tmp/origins"
      echo "$f" >> "$tmp/signed"
    fi
  done < "$tmp/srpms"
  mapfile -t signed < "$tmp/signed"
  if (( ${#signed[@]} )); then
    podman run --rm -v "$out:/src:ro" "$fedora" sh -c 'cd /src && rpm -K -- "$@"' sh "${signed[@]}" > "$tmp/rpmk" \
      || { grep -v ': digests signatures OK$' "$tmp/rpmk" >&2; fail "rpm -K failed"; }
    [[ $(grep -c ': digests signatures OK$' "$tmp/rpmk") == "${#signed[@]}" ]] || fail "rpm -K did not pass every signed source rpm"
  fi
  if (( ${#unsigned[@]} )); then
    echo "source-artifact: no signed copy on koji, checked against its rpm records: ${unsigned[*]}"
    podman run --rm -v "$out:/src:ro" "$fedora" sh -c 'cd /src && rpm -K --nosignature -- "$@"' sh "${unsigned[@]}" > "$tmp/rpmk" \
      || { cat "$tmp/rpmk" >&2; fail "rpm -K --nosignature failed"; }
    [[ $(grep -c ': digests OK$' "$tmp/rpmk") == "${#unsigned[@]}" ]] || fail "rpm -K --nosignature did not pass every unsigned source rpm"
    podman run --rm -v "$out:/src:ro" "$fedora" sh -c 'cd /src && for f; do printf "%s %s\n" "$f" "$(rpm -qp --qf "%{SIGMD5} %{SHA256HEADER}" -- "$f")"; done' \
      sh "${unsigned[@]}" > "$tmp/got" || fail "rpm -qp failed on the unsigned source rpms"
    python3 - "$tmp/got" "$out" << 'EOF' || fail "unsigned source rpms differ from koji's rpm records"
import os, socket, sys, time, xmlrpc.client
socket.setdefaulttimeout(60)
hub = xmlrpc.client.ServerProxy("https://koji.fedoraproject.org/kojihub")
def rpm(nvra):
    for n in range(3):
        try:
            return hub.getRPM(nvra) or {}
        except (OSError, xmlrpc.client.ProtocolError):
            if n == 2:
                raise
            time.sleep(10)
bad = 0
for line in open(sys.argv[1]):
    f, md5, sha = line.split()
    r = rpm(f.removesuffix(".rpm"))
    size = os.path.getsize(os.path.join(sys.argv[2], f))
    if r.get("payloadhash") != md5 or r.get("sha256header") not in (None, sha) or r.get("size") != size:
        print(f"{f}: koji {r.get('payloadhash')} {r.get('sha256header')} {r.get('size')}, file {md5} {sha} {size}", file=sys.stderr)
        bad = 1
sys.exit(bad)
EOF
  fi
fi

sort "$tmp/origins" | while read -r f url flag; do
  printf '%s %s %s%s\n' "$f" "$(sha256sum < "$out/$f" | cut -d' ' -f1)" "$url" "${flag:+ $flag}"
done > "$tmp/SOURCES"
[[ $(find "$out" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort) == "$(cut -d' ' -f1 "$tmp/SOURCES")" ]] || fail "files in $out differ from SOURCES"
mv "$tmp/SOURCES" "$out/SOURCES"

echo "source-artifact: $mode, $(wc -l < "$out/SOURCES") files, $(du -sb "$out" | cut -f1) bytes"
