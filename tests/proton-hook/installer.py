#!/usr/bin/env python3
import contextlib
import fcntl
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

here = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
tree = os.path.abspath(os.environ.get("MICROOS_TREE", os.path.join(here, "..", "..", "system_files")))
share = os.path.join(tree, "usr/share/microos")
SCAN = os.path.join(tree, "usr/libexec/microos/microos-proton-hook")
USER = os.path.join(tree, "usr/lib/systemd/user")
STUB = os.path.join(share, "proton/user_settings_stub.py")
ARM_MANIFEST = '"manifest"\n{\n\t"version"\t\t"2"\n\t"commandline"\t\t"/proton %verb%"\n\t"require_tool_appid"\t\t"4185400"\n\t"use_sessions"\t\t"1"\n}\n'
X86_MANIFEST = ARM_MANIFEST.replace("4185400", "1628350")
failures = []
checks = [0]

SYSTEMCTL = r'''#!/usr/bin/env python3
import fnmatch
import json
import os
import sys

path = os.environ["TEST_UNITS"]
with open(path) as f:
    units = json.load(f)
args = sys.argv[1:]
with open(os.environ["TEST_CALLS"], "a") as f:
    f.write(" ".join(args) + "\n")
assert args[0] == "--user", args
verb, rest = args[1], args[2:]
names = [a for a in rest if not a.startswith("--")]
rc = 0
if verb == "list-units":
    for u in sorted(units):
        if any(fnmatch.fnmatchcase(u, p) for p in names):
            print(f"{u} loaded {units[u]} {'waiting' if units[u] == 'active' else 'dead'} watch")
elif verb == "start":
    for u in names:
        if units.get(u) == "failed":
            print(f"Job for {u} failed", file=sys.stderr)
            rc = 1
        else:
            units[u] = "active"
elif verb == "stop":
    for u in names:
        units.pop(u, None)
elif verb == "reset-failed":
    for u in names:
        if units.get(u) == "failed":
            del units[u]
else:
    print(f"unknown verb {verb}", file=sys.stderr)
    rc = 1
with open(path, "w") as f:
    json.dump(units, f)
sys.exit(rc)
'''

DRIVER = r'''
import errno
import os
import runpy
import subprocess
import sys
import tempfile
import time

fail = os.environ.get("TEST_LINK_FAIL", "")
real = os.link


def link(src, dst, *a, **k):
    if fail:
        code, dirs = fail.split(":", 1)
        if os.path.dirname(os.fspath(src)) in dirs.split("|"):
            n = getattr(errno, code)
            raise OSError(n, os.strerror(n), src)
    return real(src, dst, *a, **k)


os.link = link
swap = os.environ.get("TEST_SWAP", "")
swapped = []
real_mkstemp = tempfile.mkstemp


def mkstemp(*a, **k):
    r = real_mkstemp(*a, **k)
    if swap and k.get("dir") == swap and not swapped:
        swapped.append(swap)
        with open(os.path.join(swap, ".swap"), "w") as f:
            f.write("user_settings = {'NEW': '1'}\n")
        real_rename(os.path.join(swap, ".swap"), os.path.join(swap, "user_settings.py"))
    return r


tempfile.mkstemp = mkstemp
real_rename = os.rename
unlink_after = os.environ.get("TEST_UNLINK_AFTER", "")
append_after = os.environ.get("TEST_APPEND_AFTER", "")
after = []


def rename(src, dst, *a, **k):
    s = os.fspath(dst)
    if os.environ.get("TEST_RENAMES") and s.endswith("/user_settings.py"):
        pyc = os.path.join(os.path.dirname(s), "__pycache__")
        left = sorted(n for n in os.listdir(pyc) if n.startswith("user_settings.")) if os.path.isdir(pyc) else []
        print(f"TEST rename {s} pyc {left}", flush=True)
    r = real_rename(src, dst, *a, **k)
    if not after and s in (f"{unlink_after}/user_settings.py", f"{append_after}/user_settings.py"):
        after.append(s)
        if unlink_after:
            os.unlink(s)
        else:
            with open(s, "ab") as f:
                f.write(b"\n")
    return r


os.rename = rename
during = os.environ.get("TEST_DURING", "")
real_run = subprocess.run


def run(args, *a, **k):
    if during and "list-units" in args:
        runpy.run_path(during, run_name="during")
    return real_run(args, *a, **k)


subprocess.run = run
on_sleep = os.environ.get("TEST_ON_SLEEP", "")
slept = []
real_sleep = time.sleep


def sleep(s):
    if on_sleep and not slept:
        slept.append(s)
        runpy.run_path(on_sleep, run_name="during")
    return real_sleep(s)


time.sleep = sleep
mounted = os.environ.get("TEST_MOUNTED", "").split("|")
real_ismount = os.path.ismount
os.path.ismount = lambda p: os.fspath(p) in mounted or real_ismount(p)
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
'''


