#!/usr/bin/env python3
import json
import os
import sys
import tempfile
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

here = os.path.dirname(os.path.abspath(__file__))
tree = os.environ.get("MICROOS_TREE", os.path.join(here, "..", "..", "system_files"))
sys.dont_write_bytecode = True
loader = SourceFileLoader("btr", os.path.join(tree, "usr/libexec/microos/microos-bt-reconnect"))
btr = module_from_spec(spec_from_loader("btr", loader))
loader.exec_module(btr)

HCI = btr.HCI
HEAD = HCI + "/dev_AA_AA_AA_AA_AA_01"
HEAD2 = HCI + "/dev_AA_AA_AA_AA_AA_02"
PHONE = HCI + "/dev_BB_BB_BB_BB_BB_01"
BOTH = HCI + "/dev_CC_CC_CC_CC_CC_01"
U = "-0000-1000-8000-00805f9b34fb"
HEADSET_UUIDS = ["0000110b" + U, "0000110e" + U, "0000111e" + U]
PHONE_UUIDS = ["0000110a" + U, "0000110c" + U, "0000110e" + U]
BOTH_UUIDS = ["0000110a" + U, "0000110b" + U, "0000110c" + U]
PAGE = ("org.bluez.Error.Failed", "br-connection-page-timeout")
TIMEOUT = "org.bluez.Reason.Timeout"
failures = []


def check(cond, what):
    if not cond:
        failures.append(what)
        print(f"FAIL: {what}", file=sys.stderr)


def near(a, b, tol=0.02):
    return a is not None and abs(a - b) <= tol


class T:
    def __init__(self, jitter=0.0, state=None, boot_id="boot-a", offset=1000.0, path=None):
        self.now = 0.0
        self.offset = offset
        self.dir = tempfile.mkdtemp()
        self.path = path or os.path.join(self.dir, "state.json")
        if state is not None:
            with open(self.path, "w") as f:
                json.dump(state, f)
        self.logs = []
        self.sent = []
        self.pending = []
        self.responder = lambda call: (5.12,) + PAGE
        self.e = btr.Engine(self.path, boot_id, lambda: self.now + self.offset, self.logs.append,
                            lambda top: jitter * top)

    def objects(self, devices, powered=True):
        objs = {HCI: {btr.ADAPTER: {"Powered": powered, "Discovering": False, "Discoverable": False}}}
        for path, uuids, connected in devices:
            objs[path] = {btr.DEVICE: {"UUIDs": uuids, "Connected": connected}}
        return objs

    def up(self, devices=((HEAD, HEADSET_UUIDS, False),), powered=True, start=True):
        self.e.owner(True, self.now)
        self.e.load(self.objects(devices, powered), self.now)
        if start:
            self.e.start(self.now)
        self.collect()

    def collect(self):
        for cid, path, method, args in self.e.calls:
            self.sent.append((self.now, method, path, args))
            r = self.responder((method, path, args))
            if r is not None:
                self.pending.append((self.now + r[0], cid, r[1], r[2]))
        self.e.calls.clear()

    def advance(self, by=None, to=None):
        until = to if to is not None else self.now + by
        for _ in range(100000):
            self.collect()
            w = self.e.wake()
            p = min(self.pending) if self.pending else None
            nxt = min(x for x in (w, p[0] if p else None) if x is not None) if (w is not None or p) else None
            if nxt is None or nxt > until:
                break
            self.now = max(self.now, nxt)
            if p is not None and p[0] <= self.now:
                self.pending.remove(p)
                self.e.reply(p[1], p[2], p[3], self.now)
            else:
                self.e.tick(self.now)
        self.collect()
        self.now = until

    def do(self, fn, *args):
        out = fn(*args, self.now)
        self.collect()
        return out

    def connects(self, path=HEAD, method="Connect"):
        return [t for t, m, p, _ in self.sent if m == method and p == path]

    def methods(self):
        return [m for _, m, _, _ in self.sent]

    def lost(self, path=HEAD, reason=TIMEOUT):
        self.do(self.e.disconnected, path, reason, "")

    def transport(self, path, device, uuid):
        self.do(self.e.added, path, {btr.TRANSPORT: {"Device": device, "UUID": uuid + U}})

    def unport(self, path):
        self.do(self.e.removed, path, [btr.TRANSPORT])

    def connected(self, path, on):
        self.do(self.e.changed, path, btr.DEVICE, {"Connected": on})

    def adapter(self, **props):
        self.do(self.e.changed, HCI, btr.ADAPTER, props)

    def state(self):
        with open(self.path) as f:
            return json.load(f)


def target_state(addr="AA:AA:AA:AA:AA:01", **extra):
    s = {"target": addr}
    s.update(extra)
    return s


def test_reasons():
    for reason in ("org.bluez.Reason.Timeout", "org.bluez.Reason.Unknown"):
        t = T(state=target_state())
        t.up()
        t.advance(by=60)
        n = len(t.connects())
        t.lost(HEAD, reason)
        t.advance(by=2)
        check(len(t.connects()) == n + 1, f"{reason} starts a loss run")
    for reason in ("org.bluez.Reason.Local", "org.bluez.Reason.Remote", "org.bluez.Reason.Authentication",
                   "org.bluez.Reason.Suspend"):
        t = T(state=target_state())
        t.up()
        t.advance(by=60)
        n = len(t.sent)
        t.lost(HEAD, reason)
        t.advance(by=1200)
        check(len(t.sent) == n, f"{reason} sends nothing")
    t = T(state=target_state())
    t.up(devices=((HEAD, HEADSET_UUIDS, False), (HEAD2, HEADSET_UUIDS, False)))
    t.advance(by=60)
    n = len(t.sent)
    t.lost(HEAD2)
    t.advance(by=1200)
    check(len(t.sent) == n, "a non target loss sends nothing")


def loss_run(jitter):
    t = T(jitter=jitter, state=target_state())
    t.up()
    t.advance(by=60)
    t.sent.clear()
    start = t.now
    t.lost()
    t.advance(by=1200)
    return t, [x - start for x in t.connects()]


