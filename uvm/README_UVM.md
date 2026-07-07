# UVM Testbench — HFT Trading System

## Overview

A complete UVM-1.2 testbench for `trading_top.sv`.
Targets **Mentor Questa / Synopsys VCS / Cadence Xcelium**.
iverilog does **not** support UVM — use the `sim/tb_system.sv` directed testbench with iverilog.

---

## File Map

| File | Role | Key Skills Shown |
|------|------|-----------------|
| [hft_if.sv](hft_if.sv) | Interface + clocking blocks | Modports, `clocking` with skew |
| [hft_pkg.sv](hft_pkg.sv) | All UVM classes (one package) | Factory, TLM, constraints, coverage |
| [tb_uvm_top.sv](tb_uvm_top.sv) | Top module + DUT instantiation | `config_db::set`, `run_test()` |
| [run_questa.do](run_questa.do) | Mentor Questa run script | Multi-test regression |
| [run_vcs.sh](run_vcs.sh) | Synopsys VCS run script | VCS UVM invocation flags |

---

## Architecture

```
                +--------------------+
  +------+      |   hft_env          |
  | Test | ---> |  +-------------+   |    uvm_analysis_port (fan-out)
  +------+      |  | hft_agent   |---+---> hft_scoreboard
                |  | +---------+ |   |
                |  | | sequen- | |   +---> hft_coverage
                |  | | cer     | |   |
                |  | +---------+ |   |
                |  |      |      |   |
                |  | hft_driver  |   |
                |  |   (UART +   |   |
                |  |    fill)    |   |
                |  |      |      |   |
                |  | hft_monitor |   |
                |  +------+------+   |
                +---------+----------+
                          |
                       hft_if (virtual interface)
                          |
                     trading_top (DUT)
```

---

## UVM Components

### `hft_seq_item` — Stimulus Transaction
- **Two kinds** via `txn_kind_e` enum: `TXN_FRAME` (11-byte UART packet) or `TXN_FILL` (single-cycle exchange confirm)
- **Constrained random fields**: price window 99000–101000, BID below mid/ASK above mid, qty in 100–500 shares
- Registered with factory: `uvm_object_utils_begin/end` + `uvm_field_*` for auto-print/copy/compare

### `hft_obs_item` — Monitor Observation
- Captures one cycle snapshot: `pkt_valid`, `sig_valid/source`, `order_valid`, `breach_flags`, `running_pnl`, `fill_count`
- `convert2string()` for `UVM_DEBUG` logging

### Sequences

| Sequence | What it does |
|----------|-------------|
| `hft_smoke_seq` | ADD BID + ADD ASK + TRADE → VWAP BUY fired |
| `hft_vwap_seq` | Same + BUY fill + SELL fill → round-trip P&L |
| `hft_breach_seq` | Fill to MAX_POSITION, then re-trigger → pos breach |
| `hft_rand_seq` | N constrained-random TRADE frames (price 99800–100200) |

### `hft_driver`
- Gets `hft_seq_item` from sequencer
- `TXN_FRAME` → drives 11 UART bytes (start+8data+stop, BIT_CYCLES each) then waits 30 cycles for pipeline
- `TXN_FILL` → single `@(negedge clk)` pulse on `fill_valid`
- Uses `@(posedge vif.clk iff vif.rst_n)` to stall until reset de-asserts

### `hft_monitor`
- Samples `vif.mon_cb` (clocking block, #1 skew) every posedge
- Creates one `hft_obs_item` per active cycle (pkt/sig/order/breach)
- Broadcasts via `uvm_analysis_port`

### `hft_scoreboard`
- Receives via `uvm_analysis_imp` (single-port; fan-out handled by env)
- **Rule 1** — `order_valid` and `breach_flags != 0` are mutually exclusive → `uvm_error` on violation
- **Rule 2** — `fill_count` must be monotonically non-decreasing
- `report_phase` prints counters and final PASS/FAIL

### `hft_coverage` (extends `uvm_subscriber`)
- Single `hft_cg` covergroup with 8 coverpoints + 2 crosses:
  - `cp_pkt_type` — all 4 frame types (ADD/CAN/TRD/HB)
  - `cp_sig_src` — both strategies fire (VWAP=0, MOM=1)
  - `cp_breach_pos/qty/price/rate` — each risk-gate check trips
  - `cp_order` — orders both approved and rejected
  - `cx_pkt_order` — every packet type leads to both outcomes
  - `cx_src_order` — both strategies in approved + rejected state
- `report_phase` prints `get_coverage()` percentage

---

## How to Run

### Mentor Questa
```tcl
# From hft_trading_system/ directory
vsim -c -do uvm/run_questa.do

# Single test
vsim -c -do "source uvm/run_questa.do; run_test hft_breach_test"
```

### Synopsys VCS
```bash
# Run default (smoke) test
./uvm/run_vcs.sh

# Named test
./uvm/run_vcs.sh hft_breach_test
./uvm/run_vcs.sh hft_rand_test
./uvm/run_vcs.sh hft_vwap_test
```

### EDA Playground (online, free)
1. Paste `hft_if.sv` + `hft_pkg.sv` + `tb_uvm_top.sv` into the editor
2. Add all RTL files from `rtl/`
3. Select **Cadence Xcelium** (supports UVM-1.2 natively)
4. Set `+UVM_TESTNAME=hft_smoke_test` in the runtime args

---

## Expected Output (Questa, smoke test)

```
UVM_INFO @ 0: reporter [RNTST] Running test hft_smoke_test...
UVM_INFO [TEST]  Running smoke test
UVM_INFO [SEQ]   smoke_seq: ADD BID, ADD ASK, TRADE -> VWAP BUY
UVM_INFO [SB]    ===== Scoreboard Report =====
                 pkts=3  sigs=1  orders=1  breaches=0
                 errors=0
UVM_INFO [SB]    *** SCOREBOARD: ALL CHECKS PASSED ***
UVM_INFO [COV]   Functional coverage: 34.2%
UVM_INFO @ ...: reporter [TEST_DONE] UVM_INFO count...
UVM_ERROR count : 0
```

> Run all four tests together to push coverage above 80%.
> Add more random seeds (`+ntb_random_seed=N`) for coverage closure.

---

## Extending the Testbench

| Goal | How |
|------|-----|
| Add momentum coverage | Send 8× TRADE at 99900 in a new `hft_momentum_seq` |
| Inject framing errors | Add `TXN_BAD_FRAME` kind to seq_item; driver sends wrong EOF |
| Scoreboard ref model | Track `net_pos_biased` in SB; predict order_valid exactly |
| Regression script | Loop `run_vcs.sh` over all four tests + 10 random seeds |
| CDC checks | Run Questa CDC on `trading_top.sv` (UART domain crossing) |
