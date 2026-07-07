// rtl/risk_gate.sv  --  Day 10
// Pre-trade risk enforcement layer.
//
// Sits between strategy_core and order_serializer.  Every incoming signal
// from strategy_core passes four independent risk checks; ALL must pass for
// an order to be forwarded.  If any check fails, the signal is dropped and
// the corresponding breach_flag bit is latched for one cycle.
//
// Risk checks
// -----------
//  [0] Position limit  : |net_position| must not exceed MAX_POSITION after fill.
//                         Uses a biased unsigned register (bias = MAX_POSITION) to
//                         avoid signed arithmetic inside always_ff.
//  [1] Order size      : sig_qty <= MAX_QTY
//  [2] Price sanity    : |sig_price - last_trade_price| <= PRICE_BAND
//                         (skipped when last_trade_valid = 0)
//  [3] Rate limit      : token-bucket; RATE_TOKENS tokens, one refilled every
//                         RATE_REFILL cycles. Each approved order costs 1 token.
//
// Position register
// -----------------
//  net_pos_biased is unsigned with bias = MAX_POSITION.
//  actual net = net_pos_biased - MAX_POSITION
//  BUY  fill: net_pos_biased += fill_qty
//  SELL fill: net_pos_biased -= fill_qty
//  BUY  check (before order): net_pos_biased + sig_qty <= 2*MAX_POSITION
//  SELL check (before order): net_pos_biased >= sig_qty

module risk_gate #(
    parameter int PRICE_W      = 24,
    parameter int QTY_W        = 16,
    parameter int POS_W        = 22,      // bits for biased position counter
    parameter int MAX_POSITION = 1000,    // max net position (shares each direction)
    parameter int MAX_QTY      = 500,     // max single order size
    parameter int RATE_TOKENS  = 10,      // token bucket capacity
    parameter int RATE_REFILL  = 1000,    // cycles between token refills
    parameter int PRICE_BAND   = 500      // max paise deviation from last trade
)(
    input  logic                clk,
    input  logic                rst_n,

    // Incoming signal from strategy_core
    input  logic                sig_valid,
    input  logic                sig_side,        // 0=BUY  1=SELL
    input  logic [PRICE_W-1:0]  sig_price,
    input  logic [QTY_W-1:0]    sig_qty,

    // Last-trade price from order_book (price sanity reference)
    input  logic                last_trade_valid,
    input  logic [PRICE_W-1:0]  last_trade_price,

    // Approved order output (1-cycle latency from sig_valid)
    output logic                order_valid,
    output logic                order_side,
    output logic [PRICE_W-1:0]  order_price,
    output logic [QTY_W-1:0]    order_qty,

    // Fill feed (exchange execution confirmations update position)
    input  logic                fill_valid,
    input  logic                fill_side,       // 0=BUY fill  1=SELL fill
    input  logic [QTY_W-1:0]    fill_qty,

    // Monitor outputs
    output logic [POS_W-1:0]    net_pos_biased,  // actual = this - MAX_POSITION
    output logic [3:0]          breach_flags     // [3:0] = {rate,price,qty,pos}
);

    // ── Position register (unsigned, biased by MAX_POSITION) ───────────────
    logic [POS_W-1:0] net_pos_r;   // ranges 0 .. 2*MAX_POSITION
    assign net_pos_biased = net_pos_r;

    // ── Token bucket ───────────────────────────────────────────────────────
    localparam int TOK_W  = $clog2(RATE_TOKENS + 2);
    localparam int RCNT_W = $clog2(RATE_REFILL + 1);

    logic [TOK_W-1:0]  token_cnt;
    logic [RCNT_W-1:0] refill_cnt;

    // ── Risk check wires (combinatorial, all in assign) ────────────────────

    // Check 0: Position
    logic [POS_W-1:0] pos_after_buy;
    logic [POS_W-1:0] pos_after_sell_signed;   // may underflow; guarded by check
    logic             pos_ok;

    assign pos_after_buy  = net_pos_r + {{(POS_W-QTY_W){1'b0}}, sig_qty};
    // SELL check: net_pos_r >= sig_qty (so subtraction doesn't underflow)
    assign pos_ok = sig_side
        ? (net_pos_r >= {{(POS_W-QTY_W){1'b0}}, sig_qty})           // SELL: have enough
        : (pos_after_buy <= POS_W'(2 * MAX_POSITION));               // BUY: below max

    // Check 1: Order size
    logic qty_ok;
    assign qty_ok = (sig_qty <= QTY_W'(MAX_QTY));

    // Check 2: Price sanity
    logic [PRICE_W-1:0] price_dist;
    logic               price_ok;

    assign price_dist = (sig_price >= last_trade_price)
                        ? sig_price - last_trade_price
                        : last_trade_price - sig_price;
    assign price_ok   = !last_trade_valid || (price_dist <= PRICE_W'(PRICE_BAND));

    // Check 3: Rate limit
    logic rate_ok;
    assign rate_ok = (token_cnt > 0);

    // Combined gate
    logic risk_ok;
    assign risk_ok = pos_ok && qty_ok && price_ok && rate_ok;

    // ── Breach flags (1-cycle pulse per violation) ─────────────────────────
    logic [3:0] breach_next;
    assign breach_next = sig_valid ?
        { !rate_ok, !price_ok, !qty_ok, !pos_ok } : 4'd0;

    // ── tok_delta: intermediate for atomic refill+consume ─────────────────
    // Module-level integer used as blocking temp inside always_ff (iverilog safe)
    integer tok_delta;

    // ── Sequential logic ───────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            net_pos_r    <= POS_W'(MAX_POSITION);   // bias = 0 actual position
            token_cnt    <= TOK_W'(RATE_TOKENS);
            refill_cnt   <= RCNT_W'(RATE_REFILL - 1);
            order_valid  <= 1'b0;
            order_side   <= 1'b0;
            order_price  <= '0;
            order_qty    <= '0;
            breach_flags <= 4'd0;
        end else begin
            // ── Approved order output ──────────────────────────────────────
            order_valid <= sig_valid && risk_ok;
            if (sig_valid && risk_ok) begin
                order_side  <= sig_side;
                order_price <= sig_price;
                order_qty   <= sig_qty;
            end

            // ── Breach flags ───────────────────────────────────────────────
            breach_flags <= breach_next;

            // ── Token bucket (delta method: refill + consume in same cycle) ─
            tok_delta = 0;

            if (refill_cnt == 0) begin
                refill_cnt <= RCNT_W'(RATE_REFILL - 1);
                if (token_cnt < RATE_TOKENS) tok_delta = tok_delta + 1;
            end else begin
                refill_cnt <= refill_cnt - 1;
            end

            if (sig_valid && risk_ok) tok_delta = tok_delta - 1;

            token_cnt <= token_cnt + TOK_W'(tok_delta);

            // ── Position update on fill (from exchange) ────────────────────
            if (fill_valid) begin
                if (!fill_side)   // BUY fill → position goes long
                    net_pos_r <= net_pos_r + {{(POS_W-QTY_W){1'b0}}, fill_qty};
                else              // SELL fill → position goes short
                    net_pos_r <= net_pos_r - {{(POS_W-QTY_W){1'b0}}, fill_qty};
            end
        end
    end

endmodule