def test_loss_schedule():
    for jitter in (0.0, 1.0):
        t, at = loss_run(jitter)
        check([round(x, 2) for x in at[:4]] == [1.0, 8.12, 17.24, 30.36], f"loss phase A at {at[:4]}")
        b_gap = at[4] - (at[3] + 5.12)
        check(near(b_gap, 30 + 5 * jitter), f"loss phase B gap {b_gap} with jitter {jitter}")
        gaps = [at[i + 1] - (at[i] + 5.12) for i in range(len(at) - 1)]
        b = [g for i, g in enumerate(gaps) if at[i + 1] < 300]
        c = [g for i, g in enumerate(gaps) if at[i + 1] >= 300 + 5.12 + 35]
        check(all(29.99 <= g <= 35.01 for g in b[3:]), f"phase B gaps {b[3:]}")
        check(c and all(119.99 <= g <= 140.01 for g in c), f"phase C gaps {c}")
        check(at[-1] <= 900, f"last loss attempt at {at[-1]}")
        check(near(c[0], 120 + 20 * jitter), f"phase C gap {c[0]} with jitter {jitter}")
        check(t.e.run is None, "loss run ended after 15 min")


def boot_run(responder=None, transport=False):
    t = T(state=target_state())
    if responder:
        t.responder = responder
    t.up()
    t.advance(by=200)
    return t, t.connects()


def test_boot_schedule():
    t, at = boot_run()
    check([round(x, 2) for x in at] == [0.0, 6.12, 13.24, 22.36, 35.48], f"boot run at {at}")
    t, at = boot_run(lambda c: (1.0, "org.bluez.Error.Failed", "br-connection-refused"))
    check([round(x, 2) for x in at] == [0.0, 2.0, 5.0, 10.0, 19.0], f"boot run with refused replies at {at}")
    t, at = boot_run(lambda c: (1.0, None, None))
    check([round(x, 2) for x in at] == [0.0, 12.0, 25.0, 40.0, 59.0], f"boot run with ok and no transport at {at}")


def test_one_call():
    t = T(state=target_state())
    t.responder = lambda c: None
    t.up()
    t.advance(by=29.9)
    check(len(t.sent) == 1, "one boot call before its reply")
    t.e.want("w", t.now)
    t.collect()
    t.lost()
    t.advance(by=0.09)
    check(len(t.sent) == 1, "no second call through 30 s without a reply")
    cid = t.e.inflight["id"]
    t.do(t.e.reply, cid, btr.NOREPLY, "timed out")
    t.advance(by=10)
    check(len(t.sent) == 2 and near(t.sent[1][0] - t.now, -8.0, 0.05), f"NoReply then the next gap: {t.sent}")


def reply_case(error, message, kind="loss", powered=True):
    t = T(state=target_state())
    seq = [(1.0, error, message)]
    t.responder = lambda c: seq.pop(0) if seq else (1.0,) + PAGE
    t.up(start=False)
    if not powered:
        t.e.powered = powered
    t.e.start(t.now)
    t.collect()
    if kind == "loss":
        t.advance(by=1)
        t.lost()
    t.advance(by=60)
    return t


def test_replies():
    for err, msg in [(None, "br-connection-page-timeout"), (None, "br-connection-timeout"),
                     (None, "br-connection-sdp-search"), (None, "br-connection-canceled"), (btr.NOREPLY, "x")]:
        t = reply_case(err or "org.bluez.Error.Failed", msg)
        c = t.connects()
        check(len(c) >= 3 and near(c[2] - c[1], 3.0), f"{msg} next gap: {c}")
    for err, msg in [("org.bluez.Error.InProgress", ""), ("org.bluez.Error.Failed", "br-connection-busy"),
                     ("org.bluez.Error.AlreadyConnected", ""),
                     ("org.bluez.Error.Failed", "br-connection-already-connected"),
                     ("org.bluez.Error.NotReady", "")]:
        t = T(state=target_state())
        seq = [(1.0, err, msg)] * 4
        t.responder = lambda c: seq.pop(0) if seq else (1.0,) + PAGE
        t.up()
        t.advance(by=40)
        rel = [round(x, 2) for x in t.connects()[:5]]
        check(rel == [0.0, 3.0, 6.0, 9.0, 11.0], f"{err} {msg} busy retries 2 s, at most 3: {rel}")
    for msg in ("br-connection-refused", "br-connection-aborted-by-remote"):
        t = T(state=target_state())
        t.up()
        t.advance(by=60)
        seq = [(1.0, "org.bluez.Error.Failed", msg)]
        t.responder = lambda c: seq.pop(0) if seq else (1.0,) + PAGE
        t.lost()
        t.advance(by=200)
        c = t.connects()[-2:]
        check(t.e.run is not None and t.e.run.phase == "c" and near(c[1] - c[0] - 1.0, 120.0),
              f"{msg} goes to phase C: {c}")
    for err, msg in [("org.bluez.Error.ProfileUnavailable", ""), ("org.bluez.Error.Failed", "br-connection-key-missing")]:
        t = T(state=target_state())
        seq = [(1.0, err, msg)]
        t.responder = lambda c: seq.pop(0) if seq else (1.0,) + PAGE
        t.up()
        t.advance(by=100)
        check(len(t.connects()) == 1 and t.e.run is None, f"{err} {msg} stops the boot run")
        t.lost()
        seq.append((1.0, err, msg))
        t.advance(by=100)
        check(len(t.connects()) == 2 and t.e.run is None, f"{err} {msg} stops the loss run")
    t = T(state=target_state())
    seq = [(1.0, "org.bluez.Error.NotReady", "")]
    t.responder = lambda c: seq.pop(0) if seq else (1.0,) + PAGE
    t.up()
    t.e.powered = False
    t.advance(by=30)
    check(len(t.connects()) == 1 and t.e.run is None, "NotReady with Powered false stops")
    t = T(state=target_state())
    seq = [(1.0, "org.bluez.Error.Failed", "br-connection-whatever")]
    t.responder = lambda c: seq.pop(0) if seq else (1.0,) + PAGE
    t.up()
    t.advance(by=10)
    c = t.connects()
    check(len(c) >= 2 and near(c[1], 2.0), f"an unknown reply takes the next boot gap: {c}")
    check(any("br-connection-whatever" in line for line in t.logs), "an unknown reply is logged")


