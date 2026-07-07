// sim/tb_risk_pnl.sv  --  Day 10 + 11 testbench
//
// Self-checking testbench for risk_gate.sv (Day 10) and pnl_engine.sv (Day 11).
//
// Two DUTs are instantiated and driven in sequence through separate test groups.
//
// risk_gate parameters (overridden for fast tests):
//   MAX_POSITION = 500   max ± net position
//   MAX_QTY      = 200   max single order size
//   RATE_TOKENS  = 3     token bucket depth
//   RATE_REFILL  = 20    cycles per refill (fast for simulation)
//   PRICE_BAND   = 200   paise deviation allowed
//
// pnl_engine parameters:
//   MAX_DRAWDOWN = 100_000   paise (Rs 1000.00)
//
// Risk gate tests
// ---------------
//  RG1  Clean signal passes all 4 checks
//  RG2  Position limit: BUY that would exceed MAX_POSITION → blocked [0]
//  RG3  Position limit: SELL with no position → blocked [0]
//  RG4  Order size too large → blocked [1]
//  RG5  Price outside PRICE_BAND → blocked [2]
//  RG6  Rate limit exhaustion → blocked [3]
//  RG7  Rate limit recovery after refill
//  RG8  Fill updates position; subsequent order unblocked
//  RG9  Multiple simultaneous breaches → multiple flags
//
// P&L engine tests
// ----------------
//  PL1  BUY fill decrements running_pnl
//  PL2  SELL fill increments running_pnl
//  PL3  Round-trip: BUY then SELL at higher price → positive P&L
//  PL4  fill_count increments correctly
//  PL5  total_buy_qty / total_sell_qty track correctly
//  PL6  max_drawdown_hit fires when pnl < -MAX_DRAWDOWN

