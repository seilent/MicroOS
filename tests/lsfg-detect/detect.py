#!/usr/bin/env python3
import json
import os
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import time

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, "..", "steam-compat"))
sys.dont_write_bytecode = True
import fixture as fx

tree = os.environ.get("MICROOS_TREE", os.path.join(here, "..", "..", "system_files"))
PROGRAM = os.path.join(tree, "usr/libexec/microos/microos-lsfg")
FAKE = os.path.join(here, "fake.py")
APP = 993090
ACCOUNT = 424242
OTHER = 515151
PKG = 70001
URL = f"steam://install/{APP}"
TIMER = "microos-lsfg-retry.timer"
HANDLED = f'[2026-01-01 00:00:00] ExecuteSteamURL: "{URL}"\n'
FLAGS = {"Pending": 0x04, "Expired": 0x08, "CancelledByUser": 0x10, "CancelledByAdmin": 0x20,
         "CancelledByFriendlyFraudLock": 0x400, "NotActivated": 0x800, "PendingRefund": 0x2000,
         "CancelledByPartner": 0x40000, "NonPermanent": 0x80000}
with open("/proc/sys/kernel/random/boot_id") as f:
    BOOT = f.read().strip()
failures = []
clients = []


def check(cond, what):
    if not cond:
        failures.append(what)
        print(f"FAIL: {what}", file=sys.stderr)


def sid(account):
    return str(76561197960265728 + account)


def lic(package=PKG, owner=ACCOUNT, **extra):
    return {"package_id": package, "license_type": 1, "owner_id": owner, **extra}


def until(cond, limit=10):
    end = time.monotonic() + limit
    while not cond():
        if time.monotonic() > end:
            return False
        time.sleep(0.01)
    return True