def test_unknown_bond():
    def acl():
        t.connected(HEAD, True)
        t.connected(HEAD, False)

    unknown = (1.0, "org.bluez.Error.Failed", "br-connection-unknown")
    t = T(state=target_state())
    t.up()
    t.advance(by=60)
    t.responder = lambda c: unknown
    t.lost()
    for step in (1.0, 3.0, 5.0):
        t.advance(by=step)
        acl()
    t.advance(by=60)
    bond = [line for line in t.logs if "likely lost bond" in line]
    check(len(bond) == 1, f"one lost bond line after 3 unknowns with an ACL: {bond}")
    t = T(state=target_state())
    t.up()
    t.advance(by=60)
    t.responder = lambda c: unknown
    t.lost()
    t.advance(by=60)
    check(not any("likely lost bond" in line for line in t.logs), "no lost bond line without an ACL")
    t = T(state=target_state())
    t.up()
    t.advance(by=60)
    seq = [unknown, unknown, (1.0,) + PAGE]
    t.responder = lambda c: seq.pop(0) if seq else unknown
    t.lost()
    for step in (1.0, 3.0, 5.0, 9.0, 4.0):
        t.advance(by=step)
        acl()
    t.advance(by=2)
    check(len(t.connects()) >= 5, f"reset case attempts: {t.connects()}")
    check(not any("likely lost bond" in line for line in t.logs), "another class resets the unknown count")


def test_second_loss():
    t = T(state=target_state())
    t.up()
    t.advance(by=60)
    t.sent.clear()
    start = t.now
    t.lost()
    t.advance(by=30)
    t.lost()
    t.advance(by=1200)
    at = [x - start for x in t.connects()]
    check([round(x, 2) for x in at[:4]] == [1.0, 8.12, 17.24, 30.36], f"second loss keeps the schedule: {at[:5]}")
    check(at[-1] <= 900, f"second loss keeps the 15 min end: {at[-1]}")
    t = T(state=target_state())
    t.responder = lambda c: (5.12,) + PAGE
    t.up()
    t.advance(by=2)
    t.lost()
    t.advance(by=3.0)
    check(len(t.connects()) == 1, "no call before the boot call's reply")
    t.advance(by=20)
    at = t.connects()
    check(t.e.run.kind == "loss" and near(at[1], 5.12 + 2.0), f"boot turns into a loss run: {at}")


def test_audio_up():
    t = T(state=target_state())
    t.responder = lambda c: (1.0, None, None)
    t.up()
    t.transport(HEAD + "/sep1/fd0", HEAD, "0000110a")
    t.advance(by=1.0)
    check(t.e.run is None and any("done" in line for line in t.logs), "transport before the ok: done")
    t = T(state=target_state())
    t.responder = lambda c: (1.0, None, None)
    t.up()
    t.advance(by=5)
    t.transport(HEAD + "/sep1/fd0", HEAD, "0000110a")
    check(t.e.run is None, "ok then a transport within 10 s: done")
    t = T(state=target_state())
    t.responder = lambda c: (1.0, None, None)
    t.up()
    t.advance(by=0.5)
    t.transport(HEAD + "/sep1/fd0", HEAD, "0000110a")
    run_after = t.e.run
    t.unport(HEAD + "/sep1/fd0")
    check(run_after is None, "a target transport added in the run ends it")
    t = T(state=target_state())
    t.responder = lambda c: (1.0, None, None)
    t.up()
    t.advance(by=1.0)
    t.connected(HEAD, True)
    t.advance(by=10.5)
    check(t.e.run is not None and t.e.run.kind == "boot" and t.e.run.step == 1, "Connected alone is not audio up")
    t = T(state=target_state())
    t.up()
    t.advance(by=60)
    t.responder = lambda c: (1.0, None, None)
    t.lost()
    t.advance(by=13)
    check(t.e.run is not None and t.e.run.phase == "c", "loss ok and no transport goes to phase C")
    t.transport(HEAD + "/sep1/fd0", HEAD, "0000110a")
    check(t.e.run is None, "a target transport later in the run: done")
    t = T(state=target_state())
    t.up()
    t.advance(by=60)
    t.responder = lambda c: (1.0, None, None)
    t.transport(HEAD + "/sep1/fd9", HEAD2, "0000110a")
    t.unport(HEAD + "/sep1/fd9")
    t.lost()
    t.advance(by=2.0)
    t.transport(HEAD2 + "/sep1/fd0", HEAD2, "0000110b")
    check(t.e.run is not None, "another device's transport does not end the run")


def test_role():
    t = T(state=target_state())
    t.up()
    check(t.e.role() == "headphones", "no claim acts headphones")
    t.advance(by=60)
    t.lost()
    t.advance(by=2)
    check(t.e.run is not None, "headphones run")
    t.do(t.e.set_role, "dap", "receiver")
    check(t.e.run is None, "a receiver claim stops the headset run")
    n = len(t.sent)
    t.do(t.e.want, "dap")
    t.advance(by=100)
    check(len(t.sent) == n, "a receiver claim blocks wants")
    t.do(t.e.client_gone, "dap")
    check(t.e.role() == "headphones", "claimer gone gives headphones")
    t.advance(by=1)
    check(len(t.sent) == n + 1, "the receiver claimer killed gives one boot attempt")
    t = T(state=target_state())
    t.up()
    t.advance(by=100)
    n = len(t.sent)
    t.do(t.e.set_role, "dap", "receiver")
    t.do(t.e.hold, "dap", True)
    t.do(t.e.set_role, "dap", "headphones")
    t.do(t.e.hold, "dap", False)
    t.advance(by=100)
    check(len(t.sent) == n, "Hold(false) after SetRole(headphones) sends no Connect")
    t.do(t.e.set_role, "dap", "receiver")
    t.do(t.e.set_role, "dap", "headphones")
    t.advance(by=100)
    check(len(t.sent) == n, "a live headphones claim after receiver sends no Connect")
    t.do(t.e.set_role, "a", "receiver")
    t.do(t.e.set_role, "b", "headphones")
    check(t.e.role() == "headphones", "two claimers, the latest wins")
    t.do(t.e.set_role, "a", "receiver")
    check(t.e.role() == "receiver", "two claimers, the latest SetRole wins")
    t.do(t.e.client_gone, "a")
    check(t.e.role() == "headphones", "the latest live claim wins")
    check(t.e.set_role("x", "speaker", t.now)[0] == btr.INVALID, "SetRole of a bad role refused")
    for n in ("c", "d"):
        t.do(t.e.set_role, n, "headphones")
    check(t.e.set_role("e", "headphones", t.now)[0] == btr.LIMITS, "a fifth claimer refused")


