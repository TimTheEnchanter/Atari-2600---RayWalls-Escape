#!/usr/bin/env python3
"""Minimal Atari 2600 emulator for testing: 6507 (official opcodes), RIOT timer/IO,
TIA playfield + background (no sprites), F8 + Superchip banking.
Reports per-frame scanline counts and timer overruns, renders frames to PIL images."""
import colorsys

def ntsc_rgb(c):
    hue, lum = (c >> 4) & 15, (c >> 1) & 7
    v = 0.12 + lum / 7 * 0.85
    if hue == 0:
        g = int(v * 255); return (g, g, g)
    h = [0,52,38,22,355,320,285,255,232,212,192,168,132,96,70,40][hue] / 360
    r, g, b = colorsys.hsv_to_rgb(h, 0.75 - lum * 0.05, v)
    return (int(r * 255), int(g * 255), int(b * 255))
PAL = [ntsc_rgb(i) for i in range(256)]

# (mnemonic, mode, cycles)
T = {}
def d(op, mn, mode, cyc):
    T[op] = (mn, mode, cyc)
for mn, base in [('ORA',0x00),('AND',0x20),('EOR',0x40),('ADC',0x60),('STA',0x80),('LDA',0xA0),('CMP',0xC0),('SBC',0xE0)]:
    for off, mode, cyc in [(0x01,'izx',6),(0x05,'zp',3),(0x09,'imm',2),(0x0D,'abs',4),(0x11,'izy',5),(0x15,'zpx',4),(0x19,'aby',4),(0x1D,'abx',4)]:
        if mn == 'STA' and mode == 'imm': continue
        c = cyc
        if mn == 'STA' and mode in ('izy',): c = 6
        if mn == 'STA' and mode in ('aby','abx'): c = 5
        d(base + off, mn, mode, c)
for mn, base in [('ASL',0x00),('ROL',0x20),('LSR',0x40),('ROR',0x60)]:
    d(base+0x0A, mn, 'acc', 2); d(base+0x06, mn, 'zp', 5); d(base+0x16, mn, 'zpx', 6)
    d(base+0x0E, mn, 'abs', 6); d(base+0x1E, mn, 'abx', 7)
for mn, base in [('DEC',0xC0),('INC',0xE0)]:
    d(base+0x06, mn, 'zp', 5); d(base+0x16, mn, 'zpx', 6); d(base+0x0E, mn, 'abs', 6); d(base+0x1E, mn, 'abx', 7)
for op, mn in [(0x10,'BPL'),(0x30,'BMI'),(0x50,'BVC'),(0x70,'BVS'),(0x90,'BCC'),(0xB0,'BCS'),(0xD0,'BNE'),(0xF0,'BEQ')]:
    d(op, mn, 'rel', 2)
for op, mn in [(0x18,'CLC'),(0x38,'SEC'),(0x58,'CLI'),(0x78,'SEI'),(0xB8,'CLV'),(0xD8,'CLD'),(0xF8,'SED'),
               (0xAA,'TAX'),(0x8A,'TXA'),(0xCA,'DEX'),(0xE8,'INX'),(0xA8,'TAY'),(0x98,'TYA'),(0x88,'DEY'),
               (0xC8,'INY'),(0x9A,'TXS'),(0xBA,'TSX'),(0xEA,'NOP')]:
    d(op, mn, 'imp', 2)
