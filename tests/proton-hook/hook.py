#!/usr/bin/env python3
import ast
import builtins
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import types
import urllib.request

here = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
tree = os.environ.get("MICROOS_TREE", os.path.join(here, "..", "..", "system_files"))
share = os.path.join(tree, "usr/share/microos")
HOOK = os.path.join(share, "proton/hook.py")
STUB = os.path.join(share, "proton/user_settings_stub.py")
CASES = os.path.join(here, "applier-cases.json")
PROTON_TAG = "proton-11.0-2e"
PROTON_SHA = "a4f94c208355639c87877ba63e8faf1f26d8c0731db04f722dee66cdfcfbf478"
PROTON_URL = f"https://raw.githubusercontent.com/ValveSoftware/Proton/{PROTON_TAG}/proton"
VERSION = "1791559733 proton-11.0-2e-arm64\n"
FF13 = "292120"
FF13_FILE = {"version": 2, "below_local": ["FEX_TSOENABLED", "PROTON_NO_NTSYNC"],
             "features": {"fex": {"env": {"FEX_TSOENABLED": "0"}, "fallback": {}},
                          "wine": {"env": {"PROTON_NO_NTSYNC": "1"}, "fallback": {}}},
             "profile": {"names": ["FEX_TSOENABLED", "PROTON_NO_NTSYNC"], "tool": "proton-11.0-",
                         "yield": ["FEX_TSOENABLED"]}}
failures = []
checks = [0]


def check(cond, what):
    checks[0] += 1
    if not cond:
        failures.append(what)
        print(f"FAIL: {what}", file=sys.stderr)


def write(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if isinstance(data, (dict, list)):
        data = json.dumps(data, separators=(",", ":"))
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)
    os.chmod(path, mode)


def load_hook():
    with open(HOOK, "rb") as f:
        src = f.read()
    ns = {"__name__": "hook", "__file__": HOOK, "__builtins__": builtins}
    exec(compile(src, HOOK, "exec", dont_inherit=True), ns)
    return ns


def fake_main(compat=(), fex=None, session=True, config=True):
    m = types.ModuleType("proton")
    if session:
        m.g_session = types.SimpleNamespace(env={})
        if config:
            m.g_session.compat_config = set(compat)
    if fex is not None:
        m.fex_application_profiles = fex
    return m


def run(ns, envdir, environ, local=None, state="ok", tool=None, main=None):
    ns["ENV_DIR"] = envdir
    saved_env = dict(os.environ)
    saved_main = sys.modules.get("__main__")
    saved_err = sys.stderr
    err = io.StringIO()
    os.environ.clear()
    os.environ.update(environ)
    sys.modules["__main__"] = fake_main(fex={}) if main is None else main
    sys.stderr = err
    try:
        got = ns["settings"]({"api": 1, "tool_dir": tool or "", "local": dict(local or {}), "local_state": state})
    finally:
        sys.stderr = saved_err
        sys.modules["__main__"] = saved_main
        os.environ.clear()
        os.environ.update(saved_env)
    check(got.get("api") == 1, f"hook api {got.get('api')}")
    return got["env"], err.getvalue()


def tool_dir(tmp, version=VERSION):
    d = os.path.join(tmp, "Proton 11.0 (ARM64)")
    os.makedirs(d, exist_ok=True)
    if version is not None:
        write(os.path.join(d, "version"), version)
    return d


def imports(path, allow=()):
    with open(path) as f:
        mod = ast.parse(f.read())
    bad = []
    for node in ast.walk(mod):
        if isinstance(node, ast.Import):
            bad += [a.name for a in node.names if a.name.split(".")[0] not in sys.stdlib_module_names]
        elif isinstance(node, ast.ImportFrom):
            if node.level or node.module.split(".")[0] not in sys.stdlib_module_names:
                bad.append(node.module or ".")
    return mod, bad


def case_rules(tmp):
    _, bad = imports(HOOK)
    check(not bad, f"hook imports outside the standard library: {bad}")
    mod, bad = imports(STUB)
    check(not bad, f"stub imports outside the standard library: {bad}")
    first = mod.body[0]
    check(isinstance(first, ast.Assign) and [t.id for t in first.targets] == ["user_settings"]
          and isinstance(first.value, ast.Dict) and not first.value.keys, "stub does not start with user_settings = {}")
    for path in (HOOK, STUB):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        check("\u2014" not in text and "\u2013" not in text, f"{path} has a dash")
        check(not any(line.lstrip().startswith("#") for line in text.splitlines()), f"{path} has a comment")
        check("time.time(" not in text, f"{path} uses wall clock time")
    check(compile(open(STUB, "rb").read(), STUB, "exec", dont_inherit=True) is not None, "stub does not compile")
    ns = load_hook()
    try:
        ns["settings"]({"api": 2})
        check(False, "hook served api 2")
    except ValueError:
        pass
    return {}


