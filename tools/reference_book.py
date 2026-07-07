#!/usr/bin/env python3
"""
tools/reference_book.py  --  Day 5
Python golden reference order book for the HFT FPGA system.

This is the SOLE source of truth for correct order book behaviour.
The RTL order_book.sv (Day 6) must produce identical results for
every scenario this model generates.

=======================================================================
Design decisions  (must match order_book.sv exactly)
=======================================================================
1. Price-time priority
     BID: higher price wins; equal price -> earlier arrival first.
     ASK: lower  price wins; equal price -> earlier arrival first.

2. CANCEL removes by order_id only -- price/side in the frame are
   routing hints; the book looks up the stored order.

3. TRADE records last-trade price & qty.  It does NOT automatically
   remove orders.  The exchange sends explicit CANCELs for matched
   portions before or alongside the TRADE report.

4. Price unit : paise (integer).  Rs 1000.00 = 100000 paise.
5. Qty unit   : raw share count (integer).
6. Depth shown: configurable; default 5 levels per side.

=======================================================================
Usage -- standalone
=======================================================================
  python tools/reference_book.py                        # basic scenario
  python tools/reference_book.py --scenario stress      # 1000-event run
  python tools/reference_book.py --scenario latency     # back-to-back
  python tools/reference_book.py --hex sim/stimulus.hex # replay hex file
  python tools/reference_book.py --self-test            # run built-in tests

=======================================================================
Usage -- as module
=======================================================================
  from reference_book import OrderBook

  book = OrderBook()
  book.process_frame(frame)       # feed_sender.Frame or plain dict
  bb = book.best_bid()            # (price_paise, qty) or None
  ba = book.best_ask()            # (price_paise, qty) or None
  snap = book.snapshot()          # BookSnapshot for RTL comparison
  book.display()                  # pretty-print to terminal
"""

from __future__ import annotations

import sys
import os
import argparse
import time
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple
from collections import defaultdict


# =========================================================================
# Protocol constants  (must match protocol_spec.md)
# =========================================================================
SOF_BYTE      = 0xAA
EOF_BYTE      = 0x55
FRAME_LEN     = 11

MSG_ADD       = 0x01
MSG_CANCEL    = 0x02
MSG_TRADE     = 0x03
MSG_HEARTBEAT = 0x04

SIDE_BID      = 0x00
SIDE_ASK      = 0x01


# =========================================================================
# Data types
# =========================================================================

@dataclass
class Order:
    """One resting limit order."""
    order_id : int    # 0..65535
    price    : int    # paise
    qty      : int    # shares
    side     : int    # SIDE_BID or SIDE_ASK
    seq      : int    # arrival sequence (for time priority)

    @property
    def side_str(self) -> str:
        return "BID" if self.side == SIDE_BID else "ASK"

    @property
    def price_rs(self) -> float:
        return self.price / 100.0

    def __repr__(self) -> str:
        return (f"Order(id={self.order_id}, {self.side_str}, "
                f"Rs{self.price_rs:.2f}, qty={self.qty}, seq={self.seq})")


@dataclass
class TradeReport:
    """Record of the most recent executed trade."""
    price : int    # paise
    qty   : int    # shares
    side  : int    # aggressor side
    seq   : int    # global sequence at time of trade

    @property
    def price_rs(self) -> float:
        return self.price / 100.0


@dataclass
class BookSnapshot:
    """
    Complete book state at one instant.
    Used to compare Python model output against RTL order_book.sv output.
    """
    best_bid_price   : Optional[int]   # paise, or None if empty
    best_bid_qty     : Optional[int]
    best_ask_price   : Optional[int]
    best_ask_qty     : Optional[int]
    mid_price        : Optional[int]   # (bid+ask)//2, paise
    spread           : Optional[int]   # ask - bid, paise
    last_trade_price : Optional[int]
    last_trade_qty   : Optional[int]
    total_bid_levels : int
    total_ask_levels : int

    def __str__(self) -> str:
        def fp(v):
            return f"Rs{v/100:.2f}" if v is not None else "---"
        def fq(v):
            return str(v) if v is not None else "---"
        return (
            f"  Best BID : {fp(self.best_bid_price)} x {fq(self.best_bid_qty)}\n"
            f"  Best ASK : {fp(self.best_ask_price)} x {fq(self.best_ask_qty)}\n"
            f"  Mid      : {fp(self.mid_price)}\n"
            f"  Spread   : {fp(self.spread)}\n"
            f"  LastTrade: {fp(self.last_trade_price)} x {fq(self.last_trade_qty)}\n"
            f"  BidLevels: {self.total_bid_levels}\n"
            f"  AskLevels: {self.total_ask_levels}"
        )


