#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
relay=$tree/usr/libexec/microos/microos-mdns-relay
for c in ip setpriv unshare python3; do
  command -v "$c" > /dev/null || { echo "FAIL: $c missing, the relay test needs it" >&2; exit 1; }
done
err=$(unshare --user --map-root-user true 2>&1) || { echo "FAIL: setup step user namespace: $err" >&2; exit 1; }
err=$(unshare --user --map-root-user --net ip link add t0 type veth peer name t1 2>&1) ||
  { echo "FAIL: setup step veth pair in a user owned network namespace: $err" >&2; exit 1; }

exec unshare --user --map-root-user --net python3 - "$relay" <<'PY'
import os
import select
import signal
import socket
import struct
import subprocess
import sys
import time

RELAY = sys.argv[1]
ME = "microos-mdns-relay"
GROUP, PORT = "224.0.0.251", 5353
HOST, PEER, FAR = "198.51.100.1", "198.51.100.2", "203.0.113.9"
BRIDGE, GUEST = "192.168.240.1", "192.168.240.112"
QUIET_S = 0.3
failed = []


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr, flush=True)
    failed.append(message)


def expect(got, want, what):
    if got != want:
        fail(f"{what}: {got!r}, not {want!r}")


def netns():
    ready_r, ready_w = os.pipe()
    hold_r, hold_w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(ready_r)
        os.close(hold_w)
        os.unshare(os.CLONE_NEWNET)
        os.write(ready_w, b"1")
        os.read(hold_r, 1)
        os._exit(0)
    os.close(ready_w)
    os.close(hold_r)
    os.read(ready_r, 1)
    os.close(ready_r)
    return pid, hold_w


def inside(pid, make):
    fd = os.open(f"/proc/{pid}/ns/net", os.O_RDONLY)
    try:
        os.setns(fd, os.CLONE_NEWNET)
        return make()
    finally:
        os.close(fd)
        os.setns(home, os.CLONE_NEWNET)


def ip(*args):
    done = subprocess.run(["ip", *args], capture_output=True, text=True)
    if done.returncode:
        print(f"FAIL: setup step ip {' '.join(args)}: {done.stderr.strip()}", file=sys.stderr, flush=True)
        sys.exit(1)


def mreqn(index, group="0.0.0.0"):
    return struct.pack("=4s4si", socket.inet_aton(group), bytes(4), index)


def udp():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    return sock


def peer(ifname, addr):
    ip("addr", "add", f"{addr}/24", "dev", ifname)
    ip("link", "set", ifname, "up")
    index = socket.if_nametoindex(ifname)
    rx = udp()
    rx.bind((GROUP, PORT))
    rx.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreqn(index, GROUP))
    tx = udp()
    tx.bind((addr, PORT))
    tx.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, mreqn(index))
    tx.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
    tx.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
    return rx, tx


def far():
    ip("addr", "add", f"{FAR}/32", "dev", "lan1")
    sock = udp()
    sock.bind((FAR, PORT))
    return sock


def recv(sock, timeout=5.0):
    if not select.select([sock], [], [], timeout)[0]:
        return None, None
    return sock.recvfrom(9000)


def quiet(sock, what):
    data, source = recv(sock, QUIET_S)
    if data is not None:
        fail(f"{what} got {data!r} from {source}")


def caps(pid):
    with open(f"/proc/{pid}/status") as f:
        status = dict(line.split(":", 1) for line in f.read().splitlines() if ":" in line)
    got = {key: status.get(key, "").strip() for key in ("CapPrm", "CapEff", "CapBnd", "NoNewPrivs")}
    expect(got, {"CapPrm": "0" * 16, "CapEff": "0" * 16, "CapBnd": "0" * 16, "NoNewPrivs": "1"}, "relay privileges")


