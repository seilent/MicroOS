#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-audioreach-topology.sh <rpmdir>}
here=$(cd "$(dirname "$0")" && pwd)
ucm=${UCM_HIFI:-$here/../devices/y700/system_files/usr/share/alsa/ucm2/Qualcomm/sm8650/TB321FU/HiFi.conf}
ref=${REF_TPLG:-}
fw=/usr/lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin
name=audioreach-topology
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

rpm=$(find "$dir" -maxdepth 1 -name "$name-0^*.noarch.rpm")
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 ]]; then echo "FAIL: expected one noarch $name RPM in $dir" >&2; exit 1; fi
srpm=$(find "$dir" -maxdepth 1 -name "$name-0^*.src.rpm")
if [[ -z $srpm || $(wc -l <<<"$srpm") -ne 1 ]]; then fail "expected one SRPM in $dir"
elif [[ $(rpm -qp --qf '%{SOURCERPM}' "$rpm") != "${srpm##*/}" ]]; then fail "SOURCERPM is not ${srpm##*/}"; fi
[[ $(rpm -qp --qf '%{RELEASE}' "$rpm") == *.microos ]] || fail "release"
[[ $(rpm -qp --qf '%{VENDOR}' "$rpm") == MicroOS ]] || fail "vendor"
[[ $(rpm -qp --qf '%{LICENSE}' "$rpm") == BSD-3-Clause ]] || fail "license tag"
writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
[[ -z $writable ]] || fail "group or other writable: $writable"
files=$(rpm -qlp "$rpm" | LC_ALL=C sort | paste -sd' ')
[[ $files == "$fw /usr/share/licenses/$name /usr/share/licenses/$name/LICENSE" ]] || fail "files: $files"
debug=$(find "$dir" -maxdepth 1 \( -name '*-debuginfo-*' -o -name '*-debugsource-*' \))
[[ -z $debug ]] || fail "debug RPMs: $debug"

w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT
(cd "$w" && rpm2cpio "$rpm" | cpio -idm --quiet)
alsatplg -d "$w$fw" -o "$w/ours.conf" 2>"$w/ours.err" || { cat "$w/ours.err" >&2; fail "alsatplg -d $fw"; exit 1; }
if [[ -f $ucm ]]; then
  cp "$ucm" "$w/ucm.conf"
else
  echo "skip: no UCM at $ucm" >&2
fi
if [[ -n $ref ]]; then
  alsatplg -d "$ref" -o "$w/ref.conf" 2>"$w/ref.err" || { cat "$w/ref.err" >&2; fail "alsatplg -d $ref"; exit 1; }
else
  echo "skip: no REF_TPLG" >&2
fi

python3 - "$w" <<'PY' || rc=1
import os, re, sys

w = sys.argv[1]
errors = []
def fail(msg):
    errors.append(msg)
    print("FAIL: " + msg, file=sys.stderr)

def parse(path):
    toks = re.findall(r"(?:'[^']*'|[^\s{}\[\]'])+|[{}\[\]]", open(path).read())
    pos = 0
    def unq(s):
        return s[1:-1] if s.startswith("'") else s
    def keypath(s):
        return [unq(p) for p in re.findall(r"'[^']*'|[^.]+", s)]
    def value():
        nonlocal pos
        t = toks[pos]; pos += 1
        if t == '{':
            return block()
        if t == '[':
            out = []
            while toks[pos] != ']':
                out.append(value())
            pos += 1
            return out
        return unq(t)
    def block():
        nonlocal pos
        d = {}
        while pos < len(toks) and toks[pos] != '}':
            path = keypath(toks[pos]); pos += 1
            v = value()
            cur = d
            for p in path[:-1]:
                cur = cur.setdefault(p, {})
            cur[path[-1]] = v
        pos += 1
        return d
    return block()

