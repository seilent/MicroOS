import argparse
import ctypes
import math
import multiprocessing
import os
import subprocess
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v3ref as V

BLOCK = 1024
RC = 0


def fail(msg):
    global RC
    RC = 1
    print(f"FAIL: {msg}", flush=True)


def ok(msg):
    print(f"ok {msg}", flush=True)


class Hint(ctypes.Structure):
    _fields_ = [("HintDescriptor", ctypes.c_int), ("LowerBound", ctypes.c_float), ("UpperBound", ctypes.c_float)]


class Desc(ctypes.Structure):
    pass


HANDLE = ctypes.c_void_p
Desc._fields_ = [
    ("UniqueID", ctypes.c_ulong), ("Label", ctypes.c_char_p), ("Properties", ctypes.c_int),
    ("Name", ctypes.c_char_p), ("Maker", ctypes.c_char_p), ("Copyright", ctypes.c_char_p),
    ("PortCount", ctypes.c_ulong), ("PortDescriptors", ctypes.POINTER(ctypes.c_int)),
    ("PortNames", ctypes.POINTER(ctypes.c_char_p)), ("PortRangeHints", ctypes.POINTER(Hint)),
    ("ImplementationData", ctypes.c_void_p),
    ("instantiate", ctypes.CFUNCTYPE(HANDLE, ctypes.POINTER(Desc), ctypes.c_ulong)),
    ("connect_port", ctypes.CFUNCTYPE(None, HANDLE, ctypes.c_ulong, ctypes.POINTER(ctypes.c_float))),
    ("activate", ctypes.CFUNCTYPE(None, HANDLE)),
    ("run", ctypes.CFUNCTYPE(None, HANDLE, ctypes.c_ulong)),
    ("run_adding", ctypes.CFUNCTYPE(None, HANDLE, ctypes.c_ulong)),
    ("set_run_adding_gain", ctypes.CFUNCTYPE(None, HANDLE, ctypes.c_float)),
    ("deactivate", ctypes.CFUNCTYPE(None, HANDLE)),
    ("cleanup", ctypes.CFUNCTYPE(None, HANDLE)),
]
MID = ctypes.CFUNCTYPE(None, ctypes.c_void_p)
FP = ctypes.POINTER(ctypes.c_float)

PLUGINS = {}


class Plugin:
    def __init__(self, path):
        self.lib = ctypes.CDLL(path)
        self.lib.ladspa_descriptor.restype = ctypes.POINTER(Desc)
        self.lib.ladspa_descriptor.argtypes = [ctypes.c_ulong]
        self.dp = self.lib.ladspa_descriptor(0)
        self.d = self.dp.contents
        self.names = [self.d.PortNames[i].decode() for i in range(self.d.PortCount)]
        self.lib.microos_eq_design.argtypes = [ctypes.c_int] + [ctypes.c_double] * 4 + [ctypes.POINTER(ctypes.c_double)]
        self.lib.microos_eq_design.restype = ctypes.c_int
        for name, res in (("warm", ctypes.c_long), ("chains", ctypes.c_int), ("sections", ctypes.c_ulong),
                          ("swaps", ctypes.c_ulong)):
            f = getattr(self.lib, f"microos_eq_test_{name}", None)
            if f is not None:
                f.argtypes, f.restype = [ctypes.c_void_p], res

    def design(self, kind, f, g, q, rate):
        c = (ctypes.c_double * 5)()
        on = self.lib.microos_eq_design(V.TYPES.index(kind), f, g, q, rate, c)
        return bool(on), tuple(c)

    def test(self, name, h):
        return getattr(self.lib, f"microos_eq_test_{name}")(h)


def plugin(path):
    if path not in PLUGINS:
        PLUGINS[path] = Plugin(path)
    return PLUGINS[path]


class Inst:
    def __init__(self, p, rate, ctrl=None):
        self.p = p
        self.h = p.d.instantiate(p.dp, rate)
        self.ctrl = np.zeros(V.CONTROLS, dtype=np.float32) if ctrl is None else ctrl
        base = self.ctrl.ctypes.data
        for k in range(V.CONTROLS):
            p.d.connect_port(self.h, 2 + k, ctypes.cast(base + 4 * k, FP))
        p.d.activate(self.h)

    def reset(self):
        if self.p.d.deactivate:
            self.p.d.deactivate(self.h)
        self.p.d.activate(self.h)

    def run(self, x, y, f0, n):
        self.p.d.connect_port(self.h, 0, ctypes.cast(x.ctypes.data + 4 * f0, FP))
        self.p.d.connect_port(self.h, 1, ctypes.cast(y.ctypes.data + 4 * f0, FP))
        self.p.d.run(self.h, n)

    def close(self):
        self.p.d.cleanup(self.h)

    def t(self, name):
        return self.p.test(name, self.h)


