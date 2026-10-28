#!/usr/bin/env python3
import ast
import json
import os
import shutil
import struct
import sys
import tempfile
import time
import types

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
sys.dont_write_bytecode = True
import fixture as fx

tree = os.environ.get("MICROOS_TREE", os.path.join(here, "..", "..", "system_files"))
pkg = os.path.join(tree, "usr/share/microos/python/microos_steam")
FILES = ("appinfo", "compat", "config", "libraries")
failures = []


def check(cond, what):
    if not cond:
        failures.append(what)
        print(f"FAIL: {what}", file=sys.stderr)


def load_import():
    sys.path.insert(0, os.path.dirname(pkg))
    import microos_steam
    sys.path.pop(0)
    return microos_steam


def load_exec():
    ms = types.SimpleNamespace()

    def run(name, inject):
        path = os.path.join(pkg, name + ".py")
        with open(path, "rb") as f:
            src = f.read()
        m = types.ModuleType("microos_steam_" + name)
        m.__file__ = path
        m.__dict__.update(inject)
        exec(compile(src, path, "exec", dont_inherit=True), m.__dict__)
        return m

    ms.vdf = run("vdf", {})
    for name in FILES:
        setattr(ms, name, run(name, {"vdf": ms.vdf}))
    return ms


def import_rule():
    own = {"vdf", "microos_steam", *FILES}
    for name in ("vdf",) + FILES:
        with open(os.path.join(pkg, name + ".py")) as f:
            mod = ast.parse(f.read())
        for node in ast.walk(mod):
            if isinstance(node, ast.ImportFrom):
                check(node.level == 0 and node.module.split(".")[0] not in own, f"{name}.py imports from {node.module}")
                check(node.module.split(".")[0] in sys.stdlib_module_names, f"{name}.py imports non stdlib {node.module}")
            elif isinstance(node, ast.Import):
                for a in node.names:
                    top = a.name.split(".")[0]
                    check(top not in own and top in sys.stdlib_module_names, f"{name}.py imports {a.name}")
        if name != "vdf":
            used = {n.id for n in ast.walk(mod) if isinstance(n, ast.Name)}
            check("vdf" in used, f"{name}.py does not use the injected vdf")


def case_text(ms, tmp):
    v = ms.vdf
    text = ('// head\n"Root"\n{\n\t"a"\t\t"1"\n\t"Q"\t\t"say \\"hi\\" \\\\ x\\n"\n\tbare value\n'
            '\t"cond"\t\t"v" [$WIN32]\n\t"Sub" { "k" "v" }\n}\n')
    d = v.loads(text)
    r = {"d": d, "get": v.get(d, "root") is d["Root"], "sub": v.get(v.get(d, "ROOT"), "sub")}
    check(d == {"Root": {"a": "1", "Q": 'say "hi" \\ x\n', "bare": "value", "cond": "v", "Sub": {"k": "v"}}}, f"text parse {d}")
    errs = {}
    for name, bad in (("open", '"a"\n{\n"b" "c"\n'), ("close", '"a" "b"\n}\n'), ("dangling", '"a" "b" "c"'),
                      ("quote", '"a" "b'), ("nokey", '{ "a" "b" }'), ("bracket", '"a" [x'),
                      ("deep", '"a" {' * 70 + '}' * 70)):
        try:
            v.loads(bad)
            errs[name] = "parsed"
        except v.Error:
            errs[name] = "error"
    check(all(x == "error" for x in errs.values()), f"text errors {errs}")
    r["errs"] = errs
    try:
        v.loads('"k" "v"\n' * 5000, time.monotonic() - 1)
        r["deadline"] = "parsed"
    except TimeoutError:
        r["deadline"] = "timeout"
    check(r["deadline"] == "timeout", "text parse passed its deadline")
    return r


