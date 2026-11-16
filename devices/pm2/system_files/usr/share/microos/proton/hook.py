import errno
import json
import os
import re
import stat
import sys
import time
import types

API = 1
ENV_DIR = "/run/microset/proton"
MODULES = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "python", "microos_steam")
ENV_CAP = 4 << 10
VERSION_CAP = 4 << 10
CODE_CAP = 256 << 10
READ_CAP = 1 << 20
STATS = 64
BUDGET = 0.2
FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
APPID = re.compile(r"[1-9][0-9]{0,9}")
GAME_ID = re.compile(r"[1-9][0-9]{0,19}")
SHORTCUT = 0x02000000
HOOK = "MICROOS_PROTON_HOOK"
PROFILE = "MICROOS_PROTON_PROFILE"
YIELDED = "MICROOS_PROTON_YIELDED"
DXVK = "DXVK_CONFIG"
NTSYNC = "PROTON_NO_NTSYNC"
NOLSFG = "DISABLE_LSFGVK"
LSFG_CAP = "VKD3D_FRAME_RATE"
LSFG_FRAGMENTS = ("dxgi.maxFrameRate", "d3d9.maxFrameRate")
LSFG_DLL = "steamapps/common/Lossless Scaling/Lossless.dll"
ABSENT = (errno.ENOENT, errno.ENOTDIR, errno.EACCES, errno.ELOOP, errno.ENAMETOOLONG)
HINTS = {"FEX_TSOENABLED": "STEAM_FEX_TSOENABLED", "FEX_MULTIBLOCK": "STEAM_FEX_MULTIBLOCK"}
STEAM_FIELD = ("FEX_TSOENABLED", "FEX_MULTIBLOCK")
FEX = ("TSOENABLED", "HALFBARRIERTSOENABLED", "VECTORTSOENABLED", "MEMCPYSETTSOENABLED", "MULTIBLOCK", "MAXINST",
       "X87REDUCEDPRECISION", "SMCCHECKS", "VOLATILEMETADATA", "MONOHACKS")


class Bad(Exception):
    pass


def say(msg):
    try:
        print(f"microos proton hook: {msg}", file=sys.stderr, flush=True)
    except Exception:
        pass


def nonzero(s):
    return len(s) > 0 and s != "0"


def pair(k, v):
    if type(k) is not str or type(v) is not str or k == "" or "=" in k or "\0" in k or "\0" in v:
        return False
    try:
        os.fsencode(k)
        os.fsencode(v)
    except UnicodeError:
        return False
    return True


def read(path, limit):
    fd = os.open(path, FLAGS)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise Bad(f"{path}: not a regular file")
        if st.st_size > limit:
            raise Bad(f"{path}: {st.st_size} bytes, over {limit}")
        parts = []
        n = 0
        while True:
            b = os.read(fd, limit + 1 - n)
            if not b:
                break
            parts.append(b)
            n += len(b)
            if n > limit:
                raise Bad(f"{path}: over {limit} bytes")
        return b"".join(parts), st
    finally:
        os.close(fd)


def code(path, inject):
    data, st = read(path, CODE_CAP)
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise Bad(f"{path}: writable by group or others")
    m = types.ModuleType("microos_steam_" + os.path.basename(path).removesuffix(".py"))
    m.__file__ = path
    m.__dict__.update(inject)
    exec(compile(data, path, "exec", dont_inherit=True), m.__dict__)
    return m


class Probe:
    def __init__(self, environ, local):
        self.environ = environ
        self.local = local
        self.deadline = time.monotonic() + BUDGET
        self.paths = 0
        self.modules = {}

    def check(self):
        if time.monotonic() > self.deadline:
            raise TimeoutError("past its deadline")

    def count(self):
        self.check()
        self.paths += 1
        if self.paths > STATS:
            raise Bad(f"more than {STATS} paths")

    def read(self, path, limit=READ_CAP):
        self.count()
        data, _ = read(path, min(limit, READ_CAP))
        self.check()
        return data

    def stat(self, path):
        self.count()
        return os.stat(path, follow_symlinks=False)

    def steam(self, name):
        self.check()
        if "vdf" not in self.modules:
            self.modules["vdf"] = code(os.path.join(MODULES, "vdf.py"), {})
        if name not in self.modules:
            self.modules[name] = code(os.path.join(MODULES, f"{name}.py"), {"vdf": self.modules["vdf"]})
        self.check()
        return self.modules[name]


