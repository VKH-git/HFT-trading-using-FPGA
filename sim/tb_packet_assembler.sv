// sim/tb_packet_assembler.sv
// Self-checking testbench for packet_assembler.sv
//
// ── WHY THE ORIGINAL FAILED (ALL 13 FAILURES) ────────────────────
//
// push_byte() used @(posedge clk) for both the "drive" edge and the
// "clear" edge.  The DUT's always_ff also fires on posedge clk, so
// there was a scheduling race at every byte boundary: the TB could
// clear rx_valid BEFORE the DUT evaluated it (or the DUT could
// evaluate with the already-cleared value).
//
// On top of that, send_frame added a whole extra @(posedge clk) after
// push_byte(EOF) returned.  By that next rising edge the DUT had
// already fired its "default: pkt_valid <= 0", so every sample of
// pkt_valid read 0.  The same off-by-one clock problem hit every
// parse_error check in tests 6-9.
//
// ── THE FIX ───────────────────────────────────────────────────────
//
// push_byte() now drives signals on NEGEDGE clk (mid-cycle).  This
// is the standard "drive-on-negedge / sample-on-posedge" convention
// used in real chip testbenches:
//
//   negedge N  : TB drives rx_data=b, rx_valid=1   (½ cycle setup)
//   posedge N+1: DUT latches — no race, clean capture
//   negedge N+1: TB clears rx_valid; push_byte() returns HERE
//
// When push_byte(EOF) returns (at negedge N+1), pkt_valid has already
// been set to 1 by the NBA committed at posedge N+1, and the NEXT
// posedge that would clear it is still 5 ns away.  Sampling
// immediately (or with a short #1 for clarity) gets the right value.
//
// ── IVERILOG 12 COMPATIBILITY ─────────────────────────────────────
// 1. RTL: replaced unsupported 'inside {}' with a valid_type() helper.
// 2. TB:  'automatic' local variables inside begin..end are not
//    supported; all temporaries hoisted to module level.
//
// Tests:
//   1. ADD frame    — verify all fields decoded correctly
//   2. CANCEL frame — verify type=1
//   3. TRADE frame  — verify type=2, price, qty, side
//   4. HEARTBEAT    — verify type=3, pkt_valid still fires
//   5. Bad SOF      — parse_error must NOT fire, just ignored
//   6. Bad EOF      — parse_error must fire, frame dropped
//   7. Bad msg_type — parse_error fires, recovery to next valid frame
//   8. rx_error mid-frame — parse_error fires, recovery works
//   9. Back-to-back frames — two frames with no gap between them

