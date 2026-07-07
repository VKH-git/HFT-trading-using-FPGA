// rtl/strategy_core.sv  --  Day 9
// Strategy arbitration engine.
//
// Instantiates two strategies (VWAP mean-reversion + momentum trend-following)
// and arbitrates their output signals.
//
// Arbitration
// -----------
//   Priority encoder: VWAP (index 0) wins over Momentum (index 1).
//   A GENERATE chain propagates a "higher-priority-active" carry bit so the
//   design scales cleanly to N strategies without O(N^2) logic.
//
// Cooldown
// --------
//   After each signal is forwarded to risk_gate, a COOLDOWN_CYCLES counter
//   blocks further signals. This prevents hammering the exchange on a single
//   event. Default: 1000 cycles (= 10 µs at 100 MHz).
//
// Outputs
// -------
//   sig_valid / sig_side / sig_price / sig_qty : to risk_gate.sv
//   sig_source [1:0]                            : 0=VWAP, 1=MOM  (for logging)

module strategy_core #(
    parameter int PRICE_W         = 24,
    parameter int QTY_W           = 16,
    parameter int VWAP_THRESHOLD  = 10,    // paise for VWAP strategy
    parameter int MOM_THRESHOLD   = 20,    // paise for momentum strategy
    parameter int LOT_SIZE        = 100,   // shares per order
    parameter int COOLDOWN_CYCLES = 1000   // min cycles between signals
)(
    input  logic                clk,
    input  logic                rst_n,

    // Book snapshot from order_book
    input  logic                best_bid_valid,
    input  logic [PRICE_W-1:0]  best_bid_price,
    input  logic                best_ask_valid,
    input  logic [PRICE_W-1:0]  best_ask_price,

    // Trade feed from order_book
    input  logic                trade_valid,
    input  logic [PRICE_W-1:0]  trade_price,
    input  logic [QTY_W-1:0]    trade_qty,

    // To risk_gate
    output logic                sig_valid,
    output logic                sig_side,
    output logic [PRICE_W-1:0]  sig_price,
    output logic [QTY_W-1:0]    sig_qty,
    output logic [1:0]          sig_source    // 0=VWAP  1=MOM
);

    // ── Number of strategies ───────────────────────────────────────────────
    localparam int N = 2;

    // ── Per-strategy signal arrays ─────────────────────────────────────────
    logic [N-1:0]         sv;          // sig_valid per strategy
    logic [N-1:0]         ss;          // sig_side per strategy
    logic [PRICE_W-1:0]   sp [N];     // sig_price per strategy
    logic [QTY_W-1:0]     sq [N];     // sig_qty  per strategy

    // ── Strategy 0: VWAP mean-reversion ───────────────────────────────────
    strategy_vwap #(
        .PRICE_W   (PRICE_W),
        .QTY_W     (QTY_W),
        .THRESHOLD (VWAP_THRESHOLD),
        .LOT_SIZE  (LOT_SIZE)
    ) u_vwap (
        .clk           (clk),
        .rst_n         (rst_n),
        .best_bid_valid(best_bid_valid),
        .best_bid_price(best_bid_price),
        .best_ask_valid(best_ask_valid),
        .best_ask_price(best_ask_price),
        .trade_valid   (trade_valid),
        .trade_price   (trade_price),
        .trade_qty     (trade_qty),
        .sig_valid     (sv[0]),
        .sig_side      (ss[0]),
        .sig_price     (sp[0]),
        .sig_qty       (sq[0]),
        .vwap_valid    (),
        .vwap_price    ()
    );

    // ── Strategy 1: Momentum trend-following ──────────────────────────────
    strategy_momentum #(
        .PRICE_W   (PRICE_W),
        .QTY_W     (QTY_W),
        .THRESHOLD (MOM_THRESHOLD),
        .LOT_SIZE  (LOT_SIZE)
    ) u_mom (
        .clk           (clk),
        .rst_n         (rst_n),
        .best_bid_valid(best_bid_valid),
        .best_bid_price(best_bid_price),
        .best_ask_valid(best_ask_valid),
        .best_ask_price(best_ask_price),
        .trade_valid   (trade_valid),
        .trade_price   (trade_price),
        .trade_qty     (trade_qty),
        .sig_valid     (sv[1]),
        .sig_side      (ss[1]),
        .sig_price     (sp[1]),
        .sig_qty       (sq[1]),
        .mom_valid     (),
        .fast_price    (),
        .slow_price    ()
    );

    // ── GENERATE: priority-chain carry encoder ─────────────────────────────
    // any_above[i] = OR of sv[0..i-1].  chosen[i] = sv[i] & ~any_above[i].
    // This is a ripple-carry priority encoder: O(N) logic, O(N) depth.
    logic [N:0] any_above;
    logic [N-1:0] chosen;

    assign any_above[0] = 1'b0;

    genvar gi;
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : gen_pri
            assign any_above[gi+1] = any_above[gi] | sv[gi];
            assign chosen[gi]      = sv[gi] & ~any_above[gi];
        end
    endgenerate

    // ── Combinatorial winner mux (hardcoded for N=2) ───────────────────────
    // Extends to N=3+ by adding additional else-if blocks.
    logic               win_valid;
    logic               win_side;
    logic [PRICE_W-1:0] win_price;
    logic [QTY_W-1:0]   win_qty;
    logic [1:0]         win_source;

    // Continuous assignment avoids constant selects inside always_* (iverilog-12 bug).
    assign win_valid  = |chosen;
    assign win_side   = chosen[0] ? ss[0] : ss[1];
    assign win_price  = chosen[0] ? sp[0] : sp[1];
    assign win_qty    = chosen[0] ? sq[0] : sq[1];
    assign win_source = chosen[0] ? 2'd0  : 2'd1;

    // ── Cooldown gate ──────────────────────────────────────────────────────
    localparam int CD_W = $clog2(COOLDOWN_CYCLES + 1);

    logic [CD_W-1:0] cooldown_cnt;
    logic            cooldown_active;
    assign cooldown_active = (cooldown_cnt != '0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cooldown_cnt <= '0;
            sig_valid    <= 1'b0;
            sig_side     <= 1'b0;
            sig_price    <= '0;
            sig_qty      <= '0;
            sig_source   <= 2'd0;
        end else begin
            sig_valid <= 1'b0;   // default: no signal

            // Countdown (plain integer subtraction — width inferred from LHS)
            if (cooldown_active)
                cooldown_cnt <= cooldown_cnt - 1;

            // Forward winning signal if not in cooldown
            if (win_valid && !cooldown_active) begin
                sig_valid    <= 1'b1;
                sig_side     <= win_side;
                sig_price    <= win_price;
                sig_qty      <= win_qty;
                sig_source   <= win_source;
                cooldown_cnt <= COOLDOWN_CYCLES;
            end
        end
    end

endmodule
