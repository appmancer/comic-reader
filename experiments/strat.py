import sys, math, subprocess
S='/home/sjp/Workspace/comic-guide/work'
sys.path.insert(0,S)
from guide import load, text_regions, W
import xycut2 as X

path=f'{S}/sd/p-13.jpg'
raw,h = load(path)
tr = text_regions(raw,h)
panels = X.split(raw,h,X.trim(raw,h))

# beats defined as (focus panel indices, focus text regions)
P1,P2,P3 = panels[0],panels[1],panels[2]
BOT = (212,765,700,1056)
t = {r:r for r in tr}
def tin(reg): return [r for r in tr if reg[0]<=(r[0]+r[2])/2<=reg[2] and reg[1]<=(r[1]+r[3])/2<=reg[3]]

BEATS = [
  dict(name="col top",  panel=(0,0,212,470),    focus=[(27,47,109,94),(130,314,204,442)]),
  dict(name="col bottom",panel=(0,470,212,1056),focus=[(61,558,159,664)]),
  dict(name="face",     panel=P2,               focus=tin(P2)),
  dict(name="mid tier", panel=P3,               focus=tin(P3)),
  dict(name="bottom",   panel=BOT,              focus=tin(BOT)),
]

def ov(a,b):
    w=max(0,min(a[2],b[2])-max(a[0],b[0])); hh=max(0,min(a[3],b[3])-max(a[1],b[1]))
    return w*hh
def frac_in(r,rect): return ov(r,rect)/max((r[2]-r[0])*(r[3]-r[1]),1)

def expand(base, focus, aspect, cap=0.50):
    """grow toward frame aspect, but never let a NON-focus balloon exceed `cap` visible"""
    x0,y0,x1,y1=base
    others=[r for r in tr if r not in focus]
    def ok(rect): return all(frac_in(r,rect)<=cap for r in others)
    for _ in range(400):
        w,hh=x1-x0,y1-y0
        if w/hh < aspect:
            nx0,nx1=max(0,x0-4),min(W,x1+4)
            cand=(nx0,y0,nx1,y1)
        else:
            ny0,ny1=max(0,y0-4),min(h,y1+4)
            cand=(x0,ny0,x1,ny1)
        if cand==(x0,y0,x1,y1) or not ok(cand): break
        x0,y0,x1,y1=cand
    return (x0,y0,x1,y1)

def render(tag, aspect, masked):
    SW=math.sqrt(0.25*W*h*aspect); SH=SW/aspect
    outs=[]
    for i,b in enumerate(BEATS,1):
        base=(min(r[0] for r in b['focus'])-14, min(r[1] for r in b['focus'])-14,
              max(r[2] for r in b['focus'])+14, max(r[3] for r in b['focus'])+14)
        base=(max(0,base[0]),max(0,base[1]),min(W,base[2]),min(h,base[3]))
        if masked:
            p=b['panel']
            rect=(max(p[0],base[0]-30),max(p[1],base[1]-30),min(p[2],base[2]+30),min(p[3],base[3]+30))
        else:
            rect=expand(base,b['focus'],aspect)
        x0,y0,x1,y1=rect
        f=f"{S}/{tag}_{i:02d}.jpg"
        cmd=["convert",path,"-resize",f"{W}x"]
        if masked:
            p=b['panel']
            cmd+=["-fill","black","-draw",
                  f"rectangle 0,0 {W},{p[1]}", "-draw",f"rectangle 0,{p[3]} {W},{h}",
                  "-draw",f"rectangle 0,0 {p[0]},{h}", "-draw",f"rectangle {p[2]},0 {W},{h}"]
        cmd+=["-crop",f"{x1-x0}x{y1-y0}+{x0}+{y0}","+repage","-background","#0b0b0b",
              "-gravity","center","-resize",f"{int(SW)}x{int(SH)}",
              "-extent",f"{int(SW)}x{int(SH)}",f]
        subprocess.run(cmd,check=True); outs.append(f)
        s=min(SW/(x1-x0),SH/(y1-y0))
        print(f"  {tag} beat {i} [{b['name']:10s}] {rect} {x1-x0}x{y1-y0} bars {1-((x1-x0)*s*(y1-y0)*s)/(SW*SH):.0%}")
    subprocess.run(["convert"]+outs+["-bordercolor","#2a2a2a","-border","4","-append",f"{S}/{tag}_seq.jpg"],check=True)

print("STRATEGY A - bleed, capped at 50% of any foreign balloon (landscape):")
render("stratA", 16/9, False)
print("\nSTRATEGY B - mask other panels, blow up focus (portrait):")
render("stratB", 0.70, True)