def case_file(tmp):
    ns = load_hook()
    envdir = os.path.join(tmp, "proton")
    local = {"MY_OWN": "1"}
    out = {}

    def state(name, environ=None, setup=None):
        if setup:
            setup()
        env, err = run(ns, envdir, environ or {"SteamGameId": FF13}, local)
        out[name] = env.get("MICROOS_PROTON_HOOK")
        check(env.get("MY_OWN") == "1", f"{name}: local names not applied: {env}")
        return env, err

    state("missing dir")
    check(out["missing dir"] == "no-dir", f"missing dir {out}")
    os.makedirs(envdir)
    state("missing file")
    check(out["missing file"] == "no-file", f"missing file {out}")
    os.mkfifo(os.path.join(envdir, "default.json"))
    t = time.monotonic()
    state("fifo")
    check(out["fifo"] == "bad-file" and time.monotonic() - t < 2, f"fifo {out}")
    os.unlink(os.path.join(envdir, "default.json"))
    write(os.path.join(tmp, "real.json"), {"version": 2, "features": {}})
    os.symlink(os.path.join(tmp, "real.json"), os.path.join(envdir, "default.json"))
    state("symlink")
    check(out["symlink"] == "bad-file", f"symlink {out}")
    os.unlink(os.path.join(envdir, "default.json"))
    big = {"version": 2, "features": {"fex": {"env": {"FEX_TSOENABLED": "0"}}}, "below_local": ["X" * 4100]}
    write(os.path.join(envdir, "default.json"), big)
    state("oversized")
    check(out["oversized"] == "bad-file", f"oversized {out}")
    write(os.path.join(envdir, "default.json"), "{\"version\": 2, \"features\": {")
    state("malformed")
    check(out["malformed"] == "bad-file", f"malformed {out}")
    write(os.path.join(envdir, "default.json"), "[" * 2000 + "]" * 2000)
    state("nested")
    dec = json._default_decoder
    c_scan = dec.scan_once
    dec.scan_once = json.scanner.py_make_scanner(dec)
    try:
        _, err = state("nested, python scanner")
    finally:
        dec.scan_once = c_scan
    check(out["nested"] == "bad-file" and out["nested, python scanner"] == "bad-file" and "recursion" in err,
          f"nested {out} {err}")
    for name, doc in (("version 1", {"version": 1, "features": {}}), ("version true", {"version": True}),
                      ("version 2.0", {"version": 2.0}), ("env list", {"version": 2, "features": {"fex": {"env": []}}}),
                      ("value int", {"version": 2, "features": {"fex": {"env": {"FEX_TSOENABLED": 0}}}}),
                      ("array", [2])):
        write(os.path.join(envdir, "default.json"), doc)
        env, _ = state(name)
        check(out[name] == "bad-file" and "FEX_TSOENABLED" not in env, f"{name}: {out[name]} {env}")
    write(os.path.join(envdir, "default.json"), {"version": 2, "below_local": [], "features": {
        "fex": {"env": {"FEX_TSOENABLED": "1", "FEX_MAXINST": "500;x", "FEX_UNKNOWN": "1", "PROTON_NO_NTSYNC": "1",
                        "MICROOS_PROTON_HOOK": "ok", "MICROOS_LSFG": "on", "DXVK_CONFIG": "a = 1"}},
        "wine": {"env": {"PROTON_NO_NTSYNC": "2"}},
        "later": {"env": {"LATER_NAME": "1"}}}})
    env, err = state("allowlist")
    out["allowlist env"] = env
    check(env == {"FEX_TSOENABLED": "1", "MY_OWN": "1", "MICROOS_PROTON_HOOK": "ok"}, f"allowlist {env}")
    check("7 names dropped" in err and "FEX_UNKNOWN" in err and "LATER_NAME" in err, f"allowlist count line: {err}")
    write(os.path.join(envdir, "default.json"), {"version": 2, "features": {"wine": {"env": {"PROTON_NO_NTSYNC": "1"}}}})
    write(os.path.join(envdir, f"{FF13}.json"), {"version": 2, "features": {"fex": {"env": {"FEX_TSOENABLED": "0"}}}})
    env, _ = state("per game")
    check(env.get("FEX_TSOENABLED") == "0" and "PROTON_NO_NTSYNC" not in env, f"per game file {env}")
    env, _ = state("default only", {"SteamGameId": "2161700"})
    check(env.get("PROTON_NO_NTSYNC") == "1" and "FEX_TSOENABLED" not in env, f"default only {env}")
    os.unlink(os.path.join(envdir, f"{FF13}.json"))
    write(os.path.join(envdir, "2763258687.json"), {"version": 2, "features": {"fex": {"env": {"FEX_MULTIBLOCK": "0"}}}})
    write(os.path.join(envdir, "11868105691086454784.json"), {"version": 2, "features": {"fex": {"env": {"FEX_SMCCHECKS": "full"}}}})
    keys = {}
    for gid in ("11868105691086454784", "11868105691086454785", "11868105691103231999", "33554432", "2763258687",
                "18446744073709551616", "011868105691086454784", "", "abc", "0"):
        env, _ = state(f"id {gid}", {"SteamGameId": gid})
        keys[gid] = "shortcut" if env.get("FEX_MULTIBLOCK") == "0" else "default" if env.get("PROTON_NO_NTSYNC") else env
        check("FEX_SMCCHECKS" not in env, f"id {gid}: the 20 digit file was read")
    out["keys"] = keys
    want = {"11868105691086454784": "shortcut", "2763258687": "shortcut"}
    check(all(v == want.get(k, "default") for k, v in keys.items()), f"shortcut key rule {keys}")
    return out


def case_states(tmp):
    ns = load_hook()
    envdir = os.path.join(tmp, "proton")
    write(os.path.join(envdir, f"{FF13}.json"), FF13_FILE)
    td = tool_dir(tmp)
    env, _ = run(ns, envdir, {"SteamGameId": FF13}, tool=td, main=fake_main(fex={}))
    out = {"ff13": env}
    check(env == {"FEX_TSOENABLED": "0", "PROTON_NO_NTSYNC": "1", "MICROOS_PROTON_HOOK": "ok"}, f"ff13 {env}")
    env, err = run(ns, envdir, {"SteamGameId": FF13}, {"A": "1"}, "bad-local", td, fake_main(session=False))
    out["chain"] = env.get("MICROOS_PROTON_HOOK")
    check(env.get("MICROOS_PROTON_HOOK") == "bad-local,no-fex-profiles,no-compat-config" and env.get("A") == "1"
          and "FEX_TSOENABLED" not in env and "PROTON_NO_NTSYNC" not in env
          and env.get("MICROOS_PROTON_YIELDED") == "FEX_TSOENABLED", f"state list {env}")
    check("no-fex-profiles" in err and "no-compat-config" in err, f"states not on stderr: {err}")
    env, _ = run(ns, envdir, {"SteamGameId": FF13}, {"A": "1"}, "bad-local", td, fake_main(fex={}, config=False))
    check(env.get("MICROOS_PROTON_HOOK") == "bad-local,no-compat-config" and env.get("FEX_TSOENABLED") == "0",
          f"compat_config missing {env}")

    class Sub(str):
        pass

    local = {"MINE": "1", Sub("SUB"): "1", "SURR": "\ud800", "MICROOS_LSFG": "on", "MICROOS_PROTON_PROFILE": "x",
             "MICROOS_PROTON_HOOK": "ok"}
    env, _ = run(ns, envdir, {"SteamGameId": FF13}, local, tool=td)
    out["local names"] = sorted(env)
    check(env.get("MINE") == "1" and "SUB" not in env and "SURR" not in env and "MICROOS_LSFG" not in env
          and "MICROOS_PROTON_PROFILE" not in env and env["MICROOS_PROTON_HOOK"] == "ok", f"local names {env}")
    return out


