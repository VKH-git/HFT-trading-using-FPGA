// sim/tb_system.sv  --  Day 14  End-to-end integration testbench
//
// Drives the full trading_top data-path via UART serial frames and verifies
// system behaviour through the mon_* monitoring ports — no need to decode the
// outgoing TX UART stream.
//
// Fast-simulation parameters
//   CLK_FREQ  = 100 MHz (CLK_PERIOD = 10 ns)
//   BAUD_RATE = 10 MHz  -->  BIT_CYCLES = 10
//   UART frame (11 bytes): 11 * 10 bits * 10 cycles = 1100 clock cycles
//   ORDER_BOOK_DEPTH  = 8  (scan takes 8+2 = 10 cycles)
//   VWAP_THRESHOLD    = 10 paise
//   MOM_THRESHOLD     = 5  paise
//   COOLDOWN_CYCLES   = 10
//
// Packet format (packet_assembler.sv):
//   SOF 0xAA | type | OID_H OID_L | Price_H M L | Qty_H L | Side | EOF 0x55
//   type: 0x01=ADD 0x02=CANCEL 0x03=TRADE 0x04=HEARTBEAT
//
// System tests
//   SYS1  ADD BID order   -> best_bid_valid=1, best_bid_price correct
//   SYS2  ADD ASK order   -> best_ask_valid=1, best_ask_price correct
//   SYS3  TRADE frame     -> VWAP BUY signal + risk approval (sig_source=0)
//   SYS4  HEARTBEAT       -> pkt parsed, no spurious signals
//   SYS5  Fill injection  -> pnl_engine accumulates, fill_count increments
//   SYS6  Breach on next signal after position limit reached via fills
//   SYS7  Momentum SELL   -> TRADE below EMAs; fast drops faster than slow;
//                            VWAP silent; momentum SELL approved (sig_source=1)

