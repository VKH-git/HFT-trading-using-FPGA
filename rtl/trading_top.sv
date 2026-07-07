// rtl/trading_top.sv  --  Day 13
// Full HFT system integration.
//
// Data-path (left to right):
//   uart_rx --> packet_assembler --> order_book --> strategy_core
//                                                        |
//                                                   risk_gate --> order_serializer --> uart_tx
//
// P&L path:
//   fill_valid/side/price/qty (external) --> risk_gate (position update)
//                                        --> pnl_engine (cash-flow P&L)
//
// All intermediate buses are exported as mon_* ports for ILA / testbench
// visibility without modifying internal RTL.
//
// Port-name reference (verified against each sub-module):
//   uart_rx    : .CLK_FREQ .BAUD_RATE | .rx .rx_data .rx_valid .rx_error
//   uart_tx    : .CLK_FREQ .BAUD_RATE | .tx_data .tx_valid .tx_ready .tx .tx_busy .fifo_full
//   pkt_asm    : (no width params)   | .rx_data .rx_valid .rx_error .pkt_* .parse_error
//   order_book : .MAX_ORDERS .PRICE_W .QTY_W  (OID_W=16 default)
//   strategy_* : .PRICE_W .QTY_W ...
//   risk_gate  : .PRICE_W .QTY_W .POS_W ...
//   pnl_engine : .PRICE_W .QTY_W .PNL_W .CNT_W .MAX_DRAWDOWN
//   ord_serial : .PRICE_W .QTY_W | .tx_data .tx_valid .tx_rdy

