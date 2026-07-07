# HFT System Binary Packet Protocol
# Version 1.0

## Overview

Fixed-length 11-byte frames over UART at 115200 baud.
Every frame has the same structure regardless of message type.
Fixed length means the parser FSM has exactly 11 states — one byte per state.
No length fields, no variable-length payloads, no ambiguity.

## Frame structure

```
Byte  Field       Width   Description
────────────────────────────────────────────────────────
  0   SOF         1 B     Start of frame marker = 0xAA
  1   MSG_TYPE    1 B     Message type (see below)
  2   ORDER_ID_H  1 B     Order ID bits [15:8]
  3   ORDER_ID_L  1 B     Order ID bits [7:0]
  4   PRICE_H     1 B     Price bits [23:16]
  5   PRICE_M     1 B     Price bits [15:8]
  6   PRICE_L     1 B     Price bits [7:0]
  7   QTY_H       1 B     Quantity bits [15:8]
  8   QTY_L       1 B     Quantity bits [7:0]
  9   SIDE        1 B     0x00 = BID, 0x01 = ASK
 10   EOF         1 B     End of frame marker = 0x55
────────────────────────────────────────────────────────
Total: 11 bytes per frame
```

## Message types

```
MSG_TYPE    Value   Meaning
──────────────────────────────────────────────────────────────
ADD         0x01    Add a new order to the book
CANCEL      0x02    Cancel an existing order (price/side still sent for routing)
TRADE       0x03    A trade occurred at price × qty (updates last trade price)
HEARTBEAT   0x04    Keep-alive — no book update, order_id/price/qty = 0
──────────────────────────────────────────────────────────────
```

## Field encoding

### Price (3 bytes, unsigned)
- Unit: paise (Indian rupee × 100)
- Range: 0 to 16,777,215 paise = ₹0 to ₹167,772.15
- Example: ₹1845.60 = 184560 paise = 0x02_CF_10
- Big-endian: PRICE_H is most significant byte

### Quantity (2 bytes, unsigned)
- Raw share count, 0 to 65535
- Example: 250 shares = 0x00_FA

### Order ID (2 bytes, unsigned)
- Unique per session, wraps at 65535
- On CANCEL: must match an existing order_id in the book

### Side
- 0x00 = BID (buy side)
- 0x01 = ASK (sell side)
- On TRADE: side = which side was the aggressor (0x01 = buyer aggressed)

## Timing

- Baud rate: 115200
- Clock: 100 MHz (Artix-7 default)
- Cycles per bit: 100_000_000 / 115200 = 868 cycles
- Sample point: bit centre = 434 cycles after start bit falling edge
- Frame duration: 11 bytes × 10 bits/byte × 868 cycles/bit = 95,480 cycles ≈ 0.955 ms

## Error handling

- Wrong SOF byte: discard byte, stay in IDLE, wait for 0xAA
- Wrong EOF byte: discard entire frame, return to IDLE, assert parse_error flag for 1 cycle
- Unknown MSG_TYPE: discard frame, return to IDLE, assert parse_error flag

## Example frames (hex)

ADD order 0x0001, price ₹1000.00 (100000 = 0x0186A0), qty 100 (0x0064), BID side:
  AA 01 00 01 01 86 A0 00 64 00 55

CANCEL order 0x0001, same price/side (needed for book routing):
  AA 02 00 01 01 86 A0 00 64 00 55

TRADE at ₹1000.50 (100050 = 0x0186D2), qty 50 (0x0032), buyer aggressed:
  AA 03 00 01 01 86 D2 00 32 01 55

HEARTBEAT (all payload = 0):
  AA 04 00 00 00 00 00 00 00 00 55
