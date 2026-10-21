#!/usr/bin/env python3
"""Pull a MEM(N) game's board parameters out of MAME's namcos10.cpp (for adding games to s10tool.py).

  mame_s10_import.py NAMCOS10_CPP CONFIG_NAME [SET ...]

Prints the unscrambler permutation, NAND count/type, type-2 masks, xmask, IV table and the nonlinear term,
and each set's NAND ROM names + CRCs. The nonlinear lambda is printed verbatim: convert it to the generic
form parity(Ac&C ^ Ap&P) & parity(Bc&C ^ Bp&P) * out by hand ((pm >> k) & 1 with pm = C ^ P is Ac = Ap = 1 << k;
gf2_reduce(mc & C) ^ gf2_reduce(mp & P) is (mc, mp)).
"""
import re, sys


def body(src, name):
    m = re.search(r"void namcos10_mem(?:n|p3)_state::%s\(machine_config &config\)\n\{(.*?)\n\}\n" % re.escape(name), src, re.S)
    return m.group(1) if m else None


def main():
    src = open(sys.argv[1], encoding="utf-8").read()
    b = body(src, sys.argv[2])
    if b is None:
        sys.exit("config not found")
    perm = re.search(r"bitswap<16>\(data, ([^)]*)\)", b).group(1)
    nand = re.search(r"namcos10_nand_(k9f\w+)\(config, (\d+)\)", b)
    hexes = [int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]+)ULL", b.split("},", 2)[0] + "},")]
    blocks = re.findall(r"\{\s*((?:0x[0-9a-fA-F]+ULL,?\s*(?://[^\n]*)?\s*){16})\}", b)
    masks = [[int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]+)ULL", blk)][:16] for blk in blocks[:2]]
    xm = re.search(r"\},\s*\n\s*(0x[0-9a-fA-F]+),\s*\n", b)
    ivm = re.search(r"values\[16\]\{([^}]*)\}", b)
    lam = re.search(r"-> (?:std::)?uint16_t\s*\{(.*?)\n\t\t\}", b, re.S)
    print("perm      =", "(" + perm + ")")
    print("nand      =", nand.group(1), "x", nand.group(2))
    print("exio      =", "namcos10_exio" in b, " exfinal =", "exfinalio" in b, " mgexio =", "mgexio" in b)
    print("emask     =", "[" + ", ".join("0x%016x" % v for v in masks[0]) + "]")
    print("dmask     =", "[" + ", ".join("0x%016x" % v for v in masks[1]) + "]")
    print("xmask     =", xm.group(1) if xm else None)
    print("iv        =", "[" + ivm.group(1).replace("\n", " ").replace("\t", "") + "]" if ivm else "default INIT_SBOX")
    print("nonlinear =", " ".join(lam.group(1).split()) if lam else None)
    for s in sys.argv[3:]:
        r = re.search(r"ROM_START\( %s \)(.*?)ROM_END" % re.escape(s), src, re.S).group(1)
        print(s, re.findall(r'ROM_LOAD\( "([^"]+)",\s*0x[0-9a-fA-F]+,\s*0x([0-9a-fA-F]+),\s*CRC\(([0-9a-f]+)\)', r))
    _ = hexes


if __name__ == "__main__":
    main()
