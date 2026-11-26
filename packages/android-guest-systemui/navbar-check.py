#!/usr/bin/env python3
import itertools
import re
import sys

NB = "com/android/systemui/navigationbar/NavigationBar.smali"
NV = "com/android/systemui/navigationbar/NavigationBarView.smali"
DL = "com/android/wm/shell/common/DisplayLayout.smali"
P1 = ".method public final getBarLayoutParamsForRotation(I)Landroid/view/WindowManager$LayoutParams;"
P2 = ".method public recalcInsets(Landroid/content/res/Resources;)V"
P3 = ".method public final updateCurrentRotation()V"
CAN_MOVE = 0x01110191
MODE = 0x010E00B1
FRAME_HEIGHT = 0x010501CF
HEIGHT = 0x010501D3
WIDTH = 0x010501D8
LP = "Landroid/view/WindowManager$LayoutParams;"
RES = "Landroid/content/res/Resources;->get"
SHAPES = ((2560, 1600), (1600, 2560), (1600, 1600))

failures = []
seen = set()


class Bad(Exception):
    pass


def ref(x):
    return ("ref", x)


def prim(x):
    return ("prim", x)


def split(path):
    parts, cur, name = {}, [], None
    for line in open(path).read().split("\n"):
        if line.startswith(".method "):
            parts[name], cur, name = cur, [], line
        cur.append(line)
        if line == ".end method":
            parts[name], cur, name = cur, [], ("after", name)
    parts[name] = cur
    return parts


def code(path, sig):
    lines = split(path)[sig]
    out, labels, skip = [], {}, False
    for line in (x.strip() for x in lines[1:-1]):
        if line.startswith(".annotation"):
            skip = True
        if skip:
            skip = line != ".end annotation"
            continue
        if not line or line.startswith((".", "#")):
            continue
        if line.startswith(":"):
            labels[line[1:]] = len(out)
            continue
        out.append(line)
    return out, labels


def regs(text):
    text = text.strip("{}").strip()
    if not text:
        return []
    m = re.fullmatch(r"([vp])(\d+) \.\. [vp](\d+)", text)
    if m:
        return [m.group(1) + str(i) for i in range(int(m.group(2)), int(m.group(3)) + 1)]
    return [r.strip() for r in text.split(",")]


def kinds(desc):
    out, i = [], 0
    while i < len(desc):
        j = i
        while desc[j] == "[":
            j += 1
        if desc[j] in "JD":
            raise Bad(f"no model for the wide type in {desc}")
        end = desc.index(";", j) + 1 if desc[j] == "L" else j + 1
        out.append("ref" if desc[i] in "L[" else "prim")
        i = end
    return out


def ret_kind(desc):
    r = desc.split(")")[1]
    return None if r == "V" else ("ref" if r[0] in "L[" else "prim")


def arith(op, a, b):
    if isinstance(a, int) and isinstance(b, int):
        return a | b if op == "or" else a + b
    return (op, a, b)


