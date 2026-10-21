#!/usr/bin/env python3
"""Namco System 10 ROM-board stream decrypters (Python reference models).

Faithful ports of MAME 0.289 src/mame/namco/ns10crypt.cpp:
  * Type1         - ns10_type1_decrypter_device (MEM(M), mrdrilr2)
  * Type2Generic  - ns10_type2_decrypter_device with the nonlinear term expressed generically as
                    (parity(Ac&C ^ Ap&P) & parity(Bc&C ^ Bp&P)) * outMask
  * Type2Mame     - ns10_type2_decrypter_device with a Python callable as nonlinear term (literal
                    port of the per-game lambda), used to prove the generic form equivalent.

C and P are the 64-bit histories of the last four cipher / plain words exactly as MAME keeps them
(newest word in bits 15..0, shifted left by 16 per word, older words fall off the top).

Also contains the per-game parameter sets (MRDRILRG) and helpers to pack them into the wide
vectors the RTL (rtl/s10_crypt_t2.sv) takes.
"""

M64 = (1 << 64) - 1


def parity(x):
    return bin(x).count("1") & 1


def bitswap16(v, *bits):
    """MAME bitswap<16>(v, b15, b14, ..., b0): result bit (15-i) = v bit bits[i]."""
    assert len(bits) == 16
    r = 0
    for b in bits:
        r = (r << 1) | ((v >> b) & 1)
    return r


def bit(v, n):
    return (v >> n) & 1


# ---------------------------------------------------------------------------------------------
# Type 1 (mrdrilr2)
# ---------------------------------------------------------------------------------------------
U = 16  # UNKNOWN in MAME; INIT_SBOX[iv] == 16 would be an (unused) out-of-range mask value
T1_INIT_SBOX = [U, U, U, 0, 4, 9, U, U, U, 8, U, 1, U, 9, U, 5]


class Type1:
    def __init__(self):
        self.reset()

    def reset(self):
        self.active = False
        self.mask = 0
        self.counter = 0

    def activate(self, iv):
        self.mask = T1_INIT_SBOX[iv & 15] & 0xFFFF
        self.counter = 0
        self.active = True

    def deactivate(self):
        self.active = False

    def decrypt(self, c):
        m = self.mask
        k = self.counter
        p = m ^ bitswap16(c, 9, 13, 15, 7, 14, 8, 6, 10, 11, 12, 3, 5, 0, 1, 4, 2)
        nbs = ((bit(k, 4)) << 15) ^ \
              ((bit(c, 2) ^ bit(c, 5)) << 14) ^ \
              ((bit(c, 0)) << 13) ^ \
              ((bit(c, 4) | bit(c, 5)) << 12) ^ \
              ((bit(k, 0)) << 11) ^ \
              ((bit(c, 6)) << 10) ^ \
              ((bit(c, 4) & bit(k, 1)) << 8) ^ \
              ((bit(k, 3)) << 6) ^ \
              ((bit(c, 3) | bit(k, 7)) << 5) ^ \
              ((bit(c, 2) ^ bit(k, 3)) << 4) ^ \
              ((bit(k, 2)) << 3) ^ \
              ((bit(c, 7) & bit(k, 7)) << 2) ^ \
              ((bit(k, 5)) << 1) ^ \
              ((bit(c, 7) | bit(k, 1)) << 0)
        self.mask = (nbs ^ bitswap16(c, 6, 11, 3, 1, 13, 5, 15, 10, 2, 9, 8, 4, 0, 12, 7, 14)
                     ^ bitswap16(p, 9, 7, 5, 2, 14, 4, 13, 8, 0, 15, 10, 1, 3, 6, 12, 11) ^ 0xECBE) & 0xFFFF
        self.counter = (k + 1) & 0xFF
        return p


