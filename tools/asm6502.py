#!/usr/bin/env python3
"""Tiny two-pass 6502 assembler for a DASM-compatible subset (-f3 raw output).
Supports: labels (col 0, optional ':'), NAME = expr / equ, processor, org, rorg,
.byte/dc.b, .word/dc.w, ds n[,fill], align n[,fill], include, .w suffix,
expressions with + - * / & | ^ << >> < > and [ ] / ( ) grouping."""
import re, sys, os

OPS = {
 'ADC': {'imm':0x69,'zp':0x65,'zpx':0x75,'abs':0x6D,'abx':0x7D,'aby':0x79,'izx':0x61,'izy':0x71},
 'AND': {'imm':0x29,'zp':0x25,'zpx':0x35,'abs':0x2D,'abx':0x3D,'aby':0x39,'izx':0x21,'izy':0x31},
 'ASL': {'acc':0x0A,'zp':0x06,'zpx':0x16,'abs':0x0E,'abx':0x1E},
 'BIT': {'zp':0x24,'abs':0x2C},
 'BPL': {'rel':0x10},'BMI': {'rel':0x30},'BVC': {'rel':0x50},'BVS': {'rel':0x70},
 'BCC': {'rel':0x90},'BCS': {'rel':0xB0},'BNE': {'rel':0xD0},'BEQ': {'rel':0xF0},
 'BRK': {'imp':0x00},
 'CMP': {'imm':0xC9,'zp':0xC5,'zpx':0xD5,'abs':0xCD,'abx':0xDD,'aby':0xD9,'izx':0xC1,'izy':0xD1},
 'CPX': {'imm':0xE0,'zp':0xE4,'abs':0xEC},'CPY': {'imm':0xC0,'zp':0xC4,'abs':0xCC},
 'DEC': {'zp':0xC6,'zpx':0xD6,'abs':0xCE,'abx':0xDE},
 'EOR': {'imm':0x49,'zp':0x45,'zpx':0x55,'abs':0x4D,'abx':0x5D,'aby':0x59,'izx':0x41,'izy':0x51},
 'CLC': {'imp':0x18},'SEC': {'imp':0x38},'CLI': {'imp':0x58},'SEI': {'imp':0x78},
 'CLV': {'imp':0xB8},'CLD': {'imp':0xD8},'SED': {'imp':0xF8},
 'INC': {'zp':0xE6,'zpx':0xF6,'abs':0xEE,'abx':0xFE},
 'JMP': {'abs':0x4C,'ind':0x6C},'JSR': {'abs':0x20},
 'LDA': {'imm':0xA9,'zp':0xA5,'zpx':0xB5,'abs':0xAD,'abx':0xBD,'aby':0xB9,'izx':0xA1,'izy':0xB1},
 'LDX': {'imm':0xA2,'zp':0xA6,'zpy':0xB6,'abs':0xAE,'aby':0xBE},
 'LDY': {'imm':0xA0,'zp':0xA4,'zpx':0xB4,'abs':0xAC,'abx':0xBC},
 'LSR': {'acc':0x4A,'zp':0x46,'zpx':0x56,'abs':0x4E,'abx':0x5E},
 'NOP': {'imp':0xEA},
 'ORA': {'imm':0x09,'zp':0x05,'zpx':0x15,'abs':0x0D,'abx':0x1D,'aby':0x19,'izx':0x01,'izy':0x11},
 'TAX': {'imp':0xAA},'TXA': {'imp':0x8A},'DEX': {'imp':0xCA},'INX': {'imp':0xE8},
 'TAY': {'imp':0xA8},'TYA': {'imp':0x98},'DEY': {'imp':0x88},'INY': {'imp':0xC8},
 'ROL': {'acc':0x2A,'zp':0x26,'zpx':0x36,'abs':0x2E,'abx':0x3E},
 'ROR': {'acc':0x6A,'zp':0x66,'zpx':0x76,'abs':0x6E,'abx':0x7E},
 'RTI': {'imp':0x40},'RTS': {'imp':0x60},
 'SBC': {'imm':0xE9,'zp':0xE5,'zpx':0xF5,'abs':0xED,'abx':0xFD,'aby':0xF9,'izx':0xE1,'izy':0xF1},
 'STA': {'zp':0x85,'zpx':0x95,'abs':0x8D,'abx':0x9D,'aby':0x99,'izx':0x81,'izy':0x91},
 'STX': {'zp':0x86,'zpy':0x96,'abs':0x8E},'STY': {'zp':0x84,'zpx':0x94,'abs':0x8C},
 'TXS': {'imp':0x9A},'TSX': {'imp':0xBA},'PHA': {'imp':0x48},'PLA': {'imp':0x68},
 'PHP': {'imp':0x08},'PLP': {'imp':0x28},
}
SIZE = {'imp':1,'acc':1,'imm':2,'zp':2,'zpx':2,'zpy':2,'izx':2,'izy':2,'rel':2,'abs':3,'abx':3,'aby':3,'ind':3}

