// sim/tb_order_book.sv  --  Day 6 testbench
//
// Self-checking testbench for order_book.sv.
// Expected outputs are derived from tools/reference_book.py (the golden model).
//
// Test plan
// ---------
//  Group 1  Basic scenario (mirrors feed_sender.scenario_basic)
//  Group 2  Price-level qty aggregation (two orders at same best price)
//  Group 3  Cancel best BID -> rescan -> new best
//  Group 4  Cancel best ASK -> rescan -> new best
//  Group 5  TRADE updates last_trade; book unchanged
//  Group 6  HEARTBEAT is a no-op
//  Group 7  Cancel order not in book -> graceful ignore
//  Group 8  Mid-price and spread arithmetic
//
// Timing convention
// -----------------
//  Drive inputs on NEGEDGE; sample outputs one clock after ob_ready goes high.
//  This guarantees all NBAs from the DUT's final FSM cycle have settled.

`timescale 1ns/1ps

module tb_order_book;

    // ── DUT parameters ────────────────────────────────────────────────────
    localparam int MAX_ORDERS = 64;
    localparam int PRICE_W    = 24;
    localparam int QTY_W      = 16;
    localparam int OID_W      = 16;

    // ── Message-type constants (match protocol_spec.md) ───────────────────
    localparam logic [1:0] PKT_ADD = 2'd0;
    localparam logic [1:0] PKT_CAN = 2'd1;
    localparam logic [1:0] PKT_TRD = 2'd2;
    localparam logic [1:0] PKT_HB  = 2'd3;

    localparam logic SIDE_BID = 1'b0;
    localparam logic SIDE_ASK = 1'b1;

    // ── Clock / reset ─────────────────────────────────────────────────────
    localparam int CLK_PERIOD = 10;   // 10 ns = 100 MHz

    logic clk   = 1'b0;
    logic rst_n = 1'b0;

    always #(CLK_PERIOD/2) clk = ~clk;

    // ── DUT I/O ───────────────────────────────────────────────────────────
    logic                 pkt_valid    = 1'b0;
    logic [1:0]           pkt_type     = 2'd0;
    logic [OID_W-1:0]     pkt_order_id = '0;
    logic [PRICE_W-1:0]   pkt_price    = '0;
    logic [QTY_W-1:0]     pkt_qty      = '0;
    logic                 pkt_side     = 1'b0;

    logic                 best_bid_valid;
    logic [PRICE_W-1:0]   best_bid_price;
    logic [QTY_W-1:0]     best_bid_qty;
    logic                 best_ask_valid;
    logic [PRICE_W-1:0]   best_ask_price;
    logic [QTY_W-1:0]     best_ask_qty;
    logic [PRICE_W:0]     mid_price;
    logic [PRICE_W-1:0]   spread;
    logic                 last_trade_valid;
    logic [PRICE_W-1:0]   last_trade_price;
    logic [QTY_W-1:0]     last_trade_qty;
    logic                 ob_ready;

    // ── DUT instantiation ─────────────────────────────────────────────────
    order_book #(
        .MAX_ORDERS(MAX_ORDERS),
        .PRICE_W   (PRICE_W),
        .QTY_W     (QTY_W),
        .OID_W     (OID_W)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .pkt_valid        (pkt_valid),
        .pkt_type         (pkt_type),
        .pkt_order_id     (pkt_order_id),
        .pkt_price        (pkt_price),
        .pkt_qty          (pkt_qty),
        .pkt_side         (pkt_side),
        .best_bid_valid   (best_bid_valid),
        .best_bid_price   (best_bid_price),
        .best_bid_qty     (best_bid_qty),
        .best_ask_valid   (best_ask_valid),
        .best_ask_price   (best_ask_price),
        .best_ask_qty     (best_ask_qty),
        .mid_price        (mid_price),
        .spread           (spread),
        .last_trade_valid (last_trade_valid),
        .last_trade_price (last_trade_price),
        .last_trade_qty   (last_trade_qty),
        .ob_ready         (ob_ready)
    );

    // ── Test counters (module-level for iverilog compatibility) ───────────
    integer tests_run    = 0;
    integer tests_passed = 0;
    integer tests_failed = 0;

    // Temporaries for expected values (module-level, not inside begin..end)
    integer exp_price, exp_qty;
    integer wait_cnt;

    // ── Task: check a 1-bit signal ────────────────────────────────────────
    task check_bit;
        input [63:0]  got;
        input [63:0]  expected;
        input [127:0] label;
    begin
        tests_run = tests_run + 1;
        if (got === expected) begin
            $display("  PASS  %0s", label);
            tests_passed = tests_passed + 1;
        end else begin
            $display("  FAIL  %0s : got %0d  expected %0d", label, got, expected);
            tests_failed = tests_failed + 1;
        end
    end
    endtask

    // ── Task: wait until ob_ready (with timeout) ──────────────────────────
    task wait_ob;
    begin
        wait_cnt = 0;
        while (!ob_ready && wait_cnt < 400) begin
            @(posedge clk);
            wait_cnt = wait_cnt + 1;
        end
        if (wait_cnt >= 400)
            $display("  TIMEOUT waiting for ob_ready");
        #1;   // let combinatorial outputs settle past NBA
    end
    endtask

    // ── Task: send one decoded packet frame ───────────────────────────────
    // Drive at negedge -> DUT samples at posedge -> clear at next negedge.
    task send_pkt;
        input [1:0]          typ;
        input [OID_W-1:0]    oid;
        input [PRICE_W-1:0]  price;
        input [QTY_W-1:0]    qty;
        input                side;
    begin
        @(negedge clk);
        pkt_type     = typ;
        pkt_order_id = oid;
        pkt_price    = price;
        pkt_qty      = qty;
        pkt_side     = side;
        pkt_valid    = 1'b1;
        @(negedge clk);
        pkt_valid    = 1'b0;
    end
    endtask

    // ── Task: convenient ADD / CANCEL / TRADE / HB wrappers ──────────────
    task do_add;
        input [OID_W-1:0]   oid;
        input [PRICE_W-1:0] price;
        input [QTY_W-1:0]   qty;
        input               side;
    begin
        send_pkt(PKT_ADD, oid, price, qty, side);
        wait_ob;
    end
    endtask

    task do_cancel;
        input [OID_W-1:0]   oid;
        input [PRICE_W-1:0] price;
        input               side;
    begin
        send_pkt(PKT_CAN, oid, price, 16'd0, side);
        wait_ob;
    end
    endtask

    task do_trade;
        input [PRICE_W-1:0] price;
        input [QTY_W-1:0]   qty;
        input               side;
    begin
        send_pkt(PKT_TRD, 16'd0, price, qty, side);
        wait_ob;
    end
    endtask

    task do_heartbeat;
    begin
        send_pkt(PKT_HB, 16'd0, 24'd0, 16'd0, SIDE_BID);
        wait_ob;
    end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $dumpfile("tb_order_book.vcd");
        $dumpvars(0, tb_order_book);

        // ── Reset ──────────────────────────────────────────────────────────
        rst_n = 1'b0;
        repeat(4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk); #1;

        // ================================================================
        $display("\n=== Group 1: Basic scenario (mirrors scenario_basic) ===");
        // ================================================================

        // --- Event 1: ADD BID id=1 Rs1000.00 qty=100 ---
        do_add(16'h0001, 24'd100000, 16'd100, SIDE_BID);
        check_bit(best_bid_valid,              1,      "G1E1 bb_valid");
        check_bit(best_bid_price,              100000, "G1E1 bb_price");
        check_bit(best_bid_qty,                100,    "G1E1 bb_qty");
        check_bit(best_ask_valid,              0,      "G1E1 ba_valid=0");
        check_bit(mid_price,                   0,      "G1E1 mid=0 (no ask)");
        check_bit(spread,                      0,      "G1E1 spread=0");

        // --- Event 2: ADD BID id=2 Rs999.00 qty=50 (below best) ---
        do_add(16'h0002, 24'd99900, 16'd50, SIDE_BID);
        check_bit(best_bid_price,              100000, "G1E2 bb_price unchanged");
        check_bit(best_bid_qty,                100,    "G1E2 bb_qty unchanged");

        // --- Event 3: ADD BID id=3 Rs998.00 qty=75 (below best) ---
        do_add(16'h0003, 24'd99800, 16'd75, SIDE_BID);
        check_bit(best_bid_price,              100000, "G1E3 bb_price unchanged");

        // --- Event 4: ADD ASK id=4 Rs1001.00 qty=80 ---
        do_add(16'h0004, 24'd100100, 16'd80, SIDE_ASK);
        check_bit(best_ask_valid,              1,      "G1E4 ba_valid");
        check_bit(best_ask_price,              100100, "G1E4 ba_price");
        check_bit(best_ask_qty,                80,     "G1E4 ba_qty");
        check_bit(spread,                      100,    "G1E4 spread=100");
        check_bit(mid_price,                   100050, "G1E4 mid=100050");

        // --- Event 5: ADD ASK id=5 Rs1002.00 qty=120 (worse ask) ---
        do_add(16'h0005, 24'd100200, 16'd120, SIDE_ASK);
        check_bit(best_ask_price,              100100, "G1E5 ba_price unchanged");
        check_bit(best_ask_qty,                80,     "G1E5 ba_qty unchanged");

        // --- Event 6: CANCEL id=2 (BID 999.00 -- NOT the best) ---
        do_cancel(16'h0002, 24'd99900, SIDE_BID);
        check_bit(best_bid_price,              100000, "G1E6 bb_price unchanged");
        check_bit(best_bid_qty,                100,    "G1E6 bb_qty unchanged");

        // --- Event 7: TRADE Rs1001.00 x 30 ---
        do_trade(24'd100100, 16'd30, SIDE_ASK);
        check_bit(last_trade_valid,            1,      "G1E7 lt_valid");
        check_bit(last_trade_price,            100100, "G1E7 lt_price");
        check_bit(last_trade_qty,              30,     "G1E7 lt_qty");
        check_bit(best_ask_price,              100100, "G1E7 ba_price unchanged");

        // --- Event 8: HEARTBEAT ---
        do_heartbeat;
        check_bit(best_bid_valid,              1,      "G1E8 bb_valid unchanged");
        check_bit(best_bid_price,              100000, "G1E8 bb_price unchanged");

        // ================================================================
        $display("\n=== Group 2: Qty aggregation at same price level ===");
        // ================================================================
        // State entering: BID 100000 x 100 (id=1), BID 99800 x 75 (id=3)
        //                 ASK 100100 x  80 (id=4), ASK 100200 x 120 (id=5)

        // ADD BID id=6 at SAME price as best bid (100000) -> qty += 25
        do_add(16'h0006, 24'd100000, 16'd25, SIDE_BID);
        check_bit(best_bid_price,              100000, "G2 bb_price unchanged");
        check_bit(best_bid_qty,                125,    "G2 bb_qty aggregated (100+25)");

        // ADD ASK id=7 at SAME price as best ask (100100) -> qty += 40
        do_add(16'h0007, 24'd100100, 16'd40, SIDE_ASK);
        check_bit(best_ask_price,              100100, "G2 ba_price unchanged");
        check_bit(best_ask_qty,                120,    "G2 ba_qty aggregated (80+40)");

        // ================================================================
        $display("\n=== Group 3: Cancel best BID -> full rescan ===");
        // ================================================================
        // Level 100000: id=1 (100) + id=6 (25) = 125 total
        // id=3 at 99800 qty=75

        // Cancel id=1 -> still have id=6 at 100000 -> best should stay at 100000
        do_cancel(16'h0001, 24'd100000, SIDE_BID);
        check_bit(best_bid_valid,              1,      "G3a bb_valid (id=6 remains)");
        check_bit(best_bid_price,              100000, "G3a bb_price still 100000");
        check_bit(best_bid_qty,                25,     "G3a bb_qty = 25 (only id=6)");

        // Cancel id=6 -> level 100000 now empty -> next best is id=3 at 99800
        do_cancel(16'h0006, 24'd100000, SIDE_BID);
        check_bit(best_bid_valid,              1,      "G3b bb_valid (id=3 remains)");
        check_bit(best_bid_price,              99800,  "G3b bb_price = 99800");
        check_bit(best_bid_qty,                75,     "G3b bb_qty = 75");

        // Cancel id=3 -> BID side now empty
        do_cancel(16'h0003, 24'd99800, SIDE_BID);
        check_bit(best_bid_valid,              0,      "G3c bb_valid=0 (empty)");

        // ================================================================
        $display("\n=== Group 4: Cancel best ASK -> full rescan ===");
        // ================================================================
        // ASK side: id=4 (100100 x 80) + id=7 (100100 x 40) + id=5 (100200 x 120)

        // Cancel id=4 -> level 100100 has id=7 (40) remaining -> best stays 100100
        do_cancel(16'h0004, 24'd100100, SIDE_ASK);
        check_bit(best_ask_valid,              1,      "G4a ba_valid");
        check_bit(best_ask_price,              100100, "G4a ba_price still 100100");
        check_bit(best_ask_qty,                40,     "G4a ba_qty = 40 (only id=7)");

        // Cancel id=7 -> level 100100 empty -> next best is id=5 at 100200
        do_cancel(16'h0007, 24'd100100, SIDE_ASK);
        check_bit(best_ask_valid,              1,      "G4b ba_valid");
        check_bit(best_ask_price,              100200, "G4b ba_price = 100200");
        check_bit(best_ask_qty,                120,    "G4b ba_qty = 120");

        // Cancel id=5 -> ASK side empty
        do_cancel(16'h0005, 24'd100200, SIDE_ASK);
        check_bit(best_ask_valid,              0,      "G4c ba_valid=0 (empty)");

        // ================================================================
        $display("\n=== Group 5: Mid-price and spread ===");
        // ================================================================
        // Book is currently empty. Repopulate.
        do_add(16'h0010, 24'd100000, 16'd200, SIDE_BID);
        do_add(16'h0011, 24'd100200, 16'd100, SIDE_ASK);
        check_bit(spread,                      200,    "G5 spread = 200");
        check_bit(mid_price,                   100100, "G5 mid = 100100");

        // ================================================================
        $display("\n=== Group 6: TRADE does not modify book ===");
        // ================================================================
        do_trade(24'd100200, 16'd50, SIDE_ASK);
        check_bit(last_trade_price,            100200, "G6 lt_price");
        check_bit(last_trade_qty,              50,     "G6 lt_qty");
        check_bit(best_ask_price,              100200, "G6 ba_price unchanged by TRADE");
        check_bit(best_ask_qty,                100,    "G6 ba_qty unchanged by TRADE");

        // ================================================================
        $display("\n=== Group 7: Cancel non-existent OID -> graceful ignore ===");
        // ================================================================
        do_cancel(16'hDEAD, 24'd0, SIDE_BID);   // order 0xDEAD never added
        check_bit(best_bid_valid,              1,      "G7 bb_valid unchanged");
        check_bit(best_bid_price,              100000, "G7 bb_price unchanged");

        // ================================================================
        $display("\n=== Group 8: Heartbeat is a no-op ===");
        // ================================================================
        do_heartbeat;
        check_bit(best_bid_price,              100000, "G8 bb_price unchanged");
        check_bit(best_ask_price,              100200, "G8 ba_price unchanged");
        check_bit(last_trade_price,            100200, "G8 lt_price unchanged");

        // ================================================================
        // Final report
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