# ---------------------------------------------------------------------------------------------
# Type 2
# ---------------------------------------------------------------------------------------------
class Type2Base:
    def __init__(self, emask, dmask, xmask, ivtab):
        assert len(emask) == 16 and len(dmask) == 16 and len(ivtab) == 16
        self.emask = list(emask)
        self.dmask = list(dmask)
        self.xmask = xmask
        self.ivtab = list(ivtab)
        self.reset()

    def reset(self):
        self.active = False
        self.mask = 0
        self.C = 0
        self.P = 0

    def activate(self, iv):
        self.C = self.ivtab[iv & 15] & M64
        self.P = 0
        self.mask = 0
        self.active = True

    def deactivate(self):
        self.active = False

    def nonlinear(self, C, P):
        raise NotImplementedError

    def decrypt(self, c):
        p = c ^ self.mask
        C = ((self.C << 16) ^ c) & M64
        P = ((self.P << 16) ^ p) & M64
        m = 0
        for j in range(15, -1, -1):
            m = (m << 1) ^ parity(self.emask[j] & C) ^ parity(self.dmask[j] & P)
        m ^= self.xmask
        m ^= self.nonlinear(C, P)
        self.C, self.P, self.mask = C, P, m & 0xFFFF
        return p


class Type2Mame(Type2Base):
    """Literal port: nonlinear term is a Python callable f(C, P) -> u16 (as MAME's lambda)."""

    def __init__(self, emask, dmask, xmask, ivtab, nlfunc):
        self.nlfunc = nlfunc
        super().__init__(emask, dmask, xmask, ivtab)

    def nonlinear(self, C, P):
        return self.nlfunc(C, P) & 0xFFFF


class Type2Generic(Type2Base):
    """Generic hardware form: (parity(Ac&C ^ Ap&P) & parity(Bc&C ^ Bp&P)) * outMask."""

    def __init__(self, emask, dmask, xmask, ivtab, ac, ap, bc, bp, out):
        self.ac, self.ap, self.bc, self.bp, self.out = ac, ap, bc, bp, out
        super().__init__(emask, dmask, xmask, ivtab)

    def nonlinear(self, C, P):
        a = parity((self.ac & C) ^ (self.ap & P))
        b = parity((self.bc & C) ^ (self.bp & P))
        return self.out if (a & b) else 0


# ---- mrdrilrg (namcos10.cpp ns10_mrdrilrg) ----
_MRDRILRG_MASKS = [
    0x0000115c68620401, 0x0000008102802094, 0x00000081a65270a8, 0x0000000000810010,
    0x00004c2c080f3059, 0x00000081470a9500, 0x000000816a123009, 0x00000081a2b23038,
    0x00002d18a06b9000, 0x000001186c02000c, 0x00000081a2b2704c, 0x0000702811016302,
    0x00000081470a1122, 0x0000000000006200, 0x00009170ac403013, 0x0000000000001044,
]
MRDRILRG = dict(
    emask=list(_MRDRILRG_MASKS),
    dmask=list(_MRDRILRG_MASKS),
    xmask=0x0000,
    ivtab=[0x0000, 0x0000, 0x0000, 0x2000, 0x801a, 0x6000, 0x0002, 0x0000,
           0x0000, 0x0018, 0x0000, 0x0420, 0x0000, 0x8800, 0x0000, 0xc000],
    # generic nonlinear form of the MAME lambda (A and B both act on C^P)
    ac=0x120100400000, ap=0x120100400000,
    bc=0x11800020000, bp=0x11800020000,
    out=0x0011,
)


def mrdrilrg_mame_lambda(C, P):
    pm = C ^ P
    return (1 & parity(pm & 0x120100400000) & parity(pm & 0x11800020000)) * 0x11


def mrdrilrg_mame():
    g = MRDRILRG
    return Type2Mame(g["emask"], g["dmask"], g["xmask"], g["ivtab"], mrdrilrg_mame_lambda)


def type2_generic(g):
    return Type2Generic(g["emask"], g["dmask"], g["xmask"], g["ivtab"],
                        g["ac"], g["ap"], g["bc"], g["bp"], g["out"])


def mrdrilrg_generic():
    return type2_generic(MRDRILRG)


# ---- ptblank3 / gunbalina (namcos10.cpp ns10_ptblank3): NS10_TYPE2_DECRYPTER_NONLINEAR, the nonlinear term
# is bit n of the recorded "ptblank3_nonlinear" table (n = words decrypted since reset) shifted to bit 11;
# IV from the default INIT_SBOX: bitswap<16>(INIT_SBOX[iv], 3,16,16,2,1,16,16,0,16 x 8).
_T2_INIT_SBOX = [0, 12, 13, 6, 2, 4, 9, 8, 11, 1, 7, 15, 10, 5, 14, 3]


