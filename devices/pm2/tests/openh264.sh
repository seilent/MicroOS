#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
script=$tree/usr/libexec/microos/microos-openh264
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

for t in python3 rpmbuild rpmsign gpg rpmkeys rpm2cpio cpio; do
  command -v "$t" > /dev/null || { echo "FAIL: $t missing" >&2; exit 1; }
done

tmp=$(mktemp -d)
trap 'gpgconf --kill all > /dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
export GNUPGHOME=$tmp/gnupg
mkdir -m 700 "$GNUPGHOME"
for k in good other; do
  gpg --batch --quiet --passphrase '' --quick-gen-key "$k <$k@test>" rsa2048 sign never 2> /dev/null
done
mkdir -p "$tmp/keys" "$tmp/otherkeys"
gpg --batch --armor --export good@test > "$tmp/keys/RPM-GPG-KEY-fedora-44-primary"
gpg --batch --armor --export other@test > "$tmp/otherkeys/RPM-GPG-KEY-fedora-44-primary"

mkrpm() {
  local ver=$1 rel=$2 arch=$3 out=$4 extra=${5:-}
  local top=$tmp/rpmbuild-$ver-$rel-$arch
  mkdir -p "$top"
  cat > "$top/openh264.spec" <<EOF
%global debug_package %{nil}
%global __os_install_post %{nil}
Name: openh264
Version: $ver
Release: $rel
Summary: test
License: BSD-2-Clause
%description
test
%install
mkdir -p %{buildroot}/usr/lib64 %{buildroot}/usr/share/doc/openh264
printf '\177ELFtest-$ver' > %{buildroot}/usr/lib64/libopenh264.so.$ver
ln -s libopenh264.so.$ver %{buildroot}/usr/lib64/libopenh264.so.8
echo readme > %{buildroot}/usr/share/doc/openh264/README.md
$extra
%files
/usr/lib64/libopenh264.so*
/usr/share/doc/openh264/README.md
EOF
  rpmbuild -bb --quiet --target "$arch" --define "_topdir $top" "$top/openh264.spec" > /dev/null 2>&1 \
    || { echo "FAIL: fixture rpmbuild $ver $arch" >&2; exit 1; }
  cp "$top"/RPMS/*/openh264-*.rpm "$out"
}
sign() {
  rpmsign --addsign --define "_gpg_name $1@test" --define "_gpg_path $GNUPGHOME" "$2" > /dev/null 2>&1 \
    || { echo "FAIL: rpmsign $1" >&2; exit 1; }
}

srv=$tmp/srv
repo=$srv/repo
mkdir -p "$repo/repodata" "$repo/Packages/o"
publish() {
  local rpm=$1 ver=$2 rel=$3 arch=$4 sum
  cp "$rpm" "$repo/Packages/o/openh264-$ver-$rel.$arch.rpm"
  sum=${PKG_SUM:-$(sha256sum < "$rpm" | cut -d' ' -f1)}
  python3 - "$repo" "$ver" "$rel" "$arch" "$sum" "${REPOMD_SUM:-}" "${PRIMARY_PAD:-0}" <<'PY'
import hashlib, os, sys
from compression import zstd
repo, ver, rel, arch, sum_, bad, pad = sys.argv[1:]
pkgs = ""
for name in ("mozilla-openh264", "openh264", "openh264-devel"):
    pkgs += f"""<package type="rpm"><name>{name}</name><arch>{arch}</arch>
<version epoch="0" ver="{ver}" rel="{rel}"/><checksum type="sha256" pkgid="YES">{sum_ if name == "openh264" else "0" * 64}</checksum>
<location href="Packages/o/{name}-{ver}-{rel}.{arch}.rpm"/></package>
"""
prim = f'<?xml version="1.0"?><metadata xmlns="http://linux.duke.edu/metadata/common" packages="3">{pkgs}{" " * int(pad)}</metadata>'.encode()
z = zstd.compress(prim)
zs = hashlib.sha256(z).hexdigest()
for f in os.listdir(f"{repo}/repodata"):
    os.unlink(f"{repo}/repodata/{f}")
open(f"{repo}/repodata/{zs}-primary.xml.zst", "wb").write(z)
md = f"""<?xml version="1.0" encoding="UTF-8"?>
<repomd xmlns="http://linux.duke.edu/metadata/repo"><data type="primary"><checksum type="sha256">{zs}</checksum>
<location href="repodata/{zs}-primary.xml.zst"/></data></repomd>""".encode()
open(f"{repo}/repodata/repomd.xml", "wb").write(md)
ms = bad or hashlib.sha256(md).hexdigest()
ml = f"""<?xml version="1.0" encoding="utf-8"?>
<metalink version="3.0" xmlns="http://www.metalinker.org/"><files><file name="repomd.xml"><verification>
<hash type="md5">x</hash><hash type="sha256">{ms}</hash></verification><resources>
<url protocol="http" type="http" preference="100">http://plain.test/44/{arch}/repodata/repomd.xml</url>
<url protocol="https" type="https" preference="90">https://dead.test/44/{arch}/repodata/repomd.xml</url>
<url protocol="https" type="https" preference="80">https://repo.test/44/{arch}/repodata/repomd.xml</url>
</resources></file></files></metalink>"""
open(f"{os.path.dirname(repo)}/metalink.xml", "w").write(ml)
PY
}

mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while (( $# )); do
  case $1 in
    -o) out=$2; shift ;;
    --proto|--connect-timeout|--max-time|--max-filesize|-w) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
echo "$url" >> "$STUB_SRV/calls"
[[ -z ${STUB_OFFLINE:-} ]] || exit 6
case $url in
  https://mirrors.test/metalink*) cp "$STUB_SRV/metalink.xml" "$out" ;;
  https://repo.test/44/*/Packages/*) printf 'http://cdn.test/%s' "${url##*/}" ;;
  https://cdn.test/*) cp "$STUB_SRV/repo/Packages/o/${url##*/}" "$out" 2> /dev/null || exit 22 ;;
  https://repo.test/44/*/*) cp "$STUB_SRV/repo/${url#https://repo.test/44/*/}" "$out" 2> /dev/null || exit 22 ;;
  *) exit 6 ;;
