#!/usr/bin/env python3
"""Namco System 10 core tool. Never writes ROM data into the repository.

  s10tool.py mra                      write MRA/*.mra (main sets) and MRA/_alternatives/... (clones)
  s10tool.py record SET OUT           write the board record (MRA index 1) as a binary file
  s10tool.py images SET DIR           write what the core holds after loading SET: bios.bin (descrambled
                                      4 MB BIOS, SDRAM 0x400000), ddr.bin (MEM board image, DDR3 0x32000000),
                                      record.bin - for the simulation benches
  s10tool.py check [SET ...]          compare bios.bin with MAME's maincpu:rom after driver init
                                      (local/mame/bios_<set>.bin, written by local/mame/dumpbios.lua)

ROM zips are read from ~/Downloads/mame/roms (--romdir). Board/ROM layout: docs/ARCHITECTURE.md.
"""
import argparse, os, struct, sys, zipfile, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ns10crypt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROMDIR = os.path.join(os.path.expanduser("~"), "Downloads", "mame", "roms")
CORE = "Namco_S10"
MAMEVER = "0289"
DDR3_IMG = 0x32000000            # MEM board image (s10_loader IMG_BASE = 0x2000000 from 0x30000000)
MEMN_PAGE = 0x210
MEMN_BIOS_FIRST, MEMN_BIOS_END = 0x40, 0x2020   # NAND0 pages copied by memn_driver_init
MEMM_BIOS_LEN = 0x62000

