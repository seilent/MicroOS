#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-pipewire-aptx.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
arch=$(rpm --eval '%{_arch}')

if [[ -n $(find "$dir" -maxdepth 1 \( -name '*-debuginfo-*' -o -name '*-debugsource-*' \)) ]]; then fail "debug RPM present"; fi

declare -A rpms
for name in libfreeaptx libfreeaptx-devel pipewire-codec-aptx; do
  rpm=$(find "$dir" -maxdepth 1 -name "$name-[0-9]*.$arch.rpm")
  if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 ]]; then
    echo "FAIL: expected one $name RPM in $dir" >&2
    exit 1
  fi
  rpms[$name]=$rpm
  if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "$name: release"; fi
  if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "$name: vendor"; fi
  srpm=$(rpm -qp --qf '%{SOURCERPM}' "$rpm")
  if [[ ! -f $dir/$srpm ]]; then fail "$name: SRPM $srpm missing"; fi
  writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
  if [[ -n $writable ]]; then fail "$name: group or other writable: $writable"; fi
done

libdir=/usr/lib64
codec=$libdir/spa-0.2/bluez5/libspa-codec-bluez5-aptx.so

files=$(rpm -qlp "${rpms[libfreeaptx]}")
for f in /usr/share/licenses/libfreeaptx/COPYING $libdir/libfreeaptx.so.0 $libdir/libfreeaptx.so.0.2.2; do
  if ! grep -qx "$f" <<<"$files"; then fail "libfreeaptx: missing $f"; fi
done
if grep -qE '^(/usr/bin/|/usr/include/|.*\.so$)' <<<"$files"; then fail "libfreeaptx ships tools or devel files"; fi
devfiles=$(rpm -qlp "${rpms[libfreeaptx-devel]}")
for f in /usr/include/freeaptx.h $libdir/libfreeaptx.so $libdir/pkgconfig/libfreeaptx.pc; do
  if ! grep -qx "$f" <<<"$devfiles"; then fail "libfreeaptx-devel: missing $f"; fi
done
codecfiles=$(rpm -qlp "${rpms[pipewire-codec-aptx]}")
for f in /usr/share/licenses/pipewire-codec-aptx/COPYING /usr/share/licenses/pipewire-codec-aptx/LICENSE "$codec"; do
  if ! grep -qx "$f" <<<"$codecfiles"; then fail "pipewire-codec-aptx: missing $f"; fi
done
if [[ $(grep -c '^/usr/lib64/' <<<"$codecfiles") -ne 1 ]]; then fail "pipewire-codec-aptx ships more than the codec module"; fi

. "$dir/SOURCE.env"
evr=${PIPEWIRE_EVR:?SOURCE.env has no PIPEWIRE_EVR}
isa=$(rpm --eval '%{?_isa}')
pin=$(rpm -qp --requires "${rpms[pipewire-codec-aptx]}" | awk -v n="pipewire-libs$isa" '$1 == n && $2 == "=" { print $3 }')
if [[ $pin != "$evr" ]]; then fail "pipewire-codec-aptx requires pipewire-libs$isa = '$pin', SOURCE.env pins $evr"; fi
if [[ $(rpm -qp --qf '%{VERSION}-%{RELEASE}' "${rpms[pipewire-codec-aptx]}") != "$evr.microos" ]]; then fail "pipewire-codec-aptx is not $evr.microos"; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rpmkeys --dbpath "$tmp/db" --import /etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-44-primary
pinned=("${rpms[libfreeaptx]}" "${rpms[pipewire-codec-aptx]}")
pin_rpms() {
  local pkg=$1 evr=$2 list=$3 name sum f have
  local -a want=()
  while read -r name sum; do
    if [[ -n $name ]]; then want+=("$name-$evr.$arch"); fi
  done <<<"$list"
  have=$(dnf -q repoquery --qf '%{name}-%{evr}.%{arch}\n' "${want[@]}")
  while read -r name sum; do
    [[ -n $name ]] || continue
    if grep -qxF "$name-$evr.$arch" <<<"$have"; then
      pinned+=("$name-$evr.$arch")
      continue
    fi
    f=$tmp/$name-$evr.$arch.rpm
    curl -fsSL --retry 5 --retry-all-errors -o "$f" "$KOJI_URL/$pkg/${evr%%-*}/${evr#*-}/data/signed/$KOJI_KEY/$arch/$name-$evr.$arch.rpm"
    if [[ $arch == aarch64 ]]; then
      echo "$sum  $f" | sha256sum -c --quiet - || { echo "FAIL: $name-$evr.$arch from koji fails sha256" >&2; exit 1; }
    elif [[ $(rpmkeys --dbpath "$tmp/db" --checksig "$f") != "$f: digests signatures OK" ]]; then
      echo "FAIL: $name-$evr.$arch from koji is not signed by the Fedora 44 key" >&2
      exit 1
    fi
    pinned+=("$f")
  done <<<"$list"
}
pin_rpms pipewire "$evr" "$PIPEWIRE_RPMS"
pin_rpms wireplumber "$WIREPLUMBER_EVR" "$WIREPLUMBER_RPMS"
dnf -yq --setopt=install_weak_deps=False install "${pinned[@]}" >/dev/null
if ldd "$codec" | grep -q 'not found'; then fail "$codec has unresolved libraries"; fi
if ! spa-inspect "$codec" 2>&1 | grep -qF "factory name:		'api.codec.bluez5.media.aptx'"; then fail "spa-inspect does not load the aptX factory"; fi

exit "$rc"