def case_profile(tmp):
    ns = load_hook()
    envdir = os.path.join(tmp, "proton")
    write(os.path.join(envdir, f"{FF13}.json"), FF13_FILE)
    out = {}
    for name, version, want in (("match", VERSION, True), ("other major", "1 proton-12.0-1-arm64\n", False),
                                ("one field", "1791559733\n", False), ("no file", None, False)):
        td = tool_dir(os.path.join(tmp, name), version)
        env, err = run(ns, envdir, {"SteamGameId": FF13}, tool=td)
        out[name] = env
        if want:
            check(env.get("FEX_TSOENABLED") == "0" and "MICROOS_PROTON_PROFILE" not in env, f"tool {name}: {env}")
        else:
            check("FEX_TSOENABLED" not in env and "PROTON_NO_NTSYNC" not in env
                  and env.get("MICROOS_PROTON_PROFILE") == "other-tool" and env["MICROOS_PROTON_HOOK"] == "ok",
                  f"tool {name}: {env}")
    doc = json.loads(json.dumps(FF13_FILE))
    doc["features"]["fex"]["fallback"] = {"FEX_TSOENABLED": "1"}
    write(os.path.join(envdir, f"{FF13}.json"), doc)
    env, _ = run(ns, envdir, {"SteamGameId": FF13}, tool=tool_dir(os.path.join(tmp, "fb"), "1 proton-12.0-1\n"))
    out["fallback"] = env
    check(env.get("FEX_TSOENABLED") == "1" and "PROTON_NO_NTSYNC" not in env, f"fallback {env}")
    doc["features"]["fex"]["fallback"] = {"FEX_TSOENABLED": "0"}
    write(os.path.join(envdir, f"{FF13}.json"), doc)
    for name, environ, fex in (("hint", {"STEAM_FEX_TSOENABLED": "1"}, {}),
                               ("table", {}, {FF13: {"*": {"TSOEnabled": "1"}}})):
        env, _ = run(ns, envdir, {"SteamGameId": FF13, **environ}, tool=tool_dir(os.path.join(tmp, "y")),
                     main=fake_main(fex=fex))
        out[f"yield takes no fallback, {name}"] = env
        check("FEX_TSOENABLED" not in env and env.get("MICROOS_PROTON_YIELDED") == "FEX_TSOENABLED"
              and env.get("PROTON_NO_NTSYNC") == "1", f"yield takes no fallback, {name}: {env}")
    write(os.path.join(envdir, f"{FF13}.json"), FF13_FILE)
    td = tool_dir(os.path.join(tmp, "yield"))
    for name, environ, fex, gone in (
            ("hint tso", {"STEAM_FEX_TSOENABLED": "1"}, {}, True),
            ("hint multiblock", {"STEAM_FEX_MULTIBLOCK": "1"}, {}, False),
            ("table entry", {}, {FF13: {"ffxiii*": {"tsoenabled": "1"}}}, True),
            ("table other option", {}, {FF13: {"*": {"X87ReducedPrecision": "0"}}}, False),
            ("table other game", {}, {"292030": {"setup*": {"TSOEnabled": "1"}}}, False),
            ("table malformed", {}, {FF13: ["TSOEnabled"]}, True),
            ("no table", {}, None, True)):
        main = fake_main(fex=fex) if fex is not None else fake_main()
        env, _ = run(ns, envdir, {"SteamGameId": FF13, **environ}, tool=td, main=main)
        out[name] = env
        if gone:
            check("FEX_TSOENABLED" not in env and env.get("MICROOS_PROTON_YIELDED") == "FEX_TSOENABLED"
                  and env.get("PROTON_NO_NTSYNC") == "1", f"yield {name}: {env}")
        else:
            check(env.get("FEX_TSOENABLED") == "0" and "MICROOS_PROTON_YIELDED" not in env, f"yield {name}: {env}")
        check((env["MICROOS_PROTON_HOOK"] == "no-fex-profiles") == (fex is None), f"yield {name} state {env}")
    set_file = {"version": 2, "below_local": [], "features": {"fex": {"env": {"FEX_TSOENABLED": "0"}}}}
    write(os.path.join(envdir, "default.json"), set_file)
    env, _ = run(ns, envdir, {"SteamGameId": "5", "STEAM_FEX_TSOENABLED": "1"}, tool=td, main=fake_main())
    check(env.get("FEX_TSOENABLED") == "0" and env["MICROOS_PROTON_HOOK"] == "ok", f"a set value yields: {env}")
    for field, kept in (("", True), ("TSOEnabled:1,Multiblock:0", False)):
        doc = {"version": 2, "below_local": [], "features": {"fex": {"env": {
            "FEX_TSOENABLED": "0", "FEX_MULTIBLOCK": "0", "FEX_MAXINST": "500"}}}}
        write(os.path.join(envdir, "default.json"), doc)
        env, _ = run(ns, envdir, {"SteamGameId": "5", "STEAM_COMPAT_FEX_CONFIG": field}, tool=td)
        out[f"steam field {field!r}"] = env
        check(("FEX_TSOENABLED" in env and "FEX_MULTIBLOCK" in env) == kept and env.get("FEX_MAXINST") == "500",
              f"steam field {field!r}: {env}")
    write(os.path.join(envdir, "default.json"), {
        "version": 2, "below_local": ["FEX_X87REDUCEDPRECISION"],
        "features": {"fex": {"env": {"FEX_X87REDUCEDPRECISION": "1"}}},
        "profile": {"names": ["FEX_X87REDUCEDPRECISION"], "yield": ["FEX_X87REDUCEDPRECISION"]}})
    ns2 = load_hook()
    ns2["os"] = types.ModuleType("os")
    ns2["os"].__dict__.update(vars(os))
    ns2["os"].environ = {"SteamGameId": "7", "": "1"}
    env, _ = run(ns2, envdir, {"SteamGameId": "7"}, tool=td, main=fake_main(fex={}))
    out["empty name in the environment"] = env
    check(env.get("FEX_X87REDUCEDPRECISION") == "1" and "MICROOS_PROTON_YIELDED" not in env,
          f"an empty environment name yields a name without a hint: {env}")
    return out


def case_sync(tmp):
    ns = load_hook()
    envdir = os.path.join(tmp, "proton")
    td = tool_dir(tmp)
    out = {}
    for value in ("1", "0"):
        write(os.path.join(envdir, "default.json"), {"version": 2, "features": {"wine": {"env": {"PROTON_NO_NTSYNC": value}}}})
        for name, compat, environ, local, kept in (
                ("plain", (), {}, {}, True),
                ("nofsync title", ("nofsync", "noesync"), {}, {}, False),
                ("env 1", (), {"PROTON_NO_FSYNC": "1"}, {}, False),
                ("env 0 on a nofsync title", ("nofsync",), {"PROTON_NO_FSYNC": "0"}, {}, True),
                ("env empty on a nofsync title", ("nofsync",), {"PROTON_NO_FSYNC": ""}, {}, True),
                ("local 1", (), {}, {"PROTON_NO_FSYNC": "1"}, False),
                ("local 0 on a nofsync title", ("nofsync",), {}, {"PROTON_NO_FSYNC": "0"}, True),
                ("env 0 over local 1", (), {"PROTON_NO_FSYNC": "0"}, {"PROTON_NO_FSYNC": "1"}, True)):
            env, _ = run(ns, envdir, {"SteamGameId": "5", **environ}, local, tool=td, main=fake_main(compat, fex={}))
            out[f"{value} {name}"] = env.get("PROTON_NO_NTSYNC")
            check((env.get("PROTON_NO_NTSYNC") == value) == kept and env["MICROOS_PROTON_HOOK"] == "ok",
                  f"nofsync {value} {name}: {env}")
    for name, main in (("no g_session", fake_main(session=False, fex={})),
                       ("no compat_config", fake_main(config=False, fex={})),
                       ("not proton", types.ModuleType("other"))):
        env, _ = run(ns, envdir, {"SteamGameId": "5"}, {"MY": "1"}, tool=td, main=main)
        out[name] = env
        check("PROTON_NO_NTSYNC" not in env and env["MICROOS_PROTON_HOOK"] == "no-compat-config" and env.get("MY") == "1",
              f"{name}: {env}")
    write(os.path.join(envdir, "default.json"), {"version": 2, "features": {"fex": {"env": {"FEX_TSOENABLED": "1"}}}})
    env, _ = run(ns, envdir, {"SteamGameId": "5"}, tool=td, main=fake_main(session=False))
    check(env["MICROOS_PROTON_HOOK"] == "ok", f"compat_config read without a sync name: {env}")
    return out


def lsfg(ns, ready=None):
    on = frozenset({"LSFGVK_ENV", "LSFGVK_MULTIPLIER", "VKD3D_FRAME_RATE", "dxgi.maxFrameRate", "d3d9.maxFrameRate"})
    ns["FEATURES"]["lsfg"] = {
        "names": {"DISABLE_LSFGVK": "1", "LSFGVK_ENV": "1", "LSFGVK_MULTIPLIER": "[23]", "VKD3D_FRAME_RATE": "[0-9]{1,3}"},
        "fragments": {"dxgi.maxFrameRate": "[0-9]{1,3}", "d3d9.maxFrameRate": "[0-9]{1,3}"},
        "tokens": {"lsfg-ready": ready or (lambda probe: (True, {"LSFGVK_DLL_PATH": "/x/Lossless.dll"}, "on"))},
        "state": "MICROOS_LSFG", "dropped": "cap-overridden",
        "overrides": ("DISABLE_LSFGVK", "VKD3D_FRAME_RATE"),
        "groups": (frozenset({"DISABLE_LSFGVK"}), on)}
    ns["FEATURES"]["cap"] = {"fragments": {"d3d11.cap": "[0-9]+"}}