def check(cond, what):
    checks[0] += 1
    if not cond:
        failures.append(what)
        print(f"FAIL: {what}", file=sys.stderr)


def write(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)
    os.chmod(path, mode)


def read(path):
    with open(path, "rb") as f:
        return f.read()


def kv(d, depth=0):
    tab = "\t" * depth
    out = []
    for k, v in d.items():
        if isinstance(v, dict):
            out.append(f'{tab}"{k}"\n{tab}{{\n{kv(v, depth + 1)}{tab}}}\n')
        else:
            out.append(f'{tab}"{k}"\t\t"{v}"\n')
    return "".join(out)


def libraryfolders(paths):
    return kv({"libraryfolders": {str(i): {"path": p, "label": "", "contentid": "1"} for i, p in enumerate(paths)}})


def proton(d, manifest=ARM_MANIFEST, version="1791559733 proton-11.0-2e-arm64\n"):
    write(f"{d}/proton", "#!/usr/bin/env python3\n", 0o755)
    write(f"{d}/toolmanifest.vdf", manifest)
    write(f"{d}/version", version)
    return d


def esc(path):
    p = os.fsencode(path.strip("/"))
    out = []
    for i, b in enumerate(p):
        c = chr(b)
        if c == "/":
            out.append("-")
        elif (c.isascii() and (c.isalnum() or c in ":_.")) and not (i == 0 and c == "."):
            out.append(c)
        else:
            out.append(f"\\x{b:02x}")
    return "".join(out)


class Home:
    def __init__(self, tmp):
        self.tmp = tmp
        self.home = os.path.join(tmp, "home")
        self.steam = os.path.join(self.home, ".local/share/Steam")
        self.run = os.path.join(tmp, "run")
        self.bin = os.path.join(tmp, "bin")
        self.units = os.path.join(tmp, "units.json")
        self.calls = os.path.join(tmp, "calls.log")
        for d in (self.steam + "/steamapps/common", self.run, self.bin):
            os.makedirs(d, exist_ok=True)
        os.chmod(self.run, 0o700)
        write(os.path.join(self.bin, "systemctl"), SYSTEMCTL, 0o755)
        with open(self.units, "w") as f:
            json.dump({}, f)
        self.stub = read(STUB)

    def env(self, **extra):
        return {"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": self.home, "XDG_RUNTIME_DIR": self.run, "LC_ALL": "C.UTF-8",
                "MICROOS_SHARE": share, "TEST_UNITS": self.units, "TEST_CALLS": self.calls, **extra}

    def start(self, **extra):
        return subprocess.Popen([sys.executable, "-c", DRIVER, SCAN], env=self.env(**extra), stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)

    def scan(self, **extra):
        p = subprocess.run([sys.executable, "-c", DRIVER, SCAN], env=self.env(**extra), capture_output=True, text=True,
                           timeout=60)
        check(p.returncode == 0, f"scan rc {p.returncode}: {p.stdout} {p.stderr}")
        return p.stdout + p.stderr

    def state(self):
        with open(self.units) as f:
            return json.load(f)

    def set_state(self, units):
        with open(self.units, "w") as f:
            json.dump(units, f)

    def tool(self, *parts):
        return os.path.join(self.steam, "steamapps/common", *parts)


def lib_unit(p):
    return f"microos-proton-hook-lib@{esc(os.path.realpath(p))}.path"


def dir_unit(p):
    return f"microos-proton-hook-dir@{esc(os.path.realpath(p))}.path"


def no_temp(d):
    return not [n for n in os.listdir(d) if n.startswith(".user_settings.py.")]


