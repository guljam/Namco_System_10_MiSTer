#!/usr/bin/env python3
"""Split the framebuffer capture (gra_fb_out_vga.gra, one 'color#x#y' line per pixel) into PNG frames.

  gra2png.py build/gra_fb_out_vga.gra OUTDIR [--every N] [--rotate]

A new frame starts whenever y returns to 0 after a later line. --rotate turns frames 90 degrees
clockwise (Tenkomori is ROT90) for comparison with MAME snapshots.
"""
import os, sys, argparse
from PIL import Image

ap = argparse.ArgumentParser()
ap.add_argument("gra")
ap.add_argument("out")
ap.add_argument("--every", type=int, default=1)
ap.add_argument("--rotate", action="store_true")
a = ap.parse_args()
os.makedirs(a.out, exist_ok=True)

frame = {}
maxx = maxy = 0
n = 0
last_y = -1

def flush():
    global frame, maxx, maxy, n
    if frame:
        if n % a.every == 0:
            img = Image.new("RGB", (maxx + 1, maxy + 1))
            px = img.load()
            for (x, y), c in frame.items():
                px[x, y] = ((c >> 16) & 255, (c >> 8) & 255, c & 255)
            if a.rotate:
                img = img.rotate(-90, expand=True)
            img.save(os.path.join(a.out, "frame_%04d.png" % n))
        n += 1
    frame = {}
    maxx = maxy = 0

with open(a.gra) as f:
    f.readline()
    for line in f:
        p = line.strip().split("#")
        if len(p) < 3:
            continue
        c, x, y = int(p[0]), int(p[1]), int(p[2])
        if y < last_y and y == 0:
            flush()
        last_y = y
        frame[(x, y)] = c
        maxx = max(maxx, x)
        maxy = max(maxy, y)
flush()
print("frames:", n)
