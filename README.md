# Namco System 10 for MiSTer

A MiSTer FPGA core for Namco's **System 10** arcade board (2000-2007), the PlayStation-based platform
behind **Mr. Driller 2**, **Mr. Driller G**, **Point Blank 3**, Gamshara, the Taiko no Tatsujin series and
many more. One core (`Namco_S10`) runs the board; each game has its own MRA.

I created this core because I wanted to play these games on my MiSTer FPGA. I am posting it here and open
sourcing it for everyone to enjoy and give feedback/make improvements. This core was created with the
assistance of AI tooling.

**Status: beta.** Mr. Driller 2 and Mr. Driller G are playable. Point Blank 3 is in testing. The core is
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
| Point Blank 3 (World, GNN2 Ver.A) | `ptblank3` | 2000 | MEM(N) + EXIO(G) light-gun board | 240p | In testing |

### Alternatives

| Game | MAME set | Parent | Status |
| --- | --- | --- | --- |
| Mr. Driller 2 (Japan, DR21 Ver.A) | `mrdrilr2j` | Mr. Driller 2 | Playable |
| Mr. Driller 2 (US, DR23 Ver.A) | `mrdrilr2u` | Mr. Driller 2 | Playable |
| Gunbalina (Japan, GNN1 Ver.A) | `gunbalina` | Point Blank 3 | In testing (also needs `ptblank3.zip`) |

### Video modes

The games choose their own resolution, exactly as on the PCB. Mr. Driller 2 and Point Blank 3 run at 240p.
Mr. Driller G runs its game screens at 640x480 interlaced (480i) by default; its service menu has an option
to switch the game to 240p.

## Controls

| MiSTer button | Default pad button | Mr. Driller | Point Blank 3 |
| --- | --- | --- | --- |
| Button 1 | A | Drill | Trigger |
| Start | Start | Start | Start |
| Coin | Select | Coin | Coin |
| Test | L | Test switch (slide: press once to enter the service menu, again to leave) | same |
| Service | R | Service credit | same |
| Pause | R3 | Pause | Pause |

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
* **Light Gun** (gun games only): see above.
* **Hardware**: the board's eight DIP switches (DSW1) and Pause when OSD open.

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
* **Light guns.** MAME aims with a mouse or stick-driven crosshair. The core takes real light guns (GunCon 2 on
  a CRT, Sinden, Gun4IR) through MiSTer's gun support.

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