# MAME 0.289 namcos10.cpp
BOARDS = {
    # MEM(M): Intel 28F640J5 program flash (1A) + mask ROMs (1D, 2D); KEYCUS KC001A, type-1 decrypter
    "mrdrilr2_family": dict(
        board="M", crypt=1,
        perm=(0xc, 0xd, 0xf, 0xe, 0xb, 0xa, 0x9, 0x8, 0x7, 0x6, 0x4, 0x1, 0x2, 0x5, 0x0, 0x3),
        xor=0xAAAA, save_base=0x40000, save_size=0x10000,
        data=[("dr21ma1.1d", "26dc6f55", 0x1000000), ("dr21ma2.2d", "702556ff", 0x1000000)],
    ),
    "ptblank3_family": dict(
        board="N", crypt=2, nand_big=False,
        perm=(0xd, 0xc, 0xf, 0xe, 0x8, 0x9, 0xb, 0xa, 0x5, 0x7, 0x4, 0x6, 0x1, 0x0, 0x2, 0x3),
        xor=0xAAAA, t2=ns10crypt.PTBLANK3, save_base=0x4200, save_size=0x4200,
        exio=0x32, gun=True, category="Shooter", players=2,
        buttons=("Trigger,Start,Coin,Test,Service,Pause", "A,Start,Select,L,R,R3"), joystick="lightgun",
        dips=[("Service Mode", "7", None, "On,Off")],
    ),
    "gamshara_family": dict(
        board="N", crypt=2, nand_big=False,
        perm=(0xd, 0xc, 0xf, 0xe, 0x8, 0x9, 0xb, 0xa, 0x5, 0x7, 0x4, 0x6, 0x0, 0x1, 0x2, 0x3),
        xor=0xAAAA, t2=ns10crypt.GAMSHARA, save_base=0x4200, save_size=0x4200,
        manufacturer="Mitchell", category="Action", joystick="8-way",
        buttons=("Button 1,Start,Coin,Test,Service,Pause,Button 2,Button 3", "A,Start,Select,L,R,R3,B,X"),
        # MAME: the region is a 7-bit code on SW1:8-2, only 0x6E selects World (English); read at boot
        dips=[("Region", "0,6", "110,127", "World,Japan"), ("Service Mode", "7", None, "On,Off")],
        dip_default=0xEE,
    ),
}
GAMES = {
    "mrdrilr2":  dict(name="Mr. Driller 2 (World, DR22 Ver.A)", parent=None, region="World", year=2000,
                      family="mrdrilr2_family", flash=("dr22vera.1a", "140eafb6")),
    "mrdrilr2j": dict(name="Mr. Driller 2 (Japan, DR21 Ver.A)", parent="mrdrilr2", region="Japan", year=2000,
                      family="mrdrilr2_family", flash=("dr21vera.1a", "03e0241e")),
    "mrdrilr2u": dict(name="Mr. Driller 2 (US, DR23 Ver.A)", parent="mrdrilr2", region="USA", year=2000,
                      family="mrdrilr2_family", flash=("dr23vera.1a", "5f32b6fb")),
    # MEM(N): 3 x K9F2808U0B, KEYCUS KC007A, type-2 decrypter
    "mrdrilrg":  dict(name="Mr. Driller G (Japan, DRG1 Ver.A)", parent=None, region="Japan", year=2001,
                      board="N", crypt=2, nand_big=False,
                      nands=[("0.8e", "4b61ac62"), ("1.8d", "c87b5e86"), ("2.7e", "e0a9339f")],
                      perm=(0xe, 0xc, 0xf, 0xd, 0xa, 0x9, 0x8, 0xb, 0x4, 0x5, 0x6, 0x7, 0x0, 0x1, 0x3, 0x2),
                      xor=0xAAAA, t2=ns10crypt.MRDRILRG, save_base=0x4200, save_size=0x4200),
    # MEM(N): 2 x K9F2808U0B, type-2 decrypter with the nonlinear bit table; EXIO(G) light-gun board
    "ptblank3":  dict(name="Point Blank 3 (World, GNN2 Ver.A)", parent=None, region="World", year=2000,
                      family="ptblank3_family", nands=[("gnn2vera_0.8e", "5ae03e23"), ("gnn2vera_1.8d", "82d2cfb5")]),
    "gunbalina": dict(name="Gunbalina (Japan, GNN1 Ver.A)", parent="ptblank3", region="Japan", year=2000,
                      family="ptblank3_family", nands=[("gnn1a.8e", "2371aaba"), ("gnn1a.8d", "6cd343e0")]),
    # MEM(N): 2 x K9F2808U0B, KEYCUS KC020A, type-2 decrypter (Mitchell)
    "gamshara":  dict(name="Gamshara (20020912A, 10021 Ver.A)", parent=None, region="World", year=2002,
                      family="gamshara_family", nands=[("10021a_e.8e", "1413b7d2"), ("10021a.8d", "73669ff7")]),
    "gamsharao": dict(name="Gamshara (20020716A, 10021 Ver.A)", parent="gamshara", region="World", year=2002,
                      family="gamshara_family", nands=[("10021a.8e", "6c0361fc"), ("10021a.8d", "73669ff7")]),
    # MEM(N): 2 x K9F2808U0B, KEYCUS KC034A (a reprogrammed Gamshara board), type-2 decrypter (Mitchell)
    "konotako":  dict(name="Kono e Tako (10021 Ver.A)", parent=None, region="Japan", year=2003,
                      board="N", crypt=2, nand_big=False, nands=[("0.8e", "63d23a0c"), ("1.8d", "bdbed53c")],
                      perm=(0xe, 0xf, 0xc, 0xd, 0x8, 0x9, 0xb, 0xa, 0x5, 0x4, 0x7, 0x6, 0x0, 0x1, 0x3, 0x2),
                      xor=0xAAAA, t2=ns10crypt.KONOTAKO, save_base=0x4200, save_size=0x4200,
                      manufacturer="Mitchell", category="Puzzle", joystick="8-way",
                      buttons=("Button 1,Start,Coin,Test,Service,Pause,Button 2", "A,Start,Select,L,R,R3,B"),
                      dips=[("Region", "0", None, "Export (Cristaltec),Japan")] +
                           [(f"SW1-{n}", str(8 - n), None, "On,Off") for n in range(1, 8)]),
    # ---- MEM(N) games that need no new hardware (parameters from MAME via mame_s10_import.py); untested
    "gjspace":   dict(name="GekiToride-Jong Space (10011 Ver.A)", parent=None, region="Japan", year=2001,
                      board="N", crypt=2, nand_big=False,
                      nands=[("10011.8e", "c581bca7"), ("10011.8d", "7fb4a3fe"), ("10011.7e", "31bfc843"), ("10011.7d", "15d83649")],
                      perm=(0x8, 0xa, 0x6, 0x5, 0x7, 0xe, 0x4, 0xf, 0xd, 0x9, 0x1, 0x0, 0x2, 0xb, 0xc, 0x3),
                      xor=0xAAAA, t2=ns10crypt.GJSPACE, save_base=0x4200, save_size=0x4200,
                      manufacturer="Namco / Metro", category="Puzzle", joystick="8-way", buttons=('Button 1,Start,Coin,Test,Service,Pause,Button 2,Button 3', 'A,Start,Select,L,R,R3,B,X'),
                      dips=[(f"SW1-{k}", str(8 - k), None, "On,Off") for k in range(2, 9)] + [("Service Mode", "7", None, "On,Off")]),
    "knpuzzle":  dict(name="Kotoba no Puzzle Mojipittan (Japan, KPM1 Ver.A)", parent=None, region="Japan", year=2001,
                      board="N", crypt=2, nand_big=False,
                      nands=[("kpm1vera_0.8e", "4b4255da"), ("kpm1vera_1.8d", "644595a6"), ("kpm1vera_2.7e", "6bf164e5")],
                      perm=(0xe, 0xf, 0xc, 0xd, 0xa, 0x8, 0xb, 0x9, 0x4, 0x5, 0x6, 0x7, 0x1, 0x3, 0x0, 0x2),
                      xor=0xAAAA, t2=ns10crypt.KNPUZZLE, save_base=0x4200, save_size=0x4200,
                      category="Puzzle", joystick="8-way", buttons=('Button 1,Start,Coin,Test,Service,Pause,Button 2,Button 3', 'A,Start,Select,L,R,R3,B,X')),
    "chocovdr":  dict(name="Uchuu Daisakusen: Chocovader Contactee (Japan, CVC1 Ver.A)", parent=None, region="Japan", year=2002,
                      board="N", crypt=2, nand_big=False,
                      nands=[("0.8e", "330d86d3"), ("1.8d", "4aecd6fc"), ("2.7e", "ac212e5a"), ("3.7d", "907d3d15"), ("4.6e", "1ed957dd")],
                      perm=(0xd, 0xc, 0xe, 0xf, 0x9, 0x8, 0xa, 0xb, 0x4, 0x7, 0x6, 0x5, 0x0, 0x3, 0x2, 0x1),
                      xor=0xAAAA, t2=ns10crypt.CHOCOVDR, save_base=0x4200, save_size=0x4200,
                      category="Action", joystick="8-way", buttons=('Button 1,Start,Coin,Test,Service,Pause,Button 2,Button 3', 'A,Start,Select,L,R,R3,B,X')),
    "panikuru":  dict(name="Panikuru Panekuru (Japan, PPA1 Ver.A)", parent=None, region="Japan", year=2002,
                      board="N", crypt=2, nand_big=False,
                      nands=[("0.8e", "a68b0965"), ("1.8d", "18e5135d"), ("2.7e", "cd3b25e0")],
                      perm=(0xe, 0xc, 0xf, 0xd, 0x8, 0x9, 0xa, 0xb, 0x4, 0x7, 0x6, 0x5, 0x1, 0x0, 0x3, 0x2),
                      xor=0xAAAA, t2=ns10crypt.PANIKURU, save_base=0x4200, save_size=0x4200,
                      category="Puzzle", joystick="8-way", buttons=('Button 1,Start,Coin,Test,Service,Pause,Button 2,Button 3', 'A,Start,Select,L,R,R3,B,X')),
    "startrgn":  dict(name="Star Trigon (Japan, STT1 Ver.A)", parent=None, region="Japan", year=2002,
                      board="N", crypt=2, nand_big=False,
                      nands=[("stt1a_0.bin", "1e090644"), ("stt1a_1.bin", "aa527694")],
                      perm=(0xe, 0xd, 0xc, 0xf, 0x9, 0xb, 0x8, 0xa, 0x4, 0x5, 0x6, 0x7, 0x0, 0x3, 0x2, 0x1),
                      xor=0xAAAA, t2=ns10crypt.STARTRGN, save_base=0x4200, save_size=0x4200,
                      category="Puzzle", joystick="8-way", players=1,
                      buttons=("Button 1,Start,Coin,Test,Service,Pause", "A,Start,Select,L,R,R3")),
}
MAIN = {"mrdrilr2": "mrdrilr2", "mrdrilr2j": "mrdrilr2", "mrdrilr2u": "mrdrilr2", "mrdrilrg": "mrdrilrg",
        "ptblank3": "ptblank3", "gunbalina": "ptblank3", "gamshara": "gamshara", "gamsharao": "gamshara",
        "konotako": "konotako", "gjspace": "gjspace", "knpuzzle": "knpuzzle", "chocovdr": "chocovdr",
        "panikuru": "panikuru", "startrgn": "startrgn"}
