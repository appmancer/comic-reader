"""Detect bright lettering on a dark ground (captions with no balloon).

The balloon detector looks for a bright blob perforated by dark lettering.
Splash pages like Savage Dragon #1 p15 invert that: white narration floats
directly on the page's black background, with no box at all. Measured there,
caption areas run 3-5% bright / 83-91% dark, where a normal balloon is
24% bright / 36% dark - the detector can never find them.

So instead of blobs, find cells that look like lettering on a dark ground and
group them into blocks.
"""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path: sys.path.insert(0, ROOT)

from cg.detect import W, BRIGHT, DARK

CELL = 7


def inverse_text_regions(raw, h, cell=CELL,
                         min_bright=0.04, max_bright=0.42, min_dark=0.45):
    """Blocks of bright lettering sitting on a dark ground."""
    gw, gh = W // cell, h // cell
    texty = [False] * (gw * gh)
    for gy in range(gh):
        for gx in range(gw):
            b = d = n = 0
            for y in range(gy * cell, min((gy + 1) * cell, h)):
                row = raw[y * W:(y + 1) * W]
                for x in range(gx * cell, min((gx + 1) * cell, W)):
                    v = row[x]
                    n += 1
                    if v >= BRIGHT: b += 1
                    elif v < DARK: d += 1
            if n == 0:
                continue
            fb, fd = b / n, d / n
            texty[gy * gw + gx] = (min_bright <= fb <= max_bright and fd >= min_dark)

    # dilate by one cell so letters in a word join up
    grown = list(texty)
    for gy in range(gh):
        for gx in range(gw):
            if not texty[gy * gw + gx]:
                continue
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    ny, nx = gy + dy, gx + dx
                    if 0 <= ny < gh and 0 <= nx < gw:
                        grown[ny * gw + nx] = True

    seen = [False] * (gw * gh)
    out = []
    for gy in range(gh):
        for gx in range(gw):
            i = gy * gw + gx
            if not grown[i] or seen[i]:
                continue
            stack, cells = [(gy, gx)], []
            seen[i] = True
            while stack:
                cy, cx = stack.pop()
                cells.append((cy, cx))
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = cy + dy, cx + dx
                    j = ny * gw + nx
                    if 0 <= ny < gh and 0 <= nx < gw and grown[j] and not seen[j]:
                        seen[j] = True
                        stack.append((ny, nx))
            # must contain real lettering cells, not just dilation
            core = sum(1 for cy, cx in cells if texty[cy * gw + cx])
            if core < 6:
                continue
            ys = [c[0] for c in cells]; xs = [c[1] for c in cells]
            x0, x1 = min(xs) * cell, (max(xs) + 1) * cell
            y0, y1 = min(ys) * cell, (max(ys) + 1) * cell
            if (x1 - x0) < 24 or (y1 - y0) < 12:
                continue
            if (x1 - x0) * (y1 - y0) > 0.25 * W * h:
                continue
            if not _stroke_like(raw, h, x0, y0, min(x1, W), min(y1, h)):
                continue
            out.append((x0, y0, min(x1, W), min(y1, h)))
    out.sort(key=lambda r: (r[1], r[0]))
    return out


def _stroke_like(raw, h, x0, y0, x1, y1, max_mean=3.2, max_p90=7):
    """Bright runs must look like letter strokes, not chunks of artwork.

    Measured on Savage Dragon p15: captions give mean run 2.0-2.1 and p90 of 4;
    the laundry on the washing line gives 4.4-5.4 / 12-19, and highlights on
    Dragon's face give 18.9 / 33. Thin and regular is the whole signal.
    """
    runs = []
    for y in range(y0, y1):
        row = raw[y * W:(y + 1) * W]
        cur = 0
        for x in range(x0, x1):
            if row[x] >= BRIGHT:
                cur += 1
            elif cur:
                runs.append(cur)
                cur = 0
        if cur:
            runs.append(cur)
    if len(runs) < 20:
        return False
    runs.sort()
    mean = sum(runs) / len(runs)
    p90 = runs[int(len(runs) * 0.9)]
    return mean <= max_mean and p90 <= max_p90


if __name__ == "__main__":
    from cg.detect import load
    for path in sys.argv[1:]:
        raw, h = load(path)
        rs = inverse_text_regions(raw, h)
        print(f"{os.path.basename(path)}: {len(rs)} inverse-text blocks")
        for r in rs:
            print(f"   y{r[1]/h:.2f} x{r[0]/W:.2f}-{r[2]/W:.2f}  "
                  f"{r[2]-r[0]}x{r[3]-r[1]}")