def test_retarget():
    t = T(state=target_state())
    t.up(devices=((HEAD, HEADSET_UUIDS, False), (HEAD2, HEADSET_UUIDS, True), (PHONE, PHONE_UUIDS, True)))
    t.advance(by=60)
    t.transport(HEAD2 + "/sep1/fd0", HEAD2, "0000110a")
    t.advance(by=9.9)
    check(t.e.target == HEAD, "retarget waits 10 s")
    t.advance(by=0.2)
    check(t.e.target == HEAD2 and t.e.role() == "headphones", "a headset transport for 10 s sets Target")
    check(t.state()["target"] == "AA:AA:AA:AA:AA:02", "Target persisted")
    t.transport(HEAD + "/sep1/fd1", HEAD, "0000110a")
    t.advance(by=0.5)
    t.unport(HEAD + "/sep1/fd1")
    t.advance(by=20)
    check(t.e.target == HEAD2, "a transport gone within 1 s changes nothing")
    t.do(t.e.set_role, "dap", "receiver")
    t.transport(PHONE + "/sep1/fd0", PHONE, "0000110b")
    t.advance(by=10.1)
    check(t.e.phone == PHONE and t.state()["phone"] == "BB:BB:BB:BB:BB:01", "a phone transport sets Phone")
    t.transport(HEAD + "/sep1/fd2", HEAD, "0000110a")
    t.advance(by=10.1)
    check(t.e.role() == "receiver" and t.e.target == HEAD, "a receiver claim keeps the role after a headset transport")


def test_late_connects():
    for why in ("headset", "hold", "role", "target"):
        t = T(state=target_state())
        t.up(devices=((HEAD, HEADSET_UUIDS, False), (HEAD2, HEADSET_UUIDS, False)))
        t.advance(by=60)
        t.responder = lambda c: (3.0, None, None) if c[0] == "Connect" else (0.1, None, None)
        t.lost()
        t.advance(by=1.5)
        if why == "headset":
            t.connected(HEAD2, True)
        elif why == "hold":
            t.do(t.e.hold, "dap", True)
        elif why == "role":
            t.do(t.e.set_role, "dap", "receiver")
        else:
            t.do(t.e.set_target, "dap", HEAD2)
        check(t.e.run is None, f"{why} stops the run")
        t.advance(by=10)
        d = t.connects(HEAD, "Disconnect")
        check(len(d) == 1, f"a late ok after {why} gives one Disconnect: {t.sent}")
    for why in ("pause", "sleep", "owner", "power"):
        t = T(state=target_state())
        t.up()
        t.advance(by=60)
        t.responder = lambda c: (3.0, None, None)
        t.lost()
        t.advance(by=1.5)
        if why == "pause":
            t.adapter(Discovering=True)
        elif why == "sleep":
            t.do(t.e.sleep, True)
        elif why == "owner":
            t.do(t.e.owner, False)
        else:
            t.adapter(Powered=False)
        t.advance(by=10)
        check(not t.connects(HEAD, "Disconnect"), f"a late ok after {why} keeps the link")
    t = T(state=target_state())
    t.up(devices=((HEAD, HEADSET_UUIDS, False), (HEAD2, HEADSET_UUIDS, False)))
    t.advance(by=60)
    seq = [(3.0, None, None), (0.5, "org.bluez.Error.InProgress", ""), (0.5, "org.bluez.Error.InProgress", ""),
           (0.5, "org.bluez.Error.InProgress", ""), (0.5, "org.bluez.Error.InProgress", "")]
    t.responder = lambda c: seq.pop(0) if seq else (1.0,) + PAGE
    t.lost()
    t.advance(by=1.5)
    t.connected(HEAD2, True)
    t.advance(by=30)
    d = t.connects(HEAD, "Disconnect")
    check([round(x - d[0], 1) for x in d] == [0.0, 2.5, 5.0, 7.5], f"Disconnect busy retried 3 times: {d}")
    check(any("Disconnect" in line and "dropped" in line for line in t.logs), "Disconnect dropped with a log line")


def test_wants():
    t = T(state=target_state())
    t.up()
    t.advance(by=60)
    n = len(t.sent)
    t.do(t.e.want, "dap")
    check(len(t.sent) == n + 1, "one want now")
    check(t.e.phase() == "want", "Phase reads want")
    t.advance(by=30)
    t.do(t.e.want, "dap")
    check(len(t.sent) == n + 1, "no want within 60 s")
    t.advance(by=31)
    t.responder = lambda c: None
    t.do(t.e.want, "dap")
    t.advance(by=61)
    t.do(t.e.want, "dap")
    check(len(t.sent) == n + 2, "no want with a call in flight")
    for setup in ("receiver", "hold", "pause", "notready"):
        t = T(state=target_state())
        t.up()
        t.advance(by=60)
        if setup == "receiver":
            t.do(t.e.set_role, "dap", "receiver")
        elif setup == "hold":
            t.do(t.e.hold, "dap", True)
        elif setup == "pause":
            t.adapter(Discoverable=True)
        else:
            t.adapter(Powered=False)
        n = len(t.sent)
        t.do(t.e.want, "dap")
        check(len(t.sent) == n, f"no want under {setup}")
    t, _ = loss_run(0.0)
    n = len(t.sent)
    t.do(t.e.want, "dap")
    check(len(t.sent) == n + 1, "a want after the 15 min end")
    t = T(state=target_state())
    t.up()
    t.advance(by=60)
    t.lost()
    t.advance(by=40)
    r = t.e.run
    check(r.phase == "b", "in phase B")
    held, step = r.at, r.step
    t.do(t.e.want, "dap")
    t.advance(by=5.2)
    check(r.at == held and r.step == step, "a failed want keeps the B attempt time and counts no step")
    t.advance(to=held + 0.1)
    check(near(t.connects()[-1], held), "the B attempt runs at its time after a want")