class Relay:
    def __init__(self):
        cmd = ["setpriv", "--bounding-set=-all", "--inh-caps=-all", "--no-new-privs", RELAY, "lan0", "gst0"]
        self.proc = subprocess.Popen(cmd, stderr=subprocess.PIPE)
        self.fd, self.buf = self.proc.stderr.fileno(), b""

    def line(self):
        end = time.monotonic() + 5
        while b"\n" not in self.buf:
            left = end - time.monotonic()
            if left <= 0 or not select.select([self.fd], [], [], left)[0]:
                return None
            chunk = os.read(self.fd, 4096)
            if not chunk:
                return None
            self.buf += chunk
        text, self.buf = self.buf.split(b"\n", 1)
        return text.decode()

    def end(self):
        try:
            rc = self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            rc = self.proc.wait()
        while chunk := os.read(self.fd, 4096):
            self.buf += chunk
        return rc, self.buf.decode()


def name(text):
    return b"".join(bytes([len(label)]) + label.encode() for label in text.split(".")) + b"\0"


def header(ident, flags, qd, an, ns, ar):
    return struct.pack(">HHHHHH", ident, flags, qd, an, ns, ar)


def question(owner, kind, qclass):
    return owner + struct.pack(">HH", kind, qclass)


def record(owner, kind, rdata):
    return owner + struct.pack(">HHIH", kind, 1, 120, len(rdata)) + rdata


SERVICE = name("_googlecast._tcp.local")
INSTANCE = name("Chromecast-test._googlecast._tcp.local")
TARGET = name("chromecast-test.local")
ANDROID = name("android.local")
POINTER = struct.pack(">H", 0xC000 | 12)
PTR = record(SERVICE, 12, INSTANCE)
EXTRA = (record(INSTANCE, 33, struct.pack(">HHH", 0, 0, 8009) + TARGET) + record(INSTANCE, 16, b"\x05id=ab")
         + record(TARGET, 1, socket.inet_aton("198.51.100.50")))
GUEST_A = record(ANDROID, 1, socket.inet_aton(GUEST))
ASKED = header(0x1234, 0, 1, 0, 0, 0) + question(SERVICE, 12, 0x8001)
FORWARDED = header(0x1234, 0, 1, 0, 0, 0) + question(SERVICE, 12, 0x0001)
ANSWER = header(0, 0x8400, 0, 1, 0, 3) + PTR + EXTRA
KNOWN = (header(0x2345, 0x0200, 2, 1, 0, 1) + question(SERVICE, 12, 0x8001) + question(POINTER, 33, 0x8001)
         + PTR + GUEST_A)
STRIPPED = header(0x2345, 0, 2, 0, 0, 0) + question(SERVICE, 12, 0x0001) + question(POINTER, 33, 0x0001)
GUEST_ANSWER = header(0, 0x8400, 0, 1, 0, 0) + GUEST_A
PROBE = header(0, 0, 1, 0, 1, 0) + question(ANDROID, 255, 0x8001) + GUEST_A
LAN_QUERY = header(0, 0, 1, 0, 0, 0) + question(SERVICE, 12, 0x8001)
HOST_QUERIES = {"gst0": header(0x0A01, 0, 1, 0, 0, 0) + question(SERVICE, 12, 0x0001),
                "lan0": header(0x0A02, 0, 1, 0, 0, 0) + question(SERVICE, 12, 0x0001)}
