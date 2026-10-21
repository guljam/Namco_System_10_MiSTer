#!/usr/bin/env bash
# Full-system NVC simulation of the Namco System 10 core (psx_mister + System 10 board, mixed VHDL/SV).
#
#   GAME=mrdrilrg sim/system/run10.sh [STOP_TIME]    analyze + elaborate + run (default 20ms)
#   REUSE=1 ...                                       rerun the cached elaboration
#   WD=/path ...                                      separate build directory (parallel runs)
#   inputs.txt in WD: "<ms> <IN1 hex>" lines (active low)
#
# Memory images (descrambled BIOS, MEM board image, board record) come from your MAME zips via
# scripts/s10tool.py images; nothing ROM-derived is written into the repository.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RTL="$ROOT/rtl"
SIMMEM="$ROOT/sim/common"
GAME="${GAME:-mrdrilrg}"
WD="${WD:-$HERE/build10_$GAME}"
STOP_TIME="${1:-20ms}"
NVC="${NVC:-/c/Users/klest/Documents/Codex/tools/nvc/PFiles/NVC/bin/nvc.exe}"
NVCF="--std=2008 --ieee-warnings=off --messages=compact"
NVC_MEM="-M 4g -H 3g"

mkdir -p "$WD"
cd "$WD"
WDW="$(cygpath -m "$WD" 2>/dev/null || echo "$WD")"
analyze() { "$NVC" $NVCF --work="$1:$WDW/$1" -L "$WDW" -a --relaxed "${@:2}"; }

LIBFILES=("$SIMMEM/RamMLAB.vhd" "$SIMMEM/dpram.vhd" "$RTL/SyncFifo.vhd" "$RTL/SyncFifoFallThrough.vhd"
          "$RTL/SyncFifoFallThroughMLAB.vhd" "$RTL/SyncRam.vhd" "$RTL/SyncRamDual.vhd"
          "$RTL/SyncRamDualNotPow2.vhd" "$RTL/SyncRamDualByteEnable.vhd")

if [ "${REUSE:-0}" != "1" ]; then
  if [ ! -f "$WD/ddr.bin" ]; then
    python "$ROOT/scripts/s10tool.py" images "$GAME" "$WDW"
    python - "$WDW" <<'PY'
import sys, os
d = sys.argv[1]
open(os.path.join(d, "sdram.bin"), "wb").write(bytes(0x400000) + open(os.path.join(d, "bios.bin"), "rb").read())
PY
  fi
  rm -rf altera_mf mem psx tb
  analyze altera_mf "$SIMMEM/altera_mf_sim.vhd"
  analyze mem "${LIBFILES[@]}"
  files=()
  while read -r f; do
    case "$f" in
      dpram.vhd|RamMLAB.vhd) ;;
      *) files+=("$RTL/$f");;
    esac
  done < <(grep -o 'qip_path) [^ ]*\.vhd' "$RTL/psx.qip" | awk '{print $2}')
  mkdir -p "$WD/simpatch"
  DEF="(start => 'Z', done => 'Z', dividend => (others => 'Z'), divisor => (others => 'Z'), quotient => (others => 'Z'), remainder => (others => 'Z'))"
  for g in gpu_line gpu_poly; do
    sed -E "s/^( *div[0-9] *: inout div_type) *;/\1 := $DEF;/" "$RTL/$g.vhd" > "$WD/simpatch/$g.vhd"
  done
  for i in "${!files[@]}"; do
    case "$(basename "${files[$i]}")" in gpu_line.vhd|gpu_poly.vhd) files[$i]="$WD/simpatch/$(basename "${files[$i]}")";; esac
  done
  analyze psx "${LIBFILES[@]}" "${files[@]}" "$RTL/s10_ch3.vhd"
  analyze tb "$HERE/globals.vhd" "$HERE/sdram_model_s12.vhd" "$HERE/ddrram_model.vhd" "$HERE/framebuffer.vhd"
  # the SystemVerilog board modules go into the testbench library (VHDL component default binding)
  "$NVC" --work="tb:$WDW/tb" -L "$WDW" -a "$RTL/s10_crypt_t1.sv" "$RTL/s10_crypt_t2.sv" "$RTL/s10_crypt_t2s.sv" "$RTL/s10_io.sv" "$RTL/s10_exio.sv" "$RTL/s10_mem.sv" "$RTL/s10_loader.sv"
  python "$HERE/gen_tb10.py"
  "$NVC" $NVCF --work="tb:$WDW/tb" -L "$WDW" -a --relaxed "$HERE/tb_s10.vhd"
  "$NVC" $NVCF $NVC_MEM --work="tb:$WDW/tb" -L "$WDW" -e tb_s10 -gFB_EVERY="${FB_EVERY:-1}"
fi

"$NVC" $NVCF $NVC_MEM --work="tb:$WDW/tb" -L "$WDW" -r tb_s10 --stop-time="$STOP_TIME"
echo "== $WD =="
tail -3 "$WD/mips_pc.log" || true
