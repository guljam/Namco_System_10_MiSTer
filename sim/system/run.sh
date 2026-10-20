#!/usr/bin/env bash
# Full-system NVC simulation of the Tenkomori core (psx_mister + System 12 glue + H8 sub board).
#
#   sim/system/run.sh [STOP_TIME]            analyze + elaborate + run (default 20ms)
#   REUSE=1 sim/system/run.sh 200ms          rerun the cached elaboration
#   COMPILE_ONLY=1 sim/system/run.sh         analyze only (syntax check of the RTL)
#   GAME=tenkomorja1 ...                     other MRA set for the SDRAM image
#   FULLRESET=1 ...                          hardware PSX reset sequence (no FASTSIM shortcut)
#   FB_EVERY=4 LOGVRAM=0 ...                 lighter logging for long runs
#   WD=/path ...                             separate build directory (parallel runs)
#
# The SDRAM image (ROMs placed as the MiSTer loader places them) is built from your MAME
# zips by scripts/romtool.py into sim/system/build/sdram.bin (not part of the repository).
# Outputs land in sim/system/build/: mips_pc.log, s12_events.log, gra_fb_out_vga.gra
# (convert with sim/system/gra2png.py).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RTL="$ROOT/rtl"
SIMMEM="$ROOT/sim/common"
WD="${WD:-$HERE/build}"
STOP_TIME="${1:-20ms}"
NVC="${NVC:-/c/Users/klest/Documents/Codex/tools/nvc/PFiles/NVC/bin/nvc.exe}"
NVCF="--std=2008 --ieee-warnings=off --messages=compact"
NVC_MEM="-M 4g -H 3g"
TURBO="${TURBO:-0}"
GAME="${GAME:-tenkomor}"

mkdir -p "$WD/rtl"
cp "$RTL/eeprom_ff.mif" "$WD/rtl/"   # altsyncram init_file is resolved relative to the run directory
cd "$WD"
WDW="$(cygpath -m "$WD" 2>/dev/null || echo "$WD")"
analyze() { "$NVC" $NVCF --work="$1:$WDW/$1" -L "$WDW" -a --relaxed "${@:2}"; }

LIBFILES=("$SIMMEM/RamMLAB.vhd" "$SIMMEM/dpram.vhd" "$RTL/SyncFifo.vhd" "$RTL/SyncFifoFallThrough.vhd"
          "$RTL/SyncFifoFallThroughMLAB.vhd" "$RTL/SyncRam.vhd" "$RTL/SyncRamDual.vhd"
          "$RTL/SyncRamDualNotPow2.vhd" "$RTL/SyncRamDualByteEnable.vhd")

if [ "${REUSE:-0}" != "1" ]; then
  rm -rf altera_mf mem psx tb
  analyze altera_mf "$SIMMEM/altera_mf_sim.vhd"
  analyze mem "${LIBFILES[@]}"
  # psx library in rtl/psx.qip order (simulation models for the vendor RAM wrappers)
  files=()
  while read -r f; do
    case "$f" in
      dpram.vhd|RamMLAB.vhd) ;;
      *) files+=("$RTL/$f");;
    esac
  done < <(grep -o 'qip_path) [^ ]*\.vhd' "$RTL/psx.qip" | awk '{print $2}')
  # NVC resolves the undriven result fields of the GPU's inout divider-record ports to 'U'
  # (LRM default driving value); sim-only copies give those ports a 'Z' default.
  mkdir -p "$WD/simpatch"
  DEF="(start => 'Z', done => 'Z', dividend => (others => 'Z'), divisor => (others => 'Z'), quotient => (others => 'Z'), remainder => (others => 'Z'))"
  for g in gpu_line gpu_poly; do
    sed -E "s/^( *div[0-9] *: inout div_type) *;/\1 := $DEF;/" "$RTL/$g.vhd" > "$WD/simpatch/$g.vhd"
  done
  for i in "${!files[@]}"; do
    case "$(basename "${files[$i]}")" in gpu_line.vhd|gpu_poly.vhd) files[$i]="$WD/simpatch/$(basename "${files[$i]}")";; esac
  done
  analyze psx "${LIBFILES[@]}" "${files[@]}"
  if [ "${COMPILE_ONLY:-0}" = "1" ]; then echo "analysis OK"; exit 0; fi
  analyze tb "$HERE/globals.vhd" "$HERE/sdram_model_s12.vhd" "$HERE/ddrram_model.vhd" "$HERE/framebuffer.vhd"
  python "$HERE/gen_tb.py"
  analyze tb "$HERE/tb_s12.vhd"
  if [ ! -f "$WD/sdram.bin" ]; then
    python "$ROOT/scripts/romtool.py" sdram --game "$GAME" "$WDW/sdram.bin"
  fi
  "$NVC" $NVCF $NVC_MEM --work="tb:$WDW/tb" -L "$WDW" -e tb_s12 -gTURBO="'$TURBO'" -gTCACHE="'${TCACHE:-0}'" -gTC50="'${TC50:-0}'" -gHACK480="'${HACK480:-0}'" -gSLOWVRAM="${SLOWVRAM:-0}" -gTRACE_FROM_US="${TRACE_FROM_US:-0}" -gTRACE_TO_US="${TRACE_TO_US:-0}" -gFULLRESET="'${FULLRESET:-0}'" -gFB_EVERY="${FB_EVERY:-1}" -gWATCHIDX="${WATCHIDX:--1}" -gH8HOLD="'${H8HOLD:-0}'" -gMIPS_HOLD_US="${MIPS_HOLD_US:-0}" -gVTRACE_FROM="${VTRACE_FROM:-0}" -gVTRACE_TO="${VTRACE_TO:-0}" -gLOGVRAM="'${LOGVRAM:-1}'"
fi

"$NVC" $NVCF $NVC_MEM --work="tb:$WDW/tb" -L "$WDW" -r tb_s12 --stop-time="$STOP_TIME"
echo "== $WD =="
tail -3 "$WD/mips_pc.log" || true
head -20 "$WD/s12_events.log" || true