def case_binary(ms, tmp):
    v = ms.vdf
    inline = (b"\0top\0" + b"\1s\0str\0" + b"\2i\0" + (-5).to_bytes(4, "little", signed=True) +
              b"\3f\0" + bytes.fromhex("0000c03f") + b"\7u\0" + (2 ** 40).to_bytes(8, "little") +
              b"\x0an\0" + (-2 ** 40).to_bytes(8, "little", signed=True) + b"\x08\x08tail")
    d, pos = v.load_binary(inline)
    check(d == {"top": {"s": "str", "i": -5, "f": 1.5, "u": 2 ** 40, "n": -2 ** 40}}, f"binary inline {d}")
    check(inline[pos:] == b"tail", f"binary end at {pos}")
    table = ["k", "x"]
    d2, _ = v.load_binary(b"\1\0\0\0\0v\0\0\1\0\0\0\2\0\0\0\0\7\0\0\0\x08\x08", 0, table)
    check(d2 == {"k": "v", "x": {"k": 7}}, f"binary table {d2}")
    errs = {}
    for name, (data, strings) in {"type": (b"\5k\0x\0\x08", None), "end": (b"\1k\0v\0", None),
                                  "index": (b"\1\x09\0\0\0v\0\x08", table), "short": (b"\2k\0\1\x08", None)}.items():
        try:
            v.load_binary(data, 0, strings)
            errs[name] = "parsed"
        except v.Error:
            errs[name] = "error"
    check(all(x == "error" for x in errs.values()), f"binary errors {errs}")
    return {"d": d, "d2": d2, "errs": errs}


def case_read(ms, tmp):
    v = ms.vdf
    f = os.path.join(tmp, "f")
    fx.write(f, b"0123456789")
    r = {"full": v.read(f, 10)[0].decode(), "tail": v.read(f, 4, tail=True)[0].decode()}
    for name, call in (("big", lambda: v.read(f, 9)), ("missing", lambda: v.read(f + "x", 10))):
        try:
            call()
            r[name] = "read"
        except FileNotFoundError:
            r[name] = "missing"
        except v.Error:
            r[name] = "error"
    os.symlink(f, f + ".l")
    os.mkfifo(f + ".p")
    for name in ("l", "p"):
        t0 = time.monotonic()
        try:
            v.read(f + "." + name, 10)
            r[name] = "read"
        except v.Error:
            r[name] = "error"
        except OSError:
            r[name] = "oserror"
        check(time.monotonic() - t0 < 1, f"read of .{name} took too long")
    check(r == {"full": "0123456789", "tail": "6789", "big": "error", "missing": "missing", "l": "oserror", "p": "error"},
          f"read {r}")
    return r


def apps_base(extra=None, x86_maps=None, arm_maps=None, target=True):
    apps = {891390: fx.x86(x86_maps), 3043620: fx.arm(arm_maps, target)}
    apps.update(extra or {})
    return apps


def titles(ms, tmp, apps, branches=None, raw=None, magic=fx.MAGIC):
    path = os.path.join(tmp, "appinfo.vdf")
    fx.write(path, fx.appinfo(apps, magic=magic, raw=raw))
    a = ms.appinfo.read(path, time.monotonic() + 10)
    if a["state"] != "ok":
        return {"state": a["state"], "error": a["error"]}
    try:
        found = ms.compat.experimental_titles(a["apps"], a["bad"], branches or {})
    except ms.compat.Failed as e:
        return {"state": "failed", "error": str(e)}
    return {"state": "computed", "titles": found["titles"], "shadows": found["shadows"], "target": found["target"],
            "bad": sorted(a["bad"])}