# =========================================================================
# OrderBook
# =========================================================================

class OrderBook:
    """
    Price-time priority order book.

    Internal layout
    ---------------
    _orders  : dict[order_id -> Order]
        O(1) lookup for cancel.

    _bids    : dict[price -> list[Order]]   (descending price = best first)
    _asks    : dict[price -> list[Order]]   (ascending  price = best first)
        Grouped by price level; FIFO within each level (time priority).
        The sorted view is rebuilt on demand -- correct > fast for a
        reference model.
    """

    def __init__(self, depth: int = 5) -> None:
        self._depth  : int = depth
        self._orders : Dict[int, Order] = {}
        self._bids   : Dict[int, List[Order]] = defaultdict(list)
        self._asks   : Dict[int, List[Order]] = defaultdict(list)

        self._seq          : int = 0
        self._last_trade   : Optional[TradeReport] = None
        self._add_count    : int = 0
        self._cancel_count : int = 0
        self._trade_count  : int = 0
        self._hb_count     : int = 0

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def process_frame(self, frame) -> str:
        """
        Process one decoded frame.
        Accepts a feed_sender.Frame object OR a plain dict with keys:
          msg_type, order_id, price, qty, side
        Returns a one-line description string.
        """
        self._seq += 1

        if hasattr(frame, 'msg_type'):       # feed_sender.Frame
            mt  = int(frame.msg_type)
            oid = frame.order_id
            p   = frame.price
            q   = frame.qty
            s   = int(frame.side)
        else:                                 # plain dict
            mt  = frame['msg_type']
            oid = frame['order_id']
            p   = frame['price']
            q   = frame['qty']
            s   = frame['side']

        if   mt == MSG_ADD:       return self._do_add(oid, p, q, s)
        elif mt == MSG_CANCEL:    return self._do_cancel(oid, p, s)
        elif mt == MSG_TRADE:     return self._do_trade(p, q, s)
        elif mt == MSG_HEARTBEAT: return self._do_heartbeat()
        else:
            return f"[seq={self._seq:4d}] UNKNOWN type=0x{mt:02X} -- ignored"

    def process_raw_bytes(self, raw: bytes) -> str:
        """Parse one 11-byte binary frame and process it."""
        if len(raw) != FRAME_LEN:
            return f"ERROR: bad frame length {len(raw)}"
        if raw[0] != SOF_BYTE:
            return f"ERROR: bad SOF 0x{raw[0]:02X}"
        if raw[10] != EOF_BYTE:
            return f"ERROR: bad EOF 0x{raw[10]:02X}"
        d = {
            'msg_type': raw[1],
            'order_id': (raw[2] << 8) | raw[3],
            'price'   : (raw[4] << 16) | (raw[5] << 8) | raw[6],
            'qty'     : (raw[7] << 8) | raw[8],
            'side'    : raw[9],
        }
        return self.process_frame(d)

    # -- Queries -----------------------------------------------------------

    def best_bid(self) -> Optional[Tuple[int, int]]:
        """(price_paise, total_qty) of best BID level, or None."""
        pl = self._sorted_bids()
        if not pl:
            return None
        p = pl[0]
        return (p, sum(o.qty for o in self._bids[p]))

    def best_ask(self) -> Optional[Tuple[int, int]]:
        """(price_paise, total_qty) of best ASK level, or None."""
        pl = self._sorted_asks()
        if not pl:
            return None
        p = pl[0]
        return (p, sum(o.qty for o in self._asks[p]))

    def mid_price(self) -> Optional[int]:
        """(best_bid + best_ask) // 2 in paise, or None."""
        bb = self.best_bid()
        ba = self.best_ask()
        if bb is None or ba is None:
            return None
        return (bb[0] + ba[0]) // 2

    def spread(self) -> Optional[int]:
        """best_ask_price - best_bid_price in paise, or None."""
        bb = self.best_bid()
        ba = self.best_ask()
        if bb is None or ba is None:
            return None
        return ba[0] - bb[0]

    def bid_levels(self, depth: Optional[int] = None) -> List[Tuple[int, int]]:
        """[(price, total_qty), ...] for BID side, best first."""
        d = depth if depth is not None else self._depth
        return [(p, sum(o.qty for o in self._bids[p]))
                for p in self._sorted_bids()[:d]]

    def ask_levels(self, depth: Optional[int] = None) -> List[Tuple[int, int]]:
        """[(price, total_qty), ...] for ASK side, best first."""
        d = depth if depth is not None else self._depth
        return [(p, sum(o.qty for o in self._asks[p]))
                for p in self._sorted_asks()[:d]]

    def get_order(self, order_id: int) -> Optional[Order]:
        return self._orders.get(order_id)

    def snapshot(self) -> BookSnapshot:
        """Full BookSnapshot -- compare against RTL output."""
        bb = self.best_bid()
        ba = self.best_ask()
        lt = self._last_trade
        return BookSnapshot(
            best_bid_price   = bb[0] if bb else None,
            best_bid_qty     = bb[1] if bb else None,
            best_ask_price   = ba[0] if ba else None,
            best_ask_qty     = ba[1] if ba else None,
            mid_price        = self.mid_price(),
            spread           = self.spread(),
            last_trade_price = lt.price if lt else None,
            last_trade_qty   = lt.qty   if lt else None,
            total_bid_levels = len(self._sorted_bids()),
            total_ask_levels = len(self._sorted_asks()),
        )

    @property
    def stats(self) -> dict:
        return {
            'seq'    : self._seq,
            'adds'   : self._add_count,
            'cancels': self._cancel_count,
            'trades' : self._trade_count,
            'hbs'    : self._hb_count,
            'resting': len(self._orders),
        }

    # -- Display -----------------------------------------------------------

    def display(self, depth: Optional[int] = None, title: str = "") -> None:
        """
        ASCII order book display:

          +----------------------------------------------------------+
          |              ORDER BOOK  [seq=7]                         |
          +---------------------------+------------------------------+
          |   BID side                |   ASK side                   |
          |   Price          Qty      |   Price          Qty         |
          +---------------------------+------------------------------+
          |  Rs1000.00        100     |  Rs1001.00         80        |
          |   Rs999.80         75     |  Rs1002.00        120        |
          +----------------------------------------------------------+
          |  Spread: Rs1.00   Mid: Rs1000.50   Last: Rs1001.00 x 30 |
          +----------------------------------------------------------+
        """
        d    = depth if depth is not None else self._depth
        bids = self.bid_levels(d)
        asks = self.ask_levels(d)
        rows = max(len(bids), len(asks), 1)
        W    = 60    # total inner width

        hdr = f" ORDER BOOK  [{title + '  ' if title else ''}seq={self._seq}]"
        sep = "+" + "-" * 28 + "+" + "-" * 30 + "+"
        top = "+" + "-" * W + "+"

        print()
        print(top)
        print(f"|{hdr:^{W}}|")
        print(sep)
        print(f"|{'  BID side':^28}|{'  ASK side':^30}|")
        print(f"|{'  Price':>16}{'Qty':>11} |{'  Price':>16}{'Qty':>13} |")
        print(sep)

        for i in range(rows):
            bl = f"  Rs{bids[i][0]/100:>9.2f}  {bids[i][1]:>6}" if i < len(bids) else ""
            al = f"  Rs{asks[i][0]/100:>9.2f}  {asks[i][1]:>8}" if i < len(asks) else ""
            print(f"|{bl:<28}|{al:<30}|")

        print(top)

        sp   = self.spread()
        mid  = self.mid_price()
        lt   = self._last_trade
        sp_s  = f"Rs{sp/100:.2f}"  if sp  is not None else "---"
        mid_s = f"Rs{mid/100:.2f}" if mid is not None else "---"
        lt_s  = (f"Rs{lt.price/100:.2f} x {lt.qty}" if lt else "---")

        print(f"|  Spread:{sp_s:<10}  Mid:{mid_s:<12}  Last:{lt_s:<14}|")
        s = self.stats
        print(f"|  Resting:{s['resting']} orders  "
              f"ADD:{s['adds']} CXL:{s['cancels']} "
              f"TRD:{s['trades']} HB:{s['hbs']:<22}|")
        print(top)

    # -- Private -----------------------------------------------------------

    def _do_add(self, oid: int, price: int, qty: int, side: int) -> str:
        if oid in self._orders:           # duplicate ID -- replace silently
            self._erase(oid)
        o = Order(order_id=oid, price=price, qty=qty, side=side, seq=self._seq)
        self._orders[oid] = o
        (self._bids if side == SIDE_BID else self._asks)[price].append(o)
        self._add_count += 1
        return (f"[seq={self._seq:4d}] ADD    "
                f"id={oid:5d}  {'BID' if side==SIDE_BID else 'ASK'}  "
                f"Rs{price/100:.2f}  qty={qty}")

    def _do_cancel(self, oid: int, price: int, side: int) -> str:
        if oid not in self._orders:
            self._cancel_count += 1
            return f"[seq={self._seq:4d}] CANCEL id={oid:5d}  WARN: not found"
        o = self._orders[oid]
        self._erase(oid)
        self._cancel_count += 1
        return (f"[seq={self._seq:4d}] CANCEL "
                f"id={oid:5d}  {'BID' if o.side==SIDE_BID else 'ASK'}  "
                f"Rs{o.price/100:.2f}  qty={o.qty}")

    def _do_trade(self, price: int, qty: int, side: int) -> str:
        self._last_trade = TradeReport(price=price, qty=qty,
                                       side=side, seq=self._seq)
        self._trade_count += 1
        return (f"[seq={self._seq:4d}] TRADE  "
                f"{'BID-agg' if side==SIDE_BID else 'ASK-agg'}  "
                f"Rs{price/100:.2f}  qty={qty}")

    def _do_heartbeat(self) -> str:
        self._hb_count += 1
        return f"[seq={self._seq:4d}] HEARTBEAT"

    def _erase(self, oid: int) -> None:
        o = self._orders.pop(oid)
        bucket = self._bids if o.side == SIDE_BID else self._asks
        bucket[o.price] = [x for x in bucket[o.price] if x.order_id != oid]
        if not bucket[o.price]:
            del bucket[o.price]

    def _sorted_bids(self) -> List[int]:
        return sorted(self._bids.keys(), reverse=True)   # highest first

    def _sorted_asks(self) -> List[int]:
        return sorted(self._asks.keys())                  # lowest first


