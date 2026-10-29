import re

LIMIT = 8 << 20
LOGIN_LIMIT = 1 << 20
STEAMID = 76561197960265728
PATH = ("InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping")


def accounts(path, deadline=None):
    data, _ = vdf.read(path, LOGIN_LIMIT, deadline)
    users = vdf.get(vdf.loads(data.decode("utf-8", "replace"), deadline), "users")
    ids, recent, stamps = [], None, {}
    for sid, user in users.items() if isinstance(users, dict) else ():
        if not re.fullmatch(r"[0-9]{17}", sid) or not 0 < int(sid) - STEAMID < 1 << 32:
            continue
        ids.append(int(sid) - STEAMID)
        if recent is None and vdf.get(user, "MostRecent") == "1":
            recent = ids[-1]
        stamp = vdf.get(user, "Timestamp")
        if isinstance(stamp, str) and re.fullmatch(r"[0-9]{1,20}", stamp):
            stamps[ids[-1]] = int(stamp)
    if recent is None and len(ids) == 1:
        recent = ids[0]
    if recent is None:
        top = max(stamps.values(), default=None)
        newest = [a for a, t in stamps.items() if t == top]
        recent = newest[0] if len(newest) == 1 else None
    return ids, recent


def user_mappings(path, deadline=None, limit=LIMIT):
    try:
        data, _ = vdf.read(path, limit, deadline)
    except FileNotFoundError:
        return {}
    node = vdf.loads(data.decode("utf-8", "replace"), deadline)
    for key in PATH:
        node = vdf.get(node, key)
        if node is None:
            return {}
        if not isinstance(node, dict):
            raise vdf.Error(f"{key} is not a block")
    out = {}
    for key, entry in node.items():
        if not re.fullmatch(r"[0-9]{1,10}", key):
            continue
        name = vdf.get(entry, "name")
        if isinstance(name, str) and name:
            out[int(key)] = name
    return out
