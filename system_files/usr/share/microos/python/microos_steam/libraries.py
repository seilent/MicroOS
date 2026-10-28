import os

LIMIT = 1 << 20


def library_paths(steam_root, deadline=None):
    paths = [steam_root.rstrip("/")]
    try:
        data, _ = vdf.read(f"{paths[0]}/steamapps/libraryfolders.vdf", LIMIT, deadline)
    except FileNotFoundError:
        return paths
    folders = vdf.get(vdf.loads(data.decode("utf-8", "replace"), deadline), "libraryfolders")
    if isinstance(folders, dict):
        for entry in folders.values():
            p = vdf.get(entry, "path")
            if isinstance(p, str) and p.startswith("/") and p.rstrip("/") not in paths:
                paths.append(p.rstrip("/"))
    return paths


def app_manifest(paths, appid):
    for p in paths:
        f = f"{p}/steamapps/appmanifest_{appid}.acf"
        if os.path.lexists(f):
            return f
    return None


def installed_branch(path, deadline=None):
    data, _ = vdf.read(path, LIMIT, deadline)
    state = vdf.get(vdf.loads(data.decode("utf-8", "replace"), deadline), "AppState")
    key = vdf.get(vdf.get(state, "MountedConfig"), "BetaKey")
    return key if isinstance(key, str) else ""
