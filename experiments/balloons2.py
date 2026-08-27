import subprocess, sys, os
from collections import defaultdict
W=700; WHITE=205; INK=110

def load(p):
    raw=subprocess.run(["convert",p,"-resize",f"{W}x","-colorspace","gray","-depth","8","gray:-"],
                       capture_output=True).stdout
    return raw, len(raw)//W

def comps(raw,h):
    parent={}
    def find(a):
        while parent[a]!=a: parent[a]=parent[parent[a]]; a=parent[a]
        return a
    def union(a,b):
        ra,rb=find(a),find(b)
        if ra!=rb: parent[rb]=ra
    rows=[]; nxt=0
    for y in range(h):
        row=raw[y*W:(y+1)*W]; rs=[]; x=0
        while x<W:
            if row[x]>=WHITE:
                s=x
                while x<W and row[x]>=WHITE: x+=1
                rs.append((s,x,nxt)); parent[nxt]=nxt; nxt+=1
            else: x+=1
        rows.append(rs)
        if y:
            for s,e,l in rs:
                for ps,pe,pl in rows[y-1]:
                    if ps<e and s<pe: union(pl,l)
    out=defaultdict(lambda:[W,10**9,-1,-1,0])
    for y,rs in enumerate(rows):
        for s,e,l in rs:
            c=out[find(l)]
            c[0]=min(c[0],s); c[1]=min(c[1],y); c[2]=max(c[2],e); c[3]=max(c[3],y); c[4]+=e-s
    return out

def ink(raw,h,b):
    x0,y0,x1,y1=b; d=t=0
    for y in range(y0,y1+1):
        r=raw[y*W:(y+1)*W]
        for x in range(x0,x1):
            t+=1
            if r[x]<INK: d+=1
    return d/max(t,1)

def rowprofile(raw,h,b):
    """how many distinct dark 'text lines' inside the box -> lettering signature"""
    x0,y0,x1,y1=b; flags=[]
    for y in range(y0,y1+1):
        r=raw[y*W:(y+1)*W]
        d=sum(1 for x in range(x0,x1) if r[x]<INK)
        flags.append(d/max(x1-x0,1) > 0.06)
    runs=0; prev=False
    for f in flags:
        if f and not prev: runs+=1
        prev=f
    return runs

def detect(path):
    raw,h=load(path); page=W*h; res=[]
    for c in comps(raw,h).values():
        x0,y0,x1,y1,a=c
        bw,bh=x1-x0,y1-y0+1
        if bw<22 or bh<11: continue
        if x0<=1 or y0<=1 or x1>=W-1 or y1>=h-1: continue
        f=a/page
        if not (0.0012<f<0.09): continue
        fill=a/(bw*bh)
        if not (0.14<fill<0.72): continue          # perforated by lettering
        if not (0.35<bw/bh<9.0): continue
        d=ink(raw,h,(x0,y0,x1,y1))
        if not (0.06<d<0.45): continue
        lines=rowprofile(raw,h,(x0,y0,x1,y1))
        if lines<2: continue                        # >=2 lines of lettering
        res.append(dict(px=(x0,y0,x1,y1),fill=round(fill,2),ink=round(d,2),lines=lines,
                        x=x0/W,y=y0/h,w=bw/W,hh=bh/h))
    res.sort(key=lambda b:(b['y'],b['x']))
    return res,h

if __name__=="__main__":
    p=sys.argv[1]; bs,h=detect(p)
    print(f"{os.path.basename(p)} ({W}x{h})  ->  {len(bs)} text regions\n")
    print(f"{'#':>2} {'x0':>4}{'y0':>5}{'x1':>5}{'y1':>5}   {'fill':>4} {'ink':>4} {'lines':>5}")
    for i,b in enumerate(bs,1):
        x0,y0,x1,y1=b['px']
        print(f"{i:2d} {x0:4d} {y0:4d} {x1:4d} {y1:4d}   {b['fill']:4.2f} {b['ink']:4.2f} {b['lines']:5d}")
