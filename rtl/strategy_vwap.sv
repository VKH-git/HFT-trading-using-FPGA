// rtl/strategy_vwap.sv  --  Day 8
// VWAP (Volume-Weighted Average Price) mean-reversion strategy.
//
// Algorithm
// ---------
// Maintains an Exponential Weighted Moving Average of the trade price:
//
//   vwap_new = (ALPHA_COMP * vwap_old + trade_price) >> DECAY_SHIFT
//
// where ALPHA_COMP = 2^DECAY_SHIFT - 1  (e.g. 15 for DECAY_SHIFT=4).
// This is alpha = 1/2^DECAY_SHIFT, with no divider in the RTL.
//
// Signal generation (one cycle after each VWAP update)
// ----------------------------------------------------
//   BUY  : best_ask < VWAP - THRESHOLD  (ask is cheap vs VWAP → buy)
//   SELL : best_bid > VWAP + THRESHOLD  (bid is rich vs VWAP  → sell)
//   BUY takes priority when both hold simultaneously.
//
// Note on iverilog-12 compatibility
// ----------------------------------
// Constant part-selects inside always_* are broken in iverilog-12
// ("constant selects in always_* processes not currently supported").
// All intermediate arithmetic is therefore expressed as continuous
// assign statements so only non-blocking assignments appear in always_ff.

module strategy_vwap #(
    parameter int PRICE_W     = 24,
    parameter int QTY_W       = 16,
    parameter int DECAY_SHIFT = 4,     // EWMA alpha = 1 / 2^DECAY_SHIFT  (1/16)
    parameter int THRESHOLD   = 10,    // paise min distance from VWAP to signal
    parameter int LOT_SIZE    = 100    // fixed shares per order
)(
    input  logic                clk,
    input  logic                rst_n,

    // Level-1 book snapshot (from order_book, stable between events)
    input  logic                best_bid_valid,
    input  logic [PRICE_W-1:0]  best_bid_price,
    input  logic                best_ask_valid,
    input  logic [PRICE_W-1:0]  best_ask_price,

    // Trade feed (one-cycle pulse per trade, from order_book)
    input  logic                trade_valid,
    input  logic [PRICE_W-1:0]  trade_price,
    input  logic [QTY_W-1:0]    trade_qty,      // reserved for future weighted VWAP

    // Strategy output (one-cycle pulse when a signal is generated)
    output logic                sig_valid,
    output logic                sig_side,        // 0=BUY  1=SELL
    output logic [PRICE_W-1:0]  sig_price,       // exec price: best_ask(BUY) / best_bid(SELL)
    output logic [QTY_W-1:0]    sig_qty,

    // Monitor outputs (visible on logic analyser / monitor.py)
    output logic                vwap_valid,      // high after first trade seen
    output logic [PRICE_W-1:0]  vwap_price       // current EWMA in paise
);

    // ── Constants ─────────────────────────────────────────────────────────
    // ACC_W: extra bits needed before the final right-shift.
    // ALPHA_COMP = 2^DECAY_SHIFT - 1   (= 15 when DECAY_SHIFT=4)
    localparam int ACC_W      = PRICE_W + DECAY_SHIFT;   // 28 bits
    localparam int ALPHA_COMP = (1 << DECAY_SHIFT) - 1;  // 15

    // ── Internal VWAP register ────────────────────────────────────────────
    logic [PRICE_W-1:0] vwap_reg;   // current EWMA VWAP
    logic               vwap_init;  // 1 after first trade

    // ── EWMA intermediate wires (continuous assignment, no always_* issue) ─
    // ewma_mult = ALPHA_COMP * vwap_reg   (zero-padded to ACC_W)
    // ewma_sum  = ewma_mult + trade_price (ACC_W bits)
    // ewma_next = ewma_sum >> DECAY_SHIFT = ewma_sum[ACC_W-1:DECAY_SHIFT]
    //           = upper PRICE_W bits after the shift
    //
    // All indices (ACC_W-1, DECAY_SHIFT, PRICE_W) are elaboration-time constants.
    logic [ACC_W-1:0]   ewma_mult;
    logic [ACC_W-1:0]   ewma_sum;
    logic [PRICE_W-1:0] ewma_next;

    assign ewma_mult = ALPHA_COMP * {{DECAY_SHIFT{1'b0}}, vwap_reg};
    assign ewma_sum  = ewma_mult + {{DECAY_SHIFT{1'b0}}, trade_price};
    // Right-shift by DECAY_SHIFT: take bits [ACC_W-1 : DECAY_SHIFT]
    assign ewma_next = ewma_sum[ACC_W-1 : DECAY_SHIFT];

    // ── Signal condition wires ────────────────────────────────────────────
    // Evaluated continuously; sampled into sig_* registers on trade_valid_d.
    logic [PRICE_W-1:0] ask_dist;   // vwap_reg - best_ask_price (if vwap > ask)
    logic [PRICE_W-1:0] bid_dist;   // best_bid_price - vwap_reg (if bid > vwap)
    logic               buy_cond;
    logic               sell_cond;

    assign ask_dist  = (vwap_init && best_ask_valid && vwap_reg > best_ask_price)
                       ? vwap_reg - best_ask_price : '0;
    assign bid_dist  = (vwap_init && best_bid_valid && best_bid_price > vwap_reg)
                       ? best_bid_price - vwap_reg : '0;

    assign buy_cond  = (ask_dist >= THRESHOLD);
    assign sell_cond = (bid_dist >= THRESHOLD);

    // ── Delayed trade_valid: signal evaluation fires 1 cycle after VWAP update
    logic trade_valid_d;

    // ── EWMA state update ─────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vwap_reg      <= '0;
            vwap_init     <= 1'b0;
            trade_valid_d <= 1'b0;
        end else begin
            trade_valid_d <= trade_valid;

            if (trade_valid) begin
                if (!vwap_init) begin
                    vwap_reg  <= trade_price;   // seed with first trade price
                    vwap_init <= 1'b1;
                end else begin
                    vwap_reg  <= ewma_next;     // EWMA step (wire already computed)
                end
            end
        end
    end

    // ── Monitor outputs ───────────────────────────────────────────────────
    assign vwap_valid = vwap_init;
    assign vwap_price = vwap_reg;

    // ── Signal registration (one cycle after VWAP update) ─────────────────
    // On the cycle where trade_valid_d=1, vwap_reg already holds the new VWAP
    // (NBA committed from previous posedge). buy_cond/sell_cond are combinatorial
    // from vwap_reg, so they are also correct at this point.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sig_valid <= 1'b0;
            sig_side  <= 1'b0;
            sig_price <= '0;
            sig_qty   <= '0;
        end else begin
            sig_valid <= 1'b0;   // default: no signal

            if (trade_valid_d) begin
                if (buy_cond) begin
                    sig_valid <= 1'b1;
                    sig_side  <= 1'b0;              // BUY
                    sig_price <= best_ask_price;
                    sig_qty   <= QTY_W'(LOT_SIZE);
                end else if (sell_cond) begin
                    sig_valid <= 1'b1;
                    sig_side  <= 1'b1;              // SELL
                    sig_price <= best_bid_price;
                    sig_qty   <= QTY_W'(LOT_SIZE);
                end
            end
        end
    end

endmodule
