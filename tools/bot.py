"""Play RayWalls in the emulator: follow the BFS path to each exit."""
import sys, math, re; sys.path.insert(0, 'tools')
from collections import deque
from emu2600 import Atari, PAL
from PIL import Image
rom = open(sys.argv[1], 'rb').read()
gif = sys.argv[2] if len(sys.argv) > 2 else None
maxframes = int(sys.argv[3]) if len(sys.argv) > 3 else 60 * 60 * 8
# read packed maps + exits from bank0.inc
inc = open('bank0.inc').read()
def table(name):
    m = re.search(rf"^{name}\n((?:\s+\.byte .*\n)+)", inc, re.M)
    return [int(v, 16) for v in re.findall(r"\$([0-9A-F]{2})", m.group(1))]
MAPS, EXITS = table("MAPS0"), table("LV_EXIT")
def wall(lv, x, y):
    c = y * 16 + x; return (MAPS[lv * 32 + (c >> 3)] >> (c & 7)) & 1
def path(lv, sx, sy):
    ex, ey = EXITS[lv] % 16, EXITS[lv] // 16
    prev = {(sx, sy): None}; q = deque([(sx, sy)])
    while q:
        p = q.popleft()
        if abs(p[0] - ex) + abs(p[1] - ey) == 1:
            out = [(ex, ey)]
            while p: out.append(p); p = prev[p]
            return out[::-1]
        for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)):
            n = (p[0] + dx, p[1] + dy)
            if not wall(lv, *n) and n not in prev: prev[n] = p; q.append(n)
m = Atari(rom)
events, frames, f = [], [], 0
last = None
while f < maxframes:
    lv, game = m.scram[0x78], m.scram[0x79]
    if (lv, game) != last:
        events.append((f, lv + 1, ["playing", "level done", "time out", "victory"][game])); last = (lv, game)
        if game == 3 and len([e for e in events if e[2] == 'victory']) == 1: vic = f
    px = m.ram[0x61] + m.ram[0x60] / 256; py = m.ram[0x63] + m.ram[0x62] / 256; ang = m.ram[0x64]
    joy = 0xFF
    if game == 0:
        p = path(lv, int(px), int(py)) or [(int(px), int(py))]
        tx, ty = (p[1][0] + 0.5, p[1][1] + 0.5) if len(p) > 1 else (p[0][0] + .5, p[0][1] + .5)
        want = math.atan2(ty - py, tx - px) / (2 * math.pi) * 256
        diff = (want - ang + 128) % 256 - 128
        if diff > 3: joy &= 0x7F
        elif diff < -3: joy &= 0xBF
        if abs(diff) < 24: joy &= 0xEF
    m.swcha = joy
    n, rows = m.run_frame(); f += 1
    if gif and f % 3 == 0 and len(frames) < 1500:
        st = next(i for i, r in enumerate(rows) if any(r))
        k = rows[st:st + 172]
        im = Image.new("RGB", (160, len(k))); im.putdata([PAL[c] for r in k for c in r])
        frames.append(im.resize((480, len(k) * 2), Image.NEAREST))
    if game == 3 and m.scram[0x7A] < 5: break
for e in events: print(f"frame {e[0]:6d} ({e[0]/60:6.1f}s)  level {e[1]}  {e[2]}")
print("overruns", len(m.timer_overrun), "errors", m.errors[:3])
if gif:
    frames[0].save(gif, save_all=True, append_images=frames[1:], duration=50, loop=0)
    print("gif frames", len(frames))