DROPPED = {
    "a guest answer": GUEST_ANSWER,
    "a probe": PROBE,
    "a query with no question": header(0, 0, 0, 1, 0, 0) + PTR,
    "5 bytes": bytes(5),
    "a forward pointer": (header(0x0B01, 0, 1, 0, 0, 0) + question(struct.pack(">H", 0xC000 | 18), 12, 1)
                          + name("local")),
    "a self pointer": header(0x0B02, 0, 1, 0, 0, 0) + question(b"\x01a" + POINTER, 12, 1),
    "a pointer into the header": header(0x0B03, 0, 1, 0, 0, 0) + question(struct.pack(">H", 0xC000 | 2), 12, 1),
    "a truncated label": header(0x0B04, 0, 1, 0, 0, 0) + b"\x10abc",
    "a 0x80 label byte": header(0x0B05, 0, 1, 0, 0, 0) + question(b"\x80" + bytes(5), 12, 1),
    "an overstated QDCOUNT": header(0x0B06, 0, 2, 0, 0, 0) + question(SERVICE, 12, 0x8001),
    "a non-zero OPCODE": header(0x0B07, 0x2000, 1, 0, 0, 0) + question(SERVICE, 12, 0x8001),
    "a non-zero RCODE": header(0x0B08, 0x0003, 1, 0, 0, 0) + question(SERVICE, 12, 0x8001),
    "a 257 byte name": header(0x0B09, 0, 1, 0, 0, 0) + question(name(".".join(["a" * 63] * 4)), 12, 0x8001),
}
MARKER = header(0x5678, 0, 1, 0, 0, 0) + question(SERVICE, 12, 0x8001)
MARKER_FORWARDED = header(0x5678, 0, 1, 0, 0, 0) + question(SERVICE, 12, 0x0001)
UNICAST = {
    "lan": header(0x0101, 0x8400, 0, 1, 0, 0) + PTR,
    "far": header(0x0303, 0x8400, 0, 1, 0, 0) + PTR,
    "guest": header(0x0202, 0, 1, 0, 0, 0) + question(SERVICE, 12, 0x0001),
}


def unicast():
    lan_tx.sendto(UNICAST["lan"], (HOST, PORT))
    far_tx.sendto(UNICAST["far"], (HOST, PORT))
    guest_tx.sendto(UNICAST["guest"], (BRIDGE, PORT))


def sockets():
    with open("/proc/net/udp") as f:
        return sorted(line.split()[1] for line in f.read().splitlines()[1:])