def holds(pid, path):
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
    def __init__(self, program=PROGRAM):
        self.dir = tempfile.mkdtemp()
        self.home = os.path.join(self.dir, "home")
        self.root = os.path.join(self.home, ".local/share/Steam")
        self.state = os.path.join(self.home, ".local/state/microos-lsfg")
        self.stub = os.path.join(self.dir, "stub")
        self.program = program
        self.client = None
        os.makedirs(self.root)
        fx.write(f"{self.stub}/systemctl", "#!/bin/sh\n"
                 f"echo \"$*\" >> '{self.stub}/systemctl.log'\n"
                 f"case \"$*\" in '--user start --no-block --job-mode=fail '*) ;; '--user start'*) "
                 f"echo \"$*\" >> '{self.stub}/bad-start' ;; esac\n"
                 f"case \"$*\" in *list-units*) cat '{self.stub}/scopes' 2>/dev/null ;; esac\nexit 0\n", 0o755)
        fx.write(f"{self.stub}/steam", "#!/bin/sh\n"
                 f"echo \"$*\" >> '{self.stub}/steam.log'\n"
                 f"if [ -f '{self.stub}/steam-hook' ]; then . '{self.stub}/steam-hook'; fi\n"
                 f"exit $(cat '{self.stub}/steam-rc' 2>/dev/null || echo 0)\n", 0o755)

    def login(self, accounts=((ACCOUNT, "1"),)):
        fx.write(f"{self.root}/config/loginusers.vdf", fx.loginusers([(sid(a), most) for a, most in accounts]))

    def licenses(self, lics, eresult=1, account=ACCOUNT, data=None):
        body = fx.license_list(lics, eresult)
        fx.write(f"{self.root}/userdata/{account}/config/licensecache",
                 data if data is not None else fx.licensecache(account, body))

    def packages(self, packages=None, magic=0x06565528):
        fx.write(f"{self.root}/appcache/packageinfo.vdf",
                 fx.packageinfo(packages or {PKG: [APP, 5], 70002: [6]}, magic))

    def owned(self, lics=None):
        self.login()
        self.licenses(lics or [lic()])
        self.packages()

    def libraries(self, *extra):
        fx.write(f"{self.root}/steamapps/libraryfolders.vdf", fx.libraryfolders([self.root, *extra]))

    def manifest(self, lib=None, state="4", beta=None, dll=True):
        lib = lib or self.root
        fx.write(f"{lib}/steamapps/appmanifest_{APP}.acf", fx.appmanifest(APP, beta=beta, state=state))
        if dll:
            fx.write(f"{lib}/steamapps/common/Lossless Scaling/Lossless.dll", b"MZ")

    def start_client(self):
        exe = f"{self.root}/steamrtarm64/steam"
        os.makedirs(os.path.dirname(exe), exist_ok=True)
        shutil.copy2(shutil.which("sleep"), exe)
        os.makedirs(f"{self.home}/.steam", exist_ok=True)
        pipe = f"{self.home}/.steam/steam.pipe"
        if not os.path.exists(pipe):
            os.mkfifo(pipe)
        fd = os.open(pipe, os.O_RDWR | os.O_NONBLOCK)
        try:
            self.client = subprocess.Popen([exe, "600"], stdin=fd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        finally:
            os.close(fd)
        clients.append(self.client)
        fx.write(f"{self.home}/.steam/steam.pid", f"{self.client.pid}\n")

    def stop_client(self):
        if self.client:
            self.client.kill()
            self.client.wait()
            self.client = None

    def game(self, on=True):
        path = f"{self.stub}/scopes"
        if on:
            fx.write(path, "app-steam-app2238900-1.scope loaded active running app-steam-app2238900-1.scope\n")
        elif os.path.exists(path):
            os.remove(path)

    def env(self, extra=None):
        e = {"HOME": self.home, "PATH": f"{self.stub}:/usr/bin:/bin"}
        e.update(extra or {})
        return e

    def spawn(self, *args, env=None, fake=None):
        cmd = [self.program, *args] if fake is None else [sys.executable, FAKE, *fake, self.program, *args]
        return subprocess.Popen(cmd, env=self.env(env), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def collect(self, p):
        try:
            self.out, self.err = p.communicate(timeout=60)
        finally:
            if p.poll() is None:
                p.kill()
                p.communicate()
        self.rc = p.returncode
        return self.rc

    def run(self, *args, env=None, fake=None):
        return self.collect(self.spawn(*args, env=env, fake=fake))

    def has(self, text):
        return any(text in line for line in self.err.splitlines())

    def st(self):
        with open(f"{self.state}/state.json") as f:
            return json.load(f)

    def edit(self, **send):
        st = self.st()
        st["send"].update(send)
        fx.write(f"{self.state}/state.json", json.dumps(st), 0o600)

    def lines(self, name):
        try:
            with open(f"{self.stub}/{name}") as f:
                return f.read().splitlines()
        except FileNotFoundError:
            return []

    def sends(self):
        return [line for line in self.lines("steam.log") if line == f"-ifrunning {URL}"]

    def timer(self):
        calls = [line for line in self.lines("systemctl.log") if TIMER in line]
        return calls[-1].split()[1] if calls else None

    def clear(self):
        for name in ("systemctl.log", "steam.log"):
            if os.path.exists(f"{self.stub}/{name}"):
                os.remove(f"{self.stub}/{name}")

    def clean(self):
        check(not self.lines("bad-start"), f"start without --job-mode=fail: {self.lines('bad-start')}")
        self.stop_client()
        shutil.rmtree(self.dir)


def owned_of(h):
    h.run("detect")
    check(h.rc == 0, f"detect rc {h.rc}: {h.err}")
    return h.st()["owned"]


def case_owned():
    h = Home()
    h.owned()
    check(owned_of(h) == "yes", f"own license: {h.st()} {h.err}")
    check(h.has(f"owned unknown -> yes (own license, package {PKG})"), f"own license line: {h.err}")
    mode = stat.S_IMODE(os.stat(f"{h.state}/state.json").st_mode)
    dmode = stat.S_IMODE(os.stat(h.state).st_mode)
    check(mode == 0o600 and dmode == 0o700, f"state file mode {mode:o}, dir {dmode:o}")
    check(sorted(os.listdir(h.state)) == ["lock", "state.json"], f"state dir {os.listdir(h.state)}")
    family = Home()
    family.owned([lic(owner=OTHER, flags=0x4000)])
    check(owned_of(family) == "yes" and family.has(f"owned unknown -> yes (family license, package {PKG})"),
          f"family license: {family.st()} {family.err}")
    family.clean()
    h.licenses([lic(flags=0x200 | 0x100000)])
    check(owned_of(h) == "yes", "harmless flags count as owned")
    for name, value in FLAGS.items():
        h.licenses([lic(flags=value | 0x200)])
        check(owned_of(h) == "no" and h.has(f"license flags {name}"), f"flag {name}: {h.st()['owned']} {h.err}")
        h.licenses([lic()])
        check(owned_of(h) == "yes", f"owned again after {name}")
    h.licenses([lic(flags=0x08), lic(flags=0x4000, owner=OTHER)])
    check(owned_of(h) == "yes", "a usable family license next to an expired own one")
    h.licenses([lic(minute_limit=120, minutes_used=120)])
    check(owned_of(h) == "no" and h.has("minute limit used up"), f"minute limit used up: {h.err}")
    h.licenses([lic(minute_limit=120, minutes_used=30)])
    check(owned_of(h) == "yes", "minutes left count as owned")
    h.licenses([lic(minute_limit=-1, minutes_used=50)])
    check(owned_of(h) == "yes", "a negative minute limit is no limit")
    h.licenses([lic(package=70002)])
    check(owned_of(h) == "no" and h.has(f"no license for a package listing {APP}"), f"not owned: {h.err}")
    h.licenses([lic()], eresult=2)
    check(owned_of(h) == "unknown" and h.has("eresult 2"), f"eresult not OK: {h.err}")
    h.licenses([lic()], eresult=None)
    check(owned_of(h) == "unknown", "no eresult")
    h.clean()


def case_unknown():
    h = Home()
    h.owned()
    path = f"{h.root}/userdata/{ACCOUNT}/config/licensecache"
    body = fx.license_list([lic()])
    cases = {"crc": fx.licensecache(ACCOUNT, body, crc=7), "account": fx.licensecache(ACCOUNT + 1, body),
             "truncated": fx.licensecache(ACCOUNT, body[:-2])}
    sub = fx.varint(1 << 3) + fx.varint(PKG) + fx.varint(7 << 3 | 5) + struct.pack("<I", FLAGS["Expired"])
    wire = fx.varint(1 << 3) + fx.varint(1) + fx.varint(2 << 3 | 2) + fx.varint(len(sub)) + sub
    cases["flags wire type"] = fx.licensecache(ACCOUNT, wire)
    for name, data in cases.items():
        h.licenses([], data=data)
        check(owned_of(h) == "unknown", f"licensecache {name}: {h.st()['owned']}")
    h.licenses([lic()])
    check(owned_of(h) == "yes", "licensecache back")
    h.packages(magic=0x06565526)
    check(owned_of(h) == "unknown" and h.has("magic 0x06565526"), f"packageinfo bad magic: {h.err}")
    h.packages()
    check(owned_of(h) == "yes", "packageinfo back")
    for p in (path, f"{h.root}/appcache/packageinfo.vdf"):
        with open(p, "r+b") as f:
            f.truncate((16 << 20) + 1)
        check(owned_of(h) == "unknown" and h.has("over 16777216"), f"oversized {p}: {h.err}")
        h.owned()
        check(owned_of(h) == "yes", f"{p} back")
    os.remove(path)
    os.mkfifo(path)
    t0 = time.monotonic()
    check(owned_of(h) == "unknown" and time.monotonic() - t0 < 5, "licensecache FIFO")
    os.remove(path)
    h.licenses([lic()])
    check(owned_of(h) == "yes", "licensecache back after the FIFO")
    os.remove(f"{h.root}/appcache/packageinfo.vdf")
    check(owned_of(h) == "unknown" and h.has("appcache/packageinfo.vdf missing"), f"no packageinfo: {h.err}")
    h.clean()


def case_login_later():
    h = Home()
    h.packages()
    h.licenses([lic()])
    check(owned_of(h) == "unknown" and not any("account@" in c for c in h.lines("systemctl.log")),
          f"no loginusers.vdf: {h.st()} {h.lines('systemctl.log')}")
    h.login([(OTHER, "0"), (ACCOUNT, "1")])
    check(owned_of(h) == "yes", f"loginusers.vdf created: {h.st()} {h.err}")
    starts = [c for c in h.lines("systemctl.log")
              if c.startswith("--user start --no-block --job-mode=fail microos-lsfg-account@")]
    check(starts and all(f"microos-lsfg-account@{a}.path" in starts[-1].split() for a in (OTHER, ACCOUNT)),
          f"account path units: {starts}")
    h.login([(ACCOUNT, "0")])
    check(owned_of(h) == "unknown" and h.has("no MostRecent account"), f"no MostRecent: {h.err}")
    h.clean()
    h = Home()
    h.login()
    h.packages()
    check(owned_of(h) == "unknown", f"no licensecache: {h.st()}")
    check(any(f"microos-lsfg-account@{ACCOUNT}.path" in c for c in h.lines("systemctl.log")),
          "account path unit before the licensecache exists")
    h.licenses([lic()])
    check(owned_of(h) == "yes", "licensecache appearing later")
    h.clean()


def case_install():
    h = Home()
    sd = os.path.join(h.dir, "run/media/micro/SD card")
    dotdot = os.path.join(h.dir, "x/../dd")
    lead = "/../.." + os.path.join(h.dir, "lead")
    h.libraries(sd, dotdot, lead)
    h.owned()
    h.run("detect")
    st = h.st()
    check(st["install"] == "none" and st["library"] is None and st["branch"] is None and st["branch_ok"] is None,
          f"none: {st}")
    units = [c for c in h.lines("systemctl.log") if "microos-lsfg-library@" in c]
    check(len(units) == 1 and len([u for u in units[0].split() if u.startswith("microos-lsfg-library@")]) == 3
          and h.has(f"{dotdot}: a .. component, not watched"), f"library units with a .. path {units} {h.err}")
    escape = shutil.which("systemd-escape")
    if escape:
        names = [subprocess.run([escape, "--path", p], capture_output=True, text=True).stdout.strip()
                 for p in (h.root, sd, lead)]
        want = [f"microos-lsfg-library@{n}.path" for n in names]
        check(units and all(w in units[-1].split() for w in want), f"library path units {units} want {want}")
        refused = subprocess.run([escape, "--path", dotdot], capture_output=True, text=True).returncode
        check(refused != 0, f"systemd-escape --path {dotdot} exit {refused}")
    check(units and "\\x20" in units[-1] and "-.local-share-Steam.path" in units[-1], f"library unit names {units}")
    flat = os.path.join(h.dir, "lead").strip("/").replace("/", "-")
    check(units and f"microos-lsfg-library@{flat}.path" in units[-1].split(), f"leading .. dropped: {units}")
    h.manifest()
    h.run("detect")
    st = h.st()
    check(st["install"] == "installed" and st["library"] == h.root and st["branch"] == "" and st["branch_ok"] is True,
          f"installed internal: {st}")
    check(st["default_internal"] is None, f"default_internal {st['default_internal']}")
    os.remove(f"{h.root}/steamapps/appmanifest_{APP}.acf")
    h.manifest(sd, beta="lsfg-vk")
    h.run("detect")
    st = h.st()
    check(st["install"] == "installed" and st["library"] == sd and st["branch"] == "lsfg-vk"
          and st["branch_ok"] is False, f"installed SD, beta branch: {st}")
    os.remove(f"{sd}/steamapps/common/Lossless Scaling/Lossless.dll")
    h.run("detect")
    check(h.st()["install"] == "installing", f"manifest without DLL: {h.st()}")
    h.manifest(sd, state="1026")
    h.run("detect")
    check(h.st()["install"] == "installing", f"not fully installed: {h.st()}")
    h.manifest(sd, state="4")
    os.remove(f"{sd}/steamapps/common/Lossless Scaling/Lossless.dll")
    os.mkfifo(f"{sd}/steamapps/common/Lossless Scaling/Lossless.dll")
    h.run("detect")
    check(h.st()["install"] == "installing", f"DLL a FIFO: {h.st()}")
    fx.write(f"{h.root}/steamapps/libraryfolders.vdf", '"libraryfolders"\n{\n')
    h.run("detect")
    check(h.st()["install"] == "none" and h.has("only the internal library is read"), f"bad libraryfolders.vdf: {h.err}")
    layer = f"{h.home}/.local/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.json"
    check(h.st()["user_layer"] is False, "no home layer")
    fx.write(layer, "{}")
    h.run("detect")
    check(h.st()["user_layer"] is True and h.has("user_layer False -> True"), f"home layer: {h.st()} {h.err}")
    h.clean()


def case_send():
    h = Home()
    h.owned()
    h.run("detect")
    st = h.st()["send"]
    check(not h.sends() and st["result"] == "no-client" and st["auto_sends"] == 0 and h.timer() == "start",
          f"no client: {st} {h.sends()} {h.timer()}")
    h.start_client()
    h.game()
    h.run("detect")
    st = h.st()["send"]
    check(not h.sends() and st["result"] == "game-running" and h.timer() == "start", f"game running: {st}")
    h.game(False)
    t0 = time.clock_gettime(time.CLOCK_MONOTONIC)
    h.run("detect")
    st = h.st()["send"]
    check(len(h.sends()) == 1 and st["result"] == "sent" and st["auto_sends"] == 1 and st["last_boot"] == BOOT
          and t0 <= st["last_mono"] <= time.clock_gettime(time.CLOCK_MONOTONIC) and h.timer() == "start"
          and not st["auto_done"], f"client up: {st} {h.sends()}")
    for _ in range(3):
        h.run("detect")
    check(len(h.sends()) == 1 and h.st()["send"]["result"] == "sent", f"burst while sent: {h.sends()}")
    h.run("send", "auto")
    check(len(h.sends()) == 1 and h.has("since the last send, under 1200 s"), f"timer before the gap: {h.err}")
    h.edit(last_mono=time.clock_gettime(time.CLOCK_MONOTONIC) - 1201)
    h.run("detect")
    check(len(h.sends()) == 1, f"detect after the gap: {h.sends()}")
    h.run("send", "auto")
    st = h.st()["send"]
    check(len(h.sends()) == 2 and st["auto_sends"] == 2 and not st["auto_done"] and h.timer() == "start",
          f"timer after the gap: {st}")
    h.edit(last_boot="00000000-0000-4000-8000-000000000000")
    h.run("send", "auto")
    st = h.st()["send"]
    check(len(h.sends()) == 3 and st["auto_sends"] == 3 and st["auto_done"] and h.timer() == "stop",
          f"new boot id, third send: {st} {h.timer()}")
    h.edit(last_mono=0, last_boot=None)
    h.run("send", "auto")
    h.run("detect")
    check(len(h.sends()) == 3, f"no send after three: {h.sends()}")
    h.run("send", "manual")
    st = h.st()["send"]
    check(len(h.sends()) == 4 and st["result"] == "sent" and st["auto_sends"] == 3 and st["auto_done"],
          f"manual after auto_done: {st}")
    h.clean()


def case_handled():
    h = Home()
    h.owned()
    h.start_client()
    fx.write(f"{h.root}/logs/console_log.txt", "[2026-01-01 00:00:00] start\n" + HANDLED)
    h.run("detect")
    st = h.st()["send"]
    check(len(h.sends()) == 1 and st["log_mark"] == [os.stat(f"{h.root}/logs/console_log.txt").st_ino,
                                                       os.path.getsize(f"{h.root}/logs/console_log.txt")],
          f"send with a log mark: {st}")
    h.run("detect")
    check(not h.st()["send"]["auto_done"], "a handled line from before the send latched")
    with open(f"{h.root}/logs/console_log.txt", "a") as f:
        f.write(f'[2026-01-01 00:00:01] ExecuteSteamURL: "steam://rungameid/{APP}"\n'
                f'[2026-01-01 00:00:01] ExecSteamURL: "{URL}"\n')
    h.run("detect")
    check(not h.st()["send"]["auto_done"], "another URL or another line text latched")
    with open(f"{h.root}/logs/console_log.txt", "a") as f:
        f.write("[2026-01-01 00:00:01] other\n" + HANDLED)
    h.run("detect")
    st = h.st()["send"]
    check(st["auto_done"] and h.timer() == "stop" and h.has("handled, no more automatic sends"), f"handled line: {st}")
    h.edit(last_mono=0, last_boot=None)
    h.run("send", "auto")
    check(len(h.sends()) == 1 and h.st()["install"] == "none", f"declined dialog resent: {h.sends()}")
    h.clean()
    h = Home()
    h.owned()
    h.start_client()
    fx.write(f"{h.root}/logs/console_log.txt", "[2026-01-01 00:00:00] start\n")
    h.run("detect")
    os.rename(f"{h.root}/logs/console_log.txt", f"{h.root}/logs/console_log.previous.txt")
    fx.write(f"{h.root}/logs/console_log.txt", "[2026-01-01 00:01:00] new start\n" + HANDLED)
    h.run("detect")
    check(h.st()["send"]["auto_done"], "handled line in the console log after a rotation")
    h.clean()
    h = Home()
    h.owned()
    h.start_client()
    h.run("detect")
    check(len(h.sends()) == 1 and h.st()["send"]["log_mark"] is None, f"send with no console log: {h.st()}")
    fx.write(f"{h.root}/logs/console_log.txt", HANDLED)
    h.run("detect")
    check(h.st()["send"]["auto_done"], "handled line in a log created after the send")
    h.clean()
    h = Home()
    h.owned()
    h.start_client()
    log = f"{h.root}/logs/console_log.txt"
    fx.write(log, "[2026-01-01 00:00:00] start\n" + "x" * 500 + "\n")
    h.run("detect")
    mark = [os.stat(log).st_ino, os.path.getsize(log)]
    fx.write(log, HANDLED)
    check(os.stat(log).st_ino == mark[0] and len(HANDLED) < mark[1] and h.st()["send"]["log_mark"] == mark,
          f"log cut in place: {h.st()}")
    h.run("detect")
    check(h.st()["send"]["auto_done"], "handled line in a log cut in place")
    h.clean()
    h = Home()
    h.owned()
    h.start_client()
    log, previous = f"{h.root}/logs/console_log.txt", f"{h.root}/logs/console_log.previous.txt"
    fx.write(previous, "[2026-01-01 00:00:00] older session\n" + HANDLED)
    fx.write(log, "[2026-01-01 00:01:00] start\n")
    h.run("detect")
    h.run("detect")
    check(len(h.sends()) == 1 and not h.st()["send"]["auto_done"], "a handled line in the log before the send latched")
    os.link(log, os.path.join(h.dir, "keep"))
    os.rename(log, previous)
    fx.write(log, "[2026-01-01 00:02:00] second start\n" + HANDLED)
    os.rename(log, previous)
    fx.write(log, "[2026-01-01 00:03:00] third start\n")
    h.run("detect")
    check(h.st()["send"]["auto_done"], "handled line in a previous log newer than the send")
    h.clean()


def case_install_latch():
    h = Home()
    h.owned()
    h.start_client()
    h.run("detect")
    check(len(h.sends()) == 1 and h.timer() == "start", "first send")
    h.manifest(state="1026", dll=False)
    h.run("detect")
    st = h.st()
    check(st["install"] == "installing" and st["send"]["auto_done"] and h.timer() == "stop", f"manifest appears: {st}")
    h.manifest()
    h.run("detect")
    check(h.st()["install"] == "installed", "installed")
    h.run("send", "manual")
    check(len(h.sends()) == 1 and h.st()["send"]["result"] == "installed", f"manual when installed: {h.st()}")
    os.remove(f"{h.root}/steamapps/appmanifest_{APP}.acf")
    h.run("detect")
    h.edit(last_mono=0, last_boot=None)
    h.run("send", "auto")
    st = h.st()
    check(st["install"] == "none" and st["send"]["auto_done"] and len(h.sends()) == 1 and h.timer() == "stop",
          f"uninstall after installed: {st} {h.sends()}")
    h.licenses([lic(package=70002)])
    h.run("send", "manual")
    check(h.st()["send"]["result"] == "not-owned" and len(h.sends()) == 1, f"manual when not owned: {h.st()}")
    os.remove(f"{h.root}/userdata/{ACCOUNT}/config/licensecache")
    h.run("send", "manual")
    st = h.st()
    check(st["owned"] == "unknown" and st["send"]["result"] == "ownership-unknown" and len(h.sends()) == 1,
          f"manual when ownership is unknown: {st}")
    h.clean()


def case_steam_fails():
    h = Home()
    h.owned()
    h.start_client()
    fx.write(f"{h.stub}/steam-rc", "255\n")
    h.run("detect")
    st = h.st()["send"]
    check(len(h.sends()) == 1 and st["result"] == "no-client" and st["auto_sends"] == 0 and h.timer() == "start"
          and h.has("exit 255"), f"steam exit 255: {st} {h.err}")
    h.run("send", "auto")
    st = h.st()["send"]
    check(len(h.sends()) == 2 and st["auto_sends"] == 0 and st["last_mono"] is None and st["result"] == "no-client",
          f"steam exit 255 again, the attempt taken back: {st}")
    os.remove(f"{h.stub}/steam-rc")
    h.stop_client()
    h.run("send", "auto")
    check(len(h.sends()) == 2 and h.st()["send"]["result"] == "no-client" and h.has("no steamrtarm64/steam process"),
          f"timer without a client: {h.err}")
    h.start_client()
    os.remove(f"{h.home}/.steam/steam.pid")
    h.run("send", "auto")
    check(len(h.sends()) == 2 and h.has("no ~/.steam/steam.pid"), f"no steam.pid: {h.err}")
    fx.write(f"{h.home}/.steam/steam.pid", "999999999\n")
    h.run("send", "auto")
    check(len(h.sends()) == 2 and h.has("names no live process"), f"dead steam.pid: {h.err}")
    fx.write(f"{h.home}/.steam/steam.pid", f"{h.client.pid}\n")
    os.remove(f"{h.home}/.steam/steam.pipe")
    os.mkfifo(f"{h.home}/.steam/steam.pipe")
    h.run("send", "auto")
    check(len(h.sends()) == 2 and h.has("has no reader"), f"pipe without a reader: {h.err}")
    os.remove(f"{h.home}/.steam/steam.pipe")
    fx.write(f"{h.home}/.steam/steam.pipe", "")
    h.run("send", "auto")
    check(len(h.sends()) == 2 and h.has("is not a FIFO"), f"pipe a regular file: {h.err}")
    os.remove(f"{h.home}/.steam/steam.pipe")
    h.stop_client()
    h.start_client()
    h.run("send", "auto")
    check(len(h.sends()) == 3 and h.st()["send"]["auto_sends"] == 1, f"timer makes the first send: {h.st()}")
    h.clean()


def case_branches():
    base = tempfile.mkdtemp()
    for d in ("usr/libexec/microos", "usr/share/microos/lsfg"):
        os.makedirs(os.path.join(base, d))
    program = os.path.join(base, "usr/libexec/microos/microos-lsfg")
    shutil.copy2(PROGRAM, program)
    shutil.copytree(os.path.join(tree, "usr/share/microos/python"), os.path.join(base, "usr/share/microos/python"))
    data = os.path.join(base, "usr/share/microos/lsfg/branches.json")
    with open(os.path.join(tree, "usr/share/microos/lsfg/branches.json")) as f:
        check(json.load(f) == {"version": 1, "working": ["public"]}, "image branches.json")
    h = Home(program)
    h.owned()
    h.start_client()
    fx.write(data, json.dumps({"version": 1, "working": ["lsfg-vk"]}))
    h.run("detect")
    check(not h.sends() and h.timer() == "stop" and h.st()["send"]["result"] is None, f"lsfg-vk only: {h.st()}")
    h.run("send", "manual")
    check(len(h.sends()) == 1 and h.st()["send"]["result"] == "sent", "manual with lsfg-vk only")
    h.manifest(beta="lsfg-vk")
    h.run("detect")
    check(h.st()["branch_ok"] is True, f"lsfg-vk branch ok: {h.st()}")
    os.remove(data)
    h.run("detect")
    check(h.st()["branch_ok"] is None and h.has("branches.json"), f"no branches.json: {h.st()}")
    h.clean()
    shutil.rmtree(base)


def case_lock():
    h = Home()
    h.owned()
    h.start_client()
    os.makedirs(h.state, mode=0o700)
    lock = f"{h.state}/lock"
    fx.write(lock, "", 0o600)
    held = os.path.join(h.dir, "held")
    holder = subprocess.Popen([sys.executable, "-c", "import fcntl, os, sys\n"
                               "fd = os.open(sys.argv[1], os.O_RDWR)\nfcntl.flock(fd, fcntl.LOCK_EX)\n"
                               "open(sys.argv[2], 'w').close()\nsys.stdin.read()\n", lock, held], stdin=subprocess.PIPE)
    procs = []
    try:
        check(until(lambda: os.path.exists(held)), "lock holder did not take the lock")
        procs = [h.spawn("detect"), h.spawn("send", "manual")]
        check(until(lambda: all(holds(p.pid, lock) for p in procs)), "the runs did not open the lock")
        time.sleep(0.3)
        check(all(p.poll() is None for p in procs) and not h.sends(), "a run went on while the lock was held")
    finally:
        holder.stdin.close()
        holder.wait()
    rcs, errs = [], []
    for p in procs:
        rcs.append(h.collect(p))
        errs.append(h.err)
    st = h.st()["send"]
    manual_first = "since the last send, under 1200 s" in errs[0]
    want = (1, 0) if manual_first else (2, 1)
    check(rcs == [0, 0] and (len(h.sends()), st["auto_sends"]) == want and st["result"] == "sent"
          and st["last_mono"] is not None, f"detect and manual at once: {rcs} {st} {h.sends()} {errs}")
    check(sorted(os.listdir(h.state)) == ["lock", "state.json"], f"state dir after both: {os.listdir(h.state)}")
    h.clean()


def case_bad_state():
    h = Home()
    h.owned()
    os.makedirs(h.state, mode=0o700)
    fx.write(f"{h.state}/state.json", "{not json", 0o600)
    h.run("detect")
    check(h.rc == 0 and h.has("state.json unreadable") and h.st()["owned"] == "yes", f"corrupt state: {h.err}")
    bad = {"owned": "maybe", "send": {"last_boot": "x", "result": "odd"}}
    fx.write(f"{h.state}/state.json", json.dumps(bad), 0o600)
    h.run("detect")
    st = h.st()
    check(st["owned"] == "yes" and st["send"]["auto_sends"] == 3 and st["send"]["auto_done"] is True
          and st["send"]["last_boot"] is None and st["send"]["result"] is None
          and h.has("send has no auto_sends, counted as 3"), f"bad fields reset: {st} {h.err}")
    h.start_client()
    for send in ({"auto_sends": 9}, {"auto_sends": -1}, {"auto_sends": "2"}, {"auto_sends": True},
                 {"auto_sends": 0, "auto_done": "yes"}, {"auto_sends": 0, "auto_done": None},
                 {"auto_sends": 0, "auto_done": 0}):
        fx.write(f"{h.state}/state.json", json.dumps({"owned": "yes", "send": send}), 0o600)
        h.clear()
        h.run("detect")
        st = h.st()["send"]
        check(st["auto_done"] is True and st["auto_sends"] == (0 if "auto_done" in send else 3) and not h.sends()
              and h.timer() == "stop" and h.has("counted as"), f"damaged {send}: {st} {h.sends()} {h.err}")
    files = [({"owned": "yes", "send": send}, "not an object, counted as 3 sends")
             for send in ([], [{"auto_sends": 0}], "x", None, 0, True)]
    files += [({"owned": "yes"}, "has no send, counted as 3 sends"), ({}, "has no send, counted as 3 sends")]
    files += [({"owned": "yes", "send": send}, "send has no auto_sends, counted as 3")
              for send in ({}, {"auto_done": False, "result": "sent"})]
    for value, line in files:
        fx.write(f"{h.state}/state.json", json.dumps(value), 0o600)
        h.clear()
        h.run("detect")
        st = h.st()
        check(h.rc == 0 and st["send"]["auto_done"] is True and st["send"]["auto_sends"] == 3 and not h.sends()
              and h.timer() == "stop" and h.has(line), f"state {value!r}: {st} {h.sends()} {h.err}")
    for args in ((), ("send",), ("send", "other"), ("other",), ("detect", "x")):
        h.run(*args)
        check(h.rc == 2 and h.has("usage"), f"usage {args}: rc {h.rc}")
    h.clean()


def case_save_fails():
    h = Home()
    h.owned()
    h.start_client()
    tmp = f"{h.state}/state.json.tmp"
    os.makedirs(tmp)
    h.run("detect")
    check(h.rc == 1 and not h.sends() and h.has("no send: state.json not saved") and h.timer() is None
          and not os.path.exists(f"{h.state}/state.json"), f"first run, state not saved: {h.rc} {h.sends()} {h.err}")
    os.rmdir(tmp)
    h.stop_client()
    h.run("detect")
    check(h.st()["send"]["result"] == "no-client" and h.timer() == "start", f"no client: {h.st()}")
    h.start_client()
    os.makedirs(tmp)
    for args in (("detect",), ("send", "auto"), ("send", "manual")):
        h.clear()
        h.run(*args)
        st = h.st()["send"]
        check(not h.sends() and h.has("no send: state.json not saved") and st["auto_sends"] == 0
              and st["last_mono"] is None and st["result"] == "no-client", f"{args}, state not saved: {st} {h.err}")
    os.rmdir(tmp)
    h.run("detect")
    check(len(h.sends()) == 1 and h.st()["send"]["auto_sends"] == 1, f"state saved again: {h.st()}")
    h.clean()


def case_send_record():
    h = Home()
    h.owned()
    h.start_client()
    fx.write(f"{h.stub}/steam-hook", "kill -9 $PPID\n")
    h.run("detect")
    st = h.st()["send"]
    check(h.rc == -9 and len(h.sends()) == 1 and st["auto_sends"] == 1 and st["result"] == "sent"
          and st["last_boot"] == BOOT and st["last_mono"] is not None, f"killed after steam: {h.rc} {st}")
    os.remove(f"{h.stub}/steam-hook")
    h.run("detect")
    h.run("send", "auto")
    check(len(h.sends()) == 1 and h.has("since the last send, under 1200 s"), f"after the kill: {h.sends()} {h.err}")
    h.clean()
    h = Home()
    h.owned()
    h.start_client()
    fx.write(f"{h.stub}/steam-rc", "255\n")
    fx.write(f"{h.stub}/steam-hook", f"mkdir '{h.state}/state.json.tmp'\n")
    h.run("detect")
    st = h.st()["send"]
    check(h.rc == 1 and len(h.sends()) == 1 and st["auto_sends"] == 1 and st["result"] == "sent" and h.has("exit 255"),
          f"steam exit 255, the attempt not taken back: {h.rc} {st} {h.err}")
    h.clean()
    h = Home()
    h.owned()
    h.start_client()
    h.run("detect", fake=["--steam-timeout"])
    st = h.st()["send"]
    check(h.rc == 0 and len(h.sends()) == 1 and st["auto_sends"] == 1 and st["result"] == "sent"
          and h.has("counted as sent"), f"steam past its timeout: {h.rc} {st} {h.err}")
    h.clean()


def case_manual_record():
    h = Home()
    h.owned()
    h.start_client()
    log = f"{h.root}/logs/console_log.txt"
    fx.write(log, "[2026-01-01 00:00:00] start\n")
    h.run("send", "manual", fake=["--clock=5000"])
    st = h.st()["send"]
    check(len(h.sends()) == 1 and st["result"] == "sent" and st["last_mono"] == 5000 and st["last_boot"] == BOOT
          and st["log_mark"] == [os.stat(log).st_ino, os.path.getsize(log)] and st["auto_sends"] == 0
          and not st["auto_done"], f"manual send recorded: {st}")
    for args in (("detect",), ("send", "auto")):
        h.run(*args, fake=["--clock=6199"])
        check(len(h.sends()) == 1 and h.has("1199 s since the last send, under 1200 s"), f"{args} at 1199 s: {h.err}")
    h.run("detect", fake=["--clock=6200"])
    st = h.st()["send"]
    check(len(h.sends()) == 2 and st["auto_sends"] == 1 and st["last_mono"] == 6200, f"detect at 1200 s: {st}")
    h.clean()
    h = Home()
    h.owned()
    h.start_client()
    log = f"{h.root}/logs/console_log.txt"
    fx.write(log, "[2026-01-01 00:00:00] start\n")
    h.run("send", "manual", fake=["--clock=5000"])
    with open(log, "a") as f:
        f.write(HANDLED)
    h.run("detect", fake=["--clock=9000"])
    st = h.st()["send"]
    check(st["auto_done"] and st["auto_sends"] == 0 and len(h.sends()) == 1 and h.timer() == "stop",
          f"handled line after a manual send: {st} {h.sends()}")
    h.clean()


def case_budget():
    h = Home()
    h.owned()
    h.libraries()
    h.start_client()
    h.game()
    h.run("detect")
    check(h.st()["owned"] == "yes" and h.st()["send"]["result"] == "game-running", f"game running: {h.st()}")
    h.game(False)
    for path, part in (("steamapps/libraryfolders.vdf", "install state"), ("config/loginusers.vdf", "ownership"),
                       (f"userdata/{ACCOUNT}/config/licensecache", "ownership"),
                       ("appcache/packageinfo.vdf", "ownership")):
        for args in (("detect",), ("send", "auto"), ("send", "manual")):
            h.clear()
            h.run(*args, fake=[f"--jump=/Steam/{path}"])
            st = h.st()
            check(h.rc == 0 and st["owned"] == "yes" and st["send"]["result"] == "game-running" and not h.sends()
                  and h.timer() is None and h.has(f"time budget spent on the {part}"),
                  f"{path} past the budget, {args}: {st} {h.lines('systemctl.log')} {h.err}")
    check(h.has("no send: Steam files not read this run"), f"manual past the budget: {h.err}")
    h.clear()
    h.run("detect")
    check(len(h.sends()) == 1 and h.timer() == "start", f"in budget again: {h.st()}")
    h.clean()


def case_boot_id():
    deny = "--deny=/proc/sys/kernel/random/boot_id"
    h = Home()
    h.owned()
    h.start_client()
    h.run("detect", fake=[deny, "--clock=5000"])
    st = h.st()["send"]
    check(len(h.sends()) == 1 and st["last_boot"] is None and st["last_mono"] == 5000 and h.has("boot_id: "),
          f"send with an unreadable boot id: {st} {h.err}")
    h.edit(last_boot=BOOT)
    h.run("send", "auto", fake=[deny, "--clock=6199"])
    check(len(h.sends()) == 1 and h.has("1199 s since the last send"), f"an unreadable boot id keeps the gap: {h.err}")
    h.run("send", "auto", fake=[deny, "--clock=6200"])
    st = h.st()["send"]
    check(len(h.sends()) == 2 and st["auto_sends"] == 2 and st["last_boot"] is None, f"past the gap: {st}")
    h.clean()


CASES = [case_owned, case_unknown, case_login_later, case_install, case_send, case_handled, case_install_latch,
         case_steam_fails, case_branches, case_lock, case_bad_state, case_save_fails, case_send_record,
         case_manual_record, case_budget, case_boot_id]


def main():
    for case in CASES:
        try:
            case()
        except Exception as e:
            check(False, f"{case.__name__}: {type(e).__name__}: {e}")
        for c in clients:
            c.kill()
            c.wait()
        clients.clear()
    if failures:
        return 1
    print(f"lsfg detect: ok, {len(CASES)} cases")
    return 0


sys.exit(main())
