import os
import random
import struct

MAGIC = 0x07564429
LANGS = ("english", "french", "german", "italian", "spanish", "japanese", "koreana", "schinese", "tchinese", "russian",
         "polish", "brazilian", "latam", "turkish")


def kv_binary(d, table, index):
    out = bytearray()
    for k, v in d.items():
        if k not in index:
            index[k] = len(table)
            table.append(k)
        key = struct.pack("<I", index[k])
        if isinstance(v, dict):
            out += b"\0" + key + kv_binary(v, table, index)
        elif isinstance(v, int):
            out += b"\2" + key + struct.pack("<i", v)
        else:
            out += b"\1" + key + v.encode() + b"\0"
    return bytes(out) + b"\x08"


def appinfo(apps, magic=MAGIC, raw=None, table_shift=0):
    raw = raw or {}
    table, index = [], {}
    body = bytearray()
    for appid, section in apps.items():
        kv = raw[appid] if appid in raw else kv_binary({"appinfo": section}, table, index)
        head = struct.pack("<IIQ20sI20s", 2, 1790000000, 0, b"\1" * 20, 1000 + appid % 1000, b"\2" * 20)
        body += struct.pack("<II", appid, len(head) + len(kv)) + head + kv
    body += struct.pack("<I", 0)
    strings = struct.pack("<I", len(table)) + b"".join(s.encode() + b"\0" for s in table)
    return struct.pack("<IIq", magic, 1, 16 + len(body) + table_shift) + bytes(body) + strings


def kv_text(d, depth=0):
    tab = "\t" * depth
    out = []
    for k, v in d.items():
        if isinstance(v, dict):
            out.append(f'{tab}"{k}"\n{tab}{{\n{kv_text(v, depth + 1)}{tab}}}\n')
        else:
            out.append(f'{tab}"{k}"\t\t"{v}"\n')
    return "".join(out)


def write(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)
    os.chmod(path, mode)


def tool(appid, display, aliases=None, source="windows"):
    t = {"appid": appid, "depotid": appid + 1, "display_name": display, "from_oslist": source, "to_oslist": "linux"}
    if aliases:
        t["aliases"] = aliases
    return t


def arm(mappings=None, target=True):
    tools = {
        "proton-experimental-arm64": tool(3200010, "Proton Experimental (ARM64)", "proton-experimental"),
        "lepton": tool(3200020, "Lepton", "lepton-stable,fauxdroid,lepton_11", "android"),
    }
    if target:
        tools["proton_11-arm64"] = tool(3200030, "Proton 11.0-2 (ARM64)", "proton-stable-arm64,proton-stable")
    return {"appid": 3043620, "common": {"name": "Steam Frame ARM64 Compat List", "type": "Config"},
            "extended": {"compat_tools": tools, "app_mappings": mappings or {}}}


def x86(mappings=None):
    tools = {
        "proton_experimental": tool(3200040, "Proton Experimental", "proton-experimental"),
        "proton_11": tool(3200050, "Proton 11.0-2", "proton-9,proton-stable,proton-8.0-4,proton-10.0-beta,proton-11.0-beta"),
        "proton_hotfix": tool(3200060, "Proton Hotfix", "proton-hotfix"),
        "proton_63": tool(3200070, "Proton 6.3-8", "proton-6.3-8"),
        "steamlinuxruntime_sniper": tool(3200080, "Steam Linux Runtime 3.0", "sniper", "linux"),
    }
    return {"appid": 891390, "common": {"name": "SteamPlay 2.0 Manifests", "type": "Config"},
            "extended": {"selectable_aliases": {"proton-stable": {"display_name": "Proton Stable"}},
                         "compat_tools": tools, "app_mappings": mappings or {}}}


def manifest_entry(appid, tool_name, comment="t", **extra):
    e = {"appid": appid, "platform": "linux", "tool": tool_name, "config": "none", "comment": comment}
    e.update(extra)
    return e


def game(appid, deck=None, frame=None, maps=None, frame_key=True):
    common = {"name": f"Game {appid}", "type": "Game"}
    if deck is not None:
        common["steam_deck_compatibility"] = {"category": 3, "configuration": {"supported_input": "gamepad", "recommended_runtime": deck}}
    if frame is not None:
        conf = {"supported_input": "gamepad"}
        if frame_key:
            conf["recommended_runtime"] = frame
        common["steam_frame_compatibility"] = {"category": 3, "configuration": conf}
    section = {"appid": appid, "common": common, "extended": {"developer": "x"}}
    section["config"] = {"installdir": f"Game {appid}", "launch": {"0": {"executable": "game.exe", "config": {"oslist": "windows"}}}}
    if maps:
        section["config"]["app_mappings"] = {str(i): m for i, m in enumerate(maps)}
    return section


def app_mapping(tool_name, **extra):
    e = {"platform": "linux", "tool": tool_name, "comment": "t"}
    e.update(extra)
    return e


def config_vdf(entries, extra=None):
    steam = {"AutoUpdateWindowEnabled": "0"}
    if extra:
        steam.update(extra)
    steam["CompatToolMapping"] = {str(a): {"name": n, "config": "", "priority": p} for a, n, p in entries}
    steam["LastConfigstoreUploadTime"] = "1790000000"
    return kv_text({"InstallConfigStore": {"Software": {"Valve": {"Steam": steam}}}})


