"""Deterministic guided-view generator: page image -> ordered beat rects."""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path: sys.path.insert(0, ROOT)
WORK = os.environ.get('CG_WORK', os.path.join(ROOT, 'work'))
import subprocess, math, statistics
from collections import defaultdict

W=700; BRIGHT=205; DARK=110
FLAT_MAX=99.0   # off by default

def load(path):
    raw=subprocess.run(["convert",path,"-resize",f"{W}x","-colorspace","gray","-depth","8","gray:-"],
                       capture_output=True).stdout
    return raw, len(raw)//W

# ---------- 1. connected components over bright pixels ----------
def components(raw,h):
    parent={}
    def find(a):
        while parent[a]!=a: parent[a]=parent[parent[a]]; a=parent[a]
        return a
    def union(a,b):
        ra,rb=find(a),find(b)
        if ra!=rb: parent[rb]=ra
    rows=[];nxt=0
    for y in range(h):
        row=raw[y*W:(y+1)*W]; rs=[];x=0
        while x<W:
            if row[x]>=BRIGHT:
                s=x
                while x<W and row[x]>=BRIGHT: x+=1
                rs.append((s,x,nxt)); parent[nxt]=nxt; nxt+=1
            else: x+=1
        rows.append(rs)
        if y:
            for s,e,l in rs:
                for ps,pe,pl in rows[y-1]:
                    if ps<e and s<pe: union(pl,l)
    agg=defaultdict(lambda:[W,10**9,-1,-1,0])
    for y,rs in enumerate(rows):
        for s,e,l in rs:
            c=agg[find(l)]
            c[0]=min(c[0],s); c[1]=min(c[1],y); c[2]=max(c[2],e); c[3]=max(c[3],y); c[4]+=e-s
    return agg

# ---------- 2. balloon tests ----------
def stats(raw,h,b):
    x0,y0,x1,y1=b
    brights=[];dark=0;tot=0;rowdark=[]
    for y in range(y0,y1+1):
        r=raw[y*W:(y+1)*W]; d=0
        for x in range(x0,x1):
            v=r[x]; tot+=1
            if v>=BRIGHT: brights.append(v)
            if v<DARK: d+=1; dark+=1
        rowdark.append(d/max(x1-x0,1))
    flat = statistics.pstdev(brights) if len(brights)>8 else 99
    runs=[];s=None
    for i,f in enumerate([d>0.05 for d in rowdark]):
        if f and s is None: s=i
        elif not f and s is not None: runs.append(i-s); s=None
    if s is not None: runs.append(len(rowdark)-s)
    rhythm = (statistics.pstdev(runs)/statistics.mean(runs)) if len(runs)>=2 else 0.0
    return dark/max(tot,1), flat, len(runs), rhythm

def text_regions(raw,h):
    page=W*h; out=[]
    for c in components(raw,h).values():
        x0,y0,x1,y1,a=c
        bw,bh=x1-x0,y1-y0+1
        if bw<20 or bh<9: continue
        if x0<=1 or y0<=1 or x1>=W-1 or y1>=h-1: continue
        if not (0.0010 < a/page < 0.090): continue
        fill=a/(bw*bh)
        if not (0.14<fill<0.80): continue
        if not (0.35<bw/bh<11.0): continue
        ink,flat,lines,rhythm = stats(raw,h,(x0,y0,x1,y1))
        # Ink density spans a wide range and both ends were wrong. Short
        # balloons with big bold lettering ("MOM?") run to ~60%; large balloons
        # with modest lettering run to 3-4%, and the old 0.05 floor dropped
        # both speaker groups in the bottom pane of issue 100 page 5.
        if not (0.025<ink<0.70): continue
        if flat > FLAT_MAX: continue
        if lines<1: continue
        pass  # rhythm test removed: kills stacked balloon pairs
        out.append((x0,y0,x1,y1))
    out.sort(key=lambda b:(b[1],b[0]))
    return out

