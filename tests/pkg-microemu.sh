#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-microemu.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

rpm=$(find "$dir" -maxdepth 1 -name 'microemu-0^*.noarch.rpm')
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 ]]; then
  echo "FAIL: expected one microemu noarch RPM in $dir" >&2
  exit 1
fi
srpm=$(find "$dir" -maxdepth 1 -name 'microemu-0^*.src.rpm')
if [[ -z $srpm || $(wc -l <<<"$srpm") -ne 1 ]]; then
  echo "FAIL: expected one microemu SRPM in $dir" >&2
  exit 1
fi
others=$(find "$dir" -maxdepth 1 -name '*.rpm' ! -samefile "$rpm" ! -samefile "$srpm")
if [[ -n $others ]]; then fail "other RPMs: $others"; fi

if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "release"; fi
if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi
if [[ $(rpm -qp --qf '%{SOURCERPM}' "$rpm") != "${srpm##*/}" ]]; then fail "SOURCERPM"; fi
if [[ $(rpm -qp --qf '%{LICENSE}' "$rpm") != GPL-2.0-or-later* ]]; then fail "license tag"; fi
if ! rpm -qp --qf '[%{SOURCE}\n]' "$srpm" | grep -q '^microemu-assets-.*\.tar\.gz$'; then fail "SRPM lacks the assets tarball"; fi

writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi

requires=$(rpm -qp --requires "$rpm" | awk '{ print $1 }')
need=(es-de retroarch gamescope-session microset python3 python3-gobject python3-cairo gtk3 pango gobject-introspection xprop pulseaudio-utils wireplumber)
for r in "${need[@]}"; do
  if ! grep -qx "$r" <<<"$requires"; then fail "does not require $r"; fi
done

files=$(rpm -qlp "$rpm")
for f in \
  /usr/share/licenses/microemu/LICENSE \
  /usr/share/licenses/microemu/art-book-next.txt \
  /usr/share/licenses/microemu/art-book-next-speaker.txt \
  /usr/share/licenses/microemu/slang-shaders/AUDIT \
  /usr/share/licenses/microemu/retro-crisis/LICENSE \
  /usr/lib/microos/sessions.d/microemu.conf \
  /usr/lib/microos/hotkeys.d/microemu.conf \
  /usr/lib/microos/hotkeys.d/steam.conf.d/50-microemu.conf \
  /usr/lib/microos/hotkeys.d/microdap.conf.d/50-microemu.conf \
  /usr/share/microset/schema.d/50-microemu.json \
  /usr/share/wayland-sessions/microemu.desktop \
  /usr/share/gamescope-session-plus/sessions.d/microemu \
  /usr/lib/systemd/user/microemu-lc.service \
  /usr/libexec/microemu/microemu-client \
  /usr/libexec/microemu/microemu-reconcile \
  /usr/libexec/microemu/microemu-gamescope \
  /usr/libexec/microemu/microemu-osd \
  /usr/libexec/microemu/microemu-lc \
  /usr/libexec/microemu/bin/retroarch \
  /usr/share/microemu/es-de/es_systems.xml \
  /usr/share/microemu/retroarch/microemu.cfg \
  /usr/share/microemu/osd/speaker.svg \
  /usr/share/microemu/es-de/themes/art-book-next-es-de/theme.xml \
  /usr/share/microemu/es-de/themes/art-book-next-es-de/_inc/fonts/Mulish-Light.ttf; do
  if ! grep -qxF "$f" <<<"$files"; then fail "missing $f"; fi
done
if grep -qE '^/usr/lib/(armada|extension-release\.d|extensions)|^/var/|^/etc/|^/usr/lib/microemu(/|$)' <<<"$files"; then
  fail "sysext, Armada or bundled tree paths: $(grep -E '^/usr/lib/(armada|extension-release\.d|extensions)|^/var/|^/etc/|^/usr/lib/microemu(/|$)' <<<"$files" | head -n5)"
fi
for f in microemu-apk microemu-play-run microemu-sideload microemu-guard microemu-hotkeyd microemu-leave microemu-pad-nodes; do
  if grep -q "/$f\$" <<<"$files"; then fail "removed or Android file $f installed"; fi
