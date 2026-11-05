import sys, random; sys.path.insert(0,'tools')
from emu2600 import Atari
syms={l.split()[0]:int(l.split()[1][1:],16) for l in open(sys.argv[1]+'.sym')}
code=sorted((v,k) for k,v in syms.items() if 0xF100<=v<0xFFFF and k[0].isupper() or k in ('StepLoop',))
groups={'setup':['CastColumn','CXNeg','CXF','CYNeg','CYF'],'step':['StepLoop','StepGo','DoStepY'],
 'finish':['Hit','HIdx','SigY','SigC','NoEdge','FillS','Solid','Fill','ColDone','NoHit'],
 'mul':['Mul8','MulHi','MulDif','MulPos'],'swap':['Swap','BackIsB','DoClear','ClrLoop','NoRight','NoLeft','NoUp','NoDown','TryX','TXNeg','TXChk','TXDone','TryY','TYNeg','TYChk','TYDone'],
 'work':['Work','WorkLoop','WNoResume','WSwap','WDone'],'idle':['VBWait','OSWait']}
g_of={n:g for g,ns in groups.items() for n in ns}
import bisect
addrs=[a for a,_ in code]; names=[n for _,n in code]
m=Atari(open(sys.argv[1],'rb').read())
tally={}
step=m.step
def st():
    pc=m.pc; c0=m.cycles; step()
    i=bisect.bisect_right(addrs,pc)-1
    g=g_of.get(names[i],'other') if i>=0 else 'other'
    tally[g]=tally.get(g,0)+m.cycles-c0
m.step=st
random.seed(7); J=[0xEF,0xEF,0x7F,0xBF,0x6F]
swaps=0; last=m.scram[0x60]; NF=600
for f in range(NF):
    if f%40==0: m.swcha=random.choice(J)
    m.run_frame()
    if m.scram[0x60]!=last: swaps+=1; last=m.scram[0x60]
tot=sum(v for k,v in tally.items() if k!='other')
for k,v in sorted(tally.items(), key=lambda kv:-kv[1]):
    print(f"{k:7s} {v/swaps:8.0f} cycles/view  {100*v/tot:5.1f}%")
print("views", swaps, "per s", round(swaps/NF*60,1))
