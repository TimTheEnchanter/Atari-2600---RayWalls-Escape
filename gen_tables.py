#!/usr/bin/env python3
"""Generate lookup tables (DASM syntax) for RayWalls v2.
Usage: gen_tables.py [COLS]  -> config.inc, bank0.inc, bank1.inc"""
import math, sys

COLS = int(sys.argv[1]) if len(sys.argv) > 1 else 40
HFOV = math.radians(66)          # horizontal field of view
ASPECT = 1.6                     # 2600 pixel is ~1.6x wider than tall
NLEV = 16
# scanlines per level, level 1 = next to the horizon (thin = finer detail far away)
LINES = [3, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6, 6, 7, 8, 8]
assert sum(LINES) == 80
MAXD = 10
SPEED = 0.16
NBUCK = 8                        # fisheye-correction buckets (one height table each)
# grey stone, lit at eye level, darker toward the top/bottom of near walls
WALL_COL = [0x0E, 0x0E, 0x0C, 0x0C, 0x0C, 0x0A, 0x0A, 0x0A,
            0x08, 0x08, 0x08, 0x06, 0x06, 0x06, 0x04, 0x04]
MAP = """\
################
#......#.......#
#.##...#..##...#
#.#....#...#...#
#.#..###...#...#
#..............#
####.##.####.###
#......#.......#
#.#.#..#..#....#
#......#..#.##.#
#.#.#.....#....#
#......####....#
###.####....#..#
#.......#...#..#
#...#.......#..#
################"""

def A(i): return 2 * math.pi * i / 256
def tab(out, name, vals, per=16):
    out.append(f"{name}")
    for i in range(0, len(vals), per):
        out.append("        .byte " + ",".join(f"${v & 255:02X}" for v in vals[i:i+per]))

import random
from collections import deque

def parse(m):
    rows = m.split("\n")
    assert len(rows) == 16 and all(len(r) == 16 for r in rows)
    return [[1 if ch == '#' else 0 for ch in r] for r in rows]

def gen_maze(seed, braid, rooms):
    """Perfect maze on 7x7 cells (odd coordinates), then knock out a share of
    dead ends (braid) and carve some 3x3 rooms."""
    rnd = random.Random(seed)
    g = [[1] * 16 for _ in range(16)]
    seen = {(0, 0)}; stack = [(0, 0)]; g[1][1] = 0
    while stack:
        cx, cy = stack[-1]
        nb = [(cx + dx, cy + dy, dx, dy) for dx, dy in ((1,0),(-1,0),(0,1),(0,-1))
              if 0 <= cx + dx < 7 and 0 <= cy + dy < 7 and (cx + dx, cy + dy) not in seen]
        if not nb: stack.pop(); continue
        nx, ny, dx, dy = rnd.choice(nb)
        g[1 + 2*cy + dy][1 + 2*cx + dx] = 0; g[1 + 2*ny][1 + 2*nx] = 0
        seen.add((nx, ny)); stack.append((nx, ny))
    for y in range(1, 14):
        for x in range(1, 14):
            if g[y][x] == 0:
                walls = [(x+dx, y+dy) for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)) if g[y+dy][x+dx]]
                if len(walls) == 3 and rnd.random() < braid:
                    inner = [(wx, wy) for wx, wy in walls if 1 <= wx <= 13 and 1 <= wy <= 13]
                    if inner:
                        wx, wy = rnd.choice(inner); g[wy][wx] = 0
    for _ in range(rooms):
        rx, ry = rnd.randrange(3, 11), rnd.randrange(3, 11)
        for y in range(ry - 1, ry + 2):
            for x in range(rx - 1, rx + 2): g[y][x] = 0
    return g

def bfs(g, sx, sy):
    d = {(sx, sy): 0}; q = deque([(sx, sy)])
    while q:
        x, y = q.popleft()
        for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)):
            n = (x + dx, y + dy)
            if g[n[1]][n[0]] == 0 and n not in d: d[n] = d[(x, y)] + 1; q.append(n)
    return d

