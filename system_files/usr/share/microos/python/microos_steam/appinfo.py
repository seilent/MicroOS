import struct

MAGIC = 0x07564429
LIMIT = 64 << 20
APP_HEADER = 60
HEAD = struct.Struct("<IIq")
APP = struct.Struct("<II")
COUNT = struct.Struct("<I")


def strings(data, offset, deadline):
    if offset < HEAD.size or offset + 4 > len(data):
        raise vdf.Error(f"string table offset {offset} outside the file")
    n = COUNT.unpack_from(data, offset)[0]
    if n > len(data) - offset:
        raise vdf.Error(f"string table count {n} too large")
    out = []
    p = offset + 4
    for i in range(n):
        if i % 4096 == 0:
            vdf.check(deadline)
        e = data.find(b"\0", p)
        if e < 0:
            raise vdf.Error("string table runs past the end")
        out.append(data[p:e].decode("utf-8", "replace"))
        p = e + 1
    return out


def sections(data, deadline, out, keep=None):
    if len(data) < HEAD.size:
        raise vdf.Error("header too short")
    magic, _, table = HEAD.unpack_from(data, 0)
    if magic != MAGIC:
        raise vdf.Error(f"magic {magic:#010x}, not {MAGIC:#010x}")
    names = strings(data, table, deadline)
    want = None if keep is None else {"appinfo": keep}
    off = HEAD.size
    while True:
        vdf.check(deadline)
        if off + COUNT.size > table:
            raise vdf.Error(f"app list runs into the string table at {off}")
        appid = COUNT.unpack_from(data, off)[0]
        if appid == 0:
            return
        if off + APP.size > table:
            raise vdf.Error(f"app {appid} header runs into the string table")
        size = APP.unpack_from(data, off)[1]
        start = off + APP.size
        end = start + size
        if size < APP_HEADER or end > table:
            raise vdf.Error(f"app {appid} size {size} outside the file")
        off = end
        try:
            root, pos = vdf.load_binary(data, start + APP_HEADER, names, deadline, end, want)
        except vdf.Error as e:
            out["bad"][appid] = str(e)
            continue
        section = root.get("appinfo")
        if pos != end or not isinstance(section, dict):
            out["bad"][appid] = "section does not fill its size" if pos != end else "no appinfo section"
            continue
        out["apps"][appid] = section


def read(path, deadline, limit=LIMIT, keep=None):
    out = {"state": "failed", "error": None, "apps": {}, "bad": {}, "stat": None}
    try:
        data, st = vdf.read(path, limit, deadline)
    except FileNotFoundError:
        out["state"] = "absent"
        return out
    except (OSError, ValueError) as e:
        out["error"] = str(e)
        return out
    out["stat"] = [st.st_ino, st.st_size, st.st_mtime_ns]
    try:
        sections(data, deadline, out, keep)
    except (vdf.Error, TimeoutError) as e:
        out["error"] = str(e)
        out["apps"] = {}
        out["bad"] = {}
        return out
    out["state"] = "ok"
    return out