# ---------- 3. tiers, panels ----------
def bandify(boxes):
    tiers=[]
    for b in sorted(boxes,key=lambda b:b[1]):
        for t in tiers:
            if b[1] <= max(x[3] for x in t)-0.35*(b[3]-b[1]): t.append(b); break
        else: tiers.append([b])
    return tiers

def bright_col(raw,h,x,y0,y1): 
    n=max(y1-y0,1); return sum(1 for y in range(y0,y1) if raw[y*W+x]>=BRIGHT)/n
def bright_row(raw,h,y,x0,x1):
    r=raw[y*W:(y+1)*W]; return sum(1 for x in range(x0,x1) if r[x]>=BRIGHT)/max(x1-x0,1)

def panels_for(raw,h,tier,prev_bot,next_top):
    ty0=max(prev_bot, min(b[1] for b in tier)-70)
    ty1=min(next_top, max(b[3] for b in tier)+230)
    xs=[x for x in range(W) if bright_col(raw,h,x,ty0,ty1)<0.985]
    if not xs: return []
    cx0,cx1=min(xs),max(xs)+1
    ys=[y for y in range(ty0,ty1) if bright_row(raw,h,y,cx0,cx1)<0.985]
    if not ys: return []
    py0,py1=min(ys),max(ys)+1
    scan0=py0+int((py1-py0)*0.30)
    fl=[bright_col(raw,h,x,scan0,py1)>=0.94 for x in range(cx0,cx1)]
    runs=[];s=None
    for i,f in enumerate(fl):
        if f and s is None: s=i
        elif not f and s is not None:
            if i-s>=3: runs.append((cx0+s,cx0+i))
            s=None
    gs=[g for g in runs if g[0]>cx0+8 and g[1]<cx1-8]
    cuts=[cx0]+[(g[0]+g[1])//2 for g in gs]+[cx1]
    return [(cuts[i],py0,cuts[i+1],py1) for i in range(len(cuts)-1)]


# ---------- 3b. layout from drawn panel borders (thin long dark rules) ----------
def _rules(raw,h,horiz,x0,x1,y0,y1,minfrac=0.33,maxthick=3):
    span=(x1-x0) if horiz else (y1-y0)
    hits=[]
    for p in range(y0,y1) if horiz else range(x0,x1):
        best=cur=0
        if horiz:
            r=raw[p*W:(p+1)*W]
            for q in range(x0,x1):
                cur = cur+1 if r[q]<DARK else 0
                if cur>best: best=cur
        else:
            for q in range(y0,y1):
                cur = cur+1 if raw[q*W+p]<DARK else 0
                if cur>best: best=cur
        hits.append(best>=minfrac*span)
    bands=[];s=None
    for i,f in enumerate(hits):
        if f and s is None: s=i
        elif not f and s is not None: bands.append((s,i)); s=None
    if s is not None: bands.append((s,len(hits)))
    base = y0 if horiz else x0
    return [ (base+(a+b)//2) for a,b in bands if (b-a)<=maxthick ]

def content_box(raw,h):
    def bcol(x): return sum(1 for y in range(h) if raw[y*W+x]>=BRIGHT)/h
    def brow(y,a,b):
        r=raw[y*W:(y+1)*W]; return sum(1 for x in range(a,b) if r[x]>=BRIGHT)/max(b-a,1)
    xs=[x for x in range(W) if bcol(x)<0.97]
    if not xs: return (0,0,W,h)
    cx0,cx1=min(xs),max(xs)+1
    ys=[y for y in range(h) if brow(y,cx0,cx1)<0.97]
    if not ys: return (cx0,0,cx1,h)
    return (cx0,min(ys),cx1,max(ys)+1)

def layout(raw,h,text=()):
    cx0,cy0,cx1,cy1 = content_box(raw,h)
    hs = _rules(raw,h,True,cx0,cx1,cy0,cy1)
    edges=[cy0]+[y for y in hs if cy0+12<y<cy1-12]+[cy1]
    edges=sorted(set(edges))
    tiers=[]
    for i in range(len(edges)-1):
        a,b = edges[i],edges[i+1]
        if b-a < 40: continue
        if text and not any((t[1]+t[3])/2 > a and (t[1]+t[3])/2 < b for t in text): continue
        tiers.append((a+2,b-2))
    panels=[]
    for (ty0,ty1) in tiers:
        vs = _rules(raw,h,False,cx0,cx1,ty0,ty1,minfrac=0.88)
        # also accept clean white gutters
        def bcolr(x):
            n=max(ty1-ty0,1); return sum(1 for y in range(ty0,ty1) if raw[y*W+x]>=BRIGHT)/n
        fl=[bcolr(x)>=0.94 for x in range(cx0,cx1)]
        runs=[];s=None
        for i,f in enumerate(fl):
            if f and s is None: s=i
            elif not f and s is not None:
                if i-s>=3: runs.append(cx0+(s+i)//2)
                s=None
        cuts=sorted(set([cx0]+[v for v in vs+runs if cx0+15<v<cx1-15]+[cx1]))
        merged=[cuts[0]]
        for c in cuts[1:]:
            if c-merged[-1]>=25: merged.append(c)
        for i in range(len(merged)-1):
            panels.append((merged[i],ty0,merged[i+1],ty1))
    return panels

# ---------- 4. beat packing ----------
def U(rs): return (min(r[0] for r in rs),min(r[1] for r in rs),
                   max(r[2] for r in rs),max(r[3] for r in rs))

def plan(path, aspect=16/9, budget=0.25, zoom_band=1.20):
    raw,h=load(path); page=W*h
    tr=text_regions(raw,h)
    if not tr: return raw,h,[],[],[]
    tiers=bandify(tr)
    PAN=layout(raw,h,tr)
    if not PAN: PAN=[(0,0,W,h)]
    SW=math.sqrt(budget*page*aspect); SH=SW/aspect
    def owner(f):
        cx,cy=(f[0]+f[2])/2,(f[1]+f[3])/2
        cand=[i for i,p in enumerate(PAN) if p[0]<=cx<=p[2] and p[1]<=cy<=p[3]]
        if cand: return cand[0]
        return min(range(len(PAN)),key=lambda i:(cx-(PAN[i][0]+PAN[i][2])/2)**2+(cy-(PAN[i][1]+PAN[i][3])/2)**2)
    focal=[]
    for t in tiers:
        byp=defaultdict(list)
        for b in t: byp[owner(b)].append(b)
        for pi in sorted(byp,key=lambda i:PAN[i][0]): focal.append((U(byp[pi]),pi))
    def grow(rect,bound,z):
        tw,th=SW*z,SH*z; x0,y0,x1,y1=rect; bx0,by0,bx1,by1=bound
        cx,cy=(x0+x1)/2,(y0+y1)/2
        w=min(max(x1-x0,tw),bx1-bx0); hh=min(max(y1-y0,th),by1-by0)
        x0,x1,y0,y1=cx-w/2,cx+w/2,cy-hh/2,cy+hh/2
        if x0<bx0: x1+=bx0-x0; x0=bx0
        if x1>bx1: x0-=x1-bx1; x1=bx1
        if y0<by0: y1+=by0-y0; y0=by0
        if y1>by1: y0-=y1-by1; y1=by1
        return (int(x0),int(y0),int(x1),int(y1))
    def zoom(r): return max((r[2]-r[0])/SW,(r[3]-r[1])/SH)
    def solve(zmax):
        best=[None]*(n+1); best[0]=(0,0.0,[])
        for j in range(1,n+1):
            for i in range(j):
                if best[i] is None: continue
                if len({PAN[focal[k][1]][1] for k in range(i,j)})>1: continue
                bound=U([PAN[focal[k][1]] for k in range(i,j)])
                r=grow(U([focal[k][0] for k in range(i,j)]),bound,1.0)
                z=zoom(r)
                if z>zmax: continue
                over=max(0.0,z-1.02)*3.0
                u=U([focal[k][0] for k in range(i,j)])
                waste=1-((u[2]-u[0])*(u[3]-u[1]))/max((r[2]-r[0])*(r[3]-r[1]),1)
                cand=(best[i][0]+1,best[i][1]+waste+over,best[i][2]+[(i,j)])
                if best[j] is None or cand[:2]<best[j][:2]: best[j]=cand
        return best[n]
    n=len(focal)
    res = solve(1.02) or solve(1.55)      # relax only to rescue an infeasible page
    if res is None: return raw,h,tr,PAN,[]
    segs=res[2]
    zs=[zoom(grow(U([focal[k][0] for k in range(i,j)]),
                  U([PAN[focal[k][1]] for k in range(i,j)]),1.0)) for i,j in segs]
    tgt=min(max(zs),max(min(zs)*zoom_band,1.0))          # allow limited scale variation
    beats=[grow(U([focal[k][0] for k in range(i,j)]),
                U([PAN[focal[k][1]] for k in range(i,j)]),tgt) for i,j in segs]
    return raw,h,tr,PAN,beats

# ---------- 5. coverage: never skip part of the page ----------
def fill_gaps(raw,h,beats,aspect=16/9,budget=0.25):
    page=W*h
    cx0,cy0,cx1,cy1 = content_box(raw,h)
    SW=math.sqrt(budget*page*aspect); SH=SW/aspect
    covw=[0.0]*h
    for (x0,y0,x1,y1) in beats:
        for y in range(max(cy0,y0),min(cy1,y1)):
            covw[y]=max(covw[y],(min(x1,cx1)-max(x0,cx0))/max(cx1-cx0,1))
    bands=[];s=None
    for y in range(cy0,cy1):
        thin = covw[y] < 0.45
        if thin and s is None: s=y
        elif not thin and s is not None:
            if y-s>=40: bands.append((s,y))
            s=None
    if s is not None and cy1-s>=40: bands.append((s,cy1))

    def ink_extent(y0,y1):
        """crop in from the sides to where the art actually starts"""
        n=max(y1-y0,1)
        xs=[x for x in range(cx0,cx1)
            if sum(1 for y in range(y0,y1) if raw[y*W+x]>=BRIGHT)/n < 0.97]
        return (min(xs),max(xs)+1) if xs else (cx0,cx1)

    out=[]
    thin_h = 0.11*h
    keep=[]
    for (by0,by1) in bands:
        if by1-by0 < thin_h: 
            keep.append((by0,by1))          # too short to be its own beat
            continue
        gh=by1-by0
        rows = 1 if gh <= SH*1.45 else max(1,round(gh/SH))
        for r in range(rows):
            y0=int(by0+r*gh/rows); y1=int(by0+(r+1)*gh/rows)
            x0,x1 = ink_extent(y0,y1)
            if (x1-x0)*(y1-y0) > 0.03*page: out.append((x0,y0,x1,y1))
    # absorb thin bands into whichever beat sits closest vertically
    allb = list(beats)+out
    absorbed=[list(b) for b in allb]
    for (by0,by1) in keep:
        if not absorbed: 
            x0,x1=ink_extent(by0,by1); out.append((x0,by0,x1,by1)); continue
        cy=(by0+by1)/2
        i=min(range(len(absorbed)),
              key=lambda k: min(abs(absorbed[k][1]-cy),abs(absorbed[k][3]-cy)))
        absorbed[i][1]=min(absorbed[i][1],by0); absorbed[i][3]=max(absorbed[i][3],by1)
    nd=len(beats)
    beats[:] = [tuple(b) for b in absorbed[:nd]]
    out = [tuple(b) for b in absorbed[nd:]]
    return out

def plan_full(path, aspect=16/9, budget=0.25):
    raw,h,tr,pan,beats = plan(path,aspect,budget)
    gaps = fill_gaps(raw,h,beats,aspect,budget)
    tagged=[(b,'dialogue') for b in beats]+[(g,'art') for g in gaps]
    tagged.sort(key=lambda t:((t[0][1]+t[0][3])//2, t[0][0]))
    return raw,h,tr,pan,tagged
