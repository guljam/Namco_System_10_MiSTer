#!/usr/bin/env bash
# s10_mem against MAME: replays local/mame/<GAME>_board.bin (local/mame/boardcap.lua) and compares reads.
#   GAME=mrdrilrg sim/board/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GAME="${GAME:-mrdrilrg}"
WD="${WD:-$HERE/build_$GAME}"
NVC="${NVC:-/c/Users/klest/Documents/Codex/tools/nvc/PFiles/NVC/bin/nvc.exe}"
NVCF="--std=2008 --ieee-warnings=off --messages=compact"
mkdir -p "$WD"; cd "$WD"
WDW="$(cygpath -m "$WD" 2>/dev/null || echo "$WD")"
[ -f ddr.bin ] || python "$ROOT/scripts/s10tool.py" images "$GAME" "$WDW"
cp "$ROOT/local/mame/${GAME}_board.bin" capture.bin
rm -rf tb
"$NVC" $NVCF --work="tb:$WDW/tb" -a --relaxed "$ROOT/sim/system/globals.vhd" "$ROOT/sim/system/ddrram_model.vhd"
"$NVC" --work="tb:$WDW/tb" -a "$ROOT/rtl/s10_crypt_t1.sv" "$ROOT/rtl/s10_crypt_t2.sv" "$ROOT/rtl/s10_mem.sv" "$ROOT/rtl/s10_loader.sv"
"$NVC" $NVCF --work="tb:$WDW/tb" -a --relaxed "$HERE/tb_board.vhd"
"$NVC" $NVCF -M 2g -H 2g --work="tb:$WDW/tb" -e tb_board
"$NVC" $NVCF -M 2g -H 2g --work="tb:$WDW/tb" -r tb_board
