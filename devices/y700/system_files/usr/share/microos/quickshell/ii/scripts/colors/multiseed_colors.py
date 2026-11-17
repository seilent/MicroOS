#!/usr/bin/env python3
import sys, json, argparse, importlib
from PIL import Image
from materialyoucolor.quantize import QuantizeCelebi
from materialyoucolor.score.score import Score, ScoreOptions
from materialyoucolor.hct import Hct
from materialyoucolor.palettes.tonal_palette import TonalPalette
from materialyoucolor.dynamiccolor.material_dynamic_colors import MaterialDynamicColors


def snake(name):
    out = []
    for i, c in enumerate(name):
        if c.isupper() and i > 0:
            out.append("_")
        out.append(c.lower())
    return "".join(out)


def hue_dist(a, b):
    d = abs(a - b) % 360.0
    return min(d, 360.0 - d)


def scheme_class(scheme_arg):
    name = (scheme_arg or "").replace("scheme-", "scheme_")
    try:
        mod = importlib.import_module(f"materialyoucolor.scheme.{name}")
        cls_name = "Scheme" + "".join(p.capitalize() for p in name.split("_")[1:])
        return getattr(mod, cls_name)
    except Exception:
        from materialyoucolor.scheme.scheme_tonal_spot import SchemeTonalSpot
        return SchemeTonalSpot


def prominent_clusters(quantized, min_chroma, tone_lo, tone_hi, hue_merge):
    """Cluster sufficiently-chromatic colors by hue, summing population, so a large
    region split into shades counts once. Returns clusters sorted by population desc:
    [ [representative_hct, population], ... ]. The representative is the cluster's
    highest-population member (fringe high-chroma spots stay low and lose)."""
    candidates = []
    for argb, pop in quantized.items():
        h = Hct.from_int(argb)
        if h.chroma >= min_chroma and tone_lo <= h.tone <= tone_hi:
            candidates.append((h, pop))
    candidates.sort(key=lambda x: x[1], reverse=True)

    clusters = []
    for h, pop in candidates:
        for c in clusters:
            if hue_dist(c[0].hue, h.hue) <= hue_merge:
                c[1] += pop
                break
        else:
            clusters.append([h, pop])
    clusters.sort(key=lambda c: c[1], reverse=True)
    return clusters


def most_prominent(clusters, avoid_hues, min_sep, used):
    for h, pop in clusters:
        if id(h) in used:
            continue
        if all(hue_dist(h.hue, a) >= min_sep for a in avoid_hues):
            used.add(id(h))
            return h, pop
    return None, 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--mode", default="dark")
    ap.add_argument("--scheme", default="scheme-vibrant")
    ap.add_argument("--output", required=True)
    ap.add_argument("--min-hue-sep", type=float, default=40.0)
    ap.add_argument("--min-chroma", type=float, default=20.0)
    ap.add_argument("--accent-chroma-cap", type=float, default=32.0)
    ap.add_argument("--hue-merge", type=float, default=30.0)
    ap.add_argument("--min-pop", type=float, default=0.05)
    a = ap.parse_args()

    dark = a.mode == "dark"

    img = Image.open(a.image).convert("RGB")
    img.thumbnail((256, 256))
    quantized = QuantizeCelebi(list(img.getdata()), 128)

    # Primary stays the matugen/Score seed so it matches matugen's other outputs.
    ranked = Score.score(quantized, ScoreOptions(desired=4, fallback_color_argb=0xFF4285F4, filter=True, dislike_filter=True))
    primary = Hct.from_int(ranked[0])

    total = sum(quantized.values()) or 1
    clusters = prominent_clusters(quantized, a.min_chroma, 15.0, 92.0, a.hue_merge)
    eligible = [c for c in clusters if c[1] >= a.min_pop * total]
    used = set()
    secondary, sec_pop = most_prominent(eligible, [primary.hue], a.min_hue_sep, used)
    avoid = [primary.hue] + ([secondary.hue] if secondary else [])
    tertiary, ter_pop = most_prominent(eligible, avoid, a.min_hue_sep, used)

    scheme = scheme_class(a.scheme)(primary, dark, 0.0)
    applied = []
    if secondary is not None:
        scheme.secondary_palette = TonalPalette.from_hue_and_chroma(secondary.hue, min(secondary.chroma, a.accent_chroma_cap))
        applied.append("secondary")
    if tertiary is not None:
        scheme.tertiary_palette = TonalPalette.from_hue_and_chroma(tertiary.hue, min(tertiary.chroma, a.accent_chroma_cap))
        applied.append("tertiary")

    colors = {}
    for key in vars(MaterialDynamicColors).keys():
        dc = getattr(MaterialDynamicColors, key)
        if hasattr(dc, "get_hct"):
            r, g, b, _ = dc.get_hct(scheme).to_rgba()
            colors[snake(key)] = "#%02x%02x%02x" % (r, g, b)

    with open(a.output) as f:
        base = json.load(f)
    for k in list(base.keys()):
        if k in colors:
            base[k] = colors[k]
    with open(a.output, "w") as f:
        json.dump(base, f, indent=2)

    def line(label, h, pop):
        if h is None:
            return f"{label:<9} none (fell back to scheme-derived)"
        return f"{label:<9} hue={h.hue:6.1f} chroma={h.chroma:5.1f} pop={100.0 * pop / total:4.1f}%"

    print(line("primary", primary, 0))
    print(line("secondary", secondary, sec_pop))
    print(line("tertiary", tertiary, ter_pop))
    print("applied:", applied or "none (mono-hue wallpaper)")


if __name__ == "__main__":
    main()
