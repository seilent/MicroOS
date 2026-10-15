#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: inputplumber-config.sh <rpmdir> [configdir]}
here=$(cd "$(dirname "$0")" && pwd)
conf=${2:-$here/../system_files/usr/share/inputplumber}

rpm=$(find "$dir" -maxdepth 1 -name 'inputplumber-*.rpm' ! -name '*.src.rpm')
[[ -n $rpm && $(wc -l <<<"$rpm") -eq 1 ]] || { echo "FAIL: expected one inputplumber RPM in $dir" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(cd "$tmp" && rpm2cpio "$rpm" | cpio -idm --quiet './usr/share/inputplumber/schema/*')

python3 - "$tmp/usr/share/inputplumber/schema" "$conf" <<'PY'
import glob, json, sys
import jsonschema, yaml

schemas, conf = sys.argv[1], sys.argv[2]

def strict(node):
    if isinstance(node, dict):
        if "properties" in node and "additionalProperties" not in node:
            node["additionalProperties"] = False
        for v in node.values():
            strict(v)
    elif isinstance(node, list):
        for v in node:
            strict(v)
    return node

def validator(name):
    schema = strict(json.load(open(f"{schemas}/{name}.json")))
    return jsonschema.validators.validator_for(schema)(schema)

known_gap = (["target_devices"], "deck-uhid")
checks = [("composite_device_v1", p) for p in sorted(glob.glob(f"{conf}/devices/*.yaml"))]
checks += [("capability_map_v2", p) for p in sorted(glob.glob(f"{conf}/capability_maps/*.yaml"))]
if not any(k == "composite_device_v1" for k, _ in checks) or not any(k == "capability_map_v2" for k, _ in checks):
    print(f"FAIL: no device or capability map files in {conf}", file=sys.stderr)
    sys.exit(1)

rc = 0
for kind, path in checks:
    errors = []
    for e in validator(kind).iter_errors(yaml.safe_load(open(path))):
        loc = list(e.absolute_path)
        if kind == "composite_device_v1" and loc[:-1] == known_gap[0] and e.instance == known_gap[1] and e.validator == "enum":
            continue
        errors.append(f"{loc}: {e.message}")
    for err in errors:
        print(f"FAIL: {path}: {err}", file=sys.stderr)
    rc |= bool(errors)
    print(f"{'FAIL' if errors else 'ok'} {kind} {path.rsplit('/', 1)[-1]}")

pm2 = yaml.safe_load(open(f"{conf}/capability_maps/ayaneo_pocket_micro2.yaml"))
mode = [m["target_event"] for m in pm2["mapping"]
        if any(e.get("evdev", {}).get("event_code") == "BTN_MODE" for e in m["source_events"])]
if mode != [{"keyboard": "KeyF13"}]:
    print(f"FAIL: BTN_MODE maps to {mode}, want one KeyF13 row", file=sys.stderr)
    rc = 1

dev = yaml.safe_load(open(f"{conf}/devices/04-ayaneo-pocket-micro2.yaml"))
imu = [s for s in dev["source_devices"] if s["group"] == "imu"]
cfg = imu[0].get("config", {}).get("imu", {}) if len(imu) == 1 else {}
if len(imu) != 1 or imu[0].get("ssc") != {"name": "fastrpc-sdsp"}:
    print(f"FAIL: imu sources {imu}, want one ssc source fastrpc-sdsp", file=sys.stderr)
    rc = 1
if cfg.get("sample_rate") != 400:
    print(f"FAIL: imu sample_rate {cfg.get('sample_rate')}, want 400", file=sys.stderr)
    rc = 1
if cfg.get("mount_matrix") != {"x": [0, -1, 0], "y": [1, 0, 0], "z": [0, 0, 1]}:
    print(f"FAIL: imu mount_matrix {cfg.get('mount_matrix')}", file=sys.stderr)
    rc = 1
sys.exit(rc)
PY
