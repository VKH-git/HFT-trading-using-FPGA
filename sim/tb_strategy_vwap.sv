// sim/tb_strategy_vwap.sv  --  Day 8 testbench
//
// Self-checking testbench for strategy_vwap.sv.
//
// EWMA parameters: DECAY_SHIFT=4 (alpha=1/16), THRESHOLD=10 paise, LOT=100
//
// EWMA formula:  vwap_new = (15 * vwap_old + trade_price) >> 4
//
// Key timing:
//   Negedge N   : drive trade_valid=1
//   Posedge N+1 : DUT updates vwap_acc, sets trade_valid_d via NBA
//   Negedge N+1 : clear trade_valid
//   Posedge N+2 : DUT evaluates buy/sell using updated VWAP, registers sig_valid
//   #1 after N+2: read sig_valid, sig_side, sig_price, sig_qty
//
// Tests
// -----
//  T1  First trade initialises VWAP to exact trade price
//  T2  Identical trades keep VWAP stable
//  T3  VWAP adapts upwards when trade price is higher
//  T4  BUY fires when ask < vwap - THRESHOLD
//  T5  No BUY when ask is only slightly below VWAP (< THRESHOLD)
//  T6  SELL fires when bid > vwap + THRESHOLD
//  T7  No SELL when bid is only slightly above VWAP (< THRESHOLD)
//  T8  No signal when best_ask_valid=0 (empty book)
//  T9  BUY takes priority over SELL when both conditions hold