ALT_DIR = {"mrdrilr2": "_Mr. Driller 2", "ptblank3": "_Point Blank 3", "gamshara": "_Gamshara"}
BUTTONS = ("Drill,Start,Coin,Test,Service,Pause", "A,Start,Select,L,R,R3")
# DIP switches (MRA <switches>, ioctl index 254): one byte = MAME's SYSTEM port bits 7-0, active low,
# SW1:1 = bit 7 ... SW1:8 = bit 0. Games without named switches get SW1-1..8.
GENERIC_DIPS = [(f"SW1-{n}", str(8 - n), None, "On,Off") for n in range(1, 9)]
NL_OFF = 0x6400000               # nonlinear decrypter table in the DDR3 image (s10_loader NL_OFF)


def game(setname):
    g = dict(GAMES[setname])
    if "family" in g:
        g.update(BOARDS[g["family"]])
    return g


# ---------------------------------------------------------------------------------------------- record
def record(setname):
    """Board record, docs/ARCHITECTURE.md section 5 (464 bytes, little endian)."""
    g = game(setname)
    r = bytearray(464)
    r[0:4] = b"S10B"
    r[4] = 0 if g["board"] == "M" else 1
    r[5] = g["crypt"]
    r[6] = len(g.get("nands", [])) if g["board"] == "N" else 0
    r[7] = 1 if g.get("nand_big") else 0
    struct.pack_into("<H", r, 8, g["xor"])
    r[10:26] = bytes(g["perm"])
    r[26] = g.get("exio", 0xFF)                     # EXIO ident (0xFF = no expansion board)
    t2 = g.get("t2")
    r[27] = (1 if t2 and "table" in t2 else 0) | (2 if g.get("gun") else 0)
    struct.pack_into("<I", r, 28, g["save_base"])
    if t2:
        for j in range(16):
            struct.pack_into("<Q", r, 32 + 8 * j, t2["emask"][j])
            struct.pack_into("<Q", r, 160 + 8 * j, t2["dmask"][j])
            struct.pack_into("<Q", r, 296 + 8 * j, t2["ivtab"][j])
        struct.pack_into("<H", r, 288, t2["xmask"])
        struct.pack_into("<QQQQ", r, 424, t2["ac"], t2["ap"], t2["bc"], t2["bp"])
        struct.pack_into("<H", r, 456, t2["out"])
        if "table" in t2:
            struct.pack_into("<I", r, 460, t2["table"][2] * 8)
    return bytes(r)


