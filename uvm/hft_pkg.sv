// uvm/hft_pkg.sv
// Complete UVM verification package for the HFT trading_top DUT.
//
// Contains (in dependency order):
//   hft_seq_item   -- stimulus transaction (FRAME or FILL)
//   hft_obs_item   -- monitor observation (one per active cycle)
//   hft_*_seq      -- sequences: smoke, vwap, breach, random
//   hft_driver     -- UART byte-level driver + fill driver
//   hft_monitor    -- clocking-block sampler -> analysis port
//   hft_scoreboard -- DUT output checker (mutual-exclusion rule)
//   hft_coverage   -- functional covergroups (pkt_type, sig_source, breach, cross)
//   hft_agent      -- driver + monitor + sequencer bundle
//   hft_env        -- agent + scoreboard + coverage
//   hft_*_test     -- base, smoke, breach, random tests

`ifndef HFT_PKG_SV
`define HFT_PKG_SV

package hft_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // ── Shared parameters (must match tb_uvm_top instantiation) ───────────
    localparam int BIT_CYCLES = 10;   // CLK_FREQ/BAUD = 100M/10M

    // ── Enums ──────────────────────────────────────────────────────────────
    typedef enum logic [1:0] {
        PKT_ADD = 2'd0,
        PKT_CAN = 2'd1,
        PKT_TRD = 2'd2,
        PKT_HB  = 2'd3
    } pkt_type_e;

    typedef enum { TXN_FRAME, TXN_FILL } txn_kind_e;

    // =========================================================================
    // hft_seq_item — stimulus transaction
    // =========================================================================
    class hft_seq_item extends uvm_sequence_item;
        `uvm_object_utils_begin(hft_seq_item)
            `uvm_field_enum(txn_kind_e, kind,     UVM_ALL_ON)
            `uvm_field_enum(pkt_type_e, pkt_type, UVM_ALL_ON)
            `uvm_field_int(order_id,  UVM_ALL_ON)
            `uvm_field_int(price,     UVM_ALL_ON)
            `uvm_field_int(qty,       UVM_ALL_ON)
            `uvm_field_int(side,      UVM_ALL_ON)
            `uvm_field_int(fill_side, UVM_ALL_ON)
            `uvm_field_int(fill_price,UVM_ALL_ON)
            `uvm_field_int(fill_qty,  UVM_ALL_ON)
        `uvm_object_utils_end

        // Frame fields
        rand txn_kind_e   kind;
        rand pkt_type_e   pkt_type;
        rand logic [15:0] order_id;
        rand logic [23:0] price;
        rand logic [15:0] qty;
        rand logic        side;    // 0=BID  1=ASK

        // Fill fields (used when kind==TXN_FILL)
        rand logic        fill_side;
        rand logic [23:0] fill_price;
        rand logic [15:0] fill_qty;

        // ── Constraints ─────────────────────────────────────────────────────
        // Prices in a 2000-paise window centred on 100000
        constraint c_price_range {
            if (kind == TXN_FRAME) price inside {[99000:101000]};
        }
        // BID below mid, ASK above mid (realistic spread)
        constraint c_spread {
            if (kind == TXN_FRAME && pkt_type == PKT_ADD) {
                if (!side) price inside {[99000:99999]};
                else       price inside {[100001:101000]};
            }
        }
        // TRADE prices anywhere in range
        constraint c_trade_px {
            if (kind == TXN_FRAME && pkt_type == PKT_TRD)
                price inside {[99500:100500]};
        }
        // Qty in lot multiples
        constraint c_qty { qty inside {[100:500]}; }
        // Fill fields valid for TXN_FILL
        constraint c_fill {
            if (kind == TXN_FILL) {
                fill_price inside {[99000:101000]};
                fill_qty   inside {[50:200]};
                // pkt fields not used: keep legal to avoid conflicting constraints
                pkt_type == PKT_HB; price == 0; qty == 100; side == 0;
            }
        }

        function new(string name = "hft_seq_item");
            super.new(name);
        endfunction
    endclass : hft_seq_item

    // =========================================================================
    // hft_obs_item — monitor observation (one per active cycle)
    // =========================================================================
    class hft_obs_item extends uvm_sequence_item;
        `uvm_object_utils(hft_obs_item)

        // All fields from mon_* captured in the same clock cycle
        logic        pkt_valid;
        logic [1:0]  pkt_type;
        logic        sig_valid;
        logic [1:0]  sig_source;   // 0=VWAP  1=MOM
        logic        order_valid;
        logic [3:0]  breach_flags; // [0]=pos [1]=qty [2]=price [3]=rate
        logic signed [63:0] running_pnl;
        logic [31:0] fill_count;

        function new(string name = "hft_obs_item");
            super.new(name);
        endfunction

        function string convert2string();
            return $sformatf(
                "pkt=%0b(t%0d) sig=%0b(src=%0d) ord=%0b brch=0x%0h pnl=%0d fc=%0d",
                pkt_valid, pkt_type, sig_valid, sig_source,
                order_valid, breach_flags, running_pnl, fill_count);
        endfunction
    endclass : hft_obs_item

    // =========================================================================
    // Sequences
    // =========================================================================
    // Base: helpers shared by all sequences
    class hft_base_seq extends uvm_sequence #(hft_seq_item);
        `uvm_object_utils(hft_base_seq)

        function new(string name = "hft_base_seq");
            super.new(name);
        endfunction

        // ── Helpers ──────────────────────────────────────────────────────────
        protected task send_frame(pkt_type_e pt, logic [15:0] oid,
                                   logic [23:0] px, logic [15:0] q, logic s);
            hft_seq_item it = hft_seq_item::type_id::create("it");
            start_item(it);
            it.kind = TXN_FRAME; it.pkt_type = pt;
            it.order_id = oid; it.price = px; it.qty = q; it.side = s;
            finish_item(it);
        endtask

        protected task send_fill(logic fs, logic [23:0] fp, logic [15:0] fq);
            hft_seq_item it = hft_seq_item::type_id::create("it");
            start_item(it);
            it.kind = TXN_FILL; it.fill_side = fs;
            it.fill_price = fp; it.fill_qty = fq;
            finish_item(it);
        endtask

        task body(); endtask
    endclass : hft_base_seq

    // Smoke: minimal book + one VWAP-triggering TRADE
    class hft_smoke_seq extends hft_base_seq;
        `uvm_object_utils(hft_smoke_seq)
        function new(string name="hft_smoke_seq"); super.new(name); endfunction

        task body();
            `uvm_info("SEQ", "smoke_seq: ADD BID, ADD ASK, TRADE -> VWAP BUY", UVM_MEDIUM)
            send_frame(PKT_ADD, 16'd1, 24'd99980,  16'd200, 1'b0);  // BID
            send_frame(PKT_ADD, 16'd2, 24'd100020, 16'd100, 1'b1);  // ASK
            send_frame(PKT_TRD, 16'd0, 24'd100100, 16'd100, 1'b1);  // TRADE
        endtask
    endclass : hft_smoke_seq

    // VWAP + fill round-trip P&L check
    class hft_vwap_seq extends hft_base_seq;
        `uvm_object_utils(hft_vwap_seq)
        function new(string name="hft_vwap_seq"); super.new(name); endfunction

        task body();
            `uvm_info("SEQ", "vwap_seq: book + TRADE + BUY fill + SELL fill", UVM_MEDIUM)
            send_frame(PKT_ADD, 16'd1, 24'd99980,  16'd200, 1'b0);
            send_frame(PKT_ADD, 16'd2, 24'd100020, 16'd100, 1'b1);
            send_frame(PKT_TRD, 16'd0, 24'd100100, 16'd100, 1'b1);  // BUY order fires
            send_fill(1'b0, 24'd100020, 16'd100);                    // BUY fill confirm
            send_fill(1'b1, 24'd100100, 16'd100);                    // SELL fill confirm
        endtask
    endclass : hft_vwap_seq

    // Breach: fill position to max, then re-trigger -> expect pos breach
    class hft_breach_seq extends hft_base_seq;
        `uvm_object_utils(hft_breach_seq)
        function new(string name="hft_breach_seq"); super.new(name); endfunction

        task body();
            `uvm_info("SEQ", "breach_seq: max position -> BUY blocked", UVM_MEDIUM)
            send_frame(PKT_ADD, 16'd1, 24'd99980,  16'd200, 1'b0);
            send_frame(PKT_ADD, 16'd2, 24'd100020, 16'd100, 1'b1);
            send_frame(PKT_TRD, 16'd0, 24'd100100, 16'd100, 1'b1);  // first order ok
            send_fill(1'b0, 24'd100000, 16'd1000);                   // BUY 1000 -> max long
            send_frame(PKT_TRD, 16'd0, 24'd100100, 16'd100, 1'b1);  // expect breach[0]
        endtask
    endclass : hft_breach_seq

    // Constrained-random: N random TRADE frames after book setup
    class hft_rand_seq extends hft_base_seq;
        `uvm_object_utils(hft_rand_seq)
        int unsigned num_items = 15;
        function new(string name="hft_rand_seq"); super.new(name); endfunction

        task body();
            hft_seq_item it;
            `uvm_info("SEQ", $sformatf("rand_seq: %0d random TRADEs", num_items), UVM_MEDIUM)
            send_frame(PKT_ADD, 16'd1, 24'd99980,  16'd200, 1'b0);
            send_frame(PKT_ADD, 16'd2, 24'd100020, 16'd100, 1'b1);
            repeat(num_items) begin
                it = hft_seq_item::type_id::create("rand_it");
                start_item(it);
                if (!it.randomize() with {
                        kind     == TXN_FRAME;
                        pkt_type == PKT_TRD;
                        price inside {[99800:100200]};
                    })
                    `uvm_fatal("RAND", "hft_rand_seq: randomization failed")
                finish_item(it);
            end
        endtask
    endclass : hft_rand_seq

    // =========================================================================
    // hft_driver — converts seq_items to UART/fill stimulus
    // =========================================================================
    class hft_driver extends uvm_driver #(hft_seq_item);
        `uvm_component_utils(hft_driver)

        virtual hft_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual hft_if)::get(this, "", "vif", vif))
                `uvm_fatal("NO_VIF", "hft_driver: virtual interface not found in config_db")
        endfunction

        task run_phase(uvm_phase phase);
            hft_seq_item item;
            vif.uart_rxd   = 1'b1;  // idle high
            vif.fill_valid = 1'b0;
            @(posedge vif.clk iff vif.rst_n);  // wait until out of reset
            forever begin
                seq_item_port.get_next_item(item);
                `uvm_info("DRV", {"Driving: ", item.convert2string()}, UVM_HIGH)
                if (item.kind == TXN_FRAME) drive_frame(item);
                else                         drive_fill(item);
                seq_item_port.item_done();
            end
        endtask

        // ── UART byte (8N1) ────────────────────────────────────────────────
        task drive_byte(logic [7:0] data);
            vif.uart_rxd = 1'b0;                           // start bit
            repeat(BIT_CYCLES) @(posedge vif.clk);
            for (int i = 0; i < 8; i++) begin
                vif.uart_rxd = data[i];                    // LSB first
                repeat(BIT_CYCLES) @(posedge vif.clk);
            end
            vif.uart_rxd = 1'b1;                           // stop bit
            repeat(BIT_CYCLES) @(posedge vif.clk);
        endtask

        // ── 11-byte protocol frame ─────────────────────────────────────────
        task drive_frame(hft_seq_item item);
            logic [7:0] type_byte;
            case (item.pkt_type)
                PKT_ADD: type_byte = 8'h01;
                PKT_CAN: type_byte = 8'h02;
                PKT_TRD: type_byte = 8'h03;
                PKT_HB:  type_byte = 8'h04;
                default: type_byte = 8'h01;
            endcase
            drive_byte(8'hAA);                             // SOF
            drive_byte(type_byte);                         // msg type
            drive_byte(item.order_id[15:8]);
            drive_byte(item.order_id[7:0]);
            drive_byte(item.price[23:16]);
            drive_byte(item.price[15:8]);
            drive_byte(item.price[7:0]);
            drive_byte(item.qty[15:8]);
            drive_byte(item.qty[7:0]);
            drive_byte(item.side ? 8'h01 : 8'h00);
            drive_byte(8'h55);                             // EOF
            repeat(30) @(posedge vif.clk);                // pipeline settle
        endtask

        // ── Single-cycle fill pulse ────────────────────────────────────────
        task drive_fill(hft_seq_item item);
            @(negedge vif.clk);
            vif.fill_valid = 1'b1;
            vif.fill_side  = item.fill_side;
            vif.fill_price = item.fill_price;
            vif.fill_qty   = item.fill_qty;
            @(negedge vif.clk);
            vif.fill_valid = 1'b0;
            repeat(5) @(posedge vif.clk);
        endtask
    endclass : hft_driver

    // =========================================================================
    // hft_monitor — samples DUT outputs each cycle via clocking block
    // =========================================================================
    class hft_monitor extends uvm_monitor;
        `uvm_component_utils(hft_monitor)

        virtual hft_if          vif;
        uvm_analysis_port #(hft_obs_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual hft_if)::get(this, "", "vif", vif))
                `uvm_fatal("NO_VIF", "hft_monitor: virtual interface not found")
        endfunction

        task run_phase(uvm_phase phase);
            hft_obs_item obs;
            forever begin
                @(vif.mon_cb);
                // Create one observation per cycle whenever anything is active
                if (vif.mon_cb.mon_pkt_valid  ||
                    vif.mon_cb.mon_sig_valid   ||
                    vif.mon_cb.mon_order_valid ||
                    |vif.mon_cb.mon_breach_flags) begin

                    obs = hft_obs_item::type_id::create("obs");
                    obs.pkt_valid    = vif.mon_cb.mon_pkt_valid;
                    obs.pkt_type     = vif.mon_cb.mon_pkt_type;
                    obs.sig_valid    = vif.mon_cb.mon_sig_valid;
                    obs.sig_source   = vif.mon_cb.mon_sig_source;
                    obs.order_valid  = vif.mon_cb.mon_order_valid;
                    obs.breach_flags = vif.mon_cb.mon_breach_flags;
                    obs.running_pnl  = vif.mon_cb.mon_running_pnl;
                    obs.fill_count   = vif.mon_cb.mon_fill_count;
                    `uvm_info("MON", obs.convert2string(), UVM_DEBUG)
                    ap.write(obs);
                end
            end
        endtask
    endclass : hft_monitor

    // =========================================================================
    // hft_scoreboard — correctness checker
    // Rule: order_valid and non-zero breach_flags are mutually exclusive.
    // Rule: fill_count must be monotonically non-decreasing.
    // =========================================================================
    class hft_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(hft_scoreboard)

        uvm_analysis_imp #(hft_obs_item, hft_scoreboard) analysis_export;

        int pkt_count    = 0;
        int sig_count    = 0;
        int order_count  = 0;
        int breach_count = 0;
        int errors       = 0;
        int prev_fill_count = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            analysis_export = new("analysis_export", this);
        endfunction

        // Called by monitor via analysis port write()
        function void write(hft_obs_item obs);
            if (obs.pkt_valid)   pkt_count++;
            if (obs.sig_valid)   sig_count++;
            if (obs.order_valid) order_count++;
            if (|obs.breach_flags) breach_count++;

            // ── Rule 1: order_valid and breach must be mutually exclusive ──
            if (obs.order_valid && |obs.breach_flags) begin
                `uvm_error("SB/MUTEX",
                    $sformatf("order_valid=1 AND breach_flags=0x%0h in same cycle!",
                              obs.breach_flags))
                errors++;
            end

            // ── Rule 2: fill_count must never decrease ─────────────────────
            if (int'(obs.fill_count) < prev_fill_count) begin
                `uvm_error("SB/FILLCNT",
                    $sformatf("fill_count decreased: %0d -> %0d",
                               prev_fill_count, obs.fill_count))
                errors++;
            end
            prev_fill_count = int'(obs.fill_count);
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf(
                "\n  ===== Scoreboard Report =====\n"  ,
                "  pkts=%0d  sigs=%0d  orders=%0d  breaches=%0d\n",
                "  errors=%0d",
                pkt_count, sig_count, order_count, breach_count, errors),
                UVM_NONE)
            if (errors == 0)
                `uvm_info("SB",  "  *** SCOREBOARD: ALL CHECKS PASSED ***", UVM_NONE)
            else
                `uvm_error("SB", $sformatf("  *** SCOREBOARD: %0d ERRORS ***", errors))
        endfunction
    endclass : hft_scoreboard

    // =========================================================================
    // hft_coverage — functional coverage
    // =========================================================================
    class hft_coverage extends uvm_subscriber #(hft_obs_item);
        `uvm_component_utils(hft_coverage)

        hft_obs_item curr;

        covergroup hft_cg;
            // All four packet types exercised
            cp_pkt_type: coverpoint curr.pkt_type iff (curr.pkt_valid) {
                bins add = {PKT_ADD};
                bins can = {PKT_CAN};
                bins trd = {PKT_TRD};
                bins hb  = {PKT_HB};
            }
            // Both strategies fire
            cp_sig_src: coverpoint curr.sig_source iff (curr.sig_valid) {
                bins vwap = {2'd0};
                bins mom  = {2'd1};
            }
            // Individual breach bits
            cp_breach_pos:   coverpoint curr.breach_flags[0];
            cp_breach_qty:   coverpoint curr.breach_flags[1];
            cp_breach_price: coverpoint curr.breach_flags[2];
            cp_breach_rate:  coverpoint curr.breach_flags[3];
            // Order approved vs rejected
            cp_order: coverpoint curr.order_valid iff (curr.sig_valid) {
                bins approved = {1'b1};
                bins rejected = {1'b0};
            }
            // Cross: did every pkt type eventually lead to an approved order?
            cx_pkt_order: cross cp_pkt_type, cp_order;
            // Cross: both strategies in both outcomes
            cx_src_order: cross cp_sig_src, cp_order;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            hft_cg = new();
        endfunction

        // uvm_subscriber provides analysis_export; write() is the callback
        function void write(hft_obs_item obs);
            curr = obs;
            hft_cg.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("COV",
                $sformatf("Functional coverage: %.1f%%", hft_cg.get_coverage()),
                UVM_NONE)
        endfunction
    endclass : hft_coverage

    // =========================================================================
    // hft_agent — bundles driver + monitor + sequencer
    // =========================================================================
    class hft_agent extends uvm_agent;
        `uvm_component_utils(hft_agent)

        hft_driver   driver;
        hft_monitor  monitor;
        uvm_sequencer #(hft_seq_item) sequencer;

        // Passthrough: environment connects this to scoreboard/coverage
        uvm_analysis_port #(hft_obs_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            sequencer = uvm_sequencer #(hft_seq_item)::type_id::create("sequencer", this);
            driver    = hft_driver ::type_id::create("driver",    this);
            monitor   = hft_monitor::type_id::create("monitor",   this);
            ap        = new("ap", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            driver.seq_item_port.connect(sequencer.seq_item_export);
            monitor.ap.connect(ap);  // bubble analysis port up to env
        endfunction
    endclass : hft_agent

    // =========================================================================
    // hft_env — top-level environment
    // =========================================================================
    class hft_env extends uvm_env;
        `uvm_component_utils(hft_env)

        hft_agent      agent;
        hft_scoreboard scoreboard;
        hft_coverage   coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent      = hft_agent     ::type_id::create("agent",      this);
            scoreboard = hft_scoreboard::type_id::create("scoreboard", this);
            coverage   = hft_coverage  ::type_id::create("coverage",   this);
        endfunction

        function void connect_phase(uvm_phase phase);
            // Fan out monitor analysis port to scoreboard and coverage
            agent.ap.connect(scoreboard.analysis_export);
            agent.ap.connect(coverage.analysis_export);
        endfunction
    endclass : hft_env

    // =========================================================================
    // Tests
    // =========================================================================
    class hft_base_test extends uvm_test;
        `uvm_component_utils(hft_base_test)

        hft_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = hft_env::type_id::create("env", this);
        endfunction

        // Subclasses override run_phase to pick a sequence
        task run_phase(uvm_phase phase);
            phase.raise_objection(this);
            #100;
            phase.drop_objection(this);
        endtask
    endclass : hft_base_test

    // Smoke test: builds book, fires VWAP BUY
    class hft_smoke_test extends hft_base_test;
        `uvm_component_utils(hft_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        task run_phase(uvm_phase phase);
            hft_smoke_seq seq = hft_smoke_seq::type_id::create("seq");
            phase.raise_objection(this);
            `uvm_info("TEST", "Running smoke test", UVM_NONE)
            seq.start(env.agent.sequencer);
            #50000;  // allow pipeline to fully drain
            phase.drop_objection(this);
        endtask
    endclass : hft_smoke_test

    // VWAP test: book + order + fill round-trip P&L
    class hft_vwap_test extends hft_base_test;
        `uvm_component_utils(hft_vwap_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        task run_phase(uvm_phase phase);
            hft_vwap_seq seq = hft_vwap_seq::type_id::create("seq");
            phase.raise_objection(this);
            `uvm_info("TEST", "Running VWAP+fill P&L test", UVM_NONE)
            seq.start(env.agent.sequencer);
            #50000;
            phase.drop_objection(this);
        endtask
    endclass : hft_vwap_test

    // Breach test: verifies risk gate blocks over-limit BUY
    class hft_breach_test extends hft_base_test;
        `uvm_component_utils(hft_breach_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        task run_phase(uvm_phase phase);
            hft_breach_seq seq = hft_breach_seq::type_id::create("seq");
            phase.raise_objection(this);
            `uvm_info("TEST", "Running position-breach test", UVM_NONE)
            seq.start(env.agent.sequencer);
            #50000;
            phase.drop_objection(this);
        endtask
    endclass : hft_breach_test

    // Random test: constrained-random TRADE stream
    class hft_rand_test extends hft_base_test;
        `uvm_component_utils(hft_rand_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        task run_phase(uvm_phase phase);
            hft_rand_seq seq = hft_rand_seq::type_id::create("seq");
            phase.raise_objection(this);
            `uvm_info("TEST", "Running constrained-random test (15 TRADEs)", UVM_NONE)
            seq.num_items = 15;
            seq.start(env.agent.sequencer);
            #100000;
            phase.drop_objection(this);
        endtask
    endclass : hft_rand_test

endpackage : hft_pkg

`endif // HFT_PKG_SV
