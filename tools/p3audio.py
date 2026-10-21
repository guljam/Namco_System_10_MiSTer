#!/usr/bin/env python3
"""Namco System 10 MEM(P3) audio converter (Golgo 13, Nice Tsukkomi, Seishun Quiz).

The MEM(P3) ROM board plays its music and voices with an MP3 decoder chip (Sanyo LC82310). The MiSTer core does
not decode MP3; this tool finds every MP3 file in the game's ROM set, decodes it, and writes one audio file the
core streams from the SD card (mounted once from the OSD, like the Taiko discs).

    python p3audio.py ROMDIR GAME [OUT]        e.g.  python p3audio.py C:\\MAME\\roms g13jnr

GAME is g13jnr, nicetsuk or squizchs; OUT defaults to GAME.p3a. Decoding uses ffmpeg (on the PATH) or, if that is
missing, the PyAV package (pip install av). --test-tones writes a short tone per track instead (no decoder needed;
for checking the core's stream matching).

File format (.p3a, little endian):
  0x0000  magic "NS10P3A1", u32 entry count, u32 sample rate (44100), u32 channels (2), u32 reserved
  0x0020  entries, 32 bytes each:  u32 MP3 length (bytes), u32 CRC-32 of bytes 0-63, u32 CRC-32 of bytes
          0x2000-0x203F (0 if shorter), u32 CRC-32 of bytes 0x10000-0x1003F (0 if shorter), u32 PCM start (1 KB
          blocks from the file start), u32 PCM length (stereo frames), 8 bytes reserved
  PCM     16-bit stereo at 44.1 kHz, each track starting on a 1 KB boundary
The core identifies a stream the game starts from the board's RAM: the game's length (the file length, or rounded
up to 2 KB) and the three 64-byte samples (the second only when the length is >= 12 KB, the third >= 72 KB).
"""
import io, os, struct, subprocess, sys, zipfile, zlib

# ROM layout per game (MAME 0.289 namcos10.cpp): NAND files, data XOR and the 16-bit unscramble permutation
GAMES = {
    "g13jnr": dict(xor=0xAAAA, perm=(0xe, 0xd, 0xc, 0xf, 0x9, 0xb, 0x8, 0xa, 0x6, 0x7, 0x4, 0x5, 0x1, 0x3, 0x0, 0x2),
                   nands=["glt1vera_0.2j", "glt1vera_1.1j", "glt1vera_2.2h", "glt1vera_3.1h", "glt1vera_4.2f",
                          "glt1vera_5.1f"]),
    "nicetsuk": dict(xor=0xAAAA, perm=(0xc, 0xf, 0xe, 0xd, 0xa, 0x8, 0xb, 0x9, 0x5, 0x4, 0x6, 0x7, 0x2, 0x3, 0x0, 0x1),
                     nands=["ntk1vera_0.2j", "ntk1vera_1.1j", "ntk1vera_2.2h", "ntk1vera_3.1h", "ntk1vera_4.2f",
                            "ntk1vera_5.1f", "ntk1vera_6.2e", "ntk1vera_7.1e"]),
    "squizchs": dict(xor=0xAAAA, perm=(0xe, 0xc, 0xf, 0xd, 0xa, 0x8, 0xb, 0x9, 0x6, 0x4, 0x7, 0x5, 0x0, 0x1, 0x3, 0x2),
                     nands=["chs1vera_%d.%s" % (i, p) for i, p in enumerate(
                         ["2j", "1j", "2h", "1h", "2f", "1f", "2e", "1e", "2d", "1d", "2c", "1c", "2b", "1b"])]),
}
PAGE, DATA = 528, 512
RATE = 44100


def bitswap16(v, perm):
    return sum(((v >> b) & 1) << (15 - i) for i, b in enumerate(perm))


def plain_nand(zf, game):
    """The NAND data as the game reads it (512-byte pages, unscrambled)."""
    import numpy as np
    g = GAMES[game]
    lut = np.array([bitswap16(w ^ g["xor"], g["perm"]) for w in range(65536)], dtype="<u2")
    parts = []
    for name in g["nands"]:
        raw = np.frombuffer(zf.read(name), dtype=np.uint8)
        pages = raw[:len(raw) // PAGE * PAGE].reshape(-1, PAGE)[:, :DATA]
        words = pages.reshape(-1).view(">u2")
        parts.append(lut[words].astype("<u2").tobytes())
    return b"".join(parts)


# ------------------------------------------------------------------ MP3 frame parsing
BITRATES = {  # (version id, layer III)
    3: [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0],      # MPEG-1
    2: [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0],          # MPEG-2
    0: [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0],          # MPEG-2.5
}
RATES = {3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000]}


