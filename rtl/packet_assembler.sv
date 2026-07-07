// rtl/packet_assembler.sv
// Consumes raw bytes from uart_rx and assembles 11-byte protocol frames.
// Outputs all fields in parallel for exactly one clock when a valid frame lands.
//
// Frame layout (from protocol_spec.md):
//   [0]=SOF(0xAA) [1]=type [2..3]=order_id [4..6]=price
//   [7..8]=qty [9]=side [10]=EOF(0x55)
//
// Error handling: wrong SOF or EOF returns to IDLE and pulses parse_error.
// Unknown msg_type does the same — we don't silently pass garbage downstream.

module packet_assembler (
    input  logic        clk,
    input  logic        rst_n,

    // Byte stream from uart_rx
    input  logic [7:0]  rx_data,
    input  logic        rx_valid,
    input  logic        rx_error,   // framing error from uart_rx

    // Decoded frame output — all signals valid when pkt_valid pulses
    output logic        pkt_valid,
    output logic [1:0]  pkt_type,   // 0=ADD 1=CANCEL 2=TRADE 3=HEARTBEAT
    output logic [15:0] pkt_order_id,
    output logic [23:0] pkt_price,
    output logic [15:0] pkt_qty,
    output logic        pkt_side,   // 0=BID 1=ASK

    // Error pulse — 1 cycle, check in testbench
    output logic        parse_error
);

    // msg_type byte values
    localparam logic [7:0] SOF_BYTE  = 8'hAA;
    localparam logic [7:0] EOF_BYTE  = 8'h55;
    localparam logic [7:0] TYPE_ADD  = 8'h01;
    localparam logic [7:0] TYPE_CAN  = 8'h02;
    localparam logic [7:0] TYPE_TRD  = 8'h03;
    localparam logic [7:0] TYPE_HB   = 8'h04;

    // One state per byte position — keeps the logic dead simple
    typedef enum logic [3:0] {
        S_IDLE     = 4'd0,
        S_TYPE     = 4'd1,
        S_OID_H    = 4'd2,
        S_OID_L    = 4'd3,
        S_PRICE_H  = 4'd4,
        S_PRICE_M  = 4'd5,
        S_PRICE_L  = 4'd6,
        S_QTY_H    = 4'd7,
        S_QTY_L    = 4'd8,
        S_SIDE     = 4'd9,
        S_EOF      = 4'd10
    } state_t;

    state_t state;

    // Holding registers — fields accumulate here as bytes arrive
    logic [7:0]  type_reg;
    logic [15:0] oid_reg;
    logic [23:0] price_reg;
    logic [15:0] qty_reg;
    logic [7:0]  side_reg;

    // Helper: is the type byte one of the four valid message types?
    // (replaces the 'inside' operator which iverilog 12 does not support)
    function automatic logic valid_type(input logic [7:0] b);
        return (b == TYPE_ADD) || (b == TYPE_CAN) ||
               (b == TYPE_TRD) || (b == TYPE_HB);
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            pkt_valid   <= 1'b0;
            parse_error <= 1'b0;
            type_reg    <= '0;
            oid_reg     <= '0;
            price_reg   <= '0;
            qty_reg     <= '0;
            side_reg    <= '0;
        end else begin
            // Default: clear strobes every cycle
            pkt_valid   <= 1'b0;
            parse_error <= 1'b0;

            // A framing error from uart_rx means the byte is garbage —
            // bail out rather than accumulate corrupt data
            if (rx_error) begin
                state       <= S_IDLE;
                parse_error <= 1'b1;
            end else if (rx_valid) begin
                case (state)

                    S_IDLE: begin
                        if (rx_data == SOF_BYTE)
                            state <= S_TYPE;
                        // silently ignore non-SOF bytes — line may have noise
                    end

                    S_TYPE: begin
                        if (valid_type(rx_data)) begin
                            type_reg <= rx_data;
                            state    <= S_OID_H;
                        end else begin
                            // Unknown type — drop frame, wait for next SOF
                            state       <= S_IDLE;
                            parse_error <= 1'b1;
                        end
                    end

                    S_OID_H: begin
                        oid_reg[15:8] <= rx_data;
                        state         <= S_OID_L;
                    end

                    S_OID_L: begin
                        oid_reg[7:0] <= rx_data;
                        state        <= S_PRICE_H;
                    end

                    S_PRICE_H: begin
                        price_reg[23:16] <= rx_data;
                        state            <= S_PRICE_M;
                    end

                    S_PRICE_M: begin
                        price_reg[15:8] <= rx_data;
                        state           <= S_PRICE_L;
                    end

                    S_PRICE_L: begin
                        price_reg[7:0] <= rx_data;
                        state          <= S_QTY_H;
                    end

                    S_QTY_H: begin
                        qty_reg[15:8] <= rx_data;
                        state         <= S_QTY_L;
                    end

                    S_QTY_L: begin
                        qty_reg[7:0] <= rx_data;
                        state        <= S_SIDE;
                    end

                    S_SIDE: begin
                        side_reg <= rx_data;
                        state    <= S_EOF;
                    end

                    S_EOF: begin
                        if (rx_data == EOF_BYTE) begin
                            // Good frame — decode type and fire outputs
                            pkt_valid    <= 1'b1;
                            pkt_order_id <= oid_reg;
                            pkt_price    <= price_reg;
                            pkt_qty      <= qty_reg;
                            pkt_side     <= side_reg[0];

                            // Map raw byte to 2-bit type enum
                            case (type_reg)
                                TYPE_ADD: pkt_type <= 2'd0;
                                TYPE_CAN: pkt_type <= 2'd1;
                                TYPE_TRD: pkt_type <= 2'd2;
                                TYPE_HB:  pkt_type <= 2'd3;
                                default:  pkt_type <= 2'd0;
                            endcase
                        end else begin
                            // EOF mismatch — frame is corrupt
                            parse_error <= 1'b1;
                        end
                        state <= S_IDLE;
                    end

                    default: state <= S_IDLE;

                endcase
            end
        end
    end

    // pkt_* outputs hold their last value between frames — that's fine
    // because pkt_valid is the only signal the downstream reads on

endmodule