def run(path, sig, r, fields, calls):
    body, labels = code(path, sig)
    result, events, heap, made, pc = None, [], {}, 0, 0

    def get(x, want):
        if x not in r:
            raise Bad(f"reads {x} before a write")
        v = r[x]
        if want and v[0] != want:
            raise Bad(f"{x} holds a {v[0]}, the instruction wants a {want}")
        return v

    def obj(x):
        v = get(x, "ref")
        if v[1] is None:
            raise Bad(f"{x} is null")
        return v

    for _ in range(10000):
        line = body[pc]
        pc += 1
        op, _, rest = line.partition(" ")
        try:
            if op.startswith("invoke-"):
                m = re.fullmatch(r"(\{[^}]*\}), (\S+)", rest)
                names, target = regs(m.group(1)), m.group(2)
                desc = target[target.index("("):]
                want = kinds(desc[1:desc.index(")")])
                if not op.startswith("invoke-static"):
                    want = ["ref"] + want
                if len(want) != len(names):
                    raise Bad(f"passes {len(names)} registers for {len(want)} arguments")
                args = [get(x, k) for x, k in zip(names, want)]
                if not op.startswith("invoke-static"):
                    obj(names[0])
                result = calls(target, args)
                kind = ret_kind(desc)
                if (result is None) != (kind is None) or (kind and result[0] != kind):
                    raise Bad(f"the model of {target} returned {result!r}")
                result = (result, kind)
                events.append(("call", target, args))
                if target == "Landroid/graphics/Rect;->setEmpty()V":
                    heap[args[0][1]] = {f: prim(0) for f in ("left:I", "top:I", "right:I", "bottom:I")}
                elif target == "Landroid/graphics/Rect;->set(Landroid/graphics/Rect;)V":
                    heap[args[0][1]] = dict(heap.get(args[1][1], {}))
                continue
            a = [x.strip() for x in rest.split(", ")]
            if op.startswith("const-string"):
                r[a[0]] = ref(("string", a[1]))
            elif op.startswith("const"):
                r[a[0]] = prim(int(a[1], 16))
            elif op.startswith("move-result"):
                kind = "ref" if op == "move-result-object" else "prim"
                if result is None or result[1] != kind:
                    raise Bad(f"takes a {kind} result after {result!r}")
                r[a[0]] = result[0]
                result = None
            elif op.startswith("move-object"):
                r[a[0]] = get(a[1], "ref")
            elif op.startswith("move"):
                r[a[0]] = get(a[1], "prim")
            elif op.startswith("iget") or op.startswith("iput"):
                field = a[2].split("->")[1]
                kind = "ref" if field.split(":")[1][0] in "L[" else "prim"
                if (op.endswith("-object")) != (kind == "ref"):
                    raise Bad(f"{op} on the {kind} field {field}")
                holder = obj(a[1])[1]
                if op.startswith("iget"):
                    stored = heap.get(holder, {}).get(field)
                    r[a[0]] = stored if stored is not None else fields(holder, field, kind)
                else:
                    value = get(a[0], kind)
                    heap.setdefault(holder, {})[field] = value
                    events.append(("put", field, holder, value))
            elif op == "new-instance":
                made += 1
                r[a[0]] = ref(("new", a[1], made))
            elif op == "new-array":
                get(a[1], "prim")
                made += 1
                r[a[0]] = ref(("array", a[2], made))
            elif op == "aput-object":
                get(a[2], "prim")
                events.append(("aput", obj(a[1]), get(a[0], "ref")))
            elif op == "and-int/lit8":
                v = get(a[1], "prim")[1]
                if not isinstance(v, int):
                    raise Bad(f"masks the unknown {v!r}")
                r[a[0]] = prim(v & int(a[2], 16))
            elif op in ("or-int/2addr", "add-int/2addr"):
                r[a[0]] = prim(arith(op[:op.index("-")], get(a[0], "prim")[1], get(a[1], "prim")[1]))
            elif op == "goto":
                pc = labels[a[0][1:]]
            elif op.startswith("if-"):
                kind = op[3:5]
                if op.endswith("z"):
                    x, target = get(a[0], None), a[1]
                    if x[0] == "ref":
                        if kind not in ("eq", "ne"):
                            raise Bad(f"{op} on a reference")
                        taken = (x[1] is None) == (kind == "eq")
                        if taken:
                            pc = labels[target[1:]]
                        continue
                    x, y = x[1], 0
                else:
                    x, y, target = get(a[0], "prim")[1], get(a[1], "prim")[1], a[2]
                known = [v for v in (x, y) if not isinstance(v, tuple)]
                if len(known) == 1 and isinstance(known[0], int) and known[0] <= 0 and kind in ("eq", "ne"):
                    taken = kind == "ne"
                elif len(known) == 2 and all(isinstance(v, int) for v in known):
                    taken = {"eq": x == y, "ne": x != y, "lt": x < y, "ge": x >= y, "gt": x > y, "le": x <= y}[kind]
                else:
                    raise Bad(f"branches on {x!r}, {y!r}")
                if taken:
                    pc = labels[target[1:]]
            elif op == "return-void":
                return events
            elif op in ("return", "return-object"):
                events.append(("return", get(a[0], "prim" if op == "return" else "ref")))
                return events
            else:
                raise Bad("no model")
        except Bad as e:
            raise Bad(f"{line}: {e}") from None
    raise Bad("no end after 10000 steps")


