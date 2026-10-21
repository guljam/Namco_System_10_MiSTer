# Namco System 10 for MiSTer

A MiSTer FPGA core for Namco's **System 10** arcade board (2000-2007), the PlayStation-based platform
behind **Mr. Driller 2**, **Mr. Driller G**, **Point Blank 3**, **Gamshara**, **Taiko no Tatsujin** and
many more. One core (`Namco_S10`) runs the board; each game has its own MRA.

I created this core because I wanted to play these games on my MiSTer FPGA. I am posting it here and open
sourcing it for everyone to enjoy and give feedback/make improvements. This core was created with the
assistance of AI tooling.

**Status: beta.** Tested on hardware: Mr. Driller 2 and G, Point Blank 3 and Gunbalina (GunCon 2), Gamshara, Kono e
Tako, GekiToride-Jong Space, Mojipittan, Chocovader Contactee, GAHAHA Ippatsudou 1 / 2 and Taiko no Tatsujin 2.
In testing: Taiko no Tatsujin 3 / 4 / 5 / 6 / RT, Panikuru Panekuru (music), Star Trigon (does not start since test8,
being fixed). The core is built so that the rest of the System 10
library can be added game by game.

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
| Mr. Driller 2 (World, DR22 Ver.A) | `mrdrilr2` | 2000 | MEM(M) | 240p | Tested working |
| Mr. Driller G (Japan, DRG1 Ver.A) | `mrdrilrg` | 2001 | MEM(N) | 480i (240p in the service menu) | Tested working |
| Point Blank 3 (World, GNN2 Ver.A) | `ptblank3` | 2000 | MEM(N) + EXIO(G) light-gun board | 240p | Tested working (GunCon 2) |
| Gamshara (20020912A, 10021 Ver.A) | `gamshara` | 2002 | MEM(N) | 480i | Tested working (a few thin vertical lines in one attract scene) |
| Kono e Tako (10021 Ver.A) | `konotako` | 2003 | MEM(N) | 480i | Tested working |
| GekiToride-Jong Space (10011 Ver.A) | `gjspace` | 2001 | MEM(N) | | Tested working |
| Kotoba no Puzzle Mojipittan (Japan, KPM1 Ver.A) | `knpuzzle` | 2001 | MEM(N) | | Tested working |
| GAHAHA Ippatsudou (World, GID2 Ver.A) | `gahaha` | 2000 | MEM(N) + EXIO (analog sticks) | | Tested working |
| GAHAHA Ippatsudou 2 (Japan, GIS1 Ver.A) | `gahaha2` | 2001 | MEM(N) + EXIO (analog sticks) | | Tested working |
| Taiko no Tatsujin 2 (Japan, TK21 Ver.C) | `taiko2` | 2001 | MEM(N) + EXIO + CD-ROM | 240p | Tested working |
| Taiko no Tatsujin 3 (Japan, TK31 Ver.A) | `taiko3` | 2002 | MEM(N) + EXIO + CD-ROM | 240p | In testing |
| Taiko no Tatsujin 4 (Japan, TK41 Ver.A) | `taiko4` | 2002 | MEM(N) + EXIO + CD-ROM | 240p | In testing |
| Taiko no Tatsujin 5 (Japan, TK51 Ver.A) | `taiko5` | 2003 | MEM(N) + EXIO + CD-ROM | 240p | In testing |
| Taiko no Tatsujin 6 (Japan, TK61 Ver.A) | `taiko6` | 2004 | MEM(N) + EXIO + CD-ROM | 240p | In testing |
| Taiko no Tatsujin RT: Nippon no Kokoro (Japan, TKN1 Ver.A) | `taikort` | 2004 | MEM(N) + EXIO + CD-ROM | 240p | In testing |

