import sys; sys.path.insert(0,'tools')
from emu2600 import Atari
m=Atari(open(sys.argv[1],'rb').read())
last=None; ticks=0; snd=set()
for f in range(60*64):
    if f == 60*62: m.swchb &= 0xFE          # press Reset near the end
    if f == 60*62+10: m.swchb |= 1
    m.run_frame()
    st=(m.scram[0x78], m.scram[0x79], m.scram[0x7B])
    if st[:2]!=(last or (None,None))[:2] or (last and st[2]!=last[2]):
        print(f"t={f/60:5.1f}s level {st[0]+1} state {st[1]} timer segs {st[2]}")
    last=st
    for r,v in m.audio:
        if r==0x15: snd.add(v)
    m.audio.clear()
print("AUDC values seen", sorted(snd), "overruns", len(m.timer_overrun))
