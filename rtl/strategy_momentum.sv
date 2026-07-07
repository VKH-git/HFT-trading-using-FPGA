// rtl/strategy_momentum.sv  --  Day 9
// Dual-EWMA momentum (trend-following) strategy.
//
// Two exponential moving averages track the trade price stream:
//   fast_vwap : responds quickly  (alpha = 1/2^FAST_SHIFT, default 1/4)
//   slow_vwap : responds slowly   (alpha = 1/2^SLOW_SHIFT, default 1/64)
//
// Signal logic (fires once per trade event, opposite to VWAP mean-reversion):
//   BUY  : fast > slow + THRESHOLD  -- upward momentum; ride the trend up
//   SELL : slow > fast + THRESHOLD  -- downward momentum; ride the trend down
//
// No division: update uses (ALPHA_COMP * old + new) >> SHIFT, same as strategy_vwap.

module strategy_momentum #(
    parameter int PRICE_W    = 24,
    parameter int QTY_W      = 16,
    parameter int FAST_SHIFT = 2,    // alpha = 1/4   (responds in ~4 trades)
    parameter int SLOW_SHIFT = 6,    // alpha = 1/64  (responds in ~64 trades)
    parameter int THRESHOLD  = 20,   // paise distance before signal fires
    parameter int LOT_SIZE   = 100
)(
    input  logic                clk,
    input  logic                rst_n,

    input  logic                best_bid_valid,
    input  logic [PRICE_W-1:0]  best_bid_price,
    input  logic                best_ask_valid,
    input  logic [PRICE_W-1:0]  best_ask_price,

    input  logic                trade_valid,
    input  logic [PRICE_W-1:0]  trade_price,
    input  logic [QTY_W-1:0]    trade_qty,

    output logic                sig_valid,
    output logic                sig_side,
    output logic [PRICE_W-1:0]  sig_price,
    output logic [QTY_W-1:0]    sig_qty,

    output logic                mom_valid,     // 1 once both EMAs are seeded
    output logic [PRICE_W-1:0]  fast_price,    // current fast EMA (monitor)
    output logic [PRICE_W-1:0]  slow_price     // current slow EMA (monitor)
);

    // ── EWMA constants ─────────────────────────────────────────────────────
    localparam int FAST_AC = (1 << FAST_SHIFT) - 1;   // 3  for FAST_SHIFT=2
    localparam int SLOW_AC = (1 << SLOW_SHIFT) - 1;   // 63 for SLOW_SHIFT=6

    // Wide accumulators to hold intermediate products
    localparam int FACC_W = PRICE_W + FAST_SHIFT;   // 26 bits
    localparam int SACC_W = PRICE_W + SLOW_SHIFT;   // 30 bits

    // ── Internal EMA registers ─────────────────────────────────────────────
    logic [PRICE_W-1:0] fast_reg, slow_reg;
    logic               fast_init, slow_init;

    // ── EWMA wires (continuous assignment — avoids iverilog always_* issues) ─
    logic [FACC_W-1:0]  fast_mult, fast_sum;
    logic [SACC_W-1:0]  slow_mult, slow_sum;
    logic [PRICE_W-1:0] fast_next, slow_next;

    assign fast_mult = FAST_AC * {{FAST_SHIFT{1'b0}}, fast_reg};
    assign fast_sum  = fast_mult + {{FAST_SHIFT{1'b0}}, trade_price};
    assign fast_next = fast_sum[FACC_W-1 : FAST_SHIFT];

    assign slow_mult = SLOW_AC * {{SLOW_SHIFT{1'b0}}, slow_reg};
    assign slow_sum  = slow_mult + {{SLOW_SHIFT{1'b0}}, trade_price};
    assign slow_next = slow_sum[SACC_W-1 : SLOW_SHIFT];

    // ── Signal condition wires ─────────────────────────────────────────────
    logic [PRICE_W-1:0] up_dist, dn_dist;
    logic               buy_cond, sell_cond;

    assign up_dist  = (fast_init && slow_init && fast_reg > slow_reg)
                      ? fast_reg - slow_reg : '0;
    assign dn_dist  = (fast_init && slow_init && slow_reg > fast_reg)
                      ? slow_reg - fast_reg : '0;

    assign buy_cond  = best_ask_valid && (up_dist >= THRESHOLD);
    assign sell_cond = best_bid_valid && (dn_dist >= THRESHOLD);

    // ── Delayed trade_valid ────────────────────────────────────────────────
    logic trade_valid_d;

    // ── EMA state update ───────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fast_reg      <= '0;  slow_reg      <= '0;
            fast_init     <= 1'b0; slow_init     <= 1'b0;
            trade_valid_d <= 1'b0;
        end else begin
            trade_valid_d <= trade_valid;
            if (trade_valid) begin
                if (!fast_init) begin fast_reg <= trade_price; fast_init <= 1'b1; end
                else             fast_reg <= fast_next;

                if (!slow_init) begin slow_reg <= trade_price; slow_init <= 1'b1; end
                else             slow_reg <= slow_next;
            end
        end
    end

    // ── Monitor outputs ────────────────────────────────────────────────────
    assign mom_valid  = fast_init & slow_init;
    assign fast_price = fast_reg;
    assign slow_price = slow_reg;

    // ── Signal registration (1 cycle after EMA update) ────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sig_valid <= 1'b0; sig_side <= 1'b0;
            sig_price <= '0;   sig_qty  <= '0;
        end else begin
            sig_valid <= 1'b0;
            if (trade_valid_d) begin
                if (buy_cond) begin
                    sig_valid <= 1'b1;   sig_side  <= 1'b0;
                    sig_price <= best_ask_price;
                    sig_qty   <= QTY_W'(LOT_SIZE);
                end else if (sell_cond) begin
                    sig_valid <= 1'b1;   sig_side  <= 1'b1;
                    sig_price <= best_bid_price;
                    sig_qty   <= QTY_W'(LOT_SIZE);
                end
            end
        end
    end

endmodule
