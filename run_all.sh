#!/usr/bin/env bash
# ============================================================================
#  Build & verify the QML hardware accelerator.
#  Requires: iverilog (Icarus Verilog >= 11) and python3 + numpy.
#  Usage:  bash run_all.sh
# ============================================================================
set -e
cd "$(dirname "$0")"
IV="iverilog -g2012 -I rtl"
RTL="rtl/cordic.v rtl/cmac.v rtl/gate_gen.v rtl/qpu_core.v rtl/qml_accelerator.v"
mkdir -p sim model/vectors

echo "==== 1/4  CORDIC (rotations) ===================================="
$IV -o sim/tb_cordic.vvp rtl/cordic.v tb/tb_cordic.v
( cd model && python3 gen_cordic_vectors.py && vvp ../sim/tb_cordic.vvp && python3 check_cordic.py )

echo "==== 2/4  Gate matrix generator ================================"
$IV -o sim/tb_gate.vvp rtl/cordic.v rtl/gate_gen.v tb/tb_gate_gen.v
( cd model && python3 gen_gate_vectors.py && vvp ../sim/tb_gate.vvp && python3 check_gate_gen.py )

echo "==== 3/4  System circuits (Bell, Toffoli, gradient, ...) ======="
$IV -o sim/tb_system.vvp $RTL tb/tb_system.v
( cd model && python3 system_tests.py )

echo "==== 4/4  Randomized differential fuzz ========================="
( cd model && python3 fuzz_tests.py )

echo "================================================================"
echo " ALL VERIFICATION PASSED"
echo "================================================================"