def on_section(cap="30"):
    return {"env": {"LSFGVK_ENV": "1", "LSFGVK_MULTIPLIER": "2", "VKD3D_FRAME_RATE": cap},
            "dxvk": [f"dxgi.maxFrameRate = {cap}", f"d3d9.maxFrameRate = {cap}"],
            "requires": "lsfg-ready", "otherwise": {"DISABLE_LSFGVK": "1"}}


def case_features(tmp):
    ns = load_hook()
    lsfg(ns)
    envdir = os.path.join(tmp, "proton")
    td = tool_dir(tmp)
    path = os.path.join(envdir, "default.json")
    out = {}
    off = {"env": {"DISABLE_LSFGVK": "1"}, "state": "off"}
    write(path, {"version": 2, "below_local": ["DISABLE_LSFGVK"], "features": {"lsfg": off}})
    env, _ = run(ns, envdir, {}, tool=td)
    out["whitelist default"] = env
    check(env.get("DISABLE_LSFGVK") == "1" and env.get("MICROOS_LSFG") == "off", f"section state without requires {env}")
    env, _ = run(ns, envdir, {}, {"LSFGVK_ENV": "1"}, tool=td)
    out["local on over the default"] = env
    check(env.get("LSFGVK_ENV") == "1" and "DISABLE_LSFGVK" not in env, f"exclusive groups {env}")
    write(path, {"version": 2, "below_local": [], "features": {"lsfg": off}})
    env, _ = run(ns, envdir, {}, {"LSFGVK_ENV": "1"}, tool=td)
    check(env.get("LSFGVK_ENV") == "1" and env.get("DISABLE_LSFGVK") == "1", f"a set off is not a below_local name {env}")
    write(path, {"version": 2, "below_local": [], "features": {"fex": {"env": {"FEX_TSOENABLED": "1"}}}})
    env, _ = run(ns, envdir, {}, {"FEX_TSOENABLED": "0", "OTHER": "x"}, tool=td)
    out["local under set"] = env
    check(env.get("FEX_TSOENABLED") == "1" and env.get("OTHER") == "x", f"local under a set per game name {env}")
    write(path, {"version": 2, "below_local": ["FEX_TSOENABLED"], "features": {"fex": {"env": {"FEX_TSOENABLED": "1"}}}})
    env, _ = run(ns, envdir, {}, {"FEX_TSOENABLED": "0"}, tool=td)
    check(env.get("FEX_TSOENABLED") == "0", f"local over a below_local name {env}")
    write(path, {"version": 2, "below_local": [], "features": {"lsfg": on_section(), "cap": {"env": {}, "dxvk": ["d3d11.cap = 40"]}}})
    env, _ = run(ns, envdir, {}, tool=td)
    out["on"] = env
    check(env.get("DXVK_CONFIG") == "dxgi.maxFrameRate = 30;d3d9.maxFrameRate = 30;d3d11.cap = 40"
          and env.get("LSFGVK_DLL_PATH") == "/x/Lossless.dll" and env.get("MICROOS_LSFG") == "on"
          and env.get("VKD3D_FRAME_RATE") == "30", f"fragments joined {env}")
    env, _ = run(ns, envdir, {}, {"VKD3D_FRAME_RATE": "20"}, tool=td)
    out["row 1b"] = env
    check(env.get("VKD3D_FRAME_RATE") == "20", f"local override name ranks as a launch option {env}")
    for name, environ, local in (("inherited", {"DXVK_CONFIG": "dxgi.syncInterval = 0"}, {}),
                                 ("local", {}, {"DXVK_CONFIG": "mine = 1"})):
        env, err = run(ns, envdir, environ, local, tool=td)
        out[f"dxvk {name}"] = env
        check(env.get("DXVK_CONFIG") == local.get("DXVK_CONFIG") and env.get("MICROOS_LSFG") == "cap-overridden"
              and env.get("LSFGVK_ENV") == "1" and "fragments dropped" in err, f"dxvk {name}: {env}")
    write(path, {"version": 2, "below_local": ["LSFGVK_ENV", "LSFGVK_MULTIPLIER", "VKD3D_FRAME_RATE",
                                               "dxgi.maxFrameRate", "d3d9.maxFrameRate"],
                 "features": {"lsfg": on_section()}})
    env, _ = run(ns, envdir, {}, {"DISABLE_LSFGVK": "1"}, tool=td)
    out["local off over blacklist"] = env
    check(env.get("DISABLE_LSFGVK") == "1" and "LSFGVK_ENV" not in env and "DXVK_CONFIG" not in env
          and "VKD3D_FRAME_RATE" not in env, f"local off drops the on group {env}")

    def slow(probe):
        time.sleep(ns["BUDGET"] + 0.05)
        return True, {}, "on"

    def boom(probe):
        raise RuntimeError("broken check")

    def leave(probe):
        raise SystemExit(4)

    def stats(probe):
        for _ in range(ns["STATS"] + 1):
            probe.stat(tmp)
        return True, {}, "on"

    def odd(probe):
        return 1, {}, "on"

    def fifo(probe):
        probe.read(os.path.join(tmp, "fifo"))
        return True, {}, "on"

    os.mkfifo(os.path.join(tmp, "fifo"))
    write(path, {"version": 2, "below_local": [], "features": {"lsfg": on_section()}})
    for name, fn in (("deadline", slow), ("raises", boom), ("exits", leave), ("stats", stats), ("bad result", odd),
                     ("fifo read", fifo)):
        ns2 = load_hook()
        lsfg(ns2, fn)
        t = time.monotonic()
        env, _ = run(ns2, envdir, {}, tool=td)
        out[f"token {name}"] = env
        check(env.get("MICROOS_LSFG") == "check-failed" and env.get("DISABLE_LSFGVK") == "1" and "LSFGVK_ENV" not in env
              and "DXVK_CONFIG" not in env and env["MICROOS_PROTON_HOOK"] == "ok" and time.monotonic() - t < 2,
              f"token {name}: {env}")
    ns3 = load_hook()
    lsfg(ns3, lambda probe: (False, {"LSFGVK_DLL_PATH": "/x"}, "no-dll"))
    env, _ = run(ns3, envdir, {}, tool=td)
    check(env.get("MICROOS_LSFG") == "no-dll" and env.get("DISABLE_LSFGVK") == "1" and "LSFGVK_DLL_PATH" not in env,
          f"token false {env}")
    sec = on_section()
    sec["requires"] = "no-such-token"
    write(path, {"version": 2, "below_local": [], "features": {"lsfg": sec}})
    env, err = run(ns, envdir, {}, tool=td)
    out["unknown token"] = env
    check(env.get("DISABLE_LSFGVK") == "1" and "LSFGVK_ENV" not in env and env.get("MICROOS_LSFG") == "check-failed"
          and env["MICROOS_PROTON_HOOK"] == "ok" and "unknown token" in err, f"unknown token {env}")
    sec = on_section()
    sec["env"]["LSFGVK_DLL_PATH"] = "/evil"
    write(path, {"version": 2, "below_local": [], "features": {"lsfg": sec}})
    env, _ = run(ns, envdir, {}, tool=td)
    check(env.get("LSFGVK_DLL_PATH") == "/x/Lossless.dll", f"file built name {env}")
    return out


