#!/usr/bin/env bash
# Train the variational quantum classifier on the Verilog accelerator (~80 s).
# Requires: iverilog, python3 + numpy + matplotlib + scikit-learn.
set -e
cd "$(dirname "$0")"
mkdir -p sim model/vectors/batch
iverilog -g2012 -I rtl -o sim/tb_batch.vvp \
    rtl/cordic.v rtl/cmac.v rtl/gate_gen.v rtl/qpu_core.v rtl/qml_accelerator.v tb/tb_batch.v
cd model && python3 train_vqc.py
