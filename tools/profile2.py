import sys, random, re, bisect; sys.path.insert(0,'tools')
from emu2600 import Atari
syms={l.split()[0]:int(l.split()[1][1:],16) for l in open(sys.argv[1]+'.sym')}
src=open('raywalls.asm').read()
b1start=src.rindex('; Bank 1: ray casting')
labels=re.findall(r'^([A-Za-z_][A-Za-z0-9_]*)', src, re.M)
bank={}
for mm in re.finditer(r'^([A-Za-z_][A-Za-z0-9_]*)', src, re.M):
    bank[mm.group(1)] = 1 if mm.start()>b1start else 0
groups={'setup':'CastColumn FX1 FY1 CXNeg CXF MX1h MX1d MX1p MX2h MX2d MX2p CYNeg CYF MY1h MY1d MY1p MY2h MY2d MY2p',
 'step':'StepLoop StepGo DoStepY','finish':'Hit HB0 HB2 HB4 HBodd HB1 HB3 HB5 HGot SigY SigC NoEdge NoDrop ColEnd NotEnd NoHit',
 'compose':'Compose CLoop CGo','work':'Work WL WComp WNew WCast','idle':'VBWait OSWait',
 'swap':'Swap BackIsB SwapRst NoRight NoLeft NoUp NoDown TryX TXNeg TXChk TXDone TryY TYNeg TYChk TYDone'}
g_of={n:g for g,ns in groups.items() for n in ns.split()}
tabs={0:[],1:[]}
for n,a in syms.items():
    if n in bank and 0xF100<=a<0xFFD0: tabs[bank[n]].append((a,n))
for b in tabs: tabs[b].sort()
m=Atari(open(sys.argv[1],'rb').read())
tally={}; step=m.step
def st():
    pc=m.pc; b=m.bank; c0=m.cycles; step()
    t=tabs[b]; i=bisect.bisect_right([a for a,_ in t],pc)-1
    g=g_of.get(t[i][1],'other') if i>=0 and pc<0xFFD0 else 'tramp'
    tally[g]=tally.get(g,0)+m.cycles-c0
m.step=st
random.seed(7); J=[0xEF,0xEF,0x7F,0xBF,0x6F]
swaps=0; last=m.scram[0x60]; NF=600
for f in range(NF):
    if f%40==0: m.swcha=random.choice(J)
    m.run_frame()
    if m.scram[0x60]!=last: swaps+=1; last=m.scram[0x60]
tot=sum(v for k,v in tally.items() if k not in('other',))
for k,v in sorted(tally.items(), key=lambda kv:-kv[1]):
    if k!='other': print(f"{k:8s} {v/swaps:8.0f} cycles/view  {100*v/tot:5.1f}%")
print("total work+idle per view", round(tot/swaps), " views/s", round(swaps/NF*60,1))
