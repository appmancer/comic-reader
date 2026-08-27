"""Split a merged balloon chain into individual balloons by cutting at the tails."""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path: sys.path.insert(0, ROOT)
WORK = os.environ.get('CG_WORK', os.path.join(ROOT, 'work'))
import sys

from cg.detect import load, W, BRIGHT

def unchain(raw,h,reg,min_body=18,min_rows=10):
    x0,y0,x1,y1=reg
    ext=[]
    for y in range(y0,y1):
        xs=[x for x in range(x0,x1) if raw[y*W+x]>=BRIGHT]
        ext.append((min(xs),max(xs)+1) if xs else None)
    body=[e is not None and (e[1]-e[0])>=min_body for e in ext]
    runs=[];s=None
    for i,f in enumerate(body):
        if f and s is None: s=i
        elif not f and s is not None:
            if i-s>=min_rows: runs.append((s,i))
            s=None
    if s is not None and len(body)-s>=min_rows: runs.append((s,len(body)))
    out=[]
    for a,b in runs:
        seg=[ext[i] for i in range(a,b) if ext[i]]
        if not seg: continue
        out.append((min(p[0] for p in seg), y0+a, max(p[1] for p in seg), y0+b))
    return out or [reg]

if __name__=="__main__":
    raw,h=load(f"{sys.argv[1]}")
    for r in unchain(raw,h,(219,27,410,441)):
        print(f"  balloon {r}  {r[2]-r[0]}x{r[3]-r[1]}")