def _sbox_iv(v):
    return (((v >> 3) & 1) << 15) | (((v >> 2) & 1) << 12) | (((v >> 1) & 1) << 11) | ((v & 1) << 8)


PTBLANK3 = dict(
    emask=[0x0000000057001200, 0x00000000000000a4, 0x0000000000000150, 0x0000000000008004,
           0x0000000057002204, 0x0000000009001000, 0x0000000000102000, 0x0000000064004888,
           0x0000000000100008, 0x000000a0c0980600, 0x000000001801c020, 0x00005810881a09c0,
           0x0000000400980600, 0x0000000000000300, 0x0000000000000080, 0x0000000000a00c0a],
    dmask=[0x0000000041051000, 0x0000000000000024, 0x0000000000000050, 0x0000000000008004,
           0x0000000041052200, 0x0000000009401100, 0x0000000000122000, 0x0000000004100898,
           0x0000000000120088, 0x0000000040a80400, 0x0000000019004000, 0x000001859830281d,
           0x0000002400880201, 0x0000000000000300, 0x00000000000000c0, 0x0000000000000408],
    xmask=0xe1b8,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    ac=0, ap=0, bc=0, bp=0,
    out=0x0800,
    table=("ptblank3_nonlinear", "5997d7dd", 0x2ec00),
)


# ---- gamshara / gamsharao (namcos10.cpp ns10_gamshara): pm = C ^ P; nonlinear = (pm[7] & pm[13]) << 2
GAMSHARA = dict(
    emask=[0x0000000000000028, 0x0000cae83f389fd9, 0x0000000000001000, 0x0000000042823402,
           0x0000cae8736a0592, 0x0000cae8736a8596, 0x000000008b4095b9, 0x0000000000002100,
           0x0000000004018228, 0x0000000000000042, 0x0000000000000818, 0x0000000000004010,
           0x000000008b4099f1, 0x00000000044bce08, 0x00000000000000c1, 0x0000000042823002],
    dmask=[0x0000000000000028, 0x00000904c2048dd9, 0x0000000000008000, 0x0000000054021002,
           0x00000904e0078592, 0x00000904e00785b2, 0x00000000440097f9, 0x0000000000002104,
           0x0000000029018308, 0x0000000000000042, 0x0000000000000850, 0x0000000000004012,
           0x000000004400d1f1, 0x000000006001ce08, 0x00000000000000c8, 0x0000000054023002],
    xmask=0x25ab,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    ac=1 << 7, ap=1 << 7, bc=1 << 13, bp=1 << 13,
    out=0x0004,
)


# ---- konotako (namcos10.cpp ns10_konotako): pm = C ^ P; nonlinear = (pm[7] & pm[15]) << 15
KONOTAKO = dict(
    emask=[0x000000000000004c, 0x00000000d39e3d3d, 0x0000000000001110, 0x0000000000002200,
           0x000000003680c008, 0x0000000000000281, 0x0000000000005002, 0x00002a7371895a47,
           0x0000000000000003, 0x00002a7371897a4e, 0x00002a73aea17a41, 0x00002a73fd895a4f,
           0x000000005328200a, 0x0000000000000010, 0x0000000000000040, 0x0000000000000200],
    dmask=[0x000000000000008c, 0x0000000053003d25, 0x0000000000001120, 0x0000000000002200,
           0x0000000037004008, 0x0000000000000282, 0x0000000000006002, 0x0000060035005a47,
           0x0000000000000003, 0x0000060035001a4e, 0x0000060025007a41, 0x00000600b5005a2f,
           0x000000009000200b, 0x0000000000000310, 0x0000000000001840, 0x0000000000000400],
    xmask=0x0748,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    ac=1 << 7, ap=1 << 7, bc=1 << 15, bp=1 << 15,
    out=0x8000,
)