def model(path):
    c = parse(path)
    m = {}
    m['pcm'] = {}
    for n, p in c.get('SectionPCM', {}).items():
        d = 'playback' if 'playback' in p.get('pcm', {}) else 'capture'
        m['pcm'][n] = (int(p.get('id', 0)), d)
    m['widgets'] = c.get('SectionWidget', {})
    m['controls'] = set(c.get('SectionControlMixer', {}))
    vt = c.get('SectionVendorTuples', {})
    m['mods'] = {}
    for n, wd in m['widgets'].items():
        data = wd.get('data')
        if not isinstance(data, str):
            continue
        if data not in vt:
            fail(f"{path}: widget {n} data {data} has no vendor tuples")
            continue
        kv = {}
        for arr in vt[data].get('tuples', {}).values():
            for k, v in arr.items():
                if isinstance(v, dict):
                    for k2, v2 in v.items():
                        kv[int(k2.replace('token', ''))] = int(v2)
                else:
                    kv[int(k.replace('token', ''))] = int(v)
        if 200 in kv:
            m['mods'][n] = kv
    m['mixers'] = {n: sorted(wd.get('mixer', [])) for n, wd in m['widgets'].items() if wd.get('type') == 'mixer'}
    m['kcontrols'] = {f"{n} {ctl}" for n, ctls in m['mixers'].items() for ctl in ctls}
    m['routes'] = set()
    for s in c.get('SectionGraph', {}).values():
        for line in s.get('lines', []):
            m['routes'].add(tuple(x.strip() for x in line.split(',')))
    names = set(m['widgets'])
    m['ends'] = {x for r in m['routes'] for x in (r[0], r[2]) if x not in names}
    return m

ours = model(os.path.join(w, 'ours.conf'))

want_pcm = {
    'MultiMedia1 Playback': (0, 'playback'),
    'MultiMedia2 Playback': (1, 'playback'),
    'MultiMedia3 Capture': (2, 'capture'),
    'MultiMedia4 Capture': (3, 'capture'),
}
if ours['pcm'] != want_pcm:
    fail(f"PCMs {ours['pcm']}")
want_ends = {'MultiMedia1 Playback', 'MultiMedia2 Playback', 'MultiMedia3 Capture', 'MultiMedia4 Capture',
             'Secondary TDM0 Playback', 'RX_CODEC_DMA_RX_0 Playback', 'VA_CODEC_DMA_TX_0 Capture',
             'TX_CODEC_DMA_TX_3 Capture'}
streams = {wd['stream_name'] for wd in ours['widgets'].values() if 'stream_name' in wd}
if streams != want_ends:
    fail(f"DAI streams {sorted(streams)}")
be = ours['ends'] - set(want_pcm)
if be != want_ends - set(want_pcm):
    fail(f"backend DAI links in routes {sorted(be)}")
want_mixers = {
    'SEC_TDM_RX_0 Audio Mixer': ['MultiMedia1', 'MultiMedia2'],
    'RX_CODEC_DMA_RX_0 Audio Mixer': ['MultiMedia1', 'MultiMedia2'],
    'MultiMedia3 Mixer': ['TX_CODEC_DMA_TX_3', 'VA_CODEC_DMA_TX_0'],
    'MultiMedia4 Mixer': ['TX_CODEC_DMA_TX_3', 'VA_CODEC_DMA_TX_0'],
}
if ours['mixers'] != want_mixers:
    fail(f"mixers {ours['mixers']}")
for v in ('MultiMedia1 Playback Volume', 'MultiMedia2 Playback Volume'):
    if v not in ours['controls']:
        fail(f"no control {v}")

tdm = [n for n, wd in ours['widgets'].items() if wd.get('stream_name') == 'Secondary TDM0 Playback']
if len(tdm) != 1:
    fail(f"Secondary TDM0 Playback widgets {tdm}")
else:
    t = tdm[0]
    kv = ours['mods'].get(t, {})
    want = {200: 0x0700100E, 1: 40, 251: 0, 250: 1, 253: 1, 262: 1, 263: 1, 265: 8, 266: 32, 267: 0, 268: 0, 269: 0}
    got = {k: kv.get(k) for k in want}
    if got != want:
        fail(f"{t} tokens {got}, want {want}")
    mfc = [r[2] for r in ours['routes'] if r[0] == t]
    if len(mfc) != 1 or ours['mods'].get(mfc[0], {}).get(200) != 0x07001015:
        fail(f"{t} is not fed by one MFC: {mfc}")
    elif ('SEC_TDM_RX_0 Audio Mixer' not in {r[2] for r in ours['routes'] if r[0] == mfc[0]}):
        fail(f"{mfc[0]} is not fed by SEC_TDM_RX_0 Audio Mixer")
    if ('Secondary TDM0 Playback', '', t) not in ours['routes']:
        fail(f"no route Secondary TDM0 Playback <- {t}")
