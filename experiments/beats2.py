import subprocess, math, sys
S='/home/sjp/Workspace/comic-guide/work'
SRC=f'{S}/pages/pdf2/ab-007.jpg'
W,H=700,950; PAGE=W*H
ASPECT=float(sys.argv[1]) if len(sys.argv)>1 else 16/9
SW=math.sqrt(0.25*PAGE*ASPECT); SH=SW/ASPECT          # ¼-page viewport

PANELS=[(15,40,684,255),(3,280,327,550),(327,280,483,550),(483,280,697,550),(55,566,644,870)]
FOCAL =[(380,74,535,240),(33,285,324,459),(330,285,462,444),(486,285,682,545),(29,566,465,859)]

def panel_of(f):
    cx,cy=(f[0]+f[2])/2,(f[1]+f[3])/2
    for i,p in enumerate(PANELS):
        if p[0]<=cx<=p[2] and p[1]<=cy<=p[3]: return i
    return min(range(len(PANELS)),
               key=lambda i:(cx-(PANELS[i][0]+PANELS[i][2])/2)**2+(cy-(PANELS[i][1]+PANELS[i][3])/2)**2)
OWNER=[panel_of(f) for f in FOCAL]

def U(rs): return (min(r[0] for r in rs),min(r[1] for r in rs),
                   max(r[2] for r in rs),max(r[3] for r in rs))

def grow(rect, bound, zoom):
    """expand rect toward the viewport shape at a given zoom, clamped to bound"""
    tw,th = SW*zoom, SH*zoom
    x0,y0,x1,y1=rect; bx0,by0,bx1,by1=bound
    cx,cy=(x0+x1)/2,(y0+y1)/2
    w=min(max(x1-x0,tw), bx1-bx0); h=min(max(y1-y0,th), by1-by0)
    x0,x1=cx-w/2,cx+w/2; y0,y1=cy-h/2,cy+h/2
    if x0<bx0: x1+=bx0-x0; x0=bx0
    if x1>bx1: x0-=x1-bx1; x1=bx1
    if y0<by0: y1+=by0-y0; y0=by0
    if y1>by1: y0-=y1-by1; y1=by1
    return (int(max(bx0,x0)),int(max(by0,y0)),int(min(bx1,x1)),int(min(by1,y1)))

def zoom_of(r): return max((r[2]-r[0])/SW, (r[3]-r[1])/SH)

def seg(i,j):
    bound=U([PANELS[k] for k in OWNER[i:j]])
    r=grow(U(FOCAL[i:j]), bound, 1.0)
    return r, zoom_of(r), bound

n=len(FOCAL); best=[None]*(n+1); best[0]=(0,0.0,[])
for j in range(1,n+1):
    for i in range(j):
        if best[i] is None: continue
        if len(set(OWNER[i:j]))>1 and len({PANELS[k][1] for k in OWNER[i:j]})>1: continue  # no cross-tier beats
        r,z,b = seg(i,j)
        if z>1.02: continue
        cand=(best[i][0]+1, best[i][1]+(1-((U(FOCAL[i:j])[2]-U(FOCAL[i:j])[0])*(U(FOCAL[i:j])[3]-U(FOCAL[i:j])[1]))/max((r[2]-r[0])*(r[3]-r[1]),1)),
              best[i][2]+[(i,j)])
        if best[j] is None or cand[:2]<best[j][:2]: best[j]=cand
segs=best[n][2]

# --- normalise zoom so the view doesn't lurch between beats
zs=[seg(i,j)[1] for i,j in segs]
target=max(zs)
beats=[]
for (i,j) in segs:
    bound=U([PANELS[k] for k in OWNER[i:j]])
    beats.append((grow(U(FOCAL[i:j]), bound, target), list(range(i+1,j+1))))

print(f"viewport {int(SW)}x{int(SH)} (¼ page, {ASPECT:.2f}:1)   zoom normalised to {target:.2f}\n")
cols=["#ffcc00","#00e5ff","#ff1e8e","#42f5a1","#c084fc"]; draw=[]
for k,(r,mem) in enumerate(beats,1):
    x0,y0,x1,y1=r; a=(x1-x0)*(y1-y0)/PAGE*100
    lb = "letterboxed" if abs((x1-x0)/(y1-y0)-ASPECT)>0.12 else ""
    print(f"beat {k}: focal {mem}  ({x0},{y0})-({x1},{y1})  {x1-x0}x{y1-y0}  {a:4.1f}% of page  {lb}")
    c=cols[(k-1)%5]
    draw+=["-stroke",c,"-strokewidth","5","-fill","none","-draw",f"rectangle {x0},{y0} {x1},{y1}",
           "-stroke","none","-fill",c,"-pointsize","44","-weight","Bold",
           "-draw",f"text {x0+10},{y0+48} '{k}'"]
    subprocess.run(["convert",SRC,"-resize",f"{W}x","-crop",f"{x1-x0}x{y1-y0}+{x0}+{y0}","+repage",
                    "-background","#0b0b0b","-gravity","center",
                    "-resize",f"{int(SW*2)}x{int(SH*2)}",
                    "-extent",f"{int(SW*2)}x{int(SH*2)}",f"{S}/beat_{k}.jpg"],check=True)
subprocess.run(["convert",SRC,"-resize",f"{W}x"]+draw+[f"{S}/beats.jpg"],check=True)
subprocess.run(f"convert {S}/beat_*.jpg -bordercolor '#2a2a2a' -border 5 -append {S}/filmstrip.jpg",
               shell=True,check=True)
print(f"\n{len(beats)} beats")
