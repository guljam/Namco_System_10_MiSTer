# Building and verification

## Bitstream

Quartus Prime Lite 17.0 (the version the MiSTer framework targets).

```
powershell -ExecutionPolicy Bypass -File scripts\build.ps1            # full compile -> output_files\Tenkomori.rbf
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -MapOnly   # analysis & synthesis only
```

The script waits for any other Quartus job on the machine to finish first and writes
`build/quartus.log` plus a resource/timing summary in `build/build-summary.txt`.
Release bitstreams are copied to `Releases/Tenkomori_YYYYMMDD.rbf`.

## MRAs

```
python scripts/romtool.py mra      # regenerate MRA/ and MRA/_alternatives/
python scripts/romtool.py check    # rebuild every ioctl stream from the zips, compare with MAME's layout
```

ROM zips are read from `~/Downloads/mame/roms` (`--romdir` to change). Nothing ROM-derived is
written into the repository.

## DDR3 fast loading

See `docs/FASTLOAD.md`: `rtl/tkm_fastload.sv` (enabled by `TKM_FASTLOAD` in `Tenkomori.qsf`), Verilator
bench `sim/fastload`.

## Simulation (NVC)

| Bench | What it covers |
| --- | --- |
| `sim/h8cpu` | H8/300H CPU core replayed against a 1.2M-instruction MAME register trace of the Tenkomori sound program (`sim/h8cpu/README.md`) |
| `sim/sub` | `s12_sub` on its own: H8 + peripherals + C352 + shared RAM + program cache, logs on-chip I/O and C352 writes for comparison with MAME (`local/mame/c352log.lua`) |
| `sim/system` | the whole core except the MiSTer framework: PSX CPU/GPU/DMA/MDEC with the System 12 memory map, ROM DMA, boot signature, H8 sub board, all on a preloaded SDRAM image; writes the video output as frames (`gra2png.py`) |

`sim/system/run.sh 400ms` analyses, elaborates and runs the full system (about 1.5 s of host
time per simulated millisecond). The upstream PSX core writes debug text files to `R:\`; map a
folder there first (`subst R: %TEMP%\rdisk`).

MAME reference captures used during development (Lua bus taps, debugger traces) live in
`local/mame/` and are not part of the repository.