def lsfg_ready(probe):
    if NOLSFG in probe.environ or NOLSFG in probe.local:
        return False, {}, "disabled-by-env"
    home = probe.environ.get("HOME", "")
    if not home.startswith("/"):
        raise Bad(f"HOME {home!r} is not an absolute path")
    probe.count()
    for lib in probe.steam("libraries").library_paths(f"{home.rstrip('/')}/.local/share/Steam", probe.deadline):
        dll = f"{lib}/{LSFG_DLL}"
        try:
            if stat.S_ISREG(probe.stat(dll).st_mode):
                capped = any(n in probe.environ or n in probe.local for n in (DXVK, LSFG_CAP))
                return True, {"LSFGVK_DLL_PATH": dll}, "cap-overridden" if capped else "on"
        except OSError as e:
            if e.errno not in ABSENT:
                raise
    return False, {}, "no-dll"


def lsfg_loads(env):
    return env.get("LSFGVK_ENV") == "1" and NOLSFG not in env


FEATURES = {
    "fex": {"names": {f"FEX_{n}": r"[0-9a-z]{1,16}" for n in FEX}},
    "wine": {"names": {NTSYNC: r"[01]"}},
    "lsfg": {
        "names": {NOLSFG: r"1", "LSFGVK_ENV": r"1", "LSFGVK_MULTIPLIER": r"[23]",
                  "LSFGVK_FLOW_SCALE": r"(0\.25|0\.5|0\.75|1\.0)", "LSFGVK_PERFORMANCE_MODE": r"[01]",
                  "LSFGVK_PRESENT_WAIT_OFFSET": r"[0-8]", LSFG_CAP: r"[0-9]{1,3}"},
        "fragments": {k: r"[0-9]{1,3}" for k in LSFG_FRAGMENTS},
        "tokens": {"lsfg-ready": lsfg_ready},
        "final": ("lsfg-ready", lsfg_loads),
        "state": "MICROOS_LSFG",
        "states": ("off",),
        "dropped": "cap-overridden",
        "overrides": (NOLSFG, LSFG_CAP),
        "groups": ((frozenset({NOLSFG}), False),
                   (frozenset({"LSFGVK_ENV", "LSFGVK_MULTIPLIER", "LSFGVK_FLOW_SCALE", "LSFGVK_PERFORMANCE_MODE",
                               "LSFGVK_PRESENT_WAIT_OFFSET"}), True)),
    },
}


def env_map(d, what):
    if not isinstance(d, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in d.items()):
        raise Bad(f"{what} is not a map of strings")
    return d


def str_list(d, what):
    if not isinstance(d, list) or not all(isinstance(x, str) for x in d):
        raise Bad(f"{what} is not a list of strings")
    return d


def parse(data, path):
    try:
        doc = json.loads(data.decode("utf-8"))
    except (ValueError, RecursionError) as e:
        raise Bad(f"{path}: {e}")
    if not isinstance(doc, dict):
        raise Bad(f"{path}: not an object")
    if type(doc.get("version")) is not int or doc["version"] != 2:
        raise Bad(f"{path}: version {doc.get('version')!r}, not 2")
    features = doc.get("features", {})
    if not isinstance(features, dict):
        raise Bad(f"{path}: features is not an object")
    for name, sec in features.items():
        if not isinstance(sec, dict):
            raise Bad(f"{path}: section {name} is not an object")
        env_map(sec.get("env", {}), f"{name}.env")
        str_list(sec.get("dxvk", []), f"{name}.dxvk")
        env_map(sec.get("otherwise", {}), f"{name}.otherwise")
        env_map(sec.get("fallback", {}), f"{name}.fallback")
        for k in ("requires", "state"):
            if k in sec and not isinstance(sec[k], str):
                raise Bad(f"{path}: {name}.{k} is not a string")
    str_list(doc.get("below_local", []), "below_local")
    prof = doc.get("profile", {})
    if not isinstance(prof, dict):
        raise Bad(f"{path}: profile is not an object")
    str_list(prof.get("names", []), "profile.names")
    str_list(prof.get("yield", []), "profile.yield")
    if "tool" in prof and not isinstance(prof["tool"], str):
        raise Bad(f"{path}: profile.tool is not a string")
    return doc


def game_key(environ):
    gid = environ.get("SteamGameId", "")
    if APPID.fullmatch(gid):
        return gid
    if GAME_ID.fullmatch(gid):
        v = int(gid)
        if v < 1 << 64 and v & 0xFFFFFFFF == SHORTCUT and v >> 32:
            return str(v >> 32)
    return None


def env_file(environ):
    key = game_key(environ)
    for name in ([f"{key}.json"] if key else []) + ["default.json"]:
        path = os.path.join(ENV_DIR, name)
        try:
            data, _ = read(path, ENV_CAP)
        except FileNotFoundError:
            continue
        except (OSError, Bad) as e:
            return None, path, "bad-file", str(e)
        try:
            return parse(data, path), path, None, None
        except Bad as e:
            return None, path, "bad-file", str(e)
    try:
        os.close(os.open(ENV_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC))
    except OSError as e:
        return None, ENV_DIR, "no-dir", f"{ENV_DIR}: {e.strerror}"
    return None, ENV_DIR, "no-file", f"no {key + '.json or ' if key else ''}default.json in {ENV_DIR}"