def test_pause():
    t = T(state=target_state())
    t.up()
    t.advance(by=60)
    start = t.now
    t.lost()
    t.advance(by=10)
    t.adapter(Discovering=True)
    check(t.e.phase() == "paused" and t.e.next_attempt() == 0, "paused Phase and NextAttempt 0")
    n = len(t.sent)
    t.advance(by=200)
    check(len(t.sent) == n, "no call in a pause")
    check(any("paused over 60 s" in line for line in t.logs), "a pause over 60 s logs one line")
    t.adapter(Discovering=False)
    t.advance(by=0.01)
    check(len(t.sent) == n + 1 and near(t.sent[-1][0], start + 210, 0.05), "pause end: one resume attempt now")
    t.advance(by=6)
    for _ in range(5):
        t.adapter(Discoverable=True)
        t.advance(by=1)
        t.adapter(Discoverable=False)
        t.advance(by=1)
    resumes = [x for x in t.connects() if x > start + 211]
    check(len(resumes) <= 1, f"flapping gives at most one resume per 60 s: {resumes}")
    t = T(state=target_state())
    t.up()
    t.advance(by=60)
    start = t.now
    t.lost()
    t.advance(by=2)
    t.adapter(Discovering=True)
    t.advance(by=950)
    check(t.e.run is None, "the 15 min deadline runs in a pause")
    t.adapter(Discovering=False)
    t.advance(by=5)
    check(not [x for x in t.connects() if x > start + 900], "nothing after the deadline")
    t = T(state=target_state())
    t.up(devices=((HEAD, HEADSET_UUIDS, False), (HEAD2, HEADSET_UUIDS, False)))
    t.advance(by=60)
    t.lost()
    t.advance(by=2)
    t.adapter(Discovering=True)
    t.connected(HEAD2, True)
    t.adapter(Discovering=False)
    n = len(t.sent)
    t.advance(by=100)
    check(len(t.sent) == n, "no resume after another headset connected in the pause")
    t = T(state=target_state())
    t.up(start=False)
    t.adapter(Discovering=True)
    t.do(t.e.start)
    check(t.e.run is not None and t.e.run.kind == "boot" and not t.sent, "a boot run started paused")
    t.adapter(Discovering=False)
    t.advance(by=0.01)
    check(len(t.sent) == 1, "the paused boot run pages at the pause end")
    t = T(state=target_state())
    t.up(start=False)
    t.adapter(Discovering=True)
    t.do(t.e.start)
    t.advance(by=301)
    check(t.e.run is None, "a boot run paused over 5 min ends")


def test_ready():
    t = T(state=target_state())
    t.up()
    t.advance(by=100)
    n = len(t.sent)
    t.do(t.e.hold, "dap", True)
    t.adapter(Powered=False)
    t.adapter(Powered=True)
    t.do(t.e.hold, "dap", False)
    t.advance(by=50)
    check(len(t.sent) == n, "no boot run at a hold release or a stack edge in a hold")
    t.adapter(Powered=False)
    t.adapter(Powered=True)
    t.advance(by=1)
    check(len(t.sent) == n + 1, "Powered false then true gives a boot run")
    t.advance(by=1)
    t.do(t.e.removed, HCI, [btr.ADAPTER])
    t.do(t.e.added, HCI, {btr.ADAPTER: {"Powered": True}})
    t.advance(by=1)
    check(len(t.sent) == n + 1, "edges within 5 s of a boot run start coalesce")
    t.advance(by=100)
    n = len(t.sent)
    t.do(t.e.sleep, True)
    t.do(t.e.sleep, False)
    t.advance(by=1.9)
    check(len(t.sent) == n, "resume waits 2 s")
    t.advance(by=0.2)
    check(len(t.sent) == n + 1, "resume first attempt at 2 s")
    t.do(t.e.owner, False)
    t.do(t.e.owner, True)
    t.do(t.e.load, t.objects(((HEAD, HEADSET_UUIDS, False),)))
    t.advance(by=5.2)
    check(len(t.sent) == n + 2, "BlueZ return gives a boot run after the call in flight")
    t = T(state=target_state())
    t.up(devices=((HEAD, HEADSET_UUIDS, False), (BOTH, BOTH_UUIDS, False)))
    t.advance(by=60)
    t.lost()
    t.advance(by=2)
    t.connected(BOTH, True)
    check(t.e.run is not None, "a phone listing 0000110a and 0000110b does not stop a headset run")
    check(t.e.set_target("dap", BOTH, t.now)[0] == btr.INVALID, "SetTarget of a phone listing both refused")
    t = T(state=target_state(start_boot={"boot_id": "boot-a", "at": 1000.0 - 30, "count": 1}))
    t.up()
    t.advance(by=10)
    check(not t.sent and any("start 2 in this boot" in line for line in t.logs), "start throttle within 60 s")
    t = T(state=target_state(start_boot={"boot_id": "boot-a", "at": 1000.0 - 61, "count": 1}))
    t.up()
    t.advance(by=1)
    check(len(t.sent) == 1, "start after 60 s runs the boot run")
    t = T(state=target_state(start_boot={"boot_id": "boot-z", "at": 1000.0 - 10, "count": 3}))
    t.up()
    t.advance(by=1)
    check(len(t.sent) == 1 and any("start 1 in this boot" in line for line in t.logs), "a new boot is not throttled")
    t = T(state=target_state())
    t.e.owner(True, 0)
    t.e.load({HCI: {btr.ADAPTER: {"Powered": True}}}, 0)
    t.do(t.e.start)
    t.do(t.e.added, HEAD, {btr.DEVICE: {"UUIDs": HEADSET_UUIDS, "Connected": False}})
    t.advance(by=0.1)
    check(len(t.sent) == 1, "a target added just after the adapter gets the boot run")