# ---------------------------------------------------------------------------------------------- MRA
def mra_text(setname):
    g = game(setname)
    zips = f"{setname}.zip" + (f"|{g['parent']}.zip" if g["parent"] else "")
    rec = record(setname)
    L = ["<!--",
         f"  {g['name']} - Namco {g['year']} - MRA for the {CORE} MiSTer core (Namco System 10).",
         f"  MAME set {setname} (MAME 0.289 namcos10.cpp). No ROM data is embedded in this file.",
         "  Generated by scripts/s10tool.py mra ; layout documented in docs/ARCHITECTURE.md.",
         "",
         "  index 1  board record (MEM board type, descrambler, KEYCUS decrypter parameters)",
         "  index 0  BIOS part of the first flash / NAND (descrambled by the core into SDRAM)",
         "  index 2  MEM board image -> DDR3 0x32000000 (fast loading)",
         "  index 3  MEM(M) data mask ROMs -> DDR3 0x32800000 (fast loading)",
         f"  index 4  type-2 nonlinear bit table -> DDR3 0x{DDR3_IMG + NL_OFF:08X} (Point Blank 3 family)",
         f"  index 9  settings (nvram): image offset 0x{g['save_base']:X}, {g['save_size']} bytes",
         "-->",
         "<misterromdescription>",
         f"    <name>{g['name']}</name>",
         f"    <setname>{setname}</setname>"]
    if g["parent"]:
        L.append(f"    <parent>{g['parent']}</parent>")
    L += [f"    <rbf>{CORE}</rbf>",
          f"    <mameversion>{MAMEVER}</mameversion>",
          f"    <year>{g['year']}</year>",
          f"    <manufacturer>{g.get('manufacturer', 'Namco')}</manufacturer>",
          f"    <category>{g.get('category', 'Puzzle')}</category>",
          f"    <region>{g['region']}</region>",
          f"    <players>{g.get('players', 2)}</players>",
          f"    <joystick>{g.get('joystick', '4-way')}</joystick>",
          "    <rotation>horizontal</rotation>",
          f"    <buttons names=\"{g.get('buttons', BUTTONS)[0]}\" default=\"{g.get('buttons', BUTTONS)[1]}\"/>",
          "",
          f"    <switches default=\"{g.get('dip_default', 0xFF):02X}\">"]
    for name, bits, values, ids in g.get("dips", GENERIC_DIPS):
        v = f" values=\"{values}\"" if values else ""
        L.append(f"        <dip name=\"{name}\" bits=\"{bits}\"{v} ids=\"{ids}\"/>")
    L += ["    </switches>",
          "",
          "    <rom index=\"1\">",
          "        <!-- board record -->"]
    for k in range(0, len(rec), 32):
        L.append("        <part>" + " ".join("%02X" % b for b in rec[k:k + 32]) + "</part>")
    L.append("    </rom>")
    if g["board"] == "M":
        fn, crc = g["flash"]
        L += [f"    <rom index=\"0\" zip=\"{zips}\" md5=\"None\">",
              f"        <part name=\"{fn}\" crc=\"{crc}\" length=\"0x{MEMM_BIOS_LEN:X}\"/>",
              "    </rom>",
              f"    <rom index=\"2\" zip=\"{zips}\" md5=\"None\" address=\"0x{DDR3_IMG:08X}\">",
              f"        <part name=\"{fn}\" crc=\"{crc}\"/>",
              "    </rom>",
              f"    <rom index=\"3\" zip=\"{zips}\" md5=\"None\" address=\"0x{DDR3_IMG + 0x800000:08X}\">"]
        for n, c, _ in g["data"]:
            L.append(f"        <part name=\"{n}\" crc=\"{c}\"/>")
        L.append("    </rom>")
    else:
        n0, c0 = g["nands"][0]
        off = MEMN_BIOS_FIRST * MEMN_PAGE
        L += [f"    <rom index=\"0\" zip=\"{zips}\" md5=\"None\">",
              f"        <part name=\"{n0}\" crc=\"{c0}\" offset=\"0x{off:X}\" length=\"0x{(MEMN_BIOS_END - MEMN_BIOS_FIRST) * MEMN_PAGE:X}\"/>",
              "    </rom>",
              f"    <rom index=\"2\" zip=\"{zips}\" md5=\"None\" address=\"0x{DDR3_IMG:08X}\">"]
        for n, c in g["nands"]:
            L.append(f"        <part name=\"{n}\" crc=\"{c}\"/>")
        L.append("    </rom>")
        t2 = g.get("t2") or {}
        if "table" in t2:
            tn, tc, _ = t2["table"]
            tz = f"{g['parent'] or setname}.zip"
            L += [f"    <rom index=\"4\" zip=\"{tz}\" md5=\"None\" address=\"0x{DDR3_IMG + NL_OFF:08X}\">",
                  f"        <part name=\"{tn}\" crc=\"{tc}\"/>",
                  "    </rom>"]
    L += [f"    <nvram index=\"9\" size=\"{g['save_size']}\"/>",
          "</misterromdescription>"]
    return "\n".join(L) + "\n"


