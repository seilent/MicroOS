import struct

LIMIT = 16 << 20
EXTRA = {0x06565527: 0, 0x06565528: 8}
HEAD = struct.Struct("<II")
ID = struct.Struct("<I")
HASH = 20
CHANGE = 4
END = 0xFFFFFFFF


def holders(path, appid, deadline=None, limit=LIMIT):
    data, _ = vdf.read(path, limit, deadline)
    if len(data) < HEAD.size:
        raise vdf.Error("header too short")
    magic = HEAD.unpack_from(data, 0)[0]
    if magic not in EXTRA:
        raise vdf.Error(f"magic {magic:#010x}, not one of {', '.join(f'{m:#010x}' for m in EXTRA)}")
    pos = HEAD.size
    out = set()
    while True:
        vdf.check(deadline)
        if pos + ID.size > len(data):
            raise vdf.Error("package list runs past the end")
        package = ID.unpack_from(data, pos)[0]
        pos += ID.size
        if package == END:
            return out
        pos += HASH + CHANGE + EXTRA[magic]
        if pos > len(data):
            raise vdf.Error(f"package {package} header runs past the end")
        key = str(package)
        root, pos = vdf.load_binary(data, pos, None, deadline, keep={key: {"appids": True}})
        block = vdf.get(root, key)
        if not isinstance(block, dict):
            raise vdf.Error(f"package {package} has no block under its id")
        apps = vdf.get(block, "appids")
        if isinstance(apps, dict) and any(type(v) is int and v == appid for v in apps.values()):
            out.add(package)