def test_teardown():
    t = T(state=target_state(phone="BB:BB:BB:BB:BB:01"))
    t.up(devices=((HEAD, HEADSET_UUIDS, False), (PHONE, PHONE_UUIDS, False)))
    t.advance(by=60)
    before = t.state()
    t.adapter(Powered=False)
    t.do(t.e.removed, HEAD, [btr.DEVICE])
    t.do(t.e.removed, PHONE, [btr.DEVICE])
    t.do(t.e.removed, HCI, [btr.ADAPTER])
    t.do(t.e.owner, False)
    t.advance(by=10)
    check(t.e.target == HEAD and t.e.phone == PHONE, "teardown keeps target and phone")
    after = t.state()
    check(after["target"] == before["target"] and after["phone"] == before["phone"], "teardown keeps the file")
    n = len(t.sent)
    t.do(t.e.owner, True)
    t.do(t.e.load, t.objects(((HEAD, HEADSET_UUIDS, False), (PHONE, PHONE_UUIDS, False))))
    t.advance(by=0.1)
    check(len(t.sent) == n + 1, "the return gives a boot attempt")
    t.advance(by=60)
    t.do(t.e.removed, HEAD, [btr.DEVICE])
    t.advance(by=2.9)
    check(t.e.target == HEAD, "a forget waits 3 s")
    t.advance(by=0.2)
    check(t.e.target is None and t.state()["target"] is None, "a forget clears after 3 s")
    t = T(state=target_state())
    t.up()
    t.advance(by=60)
    t.adapter(Powered=False)
    t.do(t.e.removed, HEAD, [btr.DEVICE])
    t.do(t.e.removed, HCI, [btr.ADAPTER])
    t.do(t.e.owner, False)
    n = len(t.sent)
    t.do(t.e.owner, True)
    t.do(t.e.load, t.objects(((HEAD, HEADSET_UUIDS, False),), powered=False))
    t.advance(by=1.5)
    check(len(t.sent) == n and t.e.phase() == "notready", "a return powered off pages nothing")
    t.adapter(Powered=True)
    t.advance(by=0.1)
    check(len(t.sent) == n + 1, "the later Powered edge gives one boot attempt")
    t.advance(by=6)
    check(t.e.target == HEAD, "the return in the P0 order keeps the target")
    t = T(state=target_state())
    t.up()
    t.advance(by=60)
    t.do(t.e.removed, HEAD, [btr.DEVICE])
    t.advance(by=1)
    t.do(t.e.added, HEAD, {btr.DEVICE: {"UUIDs": HEADSET_UUIDS, "Connected": False}})
    t.advance(by=5)
    check(t.e.target == HEAD, "a device added back in 3 s keeps the target")
    t = T(state=target_state())
    t.up(devices=())
    t.advance(by=4.9)
    check(t.e.target == HEAD, "reconcile waits 5 s of ready")
    t.advance(by=0.2)
    check(t.e.target is None, "a stored target absent after 5 s ready is cleared")


def test_state():
    t = T(state=target_state(phone="BB:BB:BB:BB:BB:01"))
    t.up(devices=((HEAD, HEADSET_UUIDS, False), (PHONE, PHONE_UUIDS, False)))
    t2 = T(path=t.path)
    check(t2.e.target == HEAD and t2.e.phone == PHONE, "state round trip")
    t = T()
    check(t.e.target is None and t.e.phone is None, "missing file gives defaults")
    t = T(state={"target": "nope", "phone": "BB:BB:BB:BB:BB:01"})
    check(t.e.target is None and t.e.phone == PHONE, "a bad field defaults alone")
    check(len([line for line in t.logs if "bad target" in line]) == 1, "one log line for a bad field")
    order = []
    fsync, rename = os.fsync, os.rename
    os.fsync = lambda fd: (order.append("fsync"), fsync(fd))[1]
    os.rename = lambda a, b: (order.append("rename"), rename(a, b))[1]
    try:
        t = T()
        t.up(devices=((HEAD, HEADSET_UUIDS, False),))
    finally:
        os.fsync, os.rename = fsync, rename
    check(order[:3] == ["fsync", "rename", "fsync"], f"fsync, rename, then the directory fsync: {order}")
    blocker = os.path.join(tempfile.mkdtemp(), "file")
    open(blocker, "w").close()
    t = T(path=os.path.join(blocker, "sub", "state.json"))
    t.up()
    t.do(t.e.set_target, "dap", HEAD)
    check(t.e.target == HEAD and any("kept in memory" in line for line in t.logs), "a failed write keeps memory")


def test_api():
    t = T()
    t.up(devices=((HEAD, HEADSET_UUIDS, False), (PHONE, PHONE_UUIDS, False)))
    check(t.e.set_target("dap", PHONE, t.now)[0] == btr.INVALID, "SetTarget of a phone refused")
    check(t.e.set_target("dap", "/org/freedesktop/x", t.now)[0] == btr.INVALID, "SetTarget of a non BlueZ path refused")
    check(len([line for line in t.logs if "refused" in line]) == 2, "refusals logged")
    check(t.do(t.e.set_target, "dap", HEAD) is None and t.e.target == HEAD, "SetTarget of a headset")
    t.do(t.e.set_target, "dap", "/")
    check(t.e.target is None, "SetTarget / clears")
    for n in "abcd":
        t.do(t.e.hold, n, True)
    check(t.e.hold("e", True, t.now)[0] == btr.LIMITS, "a fifth holder refused")
    check(t.e.hold("a", True, t.now) is None, "Hold is idempotent")
    t = T()
    t.e.start(0)
    check(t.e.set_target("dap", HEAD, 0) is None and t.e.target == HEAD, "SetTarget accepted while BlueZ is down")
    t.up(devices=((PHONE, PHONE_UUIDS, False),), start=False)
    t.advance(by=6)
    check(t.e.target is None, "an unknown SetTarget dropped at the next ready")
    t = T()
    t.e.start(0)
    t.do(t.e.set_target, "dap", PHONE)
    t.up(devices=((PHONE, PHONE_UUIDS, False),), start=False)
    t.advance(by=6)
    check(t.e.target is None and any("not a headset" in line for line in t.logs), "a phone SetTarget dropped at ready")


