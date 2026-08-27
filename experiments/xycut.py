"""Recursive X-Y cut: split a page on whichever axis has a full-span border."""
import sys
sys.path.insert(0,'/home/sjp/Workspace/comic-guide/work')
from guide import load, W, DARK, BRIGHT

def trim(raw,h):
    """trim uniform page margins of ANY colour (black bleed or white paper)"""
    def uniform_col(x):
        v=[raw[y*W+x] for y in range(0,h,3)]
        return (max(v)-min(v))<=26
    def uniform_row(y):
        r=raw[y*W:(y+1)*W]; v=[r[x] for x in range(0,W,3)]
        return (max(v)-min(v))<=26
    x0=0
    while x0<W-1 and uniform_col(x0): x0+=1
    x1=W
    while x1>x0+1 and uniform_col(x1-1): x1-=1
    y0=0
    while y0<h-1 and uniform_row(y0): y0+=1
    y1=h
    while y1>y0+1 and uniform_row(y1-1): y1-=1
    return (x0,y0,x1,y1)

def cuts(raw,h,reg,horiz,minfrac=0.92,maxthick=14):
    x0,y0,x1,y1=reg
    span=(x1-x0) if horiz else (y1-y0)
    if span<40: return []
    marks=[]
    rng = range(y0,y1) if horiz else range(x0,x1)
    for p in rng:
        best=cur=0
        if horiz:
            r=raw[p*W:(p+1)*W]
            for q in range(x0,x1):
                cur = cur+1 if r[q]<DARK else 0
                if cur>best: best=cur
            # a white gutter counts too
            wb=sum(1 for q in range(x0,x1) if r[q]>=BRIGHT)/span
        else:
            for q in range(y0,y1):
                cur = cur+1 if raw[q*W+p]<DARK else 0
                if cur>best: best=cur
            wb=sum(1 for q in range(y0,y1) if raw[q*W+p]>=BRIGHT)/span
        marks.append(best>=minfrac*span or wb>=0.94)
    bands=[];s=None
    for i,f in enumerate(marks):
        if f and s is None: s=i
        elif not f and s is not None: bands.append((s,i)); s=None
    if s is not None: bands.append((s,len(marks)))
    base = y0 if horiz else x0
    out=[]
    for a,b in bands:
        if (b-a)>maxthick: continue
        c=base+(a+b)//2
        lo = y0 if horiz else x0; hi = y1 if horiz else x1
        if c-lo<28 or hi-c<28: continue      # ignore cuts hugging the edge
        out.append(c)
    return out

def split(raw,h,reg,depth=0,maxdepth=5):
    x0,y0,x1,y1=reg
    if depth>=maxdepth or (x1-x0)<60 or (y1-y0)<60: return [reg]
    v=cuts(raw,h,reg,False)
    hh=cuts(raw,h,reg,True)
    # prefer the axis that yields the cleaner single split of the larger dimension
    if v and (not hh or (x1-x0)>=(y1-y0)):
        parts=[];prev=x0
        for c in v: parts.append((prev,y0,c,y1)); prev=c
        parts.append((prev,y0,x1,y1))
    elif hh:
        parts=[];prev=y0
        for c in hh: parts.append((x0,prev,x1,c)); prev=c
        parts.append((x0,prev,x1,y1))
    else:
        return [reg]
    out=[]
    for p in parts:
        out += split(raw,h,p,depth+1,maxdepth) if p!=reg else [p]
    return out

if __name__=="__main__":
    raw,h=load(sys.argv[1])
    reg=trim(raw,h)
    print("trimmed content:",reg)
    ps=split(raw,h,reg)
    print(f"{len(ps)} panels:")
    for p in sorted(ps,key=lambda p:(p[1],p[0])): print(f"   {p}  {p[2]-p[0]}x{p[3]-p[1]}")
