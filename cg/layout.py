"""Choose a page layout by generating candidates and scoring them.

There is no single threshold that works for every page, and we have the
counter-examples to prove it:

  Savage Dragon #1 p10  tier gutter is 19px thick, peaks at a 75% dark run
  2000AD Absalom p7     panel border is 2px; dark crowd art reaches 44%
                        and MUST be rejected

A detector strict enough for Absalom finds one panel on Savage Dragon; one
loose enough for Savage Dragon splits Absalom on its artwork. So we run
several parameter sets and score the results against the balloons we already
found, which are far more reliable than the layout.
"""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path: sys.path.insert(0, ROOT)

import cg.xycut as X
from cg.detect import W, DARK, BRIGHT

# name, minfrac (how much of the span a rule must cover), maxthick (px)
PARAM_SETS = [
    ("strict",  0.92, 16),
    ("thick",   0.92, 34),
    ("relaxed", 0.74, 34),
    ("loose",   0.62, 46),
]


def _overlap(a, b):
    w = min(a[2], b[2]) - max(a[0], b[0])
    h = min(a[3], b[3]) - max(a[1], b[1])
    return w * h if w > 0 and h > 0 else 0


def absorb_slivers(panels, page_area, min_share=0.014):
    """Merge tiny panels into the neighbour they share the longest edge with.

    Balloons routinely overhang a panel edge, which leaves a thin strip beside
    the panel. That strip is detector noise, not a panel - but penalising a
    layout for it throws away an otherwise better one.
    """
    panels = list(panels)
    changed = True
    while changed and len(panels) > 1:
        changed = False
        for i, p in enumerate(panels):
            if (p[2] - p[0]) * (p[3] - p[1]) >= min_share * page_area:
                continue
            best, best_edge = None, 0
            for j, q in enumerate(panels):
                if i == j:
                    continue
                # Merge only when the two tile EXACTLY - same extent on the
                # perpendicular axis and touching on the shared one. A plain
                # bounding-box union silently swallows a third panel, which is
                # how page 7 ended up with panel 3 covering 100% of panel 2 and
                # the reader seeing a beat entirely inside its predecessor.
                aligned_v = abs(p[1] - q[1]) <= 2 and abs(p[3] - q[3]) <= 2
                aligned_h = abs(p[0] - q[0]) <= 2 and abs(p[2] - q[2]) <= 2
                touch_v = aligned_v and (abs(p[0] - q[2]) <= 2 or abs(p[2] - q[0]) <= 2)
                touch_h = aligned_h and (abs(p[1] - q[3]) <= 2 or abs(p[3] - q[1]) <= 2)
                if not (touch_v or touch_h):
                    continue
                edge = (p[3] - p[1]) if touch_v else (p[2] - p[0])
                if edge > best_edge:
                    best, best_edge = j, edge
            if best is None:
                continue  # leave it; better a sliver than an overlapping panel
            q = panels[best]
            panels[best] = (min(p[0], q[0]), min(p[1], q[1]),
                            max(p[2], q[2]), max(p[3], q[3]))
            panels.pop(i)
            changed = True
            break
    return panels


def _run_strength(raw, h, pos, horiz, lo, hi):
    """How convincingly is there a rule at [pos] spanning lo..hi?

    Returns the best evidence over a few rows/cols around pos, as a fraction:
    either a long dark run (drawn border / black gutter) or a bright span
    (white gutter). This is the number that separates a real boundary from a
    coincidence, and it is what the accept/reject threshold was throwing away.
    """
    span = hi - lo
    if span <= 0:
        return 0.0
    best = 0.0
    for d in (-2, -1, 0, 1, 2):
        q = pos + d
        if horiz:
            if not (0 <= q < h):
                continue
            row = raw[q * W:(q + 1) * W]
            vals = [row[i] for i in range(lo, hi)]
        else:
            if not (0 <= q < W):
                continue
            vals = [raw[i * W + q] for i in range(lo, hi)]
        run = cur = 0
        for v in vals:
            cur = cur + 1 if v < DARK else 0
            if cur > run:
                run = cur
        bright = sum(1 for v in vals if v >= BRIGHT) / span
        best = max(best, run / span, bright)
    return best


