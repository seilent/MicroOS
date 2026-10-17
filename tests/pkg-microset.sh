#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-microset.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

srpm=$(find "$dir" -maxdepth 1 -name 'microset-0^*.src.rpm')
if [[ -z $srpm || $(wc -l <<<"$srpm") -ne 1 ]]; then fail "expected one SRPM in $dir"; fi
if [[ -n $(find "$dir" -maxdepth 1 \( -name '*-debuginfo-*' -o -name '*-debugsource-*' \)) ]]; then fail "debug RPM present"; fi

declare -A rpms
for name in microset microset-devel microset-recovery microset-settings microset-fonts; do
  rpm=$(find "$dir" -maxdepth 1 -name "$name-0^*.rpm" ! -name '*.src.rpm')
  if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 ]]; then
    echo "FAIL: expected one $name RPM in $dir" >&2
    exit 1
  fi
  rpms[$name]=$rpm
  if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "$name: release"; fi
  if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "$name: vendor"; fi
  if [[ -n $srpm && $(rpm -qp --qf '%{SOURCERPM}' "$rpm") != "${srpm##*/}" ]]; then fail "$name: SOURCERPM"; fi
  writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
  if [[ -n $writable ]]; then fail "$name: group or other writable: $writable"; fi
done

libdir=/usr/lib64

files=$(rpm -qlp "${rpms[microset]}")
for f in \
  /usr/share/licenses/microset/LICENSE \
  /usr/libexec/microsetd \
  /usr/bin/microset \
  $libdir/libmicroset.so.0 \
  /usr/share/microset/schema.d/10-microset.json \
  /usr/lib/systemd/system/microsetd.service \
  /usr/share/dbus-1/system.d/net.seilent.MicroSet.conf \
  /usr/share/dbus-1/interfaces/net.seilent.MicroSet1.xml \
  /usr/lib/sysusers.d/microset.conf; do
  if ! grep -qx "$f" <<<"$files"; then fail "missing $f"; fi
done
if grep -qE '^(/usr/include/|.*\.so$|.*/cmake/)' <<<"$files"; then fail "microset ships devel files"; fi

devfiles=$(rpm -qlp "${rpms[microset-devel]}")
for f in $libdir/libmicroset.so $libdir/cmake/MicroSet; do
  if ! grep -qx "$f" <<<"$devfiles"; then fail "devel: missing $f"; fi
done
if ! grep -q '^/usr/include/microset/.*\.h$' <<<"$devfiles"; then fail "devel: no headers"; fi
if ! grep -q "^$libdir/cmake/MicroSet/.*Config\.cmake$" <<<"$devfiles"; then fail "devel: no CMake config"; fi

fontfiles=$(rpm -qlp "${rpms[microset-fonts]}")
for f in selawk selawkb selawkl selawksb selawksl; do
  if ! grep -qx "/usr/share/fonts/microset/$f.ttf" <<<"$fontfiles"; then fail "fonts: missing $f.ttf"; fi
done
if ! grep -qx /usr/share/licenses/microset-fonts/Selawik.txt <<<"$fontfiles"; then fail "fonts: missing Selawik.txt"; fi
if [[ $(grep -c '\.ttf$' <<<"$fontfiles") -ne 5 ]]; then fail "fonts: expected five TTFs"; fi
if [[ $(rpm -qp --qf '%{ARCH}' "${rpms[microset-fonts]}") != noarch ]]; then fail "fonts: not noarch"; fi

recfiles=$(rpm -qlp "${rpms[microset-recovery]}")
if [[ $(grep -v '^/usr/share/licenses/' <<<"$recfiles") != /usr/bin/microset-recovery ]]; then fail "recovery: files: $recfiles"; fi
if ! rpm -qpR "${rpms[microset-recovery]}" | grep -q '^microset-fonts = '; then fail "recovery: does not require microset-fonts"; fi