# ---- generated from MAME namcos10.cpp by mame_s10_import.py; nonlinear terms in the generic form
GJSPACE = dict(
    emask=[0x0000000000000240, 0x0000d617eb0f1ab1, 0x00000000451111c0, 0x00000000013b1f44, 0x0000aab0b356abce, 0x00007ca76b89602a, 0x0000000000001800, 0x00000000031d1303, 0x0000000000000801, 0x0000000030111160, 0x0000000001ab3978, 0x00000000c131b160, 0x0000000000001110, 0x0000000000008002, 0x00000000e1113540, 0x0000d617fdce8bfc],
    dmask=[0x0000000000008240, 0x000000002f301ab1, 0x00000000050011c0, 0x00000000412817c4, 0x00000004c338abc6, 0x000000046108602a, 0x0000000000005800, 0x00000000c3081347, 0x0000000000000801, 0x0000000061001160, 0x0000000061183978, 0x00000000e520b142, 0x0000000000001101, 0x000000000000a002, 0x0000000029001740, 0x00000000a4309bfc],
    xmask=0x2e7f,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    ac=0x0, ap=0x0, bc=0x0, bp=0x0,
    out=0x0000,
)
KNPUZZLE = dict(
    emask=[0x00000000c0a4208c, 0x00000000204100a8, 0x000000000c0306a0, 0x000000000819e944, 0x0000000000001400, 0x0000000000000061, 0x000000000141401c, 0x0000000000000020, 0x0000000001418010, 0x00008d6a1eb690cf, 0x00008d6a4d3b90ce, 0x0000000000004201, 0x00000000012c00a2, 0x000000000c0304a4, 0x0000000000000500, 0x0000000000000980],
    dmask=[0x000000002a22608c, 0x00000000002300a8, 0x0000000000390ea0, 0x000000000100a9c4, 0x0000000000001400, 0x0000000000000041, 0x0000000003014014, 0x0000000000000022, 0x0000000003010110, 0x00000800031a80cf, 0x00000800003398de, 0x0000000000004200, 0x00000000012a04a2, 0x00000000003984a4, 0x0000000000000700, 0x0000000000000882],
    xmask=0x01e2,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    ac=0x80000, ap=0x80000, bc=0x14001290, bp=0x21290,
    out=0x0002,
)
CHOCOVDR = dict(
    emask=[0x00005239351ec1da, 0x0000000000008090, 0x0000000048264808, 0x0000000000004820, 0x0000000000000500, 0x0000000058ff5a54, 0x00000000d8220208, 0x00005239351e91d3, 0x000000009a1dfaff, 0x0000000090040001, 0x0000000000000100, 0x0000000000001408, 0x0000000032efd3f1, 0x00000000000000d0, 0x0000000032efd2d7, 0x0000000000000840],
    dmask=[0x00002000410485da, 0x0000000000008081, 0x0000000008044088, 0x0000000000004802, 0x0000000000000500, 0x00000000430cda54, 0x0000000010000028, 0x00002000410491db, 0x000000001100fafe, 0x0000000018040001, 0x0000000000000010, 0x0000000000000508, 0x000000006800d3f5, 0x0000000000000058, 0x000000006800d2d5, 0x0000000000001840],
    xmask=0x5b22,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    ac=0x200, ap=0x200, bc=0x10065810, bp=0x21005810,
    out=0x0400,
)
PANIKURU = dict(
    emask=[0x0000000000000130, 0x0000000018802004, 0x0000b04a04781081, 0x0000000006802000, 0x0000000000000c02, 0x0000000042040020, 0x0000000000000003, 0x0000b040c00c0940, 0x0000000000000009, 0x00001020a0010400, 0x0000000010204104, 0x000000005a840004, 0x0000000000000290, 0x0000000010204380, 0x0000000000001041, 0x0000000000006100],
    dmask=[0x0000000000000120, 0x0000000028002004, 0x0000010800480001, 0x0000000006040100, 0x0000000000000c00, 0x0000000042000820, 0x0000000000001003, 0x0000910212040100, 0x0000000000008009, 0x0000900021018000, 0x0000000090004104, 0x000000006a004004, 0x0000000000000214, 0x0000000090004190, 0x0000000000001040, 0x0000000000006008],
    xmask=0x7c29,
    ivtab=[0x0000, 0x020e, 0x0412, 0x0411, 0x0204, 0x001b, 0x0009, 0x0207, 0x2040, 0x2440, 0x0012, 0x0001, 0x0614, 0x000a, 0x0214, 0x041b],
    ac=0x88300281, ap=0x4600281, bc=0xa13140090000, bp=0x806240090000,
    out=0x0004,
)
STARTRGN = dict(
    emask=[0x00003e4bfe92c6a9, 0x000000000000010c, 0x00003e4b7bd6c4aa, 0x0000b1a904b8fab8, 0x0000000000000080, 0x0000000000008c00, 0x0000b1a9b2f0b4cd, 0x000000006c100828, 0x000000006c100838, 0x0000b1a9d3913fcd, 0x000000006161aa00, 0x0000000000006040, 0x0000000000000420, 0x0000000000001801, 0x00003e4b7bd6deab, 0x0000000000000105],
    dmask=[0x000012021f00c6a8, 0x0000000000000008, 0x000012020b1046aa, 0x000012001502fea8, 0x0000000000002000, 0x0000000000008800, 0x000012001e02b4cd, 0x000000002c0008aa, 0x000000002c00083a, 0x000012003f027ecd, 0x0000000021008a00, 0x0000000000002040, 0x0000000000000428, 0x0000000000001001, 0x000012020b10ceab, 0x0000000000000144],
    xmask=0x8c46,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    ac=0x1000, ap=0x1000, bc=0x4000, bp=0x4000,
    out=0x0010,
)
TAIKO2 = dict(
    emask=[0x0000000004011401, 0x000000008c208806, 0x000000008c200406, 0x0000004a08002208, 0x0000000030800000, 0x0000000000000540, 0x000000002c01011e, 0x00000000ad4805c6, 0x0000000030000004, 0x0000000048100080, 0x0000003461204408, 0x00004510422000c0, 0x0000080080210002, 0x00000000ae004004, 0x000000008c100016, 0x0000000082010009],
    dmask=[0x00000000a4019401, 0x000000005e600a06, 0x000000005e604406, 0x0000410308002208, 0x0000000030020400, 0x0000000000000150, 0x00000000ec09010e, 0x000000004ecc04c2, 0x0000000030001004, 0x0000000048304180, 0x0000141249886488, 0x000000454a000081, 0x0000184022210002, 0x000000006c00400c, 0x000000004e140816, 0x0000000080090008],
    xmask=0x0000,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    ac=0x2000000, ap=0x2000000, bc=0x80000000, bp=0x80000000,
    out=0x0010,
)
TAIKO4 = dict(
    emask=[0x0000000042c82001, 0x0000000000000200, 0x000000000910405c, 0x0000000000000c00, 0x000000000f401100, 0x000000000910002a, 0x00006280110a0440, 0x0000000040680044, 0x00000000b408b000, 0x0000000000108860, 0x0000000009100008, 0x0000a024b0000000, 0x000000000a401a40, 0x0000000000001400, 0x0000000000100162, 0x0000000020402081],
    dmask=[0x0000000082102019, 0x0000000000000400, 0x0000000005104050, 0x0000000000000c00, 0x0000000002001d00, 0x000000000510001a, 0x0000129910a10443, 0x0000000040040044, 0x0000000034088000, 0x0000000000259060, 0x0000000005100188, 0x0000204480000000, 0x000000000a801a80, 0x0000000000001400, 0x0000000000250262, 0x0000000020404081],
    xmask=0x0000,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    ac=0x4, ap=0x4, bc=0x4000, bp=0x4000,
    out=0x0002,
)
TAIKO6 = dict(
    emask=[0x00000000000000a2, 0x00000000000000c8, 0x0000909054044a04, 0x00009180101a2200, 0x0000000050002840, 0x0000000000004005, 0x000000000e220900, 0x0000000086000004, 0x0000000014220d22, 0x0000000000000110, 0x0000000000000214, 0x0000000000001000, 0x0000000031088890, 0x0000000000000802, 0x00000000f025e800, 0x0000000000000010],
    dmask=[0x00000000000000a4, 0x0000000000000148, 0x00002090a2078a04, 0x0000218020012218, 0x0000000050c22840, 0x0000000000004009, 0x00000000164109c0, 0x000000008a000004, 0x0000000014410d42, 0x0000000000000110, 0x0000000000000414, 0x0000000000001003, 0x00000000320b0890, 0x0000000000000802, 0x00000000902a8800, 0x0000000000000020],
    xmask=0x0000,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    ac=0x2000, ap=0x2000, bc=0x86000000, bp=0x8a000000,
    out=0x8000,
)

