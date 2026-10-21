import ctypes
import math
import os
import subprocess

import numpy as np

BANDS = 10
CONTROLS = 2 + 4 * BANDS
TYPES = ("peak", "lowshelf", "highshelf", "bandpass", "lowpass", "highpass", "allpass", "matchedpeak")
GAIN_TYPES = ("peak", "lowshelf", "highshelf", "matchedpeak")
PASS_TYPES = ("bandpass", "lowpass", "highpass", "allpass")
GRAPHIC = [31.25 * 2 ** k for k in range(10)]
AMP = 0.25
T_S = 0.050
FLOOR_S, CAP_S = 0.020, 1.000
POST_S, SPAN_S = 2.5, 2.4
UNUSED = ("peak", 440.0, 0.0, 1.0)

CSRC = r"""
#include <string.h>

void df1(const double *x, double *y, long n, double g, const double *c, long d)
{
    double s[10][4];
    memset(s, 0, sizeof s);
    for (long i = 0; i < n; i++) {
        double v = g * x[i];
        for (long k = 0; k < d; k++) {
            const double *q = c + 5 * k;
            double out = q[0] * v + q[1] * s[k][0] + q[2] * s[k][1] - q[3] * s[k][2] - q[4] * s[k][3];
            s[k][1] = s[k][0];
            s[k][0] = v;
            s[k][3] = s[k][2];
            s[k][2] = out;
            v = out;
        }
        y[i] = v;
    }
}
"""

LIB = None


def build_lib(work, pipewire):
    global LIB
    src, so = os.path.join(work, "v3ref.c"), os.path.join(work, "v3ref.so")
    with open(src, "w") as f:
        f.write(CSRC)
    here = os.path.dirname(os.path.abspath(__file__))
    subprocess.check_call(["gcc", "-O2", "-ffp-contract=off", "-shared", "-fPIC", "-I", pipewire, "-o", so, src,
                           os.path.join(here, "pwbiquad.c"), "-lm"])
    LIB = ctypes.CDLL(so)
    dp = ctypes.POINTER(ctypes.c_double)
    LIB.df1.argtypes = [dp, dp, ctypes.c_long, ctypes.c_double, dp, ctypes.c_long]
    LIB.df1.restype = None
    LIB.pw_design.argtypes = [ctypes.c_int] + [ctypes.c_double] * 4 + [dp]
    LIB.pw_design.restype = None


def ptr(a):
    return a.ctypes.data_as(ctypes.POINTER(ctypes.c_double))


def df1(x, gain, coefs):
    x = np.ascontiguousarray(x, dtype=np.float64)
    y = np.empty_like(x)
    c = np.ascontiguousarray(np.asarray(coefs, dtype=np.float64).reshape(-1, 5))
    LIB.df1(ptr(x), ptr(y), len(x), gain, ptr(c) if len(c) else ptr(np.zeros(5)), len(c))
    return y


def df1_p3(x, gain, coefs):
    bands = [(np.array(c[:3]), np.array([1.0, c[3], c[4]])) for c in coefs]
    x = np.asarray(x, dtype=np.float64)[None, :]
    st = np.zeros((max(len(bands), 1), 4, 1))
    y = np.empty_like(x)
    for n in range(x.shape[1]):
        v = gain * x[:, n]
        for i, (b, a) in enumerate(bands):
            x1, x2, y1, y2 = st[i].copy()
            out = b[0] * v + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
            st[i] = (v, x1, out, y1)
            v = out
        y[:, n] = v
    return y[0]


def check_df1():
    rng = np.random.default_rng(7)
    x = rng.standard_normal(4800).astype(np.float32).astype(np.float64) * 0.25
    coefs = [matched_peak(60.0, 6.0, 2.0, 48000.0), rbj("lowshelf", 20.0, 12.0, 10.0, 48000.0),
             rbj("highpass", 30.0, 0.0, 0.7, 48000.0)]
    return float(np.abs(df1(x, 0.5, coefs) - df1_p3(x, 0.5, coefs)).max())


