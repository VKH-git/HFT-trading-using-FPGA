// sim/tb_latency.sv  --  Day 15
// Order-to-wire latency measurement for the HFT trading system.
//
// Measures two intervals:
//   (A) UART_LATENCY : first bit of TRADE frame -> order_valid
//       Dominated by UART reception at the configured baud rate.
//
//   (B) PIPELINE_LATENCY : pkt_valid -> order_valid
//       Pure logic latency through order_book + strategy_core + risk_gate.
//       This is the programmable-logic contribution, independent of I/O speed.
//
// Method
// ------
//   A monitor always block records $time on pkt_valid and order_valid.
//   The initial block records $time at the instant uart_rxd first goes LOW.
//   All three timestamps are compared at the end to produce cycle counts.
//
// Expected results (BIT_CYCLES=10, CLK=100MHz)
//   UART frame         : 11 bytes x 10 bits x 10 cycles = 1100 cycles  (11 us)
//   Pipeline (A->B)    : ~4 cycles  (40 ns at 100 MHz)
//   Total (frame start -> order_valid): ~1100 cycles
//
// The pipeline breakdown is:
//   order_book  S_IDLE -> S_TRADE -> S_IDLE  : 2 cycles (TRADE is a single-state op)
//   order_book  trade_valid fires in S_TRADE : 1 cycle (combinatorial from state)
//   strategy_core trade_valid_d + signal reg : 2 cycles (2 registered stages)
//   risk_gate   order_valid register         : 1 cycle
//   Total measured from pkt_valid            : ~4 cycles (pkt_valid->order_valid)

