import sys, math, subprocess
S='/home/sjp/Workspace/comic-guide/work'
sys.path.insert(0,S)
from guide import load, W, text_regions
import xycut2 as X

path, tag = sys.argv[1], sys.argv[2]
ASPECT = float(sys.argv[3]) if len(sys.argv)>3 else 16/9
BUDGET, ZMAX = 0.25, 1.75
raw,h = load(path)
tr  = text_regions(raw,h)
panels = X.split(raw,h,X.trim(raw,h))          # reading order
SW = math.sqrt(BUDGET*W*h*ASPECT); SH = SW/ASPECT
def zoom(r): return max((r[2]-r[0])/SW,(r[3]-r[1])/SH)
def U(rs): return (min(r[0] for r in rs),min(r[1] for r in rs),
                   max(r[2] for r in rs),max(r[3] for r in rs))

# 1. split any panel too big for the viewport into a vertical pan
units=[]
for p in panels:
    z=zoom(p)
    if z<=ZMAX: units.append(p); continue
    n=max(2, round((p[3]-p[1])/SH))          # aim each unit at ~one frame height
    ph=p[3]-p[1]
    for r in range(n):
        units.append((p[0], int(p[1]+r*ph/n), p[2], int(p[1]+(r+1)*ph/n)))

# 2. greedily merge consecutive units whose union still fits
beats=[]; cur=[units[0]]
for u in units[1:]:
    if zoom(U(cur+[u])) <= 1.02: cur.append(u)
    else: beats.append(U(cur)); cur=[u]
beats.append(U(cur))

# 3. expand each beat to the viewport aspect, clamped to the PAGE (not the panel),
#    so a narrow column fills the frame instead of rendering as a postage stamp
def fill_frame(b, pw, ph):
    x0,y0,x1,y1=b; w,hh=x1-x0,y1-y0
    if w/hh < ASPECT: w2,h2 = hh*ASPECT, hh
    else:             w2,h2 = w, w/ASPECT
    cx,cy=(x0+x1)/2,(y0+y1)/2
    w2=min(w2,pw); h2=min(h2,ph)
    nx0,nx1=cx-w2/2,cx+w2/2
    ny0,ny1=cy-h2/2,cy+h2/2
    if nx0<0: nx1-=nx0; nx0=0
    if nx1>pw: nx0-=nx1-pw; nx1=pw
    if ny0<0: ny1-=ny0; ny0=0
    if ny1>ph: ny0-=ny1-ph; ny1=ph
    return (int(max(0,nx0)),int(max(0,ny0)),int(min(pw,nx1)),int(min(ph,ny1)))
beats=[fill_frame(b,W,h) for b in beats]

def bars(b):
    w,hh=b[2]-b[0],b[3]-b[1]
    s=min(SW/w,SH/hh)
    return 1-(w*s*hh*s)/(SW*SH)

print(f"{len(tr)} balloons | {len(panels)} panels | {len(units)} units -> {len(beats)} beats\n")
for k,b in enumerate(beats,1):
    n=sum(1 for t in tr if b[0]<=(t[0]+t[2])/2<=b[2] and b[1]<=(t[1]+t[3])/2<=b[3])
    print(f"  beat {k}: {b}  {b[2]-b[0]}x{b[3]-b[1]}  zoom {zoom(b):.2f}  bars {bars(b):.0%}  {n} balloon(s)")

cols=["#ffcc00","#00e5ff","#ff1e8e","#42f5a1","#c084fc","#fb923c","#f87171"]
draw=[]
for k,b in enumerate(beats,1):
    x0,y0,x1,y1=b; c=cols[(k-1)%len(cols)]
    draw+=["-stroke",c,"-strokewidth","5","-fill","none","-draw",f"rectangle {x0+3},{y0+3} {x1-3},{y1-3}",
           "-stroke","none","-fill",c,"-pointsize","48","-weight","Bold","-draw",f"text {x0+12},{y0+56} '{k}'"]
subprocess.run(["convert",path,"-resize",f"{W}x"]+draw+[f"{S}/{tag}_v3.jpg"],check=True)
seq=[]
for k,b in enumerate(beats,1):
    x0,y0,x1,y1=b; f=f"{S}/{tag}_v3_{k:02d}.jpg"
    subprocess.run(["convert",path,"-resize",f"{W}x","-crop",f"{x1-x0}x{y1-y0}+{x0}+{y0}","+repage",
                    "-background","#0b0b0b","-gravity","center","-resize",f"{int(SW)}x{int(SH)}",
                    "-extent",f"{int(SW)}x{int(SH)}",f],check=True); seq.append(f)
subprocess.run(["convert"]+seq+["-bordercolor","#2a2a2a","-border","4","-append",f"{S}/{tag}_v3_seq.jpg"],check=True)