def drive(inst, x, snaps, resets=(), block=1024):
    x = np.ascontiguousarray(x, dtype=np.float32)
    y = np.zeros_like(x)
    keep = None
    lib = inst.p.lib
    slot = ctypes.c_void_p.in_dll(lib, "microos_eq_test_mid") if hasattr(lib, "microos_eq_test_mid") else None
    for b, snap in enumerate(snaps):
        f0 = b * block
        if f0 >= len(x):
            break
        n = min(block, len(x) - f0)
        top, mid = snap if isinstance(snap, tuple) else (snap, None)
        if b in resets:
            inst.reset()
        inst.ctrl[:] = top
        if slot is not None:
            if mid is not None:
                def write(_, m=mid):
                    inst.ctrl[:] = m
                keep = MID(write)
                slot.value = ctypes.cast(keep, ctypes.c_void_p).value
            else:
                slot.value = None
        elif mid is not None:
            raise SystemExit("mid write needs the test build")
        inst.run(x, y, f0, n)
    if slot is not None:
        slot.value = None
    return y.astype(np.float64)


def blocks_for(n_total, block=1024):
    return (n_total + block - 1) // block


def switch_snaps(nb, a, b, at):
    return [a if k < at else b for k in range(nb)]


def maxerr(a, b):
    return float(np.abs(np.asarray(a, dtype=np.float64) - np.asarray(b, dtype=np.float64)).max())


def mag_db(c, freqs, rate):
    z = np.exp(-1j * 2 * np.pi * np.asarray(freqs) / rate)
    return 20 * np.log10(np.abs((c[0] + c[1] * z + c[2] * z * z) / (1 + c[3] * z + c[4] * z * z)))


def leg_design(p, fixture, flatdap_ref, biquad_ref):
    worst = 0.0
    lines = [ln.split() for ln in open(fixture) if ln.startswith("coef ")]
    for ln in lines:
        rate, f, g, q = (float(t) for t in ln[1:5])
        want = [float(t) for t in subprocess.check_output([flatdap_ref, "coef", ln[1], ln[2], ln[3], ln[4]]).split()]
        _, c = p.design("matchedpeak", f, g, q, rate)
        worst = max(worst, max(abs(a - b) for a, b in zip(c, want)))
    if worst > 1e-12 or len(lines) != 180:
        fail(f"design: matchedpeak against flatdap-ref, {len(lines)} lines, worst {worst:.3g}")
    else:
        ok(f"design: matchedpeak equals flatdap-ref on {len(lines)} lines, worst {worst:.3g}")
    worst, n = 0.0, 0
    rates = (44100.0, 48000.0, 96000.0, 32000.0, 384000.0)
    for kind in V.TYPES[:7]:
        for rate in rates:
            for f in (20.0, 31.25, 100.0, 1000.0, 8000.0, 16000.0, 20000.0):
                for g in (-24.0, -6.5, 0.0, 3.0, 12.0):
                    for q in (0.1, 0.71, 2.0, 10.0):
                        on, c = p.design(kind, f, g, q, rate)
                        won, want = V.design(kind, f, g, q, rate)
                        n += 1
                        if on != won:
                            worst = math.inf
                        worst = max(worst, max(abs(a - b) for a, b in zip(c, want)))
    if worst > 1e-12:
        fail(f"design: RBJ coefficients against PipeWire biquad.c, worst {worst:.3g}")
    else:
        ok(f"design: seven RBJ types equal PipeWire 1.6.9 biquad.c coefficients on {n} sets, worst {worst:.3g}")
    freqs = np.geomspace(20, 20000, 61)
    worst = 0.0
    for kind in V.TYPES[:7]:
        for rate in rates:
            for f, g, q in ((40.0, 6.0, 0.7), (1000.0, -9.0, 2.0), (6000.0, 4.0, 0.5), (20.0, 12.0, 10.0), (15000.0, -24.0, 0.1)):
                worst = max(worst, float(np.abs(mag_db(p.design(kind, f, g, q, rate)[1], freqs, rate)
                                                - mag_db(V.rbj(kind, f, g, q, rate), freqs, rate)).max()))
    if worst > 1e-9:
        fail(f"design: RBJ magnitude against PipeWire biquad.c, worst {worst:.3g} dB")
    else:
        ok(f"design: seven RBJ types match the PipeWire 1.6.9 biquad.c magnitude, worst {worst:.3g} dB")
    freqs = np.geomspace(20, 20000, 61)
    worst = 0.0
    for kind in V.TYPES[:7]:
        for rate in (44100.0, 48000.0, 96000.0):
            for f, g, q in ((40.0, 6.0, 0.7), (1000.0, -9.0, 2.0), (6000.0, 4.0, 0.5), (20.0, 12.0, 10.0), (15000.0, -24.0, 0.1)):
                if kind not in V.GAIN_TYPES:
                    g = 0.0
                out = subprocess.run([biquad_ref, f"{rate:g}", "0", kind, f"{f:g}", f"{g:g}", f"{q:g}"],
                                     input="\n".join(f"{v:.6f}" for v in freqs), capture_output=True, text=True, check=True).stdout
                ref = np.array([float(ln.split()[1]) for ln in out.splitlines()])
                worst = max(worst, float(np.abs(mag_db(p.design(kind, f, g, q, rate)[1], np.round(freqs, 6), rate) - ref).max()))
    if worst > 0.01:
        fail(f"design: RBJ against biquad-ref, worst {worst:.4f} dB")
    else:
        ok(f"design: seven RBJ types match biquad-ref at 44100, 48000, 96000, worst {worst:.4f} dB")


