// rtl/order_serializer.sv  --  Day 12
// Converts an approved risk_gate order into a UART byte stream.
//
// Packet format (8 bytes, big-endian):
//   Byte 0 : 0xAB          SOF
//   Byte 1 : 0x01=BUY      Type (matches packet_assembler encoding)
//            0x02=SELL
//   Byte 2 : price[23:16]  Price MSB
//   Byte 3 : price[15:8]
//   Byte 4 : price[7:0]    Price LSB
//   Byte 5 : qty[15:8]     Qty MSB
//   Byte 6 : qty[7:0]      Qty LSB
//   Byte 7 : 0xCD          EOF
//
// Implementation
// --------------
// A 64-bit shift register holds the assembled packet.  The top byte is driven
// onto tx_data at all times.  When the UART FIFO has space (tx_rdy = 1), the
// register is shifted left by 8 bits to advance to the next byte.  A 4-bit
// counter tracks how many bytes remain.
//
// This design avoids constant bit-range selects inside always_* blocks
// (iverilog-12 limitation) by doing all field extraction in assign statements.
//
// Backpressure:
//   tx_valid is held high in SEND state.  The serializer stalls when tx_rdy=0
//   (UART FIFO full) and continues immediately when tx_rdy re-asserts.
//
// New order while busy:
//   order_rdy = 0 during SEND.  The upstream risk_gate (via strategy_core
//   cooldown) guarantees no new order arrives while busy.

module order_serializer #(
    parameter int PRICE_W = 24,
    parameter int QTY_W   = 16
)(
    input  logic                clk,
    input  logic                rst_n,

    // From risk_gate
    input  logic                order_valid,
    input  logic                order_side,        // 0=BUY  1=SELL
    input  logic [PRICE_W-1:0]  order_price,
    input  logic [QTY_W-1:0]    order_qty,
    output logic                order_rdy,         // 1 = idle, ready for next order

    // To uart_tx FIFO
    output logic [7:0]          tx_data,
    output logic                tx_valid,
    input  logic                tx_rdy             // 1 = FIFO has space
);

    // ── Packet constants ───────────────────────────────────────────────────
    localparam int  N_BYTES   = 8;
    localparam int  PKT_W     = 8 * N_BYTES;   // 64 bits
    localparam logic [7:0] SOF = 8'hAB;
    localparam logic [7:0] EOF = 8'hCD;
    localparam logic [7:0] BUY_TYPE  = 8'h01;
    localparam logic [7:0] SELL_TYPE = 8'h02;

    // ── Assemble full packet in one 64-bit word (assign is fine for constant selects)
    logic [PKT_W-1:0] pkt_word;
    logic [7:0]       type_byte;
    assign type_byte = order_side ? SELL_TYPE : BUY_TYPE;
    assign pkt_word  = { SOF,
                         type_byte,
                         order_price[23:16],
                         order_price[15:8],
                         order_price[7:0],
                         order_qty[15:8],
                         order_qty[7:0],
                         EOF };

    // ── State ──────────────────────────────────────────────────────────────
    localparam logic STATE_IDLE = 1'b0;
    localparam logic STATE_SEND = 1'b1;
    logic state;

    // ── Shift register and byte counter ───────────────────────────────────
    logic [PKT_W-1:0] shift_reg;
    logic [3:0]       bytes_left;    // counts 8 → 1 → 0 (go idle when hits 0)

    // ── Combinatorial outputs (constant select in assign: fine for iverilog) ─
    assign tx_data   = shift_reg[PKT_W-1 -: 8];   // always drive top byte
    assign tx_valid  = (state == STATE_SEND);
    assign order_rdy = (state == STATE_IDLE);

    // ── Sequential logic ───────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= STATE_IDLE;
            shift_reg  <= '0;
            bytes_left <= 4'd0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (order_valid) begin
                        shift_reg  <= pkt_word;   // latch assembled packet
                        bytes_left <= 4'd8;
                        state      <= STATE_SEND;
                    end
                end

                STATE_SEND: begin
                    if (tx_rdy) begin
                        // Byte accepted by UART FIFO; advance to next
                        shift_reg  <= shift_reg << 8;   // shift op: no constant select
                        bytes_left <= bytes_left - 1;
                        if (bytes_left == 4'd1)         // last byte just accepted
                            state <= STATE_IDLE;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
