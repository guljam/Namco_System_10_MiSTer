# Namco System 10 for MiSTer

A MiSTer FPGA core for Namco's **System 10** arcade board (2000-2007), the PlayStation-based platform
behind **Mr. Driller 2**, **Mr. Driller G**, Point Blank 3, Gamshara, the Taiko no Tatsujin series and
many more. One core (`Namco_S10`) runs the board; each game has its own MRA.

I created this core because I wanted to play these games on my MiSTer FPGA. I am posting it here and open
sourcing it for everyone to enjoy and give feedback/make improvements. This core was created with the
assistance of AI tooling.

**Status: in development.** The first supported games are Mr. Driller 2 and Mr. Driller G. The core is
built so that the rest of the System 10 library can be added game by game.

## Quick start

1. Copy the core from [`Releases/`](Releases/) (`Namco_S10_YYYYMMDD.rbf`) to **`/media/fat/_Arcade/cores/`**.
2. Copy the MRA files from [`MRA/`](MRA/) to **`/media/fat/_Arcade/`**. For the alternative sets, copy the
   `_<Game>` folders from [`MRA/_alternatives/`](MRA/_alternatives/) to **`/media/fat/_Arcade/_alternatives/`**.
3. Put the MAME 0.289 ROM zips in **`/media/fat/games/mame/`** (set names below).
4. Load the game from the **Arcade** menu.

ROMs are not included. You must supply your own.

## Supported games

| Game | MAME set | Year | ROM board | Status |
| --- | --- | --- | --- | --- |
| Mr. Driller 2 (World, DR22 Ver.A) | `mrdrilr2` | 2000 | MEM(M) | In testing |
| Mr. Driller G (Japan, DRG1 Ver.A) | `mrdrilrg` | 2001 | MEM(N) | In testing |

### Alternatives

| Game | MAME set | Parent | Status |
| --- | --- | --- | --- |
| Mr. Driller 2 (Japan, DR21 Ver.A) | `mrdrilr2j` | Mr. Driller 2 | In testing |
| Mr. Driller 2 (US, DR23 Ver.A) | `mrdrilr2u` | Mr. Driller 2 | In testing |

## Controls

| MiSTer button | Default pad button | Function |
| --- | --- | --- |
| Drill (Button 1) | A | Drill |
| Start | Start | Start |
| Coin | Select | Coin |
| Test | L | Test switch (slide: press once to enter the service menu, again to leave) |
| Service | R | Service credit |
| Pause | R3 | Pause |

## OSD

* **Scandoubler Fx**, **Orientation** (all System 10 games are horizontal), **Video & Audio**, **CRT Adjust**
  for the native 15 kHz output.
* **Hardware**: the board's eight DIP switches (DSW1) and Pause when OSD open.

## Saves

System 10 keeps operator settings, high scores and bookkeeping on the ROM board itself (in the program flash
of MEM(M) boards, in block 1 of the first NAND of MEM(N) boards). The core saves that area to the SD card as
a `.nvm` file in `/media/fat/config/nvram/` shortly after the game writes it.

## About the hardware

System 10 is a PSOne on an arcade board: a CXD8606 CPU (R3000A + GTE) at 33.87 MHz, a CXD8561CQ GPU with
2 MB VRAM, the PlayStation SPU with 512 KB of sound RAM and 4 MB of main RAM. There is no boot ROM on the main
board: everything, including the boot code, comes from the **MEM** ROM board, whose KEYCUS CPLD descrambles the
ROM data and decrypts the game program. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## About the core

* Built on Robert Peip's [PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) (CPU, GTE, GPU, SPU, DMA),
  through XelaNotPu's System 11 port and the author's Namco System 12 (Tenkomori Shooting) and Konami GV cores.
* The MEM board (MEM(M) flash + mask ROMs, MEM(N) NAND), the KEYCUS descrambler and both decrypters, and the
  main-board I/O are new and follow MAME. The decrypters reproduce MAME on every word the games read.
* ROM images are loaded straight into DDR3 (fast loading), so even the largest System 10 games fit.

## License

GPL-3.0-or-later for the combined work (see [LICENSE](LICENSE), [COPYING.GPL2](COPYING.GPL2) and
[COPYING.GPL3](COPYING.GPL3)). The MiSTer framework in `sys/` keeps its own notices.

No ROMs or other game data are included in this repository. "Namco" and "System 10" are trademarks of
their owners; this project is not affiliated with them.