`timescale 1ns/1ps

module tb_strategy_vwap;

    // ── Parameters must match DUT defaults ────────────────────────────────
    localparam int PRICE_W     = 24;
    localparam int QTY_W       = 16;
    localparam int DECAY_SHIFT = 4;
    localparam int THRESHOLD   = 10;
    localparam int LOT_SIZE    = 100;
    localparam int ALPHA_COMP  = (1 << DECAY_SHIFT) - 1;   // 15

    // ── Clock ─────────────────────────────────────────────────────────────
    localparam int CLK_PERIOD = 10;
    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ── DUT ports ─────────────────────────────────────────────────────────
    logic                 best_bid_valid = 1'b0;
    logic [PRICE_W-1:0]   best_bid_price = '0;
    logic                 best_ask_valid = 1'b0;
    logic [PRICE_W-1:0]   best_ask_price = '0;

    logic                 trade_valid    = 1'b0;
    logic [PRICE_W-1:0]   trade_price    = '0;
    logic [QTY_W-1:0]     trade_qty      = '0;

    logic                 sig_valid;
    logic                 sig_side;
    logic [PRICE_W-1:0]   sig_price;
    logic [QTY_W-1:0]     sig_qty;
    logic                 vwap_valid;
    logic [PRICE_W-1:0]   vwap_price;

    // ── DUT ───────────────────────────────────────────────────────────────
    strategy_vwap #(
        .PRICE_W    (PRICE_W),
        .QTY_W      (QTY_W),
        .DECAY_SHIFT(DECAY_SHIFT),
        .THRESHOLD  (THRESHOLD),
        .LOT_SIZE   (LOT_SIZE)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .best_bid_valid(best_bid_valid),
        .best_bid_price(best_bid_price),
        .best_ask_valid(best_ask_valid),
        .best_ask_price(best_ask_price),
        .trade_valid   (trade_valid),
        .trade_price   (trade_price),
        .trade_qty     (trade_qty),
        .sig_valid     (sig_valid),
        .sig_side      (sig_side),
        .sig_price     (sig_price),
        .sig_qty       (sig_qty),
        .vwap_valid    (vwap_valid),
        .vwap_price    (vwap_price)
    );

    // ── Counters ──────────────────────────────────────────────────────────
    integer tests_run    = 0;
    integer tests_passed = 0;
    integer tests_failed = 0;

    // ── Check helper ──────────────────────────────────────────────────────
    task check_eq;
        input [63:0]  got;
        input [63:0]  expected;
        input [127:0] label;
    begin
        tests_run = tests_run + 1;
        if (got === expected) begin
            $display("  PASS  %0s", label);
            tests_passed = tests_passed + 1;
        end else begin
            $display("  FAIL  %0s : got %0d  expected %0d",
                     label, got, expected);
            tests_failed = tests_failed + 1;
        end
    end
    endtask

    // ── Task: send one trade and wait for signal evaluation ───────────────
    // Drives trade_valid at negedge, waits 3 posedges for signal to settle.
    task send_trade;
        input [PRICE_W-1:0] price;
        input [QTY_W-1:0]   qty;
    begin
        @(negedge clk);
        trade_price = price;
        trade_qty   = qty;
        trade_valid = 1'b1;
        @(negedge clk);
        trade_valid = 1'b0;
        // Timeline:
        //   posedge between the two negedges: VWAP updates, trade_valid_d <= 1
        //   NEXT posedge (@posedge clk below): sig_valid NBA = buy/sell cond
        //   #1: sig_valid readable (NBA settled)
        //   posedge AFTER that: sig_valid cleared (trade_valid_d back to 0)
        // So sample IMMEDIATELY after this one posedge — do NOT wait a second one.
        @(posedge clk);
        #1;   // past NBA: sig_valid now holds the evaluated result
    end
    endtask

    // ── Helper: compute expected VWAP after one EWMA step ─────────────────
    // Returns (15 * old + new_trade) >> 4
    function automatic [PRICE_W-1:0] expected_vwap;
        input [PRICE_W-1:0] old_vwap;
        input [PRICE_W-1:0] new_trade;
        integer acc;
    begin
        acc = ALPHA_COMP * old_vwap + new_trade;
        expected_vwap = acc >> DECAY_SHIFT;
    end
    endfunction

    // ── Expected VWAP scratch ─────────────────────────────────────────────
    logic [PRICE_W-1:0] exp_vwap;

    // =========================================================================
    initial begin
        $dumpfile("tb_strategy_vwap.vcd");
        $dumpvars(0, tb_strategy_vwap);

        // Reset
        rst_n = 1'b0;
        repeat(4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        @(posedge clk); #1;

        // Set book defaults (book is crossed/empty initially)
        best_bid_valid = 1'b0;
        best_ask_valid = 1'b0;
        best_bid_price = '0;
        best_ask_price = '0;

        // ================================================================
        $display("\n=== T1: First trade initialises VWAP ===");
        // ================================================================
        check_eq(vwap_valid, 0, "T1 vwap_valid=0 before first trade");

        send_trade(24'd100000, 16'd500);   // price=Rs1000.00

        check_eq(vwap_valid, 1,      "T1 vwap_valid after trade");
        check_eq(vwap_price, 100000, "T1 vwap_price = 100000 (exact init)");
        check_eq(sig_valid,  0,      "T1 no signal (book empty)");

        // ================================================================
        $display("\n=== T2: Identical trades keep VWAP stable ===");
        // ================================================================
        repeat(4) send_trade(24'd100000, 16'd200);   // VWAP should stay 100000
        exp_vwap = 100000;
        check_eq(vwap_price, exp_vwap, "T2 VWAP stable at 100000 after identical trades");

        // ================================================================
        $display("\n=== T3: VWAP adapts upward with high-price trade ===");
        // ================================================================
        // After one trade at 100160 (160 paise above 100000):
        // new_vwap = (15*100000 + 100160) >> 4 = 1600160 >> 4 = 100010
        send_trade(24'd100160, 16'd100);
        exp_vwap = expected_vwap(24'd100000, 24'd100160);  // = 100010
        check_eq(vwap_price, exp_vwap, "T3 VWAP moved up to 100010");

        // Restore VWAP to 100000 for clean subsequent tests
        // Send many trades at 100000 to pull VWAP back down
        repeat(16) send_trade(24'd100000, 16'd100);
        // After 16 trades at 100000 from 100010, VWAP converges back to 100000
        check_eq(vwap_price, 24'd100000, "T3 VWAP restored to 100000");

        // ================================================================
        $display("\n=== T4: BUY fires when ask < VWAP - THRESHOLD ===");
        // ================================================================
        // VWAP=100000, THRESHOLD=10
        // ask=99980: dist = 100000-99980 = 20 >= 10 -> BUY expected
        best_ask_valid = 1'b1;
        best_ask_price = 24'd99980;
        best_bid_valid = 1'b0;

        send_trade(24'd100000, 16'd100);   // VWAP stays 100000; triggers evaluation

        check_eq(sig_valid, 1,      "T4 sig_valid=1 (BUY)");
        check_eq(sig_side,  1'b0,   "T4 sig_side=BUY");
        check_eq(sig_price, 99980,  "T4 sig_price=best_ask");
        check_eq(sig_qty,   LOT_SIZE,"T4 sig_qty=LOT_SIZE");

        // ================================================================
        $display("\n=== T5: No BUY when ask only slightly below VWAP ===");
        // ================================================================
        // ask=99995: dist = 100000-99995 = 5 < 10 -> no signal
        best_ask_price = 24'd99995;
        send_trade(24'd100000, 16'd100);
        check_eq(sig_valid, 0, "T5 no signal (dist=5 < THRESHOLD=10)");

        // ================================================================
        $display("\n=== T6: SELL fires when bid > VWAP + THRESHOLD ===");
        // ================================================================
        // VWAP=100000, bid=100020: dist=20 >= 10 -> SELL expected
        best_ask_valid = 1'b0;
        best_bid_valid = 1'b1;
        best_bid_price = 24'd100020;

        send_trade(24'd100000, 16'd100);

        check_eq(sig_valid, 1,      "T6 sig_valid=1 (SELL)");
        check_eq(sig_side,  1'b1,   "T6 sig_side=SELL");
        check_eq(sig_price, 100020, "T6 sig_price=best_bid");
        check_eq(sig_qty,   LOT_SIZE,"T6 sig_qty=LOT_SIZE");

        // ================================================================
        $display("\n=== T7: No SELL when bid only slightly above VWAP ===");
        // ================================================================
        best_bid_price = 24'd100005;  // dist=5 < THRESHOLD
        send_trade(24'd100000, 16'd100);
        check_eq(sig_valid, 0, "T7 no signal (dist=5 < THRESHOLD=10)");

        // ================================================================
        $display("\n=== T8: No signal when book is empty ===");
        // ================================================================
        best_bid_valid = 1'b0;
        best_ask_valid = 1'b0;
        send_trade(24'd100000, 16'd100);
        check_eq(sig_valid, 0, "T8 no signal when book empty");

        // ================================================================
        $display("\n=== T9: BUY takes priority when both conditions hold ===");
        // ================================================================
        // Both ask below VWAP AND bid above VWAP (crossed book scenario)
        best_ask_valid = 1'b1;  best_ask_price = 24'd99975;   // 25 below vwap
        best_bid_valid = 1'b1;  best_bid_price = 24'd100030;  // 30 above vwap
        send_trade(24'd100000, 16'd100);
        check_eq(sig_valid, 1,   "T9 sig_valid=1");
        check_eq(sig_side,  1'b0,"T9 BUY takes priority over SELL");

        // ================================================================
        $display("\n=== T10: sig_valid is 0 on cycles without trade ===");
        // ================================================================
        // Wait several cycles with no trade; sig_valid must stay low
        best_ask_price = 24'd99975;   // condition still true
        repeat(5) @(posedge clk);
        #1;
        check_eq(sig_valid, 0, "T10 sig_valid stays 0 between trades");

        // ================================================================
        $display("\n========================================");
        $display("  Tests  : %0d", tests_run);
        $display("  Passed : %0d", tests_passed);
        $display("  Failed : %0d", tests_failed);
        if (tests_failed == 0)
            $display("  RESULT :  ALL TESTS PASSED");
        else
            $display("  RESULT :  *** FAILURES DETECTED ***");
        $display("========================================");
        $finish;
    end

endmodule
