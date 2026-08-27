import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path: sys.path.insert(0, ROOT)
WORK = os.environ.get('CG_WORK', os.path.join(ROOT, 'work'))
import sys, math, subprocess
S = WORK
sys.path.insert(0,S)
from cg.detect import load, text_regions, W
import cg.xycut as X
from cg.unchain import unchain
from cg.detect import BRIGHT

path=f'{S}/sd/p-13.jpg'
raw,h = load(path)
_raw_tr = text_regions(raw,h)
tr=[]
for r in _raw_tr: tr += unchain(raw,h,r)          # split linked balloon chains
PIX={}
for r in tr:
    PIX[r]=[(x,y) for y in range(r[1],r[3]) for x in range(r[0],r[2]) if raw[y*W+x]>=BRIGHT]
panels = X.split(raw,h,X.trim(raw,h))
P2,P3 = panels[1],panels[2]
def tin(reg): return [r for r in tr if reg[0]<=(r[0]+r[2])/2<=reg[2] and reg[1]<=(r[1]+r[3])/2<=reg[3]]

BEATS=[
 dict(n="col top",    panel=(0,0,212,480),     focus=[(27,47,109,94),(130,314,204,442)]),
 dict(n="col bottom", panel=(0,480,212,1056),  focus=[(61,558,159,664)]),
 dict(n="face",       panel=P2,                focus=tin(P2)),
 dict(n="mid tier",   panel=P3,                focus=tin(P3)),
 dict(n="bottom",     panel=(212,765,700,1056),focus=tin((212,765,700,1056))),
]
def ov(a,b):
    w=max(0,min(a[2],b[2])-max(a[0],b[0])); hh=max(0,min(a[3],b[3])-max(a[1],b[1])); return w*hh
def frac(r,rect):
    px=PIX.get(r)
    if not px: return ov(r,rect)/max((r[2]-r[0])*(r[3]-r[1]),1)
    inside=sum(1 for x,y in px if rect[0]<=x<rect[2] and rect[1]<=y<rect[3])
    return inside/len(px)

FWD, BACK, MIN_FOCUS = 0.20, 0.12, 0.50
def expand(base, panel, focus, seen, aspect, shown=()):
    x0,y0,x1,y1=base
    others=[r for r in tr if r not in focus]
    parea=(panel[2]-panel[0])*(panel[3]-panel[1])
    def ok(rect):
        for r in others:
            cap = BACK if id(r) in seen else FWD
            if frac(r,rect)>cap: return False
        a=(rect[2]-rect[0])*(rect[3]-rect[1])
        if ov(panel,rect)/max(a,1) < MIN_FOCUS: return False   # stay anchored on our panel
        if shown and sum(ov(s,rect) for s in shown)/max(a,1) > 0.25: return False  # don't re-show
        return True
    for _ in range(500):
        w,hh=x1-x0,y1-y0
        cand = (max(0,x0-4),y0,min(W,x1+4),y1) if w/hh<aspect else (x0,max(0,y0-4),x1,min(h,y1+4))
        if cand==(x0,y0,x1,y1) or not ok(cand): break
        x0,y0,x1,y1=cand
    return (x0,y0,x1,y1)

def run(tag,aspect):
    SW=math.sqrt(0.25*W*h*aspect); SH=SW/aspect
    seen=set(); outs=[]; shown=[]
    for i,b in enumerate(BEATS,1):
        p=b['panel']
        base=(min(r[0] for r in b['focus'])-14, min(r[1] for r in b['focus'])-14,
              max(r[2] for r in b['focus'])+14, max(r[3] for r in b['focus'])+14)
        base=(max(p[0],base[0]),max(p[1],base[1]),min(p[2],base[2]),min(p[3],base[3]))
        if b['n']=="col bottom": base=p          # include Dragon's face, not just the balloon
        rect=expand(base,p,b['focus'],seen,aspect,shown)
        for r in b['focus']: seen.add(id(r))
        for r in tr:
            if frac(r,rect)>0.85: seen.add(id(r))
        x0,y0,x1,y1=rect; f=f"{S}/{tag}_{i:02d}.jpg"
        subprocess.run(["convert",path,"-resize",f"{W}x","-crop",f"{x1-x0}x{y1-y0}+{x0}+{y0}","+repage",
            "-background","#0b0b0b","-gravity","center","-resize",f"{int(SW)}x{int(SH)}",
            "-extent",f"{int(SW)}x{int(SH)}",f],check=True)
        outs.append(f); shown.append(rect)
        s=min(SW/(x1-x0),SH/(y1-y0))
        print(f"  beat {i} [{b['n']:11s}] {rect} {x1-x0}x{y1-y0}  bars {1-((x1-x0)*s*(y1-y0)*s)/(SW*SH):.0%}")
    subprocess.run(["convert"]+outs+["-bordercolor","#2a2a2a","-border","4","-append",f"{S}/{tag}_seq.jpg"],check=True)

print("Strategy A v2 - forward-only bleed, anchored on panel (landscape):")
run("A2",16/9)
