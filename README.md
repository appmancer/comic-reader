# comic-reader

Deterministic guided-view generation for comics — find the speech balloons, derive the
panel layout, and produce an ordered sequence of "beats" to step a reader through a page.

No ML, no OpenCV, no numpy. Pure Python + ImageMagick (`convert`). ~180ms/page.

Validated 27 Aug 2026 against **Panels** (iOS) *Panels View* on Halo Jones and
Savage Dragon #1 — this produces noticeably better beats. Panels tends to show the top
~50% of a page as the first beat and doesn't zoom close enough to keep lettering legible
on a small screen.

## Status: working prototype, NOT production

Honest caveats:

- Only ~34 pages tested, across two issues (2000AD *Absalom*, Savage Dragon #1).
- Several thresholds were tuned against **Savage Dragon #1 page 13** specifically.
  They will not all survive a broader sample.
- On the Absalom run, 6 of 24 pages produced no beats at all.
- Balloon detection has good recall but mediocre precision — shirt collars, vehicle
  windows and bright art get picked up. No cheap statistical filter separated them.
- `cg/planner.py` has a **hand-specified beat list for sd13**. The bleed/expansion rules
  in it are general; wiring them to the automatic panel grouping in `cg/xycut.py` is
  the main outstanding work.

## Layout

```
cg/detect.py    balloon detection: connected components over bright regions,
                filtered on the "perforated blob" signature (see below)
cg/unchain.py   splits merged balloon chains into individual balloons at their tails
cg/xycut.py     recursive X-Y cut -> panels in true reading order
cg/planner.py   beat packing + bleed rules  (sd13 beat list is hardcoded)
cg/render.py    draws overlays and renders beat sequences
experiments/    superseded iterations, kept for the record. Archival - may not run.
samples/        key result images from the session
work/           scratch: rendered pages, output frames  (override with $CG_WORK)
```

## Detection: trained model vs threshold stack

`cg/mldetect.py` runs **ogkalu/comic-text-and-bubble-detector** (RT-DETR-v2,
ONNX), fine-tuned on ~11k manga, webtoon, manhua and Western comic pages.
Classes: `bubble`, `text_bubble`, `text_free`.

Setup (model is 161MB, gitignored):

```bash
python3 -m venv .venv && ./.venv/bin/pip install onnxruntime numpy pillow
mkdir -p models && curl -L -o models/detector.onnx \
  https://huggingface.co/ogkalu/comic-text-and-bubble-detector/resolve/main/detector.onnx
./.venv/bin/python -m cg.export /path/to/comic.pdf 1 40
```

Measured against known ground truth, 1.8s/page on CPU:

| page | truth | model | threshold stack |
| --- | --- | --- | --- |
| i100 p1 cover | 0 | **0** | 26 (all false) |
| i100 p4 dense splash | 2 | **2** | 29 (27 false) |
| i100 p6 story | 20 | **20** | 24 |
| i100 p16 story | 14 | **14** | 14 (after tuning) |
| sd1 p13 story | 13 | 15 | 13 |
| sd1 p15 splash | 9 | **9** | 6 (needed invtext.py) |
| absalom p7 | 9 | **9** | 11 |

`cg/detect.py` (the hand-tuned stack) still runs when onnxruntime or the model
is absent. Keep it: it is the fallback, and the comparison.

ONNX not torch, deliberately - onnxruntime is lighter and has mobile bindings,
so the same model can run on-device, which is required for a published app
where strangers analyse their own libraries.

## Running

```bash
cd ~/Workspace/comic-reader
pdftoppm -jpeg -r 100 -f 13 -l 13 "/path/to/comic.pdf" work/sd/p

python3 -m cg.xycut   work/sd/p-13.jpg    # panels in reading order
python3 -m cg.unchain work/sd/p-13.jpg    # split a balloon chain
python3 -m cg.planner                     # beats + rendered frames into work/
```

## What was learned the hard way

Three times I wrote a strict test where a tolerant one was needed:

- **Balloons are not solid white blobs.** Their own lettering perforates them, so fill
  ratio runs 0.2–0.55. High fill means a blank art highlight — the opposite of a balloon.
- **Gutter tests must be percentile-based, never min/max.** One 4px balloon tail
  overhanging into a gutter destroys a min/max uniformity test on an otherwise
  97%-clean column.
- **Not every comic has white gutters.** Savage Dragon separates tiers with drawn black
  rules over continuous art — rows between tiers are 96–98% *ink*. Detect thin long dark
  runs instead; thickness separates a 2px border from 14 rows of dark crowd art.

And one filter that was actively harmful: a "text rhythm" regularity test rejected
stacked balloon pairs, including the largest text block on the page. Removed.

**Reading order must come from an X-Y cut tree traversal, not from sorting boxes by
(y, x).** Savage Dragon #1 p13 has a full-height left column that reads *entirely first*;
any geometric sort interleaves it with the right-hand panels and scrambles the dialogue.

**Balloon detection generalises across publishers. Panel/layout detection does not.**
When layout under-segments, reading order degrades *quietly* — the page looks plausible
and reads slightly wrong, which is much harder to catch than a loud failure.

## Beat rules (settled with the user, do not re-litigate)

| Rule | Value |
| --- | --- |
| Forward bleed into unread balloons | ≤ 20% of the balloon visible |
| Backward bleed into already-read balloons | ≤ 12% |
| Beat's own panel as share of beat area | ≥ 50% |
| Overlap with already-shown area | ≤ 25% |

- Sequence is **full page → each beat → full page**. Never skip page area.
- Black bars are fine. Some scale variation between beats is fine.
- A little overlap between beats is *good* — it aids continuity.
- Bleed **forward, never backward**: tease what's coming, don't re-show what's read.
- Visibility must be measured as **visible bright-pixel area of the individual balloon**.
  Measuring against a merged chain's bounding box reads 19% when the truth is 45%.

## Design decisions for the app

- Store **balloon boxes + panel geometry** in the sidecar, *not* finished beats. Compute
  beats at read time for the actual screen, choosing zoom so lettering hits a target
  height. One analysis then serves phone/tablet, portrait/landscape. Baking beats at
  analysis time reproduces Panels' "not close enough to read on an iPad mini" problem.
- **Local database is authoritative**, keyed by a cheap composite identity
  (size + hash of first 64KB + page count) so it survives renames and works on
  read-only/remote sources. Sidecar is an export format, never a dependency.
- Target: Flutter (PDF page→bitmap via PDFium is off the shelf; React Native has no
  good equivalent and 77% of the test library is PDF). iOS builds via GitHub Actions
  macOS runners, free for public repos; TestFlight for device installs, no Mac needed.
- Support local files and cloud via the OS pickers (iOS document picker + security-scoped
  bookmarks; Android SAF tree URIs — *not* MANAGE_EXTERNAL_STORAGE). OPDS for
  Komga/Kavita/Calibre-Web libraries.