`timescale 1ns/1ps

module tb_risk_pnl;

    // ── Shared parameters ──────────────────────────────────────────────────
    localparam int PRICE_W      = 24;
    localparam int QTY_W        = 16;

    // ── risk_gate parameters ───────────────────────────────────────────────
    localparam int POS_W        = 22;
    localparam int MAX_POSITION = 500;
    localparam int MAX_QTY      = 200;
    localparam int RATE_TOKENS  = 3;
    localparam int RATE_REFILL  = 20;
    localparam int PRICE_BAND   = 200;

    // ── pnl_engine parameters ──────────────────────────────────────────────
    localparam int PNL_W        = 64;
    localparam int CNT_W        = 32;
    localparam int MAX_DRAWDOWN = 100_000;   // paise

    // ── Clock ──────────────────────────────────────────────────────────────
    localparam int CLK_PERIOD = 10;
    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ── risk_gate DUT signals ──────────────────────────────────────────────
    logic                rg_sig_valid      = 1'b0;
    logic                rg_sig_side       = 1'b0;
    logic [PRICE_W-1:0]  rg_sig_price      = '0;
    logic [QTY_W-1:0]    rg_sig_qty        = '0;
    logic                rg_lt_valid       = 1'b0;
    logic [PRICE_W-1:0]  rg_lt_price       = '0;
    logic                rg_fill_valid     = 1'b0;
    logic                rg_fill_side      = 1'b0;
    logic [QTY_W-1:0]    rg_fill_qty       = '0;

    logic                rg_order_valid;
    logic                rg_order_side;
    logic [PRICE_W-1:0]  rg_order_price;
    logic [QTY_W-1:0]    rg_order_qty;
    logic [POS_W-1:0]    rg_net_pos;
    logic [3:0]          rg_breach;

    // ── risk_gate DUT ──────────────────────────────────────────────────────
    risk_gate #(
        .PRICE_W     (PRICE_W),
        .QTY_W       (QTY_W),
        .POS_W       (POS_W),
        .MAX_POSITION(MAX_POSITION),
        .MAX_QTY     (MAX_QTY),
        .RATE_TOKENS (RATE_TOKENS),
        .RATE_REFILL (RATE_REFILL),
        .PRICE_BAND  (PRICE_BAND)
    ) u_rg (
        .clk              (clk),
        .rst_n            (rst_n),
        .sig_valid        (rg_sig_valid),
        .sig_side         (rg_sig_side),
        .sig_price        (rg_sig_price),
        .sig_qty          (rg_sig_qty),
        .last_trade_valid (rg_lt_valid),
        .last_trade_price (rg_lt_price),
        .order_valid      (rg_order_valid),
        .order_side       (rg_order_side),
        .order_price      (rg_order_price),
        .order_qty        (rg_order_qty),
        .fill_valid       (rg_fill_valid),
        .fill_side        (rg_fill_side),
        .fill_qty         (rg_fill_qty),
        .net_pos_biased   (rg_net_pos),
        .breach_flags     (rg_breach)
    );

    // ── pnl_engine DUT signals ─────────────────────────────────────────────
    logic                pl_fill_valid  = 1'b0;
    logic                pl_fill_side   = 1'b0;
    logic [PRICE_W-1:0]  pl_fill_price  = '0;
    logic [QTY_W-1:0]    pl_fill_qty    = '0;

    logic signed [PNL_W-1:0] pl_running_pnl;
    logic [CNT_W-1:0]         pl_fill_count;
    logic [CNT_W-1:0]         pl_buy_qty;
    logic [CNT_W-1:0]         pl_sell_qty;
    logic                     pl_dd_hit;

    // ── pnl_engine DUT ────────────────────────────────────────────────────
    pnl_engine #(
        .PRICE_W    (PRICE_W),
        .QTY_W      (QTY_W),
        .PNL_W      (PNL_W),
        .CNT_W      (CNT_W),
        .MAX_DRAWDOWN(MAX_DRAWDOWN)
    ) u_pl (
        .clk             (clk),
        .rst_n           (rst_n),
        .fill_valid      (pl_fill_valid),
        .fill_side       (pl_fill_side),
        .fill_price      (pl_fill_price),
        .fill_qty        (pl_fill_qty),
        .running_pnl     (pl_running_pnl),
        .fill_count      (pl_fill_count),
        .total_buy_qty   (pl_buy_qty),
        .total_sell_qty  (pl_sell_qty),
        .max_drawdown_hit(pl_dd_hit)
    );

    // ── Counters ───────────────────────────────────────────────────────────
    integer tests_run    = 0;
    integer tests_passed = 0;
    integer tests_failed = 0;

    // ── Check helpers ──────────────────────────────────────────────────────
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

    task check_nonzero;
        input [63:0]  got;
        input [127:0] label;
    begin
        tests_run = tests_run + 1;
        if (got !== 0) begin
            $display("  PASS  %0s", label);
            tests_passed = tests_passed + 1;
        end else begin
            $display("  FAIL  %0s : got 0 (expected non-zero)", label);
            tests_failed = tests_failed + 1;
        end
    end
    endtask

    // ── Task: send one signal to risk_gate; wait for registered output ─────
    task rg_send;
        input               side;
        input [PRICE_W-1:0] price;
        input [QTY_W-1:0]   qty;
    begin
        @(negedge clk);
        rg_sig_side  = side;
        rg_sig_price = price;
        rg_sig_qty   = qty;
        rg_sig_valid = 1'b1;
        @(negedge clk);
        rg_sig_valid = 1'b0;
        // Timeline:
        //  posedge between the two negedges: order_valid/breach_flags NBAs fire
        //  #1 after second negedge: NBA has settled; next posedge has NOT fired yet
        //  → outputs are readable here, BEFORE they are cleared at the next posedge
        #1;
    end
    endtask

    // ── Task: inject a fill into risk_gate ────────────────────────────────
    task rg_fill;
        input               side;
        input [QTY_W-1:0]   qty;
    begin
        @(negedge clk);
        rg_fill_side  = side;
        rg_fill_qty   = qty;
        rg_fill_valid = 1'b1;
        @(negedge clk);
        rg_fill_valid = 1'b0;
        @(posedge clk); #1;
    end
    endtask

    // ── Task: inject a fill into pnl_engine ───────────────────────────────
    task pl_fill;
        input               side;
        input [PRICE_W-1:0] price;
        input [QTY_W-1:0]   qty;
    begin
        @(negedge clk);
        pl_fill_side  = side;
        pl_fill_price = price;
        pl_fill_qty   = qty;
        pl_fill_valid = 1'b1;
        @(negedge clk);
        pl_fill_valid = 1'b0;
        @(posedge clk); #1;
    end
    endtask

    // ── Task: wait N cycles ────────────────────────────────────────────────
    task wait_cycles;
        input integer n;
        integer k;
    begin
        for (k = 0; k < n; k = k + 1) @(posedge clk);
        #1;
    end
    endtask

    // =========================================================================
    initial begin
        $dumpfile("tb_risk_pnl.vcd");
        $dumpvars(0, tb_risk_pnl);

        rst_n = 1'b0;
        repeat(4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        @(posedge clk); #1;

        // ================================================================
        $display("\n=== RG1: Clean signal passes all checks ===");
        // ================================================================
        // price=100000, qty=100 (<MAX_QTY=200), no last_trade (skip sanity)
        // position=0 (<MAX_POSITION=500), tokens=3 (full)
        rg_lt_valid = 1'b0;
        rg_send(1'b0, 24'd100000, 16'd100);   // BUY
        check_eq(rg_order_valid, 1,      "RG1 order_valid=1");
        check_eq(rg_order_side,  1'b0,   "RG1 order_side=BUY");
        check_eq(rg_order_price, 100000, "RG1 order_price");
        check_eq(rg_order_qty,   100,    "RG1 order_qty");
        check_eq(rg_breach,      4'd0,   "RG1 no breach_flags");

        // ================================================================
        $display("\n=== RG2: BUY position limit breach ===");
        // ================================================================
        // Inject fills to push position to MAX_POSITION (500)
        // net_pos_biased = MAX_POSITION + 500 = 1000 = 2*MAX_POSITION
        rg_fill(1'b0, 16'd500);   // BUY 500 shares
        // Now actual position = 500 = MAX_POSITION → at the limit
        // Any additional BUY of qty=1 would breach: 500+1 > 500
        rg_send(1'b0, 24'd100000, 16'd1);   // BUY 1 → breach pos limit
        check_eq(rg_order_valid, 0,      "RG2 order blocked");
        check_eq(rg_breach[0],   1'b1,   "RG2 breach_flags[0]=pos");
        check_eq(rg_breach[3:1], 3'd0,   "RG2 no other breaches");

        // ================================================================
        $display("\n=== RG3: SELL position limit breach (no inventory) ===");
        // ================================================================
        // Reset position via fills: sell 500 to go back to flat
        rg_fill(1'b1, 16'd500);   // SELL 500 → back to 0
        // Now position = 0. SELL any qty → position goes short
        // net_pos_biased = MAX_POSITION (= 500). SELL 1: 500 >= 1 → OK, actually NOT a breach
        // We need SELL > current_long_position to breach.
        // Since position=0, biased=MAX_POSITION=500, any SELL is ok up to 500.
        // To breach: SELL 501 → biased(500) < sig_qty(501) → breach!
        rg_send(1'b1, 24'd100000, 16'd501);   // SELL 501 → breaches pos limit
        check_eq(rg_order_valid, 0,    "RG3 order blocked");
        check_eq(rg_breach[0],   1'b1, "RG3 breach_flags[0]=pos");

        // ================================================================
        $display("\n=== RG4: Order size too large ===");
        // ================================================================
        rg_send(1'b0, 24'd100000, 16'd201);   // qty=201 > MAX_QTY=200
        check_eq(rg_order_valid, 0,    "RG4 order blocked");
        check_eq(rg_breach[1],   1'b1, "RG4 breach_flags[1]=qty");
        check_eq(rg_breach[0],   1'b0, "RG4 no pos breach");

        // ================================================================
        $display("\n=== RG5: Price sanity breach ===");
        // ================================================================
        rg_lt_valid = 1'b1;
        rg_lt_price = 24'd100000;
        // sig_price = 100000 + PRICE_BAND + 1 = 100201 → breach
        rg_send(1'b0, 24'd100201, 16'd50);
        check_eq(rg_order_valid, 0,    "RG5 order blocked");
        check_eq(rg_breach[2],   1'b1, "RG5 breach_flags[2]=price");
        rg_lt_valid = 1'b0;

        // ================================================================
        $display("\n=== RG6: Rate limit exhaustion ===");
        // ================================================================
        // Tokens were 3. RG1 consumed 1 → 2 left.
        // RG2,3,4,5 were blocked (no tokens consumed on breach).
        // Send 2 more clean orders to exhaust tokens.
        rg_send(1'b0, 24'd100000, 16'd10);   // token: 2→1
        check_eq(rg_order_valid, 1, "RG6a first order passes");
        rg_send(1'b0, 24'd100000, 16'd10);   // token: 1→0
        check_eq(rg_order_valid, 1, "RG6b second order passes");
        rg_send(1'b0, 24'd100000, 16'd10);   // token: 0 → BLOCKED
        check_eq(rg_order_valid, 0,    "RG6c third order blocked (rate)");
        check_eq(rg_breach[3],   1'b1, "RG6c breach_flags[3]=rate");

        // ================================================================
        $display("\n=== RG7: Rate limit recovery after refill ===");
        // ================================================================
        // Wait RATE_REFILL+2 = 22 cycles for one token to refill
        wait_cycles(RATE_REFILL + 2);
        rg_send(1'b0, 24'd100000, 16'd10);
        check_eq(rg_order_valid, 1, "RG7 order passes after refill");

        // ================================================================
        $display("\n=== RG8: Fill updates position; next order unblocked ===");
        // ================================================================
        // Position is currently at some level from RG6a/b/RG7 orders (not filled yet,
        // because fills come from exchange, not from order_valid).
        // Position hasn't changed since we manually fill.
        // Manually fill 500 SELL to reach near the SELL limit.
        // Then inject a BUY fill to free up room.
        rg_fill(1'b1, 16'd490);   // SELL 490: biased goes down by 490
        // biased was 500 (flat from earlier fills). Now biased = 500-490 = 10.
        // actual position = 10-500 = -490 (net short 490)
        // Now SELL 15 more: SELL check: biased(10) >= sig_qty(15) → 10 < 15 → BLOCKED
        rg_send(1'b1, 24'd100000, 16'd15);
        check_eq(rg_order_valid, 0,    "RG8a SELL blocked (short limit)");
        check_eq(rg_breach[0],   1'b1, "RG8a breach_flags[0]=pos");
        // BUY fill 10 to recover position
        rg_fill(1'b0, 16'd10);   // BUY 10: biased goes up by 10 → biased=20
        // Now: biased=20 → SELL 15: 20 >= 15 → OK
        wait_cycles(1);   // position register update
        rg_send(1'b1, 24'd100000, 16'd15);
        check_eq(rg_order_valid, 1, "RG8b SELL passes after fill");

        // ================================================================
        $display("\n=== RG9: Multiple simultaneous breaches ===");
        // ================================================================
        // qty=300 (> MAX_QTY=200) AND price=100500 (PRICE_BAND breach) AND
        // rate should be OK (just used 1 token, 2 remain after refill)
        rg_lt_valid = 1'b1;
        rg_lt_price = 24'd100000;
        rg_send(1'b0, 24'd100500, 16'd300);   // qty breach + price breach
        check_eq(rg_order_valid, 0,    "RG9 order blocked");
        check_eq(rg_breach[1],   1'b1, "RG9 qty breach");
        check_eq(rg_breach[2],   1'b1, "RG9 price breach");
        rg_lt_valid = 1'b0;

        // ================================================================
        $display("\n--- P&L Engine Tests ---");
        // ================================================================

        // ================================================================
        $display("\n=== PL1: BUY fill decrements running_pnl ===");
        // ================================================================
        // BUY 100 @ 100000 paise → pnl -= 100*100000 = -10_000_000
        pl_fill(1'b0, 24'd100000, 16'd100);
        check_eq(pl_running_pnl, -10_000_000, "PL1 running_pnl = -10000000");
        check_eq(pl_fill_count,  1,            "PL1 fill_count=1");
        check_eq(pl_buy_qty,     100,           "PL1 total_buy_qty=100");
        check_eq(pl_sell_qty,    0,             "PL1 total_sell_qty=0");

        // ================================================================
        $display("\n=== PL2: SELL fill increments running_pnl ===");
        // ================================================================
        // SELL 50 @ 100200 → pnl += 50*100200 = +5_010_000
        // net: -10_000_000 + 5_010_000 = -4_990_000
        pl_fill(1'b1, 24'd100200, 16'd50);
        check_eq(pl_running_pnl, -4_990_000, "PL2 running_pnl = -4990000");
        check_eq(pl_fill_count,  2,           "PL2 fill_count=2");
        check_eq(pl_sell_qty,    50,           "PL2 total_sell_qty=50");

        // ================================================================
        $display("\n=== PL3: Round-trip with profit ===");
        // ================================================================
        // Buy 50 @ 100000, Sell 50 @ 100200 → profit = 50*(100200-100000) = 10_000
        // Current pnl = -4_990_000. Add: BUY 50@100000 → -5_000_000+(-4_990_000)= -9_990_000
        pl_fill(1'b0, 24'd100000, 16'd50);
        // Sell 50 @ 100200 → +5_010_000
        pl_fill(1'b1, 24'd100200, 16'd50);
        // Net from those 2 fills: -5_000_000 + 5_010_000 = +10_000
        // Total pnl: -4_990_000 + 10_000 = -4_980_000
        check_eq(pl_running_pnl, -4_980_000, "PL3 pnl after round-trip");

        // Now close original position: sell remaining 100 @ 100200
        // pnl += 100 * 100200 = +10_020_000
        // total: -4_980_000 + 10_020_000 = +5_040_000
        pl_fill(1'b1, 24'd100200, 16'd100);
        check_eq(pl_running_pnl, 5_040_000, "PL3 positive pnl after close");

        // ================================================================
        $display("\n=== PL4: fill_count tracks all fills ===");
        // ================================================================
        // We have done fills: PL1(1), PL2(1), PL3a(1), PL3b(1), PL3c(1) = 5 total
        check_eq(pl_fill_count, 5, "PL4 fill_count=5");

        // ================================================================
        $display("\n=== PL5: Buy/Sell qty totals ===");
        // ================================================================
        // BUY  fills: 100(PL1) + 50(PL3a) = 150
        // SELL fills: 50(PL2) + 50(PL3b) + 100(PL3c) = 200
        check_eq(pl_buy_qty,  150, "PL5 total_buy_qty=150");
        check_eq(pl_sell_qty, 200, "PL5 total_sell_qty=200");

        // ================================================================
        $display("\n=== PL6: max_drawdown_hit fires on large loss ===");
        // ================================================================
        // current pnl = +5_040_000. Need pnl < -MAX_DRAWDOWN = -100_000.
        // BUY a large notional to push pnl negative by more than 100_000.
        // BUY 1 @ 5_200_000 paise → pnl -= 5_200_000 → new pnl = -160_000
        pl_fill(1'b0, 24'd5_200_000, 16'd1);
        // After fill: pnl = 5_040_000 - 5_200_000 = -160_000
        // -160_000 < -100_000 → max_drawdown_hit should fire NEXT cycle
        @(posedge clk); #1;   // drawdown detection is 1-cycle latency
        check_eq(pl_dd_hit,       1,          "PL6 max_drawdown_hit fired");
        check_eq(pl_running_pnl, -160_000,    "PL6 running_pnl=-160000");

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
