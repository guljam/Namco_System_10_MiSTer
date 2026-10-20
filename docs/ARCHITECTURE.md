# Namco System 10 for MiSTer: architecture

Status: implemented (first hardware test pending), 2026-10-19. First targets **Mr. Driller 2** (`mrdrilr2`,
`mrdrilr2j`, `mrdrilr2u`) and **Mr. Driller G** (`mrdrilrg`). The design is table-driven so the
rest of the System 10 library can be added by MRA data plus small, isolated board modules.

Reference: MAME 0.289 `src/mame/namco/namcos10.cpp`, `ns10crypt.cpp`, `video/psx.cpp`.

## 1. What System 10 is

System 10 is a PSOne on an arcade board. There are no custom Namco chips on the main board: the
game-specific hardware is on the **MEM** ROM board (flash or NAND, a KEYCUS CPLD that descrambles and
decrypts, sometimes an SRAM) and on optional expansion boards.

| Part | System 10 | System 12 (Tenkomori core) |
| --- | --- | --- |
| CPU | CXD8606BQ/CQ (R3000A + GTE) at 33.8688 MHz (101.4912 / 3), **PlayStation speed** | CXD8661R at 50 MHz (core needs the System 12 cache/turbo) |
| GPU | CXD8561CQ, 2 MB SGRAM, MAME `gputype 2` | CXD8654Q, 2 MB, `gputype 2` (**identical model**) |
| Main RAM | 4 MB EDO | 4 MB |
| Sound | **PlayStation SPU** (CXD2938Q / CXD2941R), 512 KB sound RAM | C352 driven by an H8/3002 |
| Sub CPU | none | H8/3002 + shared RAM |
| Boot ROM | **none on the main board**: the BIOS comes from the MEM board (descrambled) | 4 MB program ROM |
| Save data | in the MEM board flash (MEM(M) 0x40000) or NAND0 block 1 (MEM(N)) | AT28C16 EEPROM |
| ROM storage | MEM(M): 8 MB program flash + up to 14 x 16 MB mask ROM, banked 2 MB window. MEM(N): 1-16 K9F2808U0B/K9F5608U0D NANDs (16.5 MB each incl. spare) | 28 MB banked ROM + ROM DMA |
| Protection | KEYCUS: 16-bit bitswap (+ XOR) of all ROM data; a stream decrypter (type 1 MEM(M), type 2 MEM(N)) switched on per program segment | none relevant |
| I/O | CPLD: SYSTEM (DSW), IN1 (32-bit JAMMA), I2C bit-bang, 100 Hz IRQ10 "I/O" interrupt with status/ack, EXIO ident, watchdog | Namco I/O via H8 |
| Video | 256-640 wide, 240p or **480i** (Driller G is 512x480i; the operator menu can switch to non-interlaced) | 320x240 |

## 2. What carries over from the Tenkomori core

Taken as the base repository layout (Quartus 17.0 project, `sys/`, build scripts, MRA tooling):

* **PSX core** (`rtl/`, PSX_MiSTer via XelaNotPu's System 11 port): CPU, GTE, MDEC, DMA, timers, IRQ,
  the 2 MB-VRAM type-2 GPU with our sprite-flip / texture-page fixes and the data-cache coherence fix.
  System 10 runs at PlayStation speed, so the **System 12 turbo/cache is switched off** (exact PS1 timing).
* **Video**: video_mixer path, Scandoubler Fx, the fixed blanking window, CRT Adjust (H-Size,
  H-Position, V-Shift), the loading-screen sync, `tkm_screen_rotate` + `ddram_rotate_arb` (rotation,
  512-entry FIFO, registered psx hold). All System 10 games are ROT0, so the default is Horizontal; the
  owner's standard Orientation menu stays.
* **DDR3 fast ROM loading** (`tkm_fastload.sv` concepts, MRA `address=`), romtool-style MRA
  generator/checker, the NVC/Verilator bench infrastructure, the MAME Lua tracing tools.
* Savestate-reset fix (main RAM not zeroed by the savestate machinery).

Removed: H8/3002 CPU and peripherals, C352, System 12 sub board / shared RAM / ROM DMA window,
AT28C16 EEPROM, RTC4543, System 12 CPU-speed option.

Taken from the owner's **Konami GV core** (same PSX_MiSTer family): the **SPU** (`spu.vhd`,
`spu_ram.vhd`, `spu_gauss.vhd`) and its DDR3 client in `psx_top`'s arbiter (Tenkomori's `psx_top`
still has the arbiter and the `memSPU_*` port; only the SPU entity was stubbed), plus GV's pattern for a
DDR3-backed flash board client.