def case_units(tmp):
    svc = read(os.path.join(USER, "microos-proton-hook.service")).decode()
    for line in ("Type=oneshot", "RemainAfterExit=no", "StartLimitIntervalSec=0", "TimeoutStartSec=30s",
                 "Before=gamescope-session-plus@steam.service", "After=microos-steam-seed.service",
                 "ExecStart=/usr/libexec/microos/microos-proton-hook"):
        check(line in svc.splitlines(), f"service lacks {line}")
    unit_part = svc.split("[Service]")[0]
    check("StartLimitIntervalSec=0" in unit_part, "StartLimitIntervalSec is not in [Unit]")
    paths = {"microos-proton-hook-lib@.path": ["PathChanged=%f/steamapps", "PathChanged=%f/steamapps/common",
                                               "PathChanged=%f/compatibilitytools.d"],
             "microos-proton-hook-dir@.path": ["PathChanged=%f/user_settings.py", "PathChanged=%f/proton",
                                               "PathChanged=%f/toolmanifest.vdf"],
             "microos-proton-hook-media.path": ["PathChanged=/run/media/%u"]}
    for name, want in paths.items():
        lines = read(os.path.join(USER, name)).decode().splitlines()
        for line in want + ["Unit=microos-proton-hook.service", "TriggerLimitIntervalSec=2s", "TriggerLimitBurst=200"]:
            check(line in lines, f"{name} lacks {line}")
        check(not any(l.startswith("[Install]") for l in lines), f"{name} has an [Install] section")
    dropin = read(os.path.join(USER, "gamescope-session-plus@steam.service.d/10-microos.conf")).decode().splitlines()
    check("Wants=microos-proton-hook.service" in dropin, "Steam session does not pull in microos-proton-hook.service")
    check(os.stat(SCAN).st_mode & 0o777 == 0o755, f"scan mode {oct(os.stat(SCAN).st_mode)}")
    return {}


def case_escape(tmp):
    sys.path.insert(0, os.path.join(share, "python"))
    ns = {"__name__": "scan"}
    src = read(SCAN).decode().split("\ntry:\n    rc = main()")[0]
    exec(compile(src, SCAN, "exec"), ns)
    sys.path.pop(0)
    paths = ["/var/home/micro/.local/share/Steam", "/var/home/micro/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)",
             "/run/media/micro/SD-card", "/run/media/micro/カード", "/.hidden/x", "//a//b/", "/", "/a-b\\c",
             os.fsdecode(b"/run/media/micro/\xff\xfe card/Proton \xe9")]
    got = {p: ns["escape"](p) for p in paths}
    out = {"ours": {ascii(p): e for p, e in got.items()}}
    if shutil.which("systemd-escape"):
        ref = [subprocess.run(["systemd-escape", "--path", "--", p], capture_output=True, text=True).stdout.strip()
               for p in paths]
        out["systemd"] = {ascii(p): e for p, e in zip(paths, ref)}
        check(list(got.values()) == ref, f"escape differs from systemd-escape: {got} {ref}")
    else:
        check(False, "systemd-escape missing, the escape rule is unchecked")
    check(got["/var/home/micro/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)"]
          == "var-home-micro-.local-share-Steam-steamapps-common-Proton\\x2011.0\\x20\\x28ARM64\\x29", f"escape {got}")
    check(got[paths[-1]] == "run-media-micro-\\xff\\xfe\\x20card-Proton\\x20\\xe9", f"escape of a non UTF-8 name {got}")
    long = "/x" + "/abcdefghij" * 30
    said = io.StringIO()
    with contextlib.redirect_stdout(said):
        name = ns["unit"](ns["DIR"], long)
    check(name is None and "over 255 characters" in said.getvalue(), "unit name over 255 kept")
    return out