# ---- GAHAHA Ippatsudou 1 / 2 (namcos10.cpp ns10_gahaha / ns10_gahaha2)
GAHAHA = dict(
    emask=[0x0000000010a08200, 0x00000000001b0204, 0x00004ba503024016, 0x0000000000000004, 0x0000000000000240, 0x0000000088080180, 0x000011821ce50066, 0x000000000a204200, 0x0000000014018800, 0x00000000000000a0, 0x0000000000000412, 0x0000000000004002, 0x000000003100c002, 0x0000000000002100, 0x00000000084000a4, 0x0000000031010180],
    dmask=[0x0000000000808000, 0x0000004400130200, 0x0000021804a54036, 0x0000000000000014, 0x0000000000000240, 0x0000000085000100, 0x000008ca15400166, 0x000000009822c280, 0x0000000014008008, 0x00000000000010a0, 0x0000000000000016, 0x0000000000004002, 0x000000003120c000, 0x0000000000002100, 0x0000000018e002a6, 0x00000000a19121a0],
    xmask=0xaea7,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    ac=0x0, ap=0x0, bc=0x0, bp=0x0,          # nonlinear = 0
    out=0x0000,
)
# pm = C ^ P; nonlinear = ((pm[26] ^ pm[37]) & pm[46]) * 0x8860
GAHAHA2 = dict(
    emask=[0x0000000080064001, 0x000000000a000104, 0x0000018220912000, 0x0000000001822010, 0x00000000000001a0, 0x00000481a4220004, 0x0000a11490041269, 0x0000000000000810, 0x000000000a008200, 0x00000000010b0010, 0x0000000052108820, 0x0000042209a00258, 0x0000000001820401, 0x0000000090040040, 0x0000000000001002, 0x0000209008020004],
    dmask=[0x0000000000020001, 0x000000000a000024, 0x0000018000830400, 0x0000000001802002, 0x0000000000000130, 0x0000200110060004, 0x00000581080c1260, 0x0000000000000810, 0x000000000a008040, 0x0000000021bf0010, 0x0000000040588820, 0x0000003000220210, 0x0000000001800400, 0x0000000090000040, 0x0000000000009002, 0x00000403a5020004],
    xmask=0x925a,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    ac=(1 << 26) | (1 << 37), ap=(1 << 26) | (1 << 37), bc=1 << 46, bp=1 << 46,
    out=0x8860,
)