lan_ns, lan_hold = netns()
guest_ns, guest_hold = netns()
home = os.open("/proc/self/ns/net", os.O_RDONLY)
relay = None
try:
    ip("link", "add", "gst0", "type", "veth", "peer", "name", "gst1", "netns", str(guest_ns))
    ip("link", "set", "gst0", "up")
    guest_rx, guest_tx = inside(guest_ns, lambda: peer("gst1", GUEST))

    relay = Relay()
    expect(relay.line(), f"{ME}: waiting for lan0", "relay before lan0 exists")
    ip("link", "add", "lan0", "type", "veth", "peer", "name", "lan1", "netns", str(lan_ns))
    ip("addr", "add", f"{HOST}/24", "dev", "lan0")
    ip("link", "set", "lan0", "up")
    ip("route", "add", f"{FAR}/32", "dev", "lan0")
    lan_rx, lan_tx = inside(lan_ns, lambda: peer("lan1", PEER))
    far_tx = inside(lan_ns, far)
    expect(relay.line(), f"{ME}: waiting for an IPv4 address on gst0", "relay before gst0 has an address")
    ip("addr", "add", f"{BRIDGE}/24", "dev", "gst0")
    lan_index, guest_index = socket.if_nametoindex("lan0"), socket.if_nametoindex("gst0")
    started = f"{ME}: relaying between lan0 ({lan_index}) at {HOST} and gst0 ({guest_index}) at {BRIDGE}"
    expect(relay.line(), started, "relay start")
    caps(relay.proc.pid)
    expect(sockets(), ["FB0000E0:14E9", "FB0000E0:14E9"], "UDP sockets in the host namespace")

    guest_tx.sendto(ASKED, (GROUP, PORT))
    expect(recv(lan_rx), (FORWARDED, (HOST, PORT)), "the guest's QU query on the LAN")
    quiet(guest_rx, "the guest after its query")
    lan_tx.sendto(ANSWER, (GROUP, PORT))
    expect(recv(guest_rx), (ANSWER, (BRIDGE, PORT)), "the LAN's multicast answer in the guest")
    quiet(lan_rx, "the LAN after its answer")
    lan_tx.sendto(LAN_QUERY, (GROUP, PORT))
    expect(recv(guest_rx), (LAN_QUERY, (BRIDGE, PORT)), "the LAN's query in the guest")
    quiet(lan_rx, "the LAN after its query")

    guest_tx.sendto(KNOWN, (GROUP, PORT))
    expect(recv(lan_rx), (STRIPPED, (HOST, PORT)), "the guest's known answer query on the LAN")
    quiet(guest_rx, "the guest after its known answer query")

    unicast()
    quiet(guest_rx, "the guest after unicast to the host with no other 5353 socket")
    quiet(lan_rx, "the LAN after unicast to the host with no other 5353 socket")
    bystander = udp()
    bystander.bind(("0.0.0.0", PORT))
    unicast()
    got = {recv(bystander) for _ in UNICAST}
    want = {(UNICAST["lan"], (PEER, PORT)), (UNICAST["far"], (FAR, PORT)), (UNICAST["guest"], (GUEST, PORT))}
    expect(got, want, "unicast to the host at 0.0.0.0:5353")
    quiet(guest_rx, "the guest after unicast to the host")
    quiet(lan_rx, "the LAN after unicast to the host")
    bystander.close()

    for ifname, index, rx, other in (("gst0", guest_index, guest_rx, lan_rx), ("lan0", lan_index, lan_rx, guest_rx)):
        host_tx = udp()
        host_tx.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, mreqn(index))
        host_tx.sendto(HOST_QUERIES[ifname], (GROUP, PORT))
        expect(recv(rx)[0], HOST_QUERIES[ifname], f"a host query out {ifname}")
        quiet(other, f"the other side after a host query out {ifname}")
        host_tx.close()

    for packet in (*DROPPED.values(), MARKER):
        guest_tx.sendto(packet, (GROUP, PORT))
    expect(recv(lan_rx), (MARKER_FORWARDED, (HOST, PORT)), f"the LAN after {', '.join(DROPPED)}")
    quiet(guest_rx, "the guest after its marker query")

    relay.proc.send_signal(signal.SIGTERM)
    expect(relay.end(), (0, ""), "relay on SIGTERM")

    relay = Relay()
    expect(relay.line(), started, "relay restart")
    ip("addr", "del", f"{HOST}/24", "dev", "lan0")
    guest_tx.sendto(ASKED, (GROUP, PORT))
    quiet(lan_rx, "the LAN while lan0 has no IPv4 address")
    ip("addr", "add", f"{HOST}/24", "dev", "lan0")
    guest_tx.sendto(ASKED, (GROUP, PORT))
    expect(recv(lan_rx), (FORWARDED, (HOST, PORT)), "the guest's query once lan0 has its address back")
    quiet(guest_rx, "the guest after its query")

    ip("link", "del", "lan0")
    expect(relay.line(), f"{ME}: lan0 is gone, waiting for lan0", "relay after lan0 went")
    expect(relay.proc.poll(), None, "relay exit status after lan0 went")
    lan_rx.close()
    lan_tx.close()
    ip("link", "add", "lan0", "type", "veth", "peer", "name", "lan1", "netns", str(lan_ns))
    ip("addr", "add", f"{HOST}/24", "dev", "lan0")
    ip("link", "set", "lan0", "up")
    lan_rx, lan_tx = inside(lan_ns, lambda: peer("lan1", PEER))
    got = relay.line() or ""
    back = f"{ME}: relaying between lan0 ({socket.if_nametoindex('lan0')}) at "
    if not got.startswith(back) or not got.endswith(f" and gst0 ({guest_index}) at {BRIDGE}"):
        fail(f"relay after lan0 came back: {got!r}")
    guest_tx.sendto(ASKED, (GROUP, PORT))
    expect(recv(lan_rx), (FORWARDED, (HOST, PORT)), "the guest's query after lan0 came back")
    quiet(guest_rx, "the guest after its query")

    ip("link", "del", "gst0")
    expect(relay.end(), (0, f"{ME}: gst0 is gone\n"), "relay after gst0 went")
    relay = Relay()
    expect(relay.end(), (0, f"{ME}: gst0 is gone\n"), "relay started without gst0")
finally:
    if relay is not None and relay.proc.poll() is None:
        relay.proc.kill()
        relay.proc.wait()
    for pid, hold in ((guest_ns, guest_hold), (lan_ns, lan_hold)):
        os.close(hold)
        os.waitpid(pid, 0)

sys.exit(1 if failed else 0)
PY