def boundary_evidence(raw, h, panels, region):
    """Mean strength of the boundaries between ADJACENT panel pairs.

    Measuring a vertical cut over the whole page height dilutes it badly - a
    tier-2 border only spans that tier. Each boundary is only asserted between
    the two panels that share it, so that is the extent to measure over.
    """
    strengths = []
    for i, a in enumerate(panels):
        for b in panels[i + 1:]:
            vy = min(a[3], b[3]) - max(a[1], b[1])   # shared vertical extent
            vx = min(a[2], b[2]) - max(a[0], b[0])   # shared horizontal extent
            if vy > 8 and abs(a[2] - b[0]) <= 2:     # b is right of a
                strengths.append(_run_strength(
                    raw, h, a[2], False, max(a[1], b[1]), min(a[3], b[3])))
            elif vy > 8 and abs(b[2] - a[0]) <= 2:   # a is right of b
                strengths.append(_run_strength(
                    raw, h, a[0], False, max(a[1], b[1]), min(a[3], b[3])))
            elif vx > 8 and abs(a[3] - b[1]) <= 2:   # b is below a
                strengths.append(_run_strength(
                    raw, h, a[3], True, max(a[0], b[0]), min(a[2], b[2])))
            elif vx > 8 and abs(b[3] - a[1]) <= 2:   # a is below b
                strengths.append(_run_strength(
                    raw, h, a[1], True, max(a[0], b[0]), min(a[2], b[2])))
    if not strengths:
        return 1.0, 0
    return sum(strengths) / len(strengths), len(strengths)


def score(panels, balloons, page_area, evidence=1.0):
    """Higher is better. Balloons are the ground truth we trust."""
    if not panels:
        return -1e9, {}

    n = len(panels)
    # A balloon straddling a panel border means we cut through a panel.
    straddle = 0
    for b in balloons:
        barea = max((b[2] - b[0]) * (b[3] - b[1]), 1)
        hits = sum(1 for p in panels if _overlap(p, b) / barea > 0.12)
        if hits > 1:
            straddle += 1
    straddle_pen = 220.0 * straddle / max(len(balloons), 1)

    # Slivers are almost always detector noise, not panels.
    slivers = sum(1 for p in panels
                  if (p[2] - p[0]) * (p[3] - p[1]) < 0.012 * page_area)
    sliver_pen = 45.0 * slivers

    # A page with dialogue and one panel is a collapse; 30 panels is confetti.
    if n == 1:
        count_pen = 130.0 if balloons else 0.0
    elif n <= 12:
        count_pen = 0.0
    else:
        count_pen = 14.0 * (n - 12)

    # Reward resolving detail only in proportion to how well-evidenced the
    # boundaries are. Splitting on weak evidence is worse than not splitting:
    # a layout asserting 13 panels on 62%-strength cuts should lose to one
    # asserting 5 on 80%-strength cuts.
    detail = 18.0 * min(n, 8) * max(0.0, (evidence - 0.55) / 0.45)

    # Every extra panel must earn its place. Merging adjacent panels is fine
    # when the merge still fits the viewport, so a layout that splits further
    # on comparable evidence is not automatically better.
    per_panel_cost = 4.5 * n

    total = detail - straddle_pen - sliver_pen - count_pen - per_panel_cost
    return total, {
        "panels": n, "straddle": straddle, "slivers": slivers,
        "detail": round(detail, 1), "straddle_pen": round(straddle_pen, 1),
        "sliver_pen": round(sliver_pen, 1), "count_pen": round(count_pen, 1),
    }


def best_layout(raw, h, balloons, verbose=False):
    """Return (panels, chosen_name, score, all_results)."""
    region = X.trim(raw, h)
    page_area = W * h
    results = []
    for name, minfrac, maxthick in PARAM_SETS:
        panels = _split_with(raw, h, region, minfrac, maxthick)
        panels = absorb_slivers(panels, page_area)
        ev, nb = boundary_evidence(raw, h, panels, region)
        s, detail = score(panels, balloons, page_area, ev)
        detail["evidence"] = round(ev, 3)
        results.append((s, name, panels, detail))
        if verbose:
            print(f"    {name:8s} -> {len(panels):2d} panels  score {s:7.1f}  {detail}")
    results.sort(key=lambda r: -r[0])
    best = results[0]
    return best[2], best[1], best[0], results


def _split_with(raw, h, region, minfrac, maxthick):
    """Run the X-Y cut with one parameter set (xycut.cuts takes them directly)."""
    original = X.cuts

    def patched(raw_, h_, reg, horiz, mf=minfrac, mt=maxthick):
        return original(raw_, h_, reg, horiz, mf, mt)

    X.cuts = patched
    try:
        return X.split(raw, h, region)
    finally:
        X.cuts = original


if __name__ == "__main__":
    from cg.detect import load, text_regions
    from cg.unchain import unchain
    for path in sys.argv[1:]:
        raw, h = load(path)
        balloons = []
        for r in text_regions(raw, h):
            balloons += unchain(raw, h, r)
        print(f"\n{os.path.basename(path)}  ({len(balloons)} balloons)")
        panels, name, s, _ = best_layout(raw, h, balloons, verbose=True)
        print(f"  CHOSEN: {name}  ({len(panels)} panels, score {s:.1f})")
        for i, p in enumerate(panels, 1):
            print(f"     {i}. {p}  {p[2]-p[0]}x{p[3]-p[1]}")
