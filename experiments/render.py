import sys, subprocess, math
S='/home/sjp/Workspace/comic-guide/work'
sys.path.insert(0,S)
import guide
src=sys.argv[1]; tag=sys.argv[2]
raw,h,tr,pan,beats = guide.plan(src)
cols=["#ffcc00","#00e5ff","#ff1e8e","#42f5a1","#c084fc","#fb923c"]
draw=[]
for k,(x0,y0,x1,y1) in enumerate(beats,1):
    c=cols[(k-1)%6]
    draw+=["-stroke",c,"-strokewidth","5","-fill","none","-draw",f"rectangle {x0},{y0} {x1},{y1}",
           "-stroke","none","-fill",c,"-pointsize","44","-weight","Bold",
           "-draw",f"text {x0+10},{y0+48} '{k}'"]
subprocess.run(["convert",src,"-resize","700x"]+draw+[f"{S}/{tag}_beats.jpg"],check=True)
# the actual sequence: full page -> beats -> full page
SW,SH=543,305
seq=[f"{S}/{tag}_s00.jpg"]
subprocess.run(["convert",src,"-resize",f"{SW*2}x{SH*2}","-background","#0b0b0b","-gravity","center",
                "-extent",f"{SW*2}x{SH*2}",seq[0]],check=True)
for k,(x0,y0,x1,y1) in enumerate(beats,1):
    f=f"{S}/{tag}_s{k:02d}.jpg"
    subprocess.run(["convert",src,"-resize","700x","-crop",f"{x1-x0}x{y1-y0}+{x0}+{y0}","+repage",
                    "-background","#0b0b0b","-gravity","center",
                    "-resize",f"{SW*2}x{SH*2}","-extent",f"{SW*2}x{SH*2}",f],check=True)
    seq.append(f)
seq.append(f"{S}/{tag}_s99.jpg")
subprocess.run(["cp",seq[0],seq[-1]],check=True)
subprocess.run(["convert"]+seq+["-bordercolor","#2a2a2a","-border","4","-append",f"{S}/{tag}_sequence.jpg"],check=True)
print(f"{tag}: {len(tr)} text, {len(pan)} panels, {len(beats)} beats -> {len(seq)} screens")