def leg_analog(p):
    f = np.geomspace(20, 20000, 400)
    worst = {}
    for rate in (48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000):
        for q in (0.1, 10.0):
            for g in (12.0, -24.0):
                _, c = p.design("matchedpeak", 20.0, g, q, float(rate))
                z = np.exp(-1j * 2 * np.pi * f / rate)
                h = (c[0] + c[1] * z + c[2] * z * z) / (1 + c[3] * z + c[4] * z * z)
                a, s = 10 ** (g / 40), 1j * f / 20.0
                ha = (s * s + s * a / q + 1) / (s * s + s / (a * q) + 1)
                e = float(np.abs(20 * np.log10(np.abs(h)) - 20 * np.log10(np.abs(ha))).max())
                worst[(rate, q, g)] = e
    bound = {48000: 0.002}
    bad = [(k, v) for k, v in worst.items() if v > bound.get(k[0], 0.0004)]
    w48 = max(v for k, v in worst.items() if k[0] == 48000)
    whi = max(v for k, v in worst.items() if k[0] != 48000)
    if bad:
        fail(f"analog: {bad}")
    else:
        ok(f"analog: matchedpeak 20 Hz Q 0.1 and 10, +12 and -24 dB against the analog peak, 20 Hz to 20 kHz: "
           f"88200 to 768000 worst {whi:.6f} dB (bound 0.0004), 48000 worst {w48:.6f} dB (bound 0.002)")


def leg_response(p, flatdap_ref):
    bands = [(31.25, 6, 0.92), (100, -6, 2), (1000, 6, 0.92), (1000, -24, 10), (8000, -4, 0.92), (16000, 9, 0.92),
             (20, 12, 10), (20, -24, 0.1)]
    v = V.controls(-6, [V.mp(f, g, q) for f, g, q in bands])
    worst = 0.0
    n = 1 << 20
    for rate in (44100, 48000, 96000, 192000):
        x = np.zeros(n, dtype=np.float32)
        x[0] = 1
        inst = Inst(p, rate)
        y = drive(inst, x, [v] * blocks_for(n))
        inst.close()
        h = np.fft.rfft(y)
        target = np.geomspace(20, min(20000, 0.45 * rate), 150)
        bins = np.unique(np.round(target * n / rate).astype(int))
        fr = bins * rate / n
        args = [flatdap_ref, "mag", str(rate), "-6"] + [f"{t:g}" for b in bands for t in b]
        out = subprocess.run(args, input="\n".join(f"{t:.10g}" for t in fr), capture_output=True, text=True, check=True).stdout
        ref = np.array([float(ln.split()[1]) for ln in out.splitlines()])
        got = 20 * np.log10(np.abs(h[bins]))
        worst = max(worst, float(np.abs(got - ref).max()))
    if worst > 0.01:
        fail(f"response: impulse FFT against flatdap-ref mag, worst {worst:.4f} dB")
    else:
        ok(f"response: impulse FFT matches flatdap-ref mag at 44100, 48000, 96000, 192000, worst {worst:.4f} dB")


def leg_hints(p):
    d = p.d
    want = {"Preamp": (-24, 0, False), "Count": (0, 10, True)}
    for b in range(1, 11):
        want |= {f"Type{b}": (0, 7, True), f"Freq{b}": (20, 20000, False), f"Gain{b}": (-24, 12, False),
                 f"Q{b}": (np.float32(0.1), 10, False)}
    bad = []
    if d.Label != b"eq" or d.PortCount != 44 or p.names[:2] != ["In", "Out"]:
        bad.append(f"label {d.Label} ports {d.PortCount} {p.names[:2]}")
    if d.PortDescriptors[0] != 0x1 | 0x8 or d.PortDescriptors[1] != 0x2 | 0x8:
        bad.append("audio port descriptors")
    for i, name in enumerate(p.names[2:], 2):
        lo, hi, integer = want.pop(name, (None, None, None))
        hint = d.PortRangeHints[i]
        if lo is None or d.PortDescriptors[i] != 0x1 | 0x4 or not hint.HintDescriptor & 0x1 or not hint.HintDescriptor & 0x2 \
                or hint.LowerBound != np.float32(lo) or hint.UpperBound != np.float32(hi) or bool(hint.HintDescriptor & 0x20) != integer:
            bad.append(name)
    if want or bad or p.lib.ladspa_descriptor(1):
        fail(f"hints: {bad} missing {sorted(want)}")
    else:
        ok("hints: 42 controls bounded at MicroSET's ranges, Count and Type integer, one label")