def case_tiers(ms, tmp):
    g = fx.game
    m = fx.app_mapping
    e = fx.manifest_entry
    cases = {
        "deck": ({1: g(1, deck="proton-experimental")}, {}, {}, [1]),
        "frame over deck": ({2: g(2, deck="proton-stable", frame="proton-experimental")}, {}, {}, [2]),
        "frame stable": ({3: g(3, deck="proton-experimental", frame="proton-stable")}, {}, {}, []),
        "frame without key": ({4: g(4, deck="proton-experimental", frame="x", frame_key=False)}, {}, {}, [4]),
        "app x86 name": ({5: g(5, deck="proton-stable", maps=[m("proton_experimental")])}, {}, {}, [5]),
        "app above deck": ({6: g(6, deck="proton-experimental", maps=[m("proton-stable")])}, {}, {}, []),
        "manifest only": ({}, {"7": e(7, "proton-experimental")}, {}, [7]),
        "arm manifest": ({8: g(8)}, {}, {"8": e(8, "proton-experimental")}, [8]),
        "manifest above app": ({9: g(9, maps=[m("proton_experimental")])}, {"9": e(9, "proton-stable")}, {}, []),
        "own priority above manifest": ({10: g(10, maps=[m("proton_experimental", priority=101)])},
                                        {"10": e(10, "proton-stable")}, {}, [10]),
        "own priority below deck": ({11: g(11, deck="proton-experimental", maps=[m("proton-stable", priority="80")])},
                                    {}, {}, [11]),
        "arm before x86": ({12: g(12)}, {"12": e(12, "proton-experimental")}, {"12": e(12, "proton-stable")}, []),
        "x86 under arm": ({13: g(13)}, {"13": e(13, "proton-stable")}, {"13": e(13, "proton-experimental")}, [13]),
        "empty tool": ({14: g(14, deck="proton-experimental")}, {"14": e(14, "")}, {}, [14]),
        "x86 only above": ({15: g(15, deck="proton-experimental")}, {"15": e(15, "proton-hotfix")}, {}, []),
        "x86 only deck": ({16: g(16, deck="proton-6.3-8")}, {}, {}, []),
        "versioned alias": ({17: g(17, deck="proton-experimental")}, {"17": e(17, "proton-8.0-4")}, {}, []),
        "other platform": ({18: g(18, deck="proton-stable", maps=[m("proton_experimental", platform="windows")])},
                           {}, {}, []),
        "arm name": ({19: g(19, deck="proton-experimental-arm64")}, {}, {}, [19]),
        "case": ({20: g(20, deck="Proton-Experimental")}, {}, {}, [20]),
        "native app mapping": ({21: g(21, deck="proton-experimental", maps=[m("SteamLinuxRuntime_sniper")])}, {}, {}, []),
        "later app entry": ({22: g(22, maps=[m("proton-stable"), m("proton_experimental")])}, {}, {}, [22]),
        "unknown tool": ({23: g(23, deck="proton-experimental")}, {"23": e(23, "made-up")}, {}, []),
        "lepton": ({24: g(24, deck="proton-experimental")}, {}, {"24": e(24, "lepton")}, []),
    }
    out = {}
    for name, (games, xm, am, want) in cases.items():
        r = titles(ms, tmp, apps_base(games, xm, am))
        out[name] = r
        check(r.get("titles") == want, f"tiers {name}: {r}, want {want}")
    shadows = out["x86 only above"]["shadows"] + out["unknown tool"]["shadows"]
    check(shadows == [[15, "proton-hotfix", 100], [23, "made-up", 100]], f"shadows {shadows}")
    check(out["x86 only deck"]["shadows"] == [] and out["frame stable"]["shadows"] == [], "shadow without Experimental")
    check(out["native app mapping"]["shadows"] == [], f"linux runtime winner as a shadow {out['native app mapping']}")
    return out


def case_branch(ms, tmp):
    g = fx.game
    m = fx.app_mapping
    apps = apps_base({30: g(30, deck="proton-stable", maps=[m("proton_experimental", branch="beta")]),
                      31: g(31, deck="proton-experimental", maps=[m("proton-stable", branch="old")])},
                     {"32": fx.manifest_entry(32, "proton-experimental", branch="beta")})
    out = {}
    for name, branches, want in (("installed", {30: "beta", 31: "old", 32: "beta"}, [30, 32]),
                                 ("public", {30: "", 31: ""}, [31]),
                                 ("not installed", {}, [31])):
        r = titles(ms, tmp, apps, branches)
        out[name] = r
        check(r.get("titles") == want, f"branch {name}: {r}, want {want}")
    path = os.path.join(tmp, "appinfo.vdf")
    a = ms.appinfo.read(path, None)
    out["branch titles"] = ms.compat.branch_titles(a["apps"])
    check(out["branch titles"] == [30, 31, 32], f"branch titles {out['branch titles']}")
    return out