def matched_peak(freq, gain, q, rate):
    if gain == 0 or freq >= 0.49 * rate or q <= 0:
        return None
    a = math.pow(10.0, gain / 40.0)
    w0 = 2 * math.pi * freq / rate
    g, z = a * a, 1 / (2 * q * a)
    r = math.cos(math.sqrt(1 - z * z) * w0) if z <= 1 else math.cosh(math.sqrt(z * z - 1) * w0)
    a1 = -2 * math.exp(-z * w0) * r
    a2 = math.exp(-2 * z * w0)
    pa0, pa1, pa2 = (1 + a1 + a2) * (1 + a1 + a2), (1 - a1 + a2) * (1 - a1 + a2), -4 * a2
    p1 = math.sin(w0 / 2) * math.sin(w0 / 2)
    p0 = 1 - p1
    p2 = 4 * p0 * p1
    r1 = (pa0 * p0 + pa1 * p1 + pa2 * p2) * g * g
    r2 = (-pa0 + pa1 + 4 * (p0 - p1) * pa2) * g * g
    qb0 = pa0
    qb2 = (r1 - r2 * p1 - qb0) / (4 * p1 * p1)
    qb1 = r2 + qb0 + 4 * (p1 - p0) * qb2
    w = (math.sqrt(qb0) + math.sqrt(max(qb1, 0.0))) / 2
    if qb1 < 0 or w * w + qb2 < 0:
        return None
    b0 = (w + math.sqrt(w * w + qb2)) / 2
    return (b0, (math.sqrt(qb0) - math.sqrt(qb1)) / 2, -qb2 / (4 * b0), a1, a2)


def rbj(kind, freq, gain, q, rate):
    c = (ctypes.c_double * 5)()
    LIB.pw_design(TYPES.index(kind), freq, gain, q, rate, c)
    return tuple(c)


def design(kind, freq, gain, q, rate):
    if kind == "matchedpeak":
        c = matched_peak(freq, gain, q, rate)
        return (True, c) if c is not None else (False, (1.0, 0.0, 0.0, 0.0, 0.0))
    if kind in GAIN_TYPES and gain == 0:
        return False, (1.0, 0.0, 0.0, 0.0, 0.0)
    return True, rbj(kind, freq, gain, q, rate)


def clampd(v, lo, hi):
    if not v >= lo:
        return lo
    return hi if v > hi else v


def controls(preamp, bands, count=None):
    bands = list(bands)
    v = [preamp, len(bands) if count is None else count]
    for kind, f, g, q in bands + [UNUSED] * (BANDS - len(bands)):
        v += [TYPES.index(kind), f, g, q]
    return np.array(v, dtype=np.float32)


def key(v):
    return np.asarray(v, dtype=np.float32).tobytes()


def chain(v, rate):
    v = [float(t) for t in np.asarray(v, dtype=np.float32)]
    gain = math.pow(10.0, clampd(v[0], -24, 0) / 20.0)
    coefs = []
    for i in range(int(round(clampd(v[1], 0, BANDS)))):
        t, f, g, q = v[2 + 4 * i:6 + 4 * i]
        kind = TYPES[int(round(clampd(t, 0, len(TYPES) - 1)))]
        on, c = design(kind, clampd(f, 20, 20000), clampd(g, -24, 12), clampd(q, 0.1, 10), rate)
        if on:
            coefs.append(c)
    return gain, coefs


def pole_r(a1, a2):
    disc = a1 * a1 - 4 * a2
    return math.sqrt(a2) if disc < 0 else (abs(a1) + math.sqrt(disc)) / 2


def warm_frames(v, rate):
    tau = 0.0
    for c in chain(v, rate)[1]:
        r = pole_r(c[3], c[4])
        if r <= 0:
            t = 0.0
        elif not r < 1:
            t = math.inf
        else:
            t = -1 / (rate * math.log(r))
        if not t <= tau:
            tau = t
    w = 4 * tau
    if not w < CAP_S:
        w = CAP_S
    if w < FLOOR_S:
        w = FLOOR_S
    return int(math.floor(rate * w + 0.5))


def fade_frames(rate):
    return int(math.floor(T_S * rate + 0.5))


class Run:
    def __init__(self, x, rate):
        self.x = np.asarray(x, dtype=np.float32).astype(np.float64)
        self.rate = rate
        self.cache = {}

    def y(self, v, start):
        k = (key(v), start)
        if k not in self.cache:
            gain, coefs = chain(v, self.rate)
            out = np.zeros(len(self.x))
            out[start:] = df1(self.x[start:], gain, coefs)
            self.cache[k] = out
        return self.cache[k]


