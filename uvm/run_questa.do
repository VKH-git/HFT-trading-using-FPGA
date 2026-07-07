# uvm/run_questa.do
# Mentor Questa run script for the HFT UVM testbench.
# Usage:
#   questa vsim -do uvm/run_questa.do -do "run_test hft_smoke_test"
# Or source interactively:
#   vsim -c -do run_questa.do

# ── Step 1: Create work library ──────────────────────────────────────────────
quietly vlib work
quietly vmap work work

# ── Step 2: Compile UVM (skip if your tool includes UVM automatically) ───────
# Adjust $UVM_HOME to your installation path
quietly vlog -sv -O5 \
    +incdir+$env(UVM_HOME)/src \
    $env(UVM_HOME)/src/uvm_pkg.sv

# ── Step 3: Compile DUT RTL ──────────────────────────────────────────────────
quietly vlog -sv -O5 \
    ../rtl/uart_rx.sv           \
    ../rtl/uart_tx.sv           \
    ../rtl/packet_assembler.sv  \
    ../rtl/order_book.sv        \
    ../rtl/strategy_vwap.sv     \
    ../rtl/strategy_momentum.sv \
    ../rtl/strategy_core.sv     \
    ../rtl/risk_gate.sv         \
    ../rtl/pnl_engine.sv        \
    ../rtl/order_serializer.sv  \
    ../rtl/trading_top.sv

# ── Step 4: Compile UVM testbench ────────────────────────────────────────────
quietly vlog -sv -O5 \
    +incdir+$env(UVM_HOME)/src \
    hft_if.sv  \
    hft_pkg.sv \
    tb_uvm_top.sv

# ── Step 5: Helper proc to run a named test ──────────────────────────────────
proc run_test {test_name} {
    vsim -sv_seed random -quiet \
        +UVM_TESTNAME=$test_name \
        +UVM_VERBOSITY=UVM_MEDIUM \
        tb_uvm_top
    run -all
    quit -sim
}

# ── Step 6: Default: run all four tests ──────────────────────────────────────
echo "=== hft_smoke_test ===";   run_test hft_smoke_test
echo "=== hft_vwap_test ===";    run_test hft_vwap_test
echo "=== hft_breach_test ===";  run_test hft_breach_test
echo "=== hft_rand_test ===";    run_test hft_rand_test

echo "All UVM tests complete."
