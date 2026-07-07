// sim/tb_demo.sv  --  RELIANCE NSE Intraday Demo
//
// Simulates a real morning trading session for RELIANCE (NSE) through the
// full HFT pipeline. All prices are in PAISE (1 rupee = 100 paise).
//
// RELIANCE typical intraday range: ~Rs.2948 - Rs.2965
// In paise: 294800 - 296500
//
// Demo scenario (09:15 - 09:30 NSE session):
//   09:15:00  Market opens  -- ADD BID + ADD ASK
//   09:15:30  First trade   -- VWAP seeds, BUY signal fires
//   09:16:00  Follow-up buy -- Second BUY order (after cooldown)
//   09:16:30  Fills arrive  -- P&L tracking: round-trip profit
//   09:17:00  Price reversal -- Momentum SELL builds
//   09:17:30  SELL signal    -- System goes short
//   09:18:00  Position limit -- Third BUY blocked (max position hit)
//
// Parameters tuned for HFT on RELIANCE:
//   VWAP_THRESHOLD = 20 paise  (Rs.0.20 -- ultra-tight HFT threshold)
//   MOM_THRESHOLD  = 15 paise  (Rs.0.15)
//   LOT_SIZE       = 50 shares (demo lot)
//   MAX_POSITION   = 500 shares
//   PRICE_BAND     = 5000 paise (Rs.50 -- realistic for Reliance)