def test_empty_uuids():
    t = T(state=target_state())
    t.up(devices=((HEAD, [], False),))
    t.advance(by=4.9)
    check(not t.sent and t.e.target == HEAD, "a target with no UUIDs yet is kept and not paged")
    t.advance(by=0.2)
    check(t.e.target is None, "a target with no UUIDs after 5 s of ready is cleared")
    t = T(state=target_state())
    t.up(devices=((HEAD, [], False),))
    t.advance(by=2)
    t.do(t.e.changed, HEAD, btr.DEVICE, {"UUIDs": HEADSET_UUIDS})
    t.advance(by=5)
    check(t.e.target == HEAD, "a target whose UUIDs arrive in 5 s is kept")
    t.lost()
    t.advance(by=2)
    check(len(t.connects()) == 1, "the resolved target is paged after a loss")


def test_review_headset():
    t = T()
    t.e.start(0)
    t.do(t.e.set_target, "dap", PHONE)
    t.up(devices=((PHONE, PHONE_UUIDS, False),), start=False)
    t.advance(by=10)
    check(not t.connects(PHONE) and t.e.target is None, f"an unvalidated phone target is never paged: {t.sent}")
    t = T(state={"target": "BB:BB:BB:BB:BB:01"})
    t.up(devices=((PHONE, PHONE_UUIDS, False),))
    t.advance(by=10)
    check(not t.sent and t.e.target is None, "a stored phone target is dropped at the start, not paged")
    t = T(state=target_state())
    t.up()
    t.advance(by=60)
    t.responder = lambda c: (1.0, "org.bluez.Error.InProgress", "")
    t.do(t.e.want, "dap")
    t.advance(by=20)
    check(len(t.connects()) == 6, f"a want is one attempt, no busy retry: {t.connects()}")
    t = T(state=target_state())
    t.up()
    t.advance(by=60)
    t.responder = lambda c: (1.0, None, None)
    t.lost()
    t.advance(by=3)
    by = t.e.run.audio_by
    n = len(t.sent)
    t.do(t.e.want, "dap")
    check(len(t.sent) == n and t.e.run.audio_by == by, "a want during the audio wait sends nothing and keeps it")
    t = T(state=target_state(start_boot={"boot_id": "", "at": 1000.0 - 10, "count": 1}), boot_id="")
    t.up()
    t.advance(by=1)
    check(len(t.sent) == 1, "an empty boot_id is never the same boot")


def receiver(state=None, scope=True, claim=True, connected=True):
    t = T(state=state or {"phone": "BB:BB:BB:BB:BB:01"})
    t.up(devices=((HEAD, HEADSET_UUIDS, False), (PHONE, PHONE_UUIDS, connected)))
    if claim:
        t.do(t.e.set_role, "dap", "receiver")
    if scope:
        t.do(t.e.scope, "dap", True)
    t.advance(by=60)
    t.sent.clear()
    return t