def pick_exit(g, d):
    """Exit = wall block whose nearest reachable neighbour is as far as
    possible from the start; prefer blocks in the outer wall."""
    best = None
    for wy in range(16):
        for wx in range(16):
            if not g[wy][wx]: continue
            nd = [d[(wx+dx, wy+dy)] for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)) if (wx+dx, wy+dy) in d]
            if not nd: continue
            border = wx in (0, 15) or wy in (0, 15)
            score = min(nd) + (6 if border else 0)
            if best is None or score > best[0]: best = (score, wx, wy, min(nd))
    return best[1], best[2], best[3]

LEVELS = [(parse(MAP), 1, 5)]
for i, (seed, braid, rooms) in enumerate([(11, 0.8, 2), (23, 0.55, 2), (37, 0.35, 1), (41, 0.2, 1), (59, 0.0, 0)]):
    LEVELS.append((gen_maze(seed, braid, rooms), 1, 1))
lv_x, lv_y, lv_a, lv_exit, lv_t, packed = [], [], [], [], [], []
for g, sx, sy in LEVELS:
    d = bfs(g, sx, sy)
    ex, ey, plen = pick_exit(g, d)
    lv_x.append(sx); lv_y.append(sy); lv_exit.append(ey * 16 + ex)
    lv_a.append(0 if g[sy][sx + 1] == 0 else 64)
    secs = 20 + plen * 1.6
    lv_t.append(min(255, round(secs * 60 / (4 * 12))))     # 4-frame ticks per timer segment
    for y in range(16):
        for half in range(2):
            packed.append(sum(g[y][half * 8 + b] << b for b in range(8)))
    print(f"level {len(lv_x)}: path {plen} cells, exit ({ex},{ey}), time {secs:.0f}s")
    for y in range(16):
        print("   " + "".join("E" if (x, y) == (ex, ey) else ("S" if (x, y) == (sx, sy) else "#" if g[y][x] else ".") for x in range(16)))
NLEVELS = len(LEVELS)

# ---------------- bank 0: display + movement ----------------
b0 = []
tab(b0, "LINES", [0] + LINES + [0])          # index 0 and 17 are sentinels
FLOORCOL = 0xF4
tab(b0, "COLT", [FLOORCOL] + WALL_COL + [WALL_COL[-1]])   # [0] = floor (horizon line)
tab(b0, "MOVC", [round(SPEED * 256 * math.cos(A(i))) for i in range(256)])
tab(b0, "MAPS0", packed); tab(b0, "BITS0", [1 << i for i in range(8)])
tab(b0, "ATN16", [round(math.atan2(dy, dx) / (2 * math.pi) * 256) for dy in range(16) for dx in range(16)])
tab(b0, "LV_X", lv_x); tab(b0, "LV_Y", lv_y); tab(b0, "LV_A", lv_a)
tab(b0, "LV_EXIT", lv_exit); tab(b0, "LV_T", lv_t)
ceil = [0x80, 0x60, 0x40, 0xA0, 0x50, 0x00, 0x80, 0x80]   # per level while playing
tab(b0, "CEILT", ceil + [0x9C] * 8 + [0x44] * 8 + [0] * 8)   # x state (0 play,1 done,2 timeout,3 win)
TSEGS = 12
# status bar, left half (mirrored): PF0 b4-7 + PF1 b7,b6 = level pips, PF1 b5,b4 gap,
# PF1 b3-b0 + PF2 b0-b7 = timer segments shrinking from the centre outward
bar1 = [sum(1 << (3 - i) for i in range(min(t, 4))) for t in range(TSEGS + 1)]
bar2 = [sum(1 << j for j in range(max(0, t - 4))) for t in range(TSEGS + 1)]
tab(b0, "BAR1", bar1); tab(b0, "BAR2", bar2)
pip0 = [sum(1 << (4 + k) for k in range(min(l, 4))) for l in range(1, NLEVELS + 1)]
pip1 = [(0x80 if l >= 5 else 0) | (0x40 if l >= 6 else 0) for l in range(1, NLEVELS + 1)]
tab(b0, "PIP0", pip0); tab(b0, "PIP1", pip1)
# sound types: 0 none, 1 bump, 2 tick, 3 chime, 4 buzz, 5 fanfare
tab(b0, "SNDC", [0, 8, 4, 4, 3, 4, 0, 0])
tab(b0, "SNDF", [0, 24, 6, 4, 28, 3, 0, 0])
tab(b0, "SNDS", [0, 0, 0, 7, 0, 15, 0, 0])      # AUDF += countdown & SNDS (pitch sweep)
tab(b0, "SNDV", [0, 6, 6, 8, 8, 8, 0, 0])