# ---- MEM(P3) games (namcos10.cpp ns10_g13jnr / ns10_nicetsuk / ns10_squizchs); pm = C ^ P
# g13jnr: nonlinear = (pm[6] & pm[10]) << 14
G13JNR = dict(
    emask=[0x00005600001c0582, 0x0000000000004024, 0x0000010212403000, 0x0000000000008404, 0x0000005121060021, 0x0000010212402001, 0x0000000001024000, 0x0000000000000840, 0x00000981c2100148, 0x0000000020108400, 0x0000000008110134, 0x0000000000000003, 0x00004c9801080102, 0x0000000040860083, 0x0000000000000001, 0x0000000000000288],
    dmask=[0x0000441800340584, 0x0000000000004028, 0x0000010212800000, 0x0000000000000404, 0x0000485022000041, 0x0000010212804001, 0x0000000001028000, 0x0000000000000841, 0x00000e0104080150, 0x0000000023208400, 0x0000000040110104, 0x0000000000000003, 0x0000470001100102, 0x00000000408c0083, 0x0000000000000002, 0x0000000000000308],
    xmask=0x9546,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    ac=1 << 6, ap=1 << 6, bc=1 << 10, bp=1 << 10,
    out=0x4000,
)
# nicetsuk: nonlinear = (pm[12] & (parity(C & 0x808400410000) ^ parity(P & 0x81100630000))) << 4
NICETSUK = dict(
    emask=[0x0000000000000022, 0x0000000000008082, 0x0000808400d10000, 0x0000000000000088, 0x0000000000001040, 0x0000000000001600, 0x0000000714400404, 0x0000000021c40800, 0x0000000000004018, 0x000000002c450200, 0x0000000000000c01, 0x0000000000000180, 0x000000000c000414, 0x0000000000000110, 0x0000000023006000, 0x0000000000000068],
    dmask=[0x0000000000000026, 0x0000000000008802, 0x0000081100f22000, 0x000000000000008a, 0x0000000000001400, 0x0000000000000600, 0x00000012d8400404, 0x0000000021804800, 0x0000000000004090, 0x0000000068012000, 0x0000000000004801, 0x0000000000000180, 0x00000000c8000504, 0x0000000000000111, 0x0000000032086008, 0x0000000000000248],
    xmask=0x9f6b,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    ac=1 << 12, ap=1 << 12, bc=0x808400410000, bp=0x81100630000,
    out=0x0010,
)
# squizchs: nonlinear = (pm[12] & (parity(C & 0x140840000000) ^ parity(P & 0x141040000000))) << 14; IV table from the driver
SQUIZCHS = dict(
    emask=[0x0000000080203001, 0x000000008e001402, 0x0000000000000005, 0x0000000002030840, 0x0000000000008420, 0x0000000000000088, 0x000000001c020442, 0x00000080c0a01041, 0x00000000a1800d08, 0x0000000000002240, 0x0000020385a08010, 0x0000008054080024, 0x0000000080209020, 0x00001408c4200004, 0x0000000000000010, 0x0000000000004108],
    dmask=[0x0000000080203001, 0x0000000008001404, 0x0000000000000005, 0x0000000002001040, 0x0000000000000420, 0x0000000000000089, 0x0000000020020842, 0x00000100c1201081, 0x00000000dc800b08, 0x0000000000004240, 0x0000020006a08010, 0x0000010054100044, 0x0000000080209020, 0x0000141044200008, 0x0000000000000020, 0x0000000000008108],
    xmask=0x0000,
    ivtab=[16, 0x9000, 0x9101] + [16] * 13,
    ac=1 << 12, ap=1 << 12, bc=0x140840000000, bp=0x141040000000,
    out=0x4000,
)