def test_receiver():
    for reason in (TIMEOUT, "org.bluez.Reason.Unknown"):
        t = receiver()
        t.lost(PHONE, reason)
        t.advance(by=2)
        cp = [x for x in t.sent if x[1] == "ConnectProfile"]
        check(len(cp) == 1 and cp[0][2] == PHONE and cp[0][3] == (btr.AVRCP_TARGET,),
              f"{reason}: ConnectProfile with 0000110c: {t.sent}")
        t.advance(by=400)
        check("Connect" not in t.methods(), f"{reason}: never Connect to the phone")
    t = receiver()
    t.responder = lambda c: (1.0, None, None)
    t.lost(PHONE)
    t.advance(by=5)
    t.transport(PHONE + "/sep1/fd0", PHONE, "0000110b")
    t.advance(by=20)
    check(t.e.run is None and "DisconnectProfile" not in t.methods(), "a phone transport in 10 s ends the run")
    check(t.state()["pending_a2dp"] is None, "pending_a2dp cleared at A2DP up")
    t = receiver()
    t.responder = lambda c: (1.0, None, None)
    t.lost(PHONE)
    t.advance(by=5)
    check(t.state()["pending_a2dp"]["addr"] == "BB:BB:BB:BB:BB:01", "pending_a2dp persisted")
    t.advance(by=10)
    dp = [x for x in t.sent if x[1] == "DisconnectProfile"]
    check(len(dp) == 1 and dp[0][3] == (btr.AVRCP_TARGET,) and near(dp[0][0] - t.sent[0][0], 11.0),
          f"no A2DP: one DisconnectProfile with 0000110c at 10 s: {t.sent}")
    check("Disconnect" not in t.methods(), "never Disconnect to the phone")
    check(len([line for line in t.logs if "oui BB:BB:BB" in line]) == 1, "one OUI line")
    check(t.state()["pending_a2dp"] is None, "pending_a2dp cleared at the call")
    n = len(t.sent)
    t.lost(PHONE)
    t.advance(by=30)
    check(len(t.sent) == n, "no attempt until a new scope edge")
    t.do(t.e.scope, "dap", False)
    t.do(t.e.scope, "dap", True)
    t.lost(PHONE)
    t.advance(by=2)
    check(len(t.sent) == n + 1, "a new scope edge allows the next run")
    for scope, claim in ((False, True), (True, False)):
        t = receiver(scope=scope, claim=claim)
        t.lost(PHONE)
        t.advance(by=400)
        check(not t.sent, f"no phone run without {'a scope' if not scope else 'a receiver claim'}")
    t = receiver()
    t.responder = lambda c: (1.0, None, None)
    t.lost(PHONE)
    t.advance(by=5)
    t.do(t.e.scope, "dap", False)
    check(t.e.run is None, "scope end stops the receiver run")
    t.advance(by=10)
    dp = [x for x in t.sent if x[1] == "DisconnectProfile"]
    check(len(dp) == 1 and near(dp[0][0] - t.sent[0][0], 11.0), f"scope end keeps the window: {t.sent}")
    t = receiver()
    t.responder = lambda c: (1.0, None, None)
    t.lost(PHONE)
    t.advance(by=5)
    path = t.path
    left = t.state()["pending_a2dp"]["until"] - (1000.0 + t.now)
    t2 = T(path=path, offset=1000.0 + t.now)
    t2.up(devices=((HEAD, HEADSET_UUIDS, False), (PHONE, PHONE_UUIDS, True)))
    t2.advance(by=left - 0.1)
    check("DisconnectProfile" not in t2.methods(), "a restart waits for until")
    t2.advance(by=0.2)
    check([m for m in t2.methods() if m == "DisconnectProfile"] == ["DisconnectProfile"], f"a restart inside the window: {t2.sent}")
    t3 = T(path=path, offset=1000.0 + t.now + 30)
    t3.up(devices=((HEAD, HEADSET_UUIDS, False), (PHONE, PHONE_UUIDS, True)))
    t3.advance(by=0.1)
    check("DisconnectProfile" not in t3.methods(), "the entry cleared at the call")
    t = receiver()
    t.responder = lambda c: (1.0, None, None)
    t.lost(PHONE)
    t.advance(by=5)
    t4 = T(path=t.path, offset=1000.0 + t.now + 20)
    t4.up(devices=((HEAD, HEADSET_UUIDS, False), (PHONE, PHONE_UUIDS, True)))
    t4.advance(by=0.1)
    check("DisconnectProfile" in t4.methods(), "a restart after until calls at once")
    t5 = T(path=t.path, boot_id="boot-b")
    t5.up(devices=((HEAD, HEADSET_UUIDS, False), (PHONE, PHONE_UUIDS, True)))
    t5.advance(by=20)
    check("DisconnectProfile" not in t5.methods(), "a new boot drops the entry")
    t = receiver()
    t.responder = lambda c: (1.0, None, None)
    t.lost(PHONE)
    t.advance(by=5)
    t.do(t.e.sleep, True)
    t.advance(by=20)
    check("DisconnectProfile" not in t.methods(), "sleep inside the window: no call")
    t = receiver()
    t.lost(PHONE)
    t.advance(by=1200)
    at = [x[0] - t.sent[0][0] + 1.0 for x in t.sent if x[1] == "ConnectProfile"]
    check(t.e.run is None and at[-1] <= 300, f"the receiver run ends at 5 min: {at[-3:]}")
    t = receiver()
    t.lost(PHONE)
    t.advance(by=10)
    t.adapter(Discoverable=True)
    n = len(t.sent)
    t.advance(by=30)
    check(len(t.sent) == n, "a pause holds receiver attempts")
    t.adapter(Discoverable=False)
    t.advance(by=0.1)
    check(len(t.sent) == n + 1, "the pause end resumes the receiver run")
    t = receiver()
    t.responder = lambda c: (1.0, None, None)
    t.lost(PHONE)
    t.advance(by=5)
    t.do(t.e.client_gone, "dap")
    t.advance(by=10)
    check(len([m for m in t.methods() if m == "DisconnectProfile"]) == 1, "the scope holder killed keeps the window")
    t.lost(PHONE)
    t.advance(by=30)
    check(len([m for m in t.methods() if m == "ConnectProfile"]) == 1, "the scope holder killed: no further attempts")
    t = receiver()
    t.do(t.e.want, "dap")
    t.advance(by=10)
    check(not t.sent, "Want has no effect under receiver")
    t = receiver()
    t.responder = lambda c: (3.0, None, None)
    t.lost(PHONE)
    t.advance(by=2)
    t.do(t.e.hold, "dap", True)
    t.advance(by=15)
    check(len([m for m in t.methods() if m == "DisconnectProfile"]) == 1, "a phone ok after a hold opens the window")
    t = receiver()
    t.responder = lambda c: (3.0, None, None)
    t.lost(PHONE)
    t.advance(by=2)
    t.do(t.e.owner, False)
    t.advance(by=15)
    check("DisconnectProfile" not in t.methods(), "a phone ok after owner loss keeps it with no call")


def test_review_receiver():
    t = receiver()
    t.responder = lambda c: (3.0, None, None)
    t.lost(PHONE)
    t.advance(by=2)
    t.transport(PHONE + "/sep1/fd0", PHONE, "0000110b")
    t.advance(by=30)
    check("DisconnectProfile" not in t.methods(), f"A2DP up before the ok: no DisconnectProfile: {t.sent}")
    t = receiver()
    t.responder = lambda c: (1.0, None, None)
    t.lost(PHONE)
    t.advance(by=3)
    t.e.transports[PHONE + "/sep1/fd0"] = {"device": PHONE, "uuid": "0000110b" + U, "at": t.now, "seen": True}
    t.advance(by=20)
    check("DisconnectProfile" not in t.methods(), f"A2DP up at the window end: no DisconnectProfile: {t.sent}")
    t = receiver()
    t.responder = lambda c: (1.0, None, None)
    t.lost(PHONE)
    t.advance(by=4)
    t.do(t.e.removed, PHONE, [btr.DEVICE])
    t.advance(by=20)
    check("DisconnectProfile" not in t.methods() and t.e.window is None, "a phone forgotten in its window gets no call")


for name, fn in list(globals().items()):
    if name.startswith("test_") and callable(fn):
        fn()
if failures:
    print(f"engine: {len(failures)} failures", file=sys.stderr)
    sys.exit(1)
print("engine: ok")