# ---------------- bank 1: ray casting ----------------
b1 = []
f = (COLS / 2) / math.tan(HFOV / 2)
coloff, ccos, cmask, grp = [], [], [], []
for c in range(COLS):
    st = round(math.atan((c + 0.5 - COLS / 2) / f) / (2 * math.pi / 256))
    coloff.append(st & 255)
    ccos.append(math.cos(A(st)))
    w = 40 // COLS
    half, i = divmod(c * w, 20)
    if i < 4:    reg, bits = 0, [4 + i + k for k in range(w)]
    elif i < 12: reg, bits = 1, [7 - (i - 4) - k for k in range(w)]
    else:        reg, bits = 2, [(i - 12) + k for k in range(w)]
    cmask.append(sum(1 << b for b in bits))
    grp.append((half * 3 + reg) * NLEV)
# last column of each playfield byte -> buffer offset of that byte's level-1 entry
cgrp = [grp[c] if c == COLS - 1 or grp[c + 1] != grp[c] else 0xFF for c in range(COLS)]
# fisheye buckets
lo, hi = min(ccos), max(ccos)
edges = [lo + (hi - lo) * k / NBUCK for k in range(NBUCK + 1)]
cbuck = [min(NBUCK - 1, int((cc - lo) / (hi - lo + 1e-9) * NBUCK)) for cc in ccos]
bcos = []
for b in range(NBUCK):
    m = [ccos[c] for c in range(COLS) if cbuck[c] == b]
    bcos.append(sum(m) / len(m) if m else (edges[b] + edges[b + 1]) / 2)
tab(b1, "COLOFF", coloff); tab(b1, "CMASK", cmask); tab(b1, "CGRP", cgrp); tab(b1, "CBUCK", cbuck)
# height tables: Euclidean distance (4.4) * bucket cos -> lit levels
fv = f * (160 / COLS) * ASPECT
cum = [0]
for l in LINES: cum.append(cum[-1] + l)
for b in range(NBUCK):
    ht = []
    for idx in range(160):
        perp = (idx + 0.5) / 16 * bcos[b]
        half = fv / 2 / perp
        h = 0
        for l in range(1, NLEV + 1):
            if cum[l] - LINES[l - 1] / 2 <= half: h = l
        ht.append(h)
    tab(b1, f"HTB{b}", ht)
# 1/|cos| for folded angle 0..64 (8.8, capped)
ddl, ddh = [], []
for i in range(65):
    c = abs(math.cos(A(i)))
    v = 0x3FFF if c < 1 / 63.9 else min(0x3FFF, round(256 / c))
    ddl.append(v & 255); ddh.append(v >> 8)
tab(b1, "DDQL", ddl); tab(b1, "DDQH", ddh)
tab(b1, "MAPS1", packed); tab(b1, "BITS1", [1 << i for i in range(8)])
sq = [n * n // 4 for n in range(512)]
tab(b1, "SQL0", [v & 255 for v in sq[:256]]); tab(b1, "SQH0", [v >> 8 for v in sq[:256]])
tab(b1, "SQL1", [v & 255 for v in sq[256:]]); tab(b1, "SQH1", [v >> 8 for v in sq[256:]])

open("config.inc", "w").write(f"; generated by gen_tables.py\nCOLS    = {COLS}\nMAXD    = {MAXD}\nNLEVELS = {NLEVELS}\nTSEGS   = {TSEGS}\n")
open("bank0.inc", "w").write("\n".join(b0) + "\n")
open("bank1.inc", "w").write("\n".join(b1) + "\n")
print("COLS", COLS, "buckets", [round(x, 3) for x in bcos], "per bucket", [cbuck.count(b) for b in range(NBUCK)])
