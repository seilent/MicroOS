#!/usr/bin/env python3
import argparse
import os
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

IFACE = "android.hardware.sensors@1.0::ISensors"
CTRL = 0xFFFFFFFE
GRAVITY = 9.80665
LOOKUP = (0xABABABABABABABAB, 0xABABABABABABABAB)
ACCEL = (0x1122334455667788, 0x99AABBCCDDEEFF00)
LIGHT = (0x0102030405060708, 0x1112131415161718)
SERVER = (5, 21)
GET_SENSORS_LIST, SET_OPERATION_MODE, ACTIVATE, POLL, BATCH, FLUSH, INJECT, REGISTER, UNREGISTER, CONFIG = range(1, 11)
OK, BAD_VALUE, INVALID_OPERATION = 0, -22, -38
EBADMSG, EINVAL = -74, -22
GOLDEN_ACCEL_SUID = ("000100200037000130002e000a1209abababababababab11abababababababab15000200001a0408011001220d"
                     "120b0a05616363656c1000180110010001")

failures = []


def check(name, got, want):
    if got == want:
        print("ok   %s" % name)
    else:
        print("FAIL %s\n  got  %r\n  want %r" % (name, got, want))
        failures.append(name)


def near(name, got, want, tolerance=1e-4):
    if got is not None and abs(got - want) <= tolerance:
        print("ok   %s" % name)
    else:
        print("FAIL %s\n  got  %r\n  want %r" % (name, got, want))
        failures.append(name)


def varint(value):
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def key(field, wire):
    return varint(field << 3 | wire)


def uint(field, value):
    return key(field, 0) + varint(value)


def fixed32(field, value):
    return key(field, 5) + struct.pack("<I", value)


def fixed64(field, value):
    return key(field, 1) + struct.pack("<Q", value)


def blob(field, value):
    return key(field, 2) + varint(len(value)) + value


def suid(value):
    return fixed64(1, value[0]) + fixed64(2, value[1])


def tlv(entry, value):
    return bytes([entry]) + struct.pack("<H", len(value)) + value


def qmi(kind, txn, msg, tlvs):
    return bytes([kind]) + struct.pack("<HHH", txn, msg, len(tlvs)) + tlvs


def request(txn, target, msg, payload):
    config = uint(1, 1) + uint(2, 1)
    body = b"" if payload is None else blob(2, payload)
    inner = blob(1, suid(target)) + fixed32(2, msg) + blob(3, config) + blob(4, body)
    return qmi(0, txn, 0x20, tlv(1, struct.pack("<H", len(inner)) + inner) + tlv(0x10, b"\x01"))


def suid_request(txn, data_type):
    return request(txn, LOOKUP, 512, blob(1, data_type.encode()) + uint(2, 0) + uint(3, 1))


def enable(txn, target, rate):
    return request(txn, target, 513, fixed32(1, struct.unpack("<I", struct.pack("<f", rate))[0]))


def on_change(txn, target):
    return request(txn, target, 514, b"")


def disable(txn, target):
    return request(txn, target, 10, None)


def lookup():
    return struct.pack("<5I", 10, 400, 0, 0, 0)


def server(cmd, node, port):
    return struct.pack("<5I", cmd, 400, 1, node, port)


def event(msg, payload):
    return fixed32(1, msg) + fixed64(2, 123456) + blob(3, payload)


def report(target, events):
    inner = blob(1, suid(target))
    for entry in events:
        inner += blob(2, entry)
    return qmi(4, 0, 0x22, tlv(2, struct.pack("<H", len(inner)) + inner))


def suid_event(data_type, suids):
    payload = blob(1, data_type.encode())
    for value in suids:
        payload += blob(2, suid(value))
    return event(768, payload)


def sample(values, status=3, packed=True):
    if packed:
        payload = blob(1, struct.pack("<%df" % len(values), *values))
    else:
        payload = b"".join(fixed32(1, struct.unpack("<I", struct.pack("<f", v))[0]) for v in values)
    return event(1025, payload + uint(2, status))


def response(txn, result, error):
    return qmi(2, txn, 0x20, tlv(2, struct.pack("<HH", result, error)))


