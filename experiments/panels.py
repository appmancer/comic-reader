import subprocess
S='/home/sjp/Workspace/comic-guide/work'
W=700
raw=subprocess.run(["convert",f"{S}/pages/pdf2/ab-007.jpg","-resize",f"{W}x",
                    "-colorspace","gray","-depth","8","gray:-"],capture_output=True).stdout
H=len(raw)//W

def bright_frac_col(x,y0,y1):
    n=y1-y0
    return sum(1 for y in range(y0,y1) if raw[y*W+x]>=205)/n
def bright_frac_row(y,x0,x1):
    r=raw[y*W:(y+1)*W]
    return sum(1 for x in range(x0,x1) if r[x]>=205)/(x1-x0)

def content_x(y0,y1,th=0.985):
    xs=[x for x in range(W) if bright_frac_col(x,y0,y1)<th]
    return (min(xs),max(xs)+1) if xs else (0,W)
def content_y(x0,x1,y0,y1,th=0.985):
    ys=[y for y in range(y0,y1) if bright_frac_row(y,x0,x1)<th]
    return (min(ys),max(ys)+1) if ys else (y0,y1)

def gutters(x0,x1,y0,y1,th=0.94,minw=3):
    n=y1-y0
    fl=[bright_frac_col(x,y0,y1)>=th for x in range(x0,x1)]
    runs=[];s=None
    for i,f in enumerate(fl):
        if f and s is None: s=i
        elif not f and s is not None:
            if i-s>=minw: runs.append((x0+s,x0+i))
            s=None
    return [g for g in runs if g[0]>x0+8 and g[1]<x1-8]

BANDS=[(40,255),(280,550),(560,880)]
PANELS=[]
for (by0,by1) in BANDS:
    cx0,cx1 = content_x(by0,by1)
    ty0,ty1 = content_y(cx0,cx1,by0,by1)
    # scan gutters below the balloon overhang zone
    gs = gutters(cx0,cx1,ty0+int((ty1-ty0)*0.30),ty1)
    cuts=[cx0]+[ (g[0]+g[1])//2 for g in gs ]+[cx1]
    for i in range(len(cuts)-1):
        PANELS.append((cuts[i],ty0,cuts[i+1],ty1))
for i,p in enumerate(PANELS,1):
    print(f"panel {i}: ({p[0]},{p[1]})-({p[2]},{p[3]})  {p[2]-p[0]}x{p[3]-p[1]}")
