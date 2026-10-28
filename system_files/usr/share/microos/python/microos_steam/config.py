import re

LIMIT = 8 << 20
PATH = ("InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping")


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