def default(field, kind):
    name = field.split(":")[0]
    return ref(("field", name)) if kind == "ref" else prim(("field", name))


def resources(target, args, want, can, mode):
    if args[0] != want:
        raise Bad(f"{target} on {args[0]!r}, not on {want!r}")
    if target.endswith("getBoolean(I)Z") and args[1] == prim(CAN_MOVE):
        return prim(can)
    if target.endswith("getInteger(I)I") and args[1] == prim(MODE):
        return prim(mode)
    if target.endswith("getDimensionPixelSize(I)I") and isinstance(args[1][1], int):
        return prim(("dim", args[1][1]))
    raise Bad(f"no model for {target} with {args[1]!r}")


def fallback(target):
    kind = ret_kind(target[target.index("("):])
    return None if kind is None else (ref(("ret", target)) if kind == "ref" else prim(("ret", target)))


def p1(path, rot, wm, metrics, w, h, can, mode, immersive):
    def fields(holder, field, kind):
        name = field.split(":")[0]
        if holder == "this" and name == "mWindowManager":
            return ref("wm" if wm else None)
        if holder == "this" and name == "mImmersive":
            return prim(immersive)
        return default(field, kind)

    def calls(target, args):
        if target.startswith(RES):
            return resources(target, args, ref("userResources"), can, mode)
        if target.endswith(";->createCurrentUserContext(Landroid/content/Context;)Landroid/content/Context;"):
            return ref("userContext")
        if target == "Landroid/content/Context;->getResources()Landroid/content/res/Resources;":
            return ref("userResources" if args[0] == ref("userContext") else ("resources", args[0][1]))
        if target == "Landroid/view/WindowManager;->getCurrentWindowMetrics()Landroid/view/WindowMetrics;":
            return ref("metrics" if metrics else None)
        if target == "Landroid/graphics/Rect;->width()I":
            return prim(w)
        if target == "Landroid/graphics/Rect;->height()I":
            return prim(h)
        if target == "Landroid/graphics/Insets;->of(IIII)Landroid/graphics/Insets;":
            return ref(("insets",) + tuple(x[1] for x in args))
        return fallback(target)

    return run(path, P1, {"p0": ref("this"), "p1": prim(rot)}, fields, calls)


def p1_result(events):
    size = [[x[1] for x in e[2][1:3]] for e in events if e[0] == "call" and e[1] == f"{LP}-><init>(IIIII)V"]
    gravity = [e[3][1] for e in events if e[0] == "put" and e[1] == "gravity:I"]
    insets = [e[2][2][1] if len(e[2]) == 3 else None for e in events
              if e[0] == "call" and e[1].startswith("Landroid/view/InsetsFrameProvider;-><init>")]
    return [size, gravity, insets]


def p1_want(patched, rot, wm, metrics, w, h, can, mode, immersive):
    gate = not wm or not metrics or (w != h and (can == 1 or (patched and mode == 0)))
    if not gate:
        place = "bottom"
    elif patched:
        place = {-1: "bottom", 0: "right", 1: "bottom", 2: "right", 3: "bottom"}.get(rot, "none")
    else:
        place = {-1: "bottom", 0: "bottom", 1: "right", 2: "bottom", 3: "left"}.get(rot, "none")
    size, gravity, insets = {
        "bottom": ([-1, ("dim", FRAME_HEIGHT)], 0x50, ("insets", 0, 0, 0, ("dim", HEIGHT))),
        "right": ([("dim", WIDTH), -1], 5, None),
        "left": ([("dim", WIDTH), -1], 3, None),
        "none": ([-1, -1], 0x50, None),
    }[place]
    if immersive:
        size, insets = [0, 0], ("insets", 0, 0, 0, 0)
    return [[size], [gravity], [insets]]


