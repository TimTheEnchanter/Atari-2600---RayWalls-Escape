# RayWalls Escape: a maze game on an upright-wall raycaster for the Atari 2600

RayWalls started as a test of how far an expanded cartridge can take a Merlin's
Walls-style raycaster: walls drawn upright instead of as horizontal stripes.
Version 3 turns it into a game. v1 ran in Stella, and v2 (the speed-optimized
engine) was reported as running in Stella too. The source for v1 and v2 is
kept in `v1/` and `v2/`.

## The game

Find the exit on each of 6 levels before the timer runs out.

* **The exit** is one block in the wall, usually in the outer wall, at the far
  end of the path from the start. Its stripe pattern flips on every view
  update, so it shimmers. Walk into it to finish the level.
* **Status bar** (under the view):
  * The green blocks at both ends show the level number. Pips 1–4 sit at the
    edge, and pips 5–6 continue inward.
  * The green timer bar shrinks from the centre outward. It turns red and
    ticks during the last 3 of its 12 segments.
  * The yellow compass marker shows the direction of the exit. The middle of
    the screen is straight ahead, and the edges are 90° left or right. When
    the exit is behind you, the marker sits at the nearer edge and blinks.
* **Sounds:**
  * A bump when you walk into a wall.
  * A tick when time is low.
  * A rising chime when you find the exit.
  * A buzz when time runs out; the level then restarts.
  * A fanfare and a colour-cycling ceiling after level 6; the game then starts over.
* **Levels:**
  * Level 1 is the original open map.
  * Levels 2–6 are generated mazes. Each has fewer loops and longer paths
    than the one before.

| Level | Shortest path (cells) | Time limit |
|---|---|---|
| 1 | 23 | 57 s |
| 2 | 24 | 58 s |
| 3 | 32 | 71 s |
| 4 | 38 | 81 s |
| 5 | 72 | 135 s |
| 6 | 65 | 124 s |

Each limit is 20 s plus 1.6 s per cell. A bot that knows the route uses
about 30–40% of the limit.

## Files and controls

| ROM | Columns | View updates/s |
|---|---|---|
| `raywalls_escape.bin` | 40 | about 10 |
| `raywalls_escape_fast20.bin` | 20 | about 18 |

These are 8K **F8SC** ROMs. Compared with the v2 engine demo (12.5 and 22),
about 15% of the work time now goes to game logic, positioning the compass
sprite, and the status bar.

* Joystick left/right: turn. Up/down: walk, with sliding collision against walls.
* **Reset**: restart from level 1.
* Left difficulty switch **A**: draw side walls solid instead of striped.
* Right difficulty switch **A**: turn off the dark gaps at wall edges and corners.

## How it works

### Engine (from v2)

* **Banks:** bank 0 holds the kernels, main loop, game logic and movement.
  Bank 1 holds the ray casting, which bank 0 calls through a trampoline at
  `$FFD0`.
* **Ray casting:** grid stepping (DDA) in 8.8 fixed point. Fisheye
  correction is built into 8 height tables. Columns are combined one
  playfield byte at a time in a single cascading pass.
* **Frame buffer:** two copies, one in Superchip RAM and one in console RAM.
  One is shown while the other is built, so the picture never tears.
* **Scheduling:** small chunks of work check the RIOT timer before starting.
  A timer reading of N only guarantees about (N−1)×64 cycles, so each
  threshold is the chunk's worst case ÷ 64, plus 2.

### New in v3

* **Maps:** one bit per cell, so each level is 32 bytes. The DDA step looks
  up `MAPS[level*32 + cell/8] & bit[cell&7]`. A copy in bank 0 is used for
  collision. The exit is an ordinary wall block whose cell number is stored
  separately.
* **The exit shimmer:** exit columns get dark odd levels on one view and dark
  even levels on the next. This is a second stripe mask, `V_OMASK`, applied
  in the compose pass.
* **Status bar:** a reflected playfield pattern plus the P0 sprite, written
  once and then held for about 8 lines with no CPU. Ray casting keeps running
  underneath it, because its own short timer period follows the view. The
  compass marker is positioned during VBLANK from a 16×16 arctan table. The
  bearing uses half-cell coordinates.
* **RAM:** free bytes came from aliases that are never live at the same time:
  `prodL`/`prodH` share with `distL`/`distH`, and `colr` shares with `tmp`.
  These hold the frame counter, the exit cell and the map offset in zero page.
  The last 8 bytes of Superchip RAM hold the level, game state, timer, sound,
  ceiling colour and compass shape.

## Tested in the bundled emulator

* **Playthrough:** `tools/bot.py` plays all 6 levels to the victory screen in
  both builds, following the shortest path.
* **Flow:** `tools/flowtest.py` checks that running out of time leads to the
  time-out state and a restart of the level.
* **Timing:** 2,000-frame random walks with 4 seeds per build give exactly
  262 lines on every frame and no timer overruns.
* **Not yet tried in Stella.**
* **Note for v2:** the off-by-one timer lesson above means v2's `COMPT = 3`
  was slightly too small. It could rarely cause a 263-line frame; v3 fixes it.

## Building

```
python3 gen_tables.py 40        # or 20; writes config.inc, bank0.inc, bank1.inc
dasm raywalls.asm -f3 -oraywalls.bin
```

`gen_tables.py` also generates the levels: seeded mazes, a BFS search to
place the exit, and the time limits. It prints each map when it runs.
`tools/asm6502.py` is the small DASM-syntax assembler that built these ROMs.

## Free space and ideas

* About 80 bytes are free in bank 1 and about 1.2K in bank 0.
* Ideas for later:
  * Sprites for keys or monsters.
  * A score or time bonus.
  * More levels, at 32 bytes each.
  * A title screen.
