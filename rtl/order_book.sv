// rtl/order_book.sv  --  Day 6
// Price-time priority order book for the HFT FPGA system.
//
// Accepts decoded frames from packet_assembler and maintains:
//   - Level-1 best bid  (highest-price BID, aggregated qty at that level)
//   - Level-1 best ask  (lowest-price  ASK, aggregated qty at that level)
//   - Mid price         = (best_bid + best_ask) / 2   [PRICE_W+1 bits]
//   - Spread            = best_ask - best_bid          [clamped to 0]
//   - Last trade price & qty (updated on TRADE frames only)
//
// Storage model
// -------------
// Orders are kept in a flat register file (MAX_ORDERS slots).  Each slot
// holds: {valid[1], order_id[16], price[24], qty[16], side[1]} = 58 bits.
// At MAX_ORDERS=64 this is 3.7 Kbits — synthesises as distributed RAM
// (LUTRAM) on Artix-7 rather than a block RAM.
//
// Processing latency (worst case, MAX_ORDERS=64 @ 100 MHz)
// ---------------------------------------------------------
//   ADD       64+1+1  = 66  cycles  (scan for slot + write)
//   CANCEL    64+1+64+1 = 130 cycles  (find OID + invalidate + rescan best)
//   TRADE / HEARTBEAT = 2  cycles
//
// At 115 200 baud one frame takes ≈ 95 480 cycles; we are never the bottleneck.
//
// Matching rules (must mirror tools/reference_book.py exactly)
// -----------------------------------------------------------
//   ADD     : inserts a new order.  Duplicate order_id silently overwrites.
//   CANCEL  : removes by order_id; price/side in the frame are ignored.
//   TRADE   : records last-trade price & qty ONLY; does not modify the book.
//   HB      : no-op for the book.
//   Best qty: SUM of all resting orders at the best price level.
//   Rescan  : triggered whenever the cancelled order's price == current best.