def parse_items(text):
    items = []
    for part in text.split(";") if text else []:
        words = part.split(" ")
        if words[0] == "i32":
            items.append(("i32", int(words[1])))
        elif words[0] == "buf":
            data = b"" if words[4] == "-" else bytes.fromhex(words[4])
            items.append(("buf", int(words[1]), words[2], int(words[3]), data))
    return items


def vectors(items):
    bufs = [item for item in items if item[0] == "buf"]
    out = []
    for i in range(0, len(bufs) - 1, 2):
        head, data = bufs[i], bufs[i + 1]
        count = struct.unpack_from("<I", head[4], 8)[0]
        out.append((head, data, count))
    return out


def events_of(items):
    vecs = vectors(items)
    if not vecs:
        return []
    head, data, count = vecs[0]
    out = []
    for i in range(count):
        stamp, handle, kind = struct.unpack_from("<qii", data[4], 80 * i)
        payload = data[4][80 * i + 16:80 * i + 80]
        out.append((stamp, handle, kind, payload))
    return out


class Daemon:
    def __init__(self, binary, env=None):
        parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        self.log = tempfile.TemporaryFile()
        full = dict(os.environ, FAKE_CTL=str(child.fileno()))
        full.update(env or {})
        self.proc = subprocess.Popen([binary, "/dev/hwbinder"], pass_fds=[child.fileno()], env=full,
                                     stderr=self.log)
        child.close()
        self.sock = parent
        self.buf = b""
        self.lines = []
        self.ids = 0
        self.pings = 0

    def send(self, text):
        self.sock.sendall((text + "\n").encode())

    def pump(self, timeout):
        ready, _, _ = select.select([self.sock], [], [], timeout)
        if not ready:
            return False
        data = self.sock.recv(65536)
        if not data:
            return False
        self.buf += data
        while b"\n" in self.buf:
            text, self.buf = self.buf.split(b"\n", 1)
            self.lines.append(text.decode())
        return True

    def expect(self, test, timeout=2.0):
        end = time.monotonic() + timeout
        while True:
            for i, text in enumerate(self.lines):
                if test(text):
                    del self.lines[i]
                    return text
            remaining = end - time.monotonic()
            if remaining <= 0 or (not self.pump(remaining) and self.proc.poll() is not None):
                return None

    def sync(self):
        self.pings += 1
        self.send("ping %d" % self.pings)
        return self.expect(lambda text: text == "pong %d" % self.pings) is not None

    def take(self, prefix):
        found = [text for text in self.lines if text.startswith(prefix)]
        self.lines = [text for text in self.lines if not text.startswith(prefix)]
        return found

    def call(self, code, *args, iface=IFACE):
        self.ids += 1
        ident = self.ids
        self.send(" ".join(["call", str(ident), str(code), iface] + list(args)))
        text = self.expect(lambda t: t.split(" ")[:2] in (["reply", str(ident)], ["status", str(ident)],
                                                          ["blocked", str(ident)]))
        if text is None:
            return ident, None, None, []
        words = text.split(" ", 3)
        return ident, words[0], int(words[2]), parse_items(words[3] if len(words) > 3 else "")

    def complete(self, ident, timeout=2.0):
        text = self.expect(lambda t: t.split(" ")[:2] == ["complete", str(ident)], timeout)
        if text is None:
            return None, []
        words = text.split(" ", 3)
        return int(words[2]), parse_items(words[3] if len(words) > 3 else "")

    def sent(self, sock, timeout=2.0):
        text = self.expect(lambda t: t.startswith("sent %d " % sock), timeout)
        if text is None:
            return None
        words = text.split(" ")
        return int(words[2]), int(words[3]), bytes.fromhex(words[4]) if words[4] != "-" else b""

    def ssc(self, sock, node, port, payload):
        self.send("ssc %d %d %d %s" % (sock, node, port, payload.hex()))

    def stderr(self):
        self.log.seek(0)
        return self.log.read().decode(errors="replace")

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
        try:
            return self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            return self.proc.wait()


def result_of(items):
    return [item[1] for item in items if item[0] == "i32"]


