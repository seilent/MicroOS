#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-es-de.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"
version=${ESDE_VERSION:?SOURCE.env has no ESDE_VERSION}
arch=$(uname -m)

rpm=$(find "$dir" -maxdepth 1 -name "es-de-$version-*.microos.$arch.rpm")
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 ]]; then
  echo "FAIL: expected one es-de $arch RPM in $dir" >&2
  exit 1
fi
srpm=$(find "$dir" -maxdepth 1 -name "es-de-$version-*.src.rpm")
if [[ -z $srpm || $(wc -l <<<"$srpm") -ne 1 ]]; then
  echo "FAIL: expected one es-de SRPM in $dir" >&2
  exit 1
fi
others=$(find "$dir" -maxdepth 1 -name '*.rpm' ! -samefile "$rpm" ! -samefile "$srpm")
if [[ -n $others ]]; then fail "other RPMs: $others"; fi

if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi
if [[ $(rpm -qp --qf '%{SOURCERPM}' "$rpm") != "${srpm##*/}" ]]; then fail "SOURCERPM"; fi
listed=$(grep -o '`[0-9]\{4\}-[^`]*\.patch`' "$dir/PATCHES.md" | tr -d '`' | sort -u)
carried=$(rpm -qp --qf '[%{PATCH}\n]' "$srpm" | sort -u)
if [[ -z $listed || $listed != "$carried" ]]; then fail "SRPM patches differ from PATCHES.md: $carried"; fi
if ! rpm -qp --qf '[%{SOURCE}\n]' "$srpm" | grep -qx escape-test.cpp; then fail "SRPM lacks escape-test.cpp"; fi

writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi

files=$(rpm -qlp "$rpm")
for f in \
  /usr/bin/es-de \
  /usr/bin/es-pdf-convert \
  /usr/share/licenses/es-de/LICENSE \
  /usr/share/es-de/resources/systems/linux/es_systems.xml \
  /usr/share/es-de/resources/systems/linux/es_find_rules.xml \
  /usr/share/es-de/themes/linear-es-de/theme.xml; do
  if ! grep -qx "$f" <<<"$files"; then fail "missing $f"; fi
done
if grep -qiE 'appimage|AppRun|/opt/|\.so(\.[0-9]+)*$' <<<"$files"; then fail "bundled libraries or AppImage files: $(grep -iE 'appimage|AppRun|/opt/|\.so(\.[0-9]+)*$' <<<"$files" | head -n5)"; fi

requires=$(rpm -qp --requires "$rpm")
for lib in libavcodec libavformat libfreeimage libgit2 libpoppler-cpp libpugixml libSDL2-2.0 libcurl libharfbuzz libfreetype; do
  if ! grep -q "^$lib\.so" <<<"$requires"; then fail "does not link the Fedora $lib"; fi
done

dnf -yq --setopt=install_weak_deps=False install "$rpm" >/dev/null || { echo "FAIL: es-de does not install from the Fedora repos" >&2; exit 1; }
for b in /usr/bin/es-de /usr/bin/es-pdf-convert; do
  if ldd "$b" | grep -q 'not found'; then fail "$b has unresolved libraries"; fi
done

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
out=$(es-de --home "$home" --version 2>&1) || fail "es-de --version exit $?"
if ! grep -q "$version" <<<"$out"; then fail "es-de --version: $out"; fi

exit "$rc"
