# ⚡ HFT Trading System on FPGA

> A fully pipelined, ultra-low-latency **High-Frequency Trading (HFT)** system implemented in **SystemVerilog**, designed for Xilinx Artix-7 FPGAs. Implements the complete order-to-wire pipeline — from UART market data ingestion to order dispatch — in pure hardware logic.

---

## 🏗️ Architecture Overview

```
                         ┌──────────────────────────────────────────────┐
  Exchange Feed          │                 trading_top.sv               │
  (UART 1Mbaud) ────────►│                                              │
                         │  uart_rx → packet_assembler → order_book    │
                         │                                    │         │
                         │                             strategy_core   │
                         │                                    │         │
                         │                              risk_gate ◄─── fill_valid │
                         │                                    │         │
                         │                   pnl_engine ◄────┘         │
                         │                                    │         │
                         │                         order_serializer     │
                         │                                    │         │
  Order Output ◄─────────│                              uart_tx         │
  (UART 1Mbaud)          └──────────────────────────────────────────────┘
```

### Pipeline Stages

| Stage | Module | Function |
|-------|--------|----------|
| 1 | `uart_rx` | Deserializes incoming bytes from exchange feed |
| 2 | `packet_assembler` | Parses 11-byte fixed-length frames via FSM |
| 3 | `order_book` | Maintains live BID/ASK price levels (64 entries) |
| 4 | `strategy_core` | VWAP + Momentum signal generation |
| 5 | `risk_gate` | Pre-trade risk checks (position, rate, price band) |
| 6 | `pnl_engine` | Real-time P&L tracking with drawdown protection |
| 7 | `order_serializer` | Serializes outbound orders into 11-byte frames |
| 8 | `uart_tx` | Transmits order bytes to exchange |

---

## 📦 Repository Structure

```
hft_trading_system/
├── rtl/                        # Synthesizable SystemVerilog source
│   ├── trading_top.sv          # Top-level integration module
│   ├── uart_rx.sv              # UART receiver
│   ├── uart_tx.sv              # UART transmitter (with TX FIFO)
│   ├── packet_assembler.sv     # 11-byte frame parser FSM
│   ├── order_book.sv           # Level-1 order book (BID/ASK)
│   ├── strategy_core.sv        # Strategy dispatcher (VWAP + Momentum)
│   ├── strategy_vwap.sv        # Volume-Weighted Average Price strategy
│   ├── strategy_momentum.sv    # Momentum / trend-following strategy
│   ├── risk_gate.sv            # Pre-trade risk engine
│   ├── order_serializer.sv     # Outbound order framing
│   └── pnl_engine.sv           # Real-time P&L + drawdown monitor
│
├── sim/                        # SystemVerilog testbenches
│   ├── tb_system.sv            # Full system integration testbench
│   ├── tb_demo.sv              # End-to-end demo testbench
│   ├── tb_latency.sv           # Latency measurement testbench
│   ├── tb_order_book.sv        # Order book unit test
│   ├── tb_order_serializer.sv  # Serializer unit test
│   ├── tb_packet_assembler.sv  # Packet parser unit test
│   ├── tb_risk_pnl.sv          # Risk + P&L unit test
│   ├── tb_strategy_core.sv     # Strategy core unit test
│   ├── tb_strategy_vwap.sv     # VWAP strategy unit test
│   └── tb_uart_loopback.sv     # UART loopback test
│
├── uvm/                        # UVM verification environment
├── tools/                      # Helper scripts
├── run_all.ps1                 # PowerShell: compile + run all testbenches
└── protocol_spec.md            # Binary packet protocol specification
```

---

## 🔌 Binary Packet Protocol (v1.0)

Fixed-length **11-byte** frames over UART at **115200 / 1Mbaud**.

```
Byte   Field        Description
─────────────────────────────────────────────────────
  0    SOF (0xAA)   Start of frame marker
  1    MSG_TYPE     0x01=ADD  0x02=CANCEL  0x03=TRADE  0x04=HEARTBEAT
  2    ORDER_ID_H   Order ID [15:8]
  3    ORDER_ID_L   Order ID [7:0]
  4    PRICE_H      Price [23:16]  (paise = ₹ × 100)
  5    PRICE_M      Price [15:8]
  6    PRICE_L      Price [7:0]
  7    QTY_H        Quantity [15:8]
  8    QTY_L        Quantity [7:0]
  9    SIDE         0x00=BID  0x01=ASK
 10    EOF (0x55)   End of frame marker
─────────────────────────────────────────────────────
```

