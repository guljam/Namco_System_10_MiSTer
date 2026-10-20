#!/usr/bin/env python3
"""audio.txt (one "left right" signed 16-bit line per 88.2 kHz C352 sample) -> WAV.

  audio2wav.py build/audio.txt out.wav
"""
import sys, wave, struct
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
with wave.open(sys.argv[2], "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(88200)
    w.writeframes(b"".join(struct.pack("<hh", int(a), int(b)) for a, b in rows))
print(len(rows), "samples,", len(rows) / 88200.0, "s")
