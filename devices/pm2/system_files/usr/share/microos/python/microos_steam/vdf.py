import functools
import os
import re
import stat
import struct
import time

DEPTH = 64
TEXT_TOKEN = re.compile(r'\s+|//[^\n]*|"((?:[^"\\]|\\.)*)"|([{}])|\[[^\]\n]*\]|([^\s{}"\[\]]+)', re.S)
ESCAPES = {"n": "\n", "t": "\t", "\\": "\\", '"': '"'}
ESCAPE = re.compile(r"\\(.)", re.S)
INT32 = struct.Struct("<i")
UINT32 = struct.Struct("<I")
FLOAT32 = struct.Struct("<f")
UINT64 = struct.Struct("<Q")
INT64 = struct.Struct("<q")
FIXED = {2: INT32, 3: FLOAT32, 4: INT32, 6: INT32, 7: UINT64, 10: INT64}
ENDS = (8, 11)
NEST = 8


class Error(ValueError):
    pass


@functools.cache
def skipper(inline):
    key = rb"[^\x00]*+\x00" if inline else rb".{4}"
    flat = [rb"\x01" + key + rb"[^\x00]*+\x00"]
    for size in sorted({f.size for f in FIXED.values()}):
        types = bytes(t for t, f in FIXED.items() if f.size == size)
        flat.append(b"[" + types + b"]" + key + b".{%d}" % size)
    p = b"(?:" + b"|".join(flat) + b")*+"
    for _ in range(NEST):
        p = b"(?:" + b"|".join(flat) + b"|\x00" + key + p + b"[\x08\x0b])*+"
    return re.compile(p, re.S).match


def check(deadline):
    if deadline is not None and time.monotonic() > deadline:
        raise TimeoutError("time budget spent")


def read(path, limit, deadline=None, tail=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise Error(f"{path}: not a regular file")
        if st.st_size > limit:
            if not tail:
                raise Error(f"{path}: {st.st_size} bytes, over {limit}")
            os.lseek(fd, st.st_size - limit, os.SEEK_SET)
        parts = []
        n = 0
        while True:
            check(deadline)
            b = os.read(fd, min(1 << 20, limit + 1 - n))
            if not b:
                break
            parts.append(b)
            n += len(b)
            if n > limit:
                if tail:
                    break
                raise Error(f"{path}: over {limit} bytes")
        return b"".join(parts)[:limit], st
    finally:
        os.close(fd)


def get(d, key, default=None):
    if not isinstance(d, dict):
        return default
    if key in d:
        return d[key]
    k = key.casefold()
    for name, value in d.items():
        if name.casefold() == k:
            return value
    return default


def unescape(s):
    return ESCAPE.sub(lambda m: ESCAPES.get(m.group(1), m.group(0)), s) if "\\" in s else s


def loads(text, deadline=None):
    root = {}
    stack = [root]
    key = None
    pos = 0
    n = 0
    end = len(text)
    while pos < end:
        m = TEXT_TOKEN.match(text, pos)
        if not m:
            raise Error(f"bad token at offset {pos}")
        pos = m.end()
        quoted, brace, bare = m.group(1), m.group(2), m.group(3)
        if quoted is None and brace is None and bare is None:
            continue
        n += 1
        if n % 4096 == 0:
            check(deadline)
        if brace == "{":
            if key is None:
                raise Error(f"block without a key at offset {m.start()}")
            if len(stack) >= DEPTH:
                raise Error("nested too deep")
            child = {}
            stack[-1][key] = child
            stack.append(child)
            key = None
        elif brace == "}":
            if key is not None or len(stack) == 1:
                raise Error(f"unexpected close at offset {m.start()}")
            stack.pop()
        else:
            token = unescape(quoted) if quoted is not None else bare
            if key is None:
                key = token
            else:
                stack[-1][key] = token
                key = None
    if key is not None or len(stack) != 1:
        raise Error("unexpected end")
    return root


def skip(data, pos, end, inline, depth, deadline):
    match = skipper(inline)
    d = 1
    while True:
        check(deadline)
        pos = match(data, pos, end).end()
        if pos >= end:
            raise Error("binary KeyValues run past the end")
        t = data[pos]
        if t in ENDS:
            pos += 1
            d -= 1
            if not d:
                return pos
        elif t == 0:
            if inline:
                e = data.find(b"\0", pos + 1, end)
                if e < 0:
                    raise Error("unterminated key")
                pos = e + 1
            elif pos + 5 > end:
                raise Error("key index past the end")
            else:
                pos += 5
            d += 1
            if depth + d > DEPTH:
                raise Error("nested too deep")
        elif t == 1 or t in FIXED:
            raise Error("value past the end")
        else:
            raise Error(f"value type {t}")


def load_binary(data, pos=0, strings=None, deadline=None, end=None, keep=None):
    end = len(data) if end is None else end
    root = {}
    stack = [root]
    wants = [True if keep is None else keep]
    want = wants[0]
    n = 0
    while True:
        if pos >= end:
            raise Error("binary KeyValues run past the end")
        t = data[pos]
        pos += 1
        n += 1
        if n % 4096 == 0:
            check(deadline)
        if t in ENDS:
            stack.pop()
            if not stack:
                return root, pos
            wants.pop()
            want = wants[-1]
            continue
        if strings is None:
            e = data.find(b"\0", pos, end)
            if e < 0:
                raise Error("unterminated key")
            key = data[pos:e].decode("utf-8", "replace")
            pos = e + 1
        else:
            if pos + 4 > end:
                raise Error("key index past the end")
            i = UINT32.unpack_from(data, pos)[0]
            pos += 4
            if i >= len(strings):
                raise Error(f"key index {i} outside the string table")
            key = strings[i]
        sub = True
        if want is not True:
            sub = want.get(key) or want.get(key.casefold())
            if not sub:
                if t == 0:
                    if len(stack) >= DEPTH:
                        raise Error("nested too deep")
                    pos = skip(data, pos, end, strings is None, len(stack), deadline)
                elif t == 1:
                    e = data.find(b"\0", pos, end)
                    if e < 0:
                        raise Error("unterminated string")
                    pos = e + 1
                elif t in FIXED:
                    pos += FIXED[t].size
                    if pos > end:
                        raise Error("value past the end")
                else:
                    raise Error(f"value type {t}")
                continue
        if t == 0:
            if len(stack) >= DEPTH:
                raise Error("nested too deep")
            child = {}
            stack[-1][key] = child
            stack.append(child)
            wants.append(sub)
            want = sub
        elif t == 1:
            e = data.find(b"\0", pos, end)
            if e < 0:
                raise Error("unterminated string")
            stack[-1][key] = data[pos:e].decode("utf-8", "replace")
            pos = e + 1
        elif t in FIXED:
            f = FIXED[t]
            if pos + f.size > end:
                raise Error("value past the end")
            stack[-1][key] = f.unpack_from(data, pos)[0]
            pos += f.size
        else:
            raise Error(f"value type {t}")
