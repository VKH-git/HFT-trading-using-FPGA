// rtl/uart_rx.sv
// UART Receiver — 8N1
//
// Half-period alignment: on the start bit falling edge the baud counter
// is loaded with BIT_CYCLES/2 so the first baud_tick fires at the
// centre of the start bit. All subsequent bits sample at BIT_CYCLES
// intervals — perfectly centred on every bit in the frame.
//
// Parameters:
//   CLK_FREQ / BAUD_RATE — default 100 MHz / 115200 (BIT_CYCLES = 868)

module uart_rx #(
    parameter int CLK_FREQ  = 100_000_000,
    parameter int BAUD_RATE = 115_200
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx,

    output logic [7:0] rx_data,
    output logic       rx_valid,
    output logic       rx_error
);

    localparam int BIT_CYCLES  = CLK_FREQ / BAUD_RATE;   // 868
    localparam int HALF_PERIOD = BIT_CYCLES / 2;          // 434

    typedef enum logic [1:0] {
        IDLE  = 2'd0,
        START = 2'd1,
        DATA  = 2'd2,
        STOP  = 2'd3
    } state_t;

    state_t state;

    logic [$clog2(BIT_CYCLES)-1:0] baud_cnt;
    logic                          baud_tick;
    logic [2:0]                    bit_idx;
    logic [7:0]                    shift_reg;
    logic                          rx_meta, rx_sync, rx_sync_d;

    // Two-FF synchroniser — mandatory for async inputs
    always_ff @(posedge clk) begin
        rx_meta   <= rx;
        rx_sync   <= rx_meta;
        rx_sync_d <= rx_sync;
    end

    // Falling edge: high last cycle, low this cycle
    wire falling_edge = rx_sync_d & ~rx_sync;

    // Baud counter
    // When we detect the falling edge while IDLE, load HALF_PERIOD so
    // the first baud_tick fires exactly at mid-start-bit.
    // All subsequent bit samples fire every BIT_CYCLES from there.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            baud_cnt  <= '0;
            baud_tick <= 1'b0;
        end else if (state == IDLE && falling_edge) begin
            // Load half-period — aligns sampling to bit centres
            baud_cnt  <= HALF_PERIOD[$clog2(BIT_CYCLES)-1:0];
            baud_tick <= 1'b0;
        end else if (state == IDLE) begin
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

    // Main FSM
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            bit_idx   <= '0;
            shift_reg <= '0;
            rx_data   <= '0;
            rx_valid  <= 1'b0;
            rx_error  <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            rx_error <= 1'b0;

            case (state)

                IDLE: begin
                    bit_idx <= '0;
                    if (falling_edge)
                        state <= START;
                end

                // baud_tick fires at mid-start-bit; verify line still LOW
                START: begin
                    if (baud_tick)
                        state <= rx_sync ? IDLE : DATA;
                        // HIGH at centre means it was a glitch, back to IDLE
                end

                // baud_tick fires at centre of each data bit
                DATA: begin
                    if (baud_tick) begin
                        shift_reg <= {rx_sync, shift_reg[7:1]};  // LSB first
                        if (bit_idx == 3'd7) begin
                            bit_idx <= '0;
                            state   <= STOP;
                        end else begin
                            bit_idx <= bit_idx + 1;
                        end
                    end
                end

                STOP: begin
                    if (baud_tick) begin
                        if (rx_sync) begin
                            rx_data  <= shift_reg;
                            rx_valid <= 1'b1;
                        end else begin
                            rx_error <= 1'b1;
                        end
                        state <= IDLE;
                    end
                end

            endcase
        end
    end

endmodule
