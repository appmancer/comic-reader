import sys, math
S='/home/sjp/Workspace/comic-guide/work'
sys.path.insert(0,S)
from guide import load, W, text_regions
import xycut2 as X

path=sys.argv[1]
raw,h = load(path)
tr = text_regions(raw,h)

# mask balloons to mid-grey so they are neither "dark rule" nor "white gutter"
m=bytearray(raw)
for (x0,y0,x1,y1) in tr:
    for y in range(max(0,y0-3),min(h,y1+4)):
        for x in range(max(0,x0-3),min(W,x1+4)): m[y*W+x]=150
m=bytes(m)

reg=X.trim(m,h)
panels=X.split(m,h,reg)
print(f"{len(tr)} text regions | {len(panels)} panels in reading order:")

ASPECT=16/9; BUDGET=0.25
SW=math.sqrt(BUDGET*W*h*ASPECT); SH=SW/ASPECT
print(f"viewport {int(SW)}x{int(SH)}\n")

def owner(t):
    cx,cy=(t[0]+t[2])/2,(t[1]+t[3])/2
    for i,p in enumerate(panels):
        if p[0]<=cx<=p[2] and p[1]<=cy<=p[3]: return i
    return min(range(len(panels)),
        key=lambda i:(cx-(panels[i][0]+panels[i][2])/2)**2+(cy-(panels[i][1]+panels[i][3])/2)**2)

beats=[]
for i,p in enumerate(panels):
    px0,py0,px1,py1=p
    mine=[t for t in tr if owner(t)==i]
    pw,ph=px1-px0,py1-py0
    n_v = max(1, math.ceil(ph/ (SH*1.25)))       # tall panel -> pan down in n beats
    n_h = max(1, math.ceil(pw/ (SW*1.25)))
    for r in range(n_v):
        for c in range(n_h):
            b=(int(px0+c*pw/n_h), int(py0+r*ph/n_v),
               int(px0+(c+1)*pw/n_h), int(py0+(r+1)*ph/n_v))
            txt=[t for t in mine if (t[1]+t[3])/2>=b[1] and (t[1]+t[3])/2<b[3]
                                 and (t[0]+t[2])/2>=b[0] and (t[0]+t[2])/2<b[2]]
            beats.append((b, i+1, len(txt)))
for k,(b,pi,nt) in enumerate(beats,1):
    print(f"  beat {k}: panel {pi}  {b}  {b[2]-b[0]}x{b[3]-b[1]}  {nt} balloon(s)")

import subprocess
cols=["#ffcc00","#00e5ff","#ff1e8e","#42f5a1","#c084fc","#fb923c","#f87171","#38bdf8"]
draw=[]
for k,(b,pi,nt) in enumerate(beats,1):
    x0,y0,x1,y1=b; c=cols[(k-1)%len(cols)]
    draw+=["-stroke",c,"-strokewidth","5","-fill","none",
           "-draw",f"rectangle {x0+3},{y0+3} {x1-3},{y1-3}",
           "-stroke","none","-fill",c,"-pointsize","46","-weight","Bold",
           "-draw",f"text {x0+12},{y0+54} '{k}'"]
subprocess.run(["convert",path,"-resize",f"{W}x"]+draw+[f"{S}/sd13_v2.jpg"],check=True)
