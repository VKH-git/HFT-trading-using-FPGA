// rtl/uart_tx.sv
// UART Transmitter — 8N1, configurable baud rate, 16-entry TX FIFO
//
// Parameters:
//   CLK_FREQ   system clock frequency in Hz   (default 100 MHz)
//   BAUD_RATE  target baud rate               (default 115200)
//   FIFO_DEPTH number of bytes the TX FIFO holds (default 16, must be power of 2)
//
// Interface:
//   clk        system clock (active rising edge)
//   rst_n      synchronous active-low reset
//   tx         serial output line (idle = 1)
//   tx_data    byte to transmit — sampled when tx_valid & tx_ready
//   tx_valid   upstream asserts: tx_data is valid and should be sent
//   tx_ready   asserted when FIFO has space (backpressure signal)
//   tx_busy    asserted while a byte is being shifted out
//   fifo_full  asserted when FIFO is full (same cycle tx_ready goes low)
//
// Protocol: 8N1
//   1 start bit (logic 0)
//   8 data bits (LSB first)
//   1 stop bit  (logic 1)
//
// FIFO behaviour:
//   Upstream writes tx_data when tx_valid && tx_ready.
//   The shift FSM pulls from the FIFO head when idle.
//   FIFO depth 16 means 16 bytes can be queued before backpressure.
//   For your system: order serializer writes up to 11 bytes per order.
//   16-deep FIFO ensures one full frame is always bufferable.
//
// Timing:
//   1 bit period = CLK_FREQ / BAUD_RATE cycles (868 @ 100MHz/115200)
//   1 byte time  = 10 bit periods = 8680 cycles ≈ 86.8 µs

module uart_tx #(
    parameter int CLK_FREQ   = 100_000_000,
    parameter int BAUD_RATE  = 115_200,
    parameter int FIFO_DEPTH = 16          // must be power of 2
)(
    input  logic       clk,
    input  logic       rst_n,

    // Upstream data interface
    input  logic [7:0] tx_data,   // byte to send
    input  logic       tx_valid,  // upstream: data is valid
    output logic       tx_ready,  // asserted: FIFO has space
    output logic       tx_busy,   // asserted: currently shifting a byte
    output logic       fifo_full, // asserted: FIFO is full

    // Serial output
    output logic       tx         // serial line, idle HIGH
);

    // ── Baud rate constant ────────────────────────────────────────
    localparam int BIT_CYCLES = CLK_FREQ / BAUD_RATE;   // 868

    // ── TX FIFO (circular buffer) ─────────────────────────────────
    // Simple synchronous FIFO using a register array.
    // For depth 16: 4-bit head/tail pointers, comparison on [3:0].
    localparam int PTR_W = $clog2(FIFO_DEPTH);

    logic [7:0]       fifo [0:FIFO_DEPTH-1];
    logic [PTR_W:0]   wr_ptr;   // extra bit for full/empty detection
    logic [PTR_W:0]   rd_ptr;
    logic             fifo_empty;

    assign fifo_full  = (wr_ptr[PTR_W]   != rd_ptr[PTR_W]) &&
                        (wr_ptr[PTR_W-1:0] == rd_ptr[PTR_W-1:0]);
    assign fifo_empty = (wr_ptr == rd_ptr);
    assign tx_ready   = !fifo_full;

    // FIFO write — upstream pushes when tx_valid && tx_ready
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
        end else if (tx_valid && tx_ready) begin
            fifo[wr_ptr[PTR_W-1:0]] <= tx_data;
            wr_ptr <= wr_ptr + 1;
        end
    end

    // ── Shift FSM ─────────────────────────────────────────────────
    typedef enum logic [1:0] {
        TX_IDLE  = 2'd0,
        TX_START = 2'd1,
        TX_DATA  = 2'd2,
        TX_STOP  = 2'd3
    } tx_state_t;

    tx_state_t tx_state;

    logic [$clog2(BIT_CYCLES)-1:0] baud_cnt;   // counts cycles per bit
    logic [2:0]                    bit_idx;    // current bit being sent
    logic [7:0]                    shift_reg;  // byte being shifted out
    logic                          baud_tick;  // 1-cycle pulse at end of each bit

    // Baud tick generator
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || tx_state == TX_IDLE) begin
            baud_cnt  <= '0;
            baud_tick <= 1'b0;
        end else begin
            if (baud_cnt == BIT_CYCLES - 1) begin
                baud_cnt  <= '0;
                baud_tick <= 1'b1;
            end else begin
                baud_cnt  <= baud_cnt + 1;
                baud_tick <= 1'b0;
            end
        end
    end

    // Shift FSM + FIFO read pointer
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state <= TX_IDLE;
            tx       <= 1'b1;     // idle HIGH
            bit_idx  <= '0;
            shift_reg<= '0;
            rd_ptr   <= '0;
            tx_busy  <= 1'b0;
        end else begin
            case (tx_state)

                // ── IDLE: pull next byte from FIFO if available ───
                TX_IDLE: begin
                    tx      <= 1'b1;   // keep line HIGH
                    tx_busy <= 1'b0;
                    if (!fifo_empty) begin
                        // Latch byte from FIFO head, advance read pointer
                        shift_reg <= fifo[rd_ptr[PTR_W-1:0]];
                        rd_ptr    <= rd_ptr + 1;
                        tx_state  <= TX_START;
                        tx_busy   <= 1'b1;
                        bit_idx   <= '0;
                    end
                end

                // ── START: drive start bit (logic 0) for 1 bit period
                TX_START: begin
                    tx <= 1'b0;
                    if (baud_tick) begin
                        tx_state <= TX_DATA;
                        bit_idx  <= '0;
                    end
                end

                // ── DATA: shift out 8 bits, LSB first ────────────
                TX_DATA: begin
                    tx <= shift_reg[0];   // LSB first
                    if (baud_tick) begin
                        shift_reg <= {1'b0, shift_reg[7:1]};   // right shift
                        if (bit_idx == 3'd7) begin
                            tx_state <= TX_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1;
                        end
                    end
                end

                // ── STOP: drive stop bit (logic 1) for 1 bit period
                TX_STOP: begin
                    tx <= 1'b1;
                    if (baud_tick) begin
                        tx_state <= TX_IDLE;
                        tx_busy  <= 1'b0;
                    end
                end

            endcase
        end
    end

endmodule
