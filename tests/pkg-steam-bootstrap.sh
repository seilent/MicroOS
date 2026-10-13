#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-steam-bootstrap.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"
version=${STEAM_CLIENT_VERSION:?SOURCE.env has no STEAM_CLIENT_VERSION}
vdf=$dir/$STEAM_MANIFEST.$version.vdf

rpm=$(find "$dir" -maxdepth 1 -name "microos-steam-seed-$version-*.aarch64.rpm")
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 ]]; then
  echo "FAIL: expected one microos-steam-seed RPM in $dir" >&2
  exit 1
fi
if [[ -n $(find "$dir" -maxdepth 1 \( -name '*.src.rpm' -o -name '*-debuginfo-*' -o -name '*-debugsource-*' \)) ]]; then fail "SRPM or debug RPM present"; fi
if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "release"; fi
if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi
writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi
files=$(rpm -qlp "$rpm")
want=$'/usr/share/licenses/microos-steam-seed/steam_subscriber_agreement.txt\n/usr/share/microos-seed\n/usr/share/microos-seed/steam-seed.tar.zst\n/usr/share/microos-seed/steam-seed.version'
if [[ $(sort <<<"$files") != "$want" ]]; then fail "file list: $files"; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(cd "$tmp" && rpm2cpio "$rpm" | cpio -idm --quiet)
seed=$tmp/usr/share/microos-seed
if [[ $(cat "$seed/steam-seed.version") != "$version $STEAM_RUNTIME_VERSION" ]]; then fail "version file"; fi

