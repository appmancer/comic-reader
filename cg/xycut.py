"""Ordered recursive X-Y cut -> panels in true reading order."""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path: sys.path.insert(0, ROOT)
WORK = os.environ.get('CG_WORK', os.path.join(ROOT, 'work'))
import sys, math

from cg.detect import load, W, DARK, BRIGHT

MIN_PANEL = 55          # nothing smaller than this is a panel

def trim(raw,h):
    """strip uniform page margins of any colour"""
    def uni(vals): return (max(vals)-min(vals))<=26
    def col(x): return uni([raw[y*W+x] for y in range(0,h,3)])
    def row(y):
        r=raw[y*W:(y+1)*W]; return uni([r[x] for x in range(0,W,3)])
    x0=0
    while x0<W-1 and col(x0): x0+=1
    x1=W
    while x1>x0+1 and col(x1-1): x1-=1
    y0=0
    while y0<h-1 and row(y0): y0+=1
    y1=h
    while y1>y0+1 and row(y1-1): y1-=1
    return (x0,y0,x1,y1)

def cuts(raw,h,reg,horiz,minfrac=0.92,maxthick=16):
    x0,y0,x1,y1=reg
    span=(x1-x0) if horiz else (y1-y0)
    perp=(y1-y0) if horiz else (x1-x0)
    if span<MIN_PANEL or perp<2*MIN_PANEL: return []
    marks=[]
    for p in (range(y0,y1) if horiz else range(x0,x1)):
        best=cur=0; bright=0
        if horiz:
            r=raw[p*W:(p+1)*W]
            for q in range(x0,x1):
                v=r[q]
                cur = cur+1 if v<DARK else 0
                if cur>best: best=cur
                if v>=BRIGHT: bright+=1
        else:
            for q in range(y0,y1):
                v=raw[q*W+p]
                cur = cur+1 if v<DARK else 0
                if cur>best: best=cur
                if v>=BRIGHT: bright+=1
        marks.append(best>=minfrac*span or bright/span>=0.94)
    bands=[];s=None
    for i,f in enumerate(marks):
        if f and s is None: s=i
        elif not f and s is not None: bands.append((s,i)); s=None
    if s is not None: bands.append((s,len(marks)))
    base = y0 if horiz else x0
    lo,hi = (y0,y1) if horiz else (x0,x1)
    out=[]
    for a,b in bands:
        if (b-a)>maxthick: continue
        c=base+(a+b)//2
        if c-lo<MIN_PANEL or hi-c<MIN_PANEL: continue
        if out and c-out[-1]<MIN_PANEL: continue      # no slivers between cuts
        out.append(c)
    return out

def split(raw,h,reg,depth=0,maxdepth=6):
    """returns panels in reading order (DFS of the cut tree)"""
    x0,y0,x1,y1=reg
    if depth>=maxdepth or (x1-x0)<2*MIN_PANEL and (y1-y0)<2*MIN_PANEL: return [reg]
    v  = cuts(raw,h,reg,False)
    hz = cuts(raw,h,reg,True)
    # a vertical cut means columns: read each column fully, left to right
    if v and (not hz or (x1-x0) >= (y1-y0)*1.15):
        parts=[];prev=x0
        for c in v: parts.append((prev,y0,c,y1)); prev=c
        parts.append((prev,y0,x1,y1))
    elif hz:
        parts=[];prev=y0
        for c in hz: parts.append((x0,prev,x1,c)); prev=c
        parts.append((x0,prev,x1,y1))
    else:
        return [reg]
    if len(parts)==1: return [reg]
    out=[]
    for p in parts: out += split(raw,h,p,depth+1,maxdepth)
    return out

if __name__=="__main__":
    raw,h=load(sys.argv[1])
    reg=trim(raw,h)
    print("content:",reg)
    ps=split(raw,h,reg)
    print(f"{len(ps)} panels IN READING ORDER:")
    for i,p in enumerate(ps,1): print(f"   {i}. {p}  {p[2]-p[0]}x{p[3]-p[1]}")
