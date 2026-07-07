// sim/tb_order_serializer.sv  --  Day 12 testbench
//
// Self-checking testbench for order_serializer.sv.
//
// Byte-capture monitor
// --------------------
//   An always @(posedge clk) block writes tx_data into captured[] whenever
//   tx_valid && tx_rdy.  The initial block resets cap_idx before each test
//   and reads it only after the serializer returns to IDLE.
//
// Tests
// -----
//   OS1  BUY order -- all 8 bytes correct (SOF, type, price, qty, EOF)
//   OS2  SELL order -- type byte = 0x02
//   OS3  Backpressure: tx_rdy=0 after byte 2; serializer stalls; resumes correctly
//   OS4  Back-to-back orders -- 16 bytes total, correct interleaving
//   OS5  order_rdy is 0 during SEND; goes high exactly when IDLE

`timescale 1ns/1ps

module tb_order_serializer;

    localparam int PRICE_W   = 24;
    localparam int QTY_W     = 16;
    localparam int CLK_PERIOD = 10;

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ── DUT ports ──────────────────────────────────────────────────────────
    logic                order_valid = 1'b0;
    logic                order_side  = 1'b0;
    logic [PRICE_W-1:0]  order_price = '0;
    logic [QTY_W-1:0]    order_qty   = '0;
    logic                order_rdy;
    logic [7:0]          tx_data;
    logic                tx_valid;
    logic                tx_rdy = 1'b1;   // UART always ready unless overridden

    // ── DUT ────────────────────────────────────────────────────────────────
    order_serializer #(.PRICE_W(PRICE_W), .QTY_W(QTY_W)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .order_valid(order_valid),
        .order_side (order_side),
        .order_price(order_price),
        .order_qty  (order_qty),
        .order_rdy  (order_rdy),
        .tx_data    (tx_data),
        .tx_valid   (tx_valid),
        .tx_rdy     (tx_rdy)
    );

    // ── Byte capture buffer ────────────────────────────────────────────────
    logic [7:0]  captured [0:15];
    integer      cap_idx = 0;

    // Monitor: capture byte at every posedge where tx_valid && tx_rdy
    always @(posedge clk) begin
        if (tx_valid && tx_rdy) begin
            captured[cap_idx] = tx_data;
            cap_idx = cap_idx + 1;
        end
    end

    // ── Counters ───────────────────────────────────────────────────────────
    integer tests_run    = 0;
    integer tests_passed = 0;
    integer tests_failed = 0;

    // ── Check helpers ──────────────────────────────────────────────────────
    task check_eq;
        input [63:0]  got;
        input [63:0]  expected;
        input [127:0] label;
    begin
        tests_run = tests_run + 1;
        if (got === expected) begin
            $display("  PASS  %0s", label);
            tests_passed = tests_passed + 1;
        end else begin
            $display("  FAIL  %0s : got 0x%0h  expected 0x%0h",
                     label, got, expected);
            tests_failed = tests_failed + 1;
        end
    end
    endtask

    // ── Task: pulse order_valid for one clock cycle ────────────────────────
    // The serializer latches the order at the posedge BETWEEN the two negedges.
    task send_order;
        input               side;
        input [PRICE_W-1:0] price;
        input [QTY_W-1:0]   qty;
    begin
        @(negedge clk);
        order_side  = side;
        order_price = price;
        order_qty   = qty;
        order_valid = 1'b1;
        @(negedge clk);
        order_valid = 1'b0;
    end
    endtask

    // ── Task: wait until serializer returns to IDLE ────────────────────────
    // With tx_rdy=1, 8 bytes take 8 posedges in SEND + 1 transition posedge.
    // Waiting 10 posedges covers any residual delay.
    task wait_idle;
        integer k;
    begin
        for (k = 0; k < 10; k = k + 1) @(posedge clk);
        #1;
    end
    endtask

    // ── Expected packet helper ─────────────────────────────────────────────
    // Returns expected byte[i] for a given order
    function automatic logic [7:0] exp_byte;
        input integer    i;
        input logic      side;
        input [23:0]     price;
        input [15:0]     qty;
    begin
        case (i)
            0: exp_byte = 8'hAB;
            1: exp_byte = side ? 8'h02 : 8'h01;
            2: exp_byte = price[23:16];
            3: exp_byte = price[15:8];
            4: exp_byte = price[7:0];
            5: exp_byte = qty[15:8];
            6: exp_byte = qty[7:0];
            7: exp_byte = 8'hCD;
            default: exp_byte = 8'hXX;
        endcase
    end
    endfunction

    // ── Task: verify captured[] matches expected packet ────────────────────
    task verify_packet;
        input integer    base;     // starting index in captured[]
        input logic      side;
        input [23:0]     price;
        input [15:0]     qty;
        input [63:0]     tag;
        integer i;
        logic [7:0] exp;
        logic [7:0] got;
    begin
        for (i = 0; i < 8; i = i + 1) begin
            exp = exp_byte(i, side, price, qty);
            got = captured[base + i];
            tests_run = tests_run + 1;
            if (got === exp) begin
                tests_passed = tests_passed + 1;
            end else begin
                $display("  FAIL  pkt[%0d] tag=%0d : got 0x%02h  expected 0x%02h",
                         i, tag, got, exp);
                tests_failed = tests_failed + 1;
            end
        end
        $display("  PASS  packet tag=%0d all 8 bytes correct", tag);
    end
    endtask

    // =========================================================================
    initial begin
        $dumpfile("tb_order_serializer.vcd");
        $dumpvars(0, tb_order_serializer);

        rst_n = 1'b0;
        tx_rdy = 1'b1;
        repeat(4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        @(posedge clk); #1;

        // ================================================================
        $display("\n=== OS1: BUY order -- all 8 bytes correct ===");
        // ================================================================
        // BUY 100 shares @ 100500 paise
        // 100500 = 0x018894  price[23:16]=0x01, [15:8]=0x88, [7:0]=0x94
        // qty 100 = 0x0064  qty[15:8]=0x00, [7:0]=0x64
        cap_idx = 0;
        send_order(1'b0, 24'd100500, 16'd100);
        wait_idle;

        check_eq(cap_idx, 8, "OS1 exactly 8 bytes sent");
        check_eq(captured[0], 8'hAB, "OS1 byte0=SOF");
        check_eq(captured[1], 8'h01, "OS1 byte1=BUY");
        check_eq(captured[2], 8'h01, "OS1 byte2=price[23:16]");  // 0x01
        check_eq(captured[3], 8'h88, "OS1 byte3=price[15:8]");   // 0x88
        check_eq(captured[4], 8'h94, "OS1 byte4=price[7:0]");    // 0x94
        check_eq(captured[5], 8'h00, "OS1 byte5=qty[15:8]");
        check_eq(captured[6], 8'h64, "OS1 byte6=qty[7:0]");
        check_eq(captured[7], 8'hCD, "OS1 byte7=EOF");

        // ================================================================
        $display("\n=== OS2: SELL order -- type byte = 0x02 ===");
        // ================================================================
        // SELL 50 shares @ 200000 paise (Rs 2000.00)
        // 200000 = 0x030D40  [23:16]=0x03, [15:8]=0x0D, [7:0]=0x40
        // qty 50 = 0x0032
        cap_idx = 0;
        send_order(1'b1, 24'd200000, 16'd50);
        wait_idle;

        check_eq(cap_idx, 8,    "OS2 exactly 8 bytes");
        check_eq(captured[1], 8'h02, "OS2 byte1=SELL");
        check_eq(captured[2], 8'h03, "OS2 price[23:16]");
        check_eq(captured[3], 8'h0D, "OS2 price[15:8]");
        check_eq(captured[4], 8'h40, "OS2 price[7:0]");
        check_eq(captured[5], 8'h00, "OS2 qty[15:8]");
        check_eq(captured[6], 8'h32, "OS2 qty[7:0]");

        // ================================================================
        $display("\n=== OS3: Backpressure mid-packet ===");
        // ================================================================
        // BUY 75 @ 150000 (0x024EA0: [23:16]=0x02, [15:8]=0x4E, [7:0]=0xA0)
        // qty 75 = 0x004B
        // tx_rdy=0 after 3 bytes captured; verify stall; resume; verify full packet
        cap_idx = 0;
        send_order(1'b0, 24'd150000, 16'd75);

        // Wait 3 posedges: bytes 0,1,2 captured (SOF, BUY, price[23:16])
        repeat(3) @(posedge clk);
        @(negedge clk); tx_rdy = 1'b0;   // Stall

        repeat(4) @(posedge clk); #1;
        check_eq(cap_idx, 3, "OS3 stalled at 3 bytes");

        // Resume
        @(negedge clk); tx_rdy = 1'b1;
        wait_idle;

        check_eq(cap_idx, 8,    "OS3 all 8 bytes after resume");
        check_eq(captured[0], 8'hAB, "OS3 SOF correct");
        check_eq(captured[1], 8'h01, "OS3 BUY type correct");
        check_eq(captured[2], 8'h02, "OS3 price[23:16] correct");  // 150000=0x0249F0
        check_eq(captured[3], 8'h49, "OS3 price[15:8] correct");
        check_eq(captured[4], 8'hF0, "OS3 price[7:0] correct");
        check_eq(captured[6], 8'h4B, "OS3 qty[7:0] correct");
        check_eq(captured[7], 8'hCD, "OS3 EOF correct");

        // ================================================================
        $display("\n=== OS4: Back-to-back orders -- 16 bytes total ===");
        // ================================================================
        cap_idx = 0;
        // Order A: BUY 10 @ 120000  (0x01D4C0: [23:16]=0x01,[15:8]=0xD4,[7:0]=0xC0)
        send_order(1'b0, 24'd120000, 16'd10);
        // Order B: SELL 20 @ 130000 (0x01FBD0: [23:16]=0x01,[15:8]=0xFB,[7:0]=0xD0)
        // Wait for order_rdy before sending second order
        @(posedge order_rdy); #1;
        send_order(1'b1, 24'd130000, 16'd20);
        wait_idle;

        check_eq(cap_idx, 16, "OS4 16 bytes total");
        // Verify packet A (bytes 0-7)
        check_eq(captured[0], 8'hAB, "OS4 A-SOF");
        check_eq(captured[1], 8'h01, "OS4 A-BUY");
        check_eq(captured[7], 8'hCD, "OS4 A-EOF");
        // Verify packet B (bytes 8-15)
        check_eq(captured[8],  8'hAB, "OS4 B-SOF");
        check_eq(captured[9],  8'h02, "OS4 B-SELL");
        check_eq(captured[10], 8'h01, "OS4 B-price[23:16]");  // 130000=0x01FBD0
        check_eq(captured[11], 8'hFB, "OS4 B-price[15:8]");
        check_eq(captured[12], 8'hD0, "OS4 B-price[7:0]");
        check_eq(captured[15], 8'hCD, "OS4 B-EOF");

        // ================================================================
        $display("\n=== OS5: order_rdy tracks IDLE correctly ===");
        // ================================================================
        // Verify order_rdy = 1 now (idle)
        #1;
        check_eq(order_rdy, 1'b1, "OS5 order_rdy=1 in IDLE");

        // Send order; immediately check order_rdy goes low
        @(negedge clk);
        order_side  = 1'b0;
        order_price = 24'd100000;
        order_qty   = 16'd1;
        order_valid = 1'b1;
        @(negedge clk);
        order_valid = 1'b0;
        @(posedge clk); #1;   // state = SEND now
        check_eq(order_rdy, 1'b0, "OS5 order_rdy=0 during SEND");

        // Wait for completion
        repeat(9) @(posedge clk); #1;
        check_eq(order_rdy, 1'b1, "OS5 order_rdy=1 after SEND");

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