def mra_path(setname):
    g = dict(GAMES[setname])
    g["name"] = g["name"].replace(":", " -")              # file name (MiSTer shows <name> from the file)
    if MAIN[setname] == setname:
        return os.path.join(ROOT, "MRA", g["name"] + ".mra")
    return os.path.join(ROOT, "MRA", "_alternatives", ALT_DIR[MAIN[setname]], g["name"] + ".mra")


def cmd_mra(args):
    for s in GAMES:
        p = mra_path(s)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", newline="\n") as f:
            f.write(mra_text(s))
        print("wrote", os.path.relpath(p, ROOT))


# ---------------------------------------------------------------------------------------------- ROMs
class ZipSet:
    """MiSTer looks parts up by CRC first, then by name, across the listed zips."""
    def __init__(self, names, romdir):
        self.zips = [zipfile.ZipFile(os.path.join(romdir, n)) for n in names if os.path.exists(os.path.join(romdir, n))]

    def get(self, name, crc):
        for z in self.zips:
            for i in z.infolist():
                if "%08x" % i.CRC == crc:
                    return z.read(i)
        for z in self.zips:
            for i in z.infolist():
                if i.filename.lower() == name.lower():
                    return z.read(i)
        raise FileNotFoundError(f"{name} ({crc})")


def bitswap16(v, perm):
    out = 0
    for i, src in enumerate(perm):                  # perm[0] = source of output bit 15
        out |= ((v >> src) & 1) << (15 - i)
    return out