def simulate(x, rate, block, snaps, resets=()):
    run = Run(x, rate)
    n_total = len(run.x)
    out = np.zeros(n_total)
    t_n = fade_frames(rate)
    have, prev, applied, cur = False, None, None, None
    swap, pending = None, None
    swaps = []

    def start(v, f):
        w = warm_frames(v, rate)
        swaps.append((f, w, key(v)))
        return {"v": v, "s": f, "w": w, "end": f + w + t_n}

    for b, snap in enumerate(snaps):
        f0 = b * block
        f1 = min(f0 + block, n_total)
        if f0 >= n_total:
            break
        top, end = snap if isinstance(snap, tuple) else (snap, snap)
        if b in resets and have:
            if swap is not None:
                applied = swap["v"]
                swap = None
            pending = None
            cur = (applied, f0)
        if not have:
            prev = end
            if key(top) == key(end):
                have, applied, cur = True, top, (top, f0)
                out[f0:f1] = run.y(top, f0)[f0:f1]
            continue
        confirmed = key(top) == key(prev)
        prev = top
        if confirmed:
            if swap is not None:
                pending = None if key(top) == key(swap["v"]) else top
            elif key(top) != key(applied):
                swap = start(top, f0)
        f = f0
        while f < f1:
            yc = run.y(*cur)
            if swap is None:
                out[f:f1] = yc[f:f1]
                break
            g = min(swap["end"], f1)
            yt = run.y(swap["v"], swap["s"])
            pos = np.arange(f, g) - swap["s"]
            a = np.where(pos < swap["w"], 0.0, (pos - swap["w"]) / t_n)
            mix = (1 - a) * yc[f:g] + a * yt[f:g]
            out[f:g] = np.where(pos < swap["w"], yc[f:g], mix)
            f = g
            if f == swap["end"]:
                cur, applied = (swap["v"], swap["s"]), swap["v"]
                swap = None
                if pending is not None:
                    nxt, pending = pending, None
                    if key(nxt) != key(applied):
                        swap = start(nxt, f)
    return out, swaps, run


def win_rms(y, win):
    c = np.concatenate([[0.0], np.cumsum(np.asarray(y, dtype=np.float64) ** 2)])
    return np.sqrt(np.maximum(c[win:] - c[:-win], 0.0) / win)


def stats(y, ref_old, ref_new, pre, rate, win):
    q = rate // 4
    post = int(POST_S * rate)
    span = int(SPAN_S * rate)
    dy = np.abs(np.diff(y, prepend=y[:1]))
    step = dy[pre:pre + span].max()
    s_old = np.abs(np.diff(ref_old))[pre - q:pre + post - 1].max()
    s_new = np.abs(np.diff(ref_new))[pre - q:pre + post - 1].max()
    r = win_rms(y, win)
    ro, rn = win_rms(ref_old, win)[pre - q:pre + post - win], win_rms(ref_new, win)[pre - q:pre + post - win]
    burst = r[pre - win + 1:pre + span - win + 1].max()
    over = 20 * np.log10(burst / max(ro.max(), rn.max()))
    lo = r[pre:pre + span - win + 1].min()
    under = 20 * np.log10(max(lo, 1e-12) / min(ro.min(), rn.min()))
    return over, under, step / max(s_old, s_new)


def cycle_win(freq, rate):
    period = rate / freq
    k = int(np.ceil(0.025 * rate / period - 1e-9))
    return int(round(max(1, k) * period))


def ideal(ref_old, ref_new, s, w, t_n):
    a = np.zeros(len(ref_old))
    a[s + w:s + w + t_n] = np.arange(t_n) / t_n
    a[s + w + t_n:] = 1.0
    return (1 - a) * ref_old + a * ref_new


def ideal_dip(ref_old, ref_new, s, w, rate, freq):
    y = ideal(ref_old, ref_new, s, w, fade_frames(rate))
    return stats(y, ref_old, ref_new, s, rate, cycle_win(freq, rate))[1]


def dip_bound(d_ideal):
    return min(-1.0, d_ideal - 0.1)