def leg_identity(p, pt):
    rng = np.random.default_rng(3)
    x = (rng.standard_normal(4096) * 0.2).astype(np.float32)
    cases = []
    for kind in V.GAIN_TYPES:
        cases.append((f"{kind} gain 0", 48000, V.controls(-6.5, [(kind, f, 0.0, 0.92) for f in V.GRAPHIC])))
    cases.append(("Count 0", 48000, V.controls(-6.5, [V.mp(f, 6.0, 0.92) for f in V.GRAPHIC], count=0)))
    cases.append(("matchedpeak 16000 at 32000", 32000, V.controls(-6.5, [V.mp(16000, 6.0, 0.92)])))
    for name, rate, v in cases:
        want = (x.astype(np.float64) * 10 ** (-6.5 / 20)).astype(np.float32)
        for q in (p, pt):
            inst = Inst(q, rate)
            y = drive(inst, x, [v] * blocks_for(len(x))).astype(np.float32)
            sections = inst.t("sections") if q is pt else 0
            inst.close()
            if np.any(np.abs(y - want) > np.spacing(np.abs(want))) or sections:
                fail(f"identity: {name}: worst {np.abs(y - want).max():.3g}, sections {sections}")
                break
        else:
            ok(f"identity: {name}: out equals in times preamp within 1 ulp, no section run")


def leg_rate(p):
    v = V.sets()["S5 +12"]
    ctrl = v.copy()
    x = V.tone(25, 48000, 0, 96000, 0.3)
    nb = blocks_for(len(x))
    bad = []
    for rate in (48000, 96000, 44100):
        inst = Inst(p, rate, ctrl)
        y = drive(inst, x, [v] * nb)
        inst.close()
        ref, _, _ = V.simulate(x, rate, BLOCK, [v] * nb)
        if maxerr(y, ref) > 1e-6:
            bad.append((rate, maxerr(y, ref)))
    if bad:
        fail(f"rate: {bad}")
    else:
        ok("rate: new instances at 48000, 96000, 44100 on one control buffer design at their own rate")


def leg_clamp(p):
    rate = 48000
    nan = float("nan")
    cases = [
        ("float controls out of range and NaN",
         [6.0, 3, 7, 5.0, 30.0, 0.0, 0, nan, -40.0, 50.0, 1, 1000.0, nan, nan],
         V.controls(0, [V.mp(20, 12, 0.1), ("peak", 20, -24, 10), ("lowshelf", 1000, -24, 0.1)])),
        ("Preamp NaN, Count and Type out of range",
         [nan, 12] + [9, 1000.0, 6.0, 1.0, -3, 100.0, 3.0, 2.0, nan, 4000.0, -3.0, 0.7] + [7, 31.25 * 2 ** 3, 6.0, 0.92] * 7,
         V.controls(-24, [V.mp(1000, 6, 1), ("peak", 100, 3, 2), ("peak", 4000, -3, 0.7)] + [V.mp(250, 6, 0.92)] * 7)),
    ]
    x = V.tone(250, rate, 0, 8 * BLOCK, 0.2)
    for name, raw, hand in cases:
        ctrl = np.array(raw + [0.0] * (V.CONTROLS - len(raw)), dtype=np.float32)
        inst = Inst(p, rate)
        y = drive(inst, x, [ctrl] * 8)
        inst.close()
        want = V.df1(x.astype(np.float64), 10 ** (float(hand[0]) / 20), hand_coefs(hand, rate))
        e = maxerr(y, want)
        if e > 1e-6 or not np.isfinite(y).all():
            fail(f"clamp: {name}: max diff {e:.3g} against the hand set")
        else:
            ok(f"clamp: {name} plays the hand clamped set (max diff {e:.2g})")


def hand_coefs(v, rate):
    out = []
    for i in range(int(v[1])):
        t, f, g, q = (float(t) for t in v[2 + 4 * i:6 + 4 * i])
        on, c = V.design(V.TYPES[int(t)], f, g, q, rate)
        if on:
            out.append(c)
    return out


def leg_nan(p):
    rate = 48000
    v = V.sets()["S5 +12"]
    x = V.tone(25, rate, 0, 6 * BLOCK, 0.3)
    x[2 * BLOCK + 100] = np.nan
    inst = Inst(p, rate)
    y = drive(inst, x, [v] * 6)
    inst.close()
    nxt = y[3 * BLOCK:]
    gain, (c,) = V.chain(v, rate)
    xd = gain * x.astype(np.float64)
    x1, x2, y1, y2 = xd[3 * BLOCK - 1], xd[3 * BLOCK - 2], 0.0, 0.0
    want = np.empty(len(nxt))
    for n, xn in enumerate(xd[3 * BLOCK:]):
        out = c[0] * xn + c[1] * x1 + c[2] * x2 - c[3] * y1 - c[4] * y2
        x1, x2, y1, y2 = xn, x1, out, y1
        want[n] = out
    if not np.isfinite(nxt).all() or maxerr(nxt, want) > 1e-6:
        fail(f"NaN recovery: the blocks after a NaN sample do not restart with y state 0 and the last two inputs "
             f"(finite {bool(np.isfinite(nxt).all())}, max diff {maxerr(nxt, want):.3g})")
    else:
        ok(f"NaN recovery: the blocks after a NaN sample are finite and restart with y state 0 and the last two inputs "
           f"(max diff {maxerr(nxt, want):.2g})")


