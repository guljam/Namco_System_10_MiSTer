# Building and verification

## Bitstream

Quartus Prime Lite 17.0 (the version the MiSTer framework targets).

```
powershell -ExecutionPolicy Bypass -File scripts\build.ps1            # full compile -> output_files\Namco_S10.rbf
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -MapOnly   # analysis & synthesis only
```

The script waits for any other Quartus job on the machine to finish first and writes
`build/quartus.log` plus a resource/timing summary in `build/build-summary.txt`.
Release bitstreams are copied to `Releases/Namco_S10_YYYYMMDD.rbf`.

## MRAs and memory images

```
python scripts/s10tool.py mra               # regenerate MRA/ and MRA/_alternatives/
python scripts/s10tool.py check             # descrambled BIOS vs MAME's maincpu:rom (local/mame/dumpbios.lua)
python scripts/s10tool.py images SET DIR    # bios.bin / ddr.bin / record.bin for the benches
```

Games are described in `scripts/s10tool.py` (`GAMES`/`BOARDS`, mirroring MAME's `namcos10.cpp`): ROM files,
board type, descrambler permutation and XOR, decrypter parameters, nvram window. ROM zips are read from
`~/Downloads/mame/roms` (`--romdir`). Nothing ROM-derived is written into the repository.

## Simulation

| Bench | Tool | What it covers |
| --- | --- | --- |
| `sim/crypt` | ModelSim | `s10_crypt_t1/t2` against every cipher/plain word pair MAME produces (`sim/crypt/README.md`) |
| `sim/board` | NVC | `s10_mem` (+ loader) replaying every MEM-board access MAME makes (`local/mame/boardcap.lua`), each read compared |
| `sim/system` | NVC | the whole core except the MiSTer framework: psx_mister + System 10 board on preloaded SDRAM/DDR3 images; video frames (`gra2png.py`), PC trace, GP1 log, board-bus log |

```
GAME=mrdrilrg sim/board/run.sh
GAME=mrdrilrg sim/system/run10.sh 400ms       # REUSE=1 to rerun the cached elaboration
```

NVC 1.23 runs the mixed VHDL/SystemVerilog design; the SystemVerilog board modules are analysed into the
testbench library and bound through component declarations. Two NVC limitations are worked around in the RTL:
no `'0` fills, and XOR reductions are kept to 64 bits.

MAME reference captures (Lua bus taps, BIOS dumps, PC traces) live in `local/mame/` and are not part of the
repository.