dropins=()
hotkeys=()
for s in steam microdap microemu; do
  dropins+=("/usr/lib/systemd/user/gamescope-session-plus@$s.service.d/30-microset-overlay.conf")
  hotkeys+=("/usr/lib/microos/hotkeys.d/$s.conf.d/60-microset.conf")
done
setfiles=$(rpm -qlp "${rpms[microset-settings]}")
for f in \
  /usr/share/licenses/microset-settings/LICENSE \
  /usr/bin/microset-settings \
  /usr/libexec/microset/microset-wait-x \
  /usr/lib/systemd/user/microset-overlay@.service \
  "${dropins[@]}" "${hotkeys[@]}"; do
  if ! grep -qx "$f" <<<"$setfiles"; then fail "settings: missing $f"; fi
done
if grep -qE '^/usr/bin/microset-recovery$|^/usr/libexec/microsetd$' <<<"$setfiles"; then fail "settings ships recovery or microsetd"; fi
setreqs=$(rpm -qpR "${rpms[microset-settings]}")
isa='\((aarch|x86)-64\)'
for r in "microset$isa = " 'microset-fonts = ' "qt6-qtbase-gui$isa\$" "qt6-qtdeclarative$isa\$" 'xprop$'; do
  if ! grep -qE "^$r" <<<"$setreqs"; then fail "settings: does not require $r"; fi
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for name in microset microset-settings; do
  rpm2cpio "${rpms[$name]}" > "$tmp/$name.cpio"
  (cd "$tmp" && cpio -idm --quiet < "$name.cpio")
done

ou=$tmp/usr/lib/systemd/user/microset-overlay@.service
for kv in BindsTo=gamescope-session-plus@%i.service After=gamescope-session-plus@%i.service Type=notify NoNewPrivileges=yes \
  Environment=DISPLAY=:0 Environment=QT_QPA_PLATFORM=xcb Environment=QT_QUICK_BACKEND=software \
  Environment=QT_XCB_GL_INTEGRATION=none ExecStartPre=/usr/libexec/microset/microset-wait-x \
  'ExecStart=/usr/bin/microset-settings --overlay' Restart=on-failure; do
  if ! grep -qxF "$kv" "$ou"; then fail "microset-overlay@.service lacks $kv"; fi
done
if [[ ! -x $tmp/usr/libexec/microset/microset-wait-x ]]; then fail "microset-wait-x not executable"; fi
for s in steam microdap microemu; do
  if [[ $(< "$tmp/usr/lib/systemd/user/gamescope-session-plus@$s.service.d/30-microset-overlay.conf") != $'[Unit]\nWants=microset-overlay@'"$s"'.service' ]]; then
    fail "$s session drop-in"
  fi
  if [[ $(< "$tmp/usr/lib/microos/hotkeys.d/$s.conf.d/60-microset.conf") != 'rc tap call net.seilent.MicroSet.Overlay /net/seilent/MicroSet/Overlay net.seilent.MicroSet.Overlay1 Toggle' ]]; then
    fail "$s hotkey drop-in"
  fi
done

unit=$tmp/usr/lib/systemd/system/microsetd.service
for kv in Type=dbus BusName=net.seilent.MicroSet User=microset StateDirectory=microset ExecStart=/usr/libexec/microsetd \
  NoNewPrivileges=yes ProtectSystem=strict ProtectHome=yes PrivateTmp=yes 'RestrictAddressFamilies=AF_UNIX AF_QIPCRTR' \
  Restart=always TimeoutStartSec=10 'SupplementaryGroups=audio dialout' Before=display-manager.service WantedBy=multi-user.target; do
  if ! grep -qx "$kv" "$unit"; then fail "microsetd.service lacks $kv"; fi