# ---- multi-term nonlinear games: nonlinear = out * XOR_t (parity(Ac&C ^ Ap&P) & parity(Bc&C ^ Bp&P))
class Type2Terms(Type2Base):
    """Generic hardware form with several product terms; terms = [(ac, ap, bc, bp), ...]."""

    def __init__(self, emask, dmask, xmask, ivtab, terms, out):
        self.terms, self.out = terms, out
        super().__init__(emask, dmask, xmask, ivtab)

    def nonlinear(self, C, P):
        v = 0
        for ac, ap, bc, bp in self.terms:
            v ^= parity((ac & C) ^ (ap & P)) & parity((bc & C) ^ (bp & P))
        return self.out if v else 0


def terms_of(g):
    """(ac, ap, bc, bp) term list of a parameter dict (single-term dicts give one term)."""
    return g.get("terms") or [(g["ac"], g["ap"], g["bc"], g["bp"])]


B = lambda *bits: sum(1 << b for b in bits)

TAIKO3 = dict(
    emask=[0x00000000016d0400, 0x000000001a002021, 0x0000018884002000, 0x00000000000040a0, 0x000000003010800c, 0x0000020504100842, 0x0000008818148104, 0x0000000053220100, 0x0000000048000002, 0x0000000000008060, 0x000000003010000c, 0x00003c00d8802c00, 0x000009a8ca110004, 0x000000003010d200, 0x0000000000000450, 0x0000000052001010],
    dmask=[0x0000000000050400, 0x000000008a012028, 0x0000050804002000, 0x00000000000000a0, 0x000000003080800c, 0x0000108968100850, 0x0000000050a08804, 0x00000000c3292100, 0x0000000048010000, 0x0000000000008140, 0x0000000030800044, 0x000018905a800800, 0x00002a004a150020, 0x0000000030804200, 0x0000000000000610, 0x00000000c2001080],
    xmask=0x0000,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    terms=[(B(35, 39), B(40, 42), 0x820508000800, 0x90c12c000800), (B(35, 39), 0, 0, B(40, 42)), (B(40), B(35), 0x520000041004, 0xc20000201004)],
    out=0x0060,
)
TAIKO5 = dict(
    emask=[0x0000000000000244, 0x0000000098880004, 0x0000000018021806, 0x0000000000004810, 0x000005800ac04002, 0x0000000090044040, 0x0000000098240025, 0x0000000018022184, 0x0000000000002420, 0x0000000000002408, 0x0000000088068204, 0x00000b5001a02004, 0x0000000018020214, 0x0000218801801080, 0x0000000000000009, 0x0000000000000120],
    dmask=[0x0000000000001044, 0x00000000d0930004, 0x0000000050025006, 0x0000000000004880, 0x00000cc108804002, 0x0000000000040040, 0x0000000003042425, 0x0000000050022884, 0x0000000000000420, 0x0000000000002440, 0x0000000050060204, 0x0000091205012020, 0x0000000050020216, 0x0000288101811400, 0x0000000000000009, 0x0000000000000124],
    xmask=0x0000,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    terms=[(B(4), 0, 0x242800000000, 0x42100010000), (B(17), 0, 0x1094000, 0x100084000), (B(35), 0, 0x58200004, 0x10000014), (0, B(24), 0x101220000, 0x800030010), (B(24), B(16, 32), 0x40200000, 0x40020010)],
    out=0x0800,
)
TAIKORT = dict(
    emask=[0x0000000014020804, 0x000000000000c080, 0x0000000080140400, 0x0000000030102218, 0x0000704018840801, 0x0000000000002210, 0x00008c0102000080, 0x0000000000846000, 0x00000000b1120202, 0x0000000000001000, 0x0000000000000640, 0x00000000000040a0, 0x0000000090009200, 0x0000000000000908, 0x000000000c0c0000, 0x0000201810000000],
    dmask=[0x0000000010060824, 0x000000000000e000, 0x0000000080570000, 0x0000000038382210, 0x0000404011800001, 0x0000000000002600, 0x00001600b0080288, 0x0000000000944000, 0x00000000393a0280, 0x0000000000001820, 0x0000000000008440, 0x00000000000000a0, 0x0000000098619241, 0x0000000000004808, 0x000000000f201040, 0x0000a0d290820001],
    xmask=0x0000,
    ivtab=[_sbox_iv(v) for v in _T2_INIT_SBOX],
    terms=[(0, B(25), 0x40a000000001, 0xa000200001), (0, B(27), 0x2400440, 0x80400440), (B(19), 0, 0x18000201, 0x10000201), (B(0, 27), B(0, 21), B(6, 26), B(6, 26))],
    out=0x4010,
)


