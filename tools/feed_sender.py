# tools/feed_sender.py
#
# Market data feed sender for HFT FPGA system.
#
# Three modes:
#   1. FILE mode   (default) — writes hex stimulus file for Vivado xsim
#   2. UART mode   (--uart)  — sends frames over real serial port to FPGA
#   3. PRINT mode  (--print) — prints human-readable + hex for debugging
#
# Usage:
#   python feed_sender.py                        # generates sim/stimulus.hex
#   python feed_sender.py --print                # print to terminal
#   python feed_sender.py --uart COM3            # send over UART (Windows)
#   python feed_sender.py --uart /dev/ttyUSB0    # send over UART (Linux)
#   python feed_sender.py --scenario stress      # 1000-event stress test
#
# The hex file format is $readmemh compatible:
#   One byte per line, no 0x prefix, lowercase hex.
#   Vivado xsim loads it with: $readmemh("stimulus.hex", byte_array);

import struct
import time
import argparse
import random
import sys
from dataclasses import dataclass
from enum import IntEnum
from typing import List, Optional


# ── Protocol constants (must match protocol_spec.md exactly) ─────────────
SOF       = 0xAA
EOF_BYTE  = 0x55
FRAME_LEN = 11       # bytes

class MsgType(IntEnum):
    ADD       = 0x01
    CANCEL    = 0x02
    TRADE     = 0x03
    HEARTBEAT = 0x04

class Side(IntEnum):
    BID = 0x00
    ASK = 0x01


# ── Frame encoder ────────────────────────────────────────────────────────
@dataclass
class Frame:
    msg_type: MsgType
    order_id: int    # 0..65535
    price:    int    # paise, 0..16777215
    qty:      int    # 0..65535
    side:     Side

    def encode(self) -> bytes:
        """Pack into 11-byte binary frame."""
        assert 0 <= self.order_id <= 0xFFFF,  f"order_id out of range: {self.order_id}"
        assert 0 <= self.price    <= 0xFFFFFF, f"price out of range: {self.price}"
        assert 0 <= self.qty      <= 0xFFFF,   f"qty out of range: {self.qty}"

        price_h = (self.price >> 16) & 0xFF
        price_m = (self.price >>  8) & 0xFF
        price_l =  self.price        & 0xFF

        return bytes([
            SOF,
            int(self.msg_type),
            (self.order_id >> 8) & 0xFF,
             self.order_id       & 0xFF,
            price_h, price_m, price_l,
            (self.qty >> 8) & 0xFF,
             self.qty        & 0xFF,
            int(self.side),
            EOF_BYTE,
        ])

    def to_hex_lines(self) -> List[str]:
        """One hex byte per line — $readmemh compatible."""
        return [f"{b:02x}" for b in self.encode()]

    def describe(self) -> str:
        price_rs = self.price / 100
        return (f"{self.msg_type.name:<9} "
                f"id={self.order_id:5d}  "
                f"price=Rs{price_rs:10.2f}  "
                f"qty={self.qty:5d}  "
                f"side={'BID' if self.side == Side.BID else 'ASK'}")


def make_heartbeat() -> Frame:
    return Frame(MsgType.HEARTBEAT, 0, 0, 0, Side.BID)


# ── Scenario generators ──────────────────────────────────────────────────

def scenario_basic() -> List[Frame]:
    """
    Small deterministic scenario — use for daily regression.
    Known outputs make testbench assertions easy.

    Expected book state after all frames:
      Best BID: Rs1000.00 (100000 paise), qty 100
      Best ASK: Rs1001.00 (100100 paise), qty 80
    """
    frames = []

    # Add BID orders at different price levels
    frames.append(Frame(MsgType.ADD,    0x0001, 100000, 100, Side.BID))  # best bid
    frames.append(Frame(MsgType.ADD,    0x0002,  99900,  50, Side.BID))  # level 2 bid
    frames.append(Frame(MsgType.ADD,    0x0003,  99800,  75, Side.BID))  # level 3 bid

    # Add ASK orders
    frames.append(Frame(MsgType.ADD,    0x0004, 100100,  80, Side.ASK))  # best ask
    frames.append(Frame(MsgType.ADD,    0x0005, 100200, 120, Side.ASK))  # level 2 ask

    # Cancel one BID
    frames.append(Frame(MsgType.CANCEL, 0x0002,  99900,  50, Side.BID))  # remove level 2

    # Trade at ask price
    frames.append(Frame(MsgType.TRADE,  0x0004, 100100,  30, Side.ASK))  # partial fill

    # Heartbeat
    frames.append(make_heartbeat())

    return frames


