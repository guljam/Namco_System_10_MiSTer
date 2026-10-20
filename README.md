# Tenkomori Shooting (Namco System 12) for MiSTer

<!-- screenshots -->

A MiSTer FPGA core for **Tenkomori Shooting** (Namco, 1998), a two-player vertical variety
shooter on Namco's **System 12**, the PlayStation-based arcade board. One core (`Tenkomori`) runs
the board; each version of the game has its own MRA.

I created this core because I wanted to play this game on my MiSTer FPGA. I am posting it here and
open sourcing it for everyone to enjoy and give feedback/make improvements. This core was created
with the assistance of AI tooling. I will not be creating further Namco System 12 cores at this time.

**Status: beta.** The game boots and plays from attract mode through every minigame, with music
and sound effects, on HDMI (horizontal or rotated) and on 15 kHz CRTs.

## Quick start

1. Copy the core from [`Releases/`](Releases/) (`Tenkomori_YYYYMMDD.rbf`) to
   **`/media/fat/_Arcade/cores/`**.
2. Copy the MRA file from [`MRA/`](MRA/) to **`/media/fat/_Arcade/`**.
   For the Japanese version, copy the `_Tenkomori Shooting` folder from
   [`MRA/_alternatives/`](MRA/_alternatives/) to **`/media/fat/_Arcade/_alternatives/`**.
3. Put the MAME 0.289 ROM zips in **`/media/fat/games/mame/`**: `tenkomor.zip`, plus
   `tenkomorja1.zip` for the Japanese version (it also needs `tenkomor.zip`).
4. Load the game from the **Arcade** menu.

ROMs are not included. You must supply your own.

**A 64 MB (or larger) SDRAM module is required:** the game's ROMs are about 50 MB.

## Supported games

| Game | MAME set | Year | Genre | Board | Status |
| --- | --- | --- | --- | --- | --- |
| Tenkomori Shooting (World, TKM2/VER.A1) | `tenkomor` | 1998 | Shooter / variety | System 12 | Full game playable |

### Alternatives

These use the same core and the same board as the main set, with a different ROM set.

| Game | MAME set | Year | Parent game | Status |
| --- | --- | --- | --- | --- |
| Tenkomori Shooting (Japan, TKM1/VER.A1) | `tenkomorja1` | 1998 | Tenkomori Shooting | Full game playable |

## Fast loading

The MRAs use MiSTer's DDR3 fast ROM loading: Main_MiSTer copies the ROMs straight into memory and
the core unpacks them itself, so the game starts much sooner after you pick it from the menu than
with a normal ROM transfer (no "Sending" progress bar per ROM). More detail: [docs/FASTLOAD.md](docs/FASTLOAD.md).

## Controls

Two players, each with an 8-way joystick and one button:

| MiSTer button | Default pad button | Function |
| --- | --- | --- |
| Shoot | A | Shoot |
| Start | Start | Start (P1 / P2) |
| Coin | Select | Coin (P1 / P2) |
| Service | R | Service credit |
| Test | L | Test switch (service menu) |
| Pause | R3 | Pause |

## OSD

* **Scandoubler Fx**: None, HQ2x, CRT 25%, CRT 50% (HDMI in Horizontal).
* **Orientation**:
  * **Horizontal** (default): the picture exactly as the board outputs it, filling the screen with
    the game on its side (for a rotated monitor).
  * **Vertical CW**: rotated so the game stands upright on a normal screen.
  * **Vertical CCW**: rotated the other way.
  * **Flipped**: the native picture turned 180 degrees (HDMI and analog).
  * The analog output always carries the native raster.
* **Video & Audio**: aspect ratio, integer scaling, dithering, stereo mix.
* **CRT Adjust** for the native 15 kHz analog output: **CRT H-Size**, **CRT H-Position** and
  **CRT V-Shift** (hidden while CRT Adjust is Off).
* **Hardware**: the board's two DIP switches (**Service Mode**, **Freeze**) and **Pause when OSD
  open**.

## Saves

The game's AT28C16 EEPROM (operator settings, bookkeeping, high scores) is saved to the SD card as a
`.nvm` file in `/media/fat/config/nvram/`. MiSTer writes it when you open the OSD after the game
has changed it. On a first start the EEPROM is blank and the game initialises it itself, as on a
new board.

## About the hardware

Namco System 12 is a PlayStation mainboard extended into an arcade board:

* Sony **CXD8661R** CPU (R3000A with the GTE) at 50 MHz and a **CXD8654Q** GPU with 2 MB VRAM.
* A **Hitachi H8/3002** sub CPU that runs the sound driver and reads the cabinet inputs, sharing
  RAM with the main CPU.
* A Namco **C352** 32-voice PCM sound chip.
* Up to 28 MB of banked program/graphics ROM, reached through a window and a ROM-to-RAM DMA
  channel.
* An **AT28C16** EEPROM and an RTC.

[docs/HARDWARE.md](docs/HARDWARE.md) is the full specification, written from MAME before the core
was built.

## About the core

* Built on Robert Peip's [PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) (CPU, GTE, GPU,
  DMA). The System 12 memory map, banked ROM and ROM DMA, the H8/3002 CPU and its peripherals,
  the sub board and the EEPROM are new.
* Rotation for HDMI on a normal screen, native 15 kHz output for CRTs with CRT Adjust (H-Size,
  H-Position, V-Shift), and a black 15 kHz raster while the ROMs load so CRTs stay locked.
* EEPROM saved to the SD card as `.nvm`.
* DDR3 fast ROM loading.
* Timing closes on every clock domain.

### Known issues

* With the picture rotated (Vertical CW / CCW), the HDMI picture does not show the Scandoubler Fx
  effects (MiSTer does not apply scanlines to a rotated picture). Use MiSTer's video filters
  instead. Scandoubler Fx still works in Horizontal.

## Releases

Builds are in [`Releases/`](Releases/) as `Tenkomori_YYYYMMDD.rbf`. The MRAs name the core without
the date (`<rbf>Tenkomori</rbf>`), and MiSTer loads the newest dated file in `_Arcade/cores/`. You
are welcome to run your own build if you'd prefer.

## Building

Quartus Prime Lite 17.0. Open `Tenkomori.qpf` and compile, then copy `output_files/Tenkomori.rbf`
to `Releases/Tenkomori_YYYYMMDD.rbf`. See [docs/BUILDING.md](docs/BUILDING.md).

## Documentation

* [Hardware](docs/HARDWARE.md)
* [MRA format](docs/MRA_FORMAT.md)
* [Fast loading](docs/FASTLOAD.md)
* [Building and simulation](docs/BUILDING.md)

## License

GPL-3.0-or-later for the combined work (see [LICENSE](LICENSE), [COPYING.GPL2](COPYING.GPL2) and
[COPYING.GPL3](COPYING.GPL3)). The MiSTer framework in `sys/` keeps its own notices.

No ROMs or other game data are included in this repository. "Namco", "System 12" and "Tenkomori
Shooting" are trademarks of their owners; this project is not affiliated with them.