def mp(f, g, q):
    return ("matchedpeak", f, g, q)


def graphic(preamp, gains):
    return controls(preamp, [mp(f, g, 0.92) for f, g in zip(GRAPHIC, gains)])


def gains_at(band, value):
    g = [0.0] * 10
    g[GRAPHIC.index(band)] = value
    return g


def corners():
    out = {}
    for kind, g in (("peak", 12.0), ("lowshelf", 12.0), ("highshelf", -24.0), ("matchedpeak", 12.0),
                    ("bandpass", 0.0), ("lowpass", 0.0), ("highpass", 0.0), ("allpass", 0.0)):
        out[kind] = (20.0, g, 10.0)
    return out


def sets():
    s = {
        "S1 +6": controls(0, [mp(60, 6, 2)]), "S1 -6": controls(0, [mp(60, -6, 2)]),
        "S2 +12": controls(-12, [mp(31.25, 12, 0.92)]), "S2 -12": controls(0, [mp(31.25, -12, 0.92)]),
        "S3 C": graphic(-12, gains_at(1000.0, 12)), "S3 FLAT": graphic(0, [0.0] * 10),
        "S4 A": graphic(-6, gains_at(31.25, 6)), "S4 B": graphic(-6, gains_at(16000.0, 6)),
        "S5 +12": controls(-12, [mp(20, 12, 10)]), "S5 -12": controls(0, [mp(20, -12, 10)]),
        "S6 +12": controls(-12, [("lowshelf", 20, 12, 10)]), "S6 -12": controls(0, [("lowshelf", 20, -12, 10)]),
        "FLAT": controls(0, []),
        "S7 HP": controls(0, [("highpass", 20, 0, 10)]), "S7 LP": controls(0, [("lowpass", 20, 0, 10)]),
        "S8 +12": controls(-12, [mp(20, 12, 0.1)]), "S8 -12": controls(0, [mp(20, -12, 0.1)]),
    }
    for kind, (f0, g, q) in corners().items():
        s[f"X {kind} {f0:g} {g:+g} Q{q:g}"] = controls(-max(g, 0), [(kind, f0, g, q)])
        if kind in GAIN_TYPES:
            mg = -g if -24 <= -g <= 12 else 12.0
            s[f"X {kind} {f0:g} {mg:+g} Q{q:g}"] = controls(-max(mg, 0), [(kind, f0, mg, q)])
    return s


def s_cases():
    out = [("S1", 60, "S1 +6", "S1 -6", 0.5),
           ("S2 up", 40, "S2 -12", "S2 +12", 0.5), ("S2 down", 40, "S2 +12", "S2 -12", 0.5),
           ("S3 C to FLAT", 1000, "S3 C", "S3 FLAT", 0.5), ("S3 FLAT to C", 1000, "S3 FLAT", "S3 C", 0.5),
           ("S4 A to B", 1000, "S4 A", "S4 B", 0.5)]
    for p in ("S5", "S6"):
        for f in (20, 25):
            out += [(f"{p} down {f}", f, f"{p} +12", f"{p} -12", 2.0), (f"{p} up {f}", f, f"{p} -12", f"{p} +12", 2.0)]
    for p in ("HP", "LP"):
        for f in (20, 25):
            out += [(f"S7 FLAT to {p} {f}", f, "FLAT", f"S7 {p}", 2.0), (f"S7 {p} to FLAT {f}", f, f"S7 {p}", "FLAT", 2.0)]
    for f in (20, 25, 100):
        out += [(f"S8 up {f}", f, "S8 -12", "S8 +12", 2.0), (f"S8 down {f}", f, "S8 +12", "S8 -12", 2.0)]
    return out


def x_cases():
    out = []
    for kind, (f0, g, q) in corners().items():
        c = f"X {kind} {f0:g} {g:+g} Q{q:g}"
        pairs = [("FLAT", c), (c, "FLAT")]
        if kind in GAIN_TYPES:
            mg = -g if -24 <= -g <= 12 else 12.0
            m = f"X {kind} {f0:g} {mg:+g} Q{q:g}"
            pairs += [(m, c), (c, m)]
        for f in (f0, 1.25 * f0):
            for a, b in pairs:
                out.append((f"{a} to {b} @{f:g}", f, a, b, 2.0))
    return out