## 3. New hardware to build

### 3.1 System 10 I/O (`rtl/s10_io.vhd`) - generic, all games

At 0x1FBA0000 (KSEG mirrors 0x9FBA/0xBFBA as for all PS1 I/O):

| Address | R/W | Function |
| --- | --- | --- |
| 1FBA0000 | R | SYSTEM: DSW1 bits 7-0 (active low), bit 10 JVS sense (1) |
| 1FBA0002 | R/W | EXIO ident: write resets a bit shifter; reads shift out the ident byte (0xFF = no EXIO), 2 bits per read |
| 1FBA0004 | R | IN1 (32 bit, active low): P1/P2 joystick + 6 buttons + start, coin 1/2, test (toggle), service |
| 1FBA0008 / 0A | R/W | I2C clock / data bit-bang; device ACKs every byte (MAME model) |
| 1FBA0012-19 | W | interrupt acknowledge (one register per bit) |
| 1FBA001A | R | interrupt status: bit 3 = I/O update (100 Hz), bit 2 = CD-ROM, bit 1 = EXIO |
| 1FB60000 | R/W | watchdog (ignored) |
| 1FB20000 | W | ignored |
| 1FBC0000-F, 1FBF0000 | R/W | ATA CD-ROM (Taiko only; reads 1 = "no drive" placeholder) |

A 100 Hz timer sets status bit 3 and pulses **IRQ10** (PS1 "lightpen/PIO" input), as MAME does.

### 3.2 MEM board controller (`rtl/s10_mem.sv`) - one module, three personalities

Selected per game by a **board record** in the MRA (§5). All ROM-board images live in **DDR3**; only the
descrambled BIOS goes to SDRAM.

**BIOS.** There is no boot ROM: MAME copies a descrambled part of the first flash/NAND into
0x1FC00000. The core does the same at load time: the MRA streams that part (ioctl index 0) and the loader
unscrambles each 16-bit word (`bitswap16(w ^ xor)`, per-game permutation) and writes it to the SDRAM BIOS
area (4 MB, 0x400000, where the System 12 program ROM was).
* MEM(M): flash bytes [0, 0x62000) -> BIOS [0, 0x62000), `bitswap16(w ^ 0xAAAA)`.
* MEM(N): NAND0 pages 0x40-0x11F -> BIOS [0, 0x1C000); pages 0x120-0x201F -> BIOS [0x20000, 0x3FE000).
  The loader drops the 16 spare bytes of every 0x210-byte page and big-endian-swaps each word.
* Unloaded BIOS addresses read 0x55555555 (MAME fills the region with 0x55).

**MEM(M)** (Mr. Driller 2, KEYCUS KC001A):
* 0x1F400000-0x1F5FFFFF: 2 MB window into the current bank (bank = word address bits written at
  0x1FB40000-0x1FB5FFFF; banks 0x00-0x0F = program flash in 2 MB steps, 0x10-0x1F = data mask ROMs).
* Read path (MAME semantics): after a bank write to a flash bank the window reads the flash **raw**
  through the Intel 28F640J5 state machine (read array / status / ID); after a read of 0x1FB40000, or for a
  data bank, it reads the ROM image **descrambled** (`bitswap16(w ^ 0xAAAA)` for flash banks), or through
  the **type-1 decrypter** when it is active.
* 0x1F300000: crypto switch: bit 15 = activate with IV = bits 3-0, else deactivate.
* Writes to the window go to the 28F640J5 command interface (program word, block erase, clear status,
  read status/ID). The settings live at flash 0x40000; the flash image in DDR3 is written directly and the
  settings block is the MRA `<nvram>`.

**MEM(N)** (Mr. Driller G, KEYCUS KC007A, and most of the library):
* 0x1F400000 R: NAND ready/busy of the selected chip. 0x1F410000 W command, 0x1F420000 / 430000 /
  440000 W address column / row / page, 0x1F450000 R/W data (16 bit = two NAND bytes, big-endian),
  0x1F460000 W chip select (ignored while ctrl bit 2 is set), 0x1F470000 R/W control register,
  0x1F300000 and 0x1F380000 W crypto switch, 0x1FE40000 / 0x1FE48000 ignored.