def case_fresh(tmp):
    h = Home(tmp)
    t = h.tool("Proton 11.0 (ARM64)")
    proton(t)
    x86 = proton(h.tool("Proton 11.0"), X86_MANIFEST)
    ref = os.path.join(tmp, "before")
    write(ref, "")
    log = h.scan()
    us = f"{t}/user_settings.py"
    st = os.stat(us)
    check(read(us) == h.stub and st.st_mode & 0o777 == 0o644 and st.st_mtime_ns >= os.stat(ref).st_mtime_ns > 0,
          f"fresh stub {oct(st.st_mode)} {st.st_mtime_ns}")
    check(not os.path.exists(f"{x86}/user_settings.py"), "x86 Proton got the stub")
    check(no_temp(t), "temp file left")
    units = h.state()
    want = {"microos-proton-hook-media.path", lib_unit(h.steam), dir_unit(t)}
    check(set(units) == want and all(v == "active" for v in units.values()), f"fresh units {units} want {want}")
    check("stub written" in log, f"fresh log {log}")
    with open(h.calls) as f:
        lists = sum(1 for c in f if c.startswith("--user list-units"))
    check(lists == 1, f"a fresh stub took {lists} passes")
    before = os.stat(us)
    h.scan()
    after = os.stat(us)
    check((before.st_ino, before.st_mtime_ns) == (after.st_ino, after.st_mtime_ns), "equal stub rewritten")
    card = os.path.join(tmp, "media/micro/card")
    sd = proton(os.path.join(card, "steamapps/common/Proton 11.0 (ARM64)"))
    write(f"{h.steam}/steamapps/libraryfolders.vdf", libraryfolders([h.steam, card]))
    h.scan()
    check(read(f"{sd}/user_settings.py") == h.stub, "SD library tool has no stub")
    units = h.state()
    check(lib_unit(card) in units and dir_unit(sd) in units, f"SD units {units}")
    os.rename(card, card + ".out")
    h.scan()
    units = h.state()
    check(lib_unit(card) not in units and dir_unit(sd) not in units and lib_unit(h.steam) in units
          and dir_unit(t) in units, f"card removed {units}")
    os.rename(card + ".out", card)
    ino = os.stat(f"{sd}/user_settings.py").st_ino
    h.scan()
    units = h.state()
    check(lib_unit(card) in units and dir_unit(sd) in units and os.stat(f"{sd}/user_settings.py").st_ino == ino,
          f"card inserted {units}")
    return {"units": sorted(u.replace(esc(tmp), "T") for u in units)}


def case_filled(tmp):
    h = Home(tmp)
    hand = os.path.join(h.steam, "compatibilitytools.d/mytool")
    os.makedirs(hand)
    common = h.tool("Proton Experimental (ARM64)")
    os.makedirs(common)
    h.scan()
    units = h.state()
    check(dir_unit(hand) in units and dir_unit(common) not in units, f"empty dirs {units}")
    check(not os.path.exists(f"{hand}/user_settings.py") and not os.path.exists(f"{common}/user_settings.py"),
          "stub in an empty dir")
    for d in (hand, common):
        write(f"{d}/proton", "#!/usr/bin/env python3\n", 0o755)
        write(f"{d}/toolmanifest.vdf.tmp", ARM_MANIFEST)
        h.scan()
        check(not os.path.exists(f"{d}/user_settings.py"), f"{d}: stub before the manifest")
        os.rename(f"{d}/toolmanifest.vdf.tmp", f"{d}/toolmanifest.vdf")
    write(f"{h.steam}/steamapps/appmanifest_4427310.acf", "\"AppState\"\n{\n}\n")
    h.scan()
    for d in (hand, common):
        check(read(f"{d}/user_settings.py") == h.stub, f"{d}: no stub after the manifest rename")
    check(dir_unit(common) in h.state(), "filled common tool not watched")
    link = h.tool("Linked")
    proton(os.path.join(tmp, "elsewhere"))
    os.makedirs(link)
    write(f"{link}/proton", "#!/usr/bin/env python3\n", 0o755)
    os.symlink(os.path.join(tmp, "elsewhere/toolmanifest.vdf"), f"{link}/toolmanifest.vdf")
    os.symlink(os.path.join(tmp, "elsewhere"), h.tool("Symlinked dir"))
    log = h.scan()
    check(not os.path.exists(f"{link}/user_settings.py") and "toolmanifest.vdf not read" in log, f"symlinked manifest followed: {log}")
    check(not os.path.exists(os.path.join(tmp, "elsewhere/user_settings.py")), "symlinked tool dir followed")
    return {}