**Gamshara, Star Trigon (480i graphics).** Both games draw their 480i screens into a single buffer, one field per
frame, while the other field is on screen. System 10's GPU draws 1.5x faster than a PlayStation's (and from fast
SGRAM, where this core's GPU uses DDR3), so on the board a frame always fits in a field; on earlier test builds the
title screens did not (17 ms for a 16.7 ms field), and the rest of the frame landed in the wrong field: flashing
title logo, black squares, ghosting, and the game stopping after Gamshara's power-up. From test8 the GPU fetches
texture rows ahead (the title frame draws in 13.8 ms), a frame that still overruns finishes in its own field, and
Gamshara's per-frame GPU reset waits for the GPU as it would on the board.

Taiko no Tatsujin: up to test7 the songs and voices played at 2/3 speed (the sound chip ran at the PlayStation's
rate instead of the board's 66.15 kHz, see *Timing*); fixed from test8.

### Taiko no Tatsujin: the disc (CHD to BIN/CUE)

The Taiko games need their CD-ROM as well as the ROM zip. MAME keeps the disc as a **CHD** file, which a MiSTer
arcade core cannot read, so convert it once to **BIN/CUE** with `chdman`, the tool that comes with MAME.

**1. Find your CHDs.** They sit in a folder named after the game, next to the zip:

| Game | ROM zip | CHD | Converted disc to copy |
| --- | --- | --- | --- |
| Taiko no Tatsujin 2 | `taiko2.zip` | `taiko2/nm-002.chd` | `nm-002.bin` |
| Taiko no Tatsujin 3 | `taiko3.zip` | `taiko3/nm-003.chd` | `nm-003.bin` |
| Taiko no Tatsujin 4 | `taiko4.zip` | `taiko4/tk-41.chd` | `tk-41.bin` |
| Taiko no Tatsujin 5 | `taiko5.zip` | `taiko5/tk-5.chd` | `tk-5.bin` |
| Taiko no Tatsujin 6 | `taiko6.zip` | `taiko6/tk-6.chd` | `tk-6.bin` |
| Taiko no Tatsujin RT | `taikort.zip` | `taikort/tk-n.chd` | `tk-n.bin` |

(MAME lists RT's CHD as a bad dump; it boots and plays its attract mode.)

**2. Convert.** `chdman` is in your MAME folder (`chdman.exe` on Windows; on Linux / macOS install the
`mame-tools` package or use the binary from your MAME build). Open a terminal in the folder with the CHD and run,
for example for Taiko 2:

```
chdman extractcd -i nm-002.chd -o nm-002.cue
```

On Windows, from the MAME folder: `chdman.exe extractcd -i roms\taiko2\nm-002.chd -o nm-002.cue`. This writes
`nm-002.cue` and `nm-002.bin` (a few hundred MB). To convert all six at once on Windows, run this in the MAME folder
(Command Prompt):

```
for %g in (taiko2\nm-002 taiko3\nm-003 taiko4\tk-41 taiko5\tk-5 taiko6\tk-6 taikort\tk-n) do chdman extractcd -i roms\%g.chd -o %~ng.cue
```

**3. Copy the `.bin`** to the SD card, for example `/media/fat/games/Namco_S10/` (the `.cue` is not needed).

**4. Mount it once.** Start the game, open the OSD (F12) and choose **Mount CD**, then the `.bin`. The game restarts
with the disc in the drive (on test builds up to test6, choose **Reset** after mounting). The core remembers the disc
for each game and mounts it by itself from then on. Without a disc the game stops on a black screen after the NOTICE
screen. Both `.bin` types `chdman` can write (2352- and 2048-byte sectors) and `.iso` files work.

### More games

| Game | MAME set | Year | Status |
| --- | --- | --- | --- |
| Uchuu Daisakusen: Chocovader Contactee (Japan, CVC1 Ver.A) | `chocovdr` | 2002 | Tested working |
| Panikuru Panekuru (Japan, PPA1 Ver.A) | `panikuru` | 2002 | Runs; music silent up to test8 (it streams the music from the ROM board by DMA; fixed in test9, in testing) |
| Star Trigon (Japan, STT1 Ver.A) | `startrgn` | 2002 | Black screen after the colour bars on test8; reaches its NOTICE screen in simulation from test9 (in testing) |
| Golgo 13: Juusei no Requiem (Japan, GLT1 VER.A) | `g13jnr` | 2001 | New in test10 (MEM(P3), needs its audio file, see below) |
| Tsukkomi Yousei Gips Nice Tsukkomi (NTK1 Ver.A) | `nicetsuk` | 2002 | New in test10 (MEM(P3), needs its audio file) |
| Seishun-Quiz Colorful High School (CHS1 Ver.A) | `squizchs` | 2003 | New in test10 (MEM(P3), needs its audio file) |

The other System 10 games need hardware the core does not have yet: the EXFINAL board (Medal no Tatsujin), MGEXIO
(medal games) and Taito's MEM(IO) (Hajime no Ippo).

### MP3 board games: the audio file (Golgo 13, Nice Tsukkomi, Seishun Quiz)

These three games play their music and voices through an MP3 decoder chip on the ROM board (MEM(P3)). The core
does not decode MP3 itself. Instead, a converter on your PC decodes the game's MP3 files once into an audio file
(`.p3a`), and the core streams that file from the SD card. Without it the game runs silently, apart from its sound
effects.

**1. Install** Python 3 with numpy (`pip install numpy`), and either **ffmpeg** (on the PATH) or PyAV
(`pip install av`) to decode the MP3s.

**2. Convert** with [`tools/p3audio.py`](tools/p3audio.py), giving it your ROM folder and the set name:

```
python p3audio.py C:\MAMEoms g13jnr
```

This writes `g13jnr.p3a` (16-bit stereo, 44.1 kHz):

| Game | Set | Audio | File size |
| --- | --- | --- | --- |
| Golgo 13 | `g13jnr` | 19 tracks, 15 min | about 150 MB |
| Nice Tsukkomi | `nicetsuk` | 873 tracks, 39 min | about 400 MB |
| Seishun Quiz | `squizchs` | 87 tracks, 36 min | about 360 MB |

**3. Copy the `.p3a`** to the SD card, for example `/media/fat/games/Namco_S10/`.

**4. Mount it once.** Start the game, open the OSD (F12), choose **Mount audio**, then the `.p3a`. The core remembers
the file for each game, as it does for the Taiko discs.

The game copies each MP3 into the board's RAM before playing it. The core identifies the track from its length and
three 64-byte samples (no two tracks in any of the three games share them) and plays the converted audio at the
game's volume.

### Alternatives

| Game | MAME set | Parent | Status |
| --- | --- | --- | --- |
| Mr. Driller 2 (Japan, DR21 Ver.A) | `mrdrilr2j` | Mr. Driller 2 | Playable |
| Mr. Driller 2 (US, DR23 Ver.A) | `mrdrilr2u` | Mr. Driller 2 | Playable |
| Gunbalina (Japan, GNN1 Ver.A) | `gunbalina` | Point Blank 3 | Tested working (also needs `ptblank3.zip`) |
| Gamshara (20020716A, 10021 Ver.A) | `gamsharao` | Gamshara | In testing (also needs `gamshara.zip`) |

### Video modes

The games choose their own resolution, exactly as on the PCB. Mr. Driller 2 and Point Blank 3 run at 240p.
Mr. Driller G runs its game screens at 640x480 interlaced (480i) by default; its service menu has an option
to switch the game to 240p. Gamshara and Kono e Tako run at 640x480 interlaced.

### Timing and refresh rate

System 10 is a PlayStation running 1.5x faster: the CPU and the sound chip run from 101.4912 MHz / 2 (50.7456 MHz)
instead of the PlayStation's 33.8688 MHz, while the video timing is the PlayStation's (53.693175 MHz dot clock).
The core matches that:

* **Sound** runs at the board's **66.15 kHz** sample rate (768 sound-chip clocks per sample at 50.7456 MHz). Test
  builds up to test7 played everything at the PlayStation's 44.1 kHz: 2/3 speed and a fifth too low, which made the
  Taiko songs and voices drag.
* **CPU**: the core clocks the CPU at 33.8688 MHz and makes up the speed with the turbo / data-cache modes it
  inherited from the System 12 core (also a 50 MHz CPU).
* **Video**: the PlayStation's NTSC timing, **59.82 Hz** at 240p (263 lines) and 59.94 Hz at 480i, as on the board.

Inputs (including the Taiko drums) are read live by the game at every poll; nothing is buffered.

MiSTer's HDMI output runs at a fixed 60 Hz by default, which repeats one frame about every 6 seconds at 240p. That
is hard to see in most games but shows as a small hitch in the scrolling notes of Taiko no Tatsujin. For
frame-perfect HDMI output, set `vsync_adjust=2` (lowest latency) or `vsync_adjust=1` in `MiSTer.ini` (globally,
or in a section per game, e.g. `[taiko2]`); the HDMI output then runs at the board's own refresh rate. The analog
15 kHz output is always native.

## Controls

The buttons are asked for in this order: Buttons 1-6 (only the ones the game uses), Start, Coin, Test, Service,
Pause.

| MiSTer button | Default pad button | Mr. Driller | Point Blank 3 | Gamshara | Taiko no Tatsujin |
| --- | --- | --- | --- | --- | --- |
| Button 1 | A | Drill | Trigger | Button 1 | Enter |
| Button 2 | B | | | Button 2 | Left Don (left drum surface) |
| Button 3 | X | | | Button 3 | Right Don (right drum surface) |
| Button 4 | Y / L | | | | Left Ka (left rim) |
| Button 5 | R2 / R | | | | Right Ka (right rim) |
| Start | Start | Start | Start | Start | |
| Coin | Select | Coin | Coin | Coin | Coin |
| Test | L (L2 for Taiko) | Test switch (slide: press once to enter the service menu, again to leave) | same | same | same |
| Service | R (R2 for Taiko) | Service credit | same | same | same |
| Pause | R3 | Pause | Pause | Pause | Pause |

Golgo 13: aim the rifle with the light gun, analog stick or mouse, as in Point Blank 3 (the **Light Gun** OSD page
and crosshair work the same). Button 1 is Enter, Button 2 the trigger, and Button 3 toggles the scope sensor (put
your eye to the scope / take it away). Nice Tsukkomi: Buttons 1-3 are the forehead, chest and back-of-head hit
sensors, Button 4 the pedal, Button 5 Enter, Up / Down to select, and Start to choose. Seishun Quiz: Buttons 1-4
answer, for each player.

GAHAHA Ippatsudou: each player's two levers are the pad's left and right analog sticks; Button 1, Button 2 and
Enter (Button 3), Up / Down to select. Mr. Driller uses a 4-way joystick, Gamshara an 8-way joystick; Taiko uses Up / Down to choose songs. A USB Taiko
drum controller works by mapping its four zones to Buttons 2-5. If you used an earlier build, map the buttons
again once (the order changed).

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
* **Mount CD** (Taiko games) / **Mount audio** (MP3 board games): the disc or audio file, see above.
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
* **Taiko no Tatsujin.** MAME runs Taiko 2 to 6 and RT but marks them not working because its PlayStation timing is
  not accurate enough for a rhythm game. The core runs the CPU, GPU and SPU cycle by cycle, with the sound chip at
  the board's own 66.15 kHz.
* **Light guns.** MAME aims with a mouse or stick-driven crosshair. The core takes real light guns (GunCon 2 on
  a CRT, Sinden, Gun4IR) through MiSTer's gun support.

* **Gamshara region.** MAME's driver notes that it is unknown whether the later Gamshara set (20020912A) honours
  the World region setting like the earlier one. It does: with Region = World it runs in English (checked in
  MAME), so the core's MRA defaults to World.

MAME marks Point Blank 3 *unemulated protection*: part of the KEYCUS chip's decryption is not understood and is
replayed from a recorded bit table (`ptblank3_nonlinear`, part of the MAME set). The core does the same, so it
works with the MAME ROM set unchanged.

## About the hardware

System 10 is a PSOne on an arcade board, clocked 1.5x faster: a CXD8606 CPU (R3000A + GTE) at 50.7 MHz, a
CXD8561CQ GPU with 2 MB VRAM, the PlayStation sound chip (CXD2938Q, 66.15 kHz) with 512 KB of sound RAM and 4 MB of
main RAM. There is no boot ROM on the main
board: everything, including the boot code, comes from the **MEM** ROM board, whose KEYCUS CPLD descrambles the
ROM data and decrypts the game program. Some games add an **EXIO** expansion board (light guns, extra I/O).
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## About the core

* Built on Robert Peip's [PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) (CPU, GTE, GPU, SPU, MDEC, DMA),
  through XelaNotPu's System 11 port and the author's Namco System 12 (Tenkomori Shooting) and Konami GV cores.
* Thanks to guljam's [System 10 beta core](https://github.com/guljam/namco-system-10-mister-core-beta), whose
  development notes pointed out the 1.5x clocks (sound rate, CPU) and the 480i GPU throughput problem; the
  implementations here are this core's own.
* The MEM board (MEM(M) flash + mask ROMs, MEM(N) NAND), the KEYCUS descrambler and decrypters (type 1, type 2,
  type 2 with the nonlinear table or several nonlinear terms), the main-board I/O, the EXIO(G) light-gun board, the
  EXIO drum board (its microcontroller high-level) and the ATAPI CD-ROM drive are new and follow MAME.
  The decrypters reproduce MAME on every word the games read.
* ROM images are loaded straight into DDR3 (fast loading), so even the largest System 10 games fit.

## License

GPL-3.0-or-later for the combined work (see [LICENSE](LICENSE), [COPYING.GPL2](COPYING.GPL2) and
[COPYING.GPL3](COPYING.GPL3)). The MiSTer framework in `sys/` keeps its own notices.

No ROMs or other game data are included in this repository. "Namco" and "System 10" are trademarks of
their owners; this project is not affiliated with them.
