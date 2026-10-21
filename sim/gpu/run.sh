#!/usr/bin/env bash
# GPU-only replay: sim/gpu/run.sh GP0_FILE [SLOWVRAM]
# Times how long rtl/gpu.vhd takes to draw a captured GP0 stream (e.g. one game frame from MAME).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WD="${WD:-$HERE/build}"
NVC="${NVC:-/c/Users/klest/Documents/Codex/tools/nvc/PFiles/NVC/bin/nvc.exe}"
NVCF="--std=2008 --ieee-warnings=off --messages=compact"
mkdir -p "$WD"; cd "$WD"
WDW="$(cygpath -m "$WD" 2>/dev/null || echo "$WD")"
SYSB="${SYSB:-$ROOT/sim/system/build10_mrdrilrg}"      # reuse the psx/mem/tb libraries analysed by sim/system/run.sh
SYSBW="$(cygpath -m "$SYSB" 2>/dev/null || echo "$SYSB")"
if [ "${REUSE:-0}" != "1" ]; then
  rm -rf gtb
  python "$HERE/gen_tb_gpu.py"
  "$NVC" $NVCF --work="gtb:$WDW/gtb" -L "$SYSBW" -a --relaxed "$HERE/tb_gpu.vhd"
  "$NVC" $NVCF -M 2g -H 2g --work="gtb:$WDW/gtb" -L "$SYSBW" -e tb_gpu -gSLOWVRAM="${2:-0}" -gLOADV="'${LOADV:-0}'" -gLOGV="'${LOGV:-0}'" -gREADBACK="${READBACK:-0}" -gPROF="${PROF:-0}"
fi
cp "$1" "$WD/gp0.txt"
"$NVC" $NVCF -M 2g -H 2g --work="gtb:$WDW/gtb" -L "$SYSBW" -r tb_gpu 2>&1 | grep -v "POLY\|GP0DISPATCH\|CPU2VRAM" | tail -8
