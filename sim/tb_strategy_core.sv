// sim/tb_strategy_core.sv  --  Day 9 testbench
//
// Self-checking testbench for strategy_core.sv.
//
// DUT parameters (overridden for fast simulation):
//   VWAP_THRESHOLD  = 10 paise
//   MOM_THRESHOLD   = 5  paise    (smaller so momentum fires after ~1 trade)
//   COOLDOWN_CYCLES = 10          (very short for fast simulation)
//
// Pipeline latency through strategy_core (vs direct strategy_vwap):
//   Negedge N       : trade_valid=1
//   Posedge N+1     : EMA update, trade_valid_d<=1   (layer 1: strategy internals)
//   Negedge N+1     : trade_valid=0
//   Posedge N+2     : sv[] registered (layer 1 output) -- strategy_core reads OLD sv[]=0
//   Posedge N+3     : strategy_core reads new sv[], fires sig_valid
//   #1              : readable
// --> send_trade task must wait TWO posedges after clearing trade_valid.
//
// Tests
// -----
//   T1  VWAP BUY signal forwarded (momentum quiescent)
//   T2  Momentum BUY forwarded when VWAP threshold not met
//   T3  VWAP takes priority when both strategies fire simultaneously
//   T4  Cooldown: signal blocked within COOLDOWN_CYCLES; recovers after expiry
//   T5  VWAP SELL forwarded correctly (bid above VWAP)
//   T6  sig_source encodes which strategy won (0=VWAP, 1=MOM)