def case_moves(tmp):
    h = Home(tmp)
    out = {}
    foreign = proton(h.tool("A"))
    write(f"{foreign}/user_settings.py", "user_settings = {'PROTON_LOG': '1'}\n")
    write(f"{foreign}/__pycache__/user_settings.cpython-313.pyc", b"stale")
    write(f"{foreign}/__pycache__/user_settings.cpython-313.opt-1.pyc", b"stale")
    write(f"{foreign}/__pycache__/other.cpython-313.pyc", b"keep")
    ino = os.stat(f"{foreign}/user_settings.py").st_ino
    older = proton(h.tool("B"))
    write(f"{older}/user_settings.py", "MICROOS_PROTON_HOOK = 1\nuser_settings = {}\n")
    write(f"{older}/user_settings.py.pre-stub.1.bak", "older still\n")
    oino = os.stat(f"{older}/user_settings.py").st_ino
    taken = proton(h.tool("C"))
    write(f"{taken}/user_settings.py", "user_settings = {'MINE': '1'}\n")
    write(f"{taken}/user_settings_local.py", "user_settings = {'OTHER': '1'}\n")
    tino = (os.stat(f"{taken}/user_settings.py").st_ino, os.stat(f"{taken}/user_settings_local.py").st_ino)
    absent = proton(h.tool("D"))
    write(f"{absent}/user_settings_local.py", "user_settings = {'KEEP': '1'}\n")
    write(f"{absent}/__pycache__/user_settings.cpython-313.pyc", b"stale")
    odd = proton(h.tool("E"))
    os.symlink(f"{foreign}/user_settings.py", f"{odd}/user_settings.py")
    stale = proton(h.tool("T"))
    write(f"{stale}/user_settings.py", h.stub)
    sino = os.stat(f"{stale}/user_settings.py").st_ino
    for n in (".user_settings.py.abcd_123", ".user_settings.py.keepme", ".user_settings.py.ABCDEFGH"):
        write(f"{stale}/{n}", b"x")
    os.makedirs(f"{stale}/.user_settings.py.zzzzzzzz")
    log = h.scan(TEST_RENAMES="1")
    out["log"] = log.replace(tmp, "T").splitlines()
    for d in (foreign, absent):
        check(f"TEST rename {os.path.realpath(d)}/user_settings.py pyc []" in log, f"{d}: bytecode left at the rename: {log}")
    check(sorted(n for n in os.listdir(stale) if n.startswith(".user_settings.py."))
          == [".user_settings.py.ABCDEFGH", ".user_settings.py.keepme", ".user_settings.py.zzzzzzzz"]
          and os.stat(f"{stale}/user_settings.py").st_ino == sino and "removed the stale .user_settings.py.abcd_123" in log,
          f"stale temp files: {os.listdir(stale)} {log}")
    check(read(f"{foreign}/user_settings.py") == h.stub and os.stat(f"{foreign}/user_settings_local.py").st_ino == ino
          and read(f"{foreign}/user_settings_local.py") == b"user_settings = {'PROTON_LOG': '1'}\n", "foreign file not kept as local")
    check(not os.path.exists(f"{foreign}/__pycache__/user_settings.cpython-313.pyc")
          and not os.path.exists(f"{foreign}/__pycache__/user_settings.cpython-313.opt-1.pyc")
          and os.path.exists(f"{foreign}/__pycache__/other.cpython-313.pyc"), "stale bytecode left")
    check(read(f"{older}/user_settings.py") == h.stub and os.stat(f"{older}/user_settings.py.pre-stub.2.bak").st_ino == oino
          and read(f"{older}/user_settings.py.pre-stub.1.bak") == b"older still\n", "older stub not kept as .pre-stub.2.bak")
    check((os.stat(f"{taken}/user_settings.py").st_ino, os.stat(f"{taken}/user_settings_local.py").st_ino) == tino
          and read(f"{taken}/user_settings_local.py") == b"user_settings = {'OTHER': '1'}\n"
          and "user_settings_local.py exists" in log, "existing local overwritten or not reported")
    check(read(f"{absent}/user_settings.py") == h.stub and read(f"{absent}/user_settings_local.py") == b"user_settings = {'KEEP': '1'}\n"
          and not os.path.exists(f"{absent}/__pycache__/user_settings.cpython-313.pyc"), "absent stub case")
    check(os.path.islink(f"{odd}/user_settings.py") and "not a regular file" in log, "symlinked user_settings.py replaced")
    for d in (foreign, older, taken, absent, odd):
        check(no_temp(d), f"{d}: temp file left")
    for name, setup, us, local, said in (
            ("foreign", "user_settings = {'OLD': '1'}\n", b"user_settings = {'NEW': '1'}\n",
             b"user_settings = {'OLD': '1'}\n", "user_settings_local.py exists"),
            ("absent", None, h.stub, b"user_settings = {'NEW': '1'}\n", "kept as user_settings_local.py")):
        d = proton(h.tool(f"S {name}"))
        if setup:
            write(f"{d}/user_settings.py", setup)
        log = h.scan(TEST_SWAP=os.path.realpath(d))
        out[f"swap {name}"] = [line.replace(tmp, "T") for line in log.splitlines() if "S " in line]
        check(read(f"{d}/user_settings.py") == us and read(f"{d}/user_settings_local.py") == local and no_temp(d)
              and "changed during the scan" in log and said in log, f"swap {name}: {log}")
    for code in ("EPERM", "EXDEV"):
        d = proton(h.tool(f"F {code}"))
        write(f"{d}/user_settings.py", "user_settings = {'X': '1'}\n")
        o = proton(h.tool(f"G {code}"))
        write(f"{o}/user_settings.py", "MICROOS_PROTON_HOOK = 0\n")
        fine = proton(h.tool(f"H {code}"))
        before = {p: os.stat(p).st_ino for p in (f"{d}/user_settings.py", f"{o}/user_settings.py")}
        log = h.scan(TEST_LINK_FAIL=f"{code}:{os.path.realpath(d)}|{os.path.realpath(o)}")
        out[code] = [line.replace(tmp, "T") for line in log.splitlines()]
        check({p: os.stat(p).st_ino for p in before} == before and not os.path.exists(f"{d}/user_settings_local.py")
              and not any(n.endswith(".bak") for n in os.listdir(o)) and read(f"{fine}/user_settings.py") == h.stub
              and no_temp(d) and no_temp(o), f"link {code}: {log}")
    return out