done
if grep -qE '/(lcd-grid-v2\.slang|pixel_transparency\.slang)$' <<<"$files"; then fail "an LCD shader without a license grant is shipped"; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rpm2cpio "$rpm" > "$tmp/microemu.cpio"
(cd "$tmp" && cpio -idm --quiet < microemu.cpio)
root=$tmp

elf=$(find "$root/usr" -type f -exec sh -c 'for f; do if [ "$(head -c4 "$f" | od -An -tx1 | tr -d " ")" = 7f454c46 ]; then echo "$f"; fi; done' sh {} +)
if [[ -n $elf ]]; then fail "ELF files shipped (bundled RetroArch or cores): ${elf//$root/}"; fi

for f in "$root"/usr/libexec/microemu/* "$root"/usr/libexec/microemu/bin/*; do
  [[ -f $f ]] || continue
  if [[ $(stat -c %a "$f") != 755 ]]; then fail "${f#"$root"} is not 755"; fi
done

app=("$root/usr/libexec/microemu" "$root/usr/lib/microos" "$root/usr/lib/systemd" "$root/usr/share/gamescope-session-plus" \
  "$root/usr/share/wayland-sessions" "$root/usr/share/microemu/es-de/es_systems.xml" "$root/usr/share/microemu/retroarch")
hits=$(grep -rlE 'armada|/run/armada|session-control|date \+%s|EPOCHREALTIME' "${app[@]}" || true)
if [[ -n $hits ]]; then fail "Armada names or wall clock waits in: ${hits//$root/}"; fi

conf=$root/usr/lib/microos/sessions.d/microemu.conf
for kv in LABEL=MicroEMU DESKTOP=microemu.desktop UNIT=gamescope-session-plus@microemu.service STOP=unit DEFAULT=yes GAME_SCOPE=microemu-game.scope; do
  if ! grep -qx "$kv" "$conf"; then fail "sessions.d/microemu.conf lacks $kv"; fi
done
if ! grep -qx 'Exec=gamescope-session-plus microemu' "$root/usr/share/wayland-sessions/microemu.desktop"; then fail "desktop Exec"; fi
client=$root/usr/share/gamescope-session-plus/sessions.d/microemu
if grep -q short_session_recover "$client"; then fail "client file sets short_session_recover"; fi
if grep -q -- '--steam' "$client"; then fail "client file passes --steam"; fi
if ! grep -q 'CLIENTCMD=/usr/libexec/microemu/microemu-client' "$client"; then fail "client file CLIENTCMD"; fi
if ! grep -q '/usr/bin/es-de' "$root/usr/libexec/microemu/microemu-client"; then fail "microemu-client does not run /usr/bin/es-de"; fi
if ! grep -q '/usr/bin/retroarch' "$root/usr/libexec/microemu/bin/retroarch"; then fail "the RetroArch wrapper does not run /usr/bin/retroarch"; fi

python3 - "$root" <<'PY' || rc=1
import json, sys
import xml.etree.ElementTree as ET

root = sys.argv[1]
rc = 0
def fail(msg):
    global rc
    print(f"FAIL: {msg}", file=sys.stderr)
    rc = 1

doc = json.load(open(f"{root}/usr/share/microset/schema.d/50-microemu.json"))
if doc.get("owner") != "microemu":
    fail("schema owner is not microemu")
types = {"s": str, "b": bool, "u": int, "i": int, "d": (int, float), "as": list}
keys = doc.get("keys") or {}
if "microemu.orientation" not in keys:
    fail("schema lacks microemu.orientation")
elif sorted(keys["microemu.orientation"].get("enum", [])) != ["landscape", "landscape-flipped"]:
    fail("microemu.orientation enum")
for key, k in keys.items():
    if not key.startswith("microemu."):
        fail(f"schema key {key} outside microemu.")
    t = k.get("type")
    d = k.get("default")
    if t not in types or d is None or not isinstance(d, types[t]) or (t != "b" and isinstance(d, bool)):
        fail(f"schema {key}: default {d!r} is not {t}")
    elif "enum" in k and d not in k["enum"]:
        fail(f"schema {key}: default {d!r} not in enum")

text = open(f"{root}/usr/share/microemu/es-de/es_systems.xml").read()
systems = ET.fromstring("<root>" + text.split("?>", 1)[-1] + "</root>")
names = [s.findtext("name") for s in systems.iter("system")]
if "androidgames" in names:
    fail("es_systems.xml has the androidgames system")
if "microos" not in names:
    fail("es_systems.xml has no microos system")
cores = set()
for c in systems.iter("command"):
    words = (c.text or "").split()
    if words[:1] == ["/usr/libexec/microemu/bin/retroarch"]:
        if "-L" not in words:
            fail(f"retroarch command without -L: {c.text}")
            continue
        cores.add(words[words.index("-L") + 1])
with open(f"{root}/cores", "w") as f:
    f.write("\n".join(sorted(cores)) + "\n")
if not cores:
    fail("no RetroArch cores in es_systems.xml")
sys.exit(rc)
PY

mapfile -t deps < <(find /deps -maxdepth 1 -name 'microset-0^*.rpm' ! -name '*.src.rpm' 2> /dev/null)
if (( ${#deps[@]} != 1 )); then
  fail "no microset RPMs in /deps for the schema check"
elif ! dnf -yq --setopt=install_weak_deps=False install "${deps[@]}" > "$tmp/dnf.log" 2>&1; then
  fail "microset RPMs do not install: $(tail -n3 "$tmp/dnf.log")"
else
  install -D -m644 "$root/usr/share/microset/schema.d/50-microemu.json" /usr/share/microset/schema.d/50-microemu.json
  cat > "$tmp/bus.conf" <<BUS
<busconfig>
  <type>system</type>
  <listen>unix:path=$tmp/bus</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="*"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
BUS
  dbus-daemon --config-file="$tmp/bus.conf" --fork --print-pid > "$tmp/bus.pid"
  export DBUS_SYSTEM_BUS_ADDRESS=unix:path=$tmp/bus
  mkdir -p "$tmp/state"
  STATE_DIRECTORY=$tmp/state MICROSET_RGB_DEVICE=$tmp/tty /usr/libexec/microsetd > "$tmp/microsetd.log" 2>&1 &
  daemon=$!
  for _ in $(seq 100); do
    microset list microemu. > /dev/null 2>&1 && break
    sleep 0.1
  done
  if grep -q '50-microemu.json' "$tmp/microsetd.log"; then fail "microsetd: $(grep '50-microemu.json' "$tmp/microsetd.log")"; fi
  if ! microset schema microemu. > "$tmp/schema.json"; then
    fail "microset schema microemu."
  else
    python3 - "$tmp/schema.json" "$root/usr/share/microset/schema.d/50-microemu.json" <<'PY' || fail "microsetd did not load every microemu key"
import json, sys
loaded = json.load(open(sys.argv[1]))
mine = json.load(open(sys.argv[2]))["keys"]
if set(loaded) != set(mine):
    sys.exit(f"keys differ: {sorted(set(mine) ^ set(loaded))}")
for k, e in mine.items():
    if loaded[k].get("owner") != "microemu" or loaded[k].get("default") != e["default"]:
        sys.exit(f"{k}: {loaded[k]}")
print(f"microsetd loaded all {len(mine)} microemu keys")
PY
  fi
  kill "$daemon" 2> /dev/null || true
  kill "$(cat "$tmp/bus.pid")" 2> /dev/null || true
fi

while read -r core; do
  [[ -n $core ]] || continue
  [[ $core == /usr/lib64/libretro/*_libretro.so ]] || { fail "core $core is not under /usr/lib64/libretro"; continue; }
  owner=$(dnf -q repoquery --forcearch=aarch64 --qf '%{name}\n' --file "$core" 2>/dev/null | sort -u)
  if [[ -z $owner ]]; then fail "no Fedora aarch64 package ships $core"; continue; fi
  if ! grep -qxF "$owner" <<<"$requires"; then fail "$core comes from $owner, which microemu does not require"; fi
done < <(cat "$root/cores" 2>/dev/null)

exit "$rc"