# =========================================================================
# Hex file replay
# =========================================================================

def replay_hex_file(path: str, book: OrderBook, verbose: bool = True) -> None:
    """Read a $readmemh hex file (one byte per line) and feed every frame."""
    with open(path) as fh:
        raw_bytes = [int(ln.strip(), 16)
                     for ln in fh
                     if ln.strip() and not ln.strip().startswith("//")]

    n_frames  = len(raw_bytes) // FRAME_LEN
    remainder = len(raw_bytes) %  FRAME_LEN
    if remainder:
        print(f"WARNING: {remainder} trailing byte(s) (incomplete frame) ignored.")

    print(f"Replaying {n_frames} frames from {path}")
    for i in range(n_frames):
        chunk = bytes(raw_bytes[i * FRAME_LEN : (i + 1) * FRAME_LEN])
        msg   = book.process_raw_bytes(chunk)
        if verbose:
            print(f"  {msg}")

    book.display(title=f"after {n_frames} frames")


# =========================================================================
# Built-in self-tests
# =========================================================================

def run_self_tests() -> int:
    """Run correctness checks. Returns failure count (0 = all passed)."""
    failures = 0

    def check(label: str, got, expected) -> None:
        nonlocal failures
        if got == expected:
            print(f"  PASS  {label}")
        else:
            print(f"  FAIL  {label}: got {got!r}  expected {expected!r}")
            failures += 1

    # -----------------------------------------------------------------
    print("\n-- Test group 1: ADD / CANCEL / TRADE / HEARTBEAT --")
    book = OrderBook()

    # ADD BID Rs1000.00 qty=100
    book.process_frame({'msg_type': MSG_ADD, 'order_id': 1,
                        'price': 100000, 'qty': 100, 'side': SIDE_BID})
    check("best_bid price after first ADD", book.best_bid()[0], 100000)
    check("best_bid qty   after first ADD", book.best_bid()[1], 100)
    check("best_ask empty after first ADD", book.best_ask(), None)

    # ADD ASK Rs1001.00 qty=80
    book.process_frame({'msg_type': MSG_ADD, 'order_id': 2,
                        'price': 100100, 'qty': 80, 'side': SIDE_ASK})
    check("best_ask price", book.best_ask()[0], 100100)
    check("spread",         book.spread(),       100)
    check("mid_price",      book.mid_price(),    100050)

    # ADD second BID at lower price -- best bid unchanged
    book.process_frame({'msg_type': MSG_ADD, 'order_id': 3,
                        'price': 99900, 'qty': 50, 'side': SIDE_BID})
    check("best_bid still 100000",  book.best_bid()[0],       100000)
    check("bid_levels count = 2",   len(book.bid_levels(10)), 2)

    # ADD BID at SAME price as order 1 -- aggregated qty increases
    book.process_frame({'msg_type': MSG_ADD, 'order_id': 4,
                        'price': 100000, 'qty': 25, 'side': SIDE_BID})
    check("best_bid qty aggregated 100+25", book.best_bid()[1], 125)

    # CANCEL order 1 -- best bid qty drops to 25 (order 4 remains)
    book.process_frame({'msg_type': MSG_CANCEL, 'order_id': 1,
                        'price': 100000, 'qty': 100, 'side': SIDE_BID})
    check("after cancel order1, qty=25", book.best_bid()[1],    25)
    check("order1 gone from index",      book.get_order(1),     None)
    check("order4 still there",          book.get_order(4).qty, 25)

    # CANCEL non-existent -- should NOT crash or corrupt state
    book.process_frame({'msg_type': MSG_CANCEL, 'order_id': 999,
                        'price': 0, 'qty': 0, 'side': SIDE_BID})
    check("cancel missing order: state intact", book.best_bid()[1], 25)

    # TRADE -- only updates last_trade; does NOT remove orders
    book.process_frame({'msg_type': MSG_TRADE, 'order_id': 0,
                        'price': 100100, 'qty': 30, 'side': SIDE_ASK})
    snap = book.snapshot()
    check("last_trade_price",    snap.last_trade_price, 100100)
    check("last_trade_qty",      snap.last_trade_qty,   30)
    check("best_ask unchanged",  snap.best_ask_price,   100100)

    # HEARTBEAT -- no-op for book state
    book.process_frame({'msg_type': MSG_HEARTBEAT, 'order_id': 0,
                        'price': 0, 'qty': 0, 'side': 0})
    check("hb_count = 1", book.stats['hbs'], 1)

    # Price-time priority -- order 4 arrived before any later order at 100000
    level_orders = book._bids.get(100000, [])
    check("time priority: order4 first at 100000",
          level_orders[0].order_id if level_orders else None, 4)

    # -----------------------------------------------------------------
    print("\n-- Test group 2: feed_sender basic scenario replay --")
    book2 = OrderBook()
    events = [
        # ADD 3 BID levels
        {'msg_type': MSG_ADD,    'order_id': 0x0001, 'price': 100000,
         'qty': 100, 'side': SIDE_BID},
        {'msg_type': MSG_ADD,    'order_id': 0x0002, 'price':  99900,
         'qty':  50, 'side': SIDE_BID},
        {'msg_type': MSG_ADD,    'order_id': 0x0003, 'price':  99800,
         'qty':  75, 'side': SIDE_BID},
        # ADD 2 ASK levels
        {'msg_type': MSG_ADD,    'order_id': 0x0004, 'price': 100100,
         'qty':  80, 'side': SIDE_ASK},
        {'msg_type': MSG_ADD,    'order_id': 0x0005, 'price': 100200,
         'qty': 120, 'side': SIDE_ASK},
        # CANCEL BID level 2
        {'msg_type': MSG_CANCEL, 'order_id': 0x0002, 'price':  99900,
         'qty':  50, 'side': SIDE_BID},
        # TRADE -- only updates last_trade
        {'msg_type': MSG_TRADE,  'order_id': 0x0004, 'price': 100100,
         'qty':  30, 'side': SIDE_ASK},
        # HEARTBEAT
        {'msg_type': MSG_HEARTBEAT, 'order_id': 0, 'price': 0,
         'qty': 0, 'side': 0},
    ]
    for ev in events:
        book2.process_frame(ev)

    s2 = book2.snapshot()
    check("basic: best_bid  = 100000",  s2.best_bid_price,   100000)
    check("basic: best_bid_qty = 100",  s2.best_bid_qty,     100)
    check("basic: best_ask  = 100100",  s2.best_ask_price,   100100)
    check("basic: best_ask_qty = 80",   s2.best_ask_qty,     80)
    check("basic: spread = 100",        s2.spread,           100)
    check("basic: mid = 100050",        s2.mid_price,        100050)
    check("basic: bid_levels = 2",      s2.total_bid_levels, 2)  # order2 cancelled
    check("basic: ask_levels = 2",      s2.total_ask_levels, 2)
    check("basic: last_trade = 100100", s2.last_trade_price, 100100)
    check("basic: last_trade_qty = 30", s2.last_trade_qty,   30)

    # -----------------------------------------------------------------
    print("\n-- Test group 3: raw bytes parsing --")
    # AA 01 00 01 01 86 A0 00 64 00 55  (ADD BID Rs1000.00 qty=100 id=1)
    raw = bytes([0xAA,0x01,0x00,0x01,0x01,0x86,0xA0,0x00,0x64,0x00,0x55])
    book3 = OrderBook()
    book3.process_raw_bytes(raw)
    check("raw: best_bid price", book3.best_bid()[0], 100000)
    check("raw: best_bid qty",   book3.best_bid()[1], 100)

    bad_sof = bytes([0xBB,0x01,0x00,0x01,0x01,0x86,0xA0,0x00,0x64,0x00,0x55])
    msg_bad = book3.process_raw_bytes(bad_sof)
    check("raw: bad SOF returns error string",
          msg_bad.startswith("ERROR"), True)

    # -----------------------------------------------------------------
    print("\n-- Test group 4: empty book edge cases --")
    empty = OrderBook()
    check("empty best_bid",  empty.best_bid(),  None)
    check("empty best_ask",  empty.best_ask(),  None)
    check("empty mid_price", empty.mid_price(), None)
    check("empty spread",    empty.spread(),    None)

    return failures