* K9F2808U0B/K9F5608U0D command subset: 0x00/0x01/0x50 read (area A/B/C), 0x90 ID, 0x70 status,
  0xFF reset, 0x80/0x10 program, 0x60/0xD0 block erase. A page read fetches the 0x210-byte page from DDR3
  into a page buffer (one 66-beat burst), so each data-register read is answered from block RAM.
* Data words read from NAND0 blocks 0-1 are returned as stored; all others through the per-game
  **descrambler** (`bitswap16(w ^ xor)`, xor 0xAAAA) or, while active, the **type-2 decrypter**.
* DMA channel 5 reads pull from the data register (MAME `pio_dma_read`; Driller G does not use it).
* 0x1F500000-0x1F5FFFFF: the MEM(N) SRAM that holds the bad-block remap table (128 KB on the board,
  1 MB mirror in MAME) -> SDRAM.
* Save data: NAND0 block 1 (0x4200 bytes at 0x4200, incl. spare) is the MRA `<nvram>`.

**MEM(P3)** (MP3 board: Golgo 13, Gips Nice Tsukkomi, Colorful High School) and **Taito MEM/IO**
(Ippo 1/2): later; they add an MP3 decoder + TMP95C061 or a different XOR. The MEM(N) NAND path is
reused.

### 3.3 Decrypters (`rtl/s10_crypt_t1.sv`, `rtl/s10_crypt_t2.sv`)

* **Type 1** (only `mrdrilr2`): fixed logic from `ns10crypt.cpp`: per word a 16-bit bitswap of the
  cipherword XOR a mask computed from the previous cipherword, plainword and an 8-bit counter, with an
  IV S-box. Implemented as is.
* **Type 2** (all MEM(N) games): mask = for each output bit j, parity(eMask[j] & C) ^ parity(dMask[j] & P),
  where C/P are the last four cipher/plain words (64 bits), XOR xMask, XOR one **nonlinear term**. Every
  known game's nonlinear term has the form `(A_lin & B_lin) * outMask`, where A and B are parities of
  64-bit masks over C, P or C^P. Generic RTL with per-game parameters from the board record:
  eMask[16], dMask[16] (64 bit), xMask, IV table [16] (64 bit), A/B masks (C and P, 64 bit each), outMask.
  Driller G: A = parity((C^P) & 0x120100400000), B = parity((C^P) & 0x11800020000), outMask 0x0011.
  One word per clock, combinational parity trees (~2k mask flip-flops).
* Games whose nonlinear bits come from a table (`ns10_type2_decrypter_nonlinear_device`) get a
  table-RAM variant later.

### 3.4 DDR3 map

| Range | Use |
| --- | --- |
| 0x20000000-0x21FFFFFF | ascal scaler (sys) |
| 0x24000000-0x257FFFFF | rotation frame buffers (3 x 8 MB) |
| 0x30000000-0x301FFFFF | PSX VRAM (2 MB) |
| 0x30300000-0x3037FFFF | SPU RAM (psx_top arbiter client 3) |
| **0x32000000-0x3DFFFFFF** | **MEM board images** (192 MB: flash/mask ROMs or up to 11 NANDs at 0x1080000 each); written by Main_MiSTer through MRA `address=` (fast loading), or by the core from the ioctl stream with older firmware |
| 0x3E000000- | PSX savestates (unused) |

DDR3 masters: `ddram_rotate_arb` (rotation writes + the psx master). Inside `psx_top`'s arbiter the
psx master serves VRAM, SPU and the new **MEM board client** (page fetches, MEM(M) line reads with a
small read cache, program/erase writes, nvram transfer).

### 3.5 SDRAM map (64 MB module)

| Range | Use |
| --- | --- |
| 0x0000000-0x03FFFFF | main RAM 4 MB |
| 0x0400000-0x07FFFFF | BIOS 4 MB (descrambled at load) |
| 0x0800000-0x08FFFFF | MEM(N) SRAM (remap table) |

A 32 MB SDRAM module is enough; the ROM images are in DDR3.

## 4. Loading

MRA indexes:

