import subprocess, math, sys
S='/home/sjp/Workspace/comic-guide/work'
SRC=f'{S}/pages/pdf2/ab-007.jpg'
W,H = 700,950
PAGE = W*H
ASPECT = float(sys.argv[1]) if len(sys.argv)>1 else 16/9
MAXA, MINA = 0.25, 0.11          # beat area as fraction of page

FOCAL=[(380,74,535,240),(33,285,324,459),(330,285,462,444),(486,285,682,545),(29,566,465,859)]

def fit(r):
    """expand rect to viewport aspect, lift to min area, clamp to page"""
    x0,y0,x1,y1=r
    cx,cy=(x0+x1)/2,(y0+y1)/2
    w,h=x1-x0,y1-y0
    if w/h < ASPECT: w = h*ASPECT
    else:            h = w/ASPECT
    if w*h < MINA*PAGE:                       # never punch in closer than min zoom
        s = math.sqrt(MINA*PAGE/(w*h)); w*=s; h*=s
    x0,x1 = cx-w/2, cx+w/2
    y0,y1 = cy-h/2, cy+h/2
    if x0<0: x1-=x0; x0=0
    if y0<0: y1-=y0; y0=0
    if x1>W: x0-=(x1-W); x1=W
    if y1>H: y0-=(y1-H); y1=H
    return (max(0,int(x0)),max(0,int(y0)),min(W,int(x1)),min(H,int(y1)))

def union(rs):
    return (min(r[0] for r in rs),min(r[1] for r in rs),
            max(r[2] for r in rs),max(r[3] for r in rs))

def area(r): return (r[2]-r[0])*(r[3]-r[1])
def feasible(seg):
    f=fit(union(seg));  return area(f) <= MAXA*PAGE*1.02, f

# --- DP: fewest beats, tie-break on tightest packing (least dead space)
n=len(FOCAL)
best=[None]*(n+1); best[0]=(0,0.0,[])
for j in range(1,n+1):
    for i in range(j):
        if best[i] is None: continue
        ok,f = feasible(FOCAL[i:j])
        if not ok: continue
        waste = 1 - area(union(FOCAL[i:j]))/area(f)
        cand=(best[i][0]+1, best[i][1]+waste, best[i][2]+[(f,list(range(i+1,j+1)))])
        if best[j] is None or cand[:2] < best[j][:2]: best[j]=cand
beats = best[n][2]

print(f"viewport aspect {ASPECT:.2f}  ->  {int(math.sqrt(MAXA*PAGE*ASPECT))}x{int(math.sqrt(MAXA*PAGE/ASPECT))} window (¼ page)\n")
cols=["#ffcc00","#00e5ff","#ff1e8e","#42f5a1","#c084fc"]
draw=[]
for k,(f,members) in enumerate(beats,1):
    x0,y0,x1,y1=f
    print(f"beat {k}: focal {members}  rect ({x0},{y0})-({x1},{y1})  "
          f"{x1-x0}x{y1-y0}  = {area(f)/PAGE*100:.1f}% of page")
    c=cols[(k-1)%5]
    draw+=["-stroke",c,"-strokewidth","5","-fill","none","-draw",f"rectangle {x0},{y0} {x1},{y1}",
           "-stroke","none","-fill",c,"-pointsize","46","-weight","Bold",
           "-draw",f"text {x0+10},{y0+50} '{k}'"]
    subprocess.run(["convert",SRC,"-resize",f"{W}x","-crop",
                    f"{x1-x0}x{y1-y0}+{x0}+{y0}","+repage","-resize","900x",
                    f"{S}/beat_{k}.jpg"],check=True)
subprocess.run(["convert",SRC,"-resize",f"{W}x"]+draw+[f"{S}/beats.jpg"],check=True)
subprocess.run(f"convert {S}/beat_*.jpg -bordercolor '#111' -border 6 -append {S}/filmstrip.jpg",
               shell=True,check=True)
print(f"\n{len(beats)} beats")