def appmanifest(appid, beta=None, user_beta=None):
    user = {"language": "english"}
    mounted = {"language": "english"}
    if user_beta is not None:
        user["BetaKey"] = user_beta
    if beta is not None:
        mounted["BetaKey"] = beta
    return kv_text({"AppState": {"appid": str(appid), "universe": "1", "name": f"Game {appid}", "StateFlags": "4",
                                 "installdir": f"Game {appid}", "buildid": "1",
                                 "InstalledDepots": {str(appid + 1): {"manifest": "1", "size": "1"}},
                                 "UserConfig": user, "MountedConfig": mounted}})


def big_game(appid, r):
    s = min(max(r.lognormvariate(0, 0.9), 0.3), 30)

    def n(k):
        return max(1, int(k * s))

    def h():
        return f"{r.getrandbits(160):040x}"

    langs = LANGS[: min(n(4), len(LANGS))]
    conf = {"supported_input": "gamepad", "requires_manual_keyboard_invoke": 0, "requires_non_steam_launcher": 0}
    pick = r.random()
    if pick < 0.05:
        conf["recommended_runtime"] = "proton-experimental"
    elif pick < 0.15:
        conf["recommended_runtime"] = "proton-stable"
    common = {
        "name": f"Game {appid}", "type": "Game", "ReleaseState": "released", "oslist": "windows", "osarch": "64",
        "clienticon": h(), "clienttga": h(), "icon": h(), "languages": {lang: 1 for lang in langs},
        "steam_deck_compatibility": {"category": 3, "test_timestamp": 1790000000, "tested_build_id": str(r.randrange(10 ** 8)),
                                     "tests": {str(i): {"display": 4, "token": "#SteamDeckVerified_TestResult_Default"}
                                               for i in range(n(3))},
                                     "configuration": conf},
        "small_capsule": {lang: f"capsule_{lang}.jpg" for lang in langs},
        "header_image": {lang: f"header_{lang}.jpg" for lang in langs},
        "library_assets": {"library_capsule": "en", "library_hero": "en", "library_logo": "en",
                           "logo_position": {"pinned_position": "BottomLeft", "width_pct": "40", "height_pct": "30"}},
        "store_asset_mtime": 1790000000,
        "associations": {str(i): {"type": "developer", "name": f"Studio {r.randrange(1000)}"} for i in range(2)},
        "primary_genre": 1, "genres": {"0": "1", "1": "25"},
        "category": {f"category_{c}": 1 for c in r.sample(range(1, 70), min(n(6), 60))},
        "supported_languages": {lang: {"supported": "true", "full_audio": "true", "subtitles": "true"} for lang in langs},
        "steam_release_date": 1790000000, "review_score": 8, "review_percentage": 90,
        "store_tags": {str(i): r.randrange(1, 9000) for i in range(min(n(10), 20))},
    }
    config = {"installdir": f"Game {appid}", "steamcontrollertemplateindex": 1,
              "launch": {str(i): {"executable": f"bin/game{i}.exe", "type": "default", "config": {"oslist": "windows"}}
                         for i in range(n(1))}}
    if pick > 0.97:
        config["app_mappings"] = {"0": app_mapping("proton_experimental")}
    depots = {str(appid + 1 + i): {"config": {"oslist": "windows", "language": r.choice(LANGS)},
                                   "manifests": {"public": {"gid": str(r.getrandbits(63)), "size": str(r.getrandbits(34)),
                                                            "download": str(r.getrandbits(33))}}}
              for i in range(n(4))}
    depots["branches"] = {"public": {"buildid": str(r.randrange(10 ** 8)), "timeupdated": "1790000000"}}
    extended = {"developer": f"Studio {r.randrange(1000)}", "publisher": f"Label {r.randrange(1000)}",
                "homepage": "https://example.com/game", "listofdlc": ",".join(str(appid + 100 + i) for i in range(n(2)))}
    ufs = {"quota": 100000000, "maxnumfiles": 100,
           "savefiles": {"0": {"root": "WinMyDocuments", "path": f"Game {appid}/save", "pattern": "*.sav"}}}
    return {"appid": appid, "common": common, "extended": extended, "config": config, "depots": depots, "ufs": ufs}


def large(size, seed=1):
    r = random.Random(seed)
    first = 3100000
    x86_maps = {str(first + 10 * i): manifest_entry(first + 10 * i, r.choice(("proton-experimental", "proton-stable")))
                for i in range(1, 3000, 7)}
    arm_maps = {str(first + 10 * i): manifest_entry(first + 10 * i, "proton-experimental") for i in range(3, 3000, 97)}
    apps = {891390: x86(x86_maps), 3043620: arm(arm_maps)}
    total = 0
    appid = first
    while total < size:
        appid += 10
        apps[appid] = big_game(appid, r)
        total += len(kv_binary({"appinfo": apps[appid]}, [], {})) + 68
    return appinfo(apps)


def libraryfolders(paths):
    return kv_text({"libraryfolders": {str(i): {"path": p, "label": "", "contentid": "1", "totalsize": "0",
                                                  "apps": {}} for i, p in enumerate(paths)}})


def loginusers(users):
    return kv_text({"users": {sid: {"AccountName": "a", "PersonaName": "p", "RememberPassword": "1",
                                    "WantsOfflineMode": "0", "SkipOfflineModeWarning": "0", "AllowAutoLogin": "1",
                                    "MostRecent": most, "Timestamp": "1790000000"} for sid, most in users}})
