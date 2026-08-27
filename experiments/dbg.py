import subprocess,sys
sys.path.insert(0,'/home/sjp/Workspace/comic-guide/work')
import balloons as B
raw,h = B.load(sys.argv[1])
page=B.W*h
cs=sorted(B.components(raw,h).values(), key=lambda c:-c[4])[:12]
print(f"page {B.W}x{h}   top components by area:")
for c in cs:
    x0,y0,x1,y1,a=c
    print(f"  area={a/page:6.3f}pp  bbox=({x0:3d},{y0:3d})-({x1:3d},{y1:3d})  "
          f"w={x1-x0:3d} h={y1-y0+1:3d} fill={a/max((x1-x0)*(y1-y0+1),1):.2f} "
          f"{'EDGE' if (x0<=1 or y0<=1 or x1>=B.W-1 or y1>=h-1) else ''}")
