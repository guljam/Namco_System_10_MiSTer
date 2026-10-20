#!/usr/bin/env bash
# s10_atapi against MAME: GAME=taiko2 DISC=local/cd/nm-002.bin sim/atapi/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GAME="${GAME:-taiko2}"
DISC="${DISC:-$ROOT/local/cd/nm-002.bin}"
WD="${WD:-$HERE/build_$GAME}"
NVC="${NVC:-/c/Users/klest/Documents/Codex/tools/nvc/PFiles/NVC/bin/nvc.exe}"
NVCF="--std=2008 --ieee-warnings=off --messages=compact"
mkdir -p "$WD"; cd "$WD"
WDW="$(cygpath -m "$WD" 2>/dev/null || echo "$WD")"
[ -f trace.txt ] || python "$HERE/prep.py" "$ROOT/local/mame/${GAME}_ata.bin" "$DISC" "$WDW"
rm -rf tb
"$NVC" --work="tb:$WDW/tb" -a "$ROOT/rtl/s10_atapi.sv"
"$NVC" $NVCF --work="tb:$WDW/tb" -a --relaxed "$HERE/tb_atapi.vhd"
"$NVC" $NVCF -M 2g -H 2g --work="tb:$WDW/tb" -e tb_atapi
"$NVC" $NVCF -M 2g -H 2g --work="tb:$WDW/tb" -r tb_atapi