module order_book #(
    parameter int MAX_ORDERS = 64,   // must be a power of 2
    parameter int PRICE_W    = 24,
    parameter int QTY_W      = 16,
    parameter int OID_W      = 16
)(
    input  logic                clk,
    input  logic                rst_n,

    // From packet_assembler  (one-cycle pulse per valid frame)
    input  logic                pkt_valid,
    input  logic [1:0]          pkt_type,       // 0=ADD 1=CAN 2=TRD 3=HB
    input  logic [OID_W-1:0]    pkt_order_id,
    input  logic [PRICE_W-1:0]  pkt_price,
    input  logic [QTY_W-1:0]    pkt_qty,
    input  logic                pkt_side,       // 0=BID  1=ASK

    // Level-1 best bid
    output logic                best_bid_valid,
    output logic [PRICE_W-1:0]  best_bid_price,
    output logic [QTY_W-1:0]    best_bid_qty,

    // Level-1 best ask
    output logic                best_ask_valid,
    output logic [PRICE_W-1:0]  best_ask_price,
    output logic [QTY_W-1:0]    best_ask_qty,

    // Derived (combinatorial)
    output logic [PRICE_W:0]    mid_price,      // 25-bit: (bid+ask)/2
    output logic [PRICE_W-1:0]  spread,         // ask-bid, clamped to 0

    // Last trade (held until next TRADE frame)
    output logic                last_trade_valid,
    output logic [PRICE_W-1:0]  last_trade_price,
    output logic [QTY_W-1:0]    last_trade_qty,

    // Trade event: one-cycle pulse each time a TRADE frame is committed
    output logic                trade_valid,
    output logic [PRICE_W-1:0]  trade_price,
    output logic [QTY_W-1:0]    trade_qty,

    // Flow control: LOW while processing a frame; HIGH = ready for next
    output logic                ob_ready
);

    // ── Packet-type constants (match protocol_spec.md) ──────────────────
    localparam logic [1:0] PKT_ADD = 2'd0;
    localparam logic [1:0] PKT_CAN = 2'd1;
    localparam logic [1:0] PKT_TRD = 2'd2;
    localparam logic [1:0] PKT_HB  = 2'd3;

    // ── Slot index and scan counter widths ──────────────────────────────
    localparam int SLOT_W = $clog2(MAX_ORDERS);  // 6 for 64-entry table

    // scan_idx has SLOT_W+1 bits so it can count 0..MAX_ORDERS (inclusive).
    // When scan_idx == MAX_ORDERS the scan is finished and we do a commit.
    // For power-of-2 MAX_ORDERS: scan_idx[SLOT_W] == 1 iff scan done.
    localparam logic [SLOT_W:0] SCAN_END = SLOT_W+1'(MAX_ORDERS);

    // ── Order table (synthesises as LUTRAM on Artix-7) ──────────────────
    logic [MAX_ORDERS-1:0]  tbl_valid;                // 1 = slot occupied
    logic [OID_W-1:0]       tbl_oid   [MAX_ORDERS];
    logic [PRICE_W-1:0]     tbl_price [MAX_ORDERS];
    logic [QTY_W-1:0]       tbl_qty   [MAX_ORDERS];
    logic                   tbl_side  [MAX_ORDERS];   // 0=BID  1=ASK

    // ── Best bid/ask registers ───────────────────────────────────────────
    logic              bb_valid, ba_valid;
    logic [PRICE_W-1:0]bb_price, ba_price;
    logic [QTY_W-1:0]  bb_qty,   ba_qty;

    // ── Last trade ───────────────────────────────────────────────────────
    logic              lt_valid;
    logic [PRICE_W-1:0]lt_price;
    logic [QTY_W-1:0]  lt_qty;

    // ── FSM ─────────────────────────────────────────────────────────────
    typedef enum logic [3:0] {
        S_IDLE     = 4'd0,
        S_ADD_SCAN = 4'd1,   // scan table for a free slot
        S_ADD_WRIT = 4'd2,   // write order + fast-update best
        S_CAN_SCAN = 4'd3,   // scan table for matching order_id
        S_CAN_EXEC = 4'd4,   // invalidate slot; decide if rescan needed
        S_SCAN_BID = 4'd5,   // full scan: recompute best BID
        S_SCAN_ASK = 4'd6,   // full scan: recompute best ASK
        S_TRADE    = 4'd7,   // record last-trade fields
        S_HB       = 4'd8    // heartbeat no-op
    } state_t;

    state_t state;

    // ── Latched packet inputs ────────────────────────────────────────────
    logic [OID_W-1:0]   lat_oid;
    logic [PRICE_W-1:0] lat_price;
    logic [QTY_W-1:0]   lat_qty;
    logic               lat_side;

    // ── Scan counter (shared across all scan states) ─────────────────────
    logic [SLOT_W:0]    scan_idx;
    wire                scan_commit = (scan_idx == SCAN_END); // all slots checked

    // ── ADD_SCAN accumulators ─────────────────────────────────────────────
    logic               free_found;
    logic [SLOT_W-1:0]  free_slot;

    // ── CAN_SCAN accumulators ─────────────────────────────────────────────
    logic               oid_found;
    logic [SLOT_W-1:0]  oid_slot;
    logic               oid_was_bid;   // which side the cancelled order was on
    logic [PRICE_W-1:0] oid_price;     // its price (to compare against current best)

    // ── SCAN_BID / SCAN_ASK running best ─────────────────────────────────
    logic              sc_valid;
    logic [PRICE_W-1:0]sc_price;
    logic [QTY_W-1:0]  sc_qty;

    // ── Combinatorial mid / spread ────────────────────────────────────────
    always_comb begin
        if (bb_valid && ba_valid) begin
            mid_price = ({1'b0, ba_price} + {1'b0, bb_price}) >> 1;
            spread    = (ba_price >= bb_price) ? ba_price - bb_price
                                               : {PRICE_W{1'b0}};
        end else begin
            mid_price = '0;
            spread    = '0;
        end
    end

    // ── Output wiring ─────────────────────────────────────────────────────
    assign best_bid_valid    = bb_valid;
    assign best_bid_price    = bb_price;
    assign best_bid_qty      = bb_qty;
    assign best_ask_valid    = ba_valid;
    assign best_ask_price    = ba_price;
    assign best_ask_qty      = ba_qty;
    assign last_trade_valid  = lt_valid;
    assign last_trade_price  = lt_price;
    assign last_trade_qty    = lt_qty;
    assign ob_ready          = (state == S_IDLE);
    // Trade event pulse: active for the single cycle the FSM is in S_TRADE
    assign trade_valid       = (state == S_TRADE);
    assign trade_price       = lat_price;   // latched from pkt_price in S_IDLE
    assign trade_qty         = lat_qty;

    // ── Main FSM ──────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            tbl_valid  <= '0;
            bb_valid   <= 1'b0;   ba_valid <= 1'b0;
            lt_valid   <= 1'b0;
            scan_idx   <= '0;
            free_found <= 1'b0;   oid_found <= 1'b0;
            sc_valid   <= 1'b0;
            lat_oid    <= '0;     lat_price <= '0;
            lat_qty    <= '0;     lat_side  <= 1'b0;
        end else begin
            case (state)

                // ==========================================================
                S_IDLE: begin
                    if (pkt_valid) begin
                        // Latch the incoming frame
                        lat_oid   <= pkt_order_id;
                        lat_price <= pkt_price;
                        lat_qty   <= pkt_qty;
                        lat_side  <= pkt_side;
                        scan_idx  <= '0;

                        case (pkt_type)
                            PKT_ADD: begin
                                free_found <= 1'b0;
                                state      <= S_ADD_SCAN;
                            end
                            PKT_CAN: begin
                                oid_found  <= 1'b0;
                                state      <= S_CAN_SCAN;
                            end
                            PKT_TRD: state <= S_TRADE;
                            PKT_HB : state <= S_HB;
                            default: state <= S_IDLE;
                        endcase
                    end
                end

                // ==========================================================
                // ADD: scan all slots looking for the first free one.
                // Runs MAX_ORDERS cycles (slots 0..MAX_ORDERS-1), then
                // scan_idx reaches SCAN_END → transition to S_ADD_WRIT.
                // ==========================================================
                S_ADD_SCAN: begin
                    if (!scan_commit) begin
                        if (!tbl_valid[scan_idx[SLOT_W-1:0]] && !free_found) begin
                            free_found <= 1'b1;
                            free_slot  <= scan_idx[SLOT_W-1:0];
                        end
                        scan_idx <= scan_idx + 1'b1;
                    end else begin
                        state <= S_ADD_WRIT;
                    end
                end

                // ==========================================================
                // ADD: write order to found slot, then fast-update best.
                // ==========================================================
                S_ADD_WRIT: begin
                    if (free_found) begin
                        // Write order to the free slot
                        tbl_valid[free_slot] <= 1'b1;
                        tbl_oid  [free_slot] <= lat_oid;
                        tbl_price[free_slot] <= lat_price;
                        tbl_qty  [free_slot] <= lat_qty;
                        tbl_side [free_slot] <= lat_side;

                        // Fast-update best BID
                        if (!lat_side) begin
                            if (!bb_valid || lat_price > bb_price) begin
                                bb_valid <= 1'b1;
                                bb_price <= lat_price;
                                bb_qty   <= lat_qty;
                            end else if (lat_price == bb_price) begin
                                bb_qty   <= bb_qty + lat_qty;  // aggregate same level
                            end
                            // lat_price < bb_price → no change
                        end

                        // Fast-update best ASK
                        else begin
                            if (!ba_valid || lat_price < ba_price) begin
                                ba_valid <= 1'b1;
                                ba_price <= lat_price;
                                ba_qty   <= lat_qty;
                            end else if (lat_price == ba_price) begin
                                ba_qty   <= ba_qty + lat_qty;  // aggregate same level
                            end
                        end
                    end
                    // Book full (free_found=0): silently discard.
                    // Production systems would assert an overflow flag here.
                    state <= S_IDLE;
                end

                // ==========================================================
                // CANCEL: scan all slots for matching order_id.
                // ==========================================================
                S_CAN_SCAN: begin
                    if (!scan_commit) begin
                        if (tbl_valid[scan_idx[SLOT_W-1:0]] &&
                                tbl_oid[scan_idx[SLOT_W-1:0]] == lat_oid &&
                                !oid_found) begin
                            oid_found   <= 1'b1;
                            oid_slot    <= scan_idx[SLOT_W-1:0];
                            oid_was_bid <= !tbl_side[scan_idx[SLOT_W-1:0]];
                            oid_price   <= tbl_price[scan_idx[SLOT_W-1:0]];
                        end
                        scan_idx <= scan_idx + 1'b1;
                    end else begin
                        state <= S_CAN_EXEC;
                    end
                end

                // ==========================================================
                // CANCEL: invalidate the slot; decide if full rescan needed.
                // Rescan is triggered whenever the cancelled order's price
                // matches the current best (because qty at that level changed).
                // ==========================================================
                S_CAN_EXEC: begin
                    if (oid_found) begin
                        tbl_valid[oid_slot] <= 1'b0;  // remove from table

                        if (oid_was_bid && bb_valid && oid_price == bb_price) begin
                            // Cancelled the best BID level (or part of it)
                            bb_valid <= 1'b0;
                            sc_valid <= 1'b0;
                            scan_idx <= '0;
                            state    <= S_SCAN_BID;
                        end else if (!oid_was_bid && ba_valid &&
                                     oid_price == ba_price) begin
                            // Cancelled the best ASK level
                            ba_valid <= 1'b0;
                            sc_valid <= 1'b0;
                            scan_idx <= '0;
                            state    <= S_SCAN_ASK;
                        end else begin
                            state <= S_IDLE;  // non-best level: no rescan needed
                        end
                    end else begin
                        state <= S_IDLE;  // order_id not found: silent ignore
                    end
                end

                // ==========================================================
                // SCAN_BID: full table scan to find new best BID.
                // Running accumulator: sc_valid / sc_price / sc_qty.
                // After scan_commit, safe to copy sc_* into bb_* because
                // the sc_* NBAs from the previous cycle have already settled.
                // ==========================================================
                S_SCAN_BID: begin
                    if (!scan_commit) begin
                        if (tbl_valid[scan_idx[SLOT_W-1:0]] &&
                                !tbl_side[scan_idx[SLOT_W-1:0]]) begin  // valid BID
                            if (!sc_valid ||
                                    tbl_price[scan_idx[SLOT_W-1:0]] > sc_price) begin
                                // New best price found
                                sc_valid <= 1'b1;
                                sc_price <= tbl_price[scan_idx[SLOT_W-1:0]];
                                sc_qty   <= tbl_qty  [scan_idx[SLOT_W-1:0]];
                            end else if (tbl_price[scan_idx[SLOT_W-1:0]] == sc_price) begin
                                // Same best level — aggregate qty
                                sc_qty <= sc_qty + tbl_qty[scan_idx[SLOT_W-1:0]];
                            end
                        end
                        scan_idx <= scan_idx + 1'b1;
                    end else begin
                        // Commit: sc_* is stable (set by NBAs in previous cycles)
                        bb_valid <= sc_valid;
                        bb_price <= sc_price;
                        bb_qty   <= sc_qty;
                        state    <= S_IDLE;
                    end
                end

                // ==========================================================
                // SCAN_ASK: same as SCAN_BID but for ASK (find minimum price).
                // ==========================================================
                S_SCAN_ASK: begin
                    if (!scan_commit) begin
                        if (tbl_valid[scan_idx[SLOT_W-1:0]] &&
                                tbl_side[scan_idx[SLOT_W-1:0]]) begin  // valid ASK
                            if (!sc_valid ||
                                    tbl_price[scan_idx[SLOT_W-1:0]] < sc_price) begin
                                sc_valid <= 1'b1;
                                sc_price <= tbl_price[scan_idx[SLOT_W-1:0]];
                                sc_qty   <= tbl_qty  [scan_idx[SLOT_W-1:0]];
                            end else if (tbl_price[scan_idx[SLOT_W-1:0]] == sc_price) begin
                                sc_qty <= sc_qty + tbl_qty[scan_idx[SLOT_W-1:0]];
                            end
                        end
                        scan_idx <= scan_idx + 1'b1;
                    end else begin
                        ba_valid <= sc_valid;
                        ba_price <= sc_price;
                        ba_qty   <= sc_qty;
                        state    <= S_IDLE;
                    end
                end

                // ==========================================================
                S_TRADE: begin
                    lt_valid <= 1'b1;
                    lt_price <= lat_price;
                    lt_qty   <= lat_qty;
                    state    <= S_IDLE;
                end

                // ==========================================================
                S_HB: begin
                    state <= S_IDLE;  // nothing to do
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