`timescale 1ns/1ps

module tb_latency;

    // ── Timing parameters ──────────────────────────────────────────────────
    localparam int CLK_FREQ_HZ      = 100_000_000;
    localparam int BAUD_RATE        = 10_000_000;
    localparam int BIT_CYCLES       = CLK_FREQ_HZ / BAUD_RATE;   // 10
    localparam int CLK_PERIOD_NS    = 1_000_000_000 / CLK_FREQ_HZ;   // 10 ns

    // ── DUT parameters ─────────────────────────────────────────────────────
    localparam int PRICE_W          = 24;
    localparam int QTY_W            = 16;
    localparam int POS_W            = 22;
    localparam int PNL_W            = 64;
    localparam int CNT_W            = 32;
    localparam int ORDER_BOOK_DEPTH = 8;
    localparam int VWAP_THRESHOLD   = 10;
    localparam int MOM_THRESHOLD    = 5;
    localparam int LOT_SIZE         = 100;
    localparam int COOLDOWN_CYCLES  = 10;
    localparam int MAX_POSITION     = 1000;
    localparam int MAX_QTY          = 500;
    localparam int RATE_TOKENS      = 10;
    localparam int RATE_REFILL      = 50;
    localparam int PRICE_BAND       = 5000;
    localparam int MAX_DRAWDOWN     = 100_000_000;

    // ── Clock ──────────────────────────────────────────────────────────────
    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #(CLK_PERIOD_NS/2) clk = ~clk;

    // ── DUT I/O ────────────────────────────────────────────────────────────
    logic uart_rxd  = 1'b1;
    logic uart_txd;
    logic fill_valid  = 1'b0;
    logic fill_side   = 1'b0;
    logic [PRICE_W-1:0] fill_price = '0;
    logic [QTY_W-1:0]  fill_qty   = '0;

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

    // ── Timestamp capture (set by monitor, read by initial block) ──────────
    time t_frame_start  = 0;  // set by initial just before uart_rxd goes low
    time t_pkt_valid    = 0;  // set by monitor on pkt_valid
    time t_order_valid  = 0;  // set by monitor on order_valid

    always @(posedge clk) begin
        if (mon_pkt_valid   && t_pkt_valid   == 0) t_pkt_valid   = $time;
        if (mon_order_valid && t_order_valid == 0)  t_order_valid = $time;
    end

    // ── UART helpers (same as tb_system) ──────────────────────────────────
    task uart_send_byte;
        input [7:0] data;
        integer i;
    begin
        uart_rxd = 1'b0;
        repeat(BIT_CYCLES) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin
            uart_rxd = data[i];
            repeat(BIT_CYCLES) @(posedge clk);
        end
        uart_rxd = 1'b1;
        repeat(BIT_CYCLES) @(posedge clk);
    end
    endtask

    task send_frame;
        input [1:0]  pkt_type;
        input [15:0] order_id;
        input [23:0] price;
        input [15:0] qty;
        input        side;
        logic [7:0]  type_byte;
    begin
        case (pkt_type)
            2'd0: type_byte = 8'h01;
            2'd1: type_byte = 8'h02;
            2'd2: type_byte = 8'h03;
            2'd3: type_byte = 8'h04;
            default: type_byte = 8'h01;
        endcase
        uart_send_byte(8'hAA);
        uart_send_byte(type_byte);
        uart_send_byte(order_id[15:8]);
        uart_send_byte(order_id[7:0]);
        uart_send_byte(price[23:16]);
        uart_send_byte(price[15:8]);
        uart_send_byte(price[7:0]);
        uart_send_byte(qty[15:8]);
        uart_send_byte(qty[7:0]);
        uart_send_byte(side ? 8'h01 : 8'h00);
        uart_send_byte(8'h55);
    end
    endtask

    task wait_settle;
        input integer n;
        integer k;
    begin
        for (k = 0; k < n; k = k + 1) @(posedge clk);
        #1;
    end
    endtask

    // ── Derived result wires (computed at report time) ─────────────────────
    time  total_ns;
    time  uart_ns;
    time  pipeline_ns;
    integer total_cycles;
    integer uart_cycles;
    integer pipeline_cycles;

    // ── Main test ──────────────────────────────────────────────────────────
    initial begin
        $dumpfile("tb_latency.vcd");
        $dumpvars(0, tb_latency);

        // Reset
        rst_n    = 1'b0;
        uart_rxd = 1'b1;
        repeat(8) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        wait_settle(4);

        // ── Step 1: build book (BID + ASK) ────────────────────────────────
        $display("\nBuilding order book...");
        send_frame(2'd0, 16'd1, 24'd99980,  16'd200, 1'b0);  // ADD BID
        wait_settle(20);
        send_frame(2'd0, 16'd2, 24'd100020, 16'd100, 1'b1);  // ADD ASK
        wait_settle(20);

        // ── Step 2: seed VWAP with first TRADE (no order expected yet) ────
        $display("Seeding VWAP...");
        send_frame(2'd2, 16'd0, 24'd100100, 16'd100, 1'b1);  // TRADE #1
        wait_settle(COOLDOWN_CYCLES + 20);   // let cooldown expire

        // ── Step 3: arm timestamps and send the measured TRADE ─────────────
        // Reset captures for the clean measurement run
        t_pkt_valid   = 0;
        t_order_valid = 0;

        // Record frame start time BEFORE uart_rxd drops for the first bit
        @(negedge clk);
        t_frame_start = $time;   // just before uart_rxd goes LOW

        send_frame(2'd2, 16'd0, 24'd100100, 16'd100, 1'b1);  // TRADE #2
        wait_settle(30);   // pipeline settles: order_valid fires within ~6 cycles

        // ── Step 4: compute and report latencies ───────────────────────────
        total_ns    = t_order_valid - t_frame_start;
        uart_ns     = t_pkt_valid   - t_frame_start;
        pipeline_ns = t_order_valid - t_pkt_valid;

        total_cycles    = total_ns    / CLK_PERIOD_NS;
        uart_cycles     = uart_ns     / CLK_PERIOD_NS;
        pipeline_cycles = pipeline_ns / CLK_PERIOD_NS;

        $display("\n================================================");
        $display("  HFT FPGA System -- Order-to-Wire Latency");
        $display("================================================");
        $display("  Clock frequency  : %0d MHz", CLK_FREQ_HZ/1_000_000);
        $display("  UART baud rate   : %0d Mbps", BAUD_RATE/1_000_000);
        $display("  Bit period       : %0d cycles (%0d ns)",
                 BIT_CYCLES, BIT_CYCLES * CLK_PERIOD_NS);
        $display("  Frame size       : 11 bytes x 10 bits = 110 bits");
        $display("------------------------------------------------");
        $display("  (A) UART RX time          : %0d cycles  (%0d ns)",
                 uart_cycles, uart_ns);
        $display("  (B) Logic pipeline        : %0d cycles  (%0d ns)",
                 pipeline_cycles, pipeline_ns);
        $display("  TOTAL (frame->order_valid): %0d cycles  (%0d ns)",
                 total_cycles, total_ns);
        $display("------------------------------------------------");
        $display("  At production 1Mbaud (BIT_CYCLES=100):");
        $display("    UART RX  ~ %0d cycles  (%0d us)",
                 100 * 11 * 10, (100 * 11 * 10 * CLK_PERIOD_NS) / 1000);
        $display("    Pipeline ~ %0d cycles  (%0d ns)",
                 pipeline_cycles, pipeline_ns);
        $display("    Total    ~ %0d cycles  (%0d us)",
                 100*11*10 + pipeline_cycles,
                 (100*11*10 * CLK_PERIOD_NS + pipeline_ns) / 1000);
        $display("================================================");

        // ── Sanity assertions ──────────────────────────────────────────────
        if (pipeline_cycles < 10)
            $display("  PASS  Pipeline latency within spec (< 10 cycles)");
        else
            $display("  FAIL  Pipeline latency %0d cycles (expected < 10)", pipeline_cycles);

        if (total_cycles < BIT_CYCLES * 11 * 10 + 20)
            $display("  PASS  Total latency within spec (< frame + 20 cycles)");
        else
            $display("  FAIL  Total latency %0d out of bound", total_cycles);

        $finish;
    end

endmodule
