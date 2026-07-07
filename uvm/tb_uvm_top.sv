// uvm/tb_uvm_top.sv
// Top-level module for the UVM testbench.
//
// Responsibilities:
//   1. Generate clock and drive reset
//   2. Instantiate the DUT (trading_top) and the interface (hft_if)
//   3. Publish the virtual interface to uvm_config_db
//   4. Call run_test() -- test name comes from +UVM_TESTNAME plusarg
//
// Compile order (Questa example):
//   vlog -sv +incdir+$UVM_HOME/src $UVM_HOME/src/uvm_pkg.sv
//   vlog -sv rtl/*.sv
//   vlog -sv uvm/hft_if.sv uvm/hft_pkg.sv uvm/tb_uvm_top.sv
//   vsim -sv_seed random tb_uvm_top +UVM_TESTNAME=hft_smoke_test -do "run -all"

`timescale 1ns/1ps

`include "uvm_macros.svh"

module tb_uvm_top;

    import uvm_pkg::*;
    import hft_pkg::*;

    // ── Clock ──────────────────────────────────────────────────────────────
    localparam int CLK_PERIOD = 10;   // 10 ns => 100 MHz
    logic clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ── Interface instance ─────────────────────────────────────────────────
    hft_if dut_if (.clk(clk));

    // ── DUT instance ───────────────────────────────────────────────────────
    // Parameters match the hft_pkg::BIT_CYCLES=10 (BAUD=10 MHz)
    trading_top #(
        .CLK_FREQ_HZ    (100_000_000),
        .BAUD_RATE      (10_000_000),
        .PRICE_W        (24),
        .QTY_W          (16),
        .ORDER_BOOK_DEPTH(8),
        .VWAP_THRESHOLD (10),
        .MOM_THRESHOLD  (5),
        .LOT_SIZE       (100),
        .COOLDOWN_CYCLES(10),
        .POS_W          (22),
        .MAX_POSITION   (1000),
        .MAX_QTY        (500),
        .RATE_TOKENS    (10),
        .RATE_REFILL    (50),
        .PRICE_BAND     (5000),
        .PNL_W          (64),
        .CNT_W          (32),
        .MAX_DRAWDOWN   (100_000_000)
    ) dut (
        .clk               (clk),
        .rst_n             (dut_if.rst_n),
        .uart_rxd          (dut_if.uart_rxd),
        .uart_txd          (dut_if.uart_txd),
        .fill_valid        (dut_if.fill_valid),
        .fill_side         (dut_if.fill_side),
        .fill_price        (dut_if.fill_price),
        .fill_qty          (dut_if.fill_qty),
        .mon_pkt_valid     (dut_if.mon_pkt_valid),
        .mon_pkt_type      (dut_if.mon_pkt_type),
        .mon_best_bid_valid(dut_if.mon_best_bid_valid),
        .mon_best_bid_price(dut_if.mon_best_bid_price),
        .mon_best_ask_valid(dut_if.mon_best_ask_valid),
        .mon_best_ask_price(dut_if.mon_best_ask_price),
        .mon_trade_valid   (dut_if.mon_trade_valid),
        .mon_trade_price   (dut_if.mon_trade_price),
        .mon_sig_valid     (dut_if.mon_sig_valid),
        .mon_sig_source    (dut_if.mon_sig_source),
        .mon_order_valid   (dut_if.mon_order_valid),
        .mon_breach_flags  (dut_if.mon_breach_flags),
        .mon_net_pos_biased(dut_if.mon_net_pos_biased),
        .mon_running_pnl   (dut_if.mon_running_pnl),
        .mon_fill_count    (dut_if.mon_fill_count),
        .mon_drawdown_hit  (dut_if.mon_drawdown_hit)
    );

    // ── Reset + UVM kickoff ────────────────────────────────────────────────
    initial begin
        // Initialise driven signals before reset releases
        dut_if.rst_n     = 1'b0;
        dut_if.uart_rxd  = 1'b1;   // UART idle = HIGH
        dut_if.fill_valid= 1'b0;
        dut_if.fill_side = 1'b0;
        dut_if.fill_price= '0;
        dut_if.fill_qty  = '0;

        repeat(8) @(posedge clk);
        @(negedge clk);
        dut_if.rst_n = 1'b1;

        // Publish virtual interface -- wildcard path covers all agent subcomponents
        uvm_config_db #(virtual hft_if)::set(
            null, "uvm_test_top.*", "vif", dut_if);

        // Select test via +UVM_TESTNAME=<test_class>
        run_test();
    end

    // ── Optional waveform dump (tool-agnostic) ─────────────────────────────
    initial begin
        if ($test$plusargs("WAVES")) begin
            $dumpfile("tb_uvm_top.vcd");
            $dumpvars(0, tb_uvm_top);
        end
    end

endmodule : tb_uvm_top