def p2(path, rot, w, h, can, mode, car, nav, cutout, extra, status):
    values = {"mRotation": prim(rot), "mWidth": prim(w), "mHeight": prim(h), "mUiMode": prim(0x13 if car else 0x11),
              "mHasNavigationBar": prim(nav), "mHasStatusBar": prim(status), "mCutout": ref("cutout" if cutout else None)}

    def fields(holder, field, kind):
        name = field.split(":")[0]
        if holder == "this" and name in values:
            return values[name]
        return default(field, kind)

    def calls(target, args):
        if target.startswith(RES):
            return resources(target, args, ref("res"), can, mode)
        if target == "Landroid/view/InsetsState;->getSource(I)Landroid/view/InsetsSource;":
            return ref(None if extra == "none" else "extra")
        if target == "Landroid/view/InsetsSource;->isVisible()Z":
            return prim(int(extra == "visible"))
        if target == "Landroid/view/InsetsSource;->getFrame()Landroid/graphics/Rect;":
            return ref("extraFrame")
        if target == "Ljava/lang/Math;->max(II)I":
            a, b = args[0][1], args[1][1]
            return prim(max(a, b) if isinstance(a, int) and isinstance(b, int) else ("max", a, b))
        return fallback(target)

    return run(path, P2, {"p0": ref("this"), "p1": ref("res")}, fields, calls)


def p2_result(events):
    return [(e[1], e[3][1]) for e in events if e[0] == "put" and e[2] == ("field", "mNonDecorInsets")]


def p2_want(patched, rot, w, h, can, mode, car):
    gate = w != h and (can == 1 or (patched and mode == 0))
    if gate and w > h:
        side = "right" if patched or rot == 1 else "left"
        return [(f"{side}:I", ("dim", 0x010501D9 if car else WIDTH))]
    if car:
        return [("bottom:I", ("dim", 0x010501D6 if w > h else 0x010501D4))]
    return [("bottom:I", ("dim", 0x010501D5 if w > h else HEIGHT))]


def p3(path, rot, current, before):
    def fields(holder, field, kind):
        name = field.split(":")[0]
        if holder == "this" and name == "mCurrentRotation":
            return prim(current)
        if name == "mAlternativeOrder":
            return prim(before)
        return default(field, kind)

    def calls(target, args):
        if target == "Landroid/app/WindowConfiguration;->getDisplayRotation()I":
            return prim(rot)
        return fallback(target)

    return run(path, P3, {"p0": ref("this")}, fields, calls)


def p3_result(events, before):
    puts = [e[3][1] for e in events if e[0] == "put" and e[1] == "mAlternativeOrder:Z"]
    return puts[-1] if puts else before


def p3_events(events):
    out = []
    for e in events:
        if e[0] == "put" and e[1] == "mCurrentRotation:I":
            e = e[:3] + ("rotation",)
        elif e[0] == "call" and e[1].endswith("DeadZone;->onConfigurationChanged(I)V"):
            e = (e[0], e[1], [e[2][0], "rotation"])
        out.append(e)
    return out


def no_gate(events):
    return [e for e in events if not (e[0] == "call" and e[1].startswith(RES) and e[2][1] in (prim(CAN_MOVE), prim(MODE)))]


def fail(tag, method, case, message):
    if (tag, method, message) not in seen:
        seen.add((tag, method, message))
        failures.append(f"{tag} {method} {case}: {message}")


def twin(rot):
    return {0: 1, 2: 1, 1: 0, 3: 0}.get(rot, rot)


def attempt(tag, method, case, fn, *args):
    try:
        return fn(*args)
    except Bad as e:
        fail(tag, method, case, str(e))
        return None


