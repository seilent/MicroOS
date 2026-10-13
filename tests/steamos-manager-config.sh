#!/usr/bin/env bash
set -euo pipefail

root=${1:-$(cd "$(dirname "$0")/.." && pwd)}

python3 - "$root" <<'PY'
import re, sys, tomllib

root = sys.argv[1]
rc = 0

def fail(msg):
    global rc
    print(f"FAIL: {msg}", file=sys.stderr)
    rc = 1

def load(path):
    with open(f"{root}/{path}", "rb") as f:
        return tomllib.load(f)

dts = open(f"{root}/packages/kernel/dts/sm8250-ayaneo-pocket-micro2.dts").read()
m = re.search(r'^/ \{\n(?:\t[^\t\n].*\n)*?\tcompatible = "([^"]+)"', dts, re.M)
if not m:
    fail("no root compatible in the PM2 DTS")
compatible = m.group(1) if m else None

device = load("system_files/usr/share/steamos-manager/devices/microos-pm2.toml")
if set(device) != {"device", "inputplumber"}:
    fail(f"microos-pm2.toml sections {sorted(device)}")
matches = device.get("device", [])
if len(matches) != 1:
    fail(f"microos-pm2.toml has {len(matches)} [[device]] entries")
else:
    want = {
        "dt": {"compatible": compatible},
        "device": "ayaneo_pocket_micro2",
        "variant": "pocket_micro2",
        "friendly_name": "AYANEO Pocket MICRO 2",
    }
    if matches[0] != want:
        fail(f"microos-pm2.toml [[device]] {matches[0]}, want {want}")
if device.get("inputplumber") != {"target_devices": ["deck-uhid", "keyboard"]}:
    fail(f"microos-pm2.toml [inputplumber] {device.get('inputplumber')}")

remotes = load("system_files/usr/share/steamos-manager/remotes.d/microos.toml")
required = {"PerformanceProfile1", "GpuPerformanceLevel1", "CpuScaling1"}
if not required <= set(remotes) or not set(remotes) <= required | {"TdpLimit1"}:
    fail(f"remotes.d/microos.toml sections {sorted(remotes)}")
for name, section in remotes.items():
    if section != {"bus_name": "net.seilent.MicroOs.Power", "object_path": "/net/seilent/MicroOs/Power"}:
        fail(f"remotes.d/microos.toml [{name}] {section}")

if rc == 0:
    print(f"ok microos-pm2.toml dt.compatible {compatible}, remotes {sorted(remotes)}")
sys.exit(rc)
PY
