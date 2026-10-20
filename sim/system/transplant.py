#!/usr/bin/env python3
"""Build an SDRAM image that resumes a MAME machine state on the core (performance testing).

  transplant.py STATE_DIR BASE_SDRAM_BIN OUT_SDRAM_BIN

STATE_DIR comes from local/mame/stdump.lua (ram.bin, scratch.bin, shram.bin, regs.txt). Main RAM
(4 MB) is placed at SDRAM 0, and a boot stub replaces the program ROM at the reset vector: it
restores memory control, scratchpad, shared RAM, GTE, timers, DMA/IRQ control, the GPU display
setup and finally all CPU registers, then jumps to the captured PC with SR restored in the
delay slot. VRAM is not transplanted (textures read as zero; draw timing is unaffected).
"""
import os, sys, struct

st, base, out = sys.argv[1:4]
regs = {}
for line in open(os.path.join(st, "regs.txt")):
    p = line.split()
    if len(p) == 2:
        try: regs[p[0]] = int(p[1], 16)
        except ValueError: pass

PROG = 0x400000                    # SDRAM address of the program ROM (BFC00000)
code = []
def emit(w): code.append(w & 0xffffffff)
def lui(rt, imm): emit(0x3C000000 | rt << 16 | (imm & 0xffff))
def ori(rt, rs, imm): emit(0x34000000 | rs << 21 | rt << 16 | (imm & 0xffff))
def addiu(rt, rs, imm): emit(0x24000000 | rs << 21 | rt << 16 | (imm & 0xffff))
def sw(rt, off, rs): emit(0xAC000000 | rs << 21 | rt << 16 | (off & 0xffff))
def lw(rt, off, rs): emit(0x8C000000 | rs << 21 | rt << 16 | (off & 0xffff))
def mtc0(rt, rd): emit(0x40800000 | rt << 16 | rd << 11)
def mtc2(rt, rd): emit(0x48800000 | rt << 16 | rd << 11)
def ctc2(rt, rd): emit(0x48C00000 | rt << 16 | rd << 11)
def mthi(rs): emit(rs << 21 | 0x11)
def mtlo(rs): emit(rs << 21 | 0x13)
def jr(rs): emit(rs << 21 | 0x08)
def bne(rs, rt, off): emit(0x14000000 | rs << 21 | rt << 16 | (off & 0xffff))
def nop(): emit(0)
def li(rt, v): lui(rt, v >> 16); ori(rt, rt, v)
T0, T1, T2, T3, K0, K1 = 8, 9, 10, 11, 26, 27

def store(addr, val):
    li(T0, addr); li(T1, val); sw(T1, 0, T0)

data = []                          # data table appended after the code
def table(words):
    off = len(data); data.extend(words); return off
def words(path):
    b = open(path, "rb").read(); return list(struct.unpack("<%dI" % (len(b) // 4), b))

scr_off = table(words(os.path.join(st, "scratch.bin")))
sh_off = table(words(os.path.join(st, "shram.bin")))
GTE_D = "vxy0 vz0 vxy1 vz1 vxy2 vz2 rgb otz ir0 ir1 ir2 ir3 sxy0 sxy1 sxy2 sxyp sz0 sz1 sz2 sz3 rgb0 rgb1 rgb2 res1 mac0 mac1 mac2 mac3 irgb orgb lzcs lzcr".split()
GTE_C = "r11r12 r13r21 r22r23 r31r32 r33 trx try trz l11l12 l13l21 l22l23 l31l32 l33 rbk gbk bbk lr1lr2 lr31g1 lg2lg3 lb1lb2 lb3 rfc gfc bfc ofx ofy h dqa dqb zsf3 zsf4 flag".split()
gte_off = table([regs[n] for n in GTE_D] + [regs[n] for n in GTE_C])
GPR = "zero at v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7 s0 s1 s2 s3 s4 s5 s6 s7 t8 t9 k0 k1 gp sp fp ra".split()
gpr_off = table([regs[n] for n in GPR] + [regs["pc"], regs["SR"], regs["hi"], regs["lo"]])

# --- code ---
li(T0, 0x40000000); mtc0(T0, 12); nop(); nop()                    # SR: COP2 usable, IRQs off
for a in (0x1f801000, 0x1f801004, 0x1f801008, 0x1f80100c, 0x1f801010, 0x1f801014, 0x1f801018,
          0x1f80101c, 0x1f801020, 0x1f801060):
    store(a, regs["hw_%08X" % a])
fix_tbl = []                                                        # patched with the table base
def tbase(rt, off):
    fix_tbl.append((len(code), off)); lui(rt, 0); ori(rt, rt, 0)
def copyloop(src_off, dst, n):
    tbase(T0, src_off); li(T1, dst); li(T2, n)
    lw(T3, 0, T0); addiu(T0, T0, 4); addiu(T2, T2, -1); sw(T3, 0, T1)
    bne(T2, 0, -5); addiu(T1, T1, 4)
copyloop(scr_off, 0x1f800000, 256)
copyloop(sh_off, 0x1f080000, 4096)
tbase(K0, gte_off)
for i in range(32):
    lw(T0, 32 * 4 + i * 4, K0); nop(); ctc2(T0, i)
for i in range(32):
    if i in (15, 28, 29, 31): continue                               # sxyp/irgb/orgb/lzcr: derived
    lw(T0, i * 4, K0); nop(); mtc2(T0, i)
for t in range(3):                                                  # timers: mode, target, counter
    b = 0x1f801100 + t * 0x10
    store(b + 4, regs["hw_%08X" % (b + 4)] & 0x3ff); store(b + 8, regs["hw_%08X" % (b + 8)]); store(b, regs["hw_%08X" % b])
store(0x1f8010f0, regs["hw_1F8010F0"]); store(0x1f8010f4, regs["hw_1F8010F4"] & 0x00ffffff)
for c in (0x00, 0x01, 0x09, 0x08, 0x06, 0x07, 0x05, 0x03, 0x04):
    if "gp1_%02X" % c in regs: store(0x1f801814, regs["gp1_%02X" % c])
store(0x1f000000, regs.get("bank", 0))
store(0x1f801074, regs["hw_1F801074"])
ram_w = words(os.path.join(st, "ram.bin"))
for i in range(3):                                                  # undo the reset-time boot signature copy
    store(0x80010000 + 4 * i, ram_w[0x10000 // 4 + i])
tbase(K0, gpr_off)
lw(T0, 34 * 4, K0); nop(); mthi(T0); lw(T0, 35 * 4, K0); nop(); mtlo(T0)
for r in range(1, 32):
    if r in (K0, K1): continue
    lw(r, r * 4, K0)
lw(K1, 32 * 4, K0)                                                  # PC
lw(K0, 33 * 4, K0)                                                  # SR
nop()
jr(K1)
mtc0(K0, 12)                                                        # SR in the delay slot
nop()

tbl_addr = 0xBFC00000 + len(code) * 4
for idx, off in fix_tbl:
    a = tbl_addr + off * 4
    code[idx] = 0x3C000000 | (code[idx] & 0x001f0000) | (a >> 16)
    code[idx + 1] = (code[idx + 1] & 0xffff0000) | (a & 0xffff)

img = bytearray(open(base, "rb").read())
ram = open(os.path.join(st, "ram.bin"), "rb").read()
img[0:len(ram)] = ram
blob = struct.pack("<%dI" % len(code), *code) + struct.pack("<%dI" % len(data), *data)
img[PROG:PROG + len(blob)] = blob
open(out, "wb").write(img)
print("stub %d words, data %d words, resume pc %08X sr %08X" % (len(code), len(data), regs["pc"], regs["SR"]))
