import struct
import zlib

LIMIT = 16 << 20
OK = 1
FAIL = 2
IA = 16807
IM = 2147483647
IQ = 127773
IR = 2836
NTAB = 32
NDIV = 1 + (IM - 1) // NTAB
LOW = 32
SPAN = 126 - LOW + 1
TOP = 0x7FFFFFFF - (0x80000000 % SPAN)
CRC = struct.Struct("<I")
FIXED = {1: struct.Struct("<Q"), 5: struct.Struct("<I")}
FIELDS = {1: "package_id", 4: "minute_limit", 5: "minutes_used", 7: "flags", 9: "license_type", 12: "owner_id"}
SIGNED = {"minute_limit", "minutes_used"}
WIRES = {1: 0, 2: 2}


def step(idum):
    k = idum // IQ
    idum = IA * (idum - k * IQ) - IR * k
    return idum + IM if idum < 0 else idum


def keystream(seed):
    idum = max(seed, 1)
    table = [0] * NTAB
    for j in range(NTAB + 7, -1, -1):
        idum = step(idum)
        if j < NTAB:
            table[j] = idum
    iy = table[0]
    while True:
        idum = step(idum)
        j = iy // NDIV
        iy = table[j]
        table[j] = idum
        if iy <= TOP:
            yield LOW + iy % SPAN


def decode(data, account, deadline=None):
    if len(data) < CRC.size:
        raise vdf.Error("licensecache shorter than its checksum")
    key = keystream(account)
    out = bytearray(len(data))
    for i, c in enumerate(data):
        if i % 4096 == 0:
            vdf.check(deadline)
        out[i] = c ^ next(key)
    body = bytes(out[: -CRC.size])
    if zlib.crc32(body) != CRC.unpack_from(out, len(body))[0]:
        raise vdf.Error("licensecache checksum mismatch")
    return body


def int32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v >= 1 << 31 else v


def varint(data, pos, end):
    value = 0
    for shift in range(0, 70, 7):
        if pos >= end:
            raise vdf.Error("varint runs past the end")
        c = data[pos]
        pos += 1
        value |= (c & 0x7F) << shift
        if c < 0x80:
            return value & 0xFFFFFFFFFFFFFFFF, pos
    raise vdf.Error("varint over 10 bytes")


def fields(data, pos, end):
    while pos < end:
        key, pos = varint(data, pos, end)
        number, wire = key >> 3, key & 7
        if number == 0:
            raise vdf.Error("field number 0")
        if wire == 0:
            value, pos = varint(data, pos, end)
        elif wire == 2:
            n, pos = varint(data, pos, end)
            if n > end - pos:
                raise vdf.Error("length runs past the end")
            value = (pos, pos + n)
            pos += n
        elif wire in FIXED:
            f = FIXED[wire]
            if pos + f.size > end:
                raise vdf.Error("fixed field runs past the end")
            value = f.unpack_from(data, pos)[0]
            pos += f.size
        else:
            raise vdf.Error(f"wire type {wire}")
        yield number, wire, value


def licenses(body, deadline=None):
    eresult = FAIL
    out = []
    for n, (number, wire, value) in enumerate(fields(body, 0, len(body))):
        if n % 1024 == 0:
            vdf.check(deadline)
        if number in WIRES and wire != WIRES[number]:
            raise vdf.Error(f"field {number} wire type {wire}")
        if number == 1:
            eresult = int32(value)
        elif number == 2:
            lic = {}
            for sub, sub_wire, sub_value in fields(body, *value):
                name = FIELDS.get(sub)
                if name and sub_wire != 0:
                    raise vdf.Error(f"license field {sub} wire type {sub_wire}")
                if name:
                    lic[name] = int32(sub_value) if name in SIGNED else sub_value & 0xFFFFFFFF
            out.append(lic)
    return eresult, out


def read(path, account, deadline=None, limit=LIMIT):
    data, _ = vdf.read(path, limit, deadline)
    return licenses(decode(data, account, deadline), deadline)