class Undef(Exception): pass

class Asm:
    def __init__(self):
        self.sym = {}
        self.listing = []

    def ev(self, e):
        e = e.strip()
        toks = re.findall(r"\$[0-9A-Fa-f]+|%[01]+|\d+|[A-Za-z_.][A-Za-z0-9_.]*|<<|>>|[-+*/&|^()\[\]<>~]", e)
        out = []; prev_operand = False
        for t in toks:
            if t[0] == '$': out.append(str(int(t[1:], 16))); prev_operand = True
            elif t[0] == '%': out.append(str(int(t[1:], 2))); prev_operand = True
            elif t[0].isdigit(): out.append(t); prev_operand = True
            elif re.match(r"[A-Za-z_.]", t):
                if t not in self.sym: raise Undef(t)
                out.append(str(self.sym[t])); prev_operand = True
            elif t in '[(': out.append('('); prev_operand = False
            elif t in '])': out.append(')'); prev_operand = True
            elif t == '<' and not prev_operand: out.append('LO'); prev_operand = False
            elif t == '>' and not prev_operand: out.append('HI'); prev_operand = False
            elif t == '*' and not prev_operand: out.append(str(self.pc)); prev_operand = True
            elif t == '/': out.append('//'); prev_operand = False
            else: out.append(t); prev_operand = False
        s = " ".join(out)
        # unary lo/hi bind tightly to the following term
        s = re.sub(r"LO\s+(\(|-?\d+)", r"LO \1", s)
        def LO(x): return x & 255
        def HI(x): return (x >> 8) & 255
        s = re.sub(r"\bLO\b", "LOf", s); s = re.sub(r"\bHI\b", "HIf", s)
        # make LOf/HIf function calls on the next atom
        s = re.sub(r"(LOf|HIf)\s+(\d+)", r"\1(\2)", s)
        return int(eval(s, {"LOf": LO, "HIf": HI, "__builtins__": {}}))

    def lines(self, path):
        for ln in open(path):
            ln = ln.rstrip("\n")
            m = re.match(r"\s*include\s+\"([^\"]+)\"", ln, re.I)
            if m:
                yield from self.lines(os.path.join(os.path.dirname(path), m.group(1)))
            else:
                yield ln

    def run(self, path):
        src = list(self.lines(path))
        for p in (1, 2, 3):
            self.final = (p == 3)
            self.mem = {}; self.pc = 0; self.fpos = 0
            for ln in src:
                self.line(ln)
        return self.mem

    def emit(self, b):
        self.mem[self.fpos] = b & 255
        self.fpos += 1; self.pc += 1

    def val(self, e):
        try: return self.ev(e)
        except Undef:
            if self.final: raise
            return None

    def line(self, ln):
        code = re.sub(r";.*", "", ln)
        if not code.strip(): return
        label = None
        if not code[0].isspace():
            m = re.match(r"([A-Za-z_.][A-Za-z0-9_.]*):?(.*)", code)
            label, code = m.group(1), m.group(2)
        m = re.match(r"\s*(=|equ\b)\s*(.*)", code, re.I)
        if label and m:
            v = self.val(m.group(2))
            if v is not None: self.sym[label] = v
            return
        if label: self.sym[label] = self.pc
        parts = code.strip().split(None, 1)
        if not parts: return
        op = parts[0]; arg = parts[1] if len(parts) > 1 else ""
        opu = op.upper()
        if opu in ("PROCESSOR", "SEG", "SEG.U", "ECHO", "END", "SUBROUTINE"): return
        if opu == "ORG":
            v = self.val(arg.split(",")[0]); self.fpos = v; self.pc = v; return
        if opu == "RORG":
            self.pc = self.val(arg); return
        if opu == "REND": return
        if opu in (".BYTE", "DC.B", "BYTE"):
            for a in arg.split(","):
                v = self.val(a); self.emit(v if v is not None else 0)
            return
        if opu in (".WORD", "DC.W", "WORD"):
            for a in arg.split(","):
                v = self.val(a) or 0; self.emit(v); self.emit(v >> 8)
            return
        if opu == "DS":
            a = arg.split(","); n = self.val(a[0]); f = self.val(a[1]) if len(a) > 1 else 0
            for _ in range(n): self.emit(f)
            return
        if opu == "ALIGN":
            a = arg.split(","); n = self.val(a[0]); f = self.val(a[1]) if len(a) > 1 else 0
            while self.pc % n: self.emit(f)
            return
        force_w = opu.endswith(".W")
        mn = opu.split(".")[0]
        if mn not in OPS: raise SyntaxError(f"unknown op {op!r} in: {ln}")
        modes = OPS[mn]
        a = arg.strip()
        if not a or a.upper() == "A":
            mode = 'acc' if 'acc' in modes else 'imp'; v = None
        elif a.startswith("#"):
            mode = 'imm'; v = self.val(a[1:])
        elif 'rel' in modes:
            mode = 'rel'; v = self.val(a)
        elif re.match(r"\(.*,\s*[xX]\s*\)$", a):
            mode = 'izx'; v = self.val(a[1:a.rindex(",")])
        elif re.match(r"\(.*\)\s*,\s*[yY]$", a):
            mode = 'izy'; v = self.val(a[1:a.rindex(")")])
        elif re.match(r"\(.*\)$", a) and mn == "JMP":
            mode = 'ind'; v = self.val(a[1:-1])
        else:
            idx = None
            m = re.match(r"(.*),\s*([xXyY])$", a)
            if m: a, idx = m.group(1), m.group(2).lower()
            v = self.val(a)
            key = ('zp' if idx is None else 'zp' + idx)
            akey = ('abs' if idx is None else 'ab' + idx)
            if not force_w and v is not None and v < 256 and key in modes:
                mode = key
            else:
                mode = akey
            # keep size stable between passes
            k = ('sz', self.fpos)
            if mode == key and self.sym.get(k) == 'abs': mode = akey
            if v is None: self.sym[k] = 'abs'
        if mode not in modes: raise SyntaxError(f"bad mode {mode} for {mn}: {ln}")
        self.emit(modes[mode])
        if mode == 'rel':
            if v is None: self.emit(0); return
            d = v - (self.pc + 1)
            if self.final and not -128 <= d <= 127: raise SyntaxError(f"branch out of range: {ln}")
            self.emit(d)
        elif SIZE[mode] == 2: self.emit(v or 0)
        elif SIZE[mode] == 3: v = v or 0; self.emit(v); self.emit(v >> 8)

if __name__ == "__main__":
    a = Asm(); mem = a.run(sys.argv[1])
    lo, hi = min(mem), max(mem)
    data = bytes(mem.get(i, 0) for i in range(lo, hi + 1))
    open(sys.argv[2], "wb").write(data)
    with open(sys.argv[2] + ".sym", "w") as f:
        for k, v in sorted(a.sym.items(), key=lambda kv: str(kv[1])):
            if isinstance(k, str): f.write(f"{k:16s} ${v:04X}\n")
    print(f"assembled {len(data)} bytes")