d(0x48,'PHA','imp',3); d(0x68,'PLA','imp',4); d(0x08,'PHP','imp',3); d(0x28,'PLP','imp',4)
d(0x20,'JSR','abs',6); d(0x60,'RTS','imp',6); d(0x40,'RTI','imp',6); d(0x00,'BRK','imp',7)
d(0x4C,'JMP','abs',3); d(0x6C,'JMP','ind',5)
d(0x24,'BIT','zp',3); d(0x2C,'BIT','abs',4)
d(0xA2,'LDX','imm',2); d(0xA6,'LDX','zp',3); d(0xB6,'LDX','zpy',4); d(0xAE,'LDX','abs',4); d(0xBE,'LDX','aby',4)
d(0xA0,'LDY','imm',2); d(0xA4,'LDY','zp',3); d(0xB4,'LDY','zpx',4); d(0xAC,'LDY','abs',4); d(0xBC,'LDY','abx',4)
d(0x86,'STX','zp',3); d(0x96,'STX','zpy',4); d(0x8E,'STX','abs',4)
d(0x84,'STY','zp',3); d(0x94,'STY','zpx',4); d(0x8C,'STY','abs',4)
d(0xE0,'CPX','imm',2); d(0xE4,'CPX','zp',3); d(0xEC,'CPX','abs',4)
d(0xC0,'CPY','imm',2); d(0xC4,'CPY','zp',3); d(0xCC,'CPY','abs',4)
PENALTY = {'LDA','LDX','LDY','ORA','AND','EOR','ADC','SBC','CMP'}