UNIT = {
    "S1": (0.050, 0.050, -0.050, -0.050),
    "S2 up": (0.053, 0.054, -1.265, -0.272),
    "S2 down": (0.050, 0.051, -0.050, -0.239),
    "S3 C to FLAT": (0.050, 0.050, -0.050, -0.050),
    "S3 FLAT to C": (0.050, 0.050, -0.050, -0.050),
    "S4 A to B": (0.050, 0.050, -0.051, -0.050),
    "S5 down 20": (0.046, 0.045, -0.050, -0.050),
    "S5 up 20": (0.047, 0.046, -0.050, -0.050),
    "S5 down 25": (0.071, 0.061, -0.046, -0.081),
    "S5 up 25": (0.050, 0.050, -1.295, -0.113),
    "S6 down 20": (0.230, 0.217, -1.533, -0.866),
    "S6 up 20": (0.194, 0.280, -0.185, -0.566),
    "S6 down 25": (0.138, 0.098, -11.872, -0.299),
    "S6 up 25": (0.050, 0.050, -0.298, -0.433),
    "S7 FLAT to HP 20": (0.050, 0.050, -0.050, -0.627),
    "S7 HP to FLAT 20": (0.050, 0.050, -8.968, -1.176),
    "S7 FLAT to HP 25": (0.138, 0.129, -0.050, -0.051),
    "S7 HP to FLAT 25": (0.050, 0.050, -0.125, -0.051),
    "S7 FLAT to LP 20": (0.050, 0.050, -16.350, -1.175),
    "S7 LP to FLAT 20": (0.050, 0.050, -0.050, -0.626),
    "S7 FLAT to LP 25": (0.191, 0.174, -25.612, -5.111),
    "S7 LP to FLAT 25": (0.050, 0.050, -8.149, -4.498),
    "S8 up 20": (0.053, 0.051, -0.050, -0.050),
    "S8 down 20": (0.050, 0.050, -0.051, -0.051),
    "S8 up 25": (0.053, 0.051, -0.050, -0.050),
    "S8 down 25": (0.050, 0.050, -0.050, -0.051),
    "S8 up 100": (0.052, 0.050, -0.265, -0.085),
    "S8 down 100": (0.051, 0.050, -0.250, -0.083),
}

Q8 = {
    "FLAT to X highshelf 20 -24 Q10 @25": -2.542 - 0.05,
    "FLAT to X allpass 20 +0 Q10 @20": -5.605 - 0.05,
}

FAILS = {
    "S1": ("", "step"), "S2 up": ("over step", "over step"), "S2 down": ("over step", "step"),
    "S3 C to FLAT": ("", ""), "S3 FLAT to C": ("over step", "step"), "S4 A to B": ("step", "step"),
    "S5 down 20": ("over step", ""), "S5 up 20": ("dip step", ""), "S5 down 25": ("over step", "over step"),
    "S5 up 25": ("dip step", "dip step"),
    "S6 down 20": ("over step", "over step"), "S6 up 20": ("over step", "over step"),
    "S6 down 25": ("over step", "over step"), "S6 up 25": ("over step", "dip step"),
    "S7 FLAT to HP 20": ("", ""), "S7 HP to FLAT 20": ("step", "step"), "S7 FLAT to HP 25": ("over", "over"),
    "S7 HP to FLAT 25": ("step", "step"), "S7 FLAT to LP 20": ("", "step"), "S7 LP to FLAT 20": ("step", "step"),
    "S7 FLAT to LP 25": ("over step", "over step"), "S7 LP to FLAT 25": ("step", "step"),
    "S8 up 20": ("over step", "over step"), "S8 down 20": ("over step", "step"),
    "S8 up 25": ("over step", "over step"), "S8 down 25": ("over step", "step"),
    "S8 up 100": ("over step", "over step"), "S8 down 100": ("over step", "step"),
}

PHASES = [("peak", math.pi / 2), ("zero", 0.0)] + [(f"phase {k}/64", 2 * math.pi * k / 64) for k in range(0, 64, 8)]


def tone(freq, rate, s, n_total, phase):
    n = np.arange(n_total)
    return (AMP * np.sin(2 * np.pi * freq / rate * (n - s) + phase)).astype(np.float32)
