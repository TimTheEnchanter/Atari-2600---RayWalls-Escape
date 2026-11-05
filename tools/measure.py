import sys, random; sys.path.insert(0,'tools')
from emu2600 import Atari
syms={l.split()[0]:int(l.split()[1][1:],16) for l in open(sys.argv[1]+'.sym')}
names={v:k for k,v in syms.items()}
def nm(pc):
    best=max((v for v in syms.values() if v<=pc), default=0); return names.get(best,'?')+f"+{pc-best}"
m=Atari(open(sys.argv[1],'rb').read())
if len(sys.argv)>3: m.swchb=int(sys.argv[3],0)
last=[None]; worst={}
orig=m.rd
def rd(a):
    if (a & 0x1fff) in (0x284,0x286):
        now=m.now(); val=orig(a)
        if last[0]:
            pc,c,v=last[0]
            if v and v>0: worst[pc]=max(worst.get(pc,(0,0)), (now-c, v))
        last[0]=(m.opc, now, val)
        return val
    return orig(a)
m.rd=rd
random.seed(int(sys.argv[2]) if len(sys.argv)>2 else 1)
J=[0xEF,0xEF,0xEF,0x7F,0xBF,0xDF,0xFF,0x6F,0xAF]
swaps=0; lastf=m.scram[0x60]; counts={}
NF=2000
for f in range(NF):
    if f%40==0: m.swcha=random.choice(J)
    n,_=m.run_frame(); counts[n]=counts.get(n,0)+1
    if m.scram[0x60]!=lastf: swaps+=1; lastf=m.scram[0x60]
for k,(c,v) in sorted(worst.items(), key=lambda kv:-kv[1][0]):
    print(f"{nm(k):18s} worst {c:5d} cycles after reading INTIM={v}  (budget ~{v*64})")
print("overruns", len(m.timer_overrun), m.timer_overrun[:3], "line counts", counts)
print("view updates/s", round(swaps/NF*60,1), "pos", m.ram[0x61], m.ram[0x63])