class Atari:
    def __init__(self, rom):
        self.rom = rom
        self.nbanks = len(rom) // 4096
        self.bank = self.nbanks - 1
        self.sc = len(rom) == 8192
        self.scram = [0] * 128
        self.ram = [0] * 128
        self.a = self.x = self.y = 0; self.sp = 0xFD
        self.n = self.v = self.dflag = self.i = self.z = self.c = 0
        self.cycles = 0
        self.swcha = 0xFF; self.swchb = 0x0B; self.fire = True
        self.tim_val = 0; self.tim_int = 1024; self.tim_start = 0
        # TIA state
        self.pf0 = self.pf1 = self.pf2 = 0; self.colupf = 0; self.colubk = 0; self.ctrlpf = 0
        self.vblank = 0; self.vsync = 0
        self.grp0 = 0; self.p0x = 0; self.nusiz0 = 0; self.colup0 = 0; self.hmp0 = 0
        self.audio = []
        self.rclk = 0           # absolute color clock rendered up to
        self.lines = {}         # absolute line -> list of colors
        self.frame_start_line = 0
        self.frames = []        # (num_lines, image_rows)
        self.cur_rows = []
        self.timer_overrun = []
        self.errors = []
        self.pc = self.r16(0xFFFC)

    # ---------------- bus ----------------
    def now(self): return self.cycles + self.icyc
    def cart(self, off, write, val=0):
        if self.nbanks == 2 and off in (0xFF8, 0xFF9):
            self.bank = off - 0xFF8
        if self.sc and off < 0x100:
            if off < 0x80:
                if write: self.scram[off] = val
                else: self.errors.append(f"read SC write-port ${off:03X} pc={self.opc:04X}")
                return 0
            if write: self.errors.append(f"write SC read-port pc={self.opc:04X}"); return 0
            return self.scram[off - 0x80]
        return self.rom[self.bank * 4096 + off]
    def rd(self, a):
        a &= 0x1FFF
        if a & 0x1000: return self.cart(a & 0xFFF, False)
        if not a & 0x80:
            r = a & 0x0F
            if r == 0x0C: return 0x00 if self.fire is False else 0x80
            return 0
        if not a & 0x200: return self.ram[a & 0x7F]
        r = a & 7
        if r == 0: return self.swcha
        if r == 2: return self.swchb
        if r in (4, 6): return self.intim()
        return 0
    def wr(self, a, v):
        a &= 0x1FFF
        if a & 0x1000: self.cart(a & 0xFFF, True, v); return
        if not a & 0x80: self.tia_write(a & 0x3F, v); return
        if not a & 0x200: self.ram[a & 0x7F] = v; return
        if a & 0x14 == 0x14:
            self.tim_val = v; self.tim_int = [1, 8, 64, 1024][a & 3]; self.tim_start = self.now()
    def intim(self):
        e = self.now() - self.tim_start
        k = 1 + (e - 1) // self.tim_int if e >= 1 else 0
        if k <= self.tim_val: return self.tim_val - k
        e2 = e - (self.tim_val + 1) * self.tim_int
        if e2 > 8: self.timer_overrun.append((self.opc, e2))   # read well after expiry
        return 0          # simplification: report expired (loops then exit)
    def r16(self, a): return self.rd(a) | (self.rd(a + 1) << 8)

    # ---------------- TIA ----------------
    def pfbit(self, x):
        p = x >> 2
        if p >= 20:
            p -= 20
            if self.ctrlpf & 1: p = 19 - p
        if p < 4: return (self.pf0 >> (4 + p)) & 1
        if p < 12: return (self.pf1 >> (11 - p)) & 1
        return (self.pf2 >> (p - 12)) & 1
    def render_to(self, clk):
        while self.rclk < clk:
            line, c = divmod(self.rclk, 228)
            end = min(clk, (line + 1) * 228)
            row = self.lines.get(line)
            if row is None: row = self.lines[line] = [0] * 160
            for cc in range(max(c, 68), end - line * 228):
                x = cc - 68
                if self.vblank & 2: row[x] = 0
                else:
                    c0 = self.colupf if self.pfbit(x) else self.colubk
                    if self.grp0:
                        w = 2 if (self.nusiz0 & 7) == 5 else (4 if (self.nusiz0 & 7) == 7 else 1)
                        o = (x - self.p0x) % 160
                        if o < 8 * w and (self.grp0 >> (7 - o // w)) & 1: c0 = self.colup0
                    row[x] = c0
            self.rclk = end
    def tia_write(self, r, v):
        self.render_to(self.now() * 3)
        if r == 0x00:
            if self.vsync & 2 and not v & 2: self.end_frame()
            self.vsync = v
        elif r == 0x01: self.vblank = v
        elif r == 0x02: self.wsync = True
        elif r == 0x08: self.colupf = v
        elif r == 0x09: self.colubk = v
        elif r == 0x0A: self.ctrlpf = v
        elif r == 0x0D: self.pf0 = v
        elif r == 0x0E: self.pf1 = v
        elif r == 0x0F: self.pf2 = v
        elif r == 0x04: self.nusiz0 = v
        elif r == 0x06: self.colup0 = v
        elif r == 0x1B: self.grp0 = v
        elif r == 0x20: self.hmp0 = v
        elif r == 0x10:
            c = (self.now() * 3) % 228
            self.p0x = 3 if c < 68 else (c - 68 + 5) % 160
        elif r == 0x2A:
            m = self.hmp0 >> 4
            if m > 7: m -= 16
            self.p0x = (self.p0x - m) % 160
        elif r in (0x15, 0x17, 0x19): self.audio.append((r, v))
    def end_frame(self):
        cur = self.now() * 3 // 228
        n = cur - self.frame_start_line
        rows = [self.lines.get(l, [0] * 160) for l in range(self.frame_start_line, cur)]
        self.frames.append((n, rows))
        self.lines = {}
        self.frame_start_line = cur

    # ---------------- CPU ----------------
    def setnz(self, v): self.n = v & 0x80; self.z = 1 if v == 0 else 0; return v
    def getp(self): return (0x80 if self.n else 0) | (0x40 if self.v else 0) | 0x30 | (8 if self.dflag else 0) | (4 if self.i else 0) | (2 if self.z else 0) | (1 if self.c else 0)
    def setp(self, p): self.n = p & 0x80; self.v = p & 0x40; self.dflag = p & 8; self.i = p & 4; self.z = 1 if p & 2 else 0; self.c = p & 1
    def push(self, v): self.ram[self.sp & 0x7F] = v & 255; self.sp = (self.sp - 1) & 255
    def pop(self): self.sp = (self.sp + 1) & 255; return self.ram[self.sp & 0x7F]

    def step(self):
        pc = self.opc = self.pc
        op = self.rd(pc)
        if op not in T: raise RuntimeError(f"illegal opcode {op:02X} at {pc:04X}")
        mn, mode, cyc = T[op]
        self.icyc = cyc
        self.wsync = False
        addr = None; extra = 0
        if mode == 'imp' or mode == 'acc': self.pc = pc + 1
        elif mode == 'imm': addr = pc + 1; self.pc = pc + 2
        elif mode == 'zp': addr = self.rd(pc + 1); self.pc = pc + 2
        elif mode == 'zpx': addr = (self.rd(pc + 1) + self.x) & 255; self.pc = pc + 2
        elif mode == 'zpy': addr = (self.rd(pc + 1) + self.y) & 255; self.pc = pc + 2
        elif mode == 'abs': addr = self.rd(pc + 1) | self.rd(pc + 2) << 8; self.pc = pc + 3
        elif mode in ('abx', 'aby'):
            b = self.rd(pc + 1) | self.rd(pc + 2) << 8
            addr = (b + (self.x if mode == 'abx' else self.y)) & 0xFFFF
            if (b ^ addr) & 0xFF00 and mn in PENALTY: extra = 1
            self.pc = pc + 3
        elif mode == 'izx':
            z = (self.rd(pc + 1) + self.x) & 255
            addr = self.rd(z) | self.rd((z + 1) & 255) << 8; self.pc = pc + 2
        elif mode == 'izy':
            z = self.rd(pc + 1)
            b = self.rd(z) | self.rd((z + 1) & 255) << 8
            addr = (b + self.y) & 0xFFFF
            if (b ^ addr) & 0xFF00 and mn in PENALTY: extra = 1
            self.pc = pc + 2
        elif mode == 'ind':
            p = self.rd(pc + 1) | self.rd(pc + 2) << 8
            addr = self.rd(p) | self.rd((p & 0xFF00) | ((p + 1) & 255)) << 8; self.pc = pc + 3
        elif mode == 'rel':
            o = self.rd(pc + 1); self.pc = pc + 2
            addr = (self.pc + (o - 256 if o > 127 else o)) & 0xFFFF
        self.icyc = cyc + extra
        getattr(self, 'op_' + mn)(addr, mode)
        self.cycles += self.icyc
        self.pc &= 0xFFFF
        if self.wsync:
            r = self.cycles % 76
            if r: self.cycles += 76 - r

    def op_LDA(self, a, m): self.a = self.setnz(self.rd(a))
    def op_LDX(self, a, m): self.x = self.setnz(self.rd(a))
    def op_LDY(self, a, m): self.y = self.setnz(self.rd(a))
    def op_STA(self, a, m): self.wr(a, self.a)
    def op_STX(self, a, m): self.wr(a, self.x)
    def op_STY(self, a, m): self.wr(a, self.y)
    def op_ORA(self, a, m): self.a = self.setnz(self.a | self.rd(a))
    def op_AND(self, a, m): self.a = self.setnz(self.a & self.rd(a))
    def op_EOR(self, a, m): self.a = self.setnz(self.a ^ self.rd(a))
    def adc(self, v):
        if self.dflag: self.errors.append("decimal mode")
        s = self.a + v + (1 if self.c else 0)
        self.v = (~(self.a ^ v) & (self.a ^ s)) & 0x80
        self.c = 1 if s > 255 else 0
        self.a = self.setnz(s & 255)
    def op_ADC(self, a, m): self.adc(self.rd(a))
    def op_SBC(self, a, m): self.adc(self.rd(a) ^ 255)
    def cmp(self, r, v): t = r - v; self.c = 1 if t >= 0 else 0; self.setnz(t & 255)
    def op_CMP(self, a, m): self.cmp(self.a, self.rd(a))
    def op_CPX(self, a, m): self.cmp(self.x, self.rd(a))
    def op_CPY(self, a, m): self.cmp(self.y, self.rd(a))
    def op_BIT(self, a, m):
        v = self.rd(a); self.n = v & 0x80; self.v = v & 0x40; self.z = 1 if (v & self.a) == 0 else 0
    def rmw(self, a, m, f):
        if m == 'acc': self.a = self.setnz(f(self.a))
        else: v = f(self.rd(a)); self.wr(a, v); self.setnz(v)
    def op_ASL(self, a, m):
        def f(v): self.c = v >> 7; return (v << 1) & 255
        self.rmw(a, m, f)
    def op_LSR(self, a, m):
        def f(v): self.c = v & 1; return v >> 1
        self.rmw(a, m, f)
    def op_ROL(self, a, m):
        def f(v): c = 1 if self.c else 0; self.c = v >> 7; return ((v << 1) | c) & 255
        self.rmw(a, m, f)
    def op_ROR(self, a, m):
        def f(v): c = 0x80 if self.c else 0; self.c = v & 1; return (v >> 1) | c
        self.rmw(a, m, f)
    def op_INC(self, a, m): self.rmw(a, m, lambda v: (v + 1) & 255)
    def op_DEC(self, a, m): self.rmw(a, m, lambda v: (v - 1) & 255)
    def br(self, a, cond):
        if cond:
            self.icyc += 1 + (1 if (a ^ self.pc) & 0xFF00 else 0); self.pc = a
    def op_BPL(self, a, m): self.br(a, not self.n)
    def op_BMI(self, a, m): self.br(a, self.n)
    def op_BVC(self, a, m): self.br(a, not self.v)
    def op_BVS(self, a, m): self.br(a, self.v)
    def op_BCC(self, a, m): self.br(a, not self.c)
    def op_BCS(self, a, m): self.br(a, self.c)
    def op_BNE(self, a, m): self.br(a, not self.z)
    def op_BEQ(self, a, m): self.br(a, self.z)
    def op_CLC(self, a, m): self.c = 0
    def op_SEC(self, a, m): self.c = 1
    def op_CLI(self, a, m): self.i = 0
    def op_SEI(self, a, m): self.i = 1
    def op_CLV(self, a, m): self.v = 0
    def op_CLD(self, a, m): self.dflag = 0
    def op_SED(self, a, m): self.dflag = 1
    def op_TAX(self, a, m): self.x = self.setnz(self.a)
    def op_TXA(self, a, m): self.a = self.setnz(self.x)
    def op_TAY(self, a, m): self.y = self.setnz(self.a)
    def op_TYA(self, a, m): self.a = self.setnz(self.y)
    def op_TSX(self, a, m): self.x = self.setnz(self.sp)
    def op_TXS(self, a, m): self.sp = self.x
    def op_DEX(self, a, m): self.x = self.setnz((self.x - 1) & 255)
    def op_INX(self, a, m): self.x = self.setnz((self.x + 1) & 255)
    def op_DEY(self, a, m): self.y = self.setnz((self.y - 1) & 255)
    def op_INY(self, a, m): self.y = self.setnz((self.y + 1) & 255)
    def op_NOP(self, a, m): pass
    def op_PHA(self, a, m): self.push(self.a)
    def op_PLA(self, a, m): self.a = self.setnz(self.pop())
    def op_PHP(self, a, m): self.push(self.getp())
    def op_PLP(self, a, m): self.setp(self.pop())
    def op_JMP(self, a, m): self.pc = a
    def op_JSR(self, a, m):
        r = (self.pc - 1) & 0xFFFF; self.push(r >> 8); self.push(r); self.pc = a
    def op_RTS(self, a, m):
        lo = self.pop(); hi = self.pop(); self.pc = ((hi << 8) | lo) + 1
    def op_RTI(self, a, m):
        self.setp(self.pop()); lo = self.pop(); hi = self.pop(); self.pc = (hi << 8) | lo
    def op_BRK(self, a, m): raise RuntimeError(f"BRK at {self.opc:04X}")

    def run_frame(self, limit=200000):
        n = len(self.frames); start = self.cycles
        while len(self.frames) == n:
            self.step()
            if self.cycles - start > limit: raise RuntimeError("no VSYNC")
        return self.frames[-1]

def frame_image(rows, scale=3):
    from PIL import Image
    # crop to non-blank region heuristically: lines 3..
    img = Image.new("RGB", (160, len(rows)))
    px = img.load()
    for y, r in enumerate(rows):
        for x, c in enumerate(r): px[x, y] = PAL[c]
    return img