module trading_top #(
    parameter int CLK_FREQ_HZ     = 100_000_000,
    parameter int BAUD_RATE       = 1_000_000,
    parameter int PRICE_W         = 24,
    parameter int QTY_W           = 16,
    parameter int ORDER_BOOK_DEPTH= 64,

    // Strategy
    parameter int VWAP_THRESHOLD  = 10,
    parameter int MOM_THRESHOLD   = 20,
    parameter int LOT_SIZE        = 100,
    parameter int COOLDOWN_CYCLES = 1000,

    // Risk
    parameter int POS_W           = 22,
    parameter int MAX_POSITION    = 1000,
    parameter int MAX_QTY         = 500,
    parameter int RATE_TOKENS     = 10,
    parameter int RATE_REFILL     = 1000,
    parameter int PRICE_BAND      = 500,

    // P&L
    parameter int PNL_W           = 64,
    parameter int CNT_W           = 32,
    parameter int MAX_DRAWDOWN    = 10_000_000
)(
    input  logic                     clk,
    input  logic                     rst_n,

    // Physical UART pins
    input  logic                     uart_rxd,   // feed / exchange input
    output logic                     uart_txd,   // order output to exchange

    // Exchange fill confirmations (drives position + P&L)
    input  logic                     fill_valid,
    input  logic                     fill_side,        // 0=BUY  1=SELL
    input  logic [PRICE_W-1:0]       fill_price,
    input  logic [QTY_W-1:0]         fill_qty,

    // Monitor / ILA ports (read-only snapshots of internal buses)
    output logic                     mon_pkt_valid,
    output logic [1:0]               mon_pkt_type,
    output logic                     mon_best_bid_valid,
    output logic [PRICE_W-1:0]       mon_best_bid_price,
    output logic                     mon_best_ask_valid,
    output logic [PRICE_W-1:0]       mon_best_ask_price,
    output logic                     mon_trade_valid,
    output logic [PRICE_W-1:0]       mon_trade_price,
    output logic                     mon_sig_valid,
    output logic [1:0]               mon_sig_source,
    output logic                     mon_order_valid,
    output logic [3:0]               mon_breach_flags,
    output logic [POS_W-1:0]         mon_net_pos_biased,
    output logic signed [PNL_W-1:0]  mon_running_pnl,
    output logic [CNT_W-1:0]         mon_fill_count,
    output logic                     mon_drawdown_hit
);

    // ══════════════════════════════════════════════════════════════════════
    // Stage 1 : UART RX  (CLK_FREQ / BAUD_RATE parameters)
    // ══════════════════════════════════════════════════════════════════════
    logic       rx_valid;
    logic [7:0] rx_data;
    logic       rx_error;

    uart_rx #(
        .CLK_FREQ (CLK_FREQ_HZ),
        .BAUD_RATE(BAUD_RATE)
    ) u_uart_rx (
        .clk     (clk),
        .rst_n   (rst_n),
        .rx      (uart_rxd),       // port is named 'rx', not 'rx_serial'
        .rx_data (rx_data),
        .rx_valid(rx_valid),
        .rx_error(rx_error)
    );

    // ══════════════════════════════════════════════════════════════════════
    // Stage 2 : Packet assembler  (fixed-width ports, no parameters)
    // ══════════════════════════════════════════════════════════════════════
    logic        pkt_valid;
    logic [1:0]  pkt_type;       // 0=ADD 1=CAN 2=TRD 3=HB
    logic [15:0] pkt_order_id;   // OID_W=16
    logic [23:0] pkt_price;      // 24-bit price
    logic [15:0] pkt_qty;        // 16-bit qty
    logic        pkt_side;
    logic        pkt_parse_error;

    packet_assembler u_pkt_asm (
        .clk        (clk),
        .rst_n      (rst_n),
        .rx_data    (rx_data),
        .rx_valid   (rx_valid),
        .rx_error   (rx_error),
        .pkt_valid  (pkt_valid),
        .pkt_type   (pkt_type),
        .pkt_order_id(pkt_order_id),
        .pkt_price  (pkt_price),
        .pkt_qty    (pkt_qty),
        .pkt_side   (pkt_side),
        .parse_error(pkt_parse_error)
    );

    // ══════════════════════════════════════════════════════════════════════
    // Stage 3 : Order book  (parameter is MAX_ORDERS, not DEPTH)
    // ══════════════════════════════════════════════════════════════════════
    logic                best_bid_valid;
    logic [PRICE_W-1:0]  best_bid_price;
    logic                best_ask_valid;
    logic [PRICE_W-1:0]  best_ask_price;
    logic                trade_valid;
    logic [PRICE_W-1:0]  trade_price;
    logic [QTY_W-1:0]    trade_qty;
    logic                last_trade_valid;
    logic [PRICE_W-1:0]  last_trade_price;

    order_book #(
        .MAX_ORDERS(ORDER_BOOK_DEPTH),
        .PRICE_W   (PRICE_W),
        .QTY_W     (QTY_W)
    ) u_order_book (
        .clk             (clk),
        .rst_n           (rst_n),
        .pkt_valid       (pkt_valid),
        .pkt_type        (pkt_type),
        .pkt_order_id    (pkt_order_id),
        .pkt_price       (pkt_price),
        .pkt_qty         (pkt_qty),
        .pkt_side        (pkt_side),
        .best_bid_valid  (best_bid_valid),
        .best_bid_price  (best_bid_price),
        .best_bid_qty    (),
        .best_ask_valid  (best_ask_valid),
        .best_ask_price  (best_ask_price),
        .best_ask_qty    (),
        .mid_price       (),
        .spread          (),
        .last_trade_valid(last_trade_valid),
        .last_trade_price(last_trade_price),
        .last_trade_qty  (),
        .trade_valid     (trade_valid),
        .trade_price     (trade_price),
        .trade_qty       (trade_qty),
        .ob_ready        ()
    );

    // ══════════════════════════════════════════════════════════════════════
    // Stage 4 : Strategy core
    // ══════════════════════════════════════════════════════════════════════
    logic                sig_valid;
    logic                sig_side;
    logic [PRICE_W-1:0]  sig_price;
    logic [QTY_W-1:0]    sig_qty;
    logic [1:0]          sig_source;

    strategy_core #(
        .PRICE_W        (PRICE_W),
        .QTY_W          (QTY_W),
        .VWAP_THRESHOLD (VWAP_THRESHOLD),
        .MOM_THRESHOLD  (MOM_THRESHOLD),
        .LOT_SIZE       (LOT_SIZE),
        .COOLDOWN_CYCLES(COOLDOWN_CYCLES)
    ) u_strategy_core (
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

    // ══════════════════════════════════════════════════════════════════════
    // Stage 5 : Risk gate
    // ══════════════════════════════════════════════════════════════════════
    logic                order_valid;
    logic                order_side;
    logic [PRICE_W-1:0]  order_price;
    logic [QTY_W-1:0]    order_qty;
    logic [POS_W-1:0]    net_pos_biased;
    logic [3:0]          breach_flags;

    risk_gate #(
        .PRICE_W     (PRICE_W),
        .QTY_W       (QTY_W),
        .POS_W       (POS_W),
        .MAX_POSITION(MAX_POSITION),
        .MAX_QTY     (MAX_QTY),
        .RATE_TOKENS (RATE_TOKENS),
        .RATE_REFILL (RATE_REFILL),
        .PRICE_BAND  (PRICE_BAND)
    ) u_risk_gate (
        .clk              (clk),
        .rst_n            (rst_n),
        .sig_valid        (sig_valid),
        .sig_side         (sig_side),
        .sig_price        (sig_price),
        .sig_qty          (sig_qty),
        .last_trade_valid (last_trade_valid),
        .last_trade_price (last_trade_price),
        .order_valid      (order_valid),
        .order_side       (order_side),
        .order_price      (order_price),
        .order_qty        (order_qty),
        .fill_valid       (fill_valid),
        .fill_side        (fill_side),
        .fill_qty         (fill_qty),
        .net_pos_biased   (net_pos_biased),
        .breach_flags     (breach_flags)
    );

    // ══════════════════════════════════════════════════════════════════════
    // Stage 6 : P&L engine
    // ══════════════════════════════════════════════════════════════════════
    logic signed [PNL_W-1:0] running_pnl;
    logic [CNT_W-1:0]         fill_count;
    logic [CNT_W-1:0]         total_buy_qty;
    logic [CNT_W-1:0]         total_sell_qty;
    logic                     drawdown_hit;

    pnl_engine #(
        .PRICE_W    (PRICE_W),
        .QTY_W      (QTY_W),
        .PNL_W      (PNL_W),
        .CNT_W      (CNT_W),
        .MAX_DRAWDOWN(MAX_DRAWDOWN)
    ) u_pnl_engine (
        .clk             (clk),
        .rst_n           (rst_n),
        .fill_valid      (fill_valid),
        .fill_side       (fill_side),
        .fill_price      (fill_price),
        .fill_qty        (fill_qty),
        .running_pnl     (running_pnl),
        .fill_count      (fill_count),
        .total_buy_qty   (total_buy_qty),
        .total_sell_qty  (total_sell_qty),
        .max_drawdown_hit(drawdown_hit)
    );

    // ══════════════════════════════════════════════════════════════════════
    // Stage 7 : Order serializer
    // ══════════════════════════════════════════════════════════════════════
    logic [7:0] ser_tx_data;
    logic       ser_tx_valid;
    logic       ser_tx_ready;    // uart_tx outputs tx_ready (not tx_rdy)

    order_serializer #(
        .PRICE_W(PRICE_W),
        .QTY_W  (QTY_W)
    ) u_order_serial (
        .clk        (clk),
        .rst_n      (rst_n),
        .order_valid(order_valid),
        .order_side (order_side),
        .order_price(order_price),
        .order_qty  (order_qty),
        .order_rdy  (),
        .tx_data    (ser_tx_data),
        .tx_valid   (ser_tx_valid),
        .tx_rdy     (ser_tx_ready)   // driven by uart_tx.tx_ready
    );

    // ══════════════════════════════════════════════════════════════════════
    // Stage 8 : UART TX  (tx_ready not tx_rdy; serial pin is 'tx' not 'tx_serial')
    // ══════════════════════════════════════════════════════════════════════
    uart_tx #(
        .CLK_FREQ (CLK_FREQ_HZ),
        .BAUD_RATE(BAUD_RATE)
    ) u_uart_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (ser_tx_data),
        .tx_valid (ser_tx_valid),
        .tx_ready (ser_tx_ready),
        .tx_busy  (),
        .fifo_full(),
        .tx       (uart_txd)         // serial pin is 'tx', not 'tx_serial'
    );

    // ══════════════════════════════════════════════════════════════════════
    // Monitor output assignments
    // ══════════════════════════════════════════════════════════════════════
    assign mon_pkt_valid      = pkt_valid;
    assign mon_pkt_type       = pkt_type;
    assign mon_best_bid_valid = best_bid_valid;
    assign mon_best_bid_price = best_bid_price;
    assign mon_best_ask_valid = best_ask_valid;
    assign mon_best_ask_price = best_ask_price;
    assign mon_trade_valid    = trade_valid;
    assign mon_trade_price    = trade_price;
    assign mon_sig_valid      = sig_valid;
    assign mon_sig_source     = sig_source;
    assign mon_order_valid    = order_valid;
    assign mon_breach_flags   = breach_flags;
    assign mon_net_pos_biased = net_pos_biased;
    assign mon_running_pnl    = running_pnl;
    assign mon_fill_count     = fill_count;
    assign mon_drawdown_hit   = drawdown_hit;

endmodule
