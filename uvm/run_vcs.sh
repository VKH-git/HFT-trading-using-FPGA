#!/usr/bin/env bash
# uvm/run_vcs.sh  -- Synopsys VCS run script for HFT UVM testbench
# Usage:
#   chmod +x uvm/run_vcs.sh
#   cd hft_trading_system
#   ./uvm/run_vcs.sh [test_name]   e.g. hft_smoke_test (default)
#
# Requires: VCS with full SystemVerilog + UVM support
# Set $VCS_HOME and $UVM_HOME in your environment before running.

set -e

TEST=${1:-hft_smoke_test}
UVM_INC=${UVM_HOME:-/tools/uvm/src}
VERBOSITY=${UVM_VERBOSITY:-UVM_MEDIUM}

RTL="rtl/uart_rx.sv rtl/uart_tx.sv rtl/packet_assembler.sv \
     rtl/order_book.sv rtl/strategy_vwap.sv rtl/strategy_momentum.sv \
     rtl/strategy_core.sv rtl/risk_gate.sv rtl/pnl_engine.sv \
     rtl/order_serializer.sv rtl/trading_top.sv"

TB="uvm/hft_if.sv uvm/hft_pkg.sv uvm/tb_uvm_top.sv"

echo "====== Compiling RTL + UVM testbench ======"
vcs -full64 -sverilog -timescale=1ns/1ps \
    +incdir+${UVM_INC} \
    -ntb_opts uvm-1.2 \
    ${RTL} ${TB} \
    -o simv \
    -l compile.log

echo "====== Running test: ${TEST} ======"
./simv \
    +UVM_TESTNAME=${TEST} \
    +UVM_VERBOSITY=${VERBOSITY} \
    +ntb_random_seed_automatic \
    -l sim_${TEST}.log

echo "====== Done. Log: sim_${TEST}.log ======"
