// sim/tb_uart_loopback.sv  --  Day 7
// Integration test: uart_tx -> uart_rx -> packet_assembler pipeline.
//
// The test wires uart_tx.tx directly to uart_rx.rx (zero-wire loopback)
// and feeds decoded bytes straight into packet_assembler.
//
// To keep simulation fast we override CLK_FREQ and BAUD_RATE so that:
//   BIT_CYCLES = CLK_FREQ / BAUD_RATE = 100 / 1 = 100 cycles
//   One 11-byte frame = 11 x 10 bits x 100 cycles = 11,000 sim cycles
// The ratio is identical to 100 MHz / 115200, so all FSMs behave exactly
// as they would on real hardware.
//
// Tests
// -----
//   T1  ADD frame  -- all fields decoded correctly, no parse error
//   T2  CANCEL frame
//   T3  TRADE frame
//   T4  HEARTBEAT frame
//   T5  Back-to-back: two frames with no inter-frame gap
//   T6  Bad SOF byte injected -- should be silently dropped
//   T7  Bad EOF byte          -- parse_error asserted, recovery on next frame

`timescale 1ns/1ps

module tb_uart_loopback;

    // ── Simulation parameters (fast mode) ─────────────────────────────────
    localparam int SIM_CLK_FREQ  = 100;   // 100 "Hz"  (100 cycles per UART bit)
    localparam int SIM_BAUD_RATE = 1;     // 1  baud   (ratio preserved)

    // ── Protocol constants ─────────────────────────────────────────────────
    localparam logic [7:0] SOF      = 8'hAA;
    localparam logic [7:0] EOF_BYTE = 8'h55;

    localparam logic [7:0] MSG_ADD  = 8'h01;
    localparam logic [7:0] MSG_CAN  = 8'h02;
    localparam logic [7:0] MSG_TRD  = 8'h03;
    localparam logic [7:0] MSG_HB   = 8'h04;

    // ── Clock / reset ──────────────────────────────────────────────────────
    localparam int CLK_PERIOD = 10;   // 10 ns (100 MHz wall-time; irrelevant here)

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ── UART TX signals ────────────────────────────────────────────────────
    logic [7:0] tx_data  = 8'h00;
    logic       tx_valid = 1'b0;
    logic       tx_ready;
    logic       tx_busy;
    logic       fifo_full;
    logic       uart_tx_line;     // serial line: TX -> RX loopback

    // ── UART RX signals ────────────────────────────────────────────────────
    logic [7:0] rx_data;
    logic       rx_valid;
    logic       rx_error;

    // ── Packet assembler signals ───────────────────────────────────────────
    logic        pkt_valid;
    logic [1:0]  pkt_type;
    logic [15:0] pkt_order_id;
    logic [23:0] pkt_price;
    logic [15:0] pkt_qty;
    logic        pkt_side;
    logic        parse_error;

    // ── DUT: uart_tx ───────────────────────────────────────────────────────
    uart_tx #(
        .CLK_FREQ  (SIM_CLK_FREQ),
        .BAUD_RATE (SIM_BAUD_RATE),
        .FIFO_DEPTH(16)
    ) u_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (tx_data),
        .tx_valid (tx_valid),
        .tx_ready (tx_ready),
        .tx_busy  (tx_busy),
        .fifo_full(fifo_full),
        .tx       (uart_tx_line)
    );

    // ── DUT: uart_rx ───────────────────────────────────────────────────────
    uart_rx #(
        .CLK_FREQ  (SIM_CLK_FREQ),
        .BAUD_RATE (SIM_BAUD_RATE)
    ) u_rx (
        .clk     (clk),
        .rst_n   (rst_n),
        .rx      (uart_tx_line),    // loopback wire
        .rx_data (rx_data),
        .rx_valid(rx_valid),
        .rx_error(rx_error)
    );

    // ── DUT: packet_assembler ──────────────────────────────────────────────
    packet_assembler u_pa (
        .clk        (clk),
        .rst_n      (rst_n),
        .rx_data    (rx_data),
        .rx_valid   (rx_valid),
        .rx_error   (rx_error),
        .pkt_valid  (pkt_valid),
        .pkt_type   (pkt_type),
        .pkt_order_id(pkt_order_id),
        .pkt_price  (pkt_price),
        .pkt_qty    (pkt_qty),
        .pkt_side   (pkt_side),
        .parse_error(parse_error)
    );

    // ── Test counters ──────────────────────────────────────────────────────
    integer tests_run    = 0;
    integer tests_passed = 0;
    integer tests_failed = 0;

    // ── Scratch variables (module-level for iverilog) ──────────────────────
    integer    wait_cnt;
    logic [7:0] frame_buf [0:10];   // 11-byte frame scratch buffer
    integer     bi;                  // byte index

    // ── Tasks ──────────────────────────────────────────────────────────────

    // Check helper
    task check_eq;
        input [63:0]  got;
        input [63:0]  expected;
        input [127:0] label;
    begin
        tests_run = tests_run + 1;
        if (got === expected) begin
            $display("    PASS  %0s", label);
            tests_passed = tests_passed + 1;
        end else begin
            $display("    FAIL  %0s : got 0x%0h  expected 0x%0h",
                     label, got, expected);
            tests_failed = tests_failed + 1;
        end
    end
    endtask

    // Push one byte into the TX FIFO (waits for tx_ready)
    task push_byte;
        input [7:0] b;
    begin
        // Wait for FIFO space.
        // BIT_CYCLES=100, one UART byte = 10 bits x 100 = 1000 cycles.
        // Timeout must exceed 1000 so we always see tx_ready go high.
        wait_cnt = 0;
        while (!tx_ready && wait_cnt < 2000) begin
            @(posedge clk); wait_cnt = wait_cnt + 1;
        end
        @(negedge clk);
        tx_data  = b;
        tx_valid = 1'b1;
        @(negedge clk);
        tx_valid = 1'b0;
    end
    endtask

    // Encode one 11-byte frame into frame_buf[]
    // then push all bytes into FIFO
    task send_frame;
        input [7:0]  msg_type;
        input [15:0] order_id;
        input [23:0] price;
        input [15:0] qty;
        input        side;
    begin
        frame_buf[0]  = SOF;
        frame_buf[1]  = msg_type;
        frame_buf[2]  = order_id[15:8];
        frame_buf[3]  = order_id[7:0];
        frame_buf[4]  = price[23:16];
        frame_buf[5]  = price[15:8];
        frame_buf[6]  = price[7:0];
        frame_buf[7]  = qty[15:8];
        frame_buf[8]  = qty[7:0];
        frame_buf[9]  = {7'd0, side};
        frame_buf[10] = EOF_BYTE;

        for (bi = 0; bi < 11; bi = bi + 1)
            push_byte(frame_buf[bi]);
    end
    endtask

    // Wait until pkt_valid or parse_error fires (with timeout)
    // Returns 1 if pkt_valid fired, 0 if parse_error, -1 if timeout
    integer wait_result;
    task wait_frame_done;
    begin
        wait_cnt = 0;
        wait_result = -1;
        while (wait_cnt < 20000) begin
            @(posedge clk);
            wait_cnt = wait_cnt + 1;
            if (pkt_valid) begin
                wait_result = 1;
                wait_cnt    = 99999;   // exit
            end else if (parse_error) begin
                wait_result = 0;
                wait_cnt    = 99999;
            end
        end
        #1;
    end
    endtask

    // ── Main test body ─────────────────────────────────────────────────────
    initial begin
        $dumpfile("tb_uart_loopback.vcd");
        $dumpvars(0, tb_uart_loopback);

        // Reset
        rst_n = 1'b0;
        repeat(4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat(4) @(posedge clk);

        // ================================================================
        $display("\n=== T1: ADD frame ===");
        // ================================================================
        // ADD  id=0x0001  price=100000 (0x01_86A0)  qty=100 (0x0064)  BID
        send_frame(MSG_ADD, 16'h0001, 24'h0186A0, 16'h0064, 1'b0);
        wait_frame_done;
        check_eq(wait_result,   1,        "T1 pkt_valid");
        check_eq(parse_error,   0,        "T1 no parse_error");
        check_eq(pkt_type,      2'd0,     "T1 pkt_type=ADD");
        check_eq(pkt_order_id,  16'h0001, "T1 order_id");
        check_eq(pkt_price,     24'h0186A0,"T1 price");
        check_eq(pkt_qty,       16'h0064, "T1 qty");
        check_eq(pkt_side,      1'b0,     "T1 side=BID");

        // ================================================================
        $display("\n=== T2: CANCEL frame ===");
        // ================================================================
        send_frame(MSG_CAN, 16'h0001, 24'h0186A0, 16'h0000, 1'b0);
        wait_frame_done;
        check_eq(wait_result,   1,        "T2 pkt_valid");
        check_eq(pkt_type,      2'd1,     "T2 pkt_type=CANCEL");
        check_eq(pkt_order_id,  16'h0001, "T2 order_id");

        // ================================================================
        $display("\n=== T3: TRADE frame ===");
        // ================================================================
        // TRADE  price=100200 (0x018768)  qty=50 (0x0032)  ASK
        send_frame(MSG_TRD, 16'h0004, 24'h018768, 16'h0032, 1'b1);
        wait_frame_done;
        check_eq(wait_result,   1,        "T3 pkt_valid");
        check_eq(pkt_type,      2'd2,     "T3 pkt_type=TRADE");
        check_eq(pkt_price,     24'h018768,"T3 price");
        check_eq(pkt_qty,       16'h0032, "T3 qty");
        check_eq(pkt_side,      1'b1,     "T3 side=ASK");

        // ================================================================
        $display("\n=== T4: HEARTBEAT frame ===");
        // ================================================================
        send_frame(MSG_HB, 16'h0000, 24'h000000, 16'h0000, 1'b0);
        wait_frame_done;
        check_eq(wait_result,   1,        "T4 pkt_valid");
        check_eq(parse_error,   0,        "T4 no parse_error");
        check_eq(pkt_type,      2'd3,     "T4 pkt_type=HB");

        // ================================================================
        $display("\n=== T5: Back-to-back frames ===");
        // ================================================================
        // Queue both frames without waiting for first to complete
        send_frame(MSG_ADD, 16'h0002, 24'h018630, 16'h0050, 1'b1); // ASK
        send_frame(MSG_ADD, 16'h0003, 24'h018600, 16'h00C8, 1'b0); // BID
        wait_frame_done;
        check_eq(wait_result,   1,        "T5 frame1 pkt_valid");
        check_eq(pkt_order_id,  16'h0002, "T5 frame1 order_id=2");
        wait_frame_done;
        check_eq(wait_result,   1,        "T5 frame2 pkt_valid");
        check_eq(pkt_order_id,  16'h0003, "T5 frame2 order_id=3");

        // ================================================================
        $display("\n=== T6: Bad SOF -- silently ignored ===");
        // ================================================================
        // Push a junk byte (not AA) then a valid frame
        push_byte(8'hBB);        // bad SOF, should be discarded
        send_frame(MSG_ADD, 16'h0009, 24'h018700, 16'h0020, 1'b0);
        wait_frame_done;
        check_eq(wait_result,   1,        "T6 valid frame accepted after bad SOF");
        check_eq(pkt_order_id,  16'h0009, "T6 order_id=9");

        // ================================================================
        $display("\n=== T7: Bad EOF -- parse_error then recovery ===");
        // ================================================================
        // Manually push an ADD frame with wrong EOF byte
        frame_buf[0]  = SOF;
        frame_buf[1]  = MSG_ADD;
        frame_buf[2]  = 8'h00; frame_buf[3] = 8'h0A;
        frame_buf[4]  = 8'h01; frame_buf[5] = 8'h86; frame_buf[6] = 8'hA0;
        frame_buf[7]  = 8'h00; frame_buf[8] = 8'h64;
        frame_buf[9]  = 8'h00;
        frame_buf[10] = 8'hFF;  // bad EOF
        for (bi = 0; bi < 11; bi = bi + 1)
            push_byte(frame_buf[bi]);
        wait_frame_done;
        check_eq(wait_result,   0,        "T7 parse_error on bad EOF");

        // Recovery: send a good frame immediately after
        send_frame(MSG_ADD, 16'h000B, 24'h018500, 16'h0080, 1'b0);
        wait_frame_done;
        check_eq(wait_result,   1,        "T7 recovery: good frame accepted");
        check_eq(pkt_order_id,  16'h000B, "T7 recovery order_id=0x0B");

        // ================================================================
        $display("\n========================================");
        $display("  Tests  : %0d", tests_run);
        $display("  Passed : %0d", tests_passed);
        $display("  Failed : %0d", tests_failed);
        if (tests_failed == 0)
            $display("  RESULT :  ALL TESTS PASSED");
        else
            $display("  RESULT :  *** FAILURES DETECTED ***");
        $display("========================================");

        $finish;
    end

endmodule
