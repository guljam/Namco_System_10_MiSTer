#!/bin/sh
# Run the decrypter benches with ModelSim (vlog/vsim on PATH, e.g. ModelSim-Intel 10.5b ASE).
# Vectors must exist first:  python sim/crypt/capture.py   (see README.md)
set -e
cd "$(dirname "$0")"
RTL=../../rtl
for f in vec_mrdrilr2.hex vec_mrdrilrg.hex params_mrdrilrg.hex; do
  [ -f "$f" ] || { echo "missing $f - run: python sim/crypt/capture.py"; exit 1; }
done
rm -rf work
vlib work >/dev/null
vlog -sv -work work $RTL/s10_crypt_t1.sv $RTL/s10_crypt_t2.sv tb_crypt.sv
vsim -c -GTYPE=1 work.tb_crypt +VEC=vec_mrdrilr2.hex -do "run -all; quit -f" > run_t1.log
vsim -c -GTYPE=2 work.tb_crypt +VEC=vec_mrdrilrg.hex +PARAMS=params_mrdrilrg.hex -do "run -all; quit -f" > run_t2.log
grep -h "FAIL word\|RESULT" run_t1.log run_t2.log
if grep -q "RESULT.*-> PASS" run_t1.log && grep -q "RESULT.*-> PASS" run_t2.log; then echo "ALL PASS"; else echo "FAILURES"; exit 1; fi
