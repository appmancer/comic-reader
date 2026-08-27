import subprocess, sys, os
from collections import defaultdict

W = 700
WHITE, INK = 205, 110

def load(path):
    raw = subprocess.run(["convert", path, "-resize", f"{W}x", "-colorspace","gray","-depth","8","gray:-"],
                         capture_output=True).stdout
    h = len(raw)//W
    return raw, h

def components(raw, h):
    """Run-length connected components over 'bright' pixels."""
    parent = {}
    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]; a = parent[a]
        return a
    def union(a,b):
        ra,rb = find(a),find(b)
        if ra!=rb: parent[rb]=ra
    runs_by_row=[]
    nxt=0
    for y in range(h):
        row = raw[y*W:(y+1)*W]; runs=[]; x=0
        while x < W:
            if row[x] >= WHITE:
                s=x
                while x < W and row[x] >= WHITE: x+=1
                runs.append([s,x,nxt]); parent[nxt]=nxt; nxt+=1
            else: x+=1
        runs_by_row.append(runs)
        if y:
            for r in runs:
                for p in runs_by_row[y-1]:
                    if p[0] < r[1] and r[0] < p[1]: union(p[2], r[2])
    comps = defaultdict(lambda: [W,10**9,-1,-1,0])  # x0,y0,x1,y1,area
    for y,runs in enumerate(runs_by_row):
        for s,e,lab in runs:
            c = comps[find(lab)]
            c[0]=min(c[0],s); c[1]=min(c[1],y); c[2]=max(c[2],e); c[3]=max(c[3],y); c[4]+=e-s
    return comps

def ink_stats(raw,h,box):
    x0,y0,x1,y1 = box
    dark=tot=0
    for y in range(y0,y1+1):
        row = raw[y*W:(y+1)*W]
        for x in range(x0,x1):
            tot+=1
            if row[x] < INK: dark+=1
    return dark/max(tot,1)

def detect(path):
    raw,h = load(path)
    page = W*h
    out=[]
    for c in components(raw,h).values():
        x0,y0,x1,y1,area = c
        bw,bh = x1-x0, y1-y0+1
        if bw<12 or bh<10: continue
        if x0<=1 or y0<=1 or x1>=W-1 or y1>=h-1: continue          # touches page edge
        frac = area/page
        if not (0.0015 < frac < 0.070): continue                    # plausible balloon size
        fill = area/(bw*bh)
        if fill < 0.55: continue                                    # solid blob, not a sliver
        ar = bw/bh
        if not (0.28 < ar < 4.2): continue
        d = ink_stats(raw,h,(x0,y0,x1,y1))
        if not (0.045 < d < 0.42): continue                         # must contain lettering
        out.append(dict(x=round(x0/W,3), y=round(y0/h,3), w=round(bw/W,3), hh=round(bh/h,3),
                        fill=round(fill,2), ink=round(d,2), px=(x0,y0,x1,y1)))
    out.sort(key=lambda b:(b['y'],b['x']))
    return out,h

p = sys.argv[1]
bs,h = detect(p)
print(f"{os.path.basename(p)}  ({W}x{h})   candidates: {len(bs)}\n")
print(f"{'#':>2}  {'x':>5} {'y':>5} {'w':>5} {'h':>5}  {'fill':>4} {'ink':>4}")
for i,b in enumerate(bs,1):
    print(f"{i:2d}  {b['x']:5.3f} {b['y']:5.3f} {b['w']:5.3f} {b['hh']:5.3f}  {b['fill']:4.2f} {b['ink']:4.2f}")