def leg_lifecycle(p, pt):
    s = V.sets()
    a, b, c, d = s["S1 +6"], s["S2 +12"], s["S4 A"], s["S5 -12"]
    nb = 16
    x = V.tone(60, 48000, 0, nb * BLOCK, 0.4)
    xd = x.astype(np.float64)

    def compare(name, q, snaps, resets=(), silent=()):
        inst = Inst(q, 48000)
        y = drive(inst, x, snaps, resets)
        inst.close()
        ref, _, _ = V.simulate(x, 48000, BLOCK, snaps, resets)
        e = maxerr(y, ref)
        quiet = [k for k, blk in enumerate(y.reshape(nb, BLOCK)) if not blk.any()]
        if e <= 1e-6 and quiet == list(silent):
            ok(f"lifecycle: {name} (max diff {e:.2g}, silent blocks {quiet})")
        else:
            fail(f"lifecycle: {name}: max diff {e:.3g}, silent blocks {quiet}, want {list(silent)}")
        return y

    y = compare("the first block after instantiate and activate", p, [a] * nb)
    if maxerr(y[:BLOCK], V.df1(xd[:BLOCK], *V.chain(a, 48000))) > 1e-6:
        fail("lifecycle: the first block is not DF1 from zero state")
    y = compare("deactivate and activate keeps the applied set over a set written before it", p, [a] * 5 + [b] * (nb - 5),
                resets={5})
    if maxerr(y[5 * BLOCK:6 * BLOCK], V.df1(xd[5 * BLOCK:6 * BLOCK], *V.chain(a, 48000))) > 1e-6:
        fail("lifecycle: the block after the reset is not DF1 from zero state with the applied set")
    zero = np.zeros(V.CONTROLS, dtype=np.float32)
    inst = Inst(pt, 48000)
    drive(inst, x, [a] + [zero] * (nb - 1))
    sw = inst.t("swaps")
    inst.close()
    _, starts, _ = V.simulate(x, 48000, BLOCK, [a] + [zero] * (nb - 1))
    if [w[0] for w in starts] != [2 * BLOCK]:
        fail(f"lifecycle: reference swap frames {starts}")
    compare("all zero controls written after the first block are confirmed at the second block after it", pt,
            [a] + [zero] * (nb - 1))
    if sw != 1:
        fail(f"lifecycle: all zero controls started {sw} swaps")
    y = compare("a write between the two reads of a new instance silences that block", pt, [(a, b)] + [b] * (nb - 1),
                silent=[0])
    if maxerr(y[BLOCK:2 * BLOCK], V.df1(xd[BLOCK:2 * BLOCK], *V.chain(b, 48000))) > 1e-6:
        fail("lifecycle: the block after the silent block is not DF1 from zero state with the changed set")
    compare("writes inside three consecutive blocks give three silent blocks", pt, [(a, b), (b, c), (c, d)] + [d] * (nb - 3),
            silent=[0, 1, 2])
    compare("a write that lands between blocks gives none", p, [a] + [b] * (nb - 1))


def leg_new_instance(p):
    s = V.sets()
    bad = []
    for rate in (48000, 96000):
        for name in ("S1 +6", "S5 +12", "S7 LP"):
            x = V.tone(25, rate, 0, 4 * BLOCK, 0.0)
            inst = Inst(p, rate)
            y = drive(inst, x, [s[name]] * 4)
            inst.close()
            want = V.df1(x.astype(np.float64), *V.chain(s[name], rate))
            if maxerr(y, want) > 1e-6:
                bad.append((rate, name))
    if bad:
        fail(f"new instance: {bad}")
    else:
        ok("new instance: the first blocks at 48000 and 96000 play the first read from zero state, no fade")


def warm_of(pt, rate, v, first):
    inst = Inst(pt, rate)
    x = np.zeros(3 * BLOCK, dtype=np.float32)
    drive(inst, x, [first, v, v])
    w, n = inst.t("warm"), inst.t("swaps")
    inst.close()
    return w if n == 1 else None


def leg_warm(pt):
    s = V.sets()
    cand = dict(s)
    cand["Count 0"] = V.controls(0, [V.mp(20, 12, 10)], count=0)
    cand["slow band above Count"] = V.controls(0, [V.mp(1000, 6, 1), V.mp(20, 12, 10)], count=1)
    cand["slow band at gain 0"] = V.controls(0, [V.mp(1000, 6, 1), ("lowshelf", 20, 0.0, 10)])
    bad, n = [], 0
    for rate in (44100, 48000, 96000, 384000):
        for name, v in cand.items():
            first = s["S1 +6"] if name != "S1 +6" else s["FLAT"]
            got, want = warm_of(pt, rate, v, first), V.warm_frames(v, rate)
            n += 1
            if got != want:
                bad.append((rate, name, got, want))
    fixed = [
        ("X peak 20 +12 Q10", 48000, 48000), ("X matchedpeak 20 +12 Q10", 48000, 48000),
        ("FLAT", 48000, 960), ("Count 0", 48000, 960), ("slow band above Count", 48000, 960),
        ("slow band at gain 0", 48000, 960),
    ]
    for name, rate, frames in fixed:
        if V.warm_frames(cand[name], rate) != frames:
            bad.append(("fixed", name, V.warm_frames(cand[name], rate), frames))
    ls = V.warm_frames(cand["X lowshelf 20 +12 Q10"], 48000) / 48.0
    if abs(ls - 899.2) > 0.05:
        bad.append(("lowshelf ms", ls))
    if bad:
        fail(f"warm up: {bad}")
    else:
        ok(f"warm up: W equals v3ref.py on {n} sets and rates; peak corners at the 48000 frame cap, lowshelf corner {ls:.1f} ms")


