# Namco System 10 for MiSTer

A MiSTer FPGA core for Namco's **System 10** arcade board (2000-2007), the PlayStation-based platform
behind **Mr. Driller 2**, **Mr. Driller G**, **Point Blank 3**, **Gamshara**, the Taiko no Tatsujin series and
many more. One core (`Namco_S10`) runs the board; each game has its own MRA.

I created this core because I wanted to play these games on my MiSTer FPGA. I am posting it here and open
sourcing it for everyone to enjoy and give feedback/make improvements. This core was created with the
assistance of AI tooling.

**Status: beta.** Mr. Driller 2, Mr. Driller G and Point Blank 3 (with GunCon 2) are playable. Gamshara is in testing. The core is
built so that the rest of the System 10 library can be added game by game.

## Quick start

1. Copy the core from [`Releases/`](Releases/) (`Namco_S10_YYYYMMDD.rbf`) to **`/media/fat/_Arcade/cores/`**.
2. Copy the MRA files from [`MRA/`](MRA/) to **`/media/fat/_Arcade/`**. For the alternative sets, copy the
   `_<Game>` folders from [`MRA/_alternatives/`](MRA/_alternatives/) to **`/media/fat/_Arcade/_alternatives/`**.
3. Put the MAME 0.289 ROM zips in **`/media/fat/games/mame/`** (set names below).
4. Load the game from the **Arcade** menu.

ROMs are not included. You must supply your own.

## Supported games

| Game | MAME set | Year | ROM board | Video | Status |
| --- | --- | --- | --- | --- | --- |
| Mr. Driller 2 (World, DR22 Ver.A) | `mrdrilr2` | 2000 | MEM(M) | 240p | Playable |
| Mr. Driller G (Japan, DRG1 Ver.A) | `mrdrilrg` | 2001 | MEM(N) | 480i (240p in the service menu) | Playable |
| Point Blank 3 (World, GNN2 Ver.A) | `ptblank3` | 2000 | MEM(N) + EXIO(G) light-gun board | 240p | Playable |
| Gamshara (20020912A, 10021 Ver.A) | `gamshara` | 2002 | MEM(N) | 480i | In testing |
| Kono e Tako (10021 Ver.A) | `konotako` | 2003 | MEM(N) | 480i | In testing |

### Untested games

These need no hardware beyond what the core already has, and have MRAs, but have not been run yet (their ROM
sets were not available while the core was developed). The decrypter parameters come straight from MAME's
driver and were checked against MAME's formulas; reports are welcome.

| Game | MAME set | Year |
| --- | --- | --- |
| GekiToride-Jong Space (10011 Ver.A) | `gjspace` | 2001 |
| Kotoba no Puzzle Mojipittan (Japan, KPM1 Ver.A) | `knpuzzle` | 2001 |
| Uchuu Daisakusen: Chocovader Contactee (Japan, CVC1 Ver.A) | `chocovdr` | 2002 |
| Panikuru Panekuru (Japan, PPA1 Ver.A) | `panikuru` | 2002 |
| Star Trigon (Japan, STT1 Ver.A) | `startrgn` | 2002 |

The other System 10 games need hardware the core does not have yet: the EXIO board's microcontroller and analog
inputs (GAHAHA Ippatsudou 1/2, Taiko no Tatsujin), the EXFINAL board (Medal no Tatsujin), MGEXIO (medal games),
MEM(P3) with its MP3 decoder (Golgo 13, Nice Tsukkomi, Seishun Quiz) and Taito's MEM(IO) (Hajime no Ippo).

### Alternatives

| Game | MAME set | Parent | Status |
| --- | --- | --- | --- |
| Mr. Driller 2 (Japan, DR21 Ver.A) | `mrdrilr2j` | Mr. Driller 2 | Playable |
| Mr. Driller 2 (US, DR23 Ver.A) | `mrdrilr2u` | Mr. Driller 2 | Playable |
| Gunbalina (Japan, GNN1 Ver.A) | `gunbalina` | Point Blank 3 | In testing (also needs `ptblank3.zip`) |
| Gamshara (20020716A, 10021 Ver.A) | `gamsharao` | Gamshara | In testing (also needs `gamshara.zip`) |

### Video modes

The games choose their own resolution, exactly as on the PCB. Mr. Driller 2 and Point Blank 3 run at 240p.
Mr. Driller G runs its game screens at 640x480 interlaced (480i) by default; its service menu has an option
to switch the game to 240p. Gamshara and Kono e Tako run at 640x480 interlaced.

## Controls

| MiSTer button | Default pad button | Mr. Driller | Point Blank 3 | Gamshara |
| --- | --- | --- | --- | --- |
| Button 1 | A | Drill | Trigger | Button 1 |
| Button 2 | B | | | Button 2 |
| Button 3 | X | | | Button 3 |
| Start | Start | Start | Start | Start |
| Coin | Select | Coin | Coin | Coin |
| Test | L | Test switch (slide: press once to enter the service menu, again to leave) | same | same |
| Service | R | Service credit | same | same |
| Pause | R3 | Pause | Pause | Pause |