class Type2Table(Type2Base):
    """Nonlinear term from a bit table (MAME ns10_type2_decrypter_nonlinear_device)."""

    def __init__(self, emask, dmask, xmask, ivtab, out, table):
        self.out, self.table, self.count = out, table, 0
        super().__init__(emask, dmask, xmask, ivtab)

    def nonlinear(self, C, P):
        b = (self.table[self.count // 8] >> (7 - self.count % 8)) & 1
        self.count = (self.count + 1) % (len(self.table) * 8)
        return self.out if b else 0


def pack_wide(values, width):
    """Pack a list into one integer, element i at bits [i*width +: width] (RTL vector layout)."""
    r = 0
    for i, v in enumerate(values):
        r |= (v & ((1 << width) - 1)) << (i * width)
    return r


def t2_param_vectors(g):
    """Return the RTL parameter vectors as hex strings (no prefix), MSB first."""
    return dict(
        emask="%0256x" % pack_wide(g["emask"], 64),
        dmask="%0256x" % pack_wide(g["dmask"], 64),
        xmask="%04x" % g["xmask"],
        ivtab="%0256x" % pack_wide(g["ivtab"], 64),
        nl_ac="%016x" % g["ac"], nl_ap="%016x" % g["ap"],
        nl_bc="%016x" % g["bc"], nl_bp="%016x" % g["bp"],
        nl_out="%04x" % g["out"],
    )


if __name__ == "__main__":
    import random
    # quick self-test: generic form == MAME lambda on random streams with random (re)activations
    rnd = random.Random(1)
    a, b = mrdrilrg_mame(), mrdrilrg_generic()
    for i in range(200000):
        if i % 5000 == 0:
            iv = rnd.randrange(16)
            a.activate(iv); b.activate(iv)
        c = rnd.randrange(65536)
        assert a.decrypt(c) == b.decrypt(c)
    print("random self-test OK (generic nonlinear form == MAME lambda, 200000 words)")