def case_loader(tmp):
    root = os.path.join(tmp, "Steam")
    sd = os.path.join(tmp, "sd")
    sys.path.insert(0, os.path.join(here, "..", "steam-compat"))
    import fixture as fx
    sys.path.pop(0)
    fx.write(f"{root}/steamapps/libraryfolders.vdf", fx.libraryfolders([root, sd]))
    mods = os.path.join(tmp, "share/python/microos_steam")
    shutil.copytree(os.path.join(share, "python/microos_steam"), mods)
    for name in os.listdir(mods):
        os.chmod(os.path.join(mods, name), 0o644)
    seen = {}

    def ready(probe):
        lib = probe.steam("libraries")
        seen["same vdf"] = lib.vdf is probe.steam("config").vdf is probe.modules["vdf"]
        seen["paths"] = lib.library_paths(root, probe.deadline)
        seen["file"] = lib.__file__
        return True, {"LSFGVK_DLL_PATH": seen["paths"][-1]}, "on"

    ns = load_hook()
    check(ns["MODULES"] == os.path.abspath(os.path.join(share, "python/microos_steam")), f"module dir {ns['MODULES']}")
    ns["MODULES"] = mods
    lsfg(ns, ready)
    envdir = os.path.join(tmp, "proton")
    write(os.path.join(envdir, "default.json"), {"version": 2, "below_local": [], "features": {"lsfg": on_section()}})
    env, _ = run(ns, envdir, {}, tool=tool_dir(tmp))
    check(seen.get("same vdf") is True and seen.get("paths") == [root, sd] and env.get("LSFGVK_DLL_PATH") == sd
          and seen.get("file") == os.path.join(mods, "libraries.py") and env.get("MICROOS_LSFG") == "on",
          f"loader {seen} {env}")
    for name, mode in (("vdf.py", 0o664), ("libraries.py", 0o646)):
        ns2 = load_hook()
        ns2["MODULES"] = mods
        lsfg(ns2, ready)
        os.chmod(os.path.join(mods, name), mode)
        env, _ = run(ns2, envdir, {}, tool=tool_dir(tmp))
        check(env.get("MICROOS_LSFG") == "check-failed", f"loader with a writable {name}: {env}")
        os.chmod(os.path.join(mods, name), 0o644)
    return {"paths": [p.replace(tmp, "T") for p in seen.get("paths", [])]}


def case_applier(tmp):
    with open(CASES) as f:
        cases = json.load(f)["cases"]
    ns = load_hook()
    envdir = os.path.join(tmp, "proton")
    td = tool_dir(tmp)
    seen = 0
    for c in cases:
        doc = c["file"]
        write(os.path.join(envdir, "default.json"), doc)
        env, err = run(ns, envdir, {"SteamGameId": c["appid"] or "5"}, tool=td)
        want = {"MICROOS_PROTON_HOOK": "ok"}
        for sec in doc["features"].values():
            want.update(sec["env"])
        check(env == want and "dropped" not in err, f"applier case {c['appid']} {c['set']}: {env} want {want} {err}")
        seen += 1
    check(seen == 69, f"{seen} applier cases, not 69")
    return {"cases": seen}


DRIVER = r'''
import json
import os
import platform
import sys
import types

sys.dont_write_bytecode = True
redirect = json.loads(os.environ.pop("TEST_REDIRECT"))
mode = os.environ.pop("TEST_MODE")
tool = os.environ.pop("TEST_TOOL")
real_open = os.open
real_isdir = os.path.isdir


def fix(p):
    s = os.fspath(p)
    for a, b in redirect.items():
        if s == a or s.startswith(a + "/"):
            return b + s[len(a):]
    return p


os.open = lambda p, *a, **k: real_open(fix(p), *a, **k)
os.path.isdir = lambda p: real_isdir(fix(p))
writes = []


def audit(event, args):
    if event == "open" and isinstance(args[2], int) and args[2] & (os.O_WRONLY | os.O_RDWR | os.O_CREAT):
        writes.append(str(args[0]))
    elif event in ("os.rename", "os.remove", "os.mkdir", "os.link", "os.symlink", "os.chmod", "os.truncate"):
        writes.append(f"{event} {args[0]}")


if mode == "stub":
    import signal
    import threading
    import time
    timer = os.environ.pop("TEST_TIMER", "")
    wait = float(os.environ.pop("TEST_WAIT", "0"))
    fired = []

    def tick(signum, frame):
        fired.append(time.monotonic())

    if timer:
        signal.signal(signal.SIGALRM, tick)
        signal.setitimer(signal.ITIMER_REAL, *(float(x) for x in timer.split(",")))
    if os.environ.pop("TEST_IGN", ""):
        signal.signal(signal.SIGALRM, signal.SIG_IGN)
    if os.environ.pop("TEST_BLOCK", ""):
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
    sys.path.insert(0, tool)
    sys.addaudithook(audit)
    t0 = time.monotonic()
    if os.environ.pop("TEST_THREAD", ""):
        th = threading.Thread(target=__import__, args=("user_settings",))
        th.start()
        th.join()
    import user_settings
    t1 = time.monotonic()
    left = signal.getitimer(signal.ITIMER_REAL)
    handler = signal.getsignal(signal.SIGALRM)
    while not fired and time.monotonic() - t0 < wait:
        time.sleep(0.01)
    name = {tick: "tick", signal.SIG_DFL: "default", signal.SIG_IGN: "ignore"}.get(handler, repr(handler))
    print(json.dumps({"env": user_settings.user_settings, "writes": writes, "took": t1 - t0, "left": left,
                      "handler": name, "fired": [f - t0 for f in fired]}))
    sys.exit(0)

fl = types.ModuleType("filelock")


class FileLock:
    def __init__(self, *a, **k):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


fl.FileLock = FileLock
sys.modules["filelock"] = fl
src_path = os.environ.pop("TEST_PROTON")
with open(src_path, "rb") as f:
    src = f.read()
m = types.ModuleType("proton")
m.__file__ = src_path
exec(compile(src, src_path, "exec"), m.__dict__)
sys.modules["__main__"] = m
platform.machine = lambda: "aarch64"
sys.path.insert(0, tool)
m.g_proton = m.Proton(tool)
m.g_compatdata = m.CompatData(os.environ.pop("TEST_COMPAT"))
m.g_compatdata.setup_prefix = lambda: None
m.g_compatdata.sync_appcache = lambda: None
m.g_session = m.Session()
m.g_session.init_wine()
m.g_session.init_session(False)
with open(m.g_compatdata.fex_config_file) as f:
    fex = json.load(f)
print(json.dumps({"env": m.g_session.env, "compat": sorted(m.g_session.compat_config), "fex": fex}))
'''


def stage(tmp, hook=None, host=None, env_files=None, local=None):
    root = os.path.join(tmp, "root")
    shutil.rmtree(root, ignore_errors=True)
    td = tool_dir(root)
    with open(STUB, "rb") as f:
        write(os.path.join(td, "user_settings.py"), f.read())
    if local is not None:
        write(os.path.join(td, "user_settings_local.py"), local)
    paths = {"/usr/share/microos": os.path.join(root, "usr/share/microos"),
             "/run/host/usr": os.path.join(root, "host/usr"),
             "/run/microset/proton": os.path.join(root, "run/microset/proton")}
    with open(HOOK, "rb") as f:
        real = f.read()
    if host is not None:
        os.makedirs(paths["/run/host/usr"], exist_ok=True)
        if host is not False:
            write(os.path.join(paths["/run/host/usr"], "share/microos/proton/hook.py"), real if host is True else host)
    if hook is not None:
        write(os.path.join(paths["/usr/share/microos"], "proton/hook.py"), real if hook is True else hook)
    if env_files is not None:
        os.makedirs(paths["/run/microset/proton"])
        for name, doc in env_files.items():
            write(os.path.join(paths["/run/microset/proton"], name), doc)
    return {"root": root, "tool": td, "paths": paths}