**Example** — ADD order at ₹1000.00, qty 100, BID:
```
AA 01 00 01 01 86 A0 00 64 00 55
```

---

## ⚙️ Key Parameters (`trading_top`)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `CLK_FREQ_HZ` | 100 MHz | System clock (Artix-7) |
| `BAUD_RATE` | 1,000,000 | UART baud rate |
| `ORDER_BOOK_DEPTH` | 64 | Max simultaneous orders tracked |
| `VWAP_THRESHOLD` | 10 | VWAP signal trigger sensitivity |
| `MOM_THRESHOLD` | 20 | Momentum signal trigger sensitivity |
| `LOT_SIZE` | 100 | Default order lot size (shares) |
| `MAX_POSITION` | 1000 | Maximum net position (risk limit) |
| `MAX_QTY` | 500 | Maximum single order quantity |
| `PRICE_BAND` | 500 | ±500 paise price band filter |
| `MAX_DRAWDOWN` | 10,000,000 | Drawdown kill-switch threshold (paise) |

---

## 🧪 Running Simulations

### Prerequisites
- [Icarus Verilog](https://bleyer.org/icarus/) (`iverilog`) — for simulation
- [GTKWave](http://gtkwave.sourceforge.net/) — for waveform viewing
- PowerShell (Windows) or Bash (Linux/macOS)

### Run All Testbenches
```powershell
# Windows PowerShell
.\run_all.ps1
```

### Run Individual Testbench
```bash
# Compile
iverilog -g2012 -o sim/tb_system.vvp rtl/*.sv sim/tb_system.sv

# Simulate
vvp sim/tb_system.vvp

# View waveform
gtkwave tb_system.vcd
```

---

## 🎯 Trading Strategies

### VWAP Strategy (`strategy_vwap.sv`)
Tracks Volume-Weighted Average Price. Generates a **BUY** signal when the best ask drops below VWAP and a **SELL** when bid exceeds VWAP by the configured threshold.

### Momentum Strategy (`strategy_momentum.sv`)
Monitors successive trade prices. Detects upward/downward momentum over a sliding window and generates directional signals when momentum crosses the threshold.

### Strategy Core (`strategy_core.sv`)
Arbitrates between VWAP and Momentum signals. Applies a **cooldown timer** (1000 cycles default) to prevent over-trading.

---

## 🛡️ Risk Engine (`risk_gate.sv`)

Pre-trade checks performed **every clock cycle** before any order is placed:

| Check | Description |
|-------|-------------|
| **Position Limit** | Net position must stay within `±MAX_POSITION` |
| **Order Quantity** | Single order qty ≤ `MAX_QTY` |
| **Rate Limiter** | Token-bucket: `RATE_TOKENS` orders per `RATE_REFILL` cycles |
| **Price Band** | Order price must be within `±PRICE_BAND` of last trade price |

All breach conditions are exported on the `breach_flags[3:0]` monitor port.

---

## 📊 Monitor / ILA Ports

All internal buses are available on `mon_*` output ports for **Xilinx ILA** (Integrated Logic Analyzer) or testbench monitoring without modifying RTL:

| Port | Description |
|------|-------------|
| `mon_pkt_valid` | Parsed packet ready |
| `mon_best_bid/ask_price` | Live BBO prices |
| `mon_trade_price` | Last trade price |
| `mon_sig_valid` | Strategy signal fired |
| `mon_order_valid` | Order passed risk gate |
| `mon_breach_flags[3:0]` | Active risk breaches |
| `mon_running_pnl` | Current P&L (paise, signed 64-bit) |
| `mon_fill_count` | Total fills received |
| `mon_drawdown_hit` | Max drawdown kill-switch |

---

## 🎯 Target Hardware

- **FPGA**: Xilinx Artix-7 (e.g. XC7A35T / Nexys A7 / Arty A7)
- **Clock**: 100 MHz
- **Tools**: Vivado 2023.x (synthesis + implementation)

---

## 👤 Author

**VKH-git** — [vkh48080@gmail.com](mailto:vkh48080@gmail.com)

---

## 📄 License

This project is open-source. Feel free to use it for educational and research purposes.