def tool_version(tool_dir):
    try:
        data, _ = read(os.path.join(tool_dir, "version"), VERSION_CAP)
        fields = data.decode("utf-8", "replace").split()
        return fields[1] if len(fields) > 1 else None
    except (OSError, Bad):
        return None


def token(feature, fname, name, environ, local):
    check = feature.get("tokens", {}).get(name)
    if check is None:
        say(f"{fname}: token {name!r} check-failed: unknown token")
        return False, {}, "check-failed"
    probe = Probe(environ, local)
    try:
        ok, built, state = check(probe)
        probe.check()
        if not isinstance(ok, bool) or not isinstance(built, dict) or not all(pair(k, v) for k, v in built.items()):
            raise Bad("the check gave a bad result")
        if state is not None and not isinstance(state, str):
            raise Bad("the check gave a bad state")
        return ok, dict(built) if ok else {}, state
    except BaseException as e:
        say(f"{fname}: token {name} check-failed: {type(e).__name__}: {e}")
        return False, {}, "check-failed"


def groups_out(present, below, final=None):
    out = set()
    for feature in FEATURES.values():
        loads = feature.get("final", (None, None))[1]
        groups = feature.get("groups", ())
        for g, when in groups:
            if any(n in present for n in g) and (final is None or loads is None or loads(final) == when):
                for other, _ in groups:
                    if other is not g:
                        out.update(n for n in other if n in below and n not in present)
    return out