| index | content | path |
| --- | --- | --- |
| 0 | BIOS part of flash / NAND0 | ioctl -> loader unscrambles -> SDRAM BIOS |
| 1 | board record (64-byte header + crypto parameters) | ioctl -> registers / small BRAM |
| 2 | MEM(M) flash, or all NANDs concatenated | MRA `address=0x32000000` -> DDR3 (fallback: ioctl -> DDR3 writer) |
| 3 | MEM(M) data mask ROMs | MRA `address=0x32800000` -> DDR3 |
| 9 | nvram: a window of the DDR3 image (MEM(M) flash 0x40000, 64 KB; MEM(N) NAND0 block 1, 0x4200 bytes) | load: written into DDR3 by the loader while the PSX is in reset; save: uploaded from DDR3 by `s10_mem` |

The core holds the PSX in reset until all indexes have arrived, then releases it (the Tenkomori
reset chain).

## 5. Board record (MRA index 1)

Little-endian, written by `scripts/romtool.py` from a per-game table that mirrors MAME:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | magic "S10B", version |
| 4 | 1 | board type: 0 MEM(M), 1 MEM(N), 2 MEM(P3), 3 Taito |
| 5 | 1 | decrypter: 0 none, 1 type 1, 2 type 2, 3 type 2 + nonlinear table |
| 6 | 1 | NAND count / data ROM count |
| 7 | 1 | NAND type (0 K9F2808U0B, 1 K9F5608U0D) |
| 8 | 2 | data XOR (0xAAAA) |
| 10 | 16 | unscramble permutation: source bit for each output bit 15..0 |
| 26 | 1 | EXIO ident (0xFF none) |
| 32 | 128 | type 2: eMask[16] (8 bytes each) |
| 160 | 128 | dMask[16] |
| 288 | 2 | xMask |
| 296 | 128 | IV table [16] |
| 424 | 32 | nonlinear A_c, A_p, B_c, B_p |
| 456 | 2 | nonlinear output mask |

## 6. Verification

Status (2026-10-19):
* Decrypters: 100% of MAME's words (mrdrilr2 1,634,304, mrdrilrg 1,687,552; `sim/crypt`, ModelSim).
* BIOS descramble (`s10tool.py check`): byte-identical to MAME's `maincpu:rom` for all sets.
* MEM board (`sim/board`, NVC): every board access MAME makes in the first 4 s replayed into `s10_mem`,
  each read compared (mrdrilrg: 2.86M accesses incl. all decrypted words).
* System (`sim/system/run10.sh`, NVC mixed VHDL/SystemVerilog): BIOS boots into the PS1 kernel with
  the same GP1 sequence as MAME.

Simulator note: NVC 1.23 mis-evaluates XOR reductions of vectors wider than 64 bits and does not
parse `'0` fills; the RTL avoids both.

Plan:

1. **Decrypters**: MAME Lua captures (crypto switch writes + every cipher/plain word pair the game reads)
   -> bench replays them through `s10_crypt_t1/t2`; 100% match required.
2. **MEM board**: bench with a DDR3 model replays MAME's register traffic (bank/NAND command sequences,
   CPU reads) and compares every returned word.
3. **Loader**: the BIOS image in SDRAM equals MAME's `maincpu:rom` after `driver_init` (dumped by Lua).
4. **System**: full-core simulation (NVC + DDR3/SDRAM models) from reset: boot PC path, GP1 mode
   writes and frames compared with MAME (`local/mame/boot.lua` logs and snapshots).
5. **Hardware**: owner test of the RBF + MRAs (attract loop, coin/start/play, operator menu, save).

## 7. Implementation order

1. Repository scaffold from Tenkomori; strip System 12; restore the SPU; System 10 I/O; PS1 timing.
2. Loader + board record + BIOS descramble; romtool for the two games (MRAs, check vs MAME).
3. MEM(N) NAND controller + type-2 decrypter (Driller G), benches vs MAME captures.
4. MEM(M) flash/mask controller + type-1 decrypter (Driller 2), benches.
5. Full-system simulation boot of both games vs MAME.
6. Builds (3 seeds in parallel), RBF + MRAs for the hardware test.
7. Later: remaining MEM(N) games (tables only), EXIO (analog, light guns), MGEXIO medal games,
   MEM(P3) MP3 board, Taito MEM/IO, Taiko CD-ROM.