def startup(daemon):
    check("start manager", daemon.expect(lambda t: t.startswith("manager ")), "manager /dev/hwbinder hidl hidl")
    check("start object", daemon.expect(lambda t: t.startswith("object ")), "object " + IFACE)
    for sock in (0, 1):
        check("start socket %d" % sock, daemon.expect(lambda t, s=sock: t == "socket %d" % s) is not None, True)
        check("start lookup %d" % sock, daemon.sent(sock), (1, CTRL, lookup()))
    check("start sync", daemon.sync(), True)
    check("start no add before the service manager", daemon.take("add "), [])


def sensor_list(daemon):
    _, kind, status, items = daemon.call(GET_SENSORS_LIST)
    check("list reply", (kind, status), ("reply", 0))
    check("list status word", items[:1], [("i32", 0)])
    bufs = [item for item in items if item[0] == "buf"]
    check("list buffer count", len(bufs), 2 + 2 * 4)
    if len(bufs) != 2 + 2 * 4:
        return
    head, array = bufs[0], bufs[1]
    check("list vec header", (head[1], head[2], head[3]), (0, "none", 16))
    check("list vec count and owner", struct.unpack_from("<IB", head[4], 8), (2, 1))
    check("list array", (array[1], array[2], array[3]), (1, "0@0", 224))
    want = [
        (1, "Accelerometer", 1, "android.sensor.accelerometer", 156.9064, 0.0047884, 0.24, 10000, 1000000, 0),
        (2, "Ambient light", 5, "android.sensor.light", 4096.0, 0.54, 0.09, 0, 0, 2),
    ]
    data = array[4]
    for i, (handle, name, kind, type_name, max_range, resolution, power, min_delay, max_delay, flags) in enumerate(want):
        base = 112 * i
        check("list %s handle" % name, struct.unpack_from("<i", data, base)[0], handle)
        check("list %s version and type" % name, struct.unpack_from("<ii", data, base + 40), (1, kind))
        got = struct.unpack_from("<fff", data, base + 64)
        near("list %s max range" % name, got[0], max_range, 1e-3)
        near("list %s resolution" % name, got[1], resolution, 1e-6)
        near("list %s power" % name, got[2], power, 1e-6)
        check("list %s delays and fifo" % name, struct.unpack_from("<iII", data, base + 76) +
              struct.unpack_from("<iI", data, base + 104), (min_delay, 0, 0, max_delay, flags))
        for j, (offset, text) in enumerate(((8, name), (24, "MicroOS"), (48, type_name), (88, ""))):
            child = bufs[2 + 4 * i + j]
            check("list %s string %d parent" % (name, offset), (child[2], child[3]),
                  ("1@%d" % (base + offset), len(text) + 1))
            check("list %s string %d bytes" % (name, offset), child[4], text.encode() + b"\0")
            check("list %s string %d length and owner" % (name, offset),
                  struct.unpack_from("<IB", data, base + offset + 8), (len(text), 1))


def hub(daemon, sock, name, target, txn):
    daemon.ssc(sock, 1, CTRL, server(4, *SERVER))
    check("%s suid request" % name, daemon.sent(sock), SERVER + (suid_request(txn, name),))
    daemon.ssc(sock, *SERVER, report(LOOKUP, [suid_event(name, [target])]))
    check("%s sync after suid" % name, daemon.sync(), True)


def drain(daemon):
    ident, kind, _, items = daemon.call(POLL, "i:64")
    if kind != "blocked":
        return events_of(items)
    status, items = daemon.complete(ident)
    return events_of(items) if status is not None else []


def empty_poll(items):
    vecs = vectors(items)
    return result_of(items), [(v[2], v[1][3]) for v in vecs]