def check(stock, patched):
    for rot, wm, metrics, (w, h), can, mode, imm in itertools.product(range(-1, 5), (1, 0), (1, 0), SHAPES, (0, 1),
                                                                      (0, 1, 2), (0, 1)):
        case = f"rotation {rot} wm {wm} metrics {metrics} {w}x{h} canMove {can} mode {mode} immersive {imm}"
        for tag, root, is_patched in (("stock", stock, False), ("patched", patched, True)):
            events = attempt(tag, "P1", case, p1, f"{root}/{NB}", rot, wm, metrics, w, h, can, mode, imm)
            want = p1_want(is_patched, rot, wm, metrics, w, h, can, mode, imm)
            if events is not None and p1_result(events) != want:
                fail(tag, "P1", case, f"{p1_result(events)}, want {want}")
        got = attempt("patched", "P1", case, p1, f"{patched}/{NB}", rot, wm, metrics, w, h, can, mode, imm)
        movable = not wm or not metrics or (w != h and (can == 1 or mode == 0))
        srot, scan = (twin(rot), 1) if movable else (rot, can)
        base = attempt("stock", "P1", case, p1, f"{stock}/{NB}", srot, wm, metrics, w, h, scan, mode, imm)
        if got is not None and base is not None and no_gate(got) != no_gate(base):
            fail("patched", "P1", case, f"events differ from stock rotation {srot} canMove {scan}")
    for rot, (w, h), can, mode, car, nav, cutout, extra, status in itertools.product(
            range(4), SHAPES, (0, 1), (0, 1, 2), (0, 1), (1, 0), (0, 1), ("invisible", "none", "visible"), (0, 1)):
        case = (f"rotation {rot} {w}x{h} canMove {can} mode {mode} car {car} nav {nav} cutout {cutout} "
                f"extra {extra} statusBar {status}")
        for tag, root, is_patched in (("stock", stock, False), ("patched", patched, True)):
            events = attempt(tag, "P2", case, p2, f"{root}/{DL}", rot, w, h, can, mode, car, nav, cutout, extra, status)
            if events is not None and nav and not cutout and extra != "visible":
                want = p2_want(is_patched, rot, w, h, can, mode, car)
                if p2_result(events) != want:
                    fail(tag, "P2", case, f"{p2_result(events)}, want {want}")
        got = attempt("patched", "P2", case, p2, f"{patched}/{DL}", rot, w, h, can, mode, car, nav, cutout, extra, status)
        movable = nav and w != h and (can == 1 or mode == 0)
        if movable:
            srot, scan = (1 if w > h else twin(rot)), 1
        else:
            srot, scan = rot, can
        base = attempt("stock", "P2", case, p2, f"{stock}/{DL}", srot, w, h, scan, mode, car, nav, cutout, extra, status)
        if got is not None and base is not None and no_gate(got) != no_gate(base):
            fail("patched", "P2", case, f"events differ from stock rotation {srot} canMove {scan}")
    for rot, same, before in itertools.product(range(-1, 4), (0, 1), (0, 1)):
        case = f"rotation {rot} unchanged {same} from {before}"
        current = rot if same else 7
        for tag, root, is_patched in (("stock", stock, False), ("patched", patched, True)):
            events = attempt(tag, "P3", case, p3, f"{root}/{NV}", rot, current, before)
            want = before if same else (int(rot in (0, 2)) if is_patched else int(rot == 1))
            if events is not None and p3_result(events, before) != want:
                fail(tag, "P3", case, f"{p3_result(events, before)}, want {want}")
        srot = rot if same else twin(rot)
        got = attempt("patched", "P3", case, p3, f"{patched}/{NV}", rot, current, before)
        base = attempt("stock", "P3", case, p3, f"{stock}/{NV}", srot, srot if same else 7, before)
        if got is not None and base is not None and p3_events(got) != p3_events(base):
            fail("patched", "P3", case, f"events differ from stock rotation {srot}")


def methods_only(stock, patched):
    for f, sig in ((NB, P1), (DL, P2), (NV, P3)):
        a, b = split(f"{stock}/{f}"), split(f"{patched}/{f}")
        if list(a) != list(b):
            failures.append(f"{f}: the methods or their order differ")
            continue
        changed = [k for k in a if a[k] != b[k]]
        if changed != [sig]:
            failures.append(f"{f}: changed parts {changed}, want only {sig}")


stock_root, patched_root = sys.argv[1], sys.argv[2]
check(stock_root, patched_root)
methods_only(stock_root, patched_root)
for f in failures:
    print(f"navbar-check: {f}", file=sys.stderr)
sys.exit(1 if failures else 0)