def case_states(ms, tmp):
    g = fx.game
    out = {}
    good = {40: g(40, deck="proton-experimental"), 41: g(41, deck="proton-experimental")}
    out["no x86"] = titles(ms, tmp, {3043620: fx.arm(), **good})
    out["no arm"] = titles(ms, tmp, {891390: fx.x86(), **good})
    check(out["no x86"]["state"] == "failed" and out["no arm"]["state"] == "failed", f"manifest missing {out}")
    out["no target"] = titles(ms, tmp, apps_base(good, target=False))
    check(out["no target"] == {"state": "computed", "titles": [40, 41], "shadows": [], "target": False, "bad": []},
          f"no target {out['no target']}")
    out["magic"] = titles(ms, tmp, apps_base(good), magic=0x07564428)
    check(out["magic"]["state"] == "failed", f"magic {out['magic']}")
    corrupt = {41: b"\0" + (0).to_bytes(4, "little") + b"\x05junk\x08\x08"}
    out["corrupt app"] = titles(ms, tmp, apps_base(good), raw=corrupt)
    check(out["corrupt app"].get("titles") == [40] and out["corrupt app"].get("bad") == [41], f"corrupt {out['corrupt app']}")
    out["corrupt x86"] = titles(ms, tmp, apps_base(good), raw={891390: b"\0\0\0\0\0\x05\x08"})
    check(out["corrupt x86"]["state"] == "failed", f"corrupt 891390 {out['corrupt x86']}")
    path = os.path.join(tmp, "appinfo.vdf")
    data = fx.appinfo(apps_base(good))
    variants = {"short": data[:10], "table": data[:8] + (len(data) + 50).to_bytes(8, "little") + data[16:],
                "size": data[:20] + (10 ** 6).to_bytes(4, "little") + data[24:]}
    for name, d in variants.items():
        fx.write(path, d)
        a = ms.appinfo.read(path, None)
        out[name] = [a["state"], a["apps"] == {}]
        check(out[name] == ["failed", True], f"header {name}: {a['state']} {a['error']}")
    os.remove(path)
    out["absent"] = ms.appinfo.read(path, None)["state"]
    os.mkfifo(path)
    t0 = time.monotonic()
    out["fifo"] = ms.appinfo.read(path, time.monotonic() + 2)["state"]
    check(time.monotonic() - t0 < 1, "appinfo FIFO read took too long")
    os.remove(path)
    fx.write(path, fx.appinfo(apps_base(good)))
    out["limit"] = ms.appinfo.read(path, None, limit=100)["state"]
    out["deadline"] = ms.appinfo.read(path, time.monotonic() - 1)["state"]
    check([out["absent"], out["fifo"], out["limit"], out["deadline"]] == ["absent", "failed", "failed", "failed"],
          f"appinfo states {out}")
    a = ms.appinfo.read(path, None)
    out["title pass"] = [ms.compat.experimental_titles(a["apps"], a["bad"], {}, d)["titles"]
                         for d in (None, time.monotonic() + 10)]
    try:
        ms.compat.experimental_titles(a["apps"], a["bad"], {}, time.monotonic() - 1)
        out["title deadline"] = "no error"
    except TimeoutError as e:
        out["title deadline"] = str(e)
    check(out["title pass"] == [[40, 41], [40, 41]] and out["title deadline"] == "time budget spent",
          f"title pass deadline {out['title pass']} {out['title deadline']}")
    os.truncate(path, ms.appinfo.LIMIT + 1)
    a = ms.appinfo.read(path, None)
    out["cap"] = [a["state"], a["error"].replace(tmp, "T")]
    check(a["state"] == "failed" and f"{ms.appinfo.LIMIT + 1} bytes, over {ms.appinfo.LIMIT}" in a["error"], f"cap {out['cap']}")
    return out