def build_images(setname, romdir):
    g = game(setname)
    zs = ZipSet([f"{setname}.zip"] + ([f"{g['parent']}.zip"] if g["parent"] else []), romdir)
    bios = bytearray(b"\x55" * 0x400000)
    if g["board"] == "M":
        flash = zs.get(*g["flash"])
        for a in range(0, MEMM_BIOS_LEN, 2):
            w = struct.unpack_from("<H", flash, a)[0]
            struct.pack_into("<H", bios, a, bitswap16(w ^ 0xAAAA, g["perm"]))
        ddr = bytearray(flash) + bytearray(0x800000 - len(flash))
        for n, c, size in g["data"]:
            ddr += zs.get(n, c)
    else:
        nands = [zs.get(n, c) for n, c in g["nands"]]
        n0 = nands[0]
        def copy(dst, first, count):
            for page in range(first, first + count):
                a = page * MEMN_PAGE
                for i in range(0, 0x200, 2):
                    w = (n0[a + i] << 8) | n0[a + i + 1]
                    struct.pack_into("<H", bios, dst, bitswap16(w ^ g["xor"], g["perm"]))
                    dst += 2
        copy(0, 0x40, 0xE0)
        copy(0x20000, 0x120, 0x1F00)
        ddr = b"".join(nands)
        t2 = g.get("t2") or {}
        if "table" in t2:
            ddr = ddr + bytes(NL_OFF - len(ddr)) + zs.get(*t2["table"][:2])
    return bytes(bios), bytes(ddr)


def cmd_record(args):
    with open(args.out, "wb") as f:
        f.write(record(args.set))


def cmd_images(args):
    os.makedirs(args.dir, exist_ok=True)
    bios, ddr = build_images(args.set, args.romdir)
    for n, d in (("bios.bin", bios), ("ddr.bin", ddr), ("record.bin", record(args.set))):
        with open(os.path.join(args.dir, n), "wb") as f:
            f.write(d)
    print(f"{args.set}: bios 0x{len(bios):X}, ddr 0x{len(ddr):X} bytes -> {args.dir}")


def cmd_check(args):
    ok = True
    for s in (args.sets or list(GAMES)):
        ref = os.path.join(ROOT, "local", "mame", f"bios_{s}.bin")
        bios, _ = build_images(s, args.romdir)
        if not os.path.exists(ref):
            print(f"{s:10s} no MAME dump ({os.path.relpath(ref, ROOT)})")
            continue
        m = open(ref, "rb").read()
        same = m == bios
        ok &= same
        if not same:
            diff = next(i for i in range(min(len(m), len(bios))) if m[i] != bios[i])
            print(f"{s:10s} BIOS MISMATCH at 0x{diff:X} (MAME {len(m)} bytes)")
        else:
            print(f"{s:10s} BIOS == MAME maincpu:rom ({len(bios)} bytes)")
    print("ALL OK" if ok else "FAIL")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--romdir", default=ROMDIR)
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("mra")
    p = sp.add_parser("record"); p.add_argument("set"); p.add_argument("out")
    p = sp.add_parser("images"); p.add_argument("set"); p.add_argument("dir")
    p = sp.add_parser("check"); p.add_argument("sets", nargs="*")
    args = ap.parse_args()
    return {"mra": cmd_mra, "record": cmd_record, "images": cmd_images, "check": cmd_check}[args.cmd](args) or 0


if __name__ == "__main__":
    sys.exit(main())
