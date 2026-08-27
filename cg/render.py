import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path: sys.path.insert(0, ROOT)
WORK = os.environ.get('CG_WORK', os.path.join(ROOT, 'work'))
import sys, subprocess
S = WORK
sys.path.insert(0,S)
import cg.detect as guide
src,tag=sys.argv[1],sys.argv[2]
raw,h,tr,pan,tg = guide.plan_full(src)
draw=[]
for k,(b,kind) in enumerate(tg,1):
    x0,y0,x1,y1=b
    c = "#00e5ff" if kind=='dialogue' else "#ff9500"
    draw+=["-stroke",c,"-strokewidth","5","-fill","none","-draw",f"rectangle {x0+2},{y0+2} {x1-2},{y1-2}",
           "-stroke","none","-fill",c,"-pointsize","46","-weight","Bold",
           "-draw",f"text {x0+12},{y0+52} '{k}'"]
subprocess.run(["convert",src,"-resize","700x"]+draw+[f"{S}/{tag}_beats.jpg"],check=True)
SW,SH=543,305
seq=[]
for k,(b,kind) in enumerate(tg,1):
    x0,y0,x1,y1=b; f=f"{S}/{tag}_q{k:02d}.jpg"
    subprocess.run(["convert",src,"-resize","700x","-crop",f"{x1-x0}x{y1-y0}+{x0}+{y0}","+repage",
                    "-background","#0b0b0b","-gravity","center","-resize",f"{SW}x{SH}",
                    "-extent",f"{SW}x{SH}",f],check=True)
    seq.append(f)
subprocess.run(["convert"]+seq+["-bordercolor","#2a2a2a","-border","4","-append",f"{S}/{tag}_seq.jpg"],check=True)
print(f"{tag}: {sum(1 for _,k in tg if k=='dialogue')} dialogue + {sum(1 for _,k in tg if k=='art')} art = {len(tg)} beats")
