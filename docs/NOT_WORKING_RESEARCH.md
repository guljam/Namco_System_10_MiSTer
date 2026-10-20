# System 10 games marked "not working" in MAME — research

Status of every System 10 set MAME 0.289 flags `MACHINE_NOT_WORKING`, why, and whether this core can run it.
Sources: MAME `namcos10.cpp` / `namcos10_exio.cpp` / `ns10crypt.cpp` (driver code, Guru's hardware notes, TODOs),
MAME release notes, and the core's own capabilities. Nothing here has been run yet (no ROM sets).

## Summary

| Game(s) | MAME set(s) | Why MAME flags it | Extra hardware | Core feasibility | Value |
| --- | --- | --- | --- | --- | --- |
| Taiko no Tatsujin 2, 4, 6 | `taiko2`, `taiko4`, `taiko6` | **Playable in MAME**; flagged only because MAME's PS1 timing is not trusted for rhythm games | ATAPI CD-ROM + data disc (CHD), EXIO board with MCU reading the drum sensors | **Good**: timing is the core's strength. Needs a CD-ROM/ATAPI path and the EXIO drum inputs | **High** |
| Taiko no Tatsujin 3, 5, RT | `taiko3`, `taiko5`, `taikort` | Same as above (RT's disc is a bad dump) | Same + decrypter with several nonlinear terms | Good once the Taiko 2/4/6 work exists; small decrypter extension | High |
| NFL Classic Football | `nflclsfb` | Trackball not emulated (EXIO MCU serial port missing in MAME's TMP95C061) | EXIO with MCU, trackballs, 4 players | Possible: same EXIO work as Taiko + trackball (mouse) input | Medium |
| Hard Puncher Hajime no Ippo 1, 2 | `ippo`, `ippo2` | Punch-pad mechanism sensors not modelled (speed / safety / human sensors) | Taito MEM(IO) ROM board (TC58256 NANDs), motorised punch pad | Possible to boot; playing needs a simulated punch pad (fake sensor timing). Gameplay is physical | Low |
| Knock Down 2001 | `kd2001` | P-DRIVE board (H8/3002 + its own ROM) not emulated | P-DRIVE motor/sensor board | Possible: we already have an H8/300H core (Tenkomori). Gameplay is a physical punching machine | Low |
| Medal no Tatsujin 1, 2 | `medalnt`, `medalnta`, `medalnt2` | EXFINAL board not implemented ("essentially a network board") | EXFINAL (ARCNET network, RTC) — satellite of a medal-pusher cabinet | Poor: needs the cabinet's network partner | Very low |
| Medal games: Puzz Ball, Sugorotic JAPAN, Pacman BALL, Slot no Oujisama, Sekai Kaseki Hakken, Ball Pom Line, Keroro Gunsou, Gegege no Kitaro | `puzzball*`, `sugorotc*`, `pacmball`, `slotouji*`, `sekaikh*`, `ballpom`, `keroro`, `gegemdb` | MGEXIO board only "best effort": H8/3007 runs uploaded code that drives hoppers, pushers, payout solenoids and medal sensors, which MAME fakes; some crash or stop BGM | MGEXIO (H8/3007, NVRAM) + medal mechanics | Possible to boot (H8 core + faked sensors, as MAME). Gameplay depends on a physical medal field | Low |

Related, and **working** in MAME: GAHAHA Ippatsudou 1 and 2 (`gahaha`, `gahaha2`) use the same EXIO-with-MCU board
(analog sticks) as Taiko, so the Taiko EXIO work would also bring them to the core.

## Details

### Taiko no Tatsujin (2001-2004)

* **MAME status.** MAME 0.254 release notes: Taiko 2, 4 and 6 are playable, but rhythm games are not marked working
  because the developers are not confident in the timing accuracy of MAME's PlayStation emulation.
  This is the most promising group: the core runs the PS1 CPU, GPU and SPU at hardware timing, which is exactly what
  MAME is unsure of.
* **CD-ROM.** Every Taiko game needs its data disc ("The game will not show anything on screen if the CD drive & disc
  is not present", Guru's notes). The disc sits on an IDE/ATAPI drive on the main board's 40-pin connector (MAME:
  `ata:0:cdrom`, a CR-589). MAME sets: `nm-002` (TK2), `nm-003` (TK3), `tk-41`, `tk-5`, `tk-6`, `tk-n` (RT, bad dump).
  Core work: an ATAPI register block on the board bus (0x1FBCxxxx, MAME `m_ata`) plus sector reads. PSX_MiSTer already
  reads CD images (CHD/CUE) from the SD card through Main_MiSTer, so the data path exists; the new part is the ATAPI
  command set (READ(10)/(12), TEST UNIT READY, INQUIRY, REQUEST SENSE…) and its DMA/IRQ.
* **Drums.** Piezo sensors on the EXIO board's ADC, read by its TMP95C061 MCU running a program the game uploads.
  Two routes: (a) a TLCS-900/H CPU core (the NeoGeo Pocket MiSTer core has one), or (b) high-level emulation of the
  uploaded program's job (sensor values into the shared RAM). (b) is smaller and probably enough; to be decided from
  the program itself. MiSTer input: buttons per drum zone (rim/surface, left/right), or a USB Taiko drum controller.
* **Decryption.** Taiko 2, 4, 6 fit the core's existing type-2 form. Taiko 3, 5 and RT XOR several nonlinear product
  terms; the decrypter needs up to four product terms (a few hundred ALMs).
* **Fit.** The core is at 99 % ALMs. ATAPI + EXIO need space: removing the unused PS1-console logic still in the core
  (pad/memory-card SIO, savestates, cheats, debug overlays) is the plan for that.

### NFL Classic Football (2003)

MAME TODO: "Trackball (EXIO, requires serial emulation in TMP95C061)". Four players on two cabinet sides with
buttons on IN1 and EXIO_IN1. With the Taiko EXIO work in place, the trackballs are an extra input path
(MiSTer mouse / spinner). Medium value, medium effort after Taiko.

### Hard Puncher Hajime no Ippo 1 & 2 (Taito, 2001/2002)

A boxing machine: the player punches a motorised pad. The game raises the pad and watches speed sensors, a safety
sensor and "human" proximity sensors; MAME's TODO says the sensors must follow the motor timing or the game throws a
speed error. Separate ROM board (Taito MEM(IO), TC58256AFT NANDs, its own data XOR register). Booting is realistic;
playing would mean simulating the pad and mapping a punch to a button. Low value on MiSTer.

### Knock Down 2001 (2001)

Also a punching machine. Its P-DRIVE board (H8/3002, ROM `kd11-dr0-ic10.bin` in the MAME set) drives the mechanism
and is not emulated in MAME. The core already has an H8/300H CPU (from the Tenkomori port, H8/3002 family), so the
board could be emulated, but gameplay is physical. Low value.

### Medal no Tatsujin 1 & 2 (2005/2007)

Satellite stations of a medal-pusher cabinet. The EXFINAL board is an ARCNET network controller + RTC; MAME has no
implementation and the games expect the main cabinet on the network. Not practical.

### Medal games on MGEXIO (2002-2007)

Puzz Ball, Sugorotic JAPAN, Pacman BALL, Slot no Oujisama, Sekai Kaseki Hakken, Ball Pom Line, Keroro Gunsou,
Gegege no Kitaro. The MGEXIO board has an H8/3007 that runs code the game uploads and drives the medal mechanics
(hoppers, pusher motor, divider/lockout/payout solenoids, sensors). MAME fakes the mechanics "best effort" and some
games still error (divider sensor) or lose BGM (an SPU interrupt, MAME suspects — possibly better on the core's SPU).
The core could reuse its H8 core and fake the same sensors; without a physical medal field the games are mostly
attract/menus. Two of them (Keroro, Gegege) use 2x larger NAND chips, which the core supports.

## Recommendation

1. **Taiko no Tatsujin 2 / 4 / 6** first: biggest payoff, and the reason MAME holds them back is the thing an FPGA
   does best. Work: free ALMs, ATAPI CD-ROM on the board bus fed from a CD image, EXIO drum inputs (HLE), drum
   controls. Then Taiko 3 / 5 / RT (multi-term decrypter) and GAHAHA 1 / 2 (same EXIO, analog sticks).
2. **NFL Classic Football** after that (EXIO + trackball).
3. Punching machines and medal games only if wanted for completeness; they boot but are not meaningfully playable.

## ROMs needed for this work (MAME 0.289 names, into `~/Downloads/mame/roms`)

* Taiko: `taiko2.zip`, `taiko4.zip`, `taiko6.zip` and their CHDs (`taiko2/nm-002.chd`, `taiko4/tk-41.chd`,
  `taiko6/tk-6.chd`); later `taiko3` (`nm-003.chd`), `taiko5` (`tk-5.chd`), `taikort` (`tk-n.chd`).
* EXIO games: `gahaha.zip`, `gahaha2.zip`, `nflclsfb.zip`.
* Optional: `ippo.zip`, `ippo2.zip`, `kd2001.zip`, medal games.
* Also useful now: `gjspace.zip`, `knpuzzle.zip`, `chocovdr.zip`, `panikuru.zip`, `startrgn.zip` (MRAs exist, not yet
  verified against MAME).
