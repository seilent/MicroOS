#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-steamos-manager.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"
version=${STEAMOS_MANAGER_VERSION:?SOURCE.env has no STEAMOS_MANAGER_VERSION}

rpm=$(find "$dir" -maxdepth 1 -name "steamos-manager-$version-*.rpm" ! -name '*.src.rpm')
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 ]]; then
  echo "FAIL: expected one steamos-manager RPM in $dir" >&2
  exit 1
fi
if [[ -z $(find "$dir" -maxdepth 1 -name "steamos-manager-$version-*.src.rpm") ]]; then fail "SRPM missing"; fi
if [[ -n $(find "$dir" -maxdepth 1 \( -name '*-debuginfo-*' -o -name '*-debugsource-*' \)) ]]; then fail "debug RPM present"; fi

if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "release"; fi
if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi

writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi

files=$(rpm -qlp "$rpm")
for f in \
  /usr/share/licenses/steamos-manager/LICENSE \
  /usr/lib/steamos-manager \
  /usr/bin/steamosctl \
  /usr/lib/systemd/system/steamos-manager.service \
  /usr/lib/systemd/user/steamos-manager.service \
  /usr/lib/systemd/user/steamos-manager-session-cleanup.service \
  /usr/share/dbus-1/system-services/com.steampowered.SteamOSManager1.service \
  /usr/share/dbus-1/services/com.steampowered.SteamOSManager1.service \
  /usr/share/dbus-1/system.d/com.steampowered.SteamOSManager1.conf \
  /usr/share/dbus-1/interfaces/com.steampowered.SteamOSManager1.xml \
  /usr/share/steamos-manager/platform.toml \
  /usr/share/steamos-manager/devices/steam-deck.toml \
  /usr/share/steamos-manager/remotes.d \
  /etc/steamos-manager/remotes.d; do
  if ! grep -qx "$f" <<<"$files"; then fail "missing $f"; fi
done
for f in \
  /usr/lib/systemd/system/sddm.service.d/reset-oneshot-boot.conf \
  /usr/lib/systemd/user/orca.service \
  /usr/lib/systemd/user/steamos-manager-configure-cecd.service; do
  if grep -qx "$f" <<<"$files"; then fail "ships $f"; fi
done
if grep -q '^/usr/share/steamos-manager/remotes.d/.' <<<"$files"; then fail "ships a remote"; fi
if grep -q '^/usr/share/steamos-manager/devices/microos' <<<"$files"; then fail "ships the PM2 device file"; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(cd "$tmp" && rpm2cpio "$rpm" | cpio -idm --quiet './usr/share/dbus-1/system.d/*' './usr/share/steamos-manager/*')

python3 - "$tmp" <<'PY' || rc=1
import glob, sys, tomllib
import xml.etree.ElementTree as ET

root = sys.argv[1]
rc = 0
name = "com.steampowered.SteamOSManager1"
policies = {}
for p in ET.parse(f"{root}/usr/share/dbus-1/system.d/{name}.conf").getroot().iter("policy"):
    key = next(iter(p.attrib.items()))
    policies[key] = [(rule.tag, rule.attrib) for rule in p]
wheel = [
    ("org.freedesktop.DBus.Introspectable", None),
    ("org.freedesktop.DBus.Peer", None),
    ("org.freedesktop.DBus.Properties", "Get"),
    ("org.freedesktop.DBus.Properties", "GetAll"),
    (f"{name}.RootManager", "ReloadConfig"),
    (f"{name}.RootManager", "SetWifiBackend"),
    (f"{name}.RootManager", "SetWifiPowerManagementState"),
    (f"{name}.RootManager", "UpdateBios"),
    (f"{name}.Job1", None),
]
want = {
    ("user", "root"): [("allow", {"own": name}), ("allow", {"send_destination": name})],
    ("group", "wheel"): [
        ("allow", {"send_destination": name, "send_interface": i} | ({"send_member": m} if m else {})) for i, m in wheel
    ],
    ("context", "default"): [("deny", {"send_destination": name})],
}
if policies != want:
    print(f"FAIL: DBus policy {policies}", file=sys.stderr)
    rc = 1

for path in [f"{root}/usr/share/steamos-manager/platform.toml"] + sorted(glob.glob(f"{root}/usr/share/steamos-manager/devices/*.toml")):
    try:
        with open(path, "rb") as f:
            tomllib.load(f)
    except Exception as e:
        print(f"FAIL: {path}: {e}", file=sys.stderr)
        rc = 1
sys.exit(rc)
PY

exit "$rc"
