import os
import runpy
import subprocess
import sys
import time

sys.dont_write_bytecode = True
opts = {}
args = sys.argv[1:]
while args[0].startswith("--"):
    key, _, value = args.pop(0)[2:].partition("=")
    opts[key] = value
clock = [float(opts.get("clock", "1000"))]
gettime = time.clock_gettime
time.monotonic = lambda: clock[0]
time.clock_gettime = lambda c: clock[0] if c == time.CLOCK_MONOTONIC else gettime(c)
real_open = os.open


def fake_open(path, *a, **k):
    name = os.fsdecode(path)
    if name == opts.get("deny"):
        raise PermissionError(13, "Permission denied", name)
    if "jump" in opts and name.endswith(opts["jump"]):
        clock[0] += 60
    return real_open(path, *a, **k)


os.open = fake_open
if "steam-timeout" in opts:
    real_run = subprocess.run

    def fake_run(cmd, *a, **k):
        r = real_run(cmd, *a, **k)
        if cmd[0] == "steam":
            raise subprocess.TimeoutExpired(cmd, k.get("timeout"))
        return r

    subprocess.run = fake_run
sys.argv = args
runpy.run_path(args[0], run_name="__main__")