listing=$(zstd -dcq "$seed/steam-seed.tar.zst" | tar -tv --numeric-owner)
owners=$(awk '{print $2}' <<<"$listing" | sort -u)
if [[ $owners != 1000/1000 ]]; then fail "owners: $owners"; fi
bad=$(awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w") {print $6}' <<<"$listing" | head)
if [[ -n $bad ]]; then fail "group or other writable in the seed: $bad"; fi
tops=$(awk '{split($6, p, "/"); print p[1]}' <<<"$listing" | sort -u | tr '\n' ' ')
if [[ $tops != ".local .steam " ]]; then fail "seed roots: $tops"; fi

home=$tmp/home
mkdir "$home"
zstd -dcq "$seed/steam-seed.tar.zst" | tar -x -C "$home"
steam=$home/.local/share/Steam

for l in steam root sdk32 sdk64 sdkarm64 bin32 bin64; do
  p=$home/.steam/$l
  if [[ ! -L $p ]] || [[ $(realpath -e "$p" 2>/dev/null) != "$steam"* ]]; then fail "link .steam/$l"; fi
done
ibus=$steam/lib/aarch64-linux-gnu/libibus-1.0.so.5
if [[ ! -L $ibus ]] || [[ $(realpath -e "$ibus" 2>/dev/null) != "$steam/steam-runtime-steamrt-arm64/"* ]]; then fail "libibus link"; fi
for f in steamrtarm64/steam steamrtarm64/steamwebhelper steamrtarm64/steamwebhelper.sh steam-runtime-steamrt-arm64/bin/steam-runtime-launcher-service; do
  [[ -f $steam/$f && -x $steam/$f ]] || fail "not executable: $f"
done

if ! cmp -s "$vdf" "$steam/package/$STEAM_MANIFEST.manifest"; then fail "package manifest differs from the pinned one"; fi
echo "$STEAM_MANIFEST_SHA256  $vdf" | sha256sum -c --quiet - || fail "pinned manifest sha256"
if [[ -n $(find "$steam/logs" -type f 2>/dev/null) ]]; then fail "files under logs/"; fi
for f in "$steam/config/loginusers.vdf" "$steam/package/steam_client_metrics.bin" "$home/.steam/steam.pid"; do
  [[ ! -e $f ]] || fail "present: ${f#"$home"/}"
done
reg=$(tr -d '\t\n' < "$home/.steam/registry.vdf" 2>/dev/null || true)
if [[ $reg != '"Registry"{"HKCU"{"Software"{"Valve"{"Steam"{"CompletedOOBEStage1""0""CompletedOOBE""0"}}}}}' ]]; then fail ".steam/registry.vdf: $reg"; fi
left=$(find "$home" \( -name '*.token' -o -name 'ssfn*' -o -name '*\\*' -o -type s -o -type p \) | head)
if [[ -n $left ]]; then fail "tokens, sockets or stray names: $left"; fi

python3 - "$vdf" "$version" "$steam" "$STEAM_MANIFEST" "$STEAM_RUNTIME_VERSION" <<'PY' || rc=1
import gzip, hashlib, os, re, stat, sys, zlib

vdf, version, steam, manifest, runtime = sys.argv[1:]
errors = []


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def crc32(p):
    c = 0
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            c = zlib.crc32(b, c)
    return c


text = open(vdf, encoding="utf-8").read()
if re.search(r'"version"\s+"(\d+)"', text).group(1) != version:
    errors.append("pinned manifest version")
packages = 0
for name, body in re.findall(r'"(\w+)"\s*\{([^{}]*)\}', text):
    kv = dict(re.findall(r'"(\w+)"\s+"([^"\n]*)"', body))
    if "file" not in kv:
        continue
    packages += 1
    fname, digest = (kv["zipvz"], kv["sha2vz"]) if "zipvz" in kv else (kv["file"], kv["sha2"])
    p = os.path.join(steam, "package", fname)
    if not os.path.isfile(p):
        errors.append(f"package {name}: {fname} missing")
    elif "zipvz" not in kv and os.path.getsize(p) != int(kv["size"]):
        errors.append(f"package {name}: size")
    elif sha256(p) != digest:
        errors.append(f"package {name}: sha256")

entries = 0
for line in open(os.path.join(steam, "package", manifest + ".installed"), encoding="utf-8", errors="replace").read().splitlines():
    m = re.fullmatch(r"(.+),(-?\d+);\d+;(\d+)", line)
    if not m:
        continue
    entries += 1
    rel, size, crc = m.group(1), int(m.group(2)), int(m.group(3))
    p = os.path.join(steam, rel)
    try:
        st = os.lstat(p)
    except OSError:
        errors.append(f"installed {rel}: missing")
        continue
    if size == -1:
        ok = stat.S_ISDIR(st.st_mode)
    elif size == -2:
        ok = stat.S_ISLNK(st.st_mode)
    elif size >= 0:
        ok = stat.S_ISREG(st.st_mode) and st.st_size == size and crc32(p) == crc
    else:
        ok = True
    if not ok:
        errors.append(f"installed {rel}: differs")

rt = os.path.join(steam, "steam-runtime-steamrt-arm64")
checked = 0


def mtree(path, base):
    global checked
    for line in gzip.open(path, "rt", encoding="utf-8").read().splitlines():
        if not line.startswith("./"):
            continue
        name, *fields = line.split(" ")
        kv = dict(f.split("=", 1) for f in fields if "=" in f)
        if kv.get("type") != "file" or "sha256" not in kv or "optional" in fields:
            continue
        name = re.sub(r"\\(\d{3})", lambda m: chr(int(m.group(1), 8)), kv.get("contents", name))
        p = os.path.join(base, name)
        checked += 1
        if not os.path.isfile(p) or sha256(p) != kv["sha256"]:
            errors.append(f"runtime {os.path.relpath(p, rt)}: sha256")


mtree(os.path.join(rt, "mtree.txt.gz"), rt)
platform = os.path.join(rt, f"steamrt3c_platform_{runtime}")
mtree(os.path.join(platform, "usr-mtree.txt.gz"), os.path.join(platform, "files"))
if not re.search(rf"^depot\s+{re.escape(runtime)}\s", open(os.path.join(rt, "VERSIONS.txt")).read(), re.M):
    errors.append("runtime VERSIONS.txt")

for e in errors[:30]:
    print("FAIL:", e, file=sys.stderr)
print(f"{packages} packages, {entries} installed entries, {checked} runtime files checked, {len(errors)} errors")
sys.exit(1 if errors or not packages or not entries or not checked else 0)
PY

exit "$rc"
