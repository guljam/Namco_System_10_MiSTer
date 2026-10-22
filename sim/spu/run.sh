#!/usr/bin/env bash
# SPU replay: sim/spu/run.sh CAPTURE [TEND_CYCLES]   (capture from spucap.lua)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WD="${WD:-$HERE/build}"
NVC="${NVC:-/c/Users/klest/Documents/Codex/tools/nvc/PFiles/NVC/bin/nvc.exe}"
NVCF="--std=2008 --ieee-warnings=off --messages=compact"
SYSB="${SYSB:-$ROOT/sim/system/build10_taiko2}"
mkdir -p "$WD"; cd "$WD"
WDW="$(cygpath -m "$WD" 2>/dev/null || echo "$WD")"
SYSBW="$(cygpath -m "$SYSB" 2>/dev/null || echo "$SYSB")"
python "$HERE/prep.py" "$1" "$WDW"
rm -rf stb
"$NVC" $NVCF --work="stb:$WDW/stb" -L "$SYSBW" -a --relaxed "$HERE/tb_spu.vhd"
"$NVC" $NVCF -M 2g -H 2g --work="stb:$WDW/stb" -L "$SYSBW" -e tb_spu -gTEND="${2:-0}" -gTSTART="${TSTART:-0}" -gDLAT="${DLAT:-4}"
"$NVC" $NVCF -M 2g -H 2g --work="stb:$WDW/stb" -L "$SYSBW" -r tb_spu 2>&1 | tail -30