Mr. Driller uses a 4-way joystick, Gamshara an 8-way joystick.

### Light guns (Point Blank 3)

Aim comes from MiSTer's standard light-gun input, so a **GunCon 2** (on a 15 kHz CRT, calibrated for the
core with **F10** in the OSD), **Sinden**, **Gun4IR**, a Wiimote or a plain analog stick all work, one per
player. The trigger is button 1 of the same player. Player 1 can also aim with a mouse.

The **Light Gun** OSD page (shown only for gun games) has:

* **Gun aim P1**: Joystick (gun / analog stick) or Mouse.
* **Crosshair**: Off / On (a different colour per player).

The game also has its own gun calibration in its service menu (Test switch), as on the cabinet.

## OSD

* **Scandoubler Fx**, **Orientation** (all System 10 games are horizontal), **Video & Audio**, **CRT Adjust**
  for the native 15 kHz output.
* **DIP Switches**: the board's DIP switches (DSW1), named per game from MAME. Gamshara's **Region** selects
  World (English, the default) or Japan; Kono e Tako's selects Japan (*Kono e Tako*, the default) or Export
  (*Kono TaCO!*, the English Cristaltec release). The region is read at boot, so reset after changing it.
* **Light Gun** (gun games only): see above.
* **Hardware**: Pause when OSD open.

## Saves

System 10 keeps operator settings, high scores and bookkeeping on the ROM board itself (in the program flash
of MEM(M) boards, in block 1 of the first NAND of MEM(N) boards). The core saves that area to the SD card as
a `.nvm` file in `/media/fat/config/nvram/` shortly after the game writes it. On the very first boot the
games show **FIRST POWER ON** for a few seconds while they set up that area; this is normal.

## Differences from MAME

MAME is the reference for this core, and the core matches it everywhere that can be checked (decrypted ROM
data, board register traffic, boot sequence). In a few places the core goes beyond MAME 0.289:

* **Sound.** MAME flags every System 10 game as *imperfect sound*. This core plays sound through the
  PSX_MiSTer SPU, a hardware-level reimplementation of the PlayStation sound chip (the chip on the System 10
  main board), instead of MAME's SPU emulation.
* **Point Blank 3 / Gunbalina expansion board.** The real cabinets use the cut-down **EXIO(G)** board: gun
  logic only, no microcontroller (as MAME's own hardware notes describe). MAME emulates the full EXIO board
  instead, so in MAME the game detects a microcontroller and uploads a 20 KB program to a chip the cabinet does
  not have. The core reports an EXIO(G) board, and the game takes the path it takes on the cabinet (checked in
  the game code, and by running MAME with the EXIO(G) ident: same gameplay).
* **Mr. Driller 2 operator menu.** MAME lists "opening the operator menu sometimes can crash Mr. Driller 2" as a
  known issue. On the core it opens reliably (tested five times in a row on hardware, no crash).
* **Light guns.** MAME aims with a mouse or stick-driven crosshair. The core takes real light guns (GunCon 2 on
  a CRT, Sinden, Gun4IR) through MiSTer's gun support.

* **Gamshara region.** MAME's driver notes that it is unknown whether the later Gamshara set (20020912A) honours
  the World region setting like the earlier one. It does: with Region = World it runs in English (checked in
  MAME), so the core's MRA defaults to World.

MAME marks Point Blank 3 *unemulated protection*: part of the KEYCUS chip's decryption is not understood and is
replayed from a recorded bit table (`ptblank3_nonlinear`, part of the MAME set). The core does the same, so it
works with the MAME ROM set unchanged.

## About the hardware

System 10 is a PSOne on an arcade board: a CXD8606 CPU (R3000A + GTE) at 33.87 MHz, a CXD8561CQ GPU with
2 MB VRAM, the PlayStation SPU with 512 KB of sound RAM and 4 MB of main RAM. There is no boot ROM on the main
board: everything, including the boot code, comes from the **MEM** ROM board, whose KEYCUS CPLD descrambles the
ROM data and decrypts the game program. Some games add an **EXIO** expansion board (light guns, extra I/O).
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## About the core

* Built on Robert Peip's [PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) (CPU, GTE, GPU, SPU, MDEC, DMA),
  through XelaNotPu's System 11 port and the author's Namco System 12 (Tenkomori Shooting) and Konami GV cores.
* The MEM board (MEM(M) flash + mask ROMs, MEM(N) NAND), the KEYCUS descrambler and decrypters (type 1, type 2,
  type 2 with the nonlinear table), the main-board I/O and the EXIO(G) light-gun board are new and follow MAME.
  The decrypters reproduce MAME on every word the games read.
* ROM images are loaded straight into DDR3 (fast loading), so even the largest System 10 games fit.

## License

GPL-3.0-or-later for the combined work (see [LICENSE](LICENSE), [COPYING.GPL2](COPYING.GPL2) and
[COPYING.GPL3](COPYING.GPL3)). The MiSTer framework in `sys/` keeps its own notices.

No ROMs or other game data are included in this repository. "Namco" and "System 10" are trademarks of
their owners; this project is not affiliated with them.