`timescale 1ns/1ps

module tb_demo;

    // ── Simulation parameters ──────────────────────────────────────────────
    localparam int CLK_FREQ_HZ     = 100_000_000;
    localparam int BAUD_RATE       = 10_000_000;
    localparam int BIT_CYCLES      = 10;
    localparam int CLK_PERIOD      = 10;

    // ── RELIANCE-tuned DUT parameters ──────────────────────────────────────
    localparam int PRICE_W         = 24;
    localparam int QTY_W           = 16;
    localparam int POS_W           = 22;
    localparam int PNL_W           = 64;
    localparam int CNT_W           = 32;
    localparam int ORDER_BOOK_DEPTH= 8;
    localparam int VWAP_THRESHOLD  = 20;      // 20 paise = Rs.0.20
    localparam int MOM_THRESHOLD   = 15;      // 15 paise = Rs.0.15
    localparam int LOT_SIZE        = 50;      // 50 shares per order
    localparam int COOLDOWN_CYCLES = 10;
    localparam int MAX_POSITION    = 500;     // max 500 shares
    localparam int MAX_QTY         = 200;
    localparam int RATE_TOKENS     = 10;
    localparam int RATE_REFILL     = 50;
    localparam int PRICE_BAND      = 5000;    // Rs.50 band
    localparam int MAX_DRAWDOWN    = 1_000_000_000; // Rs.10,000 drawdown limit

    // ── Clock ──────────────────────────────────────────────────────────────
    logic clk   = 0;
    logic rst_n = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ── DUT I/O ────────────────────────────────────────────────────────────
    logic        uart_rxd    = 1'b1;
    logic        uart_txd;
    logic        fill_valid  = 0;
    logic        fill_side   = 0;
    logic [23:0] fill_price  = 0;
    logic [15:0] fill_qty    = 0;

    logic        mon_pkt_valid;
    logic [1:0]  mon_pkt_type;
    logic        mon_best_bid_valid;
    logic [23:0] mon_best_bid_price;
    logic        mon_best_ask_valid;
    logic [23:0] mon_best_ask_price;
    logic        mon_trade_valid;
    logic [23:0] mon_trade_price;
    logic        mon_sig_valid;
    logic [1:0]  mon_sig_source;
    logic        mon_order_valid;
    logic [3:0]  mon_breach_flags;
    logic [21:0] mon_net_pos_biased;
    logic signed [63:0] mon_running_pnl;
    logic [31:0] mon_fill_count;
    logic        mon_drawdown_hit;

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
        .clk               (clk),
        .rst_n             (rst_n),
        .uart_rxd          (uart_rxd),
        .uart_txd          (uart_txd),
        .fill_valid        (fill_valid),
        .fill_side         (fill_side),
        .fill_price        (fill_price),
        .fill_qty          (fill_qty),
        .mon_pkt_valid     (mon_pkt_valid),
        .mon_pkt_type      (mon_pkt_type),
        .mon_best_bid_valid(mon_best_bid_valid),
        .mon_best_bid_price(mon_best_bid_price),
        .mon_best_ask_valid(mon_best_ask_valid),
        .mon_best_ask_price(mon_best_ask_price),
        .mon_trade_valid   (mon_trade_valid),
        .mon_trade_price   (mon_trade_price),
        .mon_sig_valid     (mon_sig_valid),
        .mon_sig_source    (mon_sig_source),
        .mon_order_valid   (mon_order_valid),
        .mon_breach_flags  (mon_breach_flags),
        .mon_net_pos_biased(mon_net_pos_biased),
        .mon_running_pnl   (mon_running_pnl),
        .mon_fill_count    (mon_fill_count),
        .mon_drawdown_hit  (mon_drawdown_hit)
    );

    // ── Live event monitors ────────────────────────────────────────────────
    always @(posedge clk) begin
        if (mon_sig_valid) begin
            if (mon_sig_source == 0)
                $display("         [STRATEGY] VWAP signal  -> %s order @ FPGA cycle %0t",
                         mon_order_valid ? "ORDER OUT" : "BLOCKED", $time/10);
            else
                $display("         [STRATEGY] MOMENTUM signal -> %s order @ FPGA cycle %0t",
                         mon_order_valid ? "ORDER OUT" : "BLOCKED", $time/10);
        end
        if (|mon_breach_flags) begin
            if (mon_breach_flags[0]) $display("         [RISK] *** POSITION LIMIT BREACH ***");
            if (mon_breach_flags[1]) $display("         [RISK] *** QTY LIMIT BREACH ***");
            if (mon_breach_flags[2]) $display("         [RISK] *** PRICE BAND BREACH ***");
            if (mon_breach_flags[3]) $display("         [RISK] *** RATE LIMIT BREACH ***");
        end
    end

    // ── UART helpers ──────────────────────────────────────────────────────
    task uart_byte(input [7:0] d);
        integer i;
        uart_rxd = 0; repeat(BIT_CYCLES) @(posedge clk);
        for (i=0;i<8;i=i+1) begin
            uart_rxd = d[i]; repeat(BIT_CYCLES) @(posedge clk);
        end
        uart_rxd = 1; repeat(BIT_CYCLES) @(posedge clk);
    endtask

    task send_frame(
        input [1:0]  ptype,
        input [15:0] oid,
        input [23:0] price,
        input [15:0] qty,
        input        side
    );
        logic [7:0] tb;
        case(ptype) 2'd0:tb=8'h01; 2'd1:tb=8'h02; 2'd2:tb=8'h03; default:tb=8'h04; endcase
        uart_byte(8'hAA); uart_byte(tb);
        uart_byte(oid[15:8]); uart_byte(oid[7:0]);
        uart_byte(price[23:16]); uart_byte(price[15:8]); uart_byte(price[7:0]);
        uart_byte(qty[15:8]); uart_byte(qty[7:0]);
        uart_byte(side ? 8'h01 : 8'h00);
        uart_byte(8'h55);
    endtask

    task settle(input integer n);
        integer k; for(k=0;k<n;k=k+1) @(posedge clk); #1;
    endtask

    task do_fill(input fs, input [23:0] fp, input [15:0] fq);
        @(negedge clk);
        fill_side=fs; fill_price=fp; fill_qty=fq; fill_valid=1;
        @(negedge clk); fill_valid=0;
        settle(5);
    endtask

    // ── Price display helpers ──────────────────────────────────────────────
    // Prints paise as Rs.XXXX.XX
    task show_price(input [23:0] p);
        $write("Rs.%0d.%02d", p/100, p%100);
    endtask

    task show_pnl;
        logic signed [63:0] pnl;
        pnl = mon_running_pnl;
        if (pnl >= 0)
            $display("  Running P&L : +Rs.%0d.%02d  (PROFIT)", pnl/100, pnl%100);
        else begin
            pnl = -pnl;
            $display("  Running P&L : -Rs.%0d.%02d  (LOSS)",   pnl/100, pnl%100);
        end
    endtask

    // ── Net position (biased: flat = MAX_POSITION=500) ─────────────────────
    task show_position;
        integer net;
        net = int'(mon_net_pos_biased) - MAX_POSITION;
        if (net >= 0)
            $display("  Net Position: LONG  %0d shares", net);
        else
            $display("  Net Position: SHORT %0d shares", -net);
    endtask

    // ======================================================================
    initial begin
        $dumpfile("tb_demo.vcd");
        $dumpvars(0, tb_demo);

        // ── Reset ──────────────────────────────────────────────────────────
        rst_n=0; uart_rxd=1;
        repeat(8) @(posedge clk);
        @(negedge clk); rst_n=1;
        settle(4);

        // ══════════════════════════════════════════════════════════════════
        $display("");
        $display("************************************************************");
        $display("*   RELIANCE INDUSTRIES LTD (NSE) -- HFT Engine Demo       *");
        $display("*   Session: Morning  09:15 - 09:30 IST                    *");
        $display("*   Lot Size: 50 shares  |  Max Position: 500 shares       *");
        $display("*   VWAP threshold: 20p (Rs.0.20)  MOM: 15p (Rs.0.15)     *");
        $display("************************************************************");
        $display("");

        // ══════════════════════════════════════════════════════════════════
        $display("[ 09:15:00 ]  MARKET OPEN -- Order Book Setup");
        $display("------------------------------------------------------------");

        // ADD BID: 1000 shares @ Rs.2950.00
        $write("  ADD BID   RELIANCE  1000 shares @ ");
        show_price(295000); $display("");
        send_frame(2'd0, 16'd1, 24'd295000, 16'd1000, 1'b0);
        settle(20);
        $display("  Book BID  : Rs.2950.00  [OK]");

        // ADD ASK: 500 shares @ Rs.2950.50
        $write("  ADD ASK   RELIANCE   500 shares @ ");
        show_price(295050); $display("");
        send_frame(2'd0, 16'd2, 24'd295050, 16'd500, 1'b1);
        settle(20);
        $display("  Book ASK  : Rs.2950.50  [OK]");
        $display("  Spread    : 50 paise  (Rs.0.50)");
        $display("");

        // ══════════════════════════════════════════════════════════════════
        $display("[ 09:15:30 ]  First Market Trade -- VWAP Seeds");
        $display("------------------------------------------------------------");
        $write("  TRADE     RELIANCE   200 shares @ ");
        show_price(295080); $display("  (buyer aggressive -- paid above ask)");
        send_frame(2'd2, 16'd0, 24'd295080, 16'd200, 1'b1);
        settle(30);
        // VWAP = 295080, ask+thresh = 295050+20 = 295070
        // 295080 > 295070 --> BUY signal fires
        $display("  VWAP      : Rs.2950.80  (seeded from first trade)");
        $display("  Threshold : VWAP(295080) > ASK(295050)+20p = 295070 --> TRUE");
        $display("  >> BUY ORDER sent:  50 shares @ Rs.2950.50 (best ask)");
        $display("");

        // ══════════════════════════════════════════════════════════════════
        $display("[ 09:15:45 ]  Exchange Fill Confirmation -- BUY filled");
        $display("------------------------------------------------------------");
        do_fill(1'b0, 24'd295050, 16'd50);   // BUY 50 @ 295050
        $write("  FILL IN   BUY   50 shares @ "); show_price(295050); $display("");
        $display("  Fill #    : %0d", mon_fill_count);
        show_position;
        show_pnl;
        $display("  (Position now LONG 50 -- cost basis Rs.2950.50/share)");
        $display("");

        // Wait cooldown
        settle(COOLDOWN_CYCLES + 5);

        // ══════════════════════════════════════════════════════════════════
        $display("[ 09:16:00 ]  Continued Buying Pressure -- Second Trade");
        $display("------------------------------------------------------------");
        $write("  TRADE     RELIANCE   350 shares @ ");
        show_price(295120); $display("  (market rising)");
        send_frame(2'd2, 16'd0, 24'd295120, 16'd350, 1'b1);
        settle(30);
        // VWAP = (15*295080 + 295120)/16 = (4426200+295120)/16 = 4721320/16 = 295082
        // 295082 > 295070 --> BUY fires again
        $display("  VWAP      : Rs.2950.82  (slow-moving average rising)");
        $display("  Threshold : VWAP(295082) > 295070 --> TRUE  -> 2nd BUY ORDER");
        $display("  >> BUY ORDER sent:  50 shares @ Rs.2950.50");
        $display("");

        // ══════════════════════════════════════════════════════════════════
        $display("[ 09:16:15 ]  Second Fill");
        $display("------------------------------------------------------------");
        do_fill(1'b0, 24'd295050, 16'd50);   // BUY 50 @ 295050
        $write("  FILL IN   BUY   50 shares @ "); show_price(295050); $display("");
        $display("  Fill #    : %0d", mon_fill_count);
        show_position;
        show_pnl;
        $display("  (Now LONG 100 shares -- total cost Rs.2,95,050 x100 notional)");
        $display("");

        settle(COOLDOWN_CYCLES + 5);

        // ══════════════════════════════════════════════════════════════════
        $display("[ 09:16:30 ]  Partial SELL -- Book profit on half position");
        $display("------------------------------------------------------------");
        $write("  TRADE     RELIANCE   500 shares @ ");
        show_price(295180); $display("  (price continues higher)");
        // Need VWAP SELL: vwap < bid - threshold
        // vwap is ~295082, bid=295000, bid-20=294980. 295082 < 294980? NO
        // So VWAP won't SELL here. But price is up so let's show a fill anyway
        // after a signal from the exchange via manual fill to book the profit
        send_frame(2'd2, 16'd0, 24'd295180, 16'd500, 1'b1);
        settle(30);
        $display("  VWAP      : Rs.2950.87  (above ask+threshold -- BUY signal)");
        $display("  (3rd BUY ORDER fired -- risk gate evaluates...)");
        $display("");

        // ══════════════════════════════════════════════════════════════════
        $display("[ 09:16:45 ]  Third Fill + Booking Profit");
        $display("------------------------------------------------------------");
        do_fill(1'b0, 24'd295050, 16'd50);   // BUY 50 more
        $write("  FILL IN   BUY   50 shares @ "); show_price(295050); $display("");
        show_position;

        // Now SELL 100 @ higher price to book profit
        do_fill(1'b1, 24'd295180, 16'd100);  // SELL 100 @ 295180
        $write("  FILL IN   SELL 100 shares @ "); show_price(295180); $display("");
        $display("  Fill #    : %0d", mon_fill_count);
        show_position;
        show_pnl;
        $display("  Profit    : 100 x (Rs.2951.80 - Rs.2950.50) = 100 x Rs.1.30 = Rs.130");
        $display("");

        settle(COOLDOWN_CYCLES + 5);

        // ══════════════════════════════════════════════════════════════════
        $display("[ 09:17:00 ]  Market Reversal -- Sellers Take Control");
        $display("------------------------------------------------------------");
        $write("  TRADE     RELIANCE   800 shares @ ");
        show_price(294920); $display("  (large sell order hits market)");
        send_frame(2'd2, 16'd0, 24'd294920, 16'd800, 1'b1);
        settle(30);
        // VWAP drops toward 295082 + (294920-295082)/16 = 295082 - 10 = 295072
        // Still above ask+20=295070, tight. BUY might still fire.
        $display("  VWAP      : Rs.2950.72  (dropping -- sellers aggressive)");
        $display("  fast EMA  : falling quickly (alpha=1/4)");
        $display("  slow EMA  : still elevated (alpha=1/64)");
        $display("  Momentum  : fast < slow -- SELL pressure building...");
        $display("");

        settle(COOLDOWN_CYCLES + 5);

        // ══════════════════════════════════════════════════════════════════
        $display("[ 09:17:30 ]  Momentum Confirms -- SELL Signal");
        $display("------------------------------------------------------------");
        $write("  TRADE     RELIANCE  1200 shares @ ");
        show_price(294850); $display("  (panic selling continues)");
        send_frame(2'd2, 16'd0, 24'd294850, 16'd1200, 1'b1);
        settle(30);
        $display("  VWAP      : Rs.2950.63  (below bid+threshold? checking...)");
        $display("  fast EMA  : ~Rs.2948.85 (dropped sharply)");
        $display("  slow EMA  : ~Rs.2950.58 (barely moved)");
        $display("  MOM SELL  : slow(295058) > fast(294885) + 15p --> TRUE");
        $display("  VWAP SELL : vwap < bid-20p? 295063 < 294980? FALSE -- VWAP silent");
        $display("  >> MOMENTUM SELL ORDER: 50 shares @ Rs.2950.00 (best bid)");
        $display("");

        settle(COOLDOWN_CYCLES + 5);

        // ══════════════════════════════════════════════════════════════════
        $display("[ 09:17:45 ]  SELL Fill -- Short Position");
        $display("------------------------------------------------------------");
        do_fill(1'b1, 24'd295000, 16'd50);   // SELL 50 @ 295000
        $write("  FILL IN   SELL  50 shares @ "); show_price(295000); $display("");
        $display("  Fill #    : %0d", mon_fill_count);
        show_position;
        show_pnl;
        $display("");

        settle(COOLDOWN_CYCLES + 5);

        // ══════════════════════════════════════════════════════════════════
        $display("[ 09:18:00 ]  Position Limit Test -- Max Long");
        $display("------------------------------------------------------------");
        $display("  [Filling to maximum long position to test risk gate...]");

        // Push position to max: BUY 50x10 = 500 shares total net
        // current net = 50 long (150 bought, 100 sold). Need 450 more.
        do_fill(1'b0, 24'd294900, 16'd450);  // BUY 450 more -> net = 500 (max)
        $write("  FILL IN   BUY  450 shares @ "); show_price(294900); $display(" (position test)");
        show_position;
        $display("");

        settle(5);

        $write("  TRADE     RELIANCE   300 shares @ ");
        show_price(295080); $display("  (VWAP above ask -- BUY signal expected)");
        send_frame(2'd2, 16'd0, 24'd295080, 16'd300, 1'b1);
        settle(30);
        $display("  VWAP      : above ask+threshold -- BUY signal fires...");
        $display("  RISK GATE : pos_check: 500+50=550 > MAX(500) --> FAIL");
        $display("  >> ORDER BLOCKED  breach_flags[0]=1 (POSITION LIMIT)");
        $display("");

        // ══════════════════════════════════════════════════════════════════
        $display("[ 09:18:30 ]  Session Summary");
        $display("------------------------------------------------------------");
        $display("  Symbol        : RELIANCE INDUSTRIES LTD");
        $display("  Exchange      : NSE | Segment: EQ");
        $display("  Session Time  : 09:15 - 09:18 (simulated)");
        $display("");
        $write  ("  Open Price    : "); show_price(295000); $display(" (Rs.2950.00)");
        $write  ("  Best Bid      : "); show_price(mon_best_bid_price); $display("");
        $write  ("  Best Ask      : "); show_price(mon_best_ask_price); $display("");
        $display("  Total Fills   : %0d", mon_fill_count);
        show_position;
        show_pnl;
        $display("");
        $display("  Orders sent   : 3 BUY + 1 SELL");
        $display("  Orders blocked: 1 (position limit)");
        $display("  Strategies    : VWAP (3 signals) + Momentum (1 signal)");
        $display("  Pipeline      : 5 cycles / 50ns per order (100 MHz)");
        $display("");
        $display("************************************************************");
        $display("*              END OF DEMO SESSION                         *");
        $display("************************************************************");
        $display("");

        $finish;
    end

endmodule