def frame_len(b, i):
    """Length of the layer-III frame at b[i], or 0 if there is no valid header."""
    if i + 4 > len(b) or b[i] != 0xFF or (b[i + 1] & 0xE0) != 0xE0:
        return 0
    ver = (b[i + 1] >> 3) & 3
    if ver == 1 or ((b[i + 1] >> 1) & 3) != 1:      # reserved version, not layer III
        return 0
    bri, sri, pad = b[i + 2] >> 4, (b[i + 2] >> 2) & 3, (b[i + 2] >> 1) & 1
    if bri in (0, 15) or sri == 3:
        return 0
    br, sr = BITRATES[ver][bri] * 1000, RATES[ver][sri]
    return (144 if ver == 3 else 72) * br // sr + pad


def find_files(data, min_frames=4):
    """MP3 files: optional ID3v2 tag + a chain of consecutive layer-III frames. Returns [(start, length)]."""
    import re
    starts = sorted(set(m.start() for m in re.finditer(rb"ID3[\x02-\x04]", data)) |
                    set(m.start() for m in re.finditer(rb"\xff[\xe2\xe3\xea\xeb\xf2\xf3\xfa\xfb][\x10-\xeb]", data)))
    files, n, end = [], len(data), 0
    for start in starts:
        if start < end:
            continue
        j = start
        if data[start:start + 3] == b"ID3":
            size = (data[start + 6] << 21) | (data[start + 7] << 14) | (data[start + 8] << 7) | data[start + 9]
            j = start + 10 + size
        frames = 0
        while True:
            fl = frame_len(data, j)
            if fl == 0 and frames:
                # some encoders' leading Info / Xing frame is a byte off its header's length (Seishun Quiz):
                # resync when a header that starts a chain sits within 2 bytes
                for d in (-1, 1, -2, 2):
                    k = j + d
                    if k > start and frame_len(data, k) and frame_len(data, k + frame_len(data, k)):
                        j, fl = k, frame_len(data, k)
                        break
            if fl == 0 or j + fl > n:
                break
            j += fl
            frames += 1
        if frames >= min_frames:
            files.append((start, j - start))
            end = j
    return files


def decode(mp3):
    """MP3 bytes -> 16-bit stereo PCM at 44.1 kHz."""
    try:
        p = subprocess.run(["ffmpeg", "-v", "error", "-i", "pipe:0", "-f", "s16le", "-ac", "2", "-ar", str(RATE),
                            "pipe:1"], input=mp3, capture_output=True, check=True)
        return p.stdout
    except FileNotFoundError:
        import av                                   # pip install av
        out = bytearray()
        with av.open(io.BytesIO(mp3), format="mp3") as c:
            rs = av.AudioResampler(format="s16", layout="stereo", rate=RATE)
            for fr in c.decode(audio=0):
                for r in rs.resample(fr):
                    out += bytes(r.planes[0])[:r.samples * 4]
            for r in rs.resample(None):
                out += bytes(r.planes[0])[:r.samples * 4]
        return bytes(out)


def tone(n, seconds=0.25):
    """Test tone for track n: a square wave whose pitch steps with n (left), 1000 + the track number as DC (right)."""
    half = 25 + 5 * (n % 64)
    return b"".join(struct.pack("<hh", 4000 if (i // half) & 1 else -4000, 1000 + n) for i in range(int(RATE * seconds)))


def main():
    args = [a for a in sys.argv[1:] if a != "--test-tones"]
    tones = len(args) != len(sys.argv) - 1
    if len(args) < 2 or args[1] not in GAMES:
        sys.exit(__doc__)
    romdir, game = args[0], args[1]
    out = args[2] if len(args) > 2 else game + ".p3a"
    with zipfile.ZipFile(os.path.join(romdir, game + ".zip")) as zf:
        data = plain_nand(zf, game)
    files = find_files(data)
    print(f"{game}: {len(data) >> 20} MB of ROM data, {len(files)} MP3 files")
    entries, pcm, seen = [], bytearray(), {}
    head = 0x20 + 32 * len(files)
    head = (head + 1023) & ~1023
    for n, (s, l) in enumerate(files):
        mp3 = data[s:s + l]
        c0 = zlib.crc32(mp3[:64])
        c1 = zlib.crc32(mp3[0x2000:0x2040]) if l >= 0x2040 else 0
        c2 = zlib.crc32(mp3[0x10000:0x10040]) if l >= 0x10040 else 0
        if mp3 in seen:                             # identical file stored twice: share the audio
            start, frames = seen[mp3]
        else:
            p = tone(n) if tones else decode(mp3)
            start, frames = (head + len(pcm)) >> 10, len(p) // 4
            pcm += p + bytes((-len(p)) % 1024)
            seen[mp3] = (start, frames)
        entries.append(struct.pack("<IIIIII", l, c0, c1, c2, start, frames) + bytes(8))
        print(f"  {n:3d}  ROM {s:08X}  {l:8d} bytes  {frames / RATE:7.2f} s")
    with open(out, "wb") as f:
        hdr = b"NS10P3A1" + struct.pack("<IIII", len(entries), RATE, 2, 0) + b"\0" * 8
        f.write(hdr + b"".join(entries))
        f.write(b"\0" * (head - f.tell()))
        f.write(pcm)
    print(f"wrote {out} ({(head + len(pcm)) >> 20} MB)")


if __name__ == "__main__":
    main()
