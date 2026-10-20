#!/usr/bin/env python3
"""Turn the MAME captures (local/mame/crypt/<game>_cap.bin) into decrypter test vectors.

For each game this reconstructs the raw cipherword for every decrypted read from the ROM image in
the MAME zip, checks the Python models in scripts/ns10crypt.py against the words MAME returned and
writes sim/crypt/vec_<game>.hex for the RTL benches.

Vector file format (one 36-bit hex word per line, for $readmemh):
  [35:32] op : 0 = word (cipher[31:16], expected plain[15:0])
               1 = activate, iv in [3:0]
               2 = deactivate
  The first line is a header: op 0xF, [31:0] = number of following lines.

Usage: python sim/crypt/capture.py [--rompath DIR] [--capdir DIR] [game ...]
"""
import argparse
import os
import struct
import sys
import zipfile
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import ns10crypt as nc  # noqa: E402


def parse(path):
    d = open(path, "rb").read()
    i = 0
    ev = []
    n = len(d)
    while i < n:
        t = d[i]
        i += 1
        if t == 0x52 and len_short.get(path):  # 'R' short form (type-2 capture)
            ev.append(("R", d[i] | (d[i + 1] << 8)))
            i += 2
        elif t == 0x52:
            ev.append(("R",) + struct.unpack_from("<III", d, i))
            i += 12
        elif t == 0x46:  # 'F'
            ev.append(("F", struct.unpack_from("<I", d, i)[0]))
            i += 4
        elif t == 0x42:  # 'B'
            ev.append(("B", struct.unpack_from("<I", d, i)[0]))
            i += 4
        elif t in (0x57, 0x58):  # 'W', 'X'
            ev.append((chr(t),) + struct.unpack_from("<III", d, i))
            i += 12
        else:
            raise ValueError("bad record 0x%02x at %d in %s" % (t, i - 1, path))
    return ev


len_short = {}


class Vec:
    def __init__(self):
        self.lines = []
        self.words = 0
        self.acts = 0

    def act(self, iv):
        self.lines.append((1 << 32) | (iv & 15))
        self.acts += 1

    def deact(self):
        self.lines.append(2 << 32)

    def word(self, c, p):
        self.lines.append((c << 16) | p)
        self.words += 1

    def write(self, path):
        with open(path, "w") as f:
            f.write("%09x\n" % ((0xF << 32) | len(self.lines)))
            for v in self.lines:
                f.write("%09x\n" % v)


def unscramble_mrdrilrg(v):
    return nc.bitswap16(v, 0xe, 0xc, 0xf, 0xd, 0xa, 0x9, 0x8, 0xb, 0x4, 0x5, 0x6, 0x7, 0x0, 0x1, 0x3, 0x2)


def run_type2(game, ev, nands, unscr, data_xor, model_factories):
    """MEM(N): reconstruct the NAND byte stream behind every 0x1F450000 read."""
    PAGE = 0x210
    dev, ctrl = 0, 0
    area = 0
    col = row = pg = 0
    ptr = None          # byte pointer inside nands[dev] (None = not in read mode)
    active = False
    vec = Vec()
    models = [f() for f in model_factories]
    plain_ok = Counter()
    inactive_ok = inactive_bad = 0
    sessions = []
    errors = 0

    def rd_byte():
        nonlocal ptr
        b = nands[dev][ptr]
        ptr += 1
        if ptr % PAGE == 0 and area == 0x200:
            ptr += 0x200
        return b

    for e in ev:
        k = e[0]
        if k == "W":
            a, d, mk = e[1], e[2], e[3]
            if a in (0x1F300000, 0x1F380000):
                if d & 0x8000:
                    active = True
                    vec.act(d & 15)
                    sessions.append([d & 15, 0])
                    for m in models:
                        m.activate(d & 15)
                else:
                    active = False
                    vec.deact()
                    for m in models:
                        m.deactivate()
            elif a == 0x1F470000:
                ctrl = d & 0xFFFF
            elif a == 0x1F460000:
                if (ctrl & 4) == 0:
                    dev = d & 0xFFFF
            elif a == 0x1F410000:
                cmd = d & 0xFF
                ptr = None
                if cmd in (0x00, 0x01, 0x50):
                    area = {0x00: 0, 0x01: 0x100, 0x50: 0x200}[cmd]
            elif a == 0x1F420000:
                col = d & 0xFF
            elif a == 0x1F430000:
                row = d & 0xFF
            elif a == 0x1F440000:
                pg = d & 0xFF
                ptr = ((pg << 8) | row) * PAGE + area + col
        elif k == "R":
            ret = e[1]
            if ptr is None:
                if active:
                    errors += 1
                continue
            hi = rd_byte()
            lo = rd_byte()
            c = (hi << 8) | lo
            if active:
                p0 = None
                for idx, m in enumerate(models):
                    p = m.decrypt(c)
                    if p == ret:
                        plain_ok[idx] += 1
                    if p0 is None:
                        p0 = p
                vec.word(c, ret)
                sessions[-1][1] += 1
            else:
                page = (ptr - 2) // PAGE
                exp = c if (dev == 0 and (page >> 5) < 2) else unscr(c ^ data_xor)
                if exp == ret:
                    inactive_ok += 1
                else:
                    inactive_bad += 1
        elif k == "X":
            errors += 1
    return vec, models, plain_ok, sessions, inactive_ok, inactive_bad, errors


