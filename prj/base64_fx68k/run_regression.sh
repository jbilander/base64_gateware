#!/bin/sh
# Build once, run every workload. Non-zero exit if any check fails.
set -e
verilator --binary -j 4 -Wno-fatal --top-module tb --Mdir obj_bench -o tb \
    tb_base64.sv base64_top_6x.sv fastmem_zii.v sdram_ctrl.v \
    sdram_model_checked.v oddr_stub.v fx68k_pkg.sv fx68kAlu.sv uaddrPla.sv \
    fx68kRegs_generic.sv fx68kRom_generic.sv fx68k.sv
fail=0
for w in 0 1 2 3 4; do
    printf "workload %s: " "$w"
    if ./obj_bench/tb "+workload=$w" 2>&1 | grep -q "RESULT: PASS"; then
        echo PASS
    else
        echo FAIL; fail=1
    fi
done
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "REGRESSION"; exit 1; }
