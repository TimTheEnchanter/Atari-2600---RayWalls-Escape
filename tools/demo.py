import sys
sys.path.insert(0, 'tools')
from emu2600 import Atari, PAL
from PIL import Image
rom = open(sys.argv[1], 'rb').read()
out = sys.argv[2]
m = Atari(rom)
# script: (frames, swcha)  bits: 7 right,6 left,5 down,4 up (0 = pressed)
UP, L, R, NONE = 0xEF, 0xBF, 0x7F, 0xFF
script = [(30, NONE), (90, UP), (45, R), (70, UP), (60, L), (100, UP), (40, R & UP), (60, UP), (50, L)]
if len(sys.argv) > 3 and sys.argv[3] == 'solid': m.swchb |= 0xC0
imgs, swaps, counts = [], 0, set()
last = m.scram[0x60]
fidx = 0
def crop(rows):
    # first visible kernel line: find rows not in vblank -> use fixed offsets from first non-zero
    return rows
for frames, j in script:
    m.swcha = j
    for _ in range(frames):
        n, rows = m.run_frame(); counts.add(n); fidx += 1
        if m.scram[0x60] != last: swaps += 1; last = m.scram[0x60]
        if fidx % 2 == 0 and fidx > 1:
            imgs.append(rows)
total = sum(f for f, _ in script)
print("frames", total, "swaps", swaps, "view fps ~", round(swaps / total * 60, 1), "line counts", counts,
      "overruns", len(m.timer_overrun), "errors", m.errors[:3])
# find kernel rows: rows with colubk ceiling/floor; take the 160 rows starting at first row containing non-zero
def kernel(rows):
    for i, r in enumerate(rows):
        if any(r): return rows[i:i + 160]
    return rows[:160]
W, H = 5, 3
frames = []
for rows in imgs:
    k = kernel(rows)
    im = Image.new("RGB", (160, len(k)))
    im.putdata([PAL[c] for r in k for c in r])
    frames.append(im.resize((160 * W, len(k) * H), Image.NEAREST))
frames[0].save(out, save_all=True, append_images=frames[1:], duration=33, loop=0)
frames[len(frames) // 3].save(out.replace('.gif', '_a.png'))
frames[2 * len(frames) // 3].save(out.replace('.gif', '_b.png'))
frames[-1].save(out.replace('.gif', '_c.png'))