def project(d, spec):
    if spec is True or not isinstance(d, dict):
        return d
    return {k: project(v, spec.get(k) or spec.get(k.casefold())) for k, v in d.items() if spec.get(k) or spec.get(k.casefold())}


def typed(d, table):
    out = bytearray()
    for k, v in d.items():
        if k not in table:
            table.append(k)
        key = struct.pack("<I", table.index(k))
        if isinstance(v, dict):
            out += b"\0" + key + typed(v, table)
        elif isinstance(v, tuple):
            out += bytes([v[0]]) + key + v[1]
        else:
            out += b"\1" + key + v.encode() + b"\0"
    return bytes(out) + b"\x08"


def chain(n, leaf):
    d = leaf
    for i in range(n):
        d = {f"c{i}": d}
    return d


def case_keep(ms, tmp):
    v = ms.vdf
    out = {}
    path = os.path.join(tmp, "appinfo.vdf")
    fx.write(path, fx.large(1 << 20, seed=7))
    full = ms.appinfo.read(path, None)
    kept = ms.appinfo.read(path, None, keep=ms.compat.KEEP)
    out["apps"] = [len(full["apps"]), len(kept["apps"]), len(full["bad"]), len(kept["bad"])]
    check(full["state"] == kept["state"] == "ok" and not full["bad"] and not kept["bad"], f"keep read {out['apps']}")
    check(kept["apps"] == {a: project(d, ms.compat.KEEP) for a, d in full["apps"].items()}, "keep differs from the projection")
    check(not any("depots" in d or "ufs" in d or "name" in d.get("common", {}) for d in kept["apps"].values()),
          "keep built a skipped value")
    f = ms.compat.experimental_titles(full["apps"], full["bad"], {})
    k = ms.compat.experimental_titles(kept["apps"], kept["bad"], {})
    out["titles"] = len(k["titles"])
    check(f == k and k["titles"] and ms.compat.branch_titles(full["apps"]) == ms.compat.branch_titles(kept["apps"]),
          f"keep changes the compat result: {len(f['titles'])} {len(k['titles'])}")
    leaves = {"u": (7, struct.pack("<Q", 2 ** 40)), "n": (10, struct.pack("<q", -2 ** 40)), "f": (3, struct.pack("<f", 1.5)),
              "i": (2, struct.pack("<i", -5)), "p": (4, struct.pack("<i", 9)), "c": (6, struct.pack("<i", 3)), "s": "str"}
    doc = {"top": {"skip": {**leaves, "deep": chain(30, dict(leaves)), "after": "x"}, "Keep": {**leaves, "sub": {"s": "y"}},
                   "part": {"want": dict(leaves), "drop": chain(12, {"s": "z"})}, "tail": (2, struct.pack("<i", 1))}}
    spec = {"top": {"keep": True, "part": {"want": {"u": True, "s": True}}}}
    table = []
    buf = typed(doc, table) + b"rest"
    d, p = v.load_binary(buf, 0, table)
    dk, pk = v.load_binary(buf, 0, table, None, None, spec)
    out["typed"] = dk
    check(p == pk == len(buf) - 4 and dk == project(d, spec) and dk["top"]["part"]["want"] == {"u": 2 ** 40, "s": "str"},
          f"keep typed {dk} at {pk}")
    errs = {}
    for name, data in (("truncated", typed(doc, table)[:-30]), ("type", typed(doc, table).replace(b"\x07", b"\x05", 1)),
                       ("deep", typed({"top": {"skip": chain(200, {"s": "z"})}}, table))):
        for how, sp in (("full", None), ("keep", spec)):
            try:
                v.load_binary(data, 0, table, None, None, sp)
                errs[f"{name} {how}"] = "parsed"
            except v.Error:
                errs[f"{name} {how}"] = "error"
    out["errs"] = errs
    check(all(x == "error" for x in errs.values()), f"keep errors {errs}")
    inline = (b"\0top\0" + b"\0skip\0" + b"\1s\0str\0" + b"\7u\0" + (2 ** 40).to_bytes(8, "little") + b"\0d\0\2i\0"
              + (5).to_bytes(4, "little") + b"\x08\x08" + b"\0keep\0\1s\0v\0\x08\x08\x08")
    di, pi = v.load_binary(inline, 0, None, None, None, {"top": {"keep": True}})
    check(di == {"top": {"keep": {"s": "v"}}} and pi == len(inline), f"keep inline {di} at {pi}")
    try:
        v.load_binary(b"\0top\0\0skip\0\1s\0str", 0, None, None, None, {"top": {"keep": True}})
        out["inline end"] = "parsed"
    except v.Error:
        out["inline end"] = "error"
    check(out["inline end"] == "error", "keep inline past the end")
    try:
        v.load_binary(buf, 0, table, time.monotonic() - 1, None, spec)
        out["deadline"] = "parsed"
    except TimeoutError:
        out["deadline"] = "timeout"
    check(out["deadline"] == "timeout", "keep passed its deadline")
    return out