def case_lock(tmp):
    h = Home(tmp)
    t = proton(h.tool("Proton 11.0 (ARM64)"))
    fd = os.open(os.path.join(h.run, "microos-proton-hook.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    p = h.start()
    deadline = time.monotonic() + 1.5
    while time.monotonic() < deadline and p.poll() is None:
        time.sleep(0.1)
    waited = p.poll() is None and not os.path.exists(f"{t}/user_settings.py")
    fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)
    rc = p.wait(timeout=60)
    check(waited and rc == 0 and read(f"{t}/user_settings.py") == h.stub, f"scan did not wait for the lock: {waited} {rc}")
    os.unlink(f"{t}/user_settings.py")
    procs = [h.start() for _ in range(2)]
    rcs = [q.wait(timeout=60) for q in procs]
    logs = [q.stdout.read() for q in procs]
    check(rcs == [0, 0] and read(f"{t}/user_settings.py") == h.stub and no_temp(t)
          and sum(log.count("stub written") for log in logs) == 1, f"two scans at once {rcs} {logs}")
    for state in ("failed", "inactive"):
        units = h.state()
        units[dir_unit(t)] = state
        h.set_state(units)
        h.scan()
        check(h.state().get(dir_unit(t)) == "active", f"a {state} unit is not active after one scan: {h.state()}")
    units = h.state()
    units[dir_unit(t)] = "failed"
    units["microos-proton-hook-dir@gone.path"] = "active"
    units["microos-proton-hook-dir@gonefailed.path"] = "failed"
    h.set_state(units)
    t0 = time.monotonic()
    n = 0
    while n < 7 or time.monotonic() - t0 < 1:
        h.scan()
        n += 1
    units = h.state()
    check(time.monotonic() - t0 < 10 and n >= 7, f"{n} scans took {time.monotonic() - t0:.1f} s")
    check(set(units) == {"microos-proton-hook-media.path", lib_unit(h.steam), dir_unit(t)}
          and all(v == "active" for v in units.values()), f"units after {n} scans: {units}")
    with open(h.calls) as f:
        calls = f.read().splitlines()
    check(any(c.startswith("--user reset-failed") and dir_unit(t) in c for c in calls), f"failed unit not reset: {calls}")
    check(any(c.startswith("--user stop") and "dir@gone.path" in c for c in calls), f"stale unit not stopped: {calls}")
    check(any(c.startswith("--user reset-failed") and "dir@gonefailed.path" in c for c in calls)
          and not any(c.startswith("--user stop") and "dir@gonefailed.path" in c for c in calls),
          f"failed unit no longer wanted not reset: {calls}")
    return {"scans": n}


def constant(name):
    for line in read(SCAN).decode().splitlines():
        if line.startswith(f"{name} = "):
            return float(line.split(" = ", 1)[1])
    return None


def case_race(tmp):
    h = Home(tmp)
    out = {}
    script = os.path.join(tmp, "during.py")
    flag = os.path.join(tmp, "during.flag")
    stage = os.path.join(tmp, "stage")

    def during(*lines):
        if os.path.exists(flag):
            os.unlink(flag)
        body = "".join(f"    {line}\n" for line in lines)
        write(script, f"import os\nif not os.path.exists({flag!r}):\n    open({flag!r}, 'w').close()\n{body}")

    def scan(name):
        log = h.scan(TEST_DURING=script)
        out[name] = [line.replace(tmp, "T") for line in log.splitlines()]
        return log

    t = proton(h.tool("Proton 11.0 (ARM64)"))
    during(f"os.unlink({t + '/user_settings.py'!r})")
    log = scan("removed")
    check(read(f"{t}/user_settings.py") == h.stub and log.count("stub written") == 2, f"removal during a scan: {log}")
    q = proton(h.tool("Q"))
    log = h.scan(TEST_UNLINK_AFTER=os.path.realpath(q))
    out["removed after the rename"] = [line.replace(tmp, "T") for line in log.splitlines()]
    check(read(f"{q}/user_settings.py") == h.stub and log.count("Q: stub written") == 2, f"removal after the rename: {log}")
    a = proton(h.tool("A"))
    log = h.scan(TEST_APPEND_AFTER=os.path.realpath(a))
    out["written to after the rename"] = [line.replace(tmp, "T") for line in log.splitlines()]
    check(read(f"{a}/user_settings.py") == h.stub and read(f"{a}/user_settings.py.pre-stub.1.bak") == h.stub + b"\n"
          and "A: older stub kept as user_settings.py.pre-stub.1.bak" in log, f"write after the rename: {log}")
    new = proton(os.path.join(stage, "Proton Next (ARM64)"))
    during(f"os.rename({new!r}, {h.tool('Proton Next (ARM64)')!r})")
    scan("new tool")
    check(read(h.tool("Proton Next (ARM64)/user_settings.py")) == h.stub
          and dir_unit(h.tool("Proton Next (ARM64)")) in h.state(), f"new tool during a scan: {h.state()}")
    hand = os.path.join(h.steam, "compatibilitytools.d/mine")
    write(f"{hand}/proton", "#!/usr/bin/env python3\n", 0o755)
    write(f"{hand}/toolmanifest.vdf.tmp", ARM_MANIFEST)
    during(f"os.rename({hand + '/toolmanifest.vdf.tmp'!r}, {hand + '/toolmanifest.vdf'!r})")
    scan("manifest rename")
    check(read(f"{hand}/user_settings.py") == h.stub, "manifest rename during a scan")
    card = os.path.join(tmp, "card")
    sd = proton(os.path.join(stage, "card/steamapps/common/Proton 11.0 (ARM64)"))
    write(f"{h.steam}/steamapps/libraryfolders.vdf", libraryfolders([h.steam, card]))
    during(f"os.rename({os.path.join(stage, 'card')!r}, {card!r})")
    scan("card")
    check(read(f"{card}/steamapps/common/Proton 11.0 (ARM64)/user_settings.py") == h.stub and lib_unit(card) in h.state(),
          f"card during a scan: {h.state()}")
    card2 = os.path.join(tmp, "card2")
    proton(os.path.join(card2, "steamapps/common/Proton 11.0 (ARM64)"))
    lf = f"{h.steam}/steamapps/libraryfolders.vdf"
    during(f"open({lf!r}, 'w').write({libraryfolders([h.steam, card, card2])!r})")
    scan("libraryfolders in place")
    check(read(f"{card2}/steamapps/common/Proton 11.0 (ARM64)/user_settings.py") == h.stub and lib_unit(card2) in h.state(),
          f"libraryfolders.vdf written in place during a scan: {h.state()}")
    def lists():
        with open(h.calls) as f:
            n = sum(1 for c in f if c.startswith("--user list-units"))
        with open(h.calls, "w"):
            pass
        return n

    lists()
    acf = [f"{d}/steamapps/appmanifest_1.acf" for d in (h.steam, card)]
    during(*(f"open({p!r}, 'w').close()" for p in acf))
    log = scan("steamapps written")
    n = lists()
    check(n == 1 and all(os.path.exists(p) for p in acf), f"steamapps written during a scan: {n} passes {log}")
    sa = h.steam + "/steamapps/common"
    write(script, f"import os\nos.mkdir(os.path.join({sa!r}, 'churn' + str(len(os.listdir({sa!r})))))\n")
    log = scan("churn")
    n = lists()
    passes = constant("PASSES")
    check(n == passes and f"still changing after {passes:g} passes" in log, f"churn: {n} passes {log}")
    return out


def case_media(tmp):
    h = Home(tmp)
    out = {}
    wait = constant("MOUNT_WAIT")
    media = os.path.join(tmp, "media/micro")
    card = os.path.join(media, "card")
    os.makedirs(card)
    t = proton(h.tool("Proton 11.0 (ARM64)"))
    write(f"{h.steam}/steamapps/libraryfolders.vdf", libraryfolders([h.steam, card]))
    staged = os.path.join(tmp, "staged")
    proton(os.path.join(staged, "steamapps/common/Proton 11.0 (ARM64)"))
    mount = os.path.join(tmp, "mount.py")
    write(mount, f"import os\nos.rename({os.path.join(staged, 'steamapps')!r}, {card + '/steamapps'!r})\n")
    t0 = time.monotonic()
    log = h.scan(MICROOS_MEDIA=media, TEST_ON_SLEEP=mount)
    out["mounting"] = {"took": round(time.monotonic() - t0, 2), "log": log.replace(tmp, "T").splitlines()}
    sd = os.path.join(card, "steamapps/common/Proton 11.0 (ARM64)")
    check(read(f"{sd}/user_settings.py") == h.stub and lib_unit(card) in h.state() and dir_unit(sd) in h.state(),
          f"card mounted while the scan waits: {log} {h.state()}")
    shutil.rmtree(f"{card}/steamapps")
    card2 = os.path.join(media, "card2")
    os.makedirs(card2)
    write(f"{h.steam}/steamapps/libraryfolders.vdf", libraryfolders([h.steam, card, card2]))
    t0 = time.monotonic()
    log = h.scan(MICROOS_MEDIA=media)
    took = time.monotonic() - t0
    out["never mounted"] = {"took": round(took, 2), "log": log.replace(tmp, "T").splitlines()}
    check(wait <= took < wait + 3 and log.count("not mounted after") == 1 and f"/card: not mounted after {wait:g} s" in log
          and lib_unit(card) not in h.state() and read(f"{t}/user_settings.py") == h.stub,
          f"two cards never mounted: {took:.2f} s {log} {h.state()}")
    os.rmdir(card2)
    for name, extra in (("mounted without a library", {"TEST_MOUNTED": card}), ("no mount dir", {})):
        if not extra:
            os.rmdir(card)
        t0 = time.monotonic()
        log = h.scan(MICROOS_MEDIA=media, **extra)
        took = time.monotonic() - t0
        out[name] = round(took, 2)
        check(took < wait / 2 and "not mounted" not in log and lib_unit(card) not in h.state(), f"{name}: {took:.2f} s {log}")
    return out


def case_names(tmp):
    h = Home(tmp)
    t = proton(h.tool(os.fsdecode(b"Proton \xff\xfe (ARM64)")))
    nonchars = [proton(h.tool(os.fsdecode(n))) for n in (b"Proton \xef\xbf\xbf (ARM64)", b"Proton \xef\xb7\x90 (ARM64)")]
    log = h.scan()
    for d in nonchars:
        name = os.path.basename(d)
        check(read(f"{d}/user_settings.py") == h.stub and log.count(f"{name}: name is not UTF-8, not watched") == 1,
              f"noncharacter tool dir {ascii(name)}: {log}")
    check(read(f"{t}/user_settings.py") == h.stub and "Proton \\udcff\\udcfe (ARM64): stub written" in log
          and h.state() == {"microos-proton-hook-media.path": "active", lib_unit(h.steam): "active"}
          and log.count("Proton \\udcff\\udcfe (ARM64): name is not UTF-8, not watched") == 1,
          f"non UTF-8 tool dir: {log} {h.state()}")
    return {"units": sorted(u.replace(esc(tmp), "T") for u in h.state())}


def case_errors(tmp):
    h = Home(tmp)
    t = proton(h.tool("Proton 11.0 (ARM64)"))
    write(f"{h.steam}/steamapps/libraryfolders.vdf", '"libraryfolders"\n{\n')
    log = h.scan()
    check(read(f"{t}/user_settings.py") == h.stub and "internal library only" in log, f"bad libraryfolders.vdf {log}")
    p = subprocess.run([sys.executable, "-c", DRIVER, SCAN], env=h.env(MICROOS_SHARE=os.path.join(tmp, "none")),
                       capture_output=True, text=True, timeout=60)
    check(p.returncode == 1 and "error" in p.stdout, f"missing share: {p.returncode} {p.stdout}")
    return {}


def main():
    results = {}
    for case in (case_units, case_escape, case_fresh, case_filled, case_moves, case_lock, case_race, case_media, case_names,
                 case_errors):
        tmp = tempfile.mkdtemp()
        try:
            results[case.__name__] = case(tmp)
        except Exception as e:
            check(False, f"{case.__name__}: {type(e).__name__}: {e}")
        finally:
            shutil.rmtree(tmp)
    if failures:
        print(f"proton hook installer: {len(failures)} failures", file=sys.stderr)
        return 1
    print(f"proton hook installer: ok, python {sys.version.split()[0]}, {checks[0]} checks in {len(results)} groups")
    return 0


sys.exit(main())