esac
EOF
chmod 755 "$tmp/bin/curl"

dir=$tmp/lib
mkdir "$dir"
printf 'NAME=MicroOS\nVERSION_ID=44\n' > "$tmp/os-release"
export PATH=$tmp/bin:$PATH STUB_SRV=$srv
export MICROOS_OPENH264_DIR=$dir MICROOS_OPENH264_KEYDIR=$tmp/keys MICROOS_OPENH264_OS_RELEASE=$tmp/os-release
export MICROOS_OPENH264_ARCH=aarch64 MICROOS_OPENH264_METALINK=https://mirrors.test/metalink MICROOS_OPENH264_ATTEMPTS=2
export MICROOS_OPENH264_RETRY_WAIT=0
run() { r=0; : > "$srv/calls"; "$script" > "$tmp/out" 2>&1 || r=$?; }
state() { (cd "$dir" && for f in $(ls -A | sort); do if [[ -L $f ]]; then echo "$f -> $(readlink "$f")"; else echo "$f $(stat -c %a "$f") $(sha256sum < "$f" | cut -c1-16)"; fi; done); }

mkrpm 2.6.0 3.fc44 aarch64 "$tmp/good.rpm"
sign good "$tmp/good.rpm"
publish "$tmp/good.rpm" 2.6.0 3.fc44 aarch64
run
[[ $r == 0 ]] || fail "good: exit $r $(cat "$tmp/out")"
[[ $(cat "$tmp/out") == "microos-openh264: installed openh264 2.6.0-3.fc44 (libopenh264.so.8) from https://repo.test/44/aarch64/" ]] \
  || fail "good: log $(cat "$tmp/out")"