def main_run(binary):
    daemon = Daemon(binary)
    startup(daemon)
    daemon.send("present 1")
    check("add on presence", daemon.expect(lambda t: t.startswith("add ")), "add default object")
    sensor_list(daemon)

    check("accel suid golden", suid_request(1, "accel").hex(), GOLDEN_ACCEL_SUID)
    hub(daemon, 0, "accel", ACCEL, 1)
    hub(daemon, 1, "ambient_light", LIGHT, 1)
    check("nothing enabled before activate", daemon.take("sent "), [])

    _, kind, status, items = daemon.call(POLL, "i:0")
    check("poll 0 is bad value", (kind, status, empty_poll(items)), ("reply", 0, ([0, BAD_VALUE], [(0, 0), (0, 0)])))

    _, kind, status, items = daemon.call(BATCH, "i:1", "l:20000000", "l:100000000")
    check("batch accel", (kind, status, result_of(items)), ("reply", 0, [0, OK]))
    _, kind, status, items = daemon.call(ACTIVATE, "i:1", "b:1")
    check("activate accel", (kind, status, result_of(items)), ("reply", 0, [0, OK]))
    check("accel enable at 50 Hz", daemon.sent(0), SERVER + (enable(2, ACCEL, 50.0),))
    check("50 Hz request body", enable(2, ACCEL, 50.0).hex()[-22:-8], "12050d00004842")

    ident, kind, status, _ = daemon.call(POLL, "i:16")
    check("poll blocks with no events", (kind, status), ("blocked", 0))
    daemon.ssc(0, *SERVER, report(ACCEL, [sample((1.0, 2.0, 9.0), 3)]))
    status, items = daemon.complete(ident)
    check("poll completes on a sample", status, 0)
    events = events_of(items)
    check("one accel event", len(events), 1)
    stamp, handle, kind, payload = events[0]
    check("accel event handle and type", (handle, kind), (1, 1))
    check("accel event in the guest frame", struct.unpack_from("<fffb", payload), (2.0, -1.0, 9.0, 3))
    check("accel event stamped", stamp > 0, True)
    check("poll result ok and no dynamic sensors", empty_poll(items)[0], [0, OK])
    check("no dynamic sensors", empty_poll(items)[1][1], (0, 0))

    daemon.ssc(0, *SERVER, report(ACCEL, [sample((0.5, 0.25, 9.5), 2, False), sample((0.0, 0.0, 9.8), 7)]))
    check("sync after two samples", daemon.sync(), True)
    _, kind, status, items = daemon.call(POLL, "i:16")
    events = events_of(items)
    check("queued samples return at once", (kind, len(events)), ("reply", 2))
    check("unpacked floats", struct.unpack_from("<fffb", events[0][3]), (0.25, -0.5, 9.5, 2))
    check("status out of range is unreliable", struct.unpack_from("<b", events[1][3], 12)[0], 0)
    check("stamps increase", events[0][0] > stamp and events[1][0] > events[0][0], True)

    daemon.ssc(0, *SERVER, report(ACCEL, [sample((1.0, 1.0, 1.0)) for _ in range(3)]))
    check("sync after three samples", daemon.sync(), True)
    _, kind, status, items = daemon.call(POLL, "i:2")
    check("poll honours max count", len(events_of(items)), 2)
    _, kind, status, items = daemon.call(POLL, "i:2")
    check("rest on the next poll", len(events_of(items)), 1)

    first, kind, _, _ = daemon.call(POLL, "i:16")
    check("first poll blocks", kind, "blocked")
    second, kind, _, _ = daemon.call(POLL, "i:16")
    status, items = daemon.complete(first)
    check("a second poll releases the first empty", (status, len(events_of(items)), result_of(items)), (0, 0, [0, OK]))
    check("second poll blocks", kind, "blocked")

    daemon.ssc(0, 5, 99, report(ACCEL, [sample((3.0, 3.0, 3.0))]))
    daemon.ssc(1, *SERVER, report(ACCEL, [sample((3.0, 3.0, 3.0))]))
    check("sync after foreign datagrams", daemon.sync(), True)
    check("foreign port and the other stream are ignored", daemon.take("complete %d " % second), [])

    _, kind, status, items = daemon.call(ACTIVATE, "i:2", "b:1")
    check("activate light", result_of(items), [0, OK])
    check("light on change", daemon.sent(1), SERVER + (on_change(2, LIGHT),))
    daemon.ssc(1, *SERVER, report(LIGHT, [sample((5.33, 60.0)), sample((5.33, 61.0)), sample((5.40, 60.0))]))
    status, items = daemon.complete(second)
    events = events_of(items)
    check("light events only on change", [(e[1], e[2]) for e in events], [(2, 5), (2, 5)])
    near("light lux first", struct.unpack_from("<f", events[0][3])[0], 5.33)
    near("light lux second", struct.unpack_from("<f", events[1][3])[0], 5.40)

    _, _, _, items = daemon.call(BATCH, "i:2", "l:5", "l:0")
    check("batch light keeps the stream", (result_of(items), daemon.take("sent 1 ")), ([0, OK], []))
    _, _, _, items = daemon.call(ACTIVATE, "i:2", "b:0")
    check("light off", daemon.sent(1), SERVER + (disable(3, LIGHT),))
    _, _, _, items = daemon.call(ACTIVATE, "i:2", "b:1")
    check("light on again", daemon.sent(1), SERVER + (on_change(4, LIGHT),))
    daemon.ssc(1, *SERVER, report(LIGHT, [sample((5.40, 60.0))]))
    check("sync after the same lux", daemon.sync(), True)
    _, kind, _, items = daemon.call(POLL, "i:16")
    check("the first lux after activation goes through", (kind, len(events_of(items))), ("reply", 1))

    _, _, _, items = daemon.call(BATCH, "i:1", "l:10000000", "l:0")
    check("rate change disables", daemon.sent(0), SERVER + (disable(3, ACCEL),))
    check("rate change enables at 100 Hz", daemon.sent(0), SERVER + (enable(4, ACCEL, 100.0),))
    _, _, _, items = daemon.call(BATCH, "i:1", "l:1000", "l:0")
    check("too fast clamps to 100 Hz", daemon.take("sent 0 "), [])
    _, _, _, items = daemon.call(BATCH, "i:1", "l:5000000000", "l:0")
    check("too slow disables", daemon.sent(0), SERVER + (disable(5, ACCEL),))
    check("too slow clamps to 1 Hz", daemon.sent(0), SERVER + (enable(6, ACCEL, 1.0),))
    _, _, _, items = daemon.call(BATCH, "i:1", "l:20000000", "l:0")
    daemon.sent(0)
    check("back to 50 Hz", daemon.sent(0), SERVER + (enable(8, ACCEL, 50.0),))

    _, _, _, items = daemon.call(FLUSH, "i:2")
    check("flush active light", result_of(items), [0, OK])
    _, _, _, items = daemon.call(POLL, "i:16")
    meta = events_of(items)
    check("flush complete event", [(e[1], e[2], struct.unpack_from("<I", e[3])[0]) for e in meta], [(2, 0, 1)])
    _, _, _, items = daemon.call(ACTIVATE, "i:2", "b:0")
    daemon.sent(1)
    _, _, _, items = daemon.call(FLUSH, "i:2")
    check("flush inactive is bad value", result_of(items), [0, BAD_VALUE])
    _, _, _, items = daemon.call(FLUSH, "i:7")
    check("flush unknown is bad value", result_of(items), [0, BAD_VALUE])
    _, _, _, items = daemon.call(ACTIVATE, "i:9", "b:1")
    check("activate unknown is bad value", result_of(items), [0, BAD_VALUE])
    _, _, _, items = daemon.call(ACTIVATE, "i:0", "b:1")
    check("handle 0 is bad value", result_of(items), [0, BAD_VALUE])
    _, _, _, items = daemon.call(BATCH, "i:1", "l:-1", "l:0")
    check("negative period is bad value", result_of(items), [0, BAD_VALUE])
    _, _, _, items = daemon.call(SET_OPERATION_MODE, "i:0")
    check("normal mode", result_of(items), [0, OK])
    _, _, _, items = daemon.call(SET_OPERATION_MODE, "i:1")
    check("data injection mode refused", result_of(items), [0, INVALID_OPERATION])
    _, _, _, items = daemon.call(INJECT)
    check("inject refused", result_of(items), [0, INVALID_OPERATION])
    _, _, _, items = daemon.call(REGISTER)
    check("direct channel refused", result_of(items), [0, INVALID_OPERATION, -1])
    _, _, _, items = daemon.call(UNREGISTER, "i:1")
    check("unregister refused", result_of(items), [0, INVALID_OPERATION])
    _, _, _, items = daemon.call(CONFIG, "i:1", "i:1", "i:1")
    check("direct report refused", result_of(items), [0, INVALID_OPERATION, -1])
    _, kind, status, _ = daemon.call(ACTIVATE, "i:1")
    check("short request", (kind, status), ("status", EINVAL))
    _, kind, status, _ = daemon.call(99)
    check("unknown call", (kind, status), ("status", EBADMSG))
    _, kind, status, _ = daemon.call(GET_SENSORS_LIST, iface="android.hidl.base@1.0::IBase")
    check("other interface", (kind, status), ("status", EBADMSG))

    daemon.proc.send_signal(signal.SIGUSR1)
    time.sleep(0.2)
    daemon.ssc(0, *SERVER, report(ACCEL, [sample((7.0, 7.0, 7.0))]))
    check("sync in test input", daemon.sync(), True)
    events = drain(daemon)
    check("test input events", len(events) >= 5, True)
    check("test input turn 1", {struct.unpack_from("<fff", e[3]) for e in events},
          {struct.unpack("<fff", struct.pack("<fff", GRAVITY, 0.0, 0.0))})
    daemon.proc.send_signal(signal.SIGUSR1)
    time.sleep(0.2)
    events = drain(daemon)
    check("test input turn 2", struct.unpack_from("<fff", events[-1][3]) if events else None,
          struct.unpack("<fff", struct.pack("<fff", 0.0, -GRAVITY, 0.0)))
    daemon.proc.send_signal(signal.SIGUSR2)
    time.sleep(0.2)
    drain(daemon)
    time.sleep(0.1)
    ident, kind, _, _ = daemon.call(POLL, "i:64")
    check("test input stopped", kind, "blocked")
    daemon.ssc(0, *SERVER, report(ACCEL, [sample((1.0, 2.0, 3.0))]))
    status, items = daemon.complete(ident)
    check("sensor hub again after test input", [struct.unpack_from("<fff", e[3]) for e in events_of(items)],
          [(2.0, -1.0, 3.0)])

    daemon.ssc(0, *SERVER, response(9, 1, 2))
    daemon.ssc(0, *SERVER, report(ACCEL, [event(130, uint(1, 7))]))
    daemon.ssc(0, 1, CTRL, server(5, *SERVER))
    check("sync after hub loss", daemon.sync(), True)
    daemon.ssc(0, 1, CTRL, server(4, 5, 22))
    check("hub back asks for the suid again", daemon.sent(0), (5, 22, suid_request(9, "accel")))
    daemon.ssc(0, 5, 22, report(LOOKUP, [suid_event("accel", [ACCEL])]))
    check("hub back re-enables the active accel", daemon.sent(0), (5, 22, enable(10, ACCEL, 50.0)))
    daemon.ssc(1, 1, CTRL, server(5, *SERVER))
    daemon.ssc(1, 1, CTRL, server(4, *SERVER))
    check("light hub back", daemon.sent(1), SERVER + (suid_request(6, "ambient_light"),))
    daemon.ssc(1, *SERVER, report(LOOKUP, [suid_event("ambient_light", [])]))
    check("sync after an empty suid answer", daemon.sync(), True)

    _, _, _, items = daemon.call(ACTIVATE, "i:1", "b:0")
    check("accel off", daemon.sent(0), (5, 22, disable(11, ACCEL)))

    _, kind, status, _ = daemon.call(ACTIVATE, "i:1", "b:1", "u:10050")
    check("an app uid is refused", (kind, status), ("status", -1))
    _, kind, status, _ = daemon.call(POLL, "i:16", "u:0")
    check("root is refused", (kind, status), ("status", -1))
    check("sync after refusals", daemon.sync(), True)
    check("a refused call changes nothing", daemon.take("sent "), [])

    _, _, _, items = daemon.call(ACTIVATE, "i:1", "b:1")
    check("accel on before the loss", daemon.sent(0), (5, 22, enable(12, ACCEL, 50.0)))
    pending, kind, _, _ = daemon.call(POLL, "i:16")
    check("poll pending before the loss", kind, "blocked")
    daemon.send("present 0")
    check("the loss turns the accel stream off", daemon.sent(0), (5, 22, disable(13, ACCEL)))
    status, items = daemon.complete(pending)
    check("the loss releases the pending poll", (status, len(events_of(items))), (0, 0))
    try:
        code = daemon.proc.wait(5)
    except subprocess.TimeoutExpired:
        code = None
    check("exits 0 after the loss", code, 0)
    log = daemon.stderr()
    for line in ("waydroid-sensord: android.hardware.sensors@1.0::ISensors/default added on /dev/hwbinder",
                 "waydroid-sensord: accel: sensor hub at 5:21",
                 "waydroid-sensord: accel: suid 99aabbccddeeff001122334455667788",
                 "waydroid-sensord: accel: on at 50 Hz",
                 "waydroid-sensord: ambient_light: on, reports on change",
                 "waydroid-sensord: ambient_light: off",
                 "waydroid-sensord: test input: turn 1",
                 "waydroid-sensord: test input: turn 2",
                 "waydroid-sensord: test input off",
                 "waydroid-sensord: accel: request 9 returned 1/2",
                 "waydroid-sensord: accel: error event 7",
                 "waydroid-sensord: accel: sensor hub at 5:21 is gone",
                 "waydroid-sensord: ambient_light: the sensor hub lists none",
                 "waydroid-sensord: refused call 3 from uid 10050",
                 "waydroid-sensord: refused call 4 from uid 0",
                 "waydroid-sensord: the service manager on /dev/hwbinder is gone, exiting"):
        check("log %s" % line, line in log.splitlines(), True)