def settings(ctx):
    if type(ctx.get("api")) is not int or ctx["api"] != API:
        raise ValueError(f"stub api {ctx.get('api')!r} is not served")
    environ = dict(os.environ)
    local = {k: v for k, v in ctx.get("local", {}).items() if pair(k, v) and not k.startswith("MICROOS_")}
    tool_dir = ctx.get("tool_dir", "")
    states = [] if ctx.get("local_state", "ok") == "ok" else [str(ctx["local_state"])]
    built_states = {}
    names = {}
    fallback = {}
    frags = []
    built = {}
    below = set()
    dropped = []
    unchecked = []
    tokened = {}
    path = ENV_DIR
    doc = None

    def fail(stage, e):
        states.append("hook-error")
        say(f"hook-error: {stage}: {type(e).__name__}: {e}")

    def drop(name):
        names.pop(name, None)

    def fall(fname):
        feature = FEATURES[fname]
        allow = feature.get("names", {})
        got, other = tokened.pop(fname)
        for n in [n for n in names if n in allow]:
            names.pop(n)
        for k, v in other.items():
            if k.startswith("MICROOS_") or k not in allow or not re.fullmatch(allow[k], v):
                dropped.append(k)
            else:
                names[k] = v
        frags[:] = [f for f in frags if f[0] != fname]
        for k in got:
            built.pop(k, None)
        built_states[feature["state"]] = "disabled-by-env"

    try:
        doc, path, state, why = env_file(environ)
        if state:
            states.append(state)
            say(f"{state}: {why}")
    except BaseException as e:
        doc = None
        fail("env file", e)

    if doc is not None:
        below = set(doc.get("below_local", []))
        for fname, sec in doc.get("features", {}).items():
            try:
                feature = FEATURES.get(fname)
                if feature is None:
                    dropped.extend([*sec.get("env", {}), *sec.get("otherwise", {}), *sec.get("fallback", {}),
                                    *(f.partition(" = ")[0] for f in sec.get("dxvk", []))])
                    continue
                state = sec.get("state")
                if "state" in sec and state not in feature.get("states", ()):
                    dropped.append(f"{fname}.state")
                    state = None
                use, got = True, {}
                if "requires" in sec:
                    use, got, state = token(feature, fname, sec["requires"], environ, local)
                    if use and feature.get("final"):
                        tokened[fname] = got, sec.get("otherwise", {})
                else:
                    unchecked.append(fname)
                state_name = feature.get("state")
                if state_name and state is not None:
                    built_states[state_name] = state
                allow = feature.get("names", {})
                for k, v in (sec.get("env", {}) if use else sec.get("otherwise", {})).items():
                    if k.startswith("MICROOS_") or k not in allow or not re.fullmatch(allow[k], v):
                        dropped.append(k)
                    else:
                        names[k] = v
                for k, v in sec.get("fallback", {}).items():
                    if k in allow and not k.startswith("MICROOS_") and re.fullmatch(allow[k], v):
                        fallback[k] = v
                    else:
                        dropped.append(k)
                keys = feature.get("fragments", {})
                for f in sec.get("dxvk", []) if use else []:
                    k, sep, v = f.partition(" = ")
                    if sep and k in keys and re.fullmatch(keys[k], v):
                        frags.append((fname, k, v))
                    else:
                        dropped.append(k)
                built.update(got)
            except BaseException as e:
                fail(f"section {fname}", e)

        prof = doc.get("profile", {})
        try:
            mine = [n for n in prof.get("names", []) if n in names]
            tool = prof.get("tool")
            if mine and tool is not None:
                have = tool_version(tool_dir)
                if have is None or not have.startswith(tool):
                    say(f"profile for {tool}*, the tool is {have or 'unknown'}: {', '.join(mine)} dropped")
                    built_states[PROFILE] = "other-tool"
                    for n in mine:
                        if n in fallback:
                            names[n] = fallback[n]
                        else:
                            drop(n)
                    mine = []
            ylds = [n for n in prof.get("yield", []) if n in mine]
            if ylds:
                table = getattr(sys.modules.get("__main__"), "fex_application_profiles", None)
                valve = set()
                if not isinstance(table, dict):
                    states.append("no-fex-profiles")
                    say("no-fex-profiles: Proton has no fex_application_profiles table")
                    valve = set(ylds)
                elif environ.get("SteamGameId", "") in table:
                    entry = table[environ.get("SteamGameId", "")]
                    if isinstance(entry, dict) and all(isinstance(o, dict) for o in entry.values()):
                        valve = {"FEX_" + str(k).upper() for o in entry.values() for k in o}
                    else:
                        valve = set(ylds)
                gone = [n for n in ylds if n in valve or (n in HINTS and HINTS[n] in environ)]
                if gone:
                    built_states[YIELDED] = ",".join(gone)
                    say(f"profile gives way to Steam: {', '.join(gone)}")
                    for n in gone:
                        drop(n)
        except BaseException as e:
            fail("profile rules", e)

        try:
            if environ.get("STEAM_COMPAT_FEX_CONFIG", ""):
                for n in STEAM_FIELD:
                    drop(n)
            if NTSYNC in names:
                cfg = getattr(getattr(sys.modules.get("__main__"), "g_session", None), "compat_config", None)
                if not isinstance(cfg, (set, frozenset)):
                    drop(NTSYNC)
                    states.append("no-compat-config")
                    say(f"no-compat-config: Proton has no g_session.compat_config, {NTSYNC} dropped")
                else:
                    nofsync = "nofsync" in cfg
                    v = environ.get("PROTON_NO_FSYNC", local.get("PROTON_NO_FSYNC"))
                    if v is not None:
                        nofsync = nonzero(v)
                    if nofsync:
                        drop(NTSYNC)
        except BaseException as e:
            fail("sync rules", e)

    overrides = {DXVK}
    for feature in FEATURES.values():
        overrides.update(feature.get("overrides", ()))

    def compose(out):
        kept = [(fname, k, v) for fname, k, v in frags if k not in out]
        lost = DXVK in environ or DXVK in local
        merged = {n: v for n, v in names.items() if n in below and n not in out}
        merged.update(built)
        merged.update(local)
        merged.update((n, v) for n, v in names.items() if n not in below and not (n in overrides and n in local))
        if kept and not lost:
            merged[DXVK] = ";".join(f"{k} = {v}" for _, k, v in kept)
        return merged, kept if lost else []

    env = dict(local)
    try:
        present = environ.keys() | local.keys()
        out = groups_out(present, below)
        final = {**compose(out)[0], **environ}
        fell = [fname for fname in tokened if not FEATURES[fname]["final"][1](final)]
        for fname in fell:
            fall(fname)
        if fell:
            final = {**compose(out)[0], **environ}
        env, lost = compose(groups_out(present, below, final))
        for fname in dict.fromkeys(fname for fname, _, _ in lost):
            feature = FEATURES[fname]
            if feature.get("state") and feature.get("dropped"):
                built_states[feature["state"]] = feature["dropped"]
        if lost:
            say(f"{DXVK} is set already, {len(lost)} fragments dropped")
    except BaseException as e:
        fail("merge", e)
        env = dict(local)
    if dropped:
        say(f"{path}: {len(set(dropped))} names dropped: {', '.join(sorted(set(dropped)))}")
    try:
        final = {**env, **environ}
        for fname in unchecked:
            feature = FEATURES[fname]
            name, loads = feature.get("final", (None, None))
            if name and loads(final):
                _, got, state = token(feature, fname, name, environ, local)
                env.update({k: v for k, v in got.items() if k not in local})
                if feature.get("state") and state is not None:
                    built_states[feature["state"]] = state
    except BaseException as e:
        fail("final checks", e)
    env.update(built_states)
    env[HOOK] = ",".join(dict.fromkeys(states)) or "ok"
    return {"api": API, "env": env}
