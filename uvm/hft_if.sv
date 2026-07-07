// uvm/hft_if.sv
// SystemVerilog interface for the HFT trading_top DUT.
// Driver drives signals directly; monitor samples via clocking block.

`ifndef HFT_IF_SV
`define HFT_IF_SV

interface hft_if (input logic clk);

    // ── Reset and serial I/O ────────────────────────────────────────────────
    logic        rst_n;
    logic        uart_rxd;    // driven by driver (market data frames)
    logic        uart_txd;    // observed (order output)

    // ── Fill (exchange confirms) ────────────────────────────────────────────
    logic        fill_valid;
    logic        fill_side;
    logic [23:0] fill_price;
    logic [15:0] fill_qty;

    // ── Monitor ports (all DUT mon_* outputs) ──────────────────────────────
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

    // ── Monitor clocking block: sample 1 unit before posedge ───────────────
    clocking mon_cb @(posedge clk);
        default input #1;
        input mon_pkt_valid;
        input mon_pkt_type;
        input mon_best_bid_valid;
        input mon_best_bid_price;
        input mon_best_ask_valid;
        input mon_best_ask_price;
        input mon_trade_valid;
        input mon_trade_price;
        input mon_sig_valid;
        input mon_sig_source;
        input mon_order_valid;
        input mon_breach_flags;
        input mon_net_pos_biased;
        input mon_running_pnl;
        input mon_fill_count;
        input mon_drawdown_hit;
    endclocking

    // ── Modports ─────────────────────────────────────────────────────────
    modport monitor_mp (clocking mon_cb, input uart_txd);
    modport driver_mp  (input clk, input uart_txd,
                        output rst_n, output uart_rxd,
                        output fill_valid, output fill_side,
                        output fill_price, output fill_qty);

endinterface : hft_if

`endif // HFT_IF_SV
