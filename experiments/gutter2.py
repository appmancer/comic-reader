import subprocess, sys, os
W = 240
def rows_of(path):
    out = subprocess.run(["convert", path, "-resize", f"{W}x", "-colorspace","gray","-depth","8","gray:-"],
                         capture_output=True).stdout
    if not out: return None
    h = len(out)//W
    return [out[y*W:(y+1)*W] for y in range(h)], h

def uniform(vals, tol=18):
    return (max(vals) - min(vals)) <= tol

def bands(flags, minlen):
    out=[];s=None
    for i,f in enumerate(flags):
        if f and s is None: s=i
        elif not f and s is not None:
            if i-s>=minlen: out.append((s,i)); 
            s=None
    if s is not None and len(flags)-s>=minlen: out.append((s,len(flags)))
    return out

def analyse(path):
    r = rows_of(path)
    if not r: return None
    rows,h = r
    urow = [uniform(row) for row in rows]
    cols = [[rows[y][x] for y in range(h)] for x in range(W)]
    ucol = [uniform(c) for c in cols]
    hb = bands(urow, max(2,h//150)); vb = bands(ucol, 2)
    hin = [b for b in hb if b[0]>h*0.04 and b[1]<h*0.96]
    vin = [b for b in vb if b[0]>W*0.04 and b[1]<W*0.96]
    # full-bleed? corners vs each other
    corners = [rows[0][0],rows[0][-1],rows[-1][0],rows[-1][-1]]
    bleed = (max(corners)-min(corners)) > 40
    return len(hin), len(vin), bleed, [round(b[0]/h,2) for b in hin][:6]

tot=[0,0,0,0]
for p in sys.argv[1:]:
    a=analyse(p)
    if not a: continue
    tot[0]+=1; tot[1]+=a[0]; tot[2]+=a[1]; tot[3]+= 1 if a[2] else 0
    print(f"{os.path.basename(p)[:40]:42s} tiers={a[0]:2d} vsplit={a[1]:2d} bleed={'Y' if a[2] else 'n'} at={a[3]}")
if tot[0]:
    print(f"  -> {tot[0]} pages | mean tiers {tot[1]/tot[0]:.1f} | mean vsplits {tot[2]/tot[0]:.1f} | full-bleed {tot[3]}/{tot[0]}")
