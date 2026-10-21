#!/usr/bin/env python3
"""spucap.lua capture -> events.txt for tb_spu (W cyc reg data / D cyc n + n words) and mame_irq.txt (SPU IRQ acks)."""
import sys, os
cap, out = sys.argv[1:3]
with open(os.path.join(out, "events.txt"), "w") as f, open(os.path.join(out, "mame_irq.txt"), "w") as g:
    for line in open(cap):
        p = line.split()
        if p[0] == "W":
            f.write("W %s %d %s\n" % (p[1], int(p[2], 16), p[3]))
        elif p[0] == "D":
            n = int(p[3]); words = p[5:5 + n]
            f.write("D %s %d\n" % (p[1], n))
            for w in words: f.write(w + "\n")
        elif p[0] == "S" and int(p[2], 16) == 0xFFFFFDFF:
            g.write(p[1] + "\n")
