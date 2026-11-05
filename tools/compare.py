import sys; sys.path.insert(0,'tools')
from emu2600 import Atari, PAL
from PIL import Image
def shot(rom, pose, frames=40):
    m=Atari(open(rom,'rb').read())
    m.run_frame()
    # poke pose into zp (same addresses in v1/v2)
    for k,v in zip((0x60,0x61,0x62,0x63,0x64), pose): m.ram[k]=v
    for _ in range(frames): n,rows=m.run_frame()
    for i,r in enumerate(rows):
        if any(r): return rows[i:i+160]
poses=[(0x80,1,0x80,5,0),(0x40,6,0x80,7,200),(0x80,9,0x30,9,96),(0x90,3,0xA0,13,32),(0x20,13,0x80,4,150)]
tiles=[]; diffs=[]
for p in poses:
    a=shot(sys.argv[1],p); b=shot(sys.argv[2],p)
    d=sum(1 for ra,rb in zip(a,b) for x,y in zip(ra,rb) if x!=y); diffs.append(d)
    for k in (a,b):
        im=Image.new('RGB',(160,160)); im.putdata([PAL[c] for r in k for c in r]); tiles.append(im.resize((320,200),Image.NEAREST))
print("differing pixels per pose (of 25600):", diffs)
s=Image.new('RGB',(650,len(poses)*205),(255,255,255))
for i,t in enumerate(tiles): s.paste(t,((i%2)*330,(i//2)*205))
s.save(sys.argv[3])
