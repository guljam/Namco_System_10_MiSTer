#!/usr/bin/env bash
# MEM(P3) stand-in bench: s10_p3 + s10_ddr_mux + s10_p3audio against a MAME MCU RAM dump and a test-tone .p3a.
#   MCU=mcu_g13jnr.bin P3A=g13jnr.p3a SELS=10,18,20 sim/p3/run.sh
#   CAP=p3cap_g13jnr.bin REF=p3cap_g13jnr_mcu.bin P3A=g13jnr.p3a MCU=x sim/p3/run.sh   (replay a local/mame/p3cap.lua capture)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WD="${WD:-$HERE/build}"
NVC="${NVC:-/c/Users/klest/Documents/Codex/tools/nvc/PFiles/NVC/bin/nvc.exe}"
NVCF="--std=2008 --ieee-warnings=off --messages=compact"
mkdir -p "$WD"; cd "$WD"
WDW="$(cygpath -m "$WD" 2>/dev/null || echo "$WD")"
rm -rf tb
"$NVC" --work="tb:$WDW/tb" -a "$ROOT/rtl/s10_p3.sv" "$ROOT/rtl/s10_p3audio.sv" "$ROOT/rtl/s10_ddr_mux.sv"
"$NVC" $NVCF --work="tb:$WDW/tb" -a --relaxed "$HERE/tb_p3.vhd"
"$NVC" $NVCF -M 2g -H 3g --work="tb:$WDW/tb" -e tb_p3 -gMCU_IMG="$MCU" -gP3A_IMG="$P3A" -gSELS="${SELS:-10}" -gDBG="${DBG:-false}" -gHOLD="${HOLD:-0}" ${CAP:+-gCAP_IMG="$CAP" -gREF_IMG="$REF"} -gGAP="${GAP:-6}" -gDLAT="${DLAT:-4}"
"$NVC" $NVCF -M 2g -H 3g --work="tb:$WDW/tb" -r tb_p3