def launch(st, mode, environ, proton=None):
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": st["root"], "PYTHONDONTWRITEBYTECODE": "1",
           "TEST_REDIRECT": json.dumps(st["paths"]), "TEST_MODE": mode, "TEST_TOOL": st["tool"], **environ}
    if mode == "proton":
        env["TEST_PROTON"] = proton
        env["TEST_COMPAT"] = os.path.join(st["root"], "compatdata") + "/"
        os.makedirs(os.path.join(st["root"], "compatdata/pfx"), exist_ok=True)
    p = subprocess.run([sys.executable, "-c", DRIVER], env=env, capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        check(False, f"driver {mode} rc {p.returncode}: {p.stderr[-2000:]}")
        return {"env": {}, "writes": [], "fex": {}, "compat": []}, p.stderr
    return json.loads(p.stdout.strip().splitlines()[-1]), p.stderr


def drive(tmp, mode, environ, proton=None, **kw):
    return launch(stage(tmp, **kw), mode, environ, proton)


def hook_src(body):
    return f"def settings(ctx):\n{body}\n"


def stub_budget():
    with open(STUB) as f:
        mod = ast.parse(f.read())
    for node in mod.body:
        if isinstance(node, ast.Assign) and [getattr(t, "id", None) for t in node.targets] == ["_BUDGET"]:
            return node.value.value
    return None


def sleepy(seconds):
    return hook_src("    import signal, time\n"
                    "    h = signal.getsignal(signal.SIGALRM)\n"
                    "    left = signal.getitimer(signal.ITIMER_REAL)[0]\n"
                    f"    time.sleep({seconds})\n"
                    "    return {'api': 1, 'env': {**ctx['local'], 'IN_HANDLER': getattr(h, '__name__', repr(h)),\n"
                    "            'IN_LEFT': f'{left:.3f}', 'MICROOS_PROTON_HOOK': 'ok'}}")


def stall(suffix):
    return ("import builtins\nimport time\n\n"
            f"_ns = {{'__name__': 'hook', '__file__': {HOOK!r}, '__builtins__': builtins}}\n"
            f"with open({HOOK!r}, 'rb') as _f:\n"
            f"    exec(compile(_f.read(), {HOOK!r}, 'exec', dont_inherit=True), _ns)\n"
            "_read = _ns['read']\n\n\n"
            "def _slow(path, limit):\n"
            f"    if path.endswith({suffix!r}):\n"
            "        time.sleep(3600)\n"
            "    return _read(path, limit)\n\n\n"
            "_ns['read'] = _slow\n"
            "settings = _ns['settings']\n")


def case_watchdog(tmp):
    out = {}
    budget = stub_budget()
    check(isinstance(budget, float) and 0 < budget < 30, f"stub budget {budget!r}")
    local = "user_settings = {'MY_OWN': '1'}\n"
    files = {"default.json": {"version": 2, "below_local": [], "features": {"fex": {"env": {"FEX_TSOENABLED": "1"}}}}}
    for name, hook in (("loops forever", hook_src("    while True:\n        pass")),
                       ("loops at load", "while True:\n    pass\n"),
                       ("blocks in a sleep", hook_src("    import time\n    time.sleep(3600)")),
                       ("swallows the timeout and stalls again",
                        hook_src("    import time\n    try:\n        time.sleep(3600)\n    except TimeoutError:\n        pass\n"
                                 "    time.sleep(20)\n    return {'api': 1, 'env': {**ctx['local'], 'MICROOS_PROTON_HOOK': 'ok'}}"))):
        got, err = drive(tmp, "stub", {"SteamGameId": "5"}, env_files=files, local=local, hook=hook)
        env = got["env"]
        took = got.get("took", 0)
        out[name] = {"state": env.get("MICROOS_PROTON_HOOK"), "took": round(took, 1)}
        check(env.get("MICROOS_PROTON_HOOK") == "hook-error" and env.get("MY_OWN") == "1" and "FEX_TSOENABLED" not in env
              and budget <= took < budget + 1 and got.get("handler") == "default" and got.get("left") == [0.0, 0.0]
              and "past its" in err, f"watchdog {name}: {got} {err[-300:]}")
    ff13 = json.loads(json.dumps(FF13_FILE))
    ff13["features"]["fex"]["fallback"] = {"FEX_TSOENABLED": "1"}
    for name, suffix in (("stalls in the version read", "/version"), ("stalls in the env file read", f"/{FF13}.json")):
        got, err = drive(tmp, "stub", {"SteamGameId": FF13}, env_files={f"{FF13}.json": ff13}, local=local, hook=stall(suffix))
        env = got["env"]
        took = got.get("took", 0)
        out[name] = {"env": env, "took": round(took, 1)}
        check("hook-error" in env.get("MICROOS_PROTON_HOOK", "").split(",") and set(env) == {"MY_OWN", "MICROOS_PROTON_HOOK"}
              and env["MY_OWN"] == "1" and budget <= took < budget + 1 and got.get("handler") == "default"
              and got.get("left") == [0.0, 0.0] and "past its" in err, f"watchdog {name}: {got} {err[-500:]}")
    got, err = drive(tmp, "stub", {"SteamGameId": FF13}, env_files={f"{FF13}.json": ff13}, local=local, hook=stall("/none"))
    out["read wrapper without a stall"] = got["env"]
    check(got["env"] == {"MY_OWN": "1", "MICROOS_PROTON_YIELDED": "FEX_TSOENABLED",
                         "MICROOS_PROTON_HOOK": "no-fex-profiles,no-compat-config"} and got.get("took", 9) < budget / 2,
          f"watchdog read wrapper without a stall: {got} {err[-300:]}")
    for name, extra, seconds in (("slow hook within the budget", {}, 0.3),
                                 ("inherited SIG_IGN restored", {"TEST_IGN": "1"}, 0.3),
                                 ("armed timer survives", {"TEST_TIMER": "5,0"}, 0.3),
                                 ("armed interval timer survives", {"TEST_TIMER": "5,1.5"}, 0.3),
                                 ("timer due during the hook", {"TEST_TIMER": "1,0", "TEST_WAIT": "3"}, 1.2),
                                 ("not the main thread", {"TEST_TIMER": "5,0", "TEST_THREAD": "1"}, 0.3),
                                 ("SIGALRM blocked", {"TEST_TIMER": "5,0", "TEST_BLOCK": "1"}, 0.3)):
        got, err = drive(tmp, "stub", {"SteamGameId": "5", **extra}, env_files=files, local=local, hook=sleepy(seconds))
        env = got["env"]
        took = got.get("took", 0)
        left = got.get("left", [0, 0])
        fired = got.get("fired", [])
        out[name] = {"in": [env.get("IN_HANDLER"), env.get("IN_LEFT")], "handler": got.get("handler"),
                     "left": [round(x, 2) for x in left], "fired": [round(x, 2) for x in fired], "took": round(took, 2)}
        check(env.get("MICROOS_PROTON_HOOK") == "ok" and env.get("MY_OWN") == "1" and not got.get("writes"),
              f"watchdog {name}: {got} {err[-300:]}")
        if "TEST_THREAD" in extra or "TEST_BLOCK" in extra:
            check(env.get("IN_HANDLER") == "tick" and float(env.get("IN_LEFT", 0)) > budget, f"watchdog {name}: armed {env}")
        else:
            check(env.get("IN_HANDLER") == "alarm" and 0 < float(env.get("IN_LEFT", 0)) <= budget, f"watchdog {name}: not armed {env}")
        if "TEST_TIMER" not in extra:
            want = "ignore" if "TEST_IGN" in extra else "default"
            check(got.get("handler") == want and left == [0.0, 0.0] and not fired, f"watchdog {name}: left behind {got}")
        elif "TEST_WAIT" in extra:
            check(got.get("handler") == "tick" and len(fired) == 1 and seconds <= fired[0] <= took + 0.2,
                  f"watchdog {name}: old timer not delivered after the hook {got}")
        else:
            want = float(extra["TEST_TIMER"].split(",")[1])
            check(got.get("handler") == "tick" and abs(left[0] + took - 5) < 0.1 and left[1] == want and not fired,
                  f"watchdog {name}: old timer not restored {got}")
    return out


def case_stub(tmp):
    out = {}
    local = ('class S(str):\n    pass\n\n\nuser_settings = {"MY_OWN": "1", "MY_INT": 5, 7: "x", "BAD=NAME": "1", '
             '"MICROOS_LSFG": "on", S("SUB"): "1", "SURR": "\\ud800"}\n')
    files = {"default.json": {"version": 2, "below_local": [], "features": {"fex": {"env": {"FEX_TSOENABLED": "1"}}}}}

    def marker(w):
        return hook_src(f"    return {{'api': 1, 'env': {{'WHERE': '{w}', **ctx['local'], 'MICROOS_PROTON_HOOK': 'ok'}}}}")

    for name, kw, want_state, want_where in (
            ("present", {"hook": True}, "ok", None),
            ("missing", {}, "no-hook", None),
            ("host when no /run/host/usr", {"hook": marker("host")}, "ok", "host"),
            ("container when /run/host/usr", {"hook": marker("host"), "host": marker("container")}, "ok", "container"),
            ("never the host hook in the container", {"hook": marker("host"), "host": False}, "no-hook", None),
            ("raising", {"hook": hook_src("    raise RuntimeError('x')")}, "hook-error", None),
            ("SystemExit in settings", {"hook": hook_src("    raise SystemExit(3)")}, "hook-error", None),
            ("SystemExit at load", {"hook": "raise SystemExit(3)\n"}, "hook-error", None),
            ("non str value", {"hook": hook_src("    return {'api': 1, 'env': {'A': 1, 'MICROOS_PROTON_HOOK': 'ok'}}")},
             "hook-error", None),
            ("other api", {"hook": hook_src("    return {'api': 2, 'env': {'MICROOS_PROTON_HOOK': 'ok'}}")}, "hook-error", None),
            ("api true", {"hook": hook_src("    return {'api': True, 'env': {'MICROOS_PROTON_HOOK': 'ok'}}")}, "hook-error", None),
            ("no state", {"hook": hook_src("    return {'api': 1, 'env': {}}")}, "hook-error", None),
            ("no settings", {"hook": "x = 1\n"}, "hook-error", None),
            ("over 256 KiB", {"hook": marker("host") + "x = 1\n" * 50000}, "hook-error", None)):
        got, err = drive(tmp, "stub", {"SteamGameId": "5"}, env_files=files, local=local, **kw)
        env = got["env"]
        out[name] = env
        check(env.get("MICROOS_PROTON_HOOK") == want_state, f"stub {name}: state {env}")
        check(env.get("MY_OWN") == "1" and "MY_INT" not in env and "BAD=NAME" not in env and "MICROOS_LSFG" not in env
              and "SUB" not in env and "SURR" not in env, f"stub {name}: local names {env}")
        check(env.get("WHERE") == want_where, f"stub {name}: hook path {env}")
        check(not got["writes"], f"stub {name} wrote {got['writes']}")
        if want_state != "ok":
            check(want_state in err, f"stub {name}: state not on stderr: {err}")
        if name == "present":
            check(env.get("FEX_TSOENABLED") == "1", f"stub present: file names {env}")
    for name, mode in (("group writable", 0o664), ("other writable", 0o646)):
        st = stage(tmp, env_files=files, local=local, hook=True)
        os.chmod(os.path.join(st["paths"]["/usr/share/microos"], "proton/hook.py"), mode)
        got, err = launch(st, "stub", {})
        env = got["env"]
        out[name] = env
        check(env.get("MICROOS_PROTON_HOOK") == "hook-error" and env.get("MY_OWN") == "1" and "FEX_TSOENABLED" not in env
              and "writable by group or others" in err, f"stub {name}: {env}")
    if os.geteuid() == 0:
        st = stage(tmp, env_files=files, host=True)
        hook = os.path.join(st["paths"]["/run/host/usr"], "share/microos/proton/hook.py")
        os.chown(hook, 65534, 65534)
        got, _ = launch(st, "stub", {})
        out["uid 65534"] = got["env"]
        check(os.stat(hook).st_uid == 65534 and got["env"].get("MICROOS_PROTON_HOOK") == "ok"
              and got["env"].get("FEX_TSOENABLED") == "1", f"stub uid 65534 hook: {got['env']}")
    else:
        check(False, "the uid 65534 case needs root (run it in the test container)")
    for name, text, want in (
            ("raises", "raise RuntimeError('mine')\nuser_settings = {'A': '1'}\n", "bad-local,no-hook"),
            ("SystemExit", "import sys\nsys.exit(2)\n", "bad-local,no-hook"),
            ("marker", "user_settings = {'MICROOS_PROTON_HOOK': 'ok'}\n", "bad-local,no-hook"),
            ("no dict", "user_settings = ['A']\n", "bad-local,no-hook"),
            ("over 64 KiB", "user_settings = {'A': '1'}\n" + "x = 1\n" * 12000, "bad-local,no-hook"),
            ("int dropped", "user_settings = {'A': '1', 'B': 2}\n", "no-hook")):
        got, err = drive(tmp, "stub", {}, local=text)
        env = got["env"]
        out[f"local {name}"] = env
        check(env.get("MICROOS_PROTON_HOOK") == want and ("A" in env) == (want == "no-hook") and "B" not in env,
              f"local {name}: {env}")
        if want.startswith("bad-local"):
            check("bad-local" in err, f"local {name}: not on stderr: {err}")
    st = stage(tmp, env_files={}, local="user_settings = {'A': '1'}\n", hook=True)
    real = os.path.join(st["root"], "real_local.py")
    os.rename(os.path.join(st["tool"], "user_settings_local.py"), real)
    os.symlink(real, os.path.join(st["tool"], "user_settings_local.py"))
    got, _ = launch(st, "stub", {})
    check(got["env"].get("MICROOS_PROTON_HOOK") == "bad-local,no-file" and "A" not in got["env"], f"local symlink {got['env']}")
    for name, files2, want in (("no-dir", None, "no-dir"), ("no-file", {}, "no-file"),
                               ("bad-file", {"default.json": {"version": 1}}, "bad-file")):
        got, _ = drive(tmp, "stub", {}, env_files=files2, local="user_settings = {'A': '1'}\n", hook=True)
        out[f"stub {name}"] = got["env"]
        check(got["env"].get("MICROOS_PROTON_HOOK") == want and got["env"].get("A") == "1", f"stub {name}: {got['env']}")
    return out


def proton_script(tmp):
    cached = os.environ.get("MICROOS_PROTON_SCRIPT")
    if cached:
        with open(cached, "rb") as f:
            data = f.read()
    else:
        for attempt in range(1, 4):
            try:
                with urllib.request.urlopen(PROTON_URL, timeout=60) as r:
                    data = r.read()
                break
            except OSError as e:
                if attempt == 3:
                    raise
                print(f"{PROTON_URL}: {e}, try {attempt + 1} of 3 in 10 s", file=sys.stderr)
                time.sleep(10)
    got = hashlib.sha256(data).hexdigest()
    if got != PROTON_SHA:
        raise RuntimeError(f"{PROTON_TAG} proton sha256 {got}, want {PROTON_SHA}")
    path = os.path.join(tmp, "proton")
    write(path, data)
    return path


def case_proton(tmp):
    proton = proton_script(tmp)
    out = {}
    ff13 = {f"{FF13}.json": FF13_FILE}

    def start(name, appid, files, environ=None, local=None, hook=True):
        got, err = drive(tmp, "proton", {"SteamGameId": appid, "SteamAppId": appid, **(environ or {})}, hook=hook,
                         env_files=files, local=local, proton=proton)
        env = got["env"]
        out[name] = {k: env.get(k) for k in ("MICROOS_PROTON_HOOK", "FEX_TSOENABLED", "PROTON_NO_NTSYNC", "WINEFSYNC",
                                            "MICROOS_PROTON_YIELDED", "FEX_X87REDUCEDPRECISION", "MY_OWN")}
        out[name]["fex"] = got.get("fex")
        check("THERE IS AN ERROR IN YOUR user_settings.py" not in err, f"proton {name}: Proton logged an error: {err[-500:]}")
        return env, got

    env, got = start("ff13", FF13, ff13)
    check(env.get("MICROOS_PROTON_HOOK") == "ok" and env.get("FEX_TSOENABLED") == "0" and env.get("PROTON_NO_NTSYNC") == "1"
          and env.get("WINEFSYNC") == "1" and got["fex"]["Config"] == {} and "AppOverrides" not in got["fex"],
          f"proton ff13 {out['ff13']}")
    sync = {"default.json": {"version": 2, "below_local": [], "features": {"wine": {"env": {"PROTON_NO_NTSYNC": "1"}}}}}
    for name, appid, environ, local, kept in (
            ("2630 keeps ntsync", "2630", {}, None, False),
            ("292120 gets fsync", FF13, {}, None, True),
            ("PROTON_NO_FSYNC=1", FF13, {"PROTON_NO_FSYNC": "1"}, None, False),
            ("PROTON_NO_FSYNC=0", "2630", {"PROTON_NO_FSYNC": "0"}, None, True),
            ("STEAM_COMPAT_CONFIG=nofsync", FF13, {"STEAM_COMPAT_CONFIG": "nofsync"}, None, False),
            ("PROTON_NO_FSYNC=1 from local", FF13, {}, "user_settings = {'PROTON_NO_FSYNC': '1'}\n", False)):
        env, got = start(name, appid, sync, environ, local)
        check((env.get("PROTON_NO_NTSYNC") == "1") == kept and ("WINEFSYNC" in env) == kept
              and env.get("MICROOS_PROTON_HOOK") == "ok", f"proton {name}: {out[name]} {got['compat']}")
    witcher = {"292030.json": {"version": 2, "below_local": ["FEX_X87REDUCEDPRECISION"],
                               "features": {"fex": {"env": {"FEX_X87REDUCEDPRECISION": "1"}, "fallback": {}}},
                               "profile": {"names": ["FEX_X87REDUCEDPRECISION"], "yield": ["FEX_X87REDUCEDPRECISION"]}}}
    env, got = start("valve table yield", "292030", witcher)
    check("FEX_X87REDUCEDPRECISION" not in env and env.get("MICROOS_PROTON_YIELDED") == "FEX_X87REDUCEDPRECISION"
          and got["fex"].get("AppOverrides") == {"setup*": {"X87ReducedPrecision": "0"}}, f"proton valve table {out['valve table yield']}")
    env, got = start("valve hint yield", FF13, ff13, {"STEAM_FEX_TSOENABLED": "1"})
    check("FEX_TSOENABLED" not in env and env.get("MICROOS_PROTON_YIELDED") == "FEX_TSOENABLED"
          and env.get("PROTON_NO_NTSYNC") == "1" and got["fex"]["Config"].get("TSOEnabled") == "1", f"proton hint {out['valve hint yield']}")
    fb = json.loads(json.dumps(FF13_FILE))
    fb["features"]["fex"]["fallback"] = {"FEX_TSOENABLED": "0"}
    env, got = start("valve hint yield with a fallback", FF13, {f"{FF13}.json": fb}, {"STEAM_FEX_TSOENABLED": "1"})
    check("FEX_TSOENABLED" not in env and env.get("MICROOS_PROTON_YIELDED") == "FEX_TSOENABLED"
          and got["fex"]["Config"].get("TSOEnabled") == "1", f"proton hint with a fallback {out['valve hint yield with a fallback']}")
    env, _ = start("launch option wins", FF13, ff13, {"FEX_TSOENABLED": "1"})
    check(env.get("FEX_TSOENABLED") == "1", f"proton launch option {out['launch option wins']}")
    env, _ = start("hook missing", FF13, ff13, local="user_settings = {'MY_OWN': '1'}\n", hook=None)
    check(env.get("MICROOS_PROTON_HOOK") == "no-hook" and env.get("MY_OWN") == "1" and "FEX_TSOENABLED" not in env,
          f"proton no hook {out['hook missing']}")
    env, _ = start("hook exits", FF13, ff13, local="user_settings = {'MY_OWN': '1'}\n",
                    hook=hook_src("    raise SystemExit(9)"))
    check(env.get("MICROOS_PROTON_HOOK") == "hook-error" and env.get("MY_OWN") == "1", f"proton hook exits {out['hook exits']}")
    env, _ = start("hook loops", FF13, ff13, local="user_settings = {'MY_OWN': '1'}\n",
                   hook=hook_src("    while True:\n        pass"))
    check(env.get("MICROOS_PROTON_HOOK") == "hook-error" and env.get("MY_OWN") == "1" and "FEX_TSOENABLED" not in env,
          f"proton hook loops {out['hook loops']}")
    env, _ = start("hook stalls in the version read", FF13, ff13, local="user_settings = {'MY_OWN': '1'}\n",
                   hook=stall("/version"))
    check(env.get("MICROOS_PROTON_HOOK") == "hook-error" and env.get("MY_OWN") == "1" and "FEX_TSOENABLED" not in env
          and "PROTON_NO_NTSYNC" not in env and "MICROOS_PROTON_PROFILE" not in env,
          f"proton hook stalls {out['hook stalls in the version read']}")
    return out


def main():
    results = {}
    for case in (case_rules, case_file, case_states, case_profile, case_sync, case_features, case_loader, case_applier,
                 case_stub, case_watchdog, case_proton):
        tmp = tempfile.mkdtemp()
        try:
            results[case.__name__] = case(tmp)
        except Exception as e:
            check(False, f"{case.__name__}: {type(e).__name__}: {e}")
        finally:
            shutil.rmtree(tmp)
    if failures:
        print(f"proton hook: {len(failures)} failures", file=sys.stderr)
        return 1
    print(f"proton hook: ok, python {sys.version.split()[0]}, {checks[0]} checks in {len(results)} groups, "
          f"{results['case_applier']['cases']} applier files, proton {PROTON_TAG}")
    return 0


sys.exit(main())
