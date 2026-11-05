# RayWalls: an upright-wall raycaster for the Atari 2600

This is a test of how far an expanded cartridge can take a Merlin's Walls-style
raycaster. Unlike Merlin's Walls, which draws each ray as a horizontal stripe,
this demo draws walls upright, the normal way. v1 runs in Stella. v2 is the
speed-optimized version, and the original v1 source is kept in `v1/`.

## Files

| ROM | Columns | View updates/s (v1 → v2) |
|---|---|---|
| `raywalls.bin` | 40 (full playfield resolution) | 7.3 → about 12.5 |
| `raywalls_fast20.bin` | 20 (each 2 playfield pixels wide) | 14 → about 22 |

Both are 8K **F8SC** ROMs: F8 bank switching plus Superchip RAM. Stella should
autodetect them. If it doesn't, set the cartridge type to F8SC.

## Controls

* Joystick left/right: turn (5.6° per step)
* Joystick up/down: walk forward/back, with sliding collision against walls
* Left difficulty switch **A**: draw side walls solid instead of striped
* Right difficulty switch **A**: turn off the dark gaps at wall edges and corners

## How it works

* **Banks:** bank 0 holds the display kernels, main loop, buffer swap and
  movement. Bank 1 holds the ray casting, which bank 0 calls through a
  trampoline at `$FFD0`. Both banks have a reset stub that selects bank 0.
* **Map:** 16×16 cells, 256 facing directions. The field of view is 66°, with
  one ray per column and the column angles spaced by arctan so the
  perspective is correct.
* **Ray casting:** grid stepping (DDA) in 8.8 fixed point. 1/|cos| comes from
  a 65-entry table using quadrant symmetry. The first boundary distance is
  frac × 1/|cos|:
  * The fractional part uses only the high bytes of the quarter-square
    tables, accurate to within 1/256 of a cell.
  * The whole-number part is usually 1–3, so it's done with repeated adds.
    Only near-parallel rays need a full multiply.
* **Wall heights:** there are 8 height tables, one per bucket of column
  angles, each with that bucket's fisheye correction built in. So the hit
  distance maps straight to a height of 0–16 *levels* with no multiply.
  Each level is 3 to 8 scanlines tall, thinner near the horizon, so distant
  walls keep more detail.
* **Building the picture:** columns are gathered one playfield byte at a time
  (4 or 8 columns). Each column ORs its bit into `cur` and records itself in
  a drop table at its height + 1. Then the byte's 16 levels are written top
  to bottom in one cascading pass: at each level, the columns that have
  ended are removed. Every byte is written exactly once, so there's no
  clearing and no read-modify-write.
* **Frame buffer:** 16 levels × 6 playfield bytes = 96 bytes, with two copies.
  Buffer A sits in Superchip RAM and buffer B in console RAM at `$80`–`$DF`.
  One is shown while the other is built, so the picture never tears.
* **Kernel:** 160 lines of asymmetric playfield, mirrored above and below the
  horizon.
* **Scheduling:** the work runs in small chunks: ray setup, one DDA step,
  finishing a column, and two compose levels. Each chunk checks the RIOT
  timer before it starts and pauses when time is short. Because all state
  lives in RAM, the next free period simply picks up where the last one
  stopped.

## Measured in the test emulator

The test emulator is in `tools/`, and the numbers are over 2,000-frame random
walks, with all four difficulty-switch settings:

* Exactly 262 scanlines every frame (after the first, power-on frame).
* No timer overruns. The worst-case cost of each chunk is commented next to
  its threshold (`STARTT`, `FINT`, `COMPT`, `SWAPT`).
* `tools/profile2.py` shows where the time goes. For the 40-column build, a
  view went from about 62,000 cycles (v1) to about 31,700.
* `tools/compare.py` renders v1 and v2 at fixed positions. The output is
  pixel-identical except for 1-level height differences on a few columns,
  caused by the fisheye buckets.

## Building

```
python3 gen_tables.py 40        # or 20; writes config.inc, bank0.inc, bank1.inc
dasm raywalls.asm -f3 -oraywalls.bin
```

`tools/asm6502.py` is a small assembler for the DASM syntax subset this
source uses. It's what built these ROMs, because DASM wasn't available.

## Caveats and next steps

* v2 is tested in the bundled emulator only. v1 runs in Stella.
* There is one color per scanline. That's a playfield limit, which is why the
  wall faces use stripes rather than shading.
* About 90 bytes are free in bank 1, and about 2K in bank 0.
* More speed would need one of these:
  * A shorter view, such as 144 lines instead of 160. That gives about 15%
    more work time per frame.
  * Separate DDA loops for each direction.
  * Moving per-angle tables into bank 0 and calling them through a second
    trampoline.
