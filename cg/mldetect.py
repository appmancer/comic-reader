"""Balloon and text detection with a trained model (RT-DETR-v2, ONNX).

ogkalu/comic-text-and-bubble-detector, fine-tuned on ~11k manga, webtoon,
manhua and WESTERN comic pages. Classes:
    0 bubble       the balloon shape itself
    1 text_bubble  lettering inside a balloon
    2 text_free    lettering with no balloon (captions, sound effects)

text_free covers the case that needed a separate hand-built detector
(cg/invtext.py) and bubble/text_bubble replace the threshold stack in
cg/detect.py. Kept behind its own module so the two can be compared.
"""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path: sys.path.insert(0, ROOT)

import numpy as np
from PIL import Image
import onnxruntime as ort

MODEL = os.path.join(ROOT, "models", "detector.onnx")
CLASSES = {0: "bubble", 1: "text_bubble", 2: "text_free"}
_SESSION = None


def session(path=MODEL):
    global _SESSION
    if _SESSION is None:
        opts = ort.SessionOptions()
        opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        _SESSION = ort.InferenceSession(path, opts, providers=["CPUExecutionProvider"])
    return _SESSION


def detect(image_path, size=640, min_score=0.35):
    """Returns [(cls_name, score, (x0,y0,x1,y1) normalised 0-1), ...]."""
    img = Image.open(image_path).convert("RGB")
    w, h = img.size
    arr = np.asarray(img.resize((size, size), Image.BILINEAR), dtype=np.float32) / 255.0
    arr = np.transpose(arr, (2, 0, 1))[None]                    # NCHW
    sizes = np.array([[w, h]], dtype=np.int64)                  # boxes come back inoriginal coords

    labels, boxes, scores = session().run(
        None, {"images": arr, "orig_target_sizes": sizes})
    labels, boxes, scores = labels[0], boxes[0], scores[0]

    out = []
    for lab, box, sc in zip(labels, boxes, scores):
        if sc < min_score:
            continue
        x0, y0, x1, y1 = box
        out.append((CLASSES.get(int(lab), str(lab)), float(sc),
                    (max(0.0, x0 / w), max(0.0, y0 / h),
                     min(1.0, x1 / w), min(1.0, y1 / h))))
    out.sort(key=lambda r: (r[2][1], r[2][0]))
    return out


if __name__ == "__main__":
    import time
    for p in sys.argv[1:]:
        t = time.time()
        res = detect(p)
        el = time.time() - t
        by = {}
        for c, _, _ in res:
            by[c] = by.get(c, 0) + 1
        print(f"{os.path.basename(p)}  {len(res)} detections in {el:.2f}s  {by}")
        for c, sc, b in res:
            print(f"   {c:11s} {sc:.2f}  x{b[0]:.3f}-{b[2]:.3f}  y{b[1]:.3f}-{b[3]:.3f}")