[[ $(readlink "$dir/libopenh264.so.8") == libopenh264.so.2.6.0 ]] || fail "good: soname link"
[[ $(stat -c %a "$dir/libopenh264.so.2.6.0") == 644 ]] || fail "good: lib mode"
[[ $(head -c4 "$dir/libopenh264.so.2.6.0" | od -An -tx1 | tr -d ' ') == 7f454c46 ]] || fail "good: lib content"
[[ $(< "$dir/version") == 2.6.0-3.fc44 ]] || fail "good: version file"
[[ $(ls -A "$dir" | sort | paste -sd' ') == "libopenh264.so.2.6.0 libopenh264.so.8 version" ]] || fail "good: dir holds $(ls -A "$dir")"
grep -qx 'https://dead.test/44/aarch64/repodata/repomd.xml' "$srv/calls" || fail "good: preferred https mirror not tried first"
! grep -q 'plain.test' "$srv/calls" || fail "good: an http mirror was used"
grep -qx 'https://cdn.test/openh264-2.6.0-3.fc44.aarch64.rpm' "$srv/calls" || fail "good: the http redirect was not taken as https"
! grep -q '^http://' "$srv/calls" || fail "good: a plain http fetch"
good_state=$(state)

run
[[ $r == 0 && $(cat "$tmp/out") == "microos-openh264: openh264 2.6.0-3.fc44 up to date" ]] || fail "rerun: $r $(cat "$tmp/out")"
! grep -qE '/Packages/|cdn.test' "$srv/calls" || fail "rerun: the RPM was downloaded again"

mkrpm 2.6.0 3.fc44 aarch64 "$tmp/other.rpm"
sign other "$tmp/other.rpm"
mkrpm 2.6.1 1.fc44 aarch64 "$tmp/bad.rpm"
sign other "$tmp/bad.rpm"
publish "$tmp/bad.rpm" 2.6.1 1.fc44 aarch64
run
[[ $r == 1 ]] && grep -q '^microos-openh264: refused: signature check failed' "$tmp/out" || fail "bad sig: $r $(cat "$tmp/out")"
[[ $(state) == "$good_state" ]] || fail "bad sig: the installed lib changed"
[[ $(grep -c 'mirrors.test' "$srv/calls") == 1 ]] || fail "bad sig: retried"

mkrpm 2.6.1 1.fc44 aarch64 "$tmp/unsigned.rpm"
publish "$tmp/unsigned.rpm" 2.6.1 1.fc44 aarch64
run
[[ $r == 1 ]] && grep -q '^microos-openh264: refused: signature check failed' "$tmp/out" || fail "unsigned: $r $(cat "$tmp/out")"
[[ $(state) == "$good_state" ]] || fail "unsigned: the installed lib changed"

mkrpm 2.6.1 1.fc44 x86_64 "$tmp/arch.rpm"
sign good "$tmp/arch.rpm"
publish "$tmp/arch.rpm" 2.6.1 1.fc44 aarch64
run
[[ $r == 1 ]] && grep -q "refused: package is 'openh264 x86_64 2.6.1-1.fc44'" "$tmp/out" || fail "wrong arch: $r $(cat "$tmp/out")"
[[ $(state) == "$good_state" ]] || fail "wrong arch: the installed lib changed"

mkrpm 2.6.1 1.fc44 aarch64 "$tmp/extra.rpm" 'printf "\177ELF" > %{buildroot}/usr/lib64/libopenh264.so.9'
sign good "$tmp/extra.rpm"
publish "$tmp/extra.rpm" 2.6.1 1.fc44 aarch64
run
[[ $r == 1 ]] && grep -q 'refused: unexpected files in the package' "$tmp/out" || fail "extra lib: $r $(cat "$tmp/out")"
[[ $(state) == "$good_state" ]] || fail "extra lib: the installed lib changed"

mkrpm 2.6.1 1.fc44 aarch64 "$tmp/new.rpm"
sign good "$tmp/new.rpm"
PKG_SUM=$(printf '0%.0s' {1..64}) publish "$tmp/new.rpm" 2.6.1 1.fc44 aarch64
run
[[ $r == 1 ]] && grep -q '^microos-openh264: failed after 2 attempts: .*sha256 differs from the repo metadata' "$tmp/out" \
  || fail "rpm sha256 mismatch: $r $(cat "$tmp/out")"
[[ $(grep -c 'mirrors.test' "$srv/calls") == 2 ]] || fail "rpm sha256 mismatch: not retried twice"
[[ $(state) == "$good_state" ]] || fail "rpm sha256 mismatch: the installed lib changed"

