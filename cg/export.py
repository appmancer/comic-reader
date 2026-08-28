"""Emit sidecar guide JSON consumed by the Flutter app (app/lib/model/guide.dart).

Stores GEOMETRY - panels and balloons in normalised page coordinates, plus a
per-balloon line height. Beats are deliberately NOT stored: the app computes
them at read time for the actual screen, so one analysis serves phone and
tablet, portrait and landscape.
"""
import os, sys, json, math, statistics, subprocess, hashlib
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path: sys.path.insert(0, ROOT)

from cg.detect import load, text_regions, W, BRIGHT, DARK
from cg.unchain import unchain
import cg.xycut as X
from cg.layout import best_layout

SCHEMA_VERSION = 1


def line_height(raw, h, r):
    """Median height of a lettering line inside a balloon, in page-height units."""
    x0, y0, x1, y1 = r
    runs, start = [], None
    for y in range(y0, y1):
        row = raw[y * W:(y + 1) * W]
        dark = sum(1 for x in range(x0, x1) if row[x] < DARK) / max(x1 - x0, 1)
        on = dark > 0.05
        if on and start is None:
            start = y
        elif not on and start is not None:
            runs.append(y - start); start = None
    if start is not None:
        runs.append(y1 - start)
    # A line of comic lettering is roughly 1-3% of page height. Runs outside
    # that band are noise (JPEG speckle at the low end, a whole balloon or a
    # solid dark region at the high end) and produced values like 0.0028 and
    # 0.0881 that drove the planner to absurd zoom levels. Report 0 = unknown
    # rather than a wrong number; the planner treats 0 as "no constraint".
    lo, hi = max(3, int(0.006 * h)), int(0.06 * h)
    runs = [r_ for r_ in runs if lo <= r_ <= hi]
    return (statistics.median(runs) / h) if runs else 0.0


DETAIL_GW, DETAIL_GH = 12, 18


def detail_grid(raw, h, gw=DETAIL_GW, gh=DETAIL_GH, box=8):
    """Edge density per cell, 0-255. A proxy for "is there anything here".

    Flat sky, shadow and grass score low; faces, hands, machinery and lettering
    score high. Measured at a coarse scale (box=8) so fine texture averages
    away: at full resolution grass outscored everything on Savage Dragon p12,
    which is the opposite of useful.

    SPECULATIVE AND UNVALIDATED. It only agreed with human judgement on that
    page at the coarsest setting and by a 13% margin, which may be tuning
    rather than signal. A deliberately empty, ominous panel is exactly the
    storytelling beat it would wrongly discard. Off by default in the planner.
    """
    def avg(x, y):
        t = n = 0
        for dy in range(box):
            for dx in range(box):
                t += raw[min(y + dy, h - 1) * W + min(x + dx, W - 1)]
                n += 1
        return t / n

    grid = []
    for gy in range(gh):
        y0, y1 = gy * h // gh, (gy + 1) * h // gh
        for gx in range(gw):
            x0, x1 = gx * W // gw, (gx + 1) * W // gw
            edges = n = 0
            for y in range(y0, y1, 2 * box):
                prev = None
                for x in range(x0, x1, 2 * box):
                    v = avg(x, y)
                    if prev is not None and abs(v - prev) > 28:
                        edges += 1
                    prev = v
                    n += 1
            grid.append(min(255, round(600.0 * edges / max(n, 1))))
    return grid


def owner_panel(rect, panels):
    cx, cy = (rect[0] + rect[2]) / 2, (rect[1] + rect[3]) / 2
    for i, p in enumerate(panels):
        if p[0] <= cx <= p[2] and p[1] <= cy <= p[3]:
            return i
    if not panels:
        return 0
    return min(range(len(panels)),
               key=lambda i: (cx - (panels[i][0] + panels[i][2]) / 2) ** 2
                           + (cy - (panels[i][1] + panels[i][3]) / 2) ** 2)


def analyse_page(path, index):
    raw, h = load(path)
    balloons_raw = []
    for r in text_regions(raw, h):
        balloons_raw += unchain(raw, h, r)
    # Candidate layouts scored against the balloons; no single threshold works
    # across pages (SD p10 needs a 75%-strength 19px gutter accepted, Absalom
    # needs 44% dark art rejected).
    panels, chosen, _score, _all = best_layout(raw, h, balloons_raw)
    panels = panels or [(0, 0, W, h)]

    def n(rect):
        return [round(rect[0] / W, 5), round(rect[1] / h, 5),
                round(rect[2] / W, 5), round(rect[3] / h, 5)]

    balloons = [{
        "rect": n(b),
        "panel": owner_panel(b, panels),
        "line_height": round(line_height(raw, h, b), 5),
    } for b in balloons_raw]

    # Confidence: a page where layout collapsed to one panel while carrying many
    # balloons is the quiet-failure case - the app should fall back to whole page.
    conf = 1.0
    if len(panels) <= 1 and len(balloons) >= 6:
        conf = 0.3
    elif not balloons:
        conf = 0.0

    return {
        "index": index,
        "layout": chosen,
        "detail": {"w": DETAIL_GW, "h": DETAIL_GH,
                   "cells": detail_grid(raw, h)},
        "panels": [{"rect": n(p)} for p in panels],
        "balloons": balloons,
        "confidence": conf,
    }


def cheap_identity(path, page_count):
    """Must match cheapIdentity() in app/lib/source/comic_source.dart."""
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        head = f.read(65536)
    hsh = 0xcbf29ce484222325
    prime, mask = 0x100000001b3, 0xFFFFFFFFFFFFFFFF
    for b in head:
        hsh = ((hsh ^ b) * prime) & mask
    for v in (size, page_count):
        x = v
        for _ in range(8):
            hsh = ((hsh ^ (x & 0xFF)) * prime) & mask
            x >>= 8
    return format(hsh, "016x")


def render_pdf_pages(pdf, out_dir, first, last, dpi=100):
    os.makedirs(out_dir, exist_ok=True)
    subprocess.run(["pdftoppm", "-jpeg", "-r", str(dpi), "-f", str(first),
                    "-l", str(last), pdf, os.path.join(out_dir, "p")], check=True)
    return sorted(f for f in os.listdir(out_dir) if f.endswith(".jpg"))


def main():
    if len(sys.argv) < 2:
        print("usage: python3 -m cg.export <comic.pdf> [first] [last]")
        return 1
    pdf = sys.argv[1]
    first = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    last = int(sys.argv[3]) if len(sys.argv) > 3 else first + 9

    work = os.path.join(ROOT, "work", "export")
    names = render_pdf_pages(pdf, work, first, last)
    total = int(subprocess.run(["pdfinfo", pdf], capture_output=True, text=True)
                .stdout.split("Pages:")[1].split()[0])

    pages = []
    for name in names:
        idx = int(''.join(c for c in name if c.isdigit())) - 1  # pdftoppm is 1-based
        pages.append(analyse_page(os.path.join(work, name), idx))
        print(f"  page {idx+1}: {len(pages[-1]['panels'])} panels "
              f"({pages[-1]['layout']}), {len(pages[-1]['balloons'])} balloons, "
              f"conf {pages[-1]['confidence']}")

    guide = {
        "version": SCHEMA_VERSION,
        "source_id": cheap_identity(pdf, total),
        "page_count": total,
        "pages": pages,
    }
    stem = os.path.splitext(pdf)[0]
    out = stem + ".guide.json"
    with open(out, "w") as f:
        json.dump(guide, f, separators=(",", ":"))
    print(f"\nwrote {out}  ({os.path.getsize(out)} bytes, {len(pages)} pages)")
    print(f"source_id {guide['source_id']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
