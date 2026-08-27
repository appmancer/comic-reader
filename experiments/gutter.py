import subprocess, sys, os

W = 240
def profile(path):
    # grayscale raw bytes at fixed width
    out = subprocess.run(["convert", path, "-resize", f"{W}x", "-colorspace","gray","-depth","8","gray:-"],
                         capture_output=True).stdout
    if not out: return None
    h = len(out)//W
    if h < 50: return None
    rows = [out[y*W:(y+1)*W] for y in range(h)]
    return rows, h

def analyse(path):
    r = profile(path)
    if not r: return None
    rows, h = r
    # background = modal brightness of the page border ring
    border = list(rows[0]) + list(rows[-1]) + [rows[y][0] for y in range(h)] + [rows[y][-1] for y in range(h)]
    bg = max(set(border), key=border.count)
    tol = 24
    def near(v): return abs(v-bg) <= tol
    # horizontal gutter rows: >=97% of pixels are background
    grow = [sum(1 for v in row if near(v))/W >= 0.97 for row in rows]
    cols = [[rows[y][x] for y in range(h)] for x in range(W)]
    gcol = [sum(1 for v in c if near(v))/h >= 0.97 for c in cols]
    def runs(flags, minlen):
        out=[];s=None
        for i,f in enumerate(flags):
            if f and s is None: s=i
            elif not f and s is not None:
                if i-s>=minlen: out.append((s,i))
                s=None
        if s is not None and len(flags)-s>=minlen: out.append((s,len(flags)))
        return out
    hr = runs(grow, max(2,h//120)); vr = runs(gcol, 2)
    # strip the outer margins
    hr_in = [x for x in hr if x[0]>h*0.03 and x[1]<h*0.97]
    vr_in = [x for x in vr if x[0]>W*0.03 and x[1]<W*0.97]
    ink = sum(1 for row in rows for v in row if not near(v))/(h*W)
    return bg, len(hr_in), len(vr_in), ink

for p in sys.argv[1:]:
    a = analyse(p)
    if a: print(f"{os.path.basename(p)[:44]:46s} bg={a[0]:3d} h-cuts={a[1]:2d} v-cuts={a[2]:2d} ink={a[3]:.2f}")
