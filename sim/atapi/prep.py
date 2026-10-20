#!/usr/bin/env python3
"""Prepare the ATAPI replay bench: MAME ATA capture -> trace.txt, needed disc blocks -> blocks.txt, sector sums.

  prep.py CAPTURE.bin DISC.bin OUTDIR
trace.txt : 'W|R ADDR24 DATA32 MASK32' per access (board-bus address, MAME data and mask)
blocks.txt: '<block> <1024 bytes hex>' for every 1 KB block of the image the drive can touch
sums.txt  : '<lba> <xor of the 1024 16-bit words>' for every sector read (expected DMA data)
"""
import struct, sys, os
cap, disc, out = sys.argv[1:4]
d = open(cap, "rb").read()
recs = [struct.unpack_from("<BIIII", d, i * 17) for i in range(len(d) // 17)]
img = open(disc, "rb")
size = os.path.getsize(disc)
img.seek(0); head = img.read(16)
raw = head[:12] == b"\x00" + b"\xff" * 10 + b"\x00"
ss = 2352 if raw else 2048
with open(os.path.join(out, "trace.txt"), "w") as f:
    for t, o, v, m, us in recs:
        f.write("%s %06X %08X %08X\n" % ("W" if t == 0 else "R", o & 0xFFFFFF, v, m))
# LBAs requested: packet words written to the data register after command A0
lbas = set(); pk = None
for t, o, v, m, us in recs:
    off = (o & 0xF) + (2 if m == 0xFFFF0000 else 0)
    val = (v >> 16) if m == 0xFFFF0000 else (v & 0xFFFF)
    if t == 0 and off == 14:
        pk = [] if val == 0xA0 else None
    elif t == 0 and off == 0 and pk is not None:
        pk += [val & 0xFF, val >> 8]
        if len(pk) == 12:
            if pk[0] in (0xBE, 0x28, 0xA8):
                lba = struct.unpack(">I", bytes(pk[2:6]))[0]
                n = (pk[6] << 16 | pk[7] << 8 | pk[8]) if pk[0] == 0xBE else (pk[7] << 8 | pk[8])
                for k in range(n + 2): lbas.add(lba + k)        # + read-ahead
            pk = None
blocks = {0}
for l in lbas:
    a = l * ss + (16 if raw else 0)
    for b in range(a >> 10, ((a + 2047) >> 10) + 1): blocks.add(b)
with open(os.path.join(out, "blocks.txt"), "w") as f:
    for b in sorted(blocks):
        img.seek(b * 1024); data = img.read(1024).ljust(1024, b"\0")
        f.write("%d %s\n" % (b, data.hex()))
with open(os.path.join(out, "sums.txt"), "w") as f:
    for l in sorted(lbas):
        img.seek(l * ss + (16 if raw else 0)); data = img.read(2048).ljust(2048, b"\0")
        x = 0
        for i in range(0, 2048, 2): x ^= data[i] | data[i + 1] << 8
        f.write("%d %d\n" % (l, x))
print("records", len(recs), "raw" if raw else "2048", "lbas", len(lbas), "blocks", len(blocks), "size", size)