def run_type1(game, ev, flash, model_factories):
    """MEM(M): cipherword = flash word at 0x100000*bank + word offset (little-endian)."""
    bank, direct = 0, 0
    active = False
    vec = Vec()
    models = [f() for f in model_factories]
    plain_ok = Counter()
    sessions = []
    skipped_direct = 0
    for e in ev:
        k = e[0]
        if k == "W":
            a, d, mk = e[1], e[2], e[3]
            if a == 0x1F300000:
                if d & 0x8000:
                    active = True
                    vec.act(d & 15)
                    sessions.append([d & 15, 0])
                    for m in models:
                        m.activate(d & 15)
                else:
                    active = False
                    vec.deact()
                    for m in models:
                        m.deactivate()
            elif 0x1FB40000 <= a < 0x1FB60000:
                # 16-bit handler on the 32-bit bus: one call per active 16-bit lane
                for lane in (0, 1):
                    if mk & (0xFFFF << (16 * lane)):
                        bank = (a - 0x1FB40000) // 2 + lane
                        direct = 1 if bank >= 0x10 else 0
        elif k == "B":
            direct = 1
        elif k == "R":
            a, d, mk = e[1], e[2], e[3]
            for lane in (0, 1):
                if not (mk & (0xFFFF << (16 * lane))):
                    continue
                ret = (d >> (16 * lane)) & 0xFFFF
                off = (a - 0x1F400000) // 2 + lane
                if not active or not direct:
                    skipped_direct += 1
                    continue
                wa = (0x100000 * bank + off) * 2
                c = flash[wa] | (flash[wa + 1] << 8)
                for idx, m in enumerate(models):
                    if m.decrypt(c) == ret:
                        plain_ok[idx] += 1
                vec.word(c, ret)
                sessions[-1][1] += 1
    return vec, models, plain_ok, sessions, skipped_direct


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rompath", default="C:/Users/klest/Downloads/mame/roms")
    ap.add_argument("--capdir", default=os.path.join(ROOT, "local", "mame", "crypt"))
    ap.add_argument("--outdir", default=HERE)
    ap.add_argument("games", nargs="*", default=["mrdrilr2", "mrdrilrg"])
    args = ap.parse_args()
    allok = True
    for game in args.games:
        cap = os.path.join(args.capdir, game + "_cap.bin")
        if game == "mrdrilrg":
            len_short[cap] = True
            ev = parse(cap)
            z = zipfile.ZipFile(os.path.join(args.rompath, game + ".zip"))
            nands = [z.read(n) for n in ("0.8e", "1.8d", "2.7e")]
            names = ["Type2Mame (MAME lambda)", "Type2Generic (Ac/Ap/Bc/Bp/out)"]
            vec, models, ok, sessions, iok, ibad, err = run_type2(
                game, ev, nands, unscramble_mrdrilrg, 0xAAAA, [nc.mrdrilrg_mame, nc.mrdrilrg_generic])
            print("%s: NAND reconstruction check on %d plaintext (inactive) reads: %d mismatches; "
                  "%d unexpected records" % (game, iok + ibad, ibad, err))
            if ibad or err:
                allok = False
        elif game == "mrdrilr2":
            ev = parse(cap)
            z = zipfile.ZipFile(os.path.join(args.rompath, game + ".zip"))
            flash = z.read("dr22vera.1a")
            names = ["Type1"]
            vec, models, ok, sessions, skipped = run_type1(game, ev, flash, [nc.Type1])
            print("%s: %d active-window reads were direct flash reads (not decrypted, skipped)" % (game, skipped))
        else:
            raise SystemExit("unknown game " + game)
        print("%s: %d activations: %s" % (game, len(sessions),
              ", ".join("iv=%X:%d" % (iv, n) for iv, n in sessions)))
        for idx, nm in enumerate(names):
            r = "PASS" if ok[idx] == vec.words else "FAIL"
            if ok[idx] != vec.words:
                allok = False
            print("%s: %-32s %d / %d words match MAME  %s" % (game, nm, ok[idx], vec.words, r))
        if game == "mrdrilrg":
            pv = nc.t2_param_vectors(nc.MRDRILRG)
            pout = os.path.join(args.outdir, "params_%s.hex" % game)
            with open(pout, "w") as f:
                for key in ("emask", "dmask", "xmask", "ivtab", "nl_ac", "nl_ap", "nl_bc", "nl_bp", "nl_out"):
                    f.write(pv[key] + "\n")
            print("%s: wrote %s" % (game, pout))
        out = os.path.join(args.outdir, "vec_%s.hex" % game)
        vec.write(out)
        print("%s: wrote %s (%d lines)" % (game, out, len(vec.lines) + 1))
    if not allok:
        sys.exit(1)


if __name__ == "__main__":
    main()