for ctl, src in (('MultiMedia1', 'stream0.logger1'), ('MultiMedia2', 'stream1.logger1')):
    if ('SEC_TDM_RX_0 Audio Mixer', ctl, src) not in ours['routes']:
        fail(f"no route SEC_TDM_RX_0 Audio Mixer {ctl} <- {src}")
iids = [kv[201] for kv in ours['mods'].values()]
if len(iids) != len(set(iids)):
    fail("module instance ids are not unique")

ucm = os.path.join(w, 'ucm.conf')
if os.path.exists(ucm):
    text = open(ucm).read()
    ns = tuple(n + ' ' for n in ours['mixers'])
    codec = ('SpkrLeft ', 'SpkrRight ')
    used = [n for n in re.findall(r"cset \"name='([^']+)'", text)
            if not n.startswith(codec) and (n.startswith(ns) or n.endswith(' Playback Volume'))]
    if not used:
        fail("UCM sets no topology control")
    for n in used:
        if n not in ours['kcontrols'] | ours['controls']:
            fail(f"UCM control {n} is not in the topology")
    for kind, d in (('PlaybackPCM', 'playback'), ('CapturePCM', 'capture')):
        for dev in re.findall(kind + r' "hw:\$\{CardId\},(\d+)"', text):
            if (int(dev), d) not in set(ours['pcm'].values()):
                fail(f"UCM {kind} device {dev} is not a {d} PCM")
    for n in re.findall(r"CaptureChannels\s+(\d+)", text):
        if int(n) < 2:
            fail(f"UCM CaptureChannels {n}: q6apm-dai capture front ends take 2 to 4 channels")
    verb = re.search(r"SectionVerb\s*\{.*?EnableSequence\s*\[(.*?)\]", text, re.S)
    routed = set(re.findall(r"cset \"name='([^']+)' 1\"", verb.group(1))) if verb else set()
    fe = {v: n.split()[0] for n, v in ours['pcm'].items()}
    for kind, d in (('PlaybackPCM', 'playback'), ('CapturePCM', 'capture')):
        for dev in set(re.findall(kind + r' "hw:\$\{CardId\},(\d+)"', text)):
            f = fe.get((int(dev), d))
            if f and not any(n.endswith(' Audio Mixer ' + f) if d == 'playback' else n.startswith(f + ' Mixer ')
                             for n in routed):
                fail(f"UCM verb routes no back end for {f}, the PipeWire probe of hw:{dev} fails")
    print(f"ucm: {len(used)} topology controls checked", file=sys.stderr)

refc = os.path.join(w, 'ref.conf')
if os.path.exists(refc):
    ref = model(refc)
    for k in ('pcm', 'mixers', 'controls', 'routes', 'ends'):
        if ours[k] != ref[k]:
            fail(f"{k} differs from the reference")
    shape = lambda m: {n: (wd.get('type'), wd.get('stream_name')) for n, wd in m['widgets'].items()}
    if shape(ours) != shape(ref):
        fail("widget names, types or stream names differ from the reference")
    ids = lambda kv: tuple(kv.get(k) for k in (200, 201, 2, 1, 100))
    for n in sorted(set(ours['mods']) | set(ref['mods'])):
        a, b = ours['mods'].get(n, {}), ref['mods'].get(n, {})
        if ids(a) != ids(b):
            fail(f"{n}: module id, instance, subgraph, dai, container {ids(a)} vs reference {ids(b)}")
        diff = {k: (a.get(k), b.get(k)) for k in set(a) | set(b) if k >= 250 and a.get(k) != b.get(k)}
        if diff:
            print(f"info: {n} tokens differ from the reference (ours, reference): {dict(sorted(diff.items()))}", file=sys.stderr)
    print(f"reference: {len(ref['mods'])} modules compared", file=sys.stderr)

sys.exit(1 if errors else 0)
PY

exit "$rc"
