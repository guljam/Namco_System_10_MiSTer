#!/usr/bin/env bash
# s10_exio NFL Classic Football serial board (SC0) bench: sim/exio/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WD="${WD:-$HERE/build}"
NVC="${NVC:-/c/Users/klest/Documents/Codex/tools/nvc/PFiles/NVC/bin/nvc.exe}"
NVCF="--std=2008 --ieee-warnings=off --messages=compact"
mkdir -p "$WD"; cd "$WD"
WDW="$(cygpath -m "$WD" 2>/dev/null || echo "$WD")"
rm -rf tb
"$NVC" --work="tb:$WDW/tb" -a "$ROOT/rtl/s10_exio.sv"
"$NVC" $NVCF --work="tb:$WDW/tb" -a --relaxed "$HERE/tb_exio_serial.vhd"
"$NVC" $NVCF --work="tb:$WDW/tb" -e tb_exio_serial
"$NVC" $NVCF --work="tb:$WDW/tb" -r tb_exio_serial