done
if ! grep -qx 'CapabilityBoundingSet=' "$unit"; then fail "microsetd.service CapabilityBoundingSet not empty"; fi
if grep -q '^PrivateNetwork=' "$unit"; then fail "microsetd.service sets PrivateNetwork, QRTR needs the host netns"; fi
if ! grep -qx 'DeviceAllow=/dev/ttyHS2 rw' "$unit"; then fail "microsetd.service lacks DeviceAllow=/dev/ttyHS2 rw"; fi
if ! grep -qx 'DeviceAllow=char-alsa rw' "$unit"; then fail "microsetd.service lacks DeviceAllow=char-alsa rw"; fi
if ! grep -qx 'After=.*alsa-restore\.service.*' "$unit"; then fail "microsetd.service not after alsa-restore.service"; fi
if ! grep -qx 'After=.*alsa-state\.service.*' "$unit"; then fail "microsetd.service not after alsa-state.service"; fi

if ! grep -qE '^u[[:space:]]+microset[[:space:]]' "$tmp/usr/lib/sysusers.d/microset.conf"; then fail "sysusers: no user microset"; fi

python3 - "$tmp" <<'PY' || rc=1
import glob, json, sys
import xml.etree.ElementTree as ET

root = sys.argv[1]
rc = 0
name = "net.seilent.MicroSet"
policies = {}
for p in ET.parse(f"{root}/usr/share/dbus-1/system.d/{name}.conf").getroot().iter("policy"):
    policies[next(iter(p.attrib.items()))] = [(r.tag, r.attrib) for r in p]
if ("allow", {"own": name}) not in policies.get(("user", "microset"), []):
    print(f"FAIL: DBus policy: microset does not own {name}", file=sys.stderr)
    rc = 1
if ("allow", {"send_destination": name}) not in policies.get(("context", "default"), []):
    print(f"FAIL: DBus policy: default context may not send to {name}", file=sys.stderr)
    rc = 1
for key, rules in policies.items():
    if key != ("user", "microset") and any("own" in a or "own_prefix" in a for _, a in rules):
        print(f"FAIL: DBus policy: {key} may own", file=sys.stderr)
        rc = 1

iface = ET.parse(f"{root}/usr/share/dbus-1/interfaces/net.seilent.MicroSet1.xml").getroot()
members = {(e.tag, e.get("name")) for i in iface.iter("interface") if i.get("name") == "net.seilent.MicroSet1" for e in i}
for m in [("method", "Get"), ("method", "Set"), ("method", "List"), ("method", "Schema"), ("signal", "Changed")]:
    if m not in members:
        print(f"FAIL: interface lacks {m[0]} {m[1]}", file=sys.stderr)
        rc = 1

types = {"s": str, "b": bool, "u": int, "i": int, "d": (int, float), "as": list}
for path in sorted(glob.glob(f"{root}/usr/share/microset/schema.d/*.json")):
    try:
        with open(path) as f:
            doc = json.load(f)
    except Exception as e:
        print(f"FAIL: {path}: {e}", file=sys.stderr)
        rc = 1
        continue
    if not isinstance(doc.get("owner"), str) or not isinstance(doc.get("keys"), dict) or not doc["keys"]:
        print(f"FAIL: {path}: owner or keys", file=sys.stderr)
        rc = 1
        continue
    for key, k in doc["keys"].items():
        t = k.get("type")
        if t not in types:
            print(f"FAIL: {path}: {key} type {t}", file=sys.stderr)
            rc = 1
            continue
        d = k.get("default")
        if d is None or not isinstance(d, types[t]) or (t != "b" and isinstance(d, bool)):
            print(f"FAIL: {path}: {key} default {d!r} is not {t}", file=sys.stderr)
            rc = 1
        if "enum" in k and d not in k["enum"]:
            print(f"FAIL: {path}: {key} default {d!r} not in enum", file=sys.stderr)
            rc = 1
        if "min" in k and "max" in k and not k["min"] <= d <= k["max"]:
            print(f"FAIL: {path}: {key} default {d!r} out of range", file=sys.stderr)
            rc = 1
sys.exit(rc)
PY

exit "$rc"