`timescale 1ns/1ps

module tb_system;

    // ── Simulation parameters ──────────────────────────────────────────────
    localparam int CLK_FREQ_HZ     = 100_000_000;
    localparam int BAUD_RATE       = 10_000_000;    // BIT_CYCLES = 10
    localparam int BIT_CYCLES      = CLK_FREQ_HZ / BAUD_RATE;   // 10

    localparam int PRICE_W         = 24;
    localparam int QTY_W           = 16;
    localparam int POS_W           = 22;
    localparam int PNL_W           = 64;
    localparam int CNT_W           = 32;

    localparam int ORDER_BOOK_DEPTH= 8;
    localparam int VWAP_THRESHOLD  = 10;
    localparam int MOM_THRESHOLD   = 5;
    localparam int LOT_SIZE        = 100;
    localparam int COOLDOWN_CYCLES = 10;
    localparam int MAX_POSITION    = 1000;
    localparam int MAX_QTY         = 500;
    localparam int RATE_TOKENS     = 10;
    localparam int RATE_REFILL     = 50;
    localparam int PRICE_BAND      = 5000;    // wide band: don't block strategy signals
    localparam int MAX_DRAWDOWN    = 100_000_000;

    // ── Clock ──────────────────────────────────────────────────────────────
    localparam int CLK_PERIOD = 10;
    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ── DUT connections ────────────────────────────────────────────────────
    logic                    uart_rxd    = 1'b1;   // idle = HIGH
    logic                    uart_txd;

    logic                    fill_valid  = 1'b0;
    logic                    fill_side   = 1'b0;
    logic [PRICE_W-1:0]      fill_price  = '0;
    logic [QTY_W-1:0]        fill_qty    = '0;

    logic                    mon_pkt_valid;
    logic [1:0]              mon_pkt_type;
    logic                    mon_best_bid_valid;
    logic [PRICE_W-1:0]      mon_best_bid_price;
    logic                    mon_best_ask_valid;
    logic [PRICE_W-1:0]      mon_best_ask_price;
    logic                    mon_trade_valid;
    logic [PRICE_W-1:0]      mon_trade_price;
    logic                    mon_sig_valid;
    logic [1:0]              mon_sig_source;
    logic                    mon_order_valid;
    logic [3:0]              mon_breach_flags;
    logic [POS_W-1:0]        mon_net_pos_biased;
    logic signed [PNL_W-1:0] mon_running_pnl;
    logic [CNT_W-1:0]        mon_fill_count;
    logic                    mon_drawdown_hit;

    // ── DUT ────────────────────────────────────────────────────────────────
    trading_top #(
        .CLK_FREQ_HZ    (CLK_FREQ_HZ),
        .BAUD_RATE      (BAUD_RATE),
        .PRICE_W        (PRICE_W),
        .QTY_W          (QTY_W),
        .ORDER_BOOK_DEPTH(ORDER_BOOK_DEPTH),
        .VWAP_THRESHOLD (VWAP_THRESHOLD),
        .MOM_THRESHOLD  (MOM_THRESHOLD),
        .LOT_SIZE       (LOT_SIZE),
        .COOLDOWN_CYCLES(COOLDOWN_CYCLES),
        .POS_W          (POS_W),
        .MAX_POSITION   (MAX_POSITION),
        .MAX_QTY        (MAX_QTY),
        .RATE_TOKENS    (RATE_TOKENS),
        .RATE_REFILL    (RATE_REFILL),
        .PRICE_BAND     (PRICE_BAND),
        .PNL_W          (PNL_W),
        .CNT_W          (CNT_W),
        .MAX_DRAWDOWN   (MAX_DRAWDOWN)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .uart_rxd         (uart_rxd),
        .uart_txd         (uart_txd),
        .fill_valid       (fill_valid),
        .fill_side        (fill_side),
        .fill_price       (fill_price),
        .fill_qty         (fill_qty),
        .mon_pkt_valid    (mon_pkt_valid),
        .mon_pkt_type     (mon_pkt_type),
        .mon_best_bid_valid(mon_best_bid_valid),
        .mon_best_bid_price(mon_best_bid_price),
        .mon_best_ask_valid(mon_best_ask_valid),
        .mon_best_ask_price(mon_best_ask_price),
        .mon_trade_valid  (mon_trade_valid),
        .mon_trade_price  (mon_trade_price),
        .mon_sig_valid    (mon_sig_valid),
        .mon_sig_source   (mon_sig_source),
        .mon_order_valid  (mon_order_valid),
        .mon_breach_flags (mon_breach_flags),
        .mon_net_pos_biased(mon_net_pos_biased),
        .mon_running_pnl  (mon_running_pnl),
        .mon_fill_count   (mon_fill_count),
        .mon_drawdown_hit (mon_drawdown_hit)
    );

    // Event capture counters (latched by monitor always block)
    integer pkt_count   = 0;
    integer sig_count   = 0;
    integer order_count = 0;
    integer breach_count= 0;
    integer trade_ev    = 0;

    // Latch breach_flags when any bit fires (flags cleared 1 cycle later)
    logic [3:0] last_breach_flags = 4'd0;
    // Latch sig_source on every signal (sig_source=0=VWAP 1=MOM, clears when sig_valid=0)
    logic [1:0] last_sig_source   = 2'd0;

    always @(posedge clk) begin
        if (mon_pkt_valid)            pkt_count    = pkt_count    + 1;
        if (mon_sig_valid)            sig_count    = sig_count    + 1;
        if (mon_order_valid)          order_count  = order_count  + 1;
        if (|mon_breach_flags) begin
            breach_count     = breach_count + 1;
            last_breach_flags <= mon_breach_flags;   // capture which bits fired
        end
        if (mon_trade_valid)          trade_ev     = trade_ev     + 1;
        if (mon_sig_valid)            last_sig_source <= mon_sig_source;
    end

    // ── Test counters ──────────────────────────────────────────────────────
    integer tests_run    = 0;
    integer tests_passed = 0;
    integer tests_failed = 0;

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
            $display("  FAIL  %0s : got 0x%0h  expected 0x%0h",
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

    // ── Task: transmit one UART byte (8N1, LSB first) ─────────────────────
    // Drives uart_rxd directly. Each bit lasts exactly BIT_CYCLES posedges.
    task uart_send_byte;
        input [7:0] data;
        integer i;
    begin
        uart_rxd = 1'b0;                         // start bit
        repeat(BIT_CYCLES) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin
            uart_rxd = data[i];                  // data bits, LSB first
            repeat(BIT_CYCLES) @(posedge clk);
        end
        uart_rxd = 1'b1;                         // stop bit
        repeat(BIT_CYCLES) @(posedge clk);
    end
    endtask

    // ── Task: send a full 11-byte market-data frame ────────────────────────
    // pkt_type: 0=ADD 1=CAN 2=TRD 3=HB
    task send_frame;
        input [1:0]  pkt_type;
        input [15:0] order_id;
        input [23:0] price;
        input [15:0] qty;
        input        side;   // 0=BID  1=ASK
        logic [7:0]  type_byte;
    begin
        case (pkt_type)
            2'd0: type_byte = 8'h01;   // ADD
            2'd1: type_byte = 8'h02;   // CANCEL
            2'd2: type_byte = 8'h03;   // TRADE
            2'd3: type_byte = 8'h04;   // HEARTBEAT
            default: type_byte = 8'h01;
        endcase

        uart_send_byte(8'hAA);                  // SOF
        uart_send_byte(type_byte);              // type
        uart_send_byte(order_id[15:8]);         // OID MSB
        uart_send_byte(order_id[7:0]);          // OID LSB
        uart_send_byte(price[23:16]);           // price[23:16]
        uart_send_byte(price[15:8]);            // price[15:8]
        uart_send_byte(price[7:0]);             // price[7:0]
        uart_send_byte(qty[15:8]);              // qty[15:8]
        uart_send_byte(qty[7:0]);               // qty[7:0]
        uart_send_byte(side ? 8'h01 : 8'h00);  // side
        uart_send_byte(8'h55);                  // EOF
    end
    endtask

    // ── Task: wait N cycles for pipeline stages to settle ─────────────────
    task wait_settle;
        input integer n;
        integer k;
    begin
        for (k = 0; k < n; k = k + 1) @(posedge clk);
        #1;
    end
    endtask

    // ── Task: pulse one fill into the DUT ─────────────────────────────────
    task do_fill;
        input               side;
        input [PRICE_W-1:0] price;
        input [QTY_W-1:0]   qty;
    begin
        @(negedge clk);
        fill_side  = side;
        fill_price = price;
        fill_qty   = qty;
        fill_valid = 1'b1;
        @(negedge clk);
        fill_valid = 1'b0;
        @(posedge clk); #1;
    end
    endtask

    // =========================================================================
    initial begin
        $dumpfile("tb_system.vcd");
        $dumpvars(0, tb_system);

        rst_n    = 1'b0;
        uart_rxd = 1'b1;
        repeat(8) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        wait_settle(4);

        // ================================================================
        $display("\n=== SYS1: ADD BID 200@99980 -> book has best bid ===");
        // ================================================================
        // 99980 = 0x018 68C: [23:16]=0x01 [15:8]=0x86 [7:0]=0x8C
        // Verify: 0x01*65536 + 0x86*256 + 0x8C = 65536 + 34304 + 140 = 99980
        pkt_count = 0;
        send_frame(2'd0, 16'd1, 24'd99980, 16'd200, 1'b0);  // ADD BID
        wait_settle(30);   // order_book scan + write: ~10 cycles headroom

        check_eq(pkt_count,          1,       "SYS1 pkt parsed");
        check_eq(mon_best_bid_valid, 1,       "SYS1 best_bid_valid");
        check_eq(mon_best_bid_price, 99980,   "SYS1 best_bid_price=99980");

        // ================================================================
        $display("\n=== SYS2: ADD ASK 100@100020 -> book has best ask ===");
        // ================================================================
        // 100020 = 0x018 6B4: [23:16]=0x01 [15:8]=0x86 [7:0]=0xB4
        pkt_count = 0;
        send_frame(2'd0, 16'd2, 24'd100020, 16'd100, 1'b1);  // ADD ASK
        wait_settle(30);

        check_eq(pkt_count,          1,        "SYS2 pkt parsed");
        check_eq(mon_best_ask_valid, 1,        "SYS2 best_ask_valid");
        check_eq(mon_best_ask_price, 100020,   "SYS2 best_ask_price=100020");

        // ================================================================
        $display("\n=== SYS3: TRADE @ 100100 -> VWAP BUY signal + order ===");
        // ================================================================
        // After first TRADE: VWAP seeds to 100100.
        // best_ask = 100020.
        // VWAP(100100) > ask(100020) + VWAP_THRESHOLD(10) = 100030 -> BUY fires.
        // risk_gate: all checks pass (position=0, qty=LOT_SIZE=100 < 500, rate ok)
        sig_count   = 0;
        order_count = 0;
        trade_ev    = 0;

        send_frame(2'd2, 16'd0, 24'd100100, 16'd100, 1'b1);  // TRADE
        wait_settle(30);   // trade_valid + 3 pipeline stages + risk_gate

        check_nonzero(trade_ev,    "SYS3 trade_valid fired");
        check_nonzero(sig_count,   "SYS3 strategy sig_valid fired");
        check_nonzero(order_count, "SYS3 order_valid approved");
        check_eq(mon_sig_source, 2'd0, "SYS3 source=VWAP(0)");

        // ================================================================
        $display("\n=== SYS4: HEARTBEAT -> pkt parsed, no extra signals ===");
        // ================================================================
        // Cooldown is active for COOLDOWN_CYCLES=10 after SYS3.
        // Wait for cooldown to expire first.
        wait_settle(COOLDOWN_CYCLES + 5);

        pkt_count   = 0;
        sig_count   = 0;
        order_count = 0;

        // HB: order_id/price/qty/side are present in frame but ignored by order_book
        send_frame(2'd3, 16'd0, 24'd0, 16'd0, 1'b0);  // HEARTBEAT
        wait_settle(30);

        check_eq(pkt_count,   1, "SYS4 HB parsed");
        check_eq(sig_count,   0, "SYS4 no spurious strategy signal");
        check_eq(order_count, 0, "SYS4 no spurious order");
        check_eq(mon_pkt_type, 2'd3, "SYS4 pkt_type=HB(3)");

        // ================================================================
        $display("\n=== SYS5: Fill injection -> pnl_engine updates ===");
        // ================================================================
        // BUY fill at 100020 qty=100: running_pnl -= 100020*100 = -10_002_000
        do_fill(1'b0, 24'd100020, 16'd100);
        check_eq(mon_fill_count,  1,           "SYS5 fill_count=1");
        check_eq(mon_running_pnl, -10_002_000, "SYS5 running_pnl=-10002000");

        // SELL fill at 100100 qty=100: running_pnl += 100100*100 = +10_010_000
        // Net: -10_002_000 + 10_010_000 = +8_000
        do_fill(1'b1, 24'd100100, 16'd100);
        check_eq(mon_fill_count,  2,      "SYS5 fill_count=2");
        check_eq(mon_running_pnl, 8_000,  "SYS5 round-trip pnl=+8000");

        // ================================================================
        $display("\n=== SYS6: Position limit reached -> breach logged ===");
        // ================================================================
        // Position is currently at MAX_POSITION bias (= 0 actual position
        // since fills cancelled out: BUY 100 + SELL 100).
        // net_pos_biased = MAX_POSITION = 1000 (flat).
        // Drive BUY fills to push position near MAX_POSITION=1000 actual.
        // After BUY 1000 fills: biased = 1000 + 1000 = 2000 = 2*MAX_POSITION.
        // Any further BUY order (sig_qty=LOT_SIZE=100) would breach:
        //   pos_after_buy = 2000+100 > 2000 = 2*MAX_POSITION -> breach[0].

        // Reset counters
        breach_count      = 0;
        last_breach_flags <= 4'd0;
        do_fill(1'b0, 24'd100000, 16'd1000);  // BUY 1000: biased = 2000 (max long)
        wait_settle(5);

        // Wait for cooldown from SYS3 to be fully clear, then send TRADE
        // that would trigger BUY signal. Risk gate should block it.
        wait_settle(COOLDOWN_CYCLES + 5);
        send_frame(2'd2, 16'd0, 24'd100100, 16'd100, 1'b1);  // TRADE again
        wait_settle(30);

        check_nonzero(breach_count,       "SYS6 breach detected on pos limit");
        // last_breach_flags latches the flags from the cycle breach fires;
        // mon_breach_flags is already cleared (1-cycle pulse) by now
        check_eq(last_breach_flags[0], 1'b1, "SYS6 breach_flags[0]=pos");

        // ================================================================
        $display("\n=== SYS7: Momentum SELL -- flush vwap then ride momentum ===");
        // ================================================================
        // Plan: send 7 TRADE frames all at 99900 (well below vwap=100100).
        //
        // vwap progression (DECAY_SHIFT=4, alpha=1/16):
        //   After frame 1: 100087   After frame 5: 100043
        //   After frame 2: 100075   After frame 6: 100034
        //   After frame 3: 100064   After frame 7: 100025 <- below ask+10=100030
        //   After frame 4: 100053
        //
        // Signal evaluation uses the UPDATED vwap_reg (NBA from trade_valid):
        //   Frames 1-6: vwap_updated (100087..100034) > 100030 -> VWAP BUY fires
        //               pos_biased=2000, BUY blocked -> order_valid=0
        //   Frame 7:    vwap_updated 100025 < 100030  -> VWAP silent
        //               fast_reg=99926, slow_reg=100079, dn_dist=153 >= 5
        //               -> Momentum SELL fires, sig_source=1=MOM
        //               pos check: biased(2000) >= sig_qty(100) -> SELL ok
        //               -> order_valid=1
        //
        // Each frame is 1100 cycles >> COOLDOWN_CYCLES=10 -> no cooldown conflict.

        sig_count       = 0;
        order_count     = 0;
        last_sig_source <= 2'd0;

        begin : sys7_loop
            integer fi;
            for (fi = 0; fi < 7; fi = fi + 1) begin
                send_frame(2'd2, 16'd0, 24'd99900, 16'd100, 1'b1);
                wait_settle(20);
            end
        end

        check_nonzero(sig_count,              "SYS7 sig fired across 7 trades");
        check_nonzero(order_count,            "SYS7 momentum SELL approved");
        check_eq(last_sig_source, 2'd1,       "SYS7 last source=1=MOMENTUM");

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