def case_config(ms, tmp):
    c = ms.config
    path = os.path.join(tmp, "config.vdf")
    out = {"missing": c.user_mappings(path)}
    fx.write(path, fx.config_vdf([(3000001, "proton_11-arm64", "250"), (3000002, "proton-experimental-arm64", "250"),
                                  (3000003, "", "250"), (0, "my-tool", "75"), (2900000001, "proton_11-arm64", "250")],
                                 extra={"ShaderCacheManager": {"App": {"3000004": {"ShaderCacheSize": "1"}}}}))
    out["file"] = {str(k): v for k, v in sorted(c.user_mappings(path).items())}
    check(out["file"] == {"0": "my-tool", "3000001": "proton_11-arm64", "3000002": "proton-experimental-arm64",
                          "2900000001": "proton_11-arm64"}, f"config {out['file']}")
    with open(path) as f:
        text = f.read()
    fx.write(path, text.replace("CompatToolMapping", "compattoolmapping").replace('"name"', '"Name"')
             .replace('"Valve"', '"valve"'))
    out["case"] = {str(k): v for k, v in sorted(c.user_mappings(path).items())}
    check(out["case"] == out["file"], f"config case {out['case']}")
    fx.write(path, fx.kv_text({"InstallConfigStore": {"Software": {"Valve": {"Steam": {"x": "1"}}}}}))
    out["no block"] = c.user_mappings(path)
    check(out["missing"] == {} and out["no block"] == {}, f"config empty {out}")
    for name, data in (("malformed", text[: len(text) // 2]), ("scalar", fx.kv_text({"InstallConfigStore": {"Software": "x"}}))):
        fx.write(path, data)
        try:
            c.user_mappings(path)
            out[name] = "parsed"
        except ms.vdf.Error:
            out[name] = "error"
    os.remove(path)
    os.mkfifo(path)
    try:
        c.user_mappings(path)
        out["fifo"] = "parsed"
    except ms.vdf.Error:
        out["fifo"] = "error"
    check([out["malformed"], out["scalar"], out["fifo"]] == ["error"] * 3, f"config errors {out}")
    return out


def case_mappings(ms, tmp):
    found = titles(ms, tmp, apps_base({50: fx.game(50, deck="proton-experimental"),
                                       51: fx.game(51, deck="proton-experimental")}))
    path = os.path.join(tmp, "appinfo.vdf")
    a = ms.appinfo.read(path, None)
    f = ms.compat.experimental_titles(a["apps"], a["bad"], {})
    out = {}
    for name, users, want in (("none", {}, ([[50, "proton_11-arm64"], [51, "proton_11-arm64"]], 0)),
                              ("user entry", {51: "proton-experimental-arm64"}, ([[50, "proton_11-arm64"]], 1)),
                              ("default other", {0: "GE-Proton10-1"}, ([[50, "GE-Proton10-1"], [51, "GE-Proton10-1"]], 0)),
                              ("default stable", {0: "proton-stable"}, ([[50, "proton_11-arm64"], [51, "proton_11-arm64"]], 0)),
                              ("default own alias", {0: "Proton-Stable-ARM64"},
                               ([[50, "proton_11-arm64"], [51, "proton_11-arm64"]], 0)),
                              ("default x86 stable", {0: "proton_11"}, ([[50, "proton_11"], [51, "proton_11"]], 0)),
                              ("default x86 alias", {0: "proton-8.0-4"}, ([[50, "proton-8.0-4"], [51, "proton-8.0-4"]], 0)),
                              ("default other arm", {0: "lepton"}, ([[50, "lepton"], [51, "lepton"]], 0)),
                              ("default exp", {0: "proton-experimental"}, ([], 0)),
                              ("default exp x86", {0: "proton_experimental"}, ([], 0)),
                              ("default exp arm", {0: "Proton-Experimental-ARM64"}, ([], 0)),
                              ("default bad name", {0: "my tool"}, ([], 0))):
        entries, skipped, note = ms.compat.mappings(f, users)
        out[name] = [entries, skipped, note]
        check((entries, skipped) == want, f"mappings {name}: {entries} {skipped}, want {want}")
        check((note is None) == bool(entries), f"mappings {name} note {note}")
    nt = ms.compat.experimental_titles(*[ms.appinfo.read(path, None)[k] for k in ("apps", "bad")], {})
    nt["target"] = False
    out["no target"] = list(ms.compat.mappings(nt, {}))
    out["no target user default"] = list(ms.compat.mappings(nt, {0: "GE-Proton10-1"}))
    check(out["no target"][0] == [] and out["no target user default"][0] == [], f"mappings without target {out}")
    check(out["no target"][2] == out["no target user default"][2] == "proton_11-arm64 is not a tool in 3043620, no mappings",
          f"mappings without target note {out['no target']}")
    out["found"] = found
    return out


def case_libraries(ms, tmp):
    lib = ms.libraries
    root = os.path.join(tmp, "Steam")
    sd = os.path.join(tmp, "sd")
    out = {"missing": [p.replace(tmp, "T") for p in lib.library_paths(root + "/")]}
    fx.write(f"{root}/steamapps/libraryfolders.vdf", fx.libraryfolders([root, sd + "/", "relative"]))
    paths = lib.library_paths(root)
    out["paths"] = [p.replace(tmp, "T") for p in paths]
    check(out["missing"] == ["T/Steam"] and out["paths"] == ["T/Steam", "T/sd"], f"libraries {out}")
    fx.write(f"{sd}/steamapps/appmanifest_60.acf", fx.appmanifest(60, beta="beta", user_beta="other"))
    fx.write(f"{root}/steamapps/appmanifest_61.acf", fx.appmanifest(61, user_beta="pending"))
    fx.write(f"{root}/steamapps/appmanifest_62.acf", fx.appmanifest(62))
    out["manifest"] = (lib.app_manifest(paths, 60) or "").replace(tmp, "T")
    out["none"] = lib.app_manifest(paths, 63)
    out["branches"] = [lib.installed_branch(lib.app_manifest(paths, a)) for a in (60, 61, 62)]
    check(out["manifest"] == "T/sd/steamapps/appmanifest_60.acf" and out["none"] is None, f"manifest {out}")
    check(out["branches"] == ["beta", "", ""], f"installed branch {out['branches']}")
    return out


CASES = [case_text, case_binary, case_read, case_tiers, case_branch, case_states, case_keep, case_config, case_mappings,
         case_libraries]


def main():
    import_rule()
    results = {}
    for how, loader in (("import", load_import), ("exec", load_exec)):
        ms = loader()
        res = {}
        for case in CASES:
            tmp = tempfile.mkdtemp()
            try:
                res[case.__name__] = case(ms, tmp)
            except Exception as e:
                check(False, f"{how} {case.__name__}: {type(e).__name__}: {e}")
            finally:
                shutil.rmtree(tmp)
        results[how] = json.dumps(res, sort_keys=True, default=str)
    check(results["import"] == results["exec"], "import and exec loads give different results")
    if failures:
        return 1
    print(f"steam module: ok, python {sys.version.split()[0]}, both loads")
    return 0


sys.exit(main())
