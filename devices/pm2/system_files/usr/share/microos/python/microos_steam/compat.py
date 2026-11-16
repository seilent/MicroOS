import re

TARGET = "proton_11-arm64"
EXPERIMENTAL = "proton-experimental-arm64"
ARM = 3043620
X86 = 891390
RUNTIME, APP, MANIFEST = 85, 90, 100
FRAME = "steam_frame_compatibility"
DECK = "steam_deck_compatibility"
NAME = re.compile(r"[A-Za-z0-9_.-]+")
RUNTIME_KEEP = {"configuration": {"recommended_runtime": True}}
KEEP = {"common": {FRAME: RUNTIME_KEEP, DECK: RUNTIME_KEEP}, "config": {"app_mappings": True},
        "extended": {"compat_tools": True, "app_mappings": True}}


class Failed(Exception):
    pass


def extended(apps, bad, appid):
    if appid in bad:
        raise Failed(f"app {appid}: {bad[appid]}")
    if appid not in apps:
        raise Failed(f"app {appid} is not in the cache")
    ext = vdf.get(apps[appid], "extended")
    if not isinstance(ext, dict):
        raise Failed(f"app {appid} has no extended section")
    return ext


def names(value):
    return [a.strip() for a in value.split(",") if a.strip()] if isinstance(value, str) else []


def block(d, key):
    v = vdf.get(d, key)
    return v if isinstance(v, dict) else {}


def own(arm):
    table = {}
    tools = block(arm, "compat_tools")
    for name, info in tools.items():
        if isinstance(info, dict):
            table.setdefault(name.casefold(), name)
    for name, info in tools.items():
        if isinstance(info, dict):
            for a in names(vdf.get(info, "aliases")):
                table.setdefault(a.casefold(), name)
    return table


def aliases(table, x86):
    table = dict(table)
    other = {}
    for name, info in block(x86, "compat_tools").items():
        if not isinstance(info, dict):
            continue
        al = names(vdf.get(info, "aliases"))
        hit = next((table[a.casefold()] for a in al if a.casefold() in table), "")
        for n in [name] + al:
            other.setdefault(n.casefold(), hit)
    for k, v in other.items():
        table.setdefault(k, v)
    return table


def runtimes(*manifests):
    out = set()
    for m in manifests:
        for name, info in block(m, "compat_tools").items():
            src = vdf.get(info, "from_oslist")
            if isinstance(src, str) and src.casefold() == "linux":
                out.update(n.casefold() for n in [name] + names(vdf.get(info, "aliases")))
    return out


def by_title(maps):
    out = {}
    for key, e in maps.items():
        if not isinstance(e, dict):
            continue
        appid = vdf.get(e, "appid", key)
        try:
            appid = int(appid)
        except (TypeError, ValueError):
            continue
        out.setdefault(appid, []).append(e)
    return out


def priority(e, tier):
    p = vdf.get(e, "priority")
    if isinstance(p, int) and not isinstance(p, bool):
        return p
    if isinstance(p, str) and re.fullmatch(r"-?[0-9]{1,9}", p.strip()):
        return int(p)
    return tier


def usable(e, appid, branches):
    tool = vdf.get(e, "tool")
    if not isinstance(tool, str) or not tool:
        return None
    platform = vdf.get(e, "platform")
    if isinstance(platform, str) and platform and platform.casefold() != "linux":
        return None
    branch = vdf.get(e, "branch")
    if isinstance(branch, str) and branch and branches.get(appid) != branch:
        return None
    return tool


def runtime(section):
    common = block(section, "common")
    for b in (FRAME, DECK):
        v = vdf.get(block(block(common, b), "configuration"), "recommended_runtime")
        if isinstance(v, str) and v:
            return v
    return None


def branch_titles(apps):
    out = set()
    for appid, section in apps.items():
        for e in block(block(section, "config"), "app_mappings").values():
            if isinstance(vdf.get(e, "branch"), str) and vdf.get(e, "branch"):
                out.add(appid)
    for m in (ARM, X86):
        for appid, es in by_title(block(block(apps.get(m), "extended"), "app_mappings")).items():
            if any(isinstance(vdf.get(e, "branch"), str) and vdf.get(e, "branch") for e in es):
                out.add(appid)
    return sorted(out)


def experimental_titles(apps, bad, branches, deadline=None):
    arm = extended(apps, bad, ARM)
    x86 = extended(apps, bad, X86)
    mine = own(arm)
    table = aliases(mine, x86)
    native = runtimes(arm, x86)
    target = TARGET in block(arm, "compat_tools")
    manifests = ((2, by_title(block(x86, "app_mappings"))), (3, by_title(block(arm, "app_mappings"))))
    titles = set(apps)
    for _, m in manifests:
        titles.update(m)
    titles.discard(0)
    kept = []
    shadows = []
    for n, appid in enumerate(sorted(titles)):
        if n % 4096 == 0:
            vdf.check(deadline)
        section = apps.get(appid)
        entries = []
        rr = runtime(section)
        if rr:
            entries.append((RUNTIME, 0, 0, rr))
        for i, e in enumerate(block(block(section, "config"), "app_mappings").values()):
            if isinstance(e, dict) and (tool := usable(e, appid, branches)):
                entries.append((priority(e, APP), 1, i, tool))
        for rank, m in manifests:
            for i, e in enumerate(m.get(appid, ())):
                if tool := usable(e, appid, branches):
                    entries.append((priority(e, MANIFEST), rank, i, tool))
        if not entries:
            continue
        top = max(entries)
        hit = table.get(top[3].casefold())
        if hit == EXPERIMENTAL:
            kept.append(appid)
        elif (not hit and top[3].casefold() not in native
              and any(table.get(e[3].casefold()) == EXPERIMENTAL for e in entries)):
            shadows.append([appid, top[3], top[0]])
    return {"titles": kept, "shadows": shadows, "aliases": table, "own": mine, "target": target}


def mappings(found, users):
    if not found["target"]:
        return [], 0, f"{TARGET} is not a tool in {ARM}, no mappings"
    tool = TARGET
    default = users.get(0)
    if default:
        key = default.casefold()
        hit = found["own"].get(key)
        if hit is None and found["aliases"].get(key) == EXPERIMENTAL:
            hit = EXPERIMENTAL
        if hit == EXPERIMENTAL:
            return [], 0, f"user default tool {default} is Proton Experimental, no mappings"
        if hit != TARGET:
            if not NAME.fullmatch(default):
                return [], 0, f"user default tool {default!r} is not a usable name, no mappings"
            tool = default
    entries = [[appid, tool] for appid in found["titles"] if appid not in users]
    return entries, len(found["titles"]) - len(entries), None