`timescale 1ns/1ps

module tb_strategy_core;

    // ── Parameters ─────────────────────────────────────────────────────────
    localparam int PRICE_W         = 24;
    localparam int QTY_W           = 16;
    localparam int VWAP_THRESHOLD  = 10;
    localparam int MOM_THRESHOLD   = 5;
    localparam int LOT_SIZE        = 100;
    localparam int COOLDOWN_CYCLES = 10;

    // ── Clock ──────────────────────────────────────────────────────────────
    localparam int CLK_PERIOD = 10;
    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ── DUT ports ──────────────────────────────────────────────────────────
    logic                best_bid_valid = 1'b0;
    logic [PRICE_W-1:0]  best_bid_price = '0;
    logic                best_ask_valid = 1'b0;
    logic [PRICE_W-1:0]  best_ask_price = '0;

    logic                trade_valid    = 1'b0;
    logic [PRICE_W-1:0]  trade_price    = '0;
    logic [QTY_W-1:0]    trade_qty      = '0;

    logic                sig_valid;
    logic                sig_side;
    logic [PRICE_W-1:0]  sig_price;
    logic [QTY_W-1:0]    sig_qty;
    logic [1:0]          sig_source;

    // ── DUT ────────────────────────────────────────────────────────────────
    strategy_core #(
        .PRICE_W        (PRICE_W),
        .QTY_W          (QTY_W),
        .VWAP_THRESHOLD (VWAP_THRESHOLD),
        .MOM_THRESHOLD  (MOM_THRESHOLD),
        .LOT_SIZE       (LOT_SIZE),
        .COOLDOWN_CYCLES(COOLDOWN_CYCLES)
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
        .sig_source    (sig_source)
    );

    // ── Counters ───────────────────────────────────────────────────────────
    integer tests_run    = 0;
    integer tests_passed = 0;
    integer tests_failed = 0;

    // ── Check helper ───────────────────────────────────────────────────────
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

    // ── Task: send one trade and wait for strategy_core output ────────────
    // Extra pipeline stage vs strategy_vwap direct: needs 2 posedges not 1.
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
        // Posedge N+2: sv[] registered by strategies (strategy_core reads OLD 0)
        @(posedge clk);
        // Posedge N+3: strategy_core reads new sv[], fires sig_valid
        @(posedge clk);
        #1;   // NBA settled
    end
    endtask

    // ── Task: seed both EMAs to a stable price (no signals) ───────────────
    // With DECAY_SHIFT=2 (fast) and DECAY_SHIFT=6 (slow), enough iterations
    // will drive both EMAs to the target price exactly (since same-price trades
    // keep (ALPHA_COMP * P + P) >> SHIFT = P for any P).
    // We disable bid/ask during seeding so no signals fire.
    task seed_emas;
        input [PRICE_W-1:0] price;
        input integer        n_trades;
        integer k;
    begin
        best_ask_valid = 1'b0;
        best_bid_valid = 1'b0;
        for (k = 0; k < n_trades; k = k + 1)
            send_trade(price, 16'd0);
    end
    endtask

    // ── Task: wait for cooldown to expire ──────────────────────────────────
    // Waits COOLDOWN_CYCLES + 3 extra posedges for safety margin.
    task wait_cooldown;
        integer k;
    begin
        for (k = 0; k < COOLDOWN_CYCLES + 3; k = k + 1)
            @(posedge clk);
        #1;
    end
    endtask

    // ─────────────────────────────────────────────────────────────────────
    initial begin
        $dumpfile("tb_strategy_core.vcd");
        $dumpvars(0, tb_strategy_core);

        // Reset
        rst_n = 1'b0;
        repeat(4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        @(posedge clk); #1;

        // ================================================================
        $display("\n=== T1: VWAP BUY forwarded (momentum quiescent) ===");
        // ================================================================
        // Seed all EMAs to 100000 (same-price trades => EMA stays constant)
        seed_emas(24'd100000, 5);

        // Ask is 25 paise below VWAP (100000-99975=25 > VWAP_THRESHOLD=10) → VWAP BUY
        // Momentum: fast=slow=100000, diff=0 < MOM_THRESHOLD=5  → no momentum signal
        best_ask_valid = 1'b1;
        best_ask_price = 24'd99975;
        best_bid_valid = 1'b0;

        send_trade(24'd100000, 16'd100);   // VWAP stays 100000

        check_eq(sig_valid,  1,       "T1 sig_valid=1");
        check_eq(sig_side,   1'b0,    "T1 sig_side=BUY");
        check_eq(sig_price,  99975,   "T1 sig_price=best_ask");
        check_eq(sig_qty,    LOT_SIZE,"T1 sig_qty=LOT_SIZE");
        check_eq(sig_source, 2'd0,    "T1 sig_source=VWAP(0)");

        // ================================================================
        $display("\n=== T2: Momentum BUY forwarded (VWAP threshold not met) ===");
        // ================================================================
        wait_cooldown;

        // Re-seed to 100000 (restores any drift from T1's VWAP trade)
        seed_emas(24'd100000, 6);

        // Ask = 99997: dist from VWAP(100000) = 3 < VWAP_THRESHOLD=10  → no VWAP BUY
        // Trade at 100100: fast => (3*100000+100100)/4 = 100025
        //                  slow => (63*100000+100100)/64 = 100001
        //                  fast-slow = 24 >= MOM_THRESHOLD=5  → MOM BUY fires
        // (VWAP_new = (15*100000+100100)/16 = 100006; 100006-99997=9 < 10 → VWAP quiet)
        best_ask_valid = 1'b1;
        best_ask_price = 24'd99997;
        best_bid_valid = 1'b0;

        send_trade(24'd100100, 16'd100);

        check_eq(sig_valid,  1,       "T2 sig_valid=1");
        check_eq(sig_side,   1'b0,    "T2 sig_side=BUY");
        check_eq(sig_source, 2'd1,    "T2 sig_source=MOM(1)");
        check_eq(sig_price,  99997,   "T2 sig_price=best_ask");

        // ================================================================
        $display("\n=== T3: VWAP takes priority over Momentum ===");
        // ================================================================
        wait_cooldown;
        seed_emas(24'd100000, 6);

        // Trade at 100100 causes: VWAP=100006 (dist to ask=99975 is 31>10 → VWAP BUY)
        //                          fast=100025, slow=100001 (diff=24>5 → MOM BUY)
        // Both fire; VWAP (index 0) wins the priority chain.
        best_ask_valid = 1'b1;
        best_ask_price = 24'd99975;   // 25 below VWAP → VWAP fires
        best_bid_valid = 1'b0;

        send_trade(24'd100100, 16'd100);

        check_eq(sig_valid,  1,    "T3 sig_valid=1");
        check_eq(sig_source, 2'd0, "T3 VWAP wins priority over MOM");
        check_eq(sig_side,   1'b0, "T3 BUY from VWAP");

        // ================================================================
        $display("\n=== T4: Cooldown blocks repeated signals ===");
        // ================================================================
        // T3 just fired, cooldown is active (COOLDOWN_CYCLES=10)
        // Immediately send another trade under same conditions → blocked
        best_ask_valid = 1'b1;
        best_ask_price = 24'd99975;

        send_trade(24'd100000, 16'd100);

        check_eq(sig_valid, 0, "T4a second signal blocked by cooldown");

        // Wait for cooldown to expire, then fire again
        wait_cooldown;
        // Re-seed so VWAP is still ~100000 and fires cleanly
        seed_emas(24'd100000, 4);
        best_ask_valid = 1'b1;
        best_ask_price = 24'd99975;

        send_trade(24'd100000, 16'd100);

        check_eq(sig_valid, 1, "T4b signal fires after cooldown expires");

        // ================================================================
        $display("\n=== T5: VWAP SELL forwarded ===");
        // ================================================================
        wait_cooldown;
        seed_emas(24'd100000, 5);

        // bid = 100020: bid-VWAP = 20 > VWAP_THRESHOLD=10 → VWAP SELL
        // best_ask_valid=0 so no BUY
        best_ask_valid = 1'b0;
        best_bid_valid = 1'b1;
        best_bid_price = 24'd100020;

        send_trade(24'd100000, 16'd100);

        check_eq(sig_valid,  1,       "T5 SELL sig_valid=1");
        check_eq(sig_side,   1'b1,    "T5 sig_side=SELL");
        check_eq(sig_price,  100020,  "T5 sig_price=best_bid");
        check_eq(sig_source, 2'd0,    "T5 sig_source=VWAP(0)");

        // ================================================================
        $display("\n=== T6: No signal when book is empty ===");
        // ================================================================
        wait_cooldown;
        seed_emas(24'd100000, 3);
        best_ask_valid = 1'b0;
        best_bid_valid = 1'b0;

        send_trade(24'd100000, 16'd100);
        check_eq(sig_valid, 0, "T6 no signal when book empty");

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
