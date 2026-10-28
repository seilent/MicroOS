#!/usr/bin/env python3
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
sys.dont_write_bytecode = True
import fixture as fx

tree = os.environ.get("MICROOS_TREE", os.path.join(here, "..", "..", "system_files"))
HELPER = os.path.join(tree, "usr/libexec/microos/microos-steam-compat")
T = "proton_11-arm64"
START = 8 << 20
CAP = 64 << 20
REFRESH = "microos-steam-compat-refresh.service"
ASKED = f"systemctl --user start --no-block {REFRESH} started, its exit is not checked"
failures = []


def check(cond, what):
    if not cond:
        failures.append(what)
        print(f"FAIL: {what}", file=sys.stderr)


def until(cond, limit=10):
    end = time.monotonic() + limit
    while not cond():
        if time.monotonic() > end:
            return False
        time.sleep(0.01)
    return True


def alive(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rpartition(")")[2].split()[0] != "Z"
    except OSError:
        return False


def opened(pid, path):
    path = os.path.realpath(path)
    try:
        fds = os.listdir(f"/proc/{pid}/fd")
    except OSError:
        return False
    for fd in fds:
        try:
            if os.readlink(f"/proc/{pid}/fd/{fd}") == path:
                return True
        except OSError:
            pass
    return False


class Home:
    def __init__(self, helper=HELPER):
        self.dir = tempfile.mkdtemp()
        self.home = os.path.join(self.dir, "home")
        self.root = os.path.join(self.home, ".local/share/Steam")
        self.state = os.path.join(self.home, ".local/state/microos-steam-compat")
        self.helper = helper
        self.stub = os.path.join(self.dir, "stub")
        self.asks = os.path.join(self.dir, "systemctl.log")
        self.vk = os.path.join(self.dir, "vk-features")
        os.makedirs(self.root)
        fx.write(f"{self.stub}/systemctl", f"#!/bin/sh\necho \"$*\" >> '{self.asks}'\n", 0o755)
        fx.write(self.vk, "storageBuffer8BitAccess=0\n")

    def appinfo(self, games=None, x86_maps=None, arm_maps=None, **kw):
        apps = {891390: fx.x86(x86_maps), 3043620: fx.arm(arm_maps, kw.pop("target", True))}
        apps.update(games or {})
        fx.write(f"{self.root}/appcache/appinfo.vdf", fx.appinfo(apps, **kw))

    def config(self, entries, extra=None):
        fx.write(f"{self.root}/config/config.vdf", fx.config_vdf(entries, extra))

    def spawn(self, mode="start", env=None):
        e = {"HOME": self.home, "PATH": f"{self.stub}:/usr/bin:/bin", "MICROOS_VK_FEATURES": self.vk}
        e.update(env or {})
        self.t0 = time.monotonic()
        return subprocess.Popen([self.helper] + ([mode] if mode else []), env=e, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)

    def collect(self, p):
        try:
            self.out, self.err = p.communicate(timeout=20)
        finally:
            if p.poll() is None:
                p.kill()
                p.communicate()
        self.took = time.monotonic() - self.t0
        self.rc = p.returncode
        return self.out

    def run(self, mode="start", env=None):
        return self.collect(self.spawn(mode, env))

    def lines(self):
        return [line.removeprefix("microos-steam-compat: ") for line in self.err.splitlines()]

    def has(self, text):
        return any(text in line for line in self.lines())

    def asked(self):
        end = time.monotonic() + 5
        data = ""
        while time.monotonic() < end:
            try:
                with open(self.asks) as f:
                    data = f.read()
            except FileNotFoundError:
                pass
            if data.endswith("\n"):
                break
            time.sleep(0.01)
        return set(data.splitlines())

    def record(self, name):
        with open(os.path.join(self.state, name)) as f:
            return json.load(f)

    def clean(self):
        shutil.rmtree(self.dir)


def copy_tree():
    base = tempfile.mkdtemp()
    for d in ("usr/libexec/microos", "usr/share/microos/python"):
        os.makedirs(os.path.join(base, d))
    helper = os.path.join(base, "usr/libexec/microos/microos-steam-compat")
    shutil.copy2(HELPER, helper)
    shutil.copytree(os.path.join(tree, "usr/share/microos/python/microos_steam"),
                    os.path.join(base, "usr/share/microos/python/microos_steam"))
    return base, helper


def value(*appids, tool=T):
    return ",".join(f"{a} 250 {tool}" for a in appids)


def exp_games(*appids):
    return {a: fx.game(a, deck="proton-experimental") for a in appids}


def case_computed():
    h = Home()
    h.appinfo({**exp_games(100, 101, 102), 103: fx.game(103, deck="proton-stable"),
               104: fx.game(104, deck="proton-stable", maps=[fx.app_mapping("proton_experimental")])},
              {"105": fx.manifest_entry(105, "proton-experimental")})
    h.config([(101, "proton-experimental-arm64", "250"), (102, "GE-Proton10-1", "75"), (100, "", "250")])
    out = h.run()
    check(out == value(100, 104, 105) and h.rc == 0, f"computed: {out!r} rc {h.rc} {h.err}")
    check(h.has(f"computed: 3 titles to {T}, 2 skipped by user entries"), f"computed line: {h.lines()}")
    rec = h.record("start")
    check(rec["result"] == "computed" and rec["entries"] == [[100, T], [104, T], [105, T]], f"start record {rec}")
    for name, mode in (("", 0o700), ("last", 0o600), ("start", 0o600)):
        m = stat.S_IMODE(os.stat(os.path.join(h.state, name)).st_mode)
        check(m == mode, f"{name or 'state dir'} mode {m:o}")
    out = h.run()
    check(out == value(100, 104, 105) and h.has("2 skipped by user entries, cached"), f"cache hit: {out!r} {h.lines()}")
    h.config([(101, "proton-experimental-arm64", "250")])
    out = h.run()
    check(out == value(100, 102, 104, 105) and h.has("cached"), f"config change on a hit: {out!r} {h.lines()}")
    os.remove(f"{h.root}/config/config.vdf")
    out = h.run()
    check(out == value(100, 101, 102, 104, 105), f"no config.vdf: {out!r} {h.lines()}")
    check(not h.has(ASKED) and sorted(os.listdir(h.state)) == ["last", "start"], f"computed: {os.listdir(h.state)}")
    h.clean()


def case_forward_usage():
    h = Home()
    h.appinfo(exp_games(110))
    out = h.run("forward")
    check(out == value(110) and not os.path.exists(os.path.join(h.state, "start")), f"forward: {out!r}")
    check(os.path.exists(os.path.join(h.state, "last")), "forward does not keep the computed list")
    for mode in ("", "other", "first"):
        out = h.run(mode)
        check(out == "" and h.rc == 2, f"usage {mode!r}: {out!r} rc {h.rc}")
    h.clean()


def case_default_tool():
    h = Home()
    h.appinfo(exp_games(120, 121))
    for name, default, want in (("other", "GE-Proton10-1", value(120, 121, tool="GE-Proton10-1")),
                                ("stable", "proton-stable", value(120, 121)),
                                ("x86 stable", "proton_11", value(120, 121, tool="proton_11")),
                                ("experimental", "proton-experimental", ""),
                                ("experimental arm", "proton-experimental-arm64", ""),
                                ("bad name", "my tool", "")):
        h.config([(0, default, "75")])
        out = h.run()
        check(out == want, f"default {name}: {out!r}, want {want!r} {h.lines()}")
    check(h.has("is not a usable name, no mappings"), f"default bad name line: {h.lines()}")
    h.clean()


def case_config_failed():
    h = Home()
    h.appinfo(exp_games(130))
    h.config([])
    check(h.run() == value(130), "config: first run")
    with open(f"{h.root}/config/config.vdf") as f:
        text = f.read()
    for name, setup in (("malformed", lambda p: fx.write(p, text[: len(text) // 2])),
                        ("fifo", lambda p: os.mkfifo(p)),
                        ("dir", lambda p: os.mkdir(p))):
        p = f"{h.root}/config/config.vdf"
        os.remove(p) if not os.path.isdir(p) else os.rmdir(p)
        setup(p)
        out = h.run()
        check(out == "" and h.rc == 0 and h.took < 5, f"config {name}: {out!r} rc {h.rc} took {h.took:.1f}")
        check(h.has("config/config.vdf unreadable") and h.record("start")["result"] == "config-failed",
              f"config {name} line: {h.lines()}")
    h.appinfo(exp_games(130, 131))
    last = os.path.join(h.state, "last")
    os.remove(last)
    os.mkdir(last)
    out = h.run("refresh")
    check(out == "" and h.rc == 0 and h.has(f"{last} not written") and h.has("computed: 2 titles not kept")
          and not h.has("kept for a later start"), f"refresh with config failed and a failed save: {out!r} rc {h.rc} {h.lines()}")
    os.rmdir(last)
    out = h.run("refresh")
    check(out == "" and h.rc == 0 and h.has("config/config.vdf unreadable") and h.has("computed: 2 titles kept for a later start")
          and h.record("last")["titles"] == [130, 131], f"refresh with config failed: {out!r} rc {h.rc} {h.lines()}")
    os.rmdir(f"{h.root}/config/config.vdf")
    out = h.run()
    check(out == value(130, 131) and h.has("cached"), f"start after a refresh with config failed: {out!r} {h.lines()}")
    h.clean()


def case_detached():
    h = Home()
    pid = os.path.join(h.dir, "systemctl.pid")
    fx.write(f"{h.stub}/systemctl", f"#!/bin/sh\necho $$ > '{pid}.tmp'\nmv '{pid}.tmp' '{pid}'\nexec sleep 5\n", 0o755)
    big = f"{h.root}/appcache/appinfo.vdf"
    fx.write(big, b"")
    os.truncate(big, START + 1)
    out = h.run()
    check(out == "" and h.rc == 0 and h.has(ASKED), f"detached: {out!r} rc {h.rc} {h.lines()}")
    check(until(lambda: os.path.exists(pid), 5), "detached: systemctl did not run")
    with open(pid) as f:
        child = int(f.read())
    check(alive(child), f"detached: the run ended only after systemctl {child} did, took {h.took:.1f}")
    try:
        os.kill(child, signal.SIGKILL)
    except ProcessLookupError:
        pass
    h.clean()


def case_tmp():
    h = Home()
    h.appinfo(exp_games(250))
    check(h.run() == value(250), "tmp: first run")
    last = os.path.join(h.state, "last")
    os.remove(last)
    os.mkdir(last)
    out = h.run()
    check(out == value(250) and h.has(f"{last} not written") and not [n for n in os.listdir(h.state) if n.endswith(".tmp")],
          f"tmp after a failed save: {os.listdir(h.state)} {h.lines()}")
    os.rmdir(last)
    dead, live, odd = f"last.{(1 << 22) + 1}.tmp", f"last.{os.getpid()}.tmp", "start.x.tmp"
    for name in (dead, live, odd):
        fx.write(os.path.join(h.state, name), "{")
    h.run("start")
    check(sorted(os.listdir(h.state)) == sorted(["last", "start", dead, live, odd]), f"tmp swept by a start: {os.listdir(h.state)}")
    out = h.run("refresh")
    check(out == "" and h.rc == 0 and sorted(os.listdir(h.state)) == sorted(["last", "start", live])
          and h.has(f"{h.state}/{dead} removed, its writer is gone") and h.has(f"{h.state}/{odd} removed, its writer is gone"),
          f"tmp sweep: {os.listdir(h.state)} {h.lines()}")
    h.clean()


def case_branch_timeout():
    base, helper = copy_tree()
    h = Home(helper)
    h.appinfo({**exp_games(260), 261: fx.game(261, deck="proton-stable", maps=[fx.app_mapping("proton_experimental", branch="beta")])})
    fx.write(f"{h.root}/steamapps/appmanifest_261.acf", fx.appmanifest(261, beta="beta"))
    check(h.run() == value(260, 261), f"branch timeout: first run {h.lines()}")
    libraries = os.path.join(base, "usr/share/microos/python/microos_steam/libraries.py")
    for name in ("installed_branch(path, deadline=None)", "library_paths(steam_root, deadline=None)"):
        with open(libraries, "a") as f:
            f.write(f"\n\ndef {name}:\n    raise TimeoutError(\"time budget spent\")\n")
        out = h.run()
        check(out == value(260, 261) and h.has("failed: time budget spent, 2 titles from the last computed list")
              and not h.has("do not count"), f"branch timeout in {name}: {out!r} {h.lines()}")
    h.clean()
    shutil.rmtree(base)


def case_failed_absent():
    h = Home()
    out = h.run()
    check(out == "" and h.has("absent: no appcache/appinfo.vdf, no last computed list"), f"absent first: {h.lines()}")
    check(h.record("start")["result"] == "absent", "absent start record")
    h.appinfo(exp_games(140, 141), magic=0x07564428)
    out = h.run()
    check(out == "" and h.has("failed: magic") and h.has("no last computed list"), f"failed without last: {h.lines()}")
    h.appinfo(exp_games(140, 141))
    check(h.run() == value(140, 141), "good run")
    h.config([(141, "proton-experimental-arm64", "250")])
    h.appinfo(exp_games(140, 141, 142), magic=0x07564428)
    out = h.run()
    check(out == value(140) and h.has("failed: magic 0x07564428") and h.has("1 titles from the last computed list"),
          f"failed with last: {out!r} {h.lines()}")
    h.appinfo(exp_games(140, 141), raw={891390: b"\0\0\0\0\0\x05\x08"})
    out = h.run()
    check(out == value(140) and h.has("failed: app 891390"), f"bad 891390: {out!r} {h.lines()}")
    fx.write(f"{h.root}/appcache/appinfo.vdf", fx.appinfo({3043620: fx.arm(), **exp_games(140)}))
    out = h.run()
    check(out == value(140) and h.has("failed: app 891390 is not in the cache"), f"no 891390: {out!r} {h.lines()}")
    os.remove(f"{h.root}/appcache/appinfo.vdf")
    h.config([(0, "GE-Proton10-1", "75")])
    out = h.run()
    check(out == value(140, 141, tool="GE-Proton10-1") and h.has("absent: no appcache/appinfo.vdf, 2 titles"),
          f"absent with last and a default: {out!r} {h.lines()}")
    check(h.record("start")["result"] == "absent", "absent start record with last")
    os.mkfifo(f"{h.root}/appcache/appinfo.vdf")
    out = h.run()
    check(h.took < 5 and h.has("failed:") and out == value(140, 141, tool="GE-Proton10-1"), f"fifo appinfo: {h.lines()}")
    big = f"{h.root}/appcache/appinfo.vdf"
    os.remove(big)
    fx.write(big, b"")
    os.truncate(big, START + 1)
    out = h.run("forward")
    check(out == value(140, 141, tool="GE-Proton10-1") and h.has(f"over {START}") and not h.has(ASKED),
          f"forward over the start cap: {out!r} {h.lines()}")
    out = h.run()
    check(out == value(140, 141, tool="GE-Proton10-1") and h.took < 5
          and h.has(f"failed: {big}: {START + 1} bytes, over {START}, 2 titles from the last computed list")
          and h.has(ASKED), f"appinfo over the start cap: {out!r} {h.lines()}")
    check(h.asked() == {f"--user start --no-block {REFRESH}"}, f"start over the cap: systemctl {h.asked()}")
    out = h.run("refresh")
    check(out == "" and h.has("failed: magic") and not h.has(ASKED), f"refresh of the sparse file: {out!r} {h.lines()}")
    os.truncate(big, CAP + 1)
    out = h.run("refresh")
    check(out == "" and h.rc == 0 and h.took < 5
          and h.has(f"failed: {big}: {CAP + 1} bytes, over {CAP}, 2 titles from the last computed list"),
          f"appinfo over the refresh cap: {out!r} {h.lines()}")
    h.clean()


def padded(appid, size):
    g = fx.game(appid)
    g["common"]["description"] = "x" * size
    return g


def case_refresh():
    h = Home()
    h.appinfo(exp_games(210, 211))
    out = h.run("refresh")
    check(out == "" and h.rc == 0 and h.has(f"computed: 2 titles to {T}") and not h.has(ASKED), f"refresh: {out!r} {h.lines()}")
    check(sorted(os.listdir(h.state)) == ["last"], f"refresh state {os.listdir(h.state)}")
    check(h.run() == value(210, 211) and h.has("cached") and not h.has(ASKED), f"start after a refresh: {h.lines()}")
    h.appinfo({**exp_games(210, 211, 212), 213: padded(213, START)})
    path = f"{h.root}/appcache/appinfo.vdf"
    check(START < os.path.getsize(path) < CAP, f"padded size {os.path.getsize(path)}")
    out = h.run()
    check(out == value(210, 211) and h.has(f"over {START}, 2 titles from the last computed list") and h.has(ASKED),
          f"start over the start cap: {out!r} {h.lines()}")
    check(h.asked() == {f"--user start --no-block {REFRESH}"}, f"start over the start cap: systemctl {h.asked()}")
    out = h.run("refresh")
    check(out == "" and h.has(f"computed: 3 titles to {T}") and not h.has("over") and h.took < 5,
          f"refresh over the start cap: {out!r} {h.lines()}")
    st = os.stat(path)
    check(h.record("last")["key"]["appinfo"] == [st.st_ino, st.st_size, st.st_mtime_ns], "refresh key")
    out = h.run()
    check(out == value(210, 211, 212) and h.has("cached") and not h.has(ASKED), f"start after the refresh: {out!r} {h.lines()}")
    os.remove(path)
    out = h.run("refresh")
    check(out == "" and h.rc == 0 and h.has("absent: no appcache/appinfo.vdf, 3 titles") and not h.has(ASKED),
          f"refresh absent: {h.lines()}")
    h.clean()


def case_budget():
    base, helper = copy_tree()
    h = Home(helper)
    h.appinfo(exp_games(220, 221))
    h.run("refresh")
    with open(helper) as f:
        src = f.read()
    with open(helper, "w") as f:
        f.write(src.replace("\nBUDGET = 2.0\n", "\nBUDGET = -1.0\n", 1))
    out = h.run()
    check(out == value(220, 221) and h.has("failed: time budget spent, 2 titles from the last computed list") and h.has(ASKED),
          f"start past its budget: {out!r} {h.lines()}")
    check(h.asked() == {f"--user start --no-block {REFRESH}"}, f"start past its budget: systemctl {h.asked()}")
    out = h.run("refresh")
    check(out == "" and h.has(f"computed: 2 titles to {T}"), f"refresh with a spent start budget: {h.lines()}")
    out = h.run()
    check(out == value(220, 221) and h.has("cached") and not h.has(ASKED), f"start past its budget, cached: {out!r} {h.lines()}")
    h.clean()
    shutil.rmtree(base)


def case_refresh_change():
    base, helper = copy_tree()
    with open(os.path.join(base, "usr/share/microos/python/microos_steam/compat.py"), "a") as f:
        f.write("""

_titles = experimental_titles


def experimental_titles(apps, bad, branches, deadline=None):
    import os
    once, path = os.environ.get("TOUCH_ONCE", ""), os.environ.get("TOUCH", "")
    if os.path.exists(once) or os.environ.get("TOUCH_ALWAYS"):
        if os.path.exists(once):
            os.remove(once)
        st = os.stat(path)
        os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns + 1))
    return _titles(apps, bad, branches, deadline)
""")
    h = Home(helper)
    h.appinfo(exp_games(230))
    path = f"{h.root}/appcache/appinfo.vdf"
    once = os.path.join(h.dir, "once")
    fx.write(once, "")
    out = h.run("refresh", {"TOUCH_ONCE": once, "TOUCH": path})
    changed = [x for x in h.lines() if x == "appcache/appinfo.vdf changed while it was read"]
    computed = [x for x in h.lines() if x.startswith("computed: 1 titles")]
    st = os.stat(path)
    check(out == "" and len(changed) == 1 and len(computed) == 2
          and h.record("last")["key"]["appinfo"] == [st.st_ino, st.st_size, st.st_mtime_ns],
          f"refresh after a change: {h.lines()}")
    os.utime(path, ns=(1, 1))
    h.run("refresh", {"TOUCH": path, "TOUCH_ALWAYS": "1"})
    changed = [x for x in h.lines() if x == "appcache/appinfo.vdf changed while it was read"]
    computed = [x for x in h.lines() if x.startswith("computed: 1 titles")]
    check(h.rc == 0 and len(changed) == 3 and len(computed) == 3, f"refresh passes: {h.lines()}")
    h.clean()
    shutil.rmtree(base)


def case_bad_state():
    h = Home()
    h.appinfo(exp_games(240, 241))
    check(h.run() == value(240, 241), "bad state: first run")
    for name in ("last", "start"):
        fx.write(os.path.join(h.state, name), "[" * 100000)
    out = h.run()
    check(out == value(240, 241) and h.rc == 0 and h.has(f"{h.state}/last: ") and h.has(f"{h.state}/start: ")
          and h.has("computed: 2 titles") and not h.has("cached"), f"deep json state: {out!r} rc {h.rc} {h.lines()}")
    last = h.record("last")
    last["key"]["manifests"] = {"\u00b2": None}
    fx.write(os.path.join(h.state, "last"), json.dumps(last))
    out = h.run()
    check(out == value(240, 241) and h.rc == 0 and h.has("failed: ValueError: ") and h.has("2 titles from the last computed list"),
          f"bad cache key: {out!r} rc {h.rc} {h.lines()}")
    h.clean()


def case_corrupt_app():
    h = Home()
    h.appinfo(exp_games(150, 151, 152), raw={151: b"\0\0\0\0\0\x05junk\x08\x08"})
    out = h.run()
    check(out == value(150, 152) and h.has("1 apps unreadable in appinfo.vdf and skipped: 151"), f"corrupt app: {out!r} {h.lines()}")
    h.clean()


def case_target_and_shadows():
    h = Home()
    h.appinfo(exp_games(160), target=False)
    out = h.run()
    check(out == "" and h.has(f"{T} is not a tool in 3043620, no mappings") and h.has("proton-stable resolves to"),
          f"no target: {out!r} {h.lines()}")
    h.appinfo(exp_games(161, 162), {"162": fx.manifest_entry(162, "proton-hotfix")})
    out = h.run()
    check(out == value(161) and h.has("162: Valve's proton-hotfix at 100 wins, runs as proton-stable, not mapped"),
          f"shadow: {out!r} {h.lines()}")
    check(not h.has("proton-stable resolves to"), f"proton-stable line with the target: {h.lines()}")
    h.clean()


def case_cache():
    base, helper = copy_tree()
    h = Home(helper)
    m = fx.app_mapping
    h.appinfo({**exp_games(170), 171: fx.game(171, deck="proton-stable", maps=[m("proton_experimental", branch="beta")])})
    fx.write(f"{h.root}/steamapps/libraryfolders.vdf", fx.libraryfolders([h.root, h.dir + "/sd"]))
    fx.write(f"{h.dir}/sd/steamapps/appmanifest_171.acf", fx.appmanifest(171))
    check(h.run() == value(170) and not h.has("cached"), f"cache first: {h.lines()}")
    check(h.run() == value(170) and h.has("cached"), f"cache hit: {h.lines()}")
    fx.write(f"{h.dir}/sd/steamapps/appmanifest_171.acf", fx.appmanifest(171, beta="beta"))
    check(h.run() == value(170, 171) and not h.has("cached"), f"cache miss on the manifest: {h.lines()}")
    check(h.run() == value(170, 171) and h.has("cached"), f"cache hit after the manifest: {h.lines()}")
    for path in (os.path.join(base, "usr/share/microos/python/microos_steam/compat.py"), helper):
        with open(path, "a") as f:
            f.write("\n")
        h.run()
        check(not h.has("cached"), f"cache miss on {os.path.basename(path)}: {h.lines()}")
        check(h.run() == value(170, 171) and h.has("cached"), f"cache hit after {os.path.basename(path)}")
    h.appinfo({**exp_games(170, 172), 171: fx.game(171, deck="proton-stable", maps=[m("proton_experimental", branch="beta")])})
    check(h.run() == value(170, 171, 172) and not h.has("cached"), f"cache miss on appinfo: {h.lines()}")
    fx.write(f"{h.state}/last", "{not json")
    check(h.run() == value(170, 171, 172) and h.has("last: ") and not h.has("cached"), f"corrupt last: {h.lines()}")
    with open(os.path.join(base, "usr/share/microos/python/microos_steam/compat.py"), "a") as f:
        f.write("\n\ndef experimental_titles(apps, bad, branches, deadline=None):\n    raise RuntimeError(\"boom\")\n")
    out = h.run()
    check(out == value(170, 171, 172) and h.rc == 0 and h.has("failed: RuntimeError: boom, 3 titles from the last computed list"),
          f"unexpected error: {out!r} rc {h.rc} {h.lines()}")
    h.clean()
    shutil.rmtree(base)


def case_compat_log():
    h = Home()
    h.appinfo(exp_games(180, 181, 182))
    h.run()
    check(not h.has("previous start"), f"first start compares: {h.lines()}")
    h.run()
    check(h.has("previous start: no logs/compat_log.txt"), f"missing log: {h.lines()}")
    log = f"{h.root}/logs/compat_log.txt"
    old = "".join(f'[2026-01-01 00:00:00] Mapping AppID {a} to tool "{T}" with priority 250\n' for a in (180, 181, 182))
    fx.write(log, (old + "\n\n[2026-01-01 00:01:00] Client version: 1000000001\n"
                   '[2026-01-01 00:01:00] Mapping AppID 0 to tool "proton-stable" with priority 75\n'
                   f'[2026-01-01 00:01:00] Mapping AppID 180 to tool "{T}" with priority 250\n'
                   f'[2026-01-01 00:01:00] Mapping AppID 181 to tool "proton-experimental-arm64" with priority 250\n'
                   '[2026-01-01 00:01:05] Recording non-user mapping for 182 at priority 85 to tool proton-experimental\n'
                   f'[2026-01-01 00:01:05] Skip mapping AppID 182 to tool "proton-experimental" with priority 85: mapping to tool "{T}" with priority 250 already exists.\n')
             .replace("\n", "\r\n").encode())
    h.run()
    check(h.has("previous start: 2 of 3 mappings not in logs/compat_log.txt: 181 182"), f"log compare: {h.lines()}")
    fx.write(log, old)
    h.run()
    check(h.has("previous start: no client start in logs/compat_log.txt"), f"log without a start: {h.lines()}")
    fx.write(log, "\n\n[x] Client version: 1\n" + "".join(
        f'[x] Mapping AppID {a} to tool "{T}" with priority 250\n' for a in (180, 181, 182)))
    h.run()
    check(not h.has("previous start"), f"all taken: {h.lines()}")
    h.run("forward")
    check(not h.has("previous start"), f"forward compares: {h.lines()}")
    h.clean()


def case_bound():
    h = Home()
    n = 6000
    h.appinfo({}, {str(a): fx.manifest_entry(a, "proton-experimental") for a in range(1000000, 1000000 + n)})
    out = h.run()
    check(0 < len(out) <= 131044 and out.count(",") + 1 < n and h.has("titles left out"),
          f"bound: {len(out)} bytes, {out.count(',') + 1} entries, {h.lines()[:3]}")
    check(out.split(",")[0] == "1000000 250 proton_11-arm64", "bound keeps the lowest appids first")
    check(len(h.record("start")["entries"]) == out.count(",") + 1, "bound: start record holds titles left out")
    h.clean()


def case_vk_features():
    h = Home()
    h.appinfo(exp_games(190, 191))
    check(h.run() == value(190, 191) and not h.has("vk-features"), f"vk 0: {h.lines()}")
    fx.write(h.vk, "storageBuffer8BitAccess=1\n")
    out = h.run()
    check(out == "" and h.has(f"storageBuffer8BitAccess=1 in {h.vk}, no mappings"), f"vk 1: {out!r} {h.lines()}")
    check(h.record("start") == {"version": 1, "result": "not-needed", "entries": []}, f"vk 1 record {h.record('start')}")
    os.remove(h.vk)
    out = h.run()
    check(out == value(190, 191) and h.has(f"{h.vk} missing, mapping"), f"vk missing: {out!r} {h.lines()}")
    for name, setup in (("garbage", lambda: fx.write(h.vk, "nonsense\n")),
                        ("value 2", lambda: fx.write(h.vk, "storageBuffer8BitAccess=2\n")),
                        ("empty", lambda: fx.write(h.vk, "")),
                        ("binary", lambda: fx.write(h.vk, b"\xff\xfe=\x00")),
                        ("fifo", lambda: os.mkfifo(h.vk)),
                        ("dir", lambda: os.mkdir(h.vk))):
        if os.path.isdir(h.vk):
            os.rmdir(h.vk)
        elif os.path.lexists(h.vk):
            os.remove(h.vk)
        setup()
        out = h.run()
        check(out == value(190, 191) and h.has(f"{h.vk} unreadable") and h.took < 5, f"vk {name}: {out!r} {h.lines()}")
    os.rmdir(h.vk)
    fx.write(h.vk, "storageBuffer8BitAccess=1\n")
    h.appinfo(exp_games(190, 191, 192))
    out = h.run("refresh")
    check(out == "" and h.rc == 0 and h.has("computed: 3 titles kept for a later start")
          and h.record("last")["titles"] == [190, 191, 192], f"vk 1 refresh: {out!r} rc {h.rc} {h.lines()}")
    fx.write(h.vk, "storageBuffer8BitAccess=0\n")
    out = h.run()
    check(out == value(190, 191, 192) and h.has("cached"), f"start after a vk 1 refresh: {out!r} {h.lines()}")
    h.clean()


CASES = [case_vk_features, case_computed, case_forward_usage, case_default_tool, case_config_failed, case_failed_absent,
         case_corrupt_app, case_target_and_shadows, case_cache, case_compat_log, case_bound, case_refresh, case_budget,
         case_refresh_change, case_bad_state, case_detached, case_tmp, case_branch_timeout]


def main():
    for case in CASES:
        try:
            case()
        except Exception as e:
            check(False, f"{case.__name__}: {type(e).__name__}: {e}")
    if failures:
        return 1
    print("steam compat helper: ok")
    return 0


sys.exit(main())
