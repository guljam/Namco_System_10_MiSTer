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
