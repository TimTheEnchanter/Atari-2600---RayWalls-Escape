import sys, time
sys.path.insert(0, 'tools')
from emu2600 import Atari, frame_image
rom = open(sys.argv[1], 'rb').read()
N = int(sys.argv[2]) if len(sys.argv) > 2 else 60
m = Atari(rom)
t = time.time()
counts = []
for f in range(N):
    n, rows = m.run_frame()
    counts.append(n)
print("time", round(time.time() - t, 2), "s")
print("line counts:", sorted(set(counts)), "last10", counts[-10:])
print("errors:", m.errors[:5], "overruns:", len(m.timer_overrun), [hex(x) for x in m.timer_overrun[:5]])
print("front", m.scram[0x60], "bcol", m.scram[0x61])
frame_image(rows).resize((640, len(rows) * 2)).save(sys.argv[3] if len(sys.argv) > 3 else 'build/frame.png')