# =========================================================================
# CLI entry point
# =========================================================================

def main() -> None:
    ap = argparse.ArgumentParser(
        description="HFT FPGA -- Python reference order book (Day 5)")
    ap.add_argument('--scenario', choices=['basic', 'stress', 'latency'],
                    default='basic')
    ap.add_argument('--hex',     metavar='FILE',
                    help='Replay a $readmemh hex file')
    ap.add_argument('--depth',   type=int, default=5,
                    help='Price levels to display (default 5)')
    ap.add_argument('--verbose', action='store_true',
                    help='Print every event while processing')
    ap.add_argument('--self-test', dest='selftest', action='store_true',
                    help='Run built-in correctness tests and exit')
    args = ap.parse_args()

    if args.selftest:
        failures = run_self_tests()
        print()
        if failures == 0:
            print("ALL TESTS PASSED")
        else:
            print(f"{failures} FAILURE(S) DETECTED")
        sys.exit(0 if failures == 0 else 1)

    # Locate feed_sender.py in the same directory
    tools_dir = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, tools_dir)

    book = OrderBook(depth=args.depth)

    if args.hex:
        replay_hex_file(args.hex, book, verbose=args.verbose)
        return

    try:
        from feed_sender import (scenario_basic, scenario_stress,
                                 scenario_latency)
        scenarios = {
            'basic'  : scenario_basic,
            'stress' : lambda: scenario_stress(1000),
            'latency': scenario_latency,
        }
        frames = scenarios[args.scenario]()
    except ImportError:
        print("ERROR: feed_sender.py not found. "
              "Run from hft_trading_system/ root or use --hex.")
        sys.exit(1)

    print(f"Scenario '{args.scenario}': {len(frames)} frames")
    print("-" * 70)

    t0 = time.perf_counter()
    for frame in frames:
        msg = book.process_frame(frame)
        if args.verbose:
            print(msg)
    elapsed_us = (time.perf_counter() - t0) * 1_000_000

    book.display(title=args.scenario)
    print(f"\nProcessed {len(frames)} frames in {elapsed_us:.1f} us "
          f"({elapsed_us/max(len(frames),1):.2f} us/frame)")
    print(f"Stats: {book.stats}")


if __name__ == '__main__':
    main()
