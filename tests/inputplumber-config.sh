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
sys.exit(rc)
PY