`timescale 1ns/1ps

module tb_packet_assembler;

    // 100 MHz clock — posedges at 5, 15, 25 … ns
    //                 negedges at 10, 20, 30 … ns
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0;

    // DUT ports
    logic [7:0]  rx_data  = 0;
    logic        rx_valid = 0;
    logic        rx_error = 0;
    logic        pkt_valid;
    logic [1:0]  pkt_type;
    logic [15:0] pkt_order_id;
    logic [23:0] pkt_price;
    logic [15:0] pkt_qty;
    logic        pkt_side;
    logic        parse_error;

    packet_assembler dut (.*);;

    int total_tests  = 0;
    int total_errors = 0;

    // Module-level temporaries (iverilog 12 forbids 'automatic' locals
    // inside begin..end blocks within an initial block)
    logic got_v, got_e, err_seen, v1;

    // ─────────────────────────────────────────────────────────────────
    // push_byte — drive one byte with negedge-to-negedge timing.
    //
    //   negedge N   : rx_data = b, rx_valid = 1   (setup before posedge)
    //   posedge N+1 : DUT latches byte             (no race)
    //   negedge N+1 : rx_valid = 0, rx_data = 0   (hold after posedge)
    //   (return)    : caller is at negedge N+1;
    //                 DUT's NBA from posedge N+1 already committed.
    //
    // After push_byte(EOF) returns, pkt_valid is already 1 and the
    // next posedge that would clear it is 5 ns in the future.
    // ─────────────────────────────────────────────────────────────────
    task automatic push_byte(input logic [7:0] b);
        @(negedge clk);
        rx_data  = b;
        rx_valid = 1'b1;
        @(negedge clk);     // posedge in between captured the byte
        rx_valid = 1'b0;
        rx_data  = 8'h00;
    endtask

    // ─────────────────────────────────────────────────────────────────
    // send_frame — send all 11 bytes and return sampled strobes.
    //
    // After push_byte(EOF) the DUT's pkt_valid NBA has committed.
    // We sample immediately; #1 just makes the intent explicit.
    // ─────────────────────────────────────────────────────────────────
    task automatic send_frame(
        input  logic [7:0]  msg_type,
        input  logic [15:0] order_id,
        input  logic [23:0] price,
        input  logic [15:0] qty,
        input  logic        side,
        output logic        got_valid,
        output logic        got_error
    );
        got_valid = 0;
        got_error = 0;

        push_byte(8'hAA);
        push_byte(msg_type);
        push_byte(order_id[15:8]);
        push_byte(order_id[7:0]);
        push_byte(price[23:16]);
        push_byte(price[15:8]);
        push_byte(price[7:0]);
        push_byte(qty[15:8]);
        push_byte(qty[7:0]);
        push_byte({7'b0, side});
        push_byte(8'h55);   // EOF — DUT fires pkt_valid at posedge inside this call

        // At this negedge the DUT's NBA has committed; next posedge is
        // still 5 ns away — plenty of time to sample cleanly.
        #1;
        got_valid = pkt_valid;
        got_error = parse_error;
    endtask

    // ── check helpers ────────────────────────────────────────────────
    task automatic check_eq(
        input string       label,
        input logic [23:0] got,
        input logic [23:0] expected
    );
        total_tests++;
        if (got === expected)
            $display("    PASS  %s = 0x%06X", label, got);
        else begin
            $display("    FAIL  %s: got 0x%06X expected 0x%06X", label, got, expected);
            total_errors++;
        end
    endtask

    task automatic check_bit(
        input string label,
        input logic  got,
        input logic  expected
    );
        total_tests++;
        if (got === expected)
            $display("    PASS  %s = %0b", label, got);
        else begin
            $display("    FAIL  %s: got %0b expected %0b", label, got, expected);
            total_errors++;
        end
    endtask

    // ═════════════════════════════════════════════════════════════════
    initial begin
        $dumpfile("tb_packet_assembler.vcd");
        $dumpvars(0, tb_packet_assembler);

        // Reset
        rst_n = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // ── Test 1: ADD frame ─────────────────────────────────────────
        $display("\n=== Test 1: ADD frame ===");
        send_frame(8'h01, 16'h0001, 24'h0186A0, 16'h0064, 1'b0, got_v, got_e);
        check_bit("pkt_valid",    got_v,        1'b1);
        check_bit("parse_error",  got_e,        1'b0);
        check_eq ("pkt_type",     pkt_type,     2'd0);
        check_eq ("pkt_order_id", pkt_order_id, 16'h0001);
        check_eq ("pkt_price",    pkt_price,    24'h0186A0);
        check_eq ("pkt_qty",      pkt_qty,      16'h0064);
        check_bit("pkt_side",     pkt_side,     1'b0);

        // ── Test 2: CANCEL frame ──────────────────────────────────────
        $display("\n=== Test 2: CANCEL frame ===");
        send_frame(8'h02, 16'h0001, 24'h0186A0, 16'h0064, 1'b0, got_v, got_e);
        check_bit("pkt_valid",   got_v,    1'b1);
        check_eq ("pkt_type",    pkt_type, 2'd1);

        // ── Test 3: TRADE frame ───────────────────────────────────────
        $display("\n=== Test 3: TRADE frame ===");
        send_frame(8'h03, 16'h0002, 24'h0186D2, 16'h0032, 1'b1, got_v, got_e);
        check_bit("pkt_valid",  got_v,     1'b1);
        check_eq ("pkt_type",   pkt_type,  2'd2);
        check_eq ("pkt_price",  pkt_price, 24'h0186D2);
        check_eq ("pkt_qty",    pkt_qty,   16'h0032);
        check_bit("pkt_side",   pkt_side,  1'b1);

        // ── Test 4: HEARTBEAT ─────────────────────────────────────────
        $display("\n=== Test 4: HEARTBEAT frame ===");
        send_frame(8'h04, 16'h0000, 24'h000000, 16'h0000, 1'b0, got_v, got_e);
        check_bit("pkt_valid",   got_v,    1'b1);
        check_bit("parse_error", got_e,    1'b0);
        check_eq ("pkt_type",    pkt_type, 2'd3);

        // ── Test 5: bad SOF — must be silently ignored ────────────────
        $display("\n=== Test 5: bad SOF (should be ignored) ===");
        err_seen = 0;
        total_tests++;
        push_byte(8'hBB);  // not 0xAA — dropped silently in S_IDLE
        #1;                // DUT NBA committed; parse_error must be 0
        if (parse_error) begin
            $display("    FAIL  parse_error fired on bad SOF (should be silent)");
            total_errors++;
            err_seen = 1;
        end
        if (!err_seen)
            $display("    PASS  bad SOF silently ignored");

        send_frame(8'h01, 16'h0003, 24'h01D4C0, 16'h00C8, 1'b0, got_v, got_e);
        total_tests++;
        if (got_v) $display("    PASS  valid frame accepted after bad SOF");
        else begin
            $display("    FAIL  assembler stuck after bad SOF");
            total_errors++;
        end

        // ── Test 6: bad EOF ───────────────────────────────────────────
        // parse_error must pulse; assembler must recover.
        $display("\n=== Test 6: bad EOF ===");
        total_tests++;
        push_byte(8'hAA);
        push_byte(8'h01);
        push_byte(8'h00); push_byte(8'h04);
        push_byte(8'h01); push_byte(8'h86); push_byte(8'hA0);
        push_byte(8'h00); push_byte(8'h64);
        push_byte(8'h00);
        push_byte(8'hFF);   // bad EOF — parse_error fires at posedge inside this call
        #1;
        if (parse_error)
            $display("    PASS  parse_error fired on bad EOF");
        else begin
            $display("    FAIL  parse_error did not fire on bad EOF");
            total_errors++;
        end

        send_frame(8'h01, 16'h0005, 24'h0186A0, 16'h0064, 1'b1, got_v, got_e);
        total_tests++;
        if (got_v) $display("    PASS  recovered correctly after bad EOF");
        else begin
            $display("    FAIL  stuck after bad EOF");
            total_errors++;
        end

        // ── Test 7: unknown msg_type ──────────────────────────────────
        // parse_error fires after the type byte; assembler resets to IDLE.
        $display("\n=== Test 7: unknown msg_type ===");
        total_tests++;
        push_byte(8'hAA);   // SOF
        push_byte(8'hFF);   // unknown type — parse_error fires at posedge inside
        #1;
        if (parse_error)
            $display("    PASS  parse_error fired on unknown type");
        else begin
            $display("    FAIL  no parse_error on unknown type");
            total_errors++;
        end

        send_frame(8'h02, 16'h0006, 24'h018000, 16'h0050, 1'b0, got_v, got_e);
        total_tests++;
        if (got_v) $display("    PASS  recovered after unknown type");
        else begin
            $display("    FAIL  stuck after unknown type");
            total_errors++;
        end

        // ── Test 8: rx_error mid-frame ────────────────────────────────
        // Drive rx_error on negedge → captured at next posedge → parse_error.
        $display("\n=== Test 8: rx_error mid-frame ===");
        total_tests++;
        push_byte(8'hAA);   // SOF → S_TYPE
        push_byte(8'h01);   // ADD → S_OID_H
        push_byte(8'h00);   // oid_h → S_OID_L

        // Idle one negedge so the DUT has moved on from the last byte,
        // then assert rx_error for exactly one clock period.
        @(negedge clk);     // idle half-cycle — DUT posedge sees rx_valid=0
        rx_error = 1'b1;    // assert at negedge: captured at next posedge
        @(negedge clk);     // posedge in between: DUT fires parse_error<=1 (NBA)
        rx_error = 1'b0;    // deassert; NBA already committed parse_error=1
        #1;                 // confirm NBA settled; next posedge 4 ns away
        if (parse_error)
            $display("    PASS  parse_error fired on rx_error mid-frame");
        else begin
            $display("    FAIL  no parse_error on rx_error mid-frame");
            total_errors++;
        end

        send_frame(8'h03, 16'h0007, 24'h019000, 16'h001E, 1'b1, got_v, got_e);
        total_tests++;
        if (got_v) $display("    PASS  recovered after rx_error");
        else begin
            $display("    FAIL  stuck after rx_error");
            total_errors++;
        end

        // ── Test 9: back-to-back frames ───────────────────────────────
        // Frame 1 EOF fires pkt_valid; frame 2 SOF immediately follows.
        $display("\n=== Test 9: back-to-back frames ===");

        // Frame 1: ADD BID id=8 price=0x0186A0 qty=10
        push_byte(8'hAA); push_byte(8'h01);
        push_byte(8'h00); push_byte(8'h08);
        push_byte(8'h01); push_byte(8'h86); push_byte(8'hA0);
        push_byte(8'h00); push_byte(8'h0A);
        push_byte(8'h00); push_byte(8'h55);  // EOF — pkt_valid set at posedge inside
        #1;                                   // DUT NBA committed, next posedge 4ns away
        v1 = pkt_valid;
        total_tests++;
        if (v1) $display("    PASS  frame 1 pkt_valid");
        else begin $display("    FAIL  frame 1 missed"); total_errors++; end

        // Frame 2: CANCEL ASK id=9 price=0x0186A4 qty=5 — starts immediately
        push_byte(8'hAA); push_byte(8'h02);
        push_byte(8'h00); push_byte(8'h09);
        push_byte(8'h01); push_byte(8'h86); push_byte(8'hA4);
        push_byte(8'h00); push_byte(8'h05);
        push_byte(8'h01); push_byte(8'h55);  // EOF frame 2
        #1;

        total_tests++;
        if (pkt_valid && pkt_type == 2'd1 && pkt_order_id == 16'h0009)
            $display("    PASS  frame 2 decoded correctly (CANCEL id=9)");
        else begin
            $display("    FAIL  frame 2: valid=%b type=%0d id=%0d",
                     pkt_valid, pkt_type, pkt_order_id);
            total_errors++;
        end

        // ── Summary ───────────────────────────────────────────────────
        repeat(4) @(posedge clk);
        $display("\n========================================");
        $display("  Tests  : %0d", total_tests);
        $display("  Passed : %0d", total_tests - total_errors);
        $display("  Failed : %0d", total_errors);
        $display("  RESULT : %s",
                 total_errors == 0 ? "ALL TESTS PASSED" : "FAILURES DETECTED");
        $display("========================================");
        $finish;
    end

endmodule