def leg_tau_guards(pt):
    s = V.sets()
    bad = []
    lp = V.controls(0, [("lowpass", 20000, 0, 0.7)])
    got = warm_of(pt, 32000, lp, s["S1 +6"])
    if got != 640:
        bad.append(("lowpass 20000 at 32000", got))
    r_on = ctypes.c_int.in_dll(pt.lib, "microos_eq_test_r_on")
    r_val = ctypes.c_double.in_dll(pt.lib, "microos_eq_test_r")
    for r in (math.nan, 1.0, 1.0 + 1e-9):
        r_on.value, r_val.value = 1, r
        got = warm_of(pt, 48000, s["S1 -6"], s["S1 +6"])
        r_on.value = 0
        if got != 48000:
            bad.append((r, got))
    v = s["S1 -6"].copy()
    v[3] = np.nan
    got = warm_of(pt, 48000, v, s["S1 +6"])
    if got is None or not 960 <= got <= 48000:
        bad.append(("NaN Freq1", got))
    if bad:
        fail(f"tau guards: {bad}")
    else:
        ok("tau guards: r 0 gives the 640 frame floor at 32000, r NaN, 1 and 1 + 1e-9 give the 48000 frame cap, a NaN Freq stays finite")


def leg_gate(p, png):
    s = V.sets()
    c, flat = s["S3 C"], s["S3 FLAT"]
    torn = c.copy()
    torn[0] = flat[0]
    rate = 48000
    at = 24
    pre = (at + 2) * BLOCK
    n_total = pre + int(V.POST_S * rate)
    nb = blocks_for(n_total)
    snaps = [c] * at + [torn] + [flat] * (nb - at - 1)
    x = V.tone(1000, rate, pre, n_total, math.pi / 2)
    ref, swaps, run = V.simulate(x, rate, BLOCK, snaps)
    yo, yn = run.y(c, 0), run.y(flat, 0)
    unit = V.UNIT["S3 C to FLAT"]
    res = {}
    for name, q in (("gate", p), ("no gate", png)):
        inst = Inst(q, rate)
        y = drive(inst, x, snaps)
        inst.close()
        o5, u5, st = V.stats(y, yo, yn, pre, rate, 240)
        oc, uc, _ = V.stats(y, yo, yn, pre, rate, V.cycle_win(1000, rate))
        within = o5 <= unit[0] and oc <= unit[1] and u5 >= unit[2] and uc >= unit[3] and st <= 1.5
        res[name] = (within, maxerr(y, ref), o5)
    g, ng = res["gate"], res["no gate"]
    if not g[0] or g[1] > 1e-6 or [w[0] for w in swaps] != [pre] or ng[0]:
        fail(f"gate: gate {g}, no gate {ng}, swaps {swaps}")
    else:
        ok(f"gate: the torn S3 sequence never plays the partial set (max diff {g[1]:.2g}, over {g[2]:+.3f} dB); "
           f"the build without the gate plays {ng[2]:+.2f} dB over")


