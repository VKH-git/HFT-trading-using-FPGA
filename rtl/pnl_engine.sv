// rtl/pnl_engine.sv  --  Day 11
// Real-time P&L tracking engine.
//
// Accumulates cash-flow equivalent P&L from exchange fill confirmations:
//   BUY  fill : running_pnl -= fill_price * fill_qty   (cash out)
//   SELL fill : running_pnl += fill_price * fill_qty   (cash in)
//
// When the book is flat (net_position = 0), running_pnl equals realised P&L.
// Unrealised P&L is left to the monitoring software which can compute:
//   unrealised = net_position * last_trade_price  (requires software multiply)
//
// The module also tracks:
//   fill_count        : total number of fills processed
//   total_buy_qty     : cumulative buy volume
//   total_sell_qty    : cumulative sell volume
//   max_drawdown_hit  : 1-cycle pulse if running_pnl < -MAX_DRAWDOWN
//
// P&L register width
// ------------------
//   Each fill: price (24-bit) * qty (16-bit) = 40-bit product.
//   Accumulate up to 2^16 fills: 40 + 16 = 56-bit.
//   Use PNL_W = 64 bits (signed) for headroom.

module pnl_engine #(
    parameter int PRICE_W     = 24,
    parameter int QTY_W       = 16,
    parameter int PNL_W       = 64,        // signed P&L accumulator width
    parameter int CNT_W       = 32,        // fill counter width
    parameter int MAX_DRAWDOWN = 1_000_000 // paise; triggers max_drawdown_hit
)(
    input  logic                clk,
    input  logic                rst_n,

    // Fill feed (exchange execution confirmations)
    input  logic                fill_valid,
    input  logic                fill_side,        // 0=BUY  1=SELL
    input  logic [PRICE_W-1:0]  fill_price,
    input  logic [QTY_W-1:0]    fill_qty,

    // P&L outputs
    output logic signed [PNL_W-1:0]  running_pnl,    // cumulative cash-flow P&L (paise)
    output logic [CNT_W-1:0]         fill_count,      // total fills processed
    output logic [CNT_W-1:0]         total_buy_qty,   // cumulative buy volume
    output logic [CNT_W-1:0]         total_sell_qty,  // cumulative sell volume
    output logic                     max_drawdown_hit // 1-cycle pulse on drawdown
);

    // ── Intermediate: price × qty product (40 bits) ───────────────────────
    logic [PRICE_W + QTY_W - 1:0] fill_notional;
    assign fill_notional = fill_price * {{QTY_W{1'b0}} | fill_qty};  // 24*16 = 40-bit

    // ── Signed extension for accumulation ─────────────────────────────────
    // Sign-extend the 40-bit notional to PNL_W bits for addition/subtraction
    logic signed [PNL_W-1:0] notional_ext;
    assign notional_ext = {{(PNL_W - PRICE_W - QTY_W){1'b0}}, fill_notional};

    // ── Drawdown check ─────────────────────────────────────────────────────
    // Fire when running_pnl goes below -MAX_DRAWDOWN (negative)
    // Use unsigned comparison trick: check sign bit and magnitude.
    // running_pnl < -MAX_DRAWDOWN  iff  running_pnl + MAX_DRAWDOWN < 0
    //                              iff  MSB of (running_pnl + MAX_DRAWDOWN) = 1
    logic signed [PNL_W-1:0] dd_check;
    assign dd_check = running_pnl + $signed(PNL_W'(MAX_DRAWDOWN));
    // drawdown hit if pnl is negative enough that even adding MAX_DRAWDOWN is still < 0
    // i.e., dd_check < 0 (MSB = 1)

    // ── Sequential accumulators ────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running_pnl      <= '0;
            fill_count       <= '0;
            total_buy_qty    <= '0;
            total_sell_qty   <= '0;
            max_drawdown_hit <= 1'b0;
        end else begin
            max_drawdown_hit <= 1'b0;   // default: no pulse

            if (fill_valid) begin
                fill_count <= fill_count + 1;

                if (!fill_side) begin
                    // BUY fill: cash out
                    running_pnl   <= running_pnl - notional_ext;
                    total_buy_qty <= total_buy_qty + CNT_W'(fill_qty);
                end else begin
                    // SELL fill: cash in
                    running_pnl    <= running_pnl + notional_ext;
                    total_sell_qty <= total_sell_qty + CNT_W'(fill_qty);
                end
            end

            // Drawdown detection (registered, 1-cycle latency after fill)
            if (dd_check[PNL_W-1])   // sign bit = 1 → pnl < -MAX_DRAWDOWN
                max_drawdown_hit <= 1'b1;
        end
    end

endmodule