def add_fails(binary):
    daemon = Daemon(binary)
    startup(daemon)
    daemon.send("addstatus -1")
    daemon.send("present 1")
    try:
        code = daemon.proc.wait(5)
    except subprocess.TimeoutExpired:
        code = None
    check("exits 1 when the add fails", code, 1)
    check("add failure logged",
          "waydroid-sensord: adding android.hardware.sensors@1.0::ISensors/default on /dev/hwbinder returned -1"
          in daemon.stderr().splitlines(), True)
    daemon.stop()


def add_unlisted(binary):
    daemon = Daemon(binary)
    startup(daemon)
    daemon.send("unlisted")
    daemon.send("present 1")
    try:
        code = daemon.proc.wait(5)
    except subprocess.TimeoutExpired:
        code = None
    check("exits 1 when the service is not listed after the add", code, 1)
    check("unlisted add logged",
          "waydroid-sensord: adding android.hardware.sensors@1.0::ISensors/default on /dev/hwbinder returned 0, "
          "not listed" in daemon.stderr().splitlines(), True)
    daemon.stop()


def presence_twice(binary):
    daemon = Daemon(binary)
    startup(daemon)
    daemon.send("present 1")
    daemon.expect(lambda t: t.startswith("add "))
    daemon.send("present 1")
    check("sync after a second presence", daemon.sync(), True)
    check("one add only", daemon.take("add "), [])
    check("still running", daemon.proc.poll(), None)
    check("sigterm exits 0", daemon.stop(), 0)


def no_qrtr(binary):
    daemon = Daemon(binary, {"FAKE_NOQRTR": "1"})
    check("no qrtr manager", daemon.expect(lambda t: t.startswith("manager ")) is not None, True)
    check("no qrtr sync", daemon.sync(), True)
    check("no qrtr sockets", daemon.take("socket "), [])
    daemon.send("present 1")
    check("no qrtr still adds", daemon.expect(lambda t: t.startswith("add ")), "add default object")
    _, kind, _, items = daemon.call(GET_SENSORS_LIST)
    check("no qrtr still lists both sensors", vectors(items)[0][2] if kind == "reply" else None, 2)
    _, _, _, items = daemon.call(ACTIVATE, "i:1", "b:1")
    check("no qrtr activate ok", result_of(items), [0, OK])
    daemon.stop()
    log = daemon.stderr().splitlines()
    check("no qrtr logged", "waydroid-sensord: accel: no QRTR socket: Address family not supported by protocol" in log,
          True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    args = parser.parse_args()
    for run in (main_run, add_fails, add_unlisted, presence_twice, no_qrtr):
        run(args.binary)
    print("sensortest %s: %d failed" % ("FAIL" if failures else "PASS", len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