REPOMD_SUM=$(printf 'f%.0s' {1..64}) publish "$tmp/new.rpm" 2.6.1 1.fc44 aarch64
run
[[ $r == 1 ]] && grep -q 'repomd.xml sha256 differs from the metalink' "$tmp/out" || fail "repomd mismatch: $r $(cat "$tmp/out")"
! grep -q '/Packages/' "$srv/calls" || fail "repomd mismatch: the RPM was fetched"

publish "$tmp/new.rpm" 2.6.1 1.fc44 aarch64
STUB_OFFLINE=1 run
[[ $r == 1 ]] && grep -q '^microos-openh264: failed after 2 attempts: https://mirrors.test/metalink: curl exit 6' "$tmp/out" \
  || fail "offline: $r $(cat "$tmp/out")"
[[ $(wc -l < "$srv/calls") == 2 ]] || fail "offline: $(wc -l < "$srv/calls") fetches, not 2"
[[ $(state) == "$good_state" ]] || fail "offline: the installed lib changed"

run
[[ $r == 0 ]] && grep -q 'installed openh264 2.6.1-1.fc44' "$tmp/out" || fail "upgrade: $r $(cat "$tmp/out")"
[[ $(ls -A "$dir" | sort | paste -sd' ') == "libopenh264.so.2.6.1 libopenh264.so.8 version" ]] || fail "upgrade: dir holds $(ls -A "$dir")"
[[ $(readlink "$dir/libopenh264.so.8") == libopenh264.so.2.6.1 && $(< "$dir/version") == 2.6.1-1.fc44 ]] || fail "upgrade: link or version"
new_state=$(state)

publish "$tmp/good.rpm" 2.6.0 3.fc44 aarch64
run
[[ $r == 1 ]] && grep -q '^microos-openh264: refused: repo offers openh264 2.6.0-3.fc44, older than the installed 2.6.1-1.fc44$' "$tmp/out" \
  || fail "downgrade: $r $(cat "$tmp/out")"
! grep -qE '/Packages/|cdn.test' "$srv/calls" || fail "downgrade: the RPM was fetched"
[[ $(state) == "$new_state" ]] || fail "downgrade: the installed lib changed"

PRIMARY_PAD=17000000 publish "$tmp/new.rpm" 2.6.2 1.fc44 aarch64
[[ $(stat -c %s "$repo"/repodata/*-primary.xml.zst) -lt 1048576 ]] || fail "bomb fixture is not small"
run
[[ $r == 1 ]] && grep -q 'refused: repodata/.*-primary.xml.zst unpacks to more than 16777216 bytes' "$tmp/out" \
  || fail "zstd bomb: $r $(cat "$tmp/out")"
[[ $(state) == "$new_state" ]] || fail "zstd bomb: the installed lib changed"

MICROOS_OPENH264_KEYDIR=$tmp/none run
[[ $r == 1 ]] && grep -q "refused: no $tmp/none/RPM-GPG-KEY-fedora-44-primary" "$tmp/out" || fail "no key: $r $(cat "$tmp/out")"
[[ ! -s $srv/calls ]] || fail "no key: fetched anyway"
MICROOS_OPENH264_DIR=$tmp/missing run
[[ $r == 1 ]] && grep -q "refused: no $tmp/missing" "$tmp/out" || fail "no dir: $r $(cat "$tmp/out")"
printf 'NAME=MicroOS\n' > "$tmp/os-release"
run
[[ $r == 1 ]] && grep -q 'refused: no numeric VERSION_ID' "$tmp/out" || fail "no VERSION_ID: $r $(cat "$tmp/out")"

! grep -nE 'time\.time|datetime|perf_counter|/etc/' "$script" || fail "the script reads the wall clock or /etc"
[[ $(stat -c %a "$script") == 755 ]] || fail "script mode"
key=$tree/usr/share/microos/openh264/RPM-GPG-KEY-fedora-44-primary
db=$tmp/realdb
mkdir "$db"
rpmkeys --dbpath "$db" --import "$key" || fail "shipped key does not import"
[[ $(rpm --dbpath "$db" -q gpg-pubkey --qf '%{VERSION}\n') == 36f612dcf27f7d1a48a835e4dbfcf71c6d9f90a6 ]] \
  || fail "shipped key is not the Fedora 44 primary key"

exit "$rc"