def fade_one(args):
    path, name, freq, a, b, pre_s, rate, label, phase, metrics = args
    p = plugin(path)
    s = V.sets()
    va, vb = s[a], s[b]
    pre = -(-int(pre_s * rate) // BLOCK) * BLOCK
    n_total = pre + int(V.POST_S * rate)
    nb = blocks_for(n_total)
    x = V.tone(freq, rate, pre, n_total, phase)
    snaps = switch_snaps(nb, va, vb, pre // BLOCK - 1)
    inst = Inst(p, rate)
    y = drive(inst, x, snaps)
    inst.close()
    out = {"name": name, "rate": rate, "label": label, "pre": pre}
    yo, yn = None, None
    if metrics != "control":
        ref, swaps, run = V.simulate(x, rate, BLOCK, snaps)
        out["err"] = maxerr(y, ref)
        out["swaps"] = [w[0] for w in swaps]
        w = swaps[0][1] if swaps else 0
        tail = pre + w + V.fade_frames(rate)
        out["tail"] = maxerr(y[tail:], run.y(vb, pre)[tail:])
        out["w"] = w
        yo, yn = run.y(va, 0), run.y(vb, 0)
    else:
        run = V.Run(x, rate)
        yo, yn = run.y(va, 0), run.y(vb, 0)
    if metrics:
        cw = V.cycle_win(freq, rate)
        o5, u5, st = V.stats(y, yo, yn, pre, rate, int(round(0.005 * rate)))
        oc, uc, _ = V.stats(y, yo, yn, pre, rate, cw)
        out["m"] = (o5, oc, u5, uc, st)
        if metrics != "control":
            out["ideal"] = V.ideal_dip(yo, yn, pre, out["w"], rate, freq)
    return out


def worker_count():
    n = len(os.sched_getaffinity(0))
    try:
        quota, period = open("/sys/fs/cgroup/cpu.max").read().split()
        if quota != "max":
            n = min(n, max(1, math.ceil(int(quota) / int(period))))
    except (OSError, ValueError):
        pass
    if os.environ.get("OMP_NUM_THREADS", "").isdigit():
        n = min(n, max(1, int(os.environ["OMP_NUM_THREADS"])))
    return n


def leg_fade(pool, path):
    jobs = []
    for name, freq, a, b, pre_s in V.s_cases() + V.x_cases():
        for label, phase in V.PHASES:
            jobs.append((path, name, freq, a, b, pre_s, 48000, label, phase, True))
    for name, freq, a, b, pre_s in V.s_cases():
        if name.startswith(("S2", "S5")):
            for rate in (44100, 96000):
                for label, phase in V.PHASES:
                    jobs.append((path, name, freq, a, b, pre_s, rate, label, phase, False))
    res = pool.map(fade_one, jobs, chunksize=1)
    by = {}
    for r in res:
        by.setdefault((r["name"], r["rate"]), []).append(r)
    bad = []
    worst_err = 0.0
    print("fade: case | rate | W frames | worst over 5 ms / cycle | worst dip 5 ms / cycle | worst step | dip bound (rule) worst margin")
    for (name, rate), rs in by.items():
        for r in rs:
            worst_err = max(worst_err, r["err"], r["tail"])
            if r["err"] > 1e-6 or r["tail"] > 1e-6 or r["swaps"] != [r["pre"]]:
                bad.append(f"{name} {rate} {r['label']}: diff {r['err']:.3g} tail {r['tail']:.3g} swaps {r['swaps']}")
        if rate != 48000:
            continue
        m = np.array([r["m"] for r in rs])
        margin = math.inf
        for r in rs:
            o5, oc, u5, uc, st = r["m"]
            floor = V.Q8[name] if name in V.Q8 else V.dip_bound(r["ideal"])
            margin = min(margin, uc - floor)
            if oc > 0.5 or uc < floor or st > 1.5:
                bad.append(f"{name} {r['label']}: chain bound, over {oc:+.3f} dip {uc:+.3f} against {floor:+.3f} step {st:.3f}")
            if name in V.UNIT:
                u = V.UNIT[name]
                if o5 > u[0] or oc > u[1] or u5 < u[2] or uc < u[3]:
                    bad.append(f"{name} {r['label']}: unit bound, {o5:+.3f}/{oc:+.3f} {u5:+.3f}/{uc:+.3f} against {u}")
        print(f"  {name} | {rate} | {rs[0]['w']} | {m[:, 0].max():+.3f} / {m[:, 1].max():+.3f} | "
              f"{m[:, 2].min():+.3f} / {m[:, 3].min():+.3f} | {m[:, 4].max():.3f} | {margin:+.3f}")
    if bad:
        for line in bad:
            fail(f"fade: {line}")
    else:
        ok(f"fade: {len(jobs)} runs equal v3ref.py (max diff {worst_err:.2g}), every S case within its unit bounds, "
           f"every S and X case within the chain bound")


def seq_check(name, pt, rate, x, snaps, block, resets=(), start_want=None):
    inst = Inst(pt, rate)
    y = drive(inst, x, snaps, resets, block)
    chains, swaps = inst.t("chains"), inst.t("swaps")
    inst.close()
    ref, sw, _ = V.simulate(x, rate, block, snaps, resets)
    e = maxerr(y, ref)
    starts = [w[0] for w in sw]
    if e <= 1e-6 and chains <= 2 and swaps == len(sw) and starts == start_want:
        ok(f"{name} (max diff {e:.2g}, swaps at frames {starts}, chains {chains})")
    else:
        fail(f"{name}: max diff {e:.3g}, plugin swaps {swaps}, reference swaps at {starts}, want {start_want}, chains {chains}")
    return y


def leg_swap_during_swap(pt):
    s = V.sets()
    rate = 48000
    for kind, blk, a, b, freq, ps in (("floor", 256, "S3 C", "S3 FLAT", 1000, ("S4 A", "S4 B", "S2 +12")),
                                      ("slow", 1024, "S5 -12", "S5 +12", 25, ("S2 +12", "S1 +6", "S5 -12"))):
        c0 = -(-int(0.5 * rate) // blk)
        sw0 = c0 * blk
        w = V.warm_frames(s[b], rate)
        end = sw0 + w + V.fade_frames(rate)
        n_total = end + int(1.6 * rate)
        nb = blocks_for(n_total, blk)
        x = V.tone(freq, rate, sw0, n_total, 0.3)
        base = switch_snaps(nb, s[a], s[b], c0 - 1)
        legs = {
            "during W": ([(c0 + 1, ps[0])], sw0, sw0 + w),
            "during T": ([((sw0 + w) // blk, ps[0])], sw0 + w, end),
            "three during one swap": ([(c0 + 1, ps[0]), (c0 + 3, ps[1]), (c0 + 5, ps[2])], sw0, end),
        }
        for leg, (writes, lo, hi) in legs.items():
            snaps = list(base)
            for at, setname in writes:
                snaps[at:] = [s[setname]] * (nb - at)
            confirms = [(at + 1) * blk for at, _ in writes]
            if not all(lo <= f < hi for f in confirms):
                fail(f"swap during swap: {kind} {leg}: confirmations {confirms} outside [{lo}, {hi})")
                continue
            seq_check(f"swap during swap: {kind} {leg}, confirmed at {confirms}", pt, rate, x, snaps, blk,
                      start_want=[sw0, end])
        snaps = list(base)
        snaps[c0 + 1:c0 + 3] = [s[ps[0]]] * 2
        seq_check(f"swap during swap: {kind}, the target written back during the swap starts no second swap", pt, rate,
                  x, snaps, blk, start_want=[sw0])


def leg_reset(pt):
    s = V.sets()
    rate = 48000
    a, b, newer = s["S5 -12"], s["S5 +12"], s["S1 +6"]
    c0 = -(-int(0.5 * rate) // BLOCK)
    sw0 = c0 * BLOCK
    w = V.warm_frames(b, rate)
    n_total = sw0 + w + int(2.0 * rate)
    nb = blocks_for(n_total)
    x = V.tone(25, rate, sw0, n_total, 0.3)
    xd = x.astype(np.float64)
    base = switch_snaps(nb, a, b, c0 - 1)
    for leg, r in (("W", c0 + 10), ("T", (sw0 + w) // BLOCK + 1)):
        y = seq_check(f"reset: during {leg} (block {r}) plays the target from zero state, no fade", pt, rate, x, base,
                      BLOCK, {r}, [sw0])
        if maxerr(y[r * BLOCK:(r + 1) * BLOCK], V.df1(xd[r * BLOCK:(r + 1) * BLOCK], *V.chain(b, rate))) > 1e-6:
            fail(f"reset: during {leg}: the block after the reset is not DF1 from zero state with the target")
    r = c0 + 10
    snaps = list(base)
    snaps[r - 1:] = [newer] * (nb - r + 1)
    seq_check("reset: a set read by the last run before it swaps in at the first block after it", pt, rate, x, snaps,
              BLOCK, {r}, [sw0, r * BLOCK])
    snaps = list(base)
    snaps[r:] = [newer] * (nb - r)
    seq_check("reset: a set written between that run and the reset swaps in at the second block after it", pt, rate, x,
              snaps, BLOCK, {r}, [sw0, (r + 1) * BLOCK])


def leg_controls(pool, paths):
    jobs = []
    for variant, path in paths.items():
        for name, freq, a, b, pre_s in V.s_cases():
            for label, phase in V.PHASES:
                jobs.append((path, name, freq, a, b, pre_s, 48000, (variant, label), phase, "control"))
    res = pool.map(fade_one, jobs, chunksize=1)
    by = {}
    for r in res:
        by.setdefault((r["label"][0], r["name"]), []).append(r["m"])
    bad = []
    n = 0
    for (variant, name), ms in by.items():
        m = np.array(ms)
        o5, oc, u5, uc, st = m[:, 0].max(), m[:, 1].max(), m[:, 2].min(), m[:, 3].min(), m[:, 4].max()
        u = V.UNIT[name]
        got = {"over": o5 > u[0] or oc > u[1], "dip": u5 < u[2] or uc < u[3], "step": st > 1.5}
        for cell in V.FAILS[name][0 if variant == "V0" else 1].split():
            n += 1
            if not got[cell]:
                bad.append(f"{variant} {name} does not fail {cell}: {o5:+.2f}/{oc:+.2f} {u5:+.2f}/{uc:+.2f} {st:.2f}")
    if bad:
        for line in bad:
            fail(f"negative controls: {line}")
    else:
        ok(f"negative controls: V0 and V1 fail all {n} cells marked fails")


def main():
    ap = argparse.ArgumentParser()
    for opt in ("so", "test", "v0", "v1", "nogate", "flatdap-ref", "biquad-ref", "fixture", "work", "pipewire"):
        ap.add_argument(f"--{opt}", required=True)
    o = ap.parse_args()
    V.build_lib(o.work, o.pipewire)
    diff = V.check_df1()
    if diff != 0:
        fail(f"v3ref: C DF1 differs from the p3.py DF1 loop by {diff:.3g}")
    else:
        ok("v3ref: C DF1 equals the p3.py DF1 loop at difference 0")
    p, pt = plugin(o.so), plugin(o.test)
    leg_design(p, o.fixture, o.flatdap_ref, o.biquad_ref)
    leg_analog(p)
    leg_response(p, o.flatdap_ref)
    leg_hints(p)
    leg_identity(p, pt)
    leg_rate(p)
    leg_clamp(p)
    leg_nan(p)
    leg_lifecycle(p, pt)
    leg_new_instance(p)
    leg_warm(pt)
    leg_tau_guards(pt)
    leg_gate(p, plugin(o.nogate))
    n = worker_count()
    with multiprocessing.get_context("fork").Pool(n) as pool:
        t0 = time.monotonic()
        leg_fade(pool, o.so)
        t1 = time.monotonic()
        leg_swap_during_swap(pt)
        leg_reset(pt)
        t2 = time.monotonic()
        print(f"fade suite: {t2 - t0:.1f} s on {n} workers (fade {t1 - t0:.1f} s, swap during swap and reset {t2 - t1:.1f} s)")
        leg_controls(pool, {"V0": o.v0, "V1": o.v1})
        print(f"negative controls: {time.monotonic() - t2:.1f} s")
    sys.exit(RC)


if __name__ == "__main__":
    main()