def scenario_stress(n: int = 1000) -> List[Frame]:
    """
    Randomised stress test — n events around a random walk price.
    Used for finding edge cases in the order book.
    """
    random.seed(42)   # fixed seed = reproducible
    frames = []

    price_center = 100000   # Rs1000.00
    order_id     = 1
    active_bids  = {}       # id -> price
    active_asks  = {}       # id -> price

    for i in range(n):
        # Random walk: price drifts ±200 paise per event
        price_center = max(10000, price_center + random.randint(-200, 200))

        r = random.random()

        if r < 0.50:
            # ADD order
            side  = Side.BID if random.random() < 0.5 else Side.ASK
            price = price_center + random.randint(-500, -1) if side == Side.BID \
                    else price_center + random.randint(1, 500)
            price = max(1, price)
            qty   = random.randint(10, 500)

            frames.append(Frame(MsgType.ADD, order_id, price, qty, side))

            if side == Side.BID:
                active_bids[order_id] = price
            else:
                active_asks[order_id] = price
            order_id += 1

        elif r < 0.70 and active_bids:
            # CANCEL a random BID
            oid   = random.choice(list(active_bids.keys()))
            price = active_bids.pop(oid)
            frames.append(Frame(MsgType.CANCEL, oid, price, 0, Side.BID))

        elif r < 0.85 and active_asks:
            # CANCEL a random ASK
            oid   = random.choice(list(active_asks.keys()))
            price = active_asks.pop(oid)
            frames.append(Frame(MsgType.CANCEL, oid, price, 0, Side.ASK))

        else:
            # TRADE at best available
            trade_price = price_center + random.randint(-100, 100)
            frames.append(Frame(MsgType.TRADE, 0, trade_price,
                                random.randint(1, 100), Side.ASK))

        # Occasional heartbeat
        if i % 50 == 0:
            frames.append(make_heartbeat())

    return frames


def scenario_latency() -> List[Frame]:
    """
    Back-to-back ADD frames with no gap — tests parser timing.
    11 bytes × 10 bits × 868 cycles = 95,480 cycles per frame.
    Send 10 frames = measure if all 10 are parsed correctly.
    """
    return [Frame(MsgType.ADD, i, 100000 + i*100, 100, Side.BID)
            for i in range(1, 11)]


SCENARIOS = {
    'basic':   scenario_basic,
    'stress':  lambda: scenario_stress(1000),
    'latency': scenario_latency,
}


# ── Output modes ─────────────────────────────────────────────────────────

def write_hex_file(frames: List[Frame], path: str) -> None:
    """Write $readmemh-compatible hex file for Vivado xsim."""
    lines = []
    for f in frames:
        lines.extend(f.to_hex_lines())
    with open(path, 'w') as fh:
        fh.write('\n'.join(lines) + '\n')
    print(f"Written {len(frames)} frames ({len(lines)} bytes) -> {path}")
    print(f"Load in testbench: $readmemh(\"{path}\", stim_mem);")


def print_frames(frames: List[Frame]) -> None:
    """Human-readable print for debugging."""
    print(f"{'#':<4}  {'Description':<55}  {'Hex bytes'}")
    print("-" * 100)
    for i, f in enumerate(frames):
        hex_str = ' '.join(f'{b:02X}' for b in f.encode())
        print(f"{i:<4}  {f.describe():<55}  {hex_str}")
    print(f"\nTotal: {len(frames)} frames, {len(frames)*FRAME_LEN} bytes")


def send_uart(frames: List[Frame], port: str,
              baud: int = 115200, delay_ms: float = 2.0) -> None:
    """Send frames over real UART to FPGA."""
    try:
        import serial
    except ImportError:
        sys.exit("ERROR: pyserial not installed. Run: pip install pyserial")

    with serial.Serial(port, baud, timeout=1) as ser:
        print(f"Opened {port} at {baud} baud")
        for i, f in enumerate(frames):
            raw = f.encode()
            ser.write(raw)
            time.sleep(delay_ms / 1000)
            if i % 50 == 0:
                print(f"  Sent {i}/{len(frames)} frames...")
        print(f"Done. {len(frames)} frames sent.")


# ── Entry point ───────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description='HFT feed sender')
    ap.add_argument('--scenario', choices=list(SCENARIOS.keys()),
                    default='basic', help='Which scenario to generate')
    ap.add_argument('--print',  action='store_true', help='Print frames to terminal')
    ap.add_argument('--uart',   metavar='PORT',      help='Send over UART to FPGA')
    ap.add_argument('--out',    default='sim/stimulus.hex',
                    help='Output hex file path (default: sim/stimulus.hex)')
    args = ap.parse_args()

    frames = SCENARIOS[args.scenario]()
    print(f"Scenario '{args.scenario}': {len(frames)} frames generated")

    if args.print:
        print_frames(frames)

    if args.uart:
        send_uart(frames, args.uart)
    else:
        write_hex_file(frames, args.out)


if __name__ == '__main__':
    main()
