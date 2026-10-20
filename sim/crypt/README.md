# Decrypter benches (`rtl/s10_crypt_t1.sv`, `rtl/s10_crypt_t2.sv`)

The ROM-board stream decrypters are checked against MAME 0.289 on real game traffic:
every word MAME's decrypter returned during the boot-time program load is replayed through the
Python models (`scripts/ns10crypt.py`) and the RTL, and must match bit for bit.

| Game     | Board  | Decrypter | Activations (iv)        | Words  |
|----------|--------|-----------|-------------------------|--------|
| mrdrilr2 | MEM(M) | type 1    | 3, F, 5, 4, B, D, 9     | 1634304 |
| mrdrilrg | MEM(N) | type 2    | 3, F, 5, 4, B, D, 9     | 1687552 |

## 1. Capture (MAME + Lua, only needed to regenerate)

Scripts live in `local/mame/crypt/` (git-ignored, like the rest of `local/`):

* `cap_mrdrilrg.lua` – logs every write to the crypto switch (0x1F300000/0x1F380000) and the NAND
  registers 0x1F410000-0x1F47FFFF (cmd, column/row/page address, chip select, ctrl), and the
  returned word of every 16-bit read of 0x1F450000. Default 160 frames (`CAP_FRAMES`).
* `cap_mrdrilr2.lua` – logs crypto switch and bank (0x1FB40000-0x1FB5FFFF) writes/reads, and
  every read of 0x1F400000-0x1F5FFFFF while the decrypter is active (offset, data, lane mask).
  Default 120 frames.

Both write a compact binary log `local/mame/crypt/<game>_cap.bin` (record format in the script
header). From a bash shell:

```sh
cd /c/Users/klest/Downloads/mame
for g in mrdrilrg mrdrilr2; do
  ./mame.exe $g -rompath roms -autoboot_script \
    C:/Users/klest/Documents/Codex/Namco_System_10_MiSTer/local/mame/crypt/cap_$g.lua \
    -nothrottle -video none -sound none -skip_gameinfo -window </dev/null
done
```

(~1 minute each; the first decryption session ends at frame ~83 / ~126.)

## 2. Reconstruct cipherwords, check the Python models, write vectors

```sh
python sim/crypt/capture.py [--rompath C:/Users/klest/Downloads/mame/roms]
```

* mrdrilrg: replays the NAND command/address/chip-select writes against the raw images in
  `mrdrilrg.zip` (page 0x210 bytes; cmd 0x00/0x01/0x50 = area A/B/C; sequential read across pages;
  0x1F460000 chip select ignored while ctrl bit 2 is set) to get the raw byte pair behind every
  read, cipher = (byte0 << 8) | byte1. The reconstruction is self-checked on all ~1.08M reads made
  while the decrypter is off (MAME returns raw / unscrambled(raw ^ 0xAAAA) there).
* mrdrilr2: cipher = little-endian word of `dr22vera.1a` at 0x100000*bank + word offset; each
  16-bit lane of a bus access is one decrypter call (low lane first).
* Checks `Type1`, `Type2Mame` (literal port of the mrdrilrg lambda) and `Type2Generic`
  (Ac/Ap/Bc/Bp/outMask form) against MAME's returned words, then writes `vec_<game>.hex`
  (large, git-ignored) and `params_mrdrilrg.hex` (type-2 parameter vectors in RTL layout).

Vector line = 36-bit hex: `[35:32]` op (0 word: `[31:16]` cipher, `[15:0]` expected plain;
1 activate: `[3:0]` iv; 2 deactivate); first line is a header with the line count.

## 3. RTL benches

```sh
sh sim/crypt/run.sh       # ModelSim (vlog/vsim on PATH, ModelSim-Intel 10.5b ASE works)
```

`tb_crypt.sv` (parameter `TYPE` = 1 or 2) streams the vectors, checks `plain` combinationally in
the cycle where `word_valid` is high, and inserts an idle cycle (word_valid = 0, garbage cipher)
before every 1000th word. Expected output:

```
# RESULT TYPE1 vec_mrdrilr2.hex: activations 7, words 1634304, pass 1634304, fail 0, idle cycles 1634 -> PASS
# RESULT TYPE2 vec_mrdrilrg.hex: activations 7, words 1687552, pass 1687552, fail 0, idle cycles 1687 -> PASS
ALL PASS
```

Lint (MSYS2 UCRT64 shell): `verilator --lint-only -Wall rtl/s10_crypt_t1.sv` / `... s10_crypt_t2.sv`
(clean). The MSYS2 Verilator 5.050 install currently fails to link `--binary` builds, so the
benches use ModelSim.
