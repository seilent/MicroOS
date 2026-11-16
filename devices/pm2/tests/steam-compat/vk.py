#!/usr/bin/env python3
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time

here = os.path.dirname(os.path.abspath(__file__))
tree = os.environ.get("MICROOS_TREE", os.path.join(here, "..", "..", "system_files"))
PROBE = os.path.join(tree, "usr/libexec/microos/microos-vk-features")
with open(os.path.join(here, "..", "fixtures", "vulkaninfo-llvmpipe.txt")) as f:
    CAPTURE = f.read()
failures = []


def check(cond, what):
    if not cond:
        failures.append(what)
        print(f"FAIL: {what}", file=sys.stderr)


def turnip(value="false", text=CAPTURE):
    out = text.replace("PHYSICAL_DEVICE_TYPE_CPU", "PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU")
    out = out.replace("llvmpipe (LLVM 22.1.8, 256 bits)", "Turnip Adreno (TM) 650")
    out = out.replace("vendorID          = 0x10005", "vendorID          = 0x5143")
    return out.replace("storageBuffer8BitAccess                            = true",
                       f"storageBuffer8BitAccess                            = {value}")


def two(first, second):
    head, _, gpu0 = first.partition("\nGPU0:\n")
    _, _, gpu1 = second.partition("\nGPU0:\n")
    return f"{head}\nGPU0:\n{gpu0}\nGPU1:\n{gpu1}"


class Probe:
    def __init__(self):
        self.dir = tempfile.mkdtemp()
        self.bin = os.path.join(self.dir, "bin")
        self.dri = os.path.join(self.dir, "dri")
        self.out = os.path.join(self.dir, "run", "vk-features")
        os.makedirs(self.bin)
        os.makedirs(os.path.dirname(self.out))

    def stub(self, text, rc=0, sleep=0):
        with open(os.path.join(self.dir, "capture.txt"), "w") as f:
            f.write(text)
        with open(os.path.join(self.bin, "vulkaninfo"), "w") as f:
            f.write(f"#!/bin/sh\nsleep {sleep}\ncat '{self.dir}/capture.txt'\necho noise >&2\nexit {rc}\n")
        os.chmod(os.path.join(self.bin, "vulkaninfo"), 0o755)

    def node(self, on=True):
        if on:
            os.makedirs(self.dri, exist_ok=True)
            open(os.path.join(self.dri, "renderD128"), "w").close()
        else:
            shutil.rmtree(self.dri, ignore_errors=True)

    def run(self, **env):
        e = {"PATH": f"{self.bin}:/usr/bin:/bin", "MICROOS_VK_FEATURES": self.out, "MICROOS_DRI": self.dri,
             "MICROOS_VK_WAIT": "1", "MICROOS_VK_TIMEOUT": "3"}
        e.update(env)
        t0 = time.monotonic()
        p = subprocess.run([PROBE], env=e, capture_output=True, text=True, timeout=30)
        self.took = time.monotonic() - t0
        self.rc, self.err = p.returncode, p.stderr
        try:
            with open(self.out) as f:
                return f.read()
        except FileNotFoundError:
            return None

    def clean(self):
        shutil.rmtree(self.dir)


def main():
    p = Probe()
    p.node()
    for name, text, rc, want in (("turnip false", turnip("false"), 0, "0"),
                                 ("turnip true", turnip("true"), 0, "1"),
                                 ("turnip false, exit 1", turnip("false"), 1, "0"),
                                 ("llvmpipe and turnip", two(CAPTURE, turnip("false")), 0, "0"),
                                 ("two GPUs with it", two(turnip("true"), turnip("true")), 0, "1"),
                                 ("one GPU without it", two(turnip("true"), turnip("false")), 0, "0")):
        p.stub(text, rc)
        got = p.run()
        check(got == f"storageBuffer8BitAccess={want}\n" and p.rc == 0, f"{name}: {got!r} rc {p.rc} {p.err}")
        check(stat.S_IMODE(os.stat(p.out).st_mode) == 0o644, f"{name}: mode")
        check(f"storageBuffer8BitAccess={want} (Turnip Adreno (TM) 650" in p.err and p.err.endswith(" on renderD128 minor 0\n"),
              f"{name}: line {p.err!r}")
    for name, text, rc, sleep, why in (("llvmpipe only", CAPTURE, 0, 0, "no GPU among 1 devices"),
                                       ("garbage", "nothing\nhere\n", 0, 0, "no GPU among 0 devices"),
                                       ("empty, exit 1", "", 1, 0, "vulkaninfo exit 1"),
                                       ("no feature line", turnip().replace("storageBuffer8BitAccess", "other"), 0, 0,
                                        "storageBuffer8BitAccess []"),
                                       ("odd value", turnip("maybe"), 0, 0, "storageBuffer8BitAccess ['maybe']"),
                                       ("hang", turnip(), 0, 30, "not written")):
        p.stub(turnip("true"))
        p.run()
        p.stub(text, rc, sleep)
        got = p.run()
        check(got is None and p.rc == 0 and why in p.err and " on renderD128 minor 0" in p.err, f"{name}: {got!r} rc {p.rc} {p.err!r}")
        check(p.took < 10, f"{name}: took {p.took:.1f} s")
    open(os.path.join(p.dri, "renderD129"), "w").close()
    os.symlink("renderD129", os.path.join(p.dri, "renderD127"))
    os.remove(os.path.join(p.dri, "renderD129"))
    p.stub(turnip())
    check(p.run() == "storageBuffer8BitAccess=0\n" and "on renderD128 minor 0" in p.err, f"first node that stats: {p.err!r}")
    os.remove(os.path.join(p.dri, "renderD127"))
    check(p.run() == "storageBuffer8BitAccess=0\n", "file before the no node case")
    p.node(False)
    got = p.run()
    check(got is None and p.rc == 0 and "no render node" in p.err and 0.9 < p.took < 5, f"no node: {got!r} {p.err!r} {p.took:.1f}")
    proc = subprocess.Popen([PROBE], env={"PATH": f"{p.bin}:/usr/bin:/bin", "MICROOS_VK_FEATURES": p.out,
                                          "MICROOS_DRI": p.dri, "MICROOS_VK_WAIT": "5", "MICROOS_VK_TIMEOUT": "3"},
                            stderr=subprocess.DEVNULL)
    time.sleep(0.5)
    p.node()
    rc = proc.wait(timeout=20)
    with open(p.out) as f:
        late = f.read()
    check(rc == 0 and late == "storageBuffer8BitAccess=0\n", f"node appears late: rc {rc} {late!r}")
    p.clean()
    if failures:
        return 1
    print("vk features: ok")
    return 0


sys.exit(main())
