#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Verify the AE350-started UART report in one-wire debug mode.

A gate line starting with BAD, or a trace line with AHB=E, reports the first
AHB write whose address or data did not match, and fails the check at once. So
does a line starting with NOBOOT, which the SoC prints when its CPU never wrote
to the UART, and a firmware line starting with BAD.

With --clock N, also read N+1 trace reports and derive the A25 core clock from
consecutive mcycle (CYC) and 50 MHz board-oscillator (REF) pairs.
"""

import argparse
import re
import time

import serial

REF_HZ = 50_000_000
MASK = 0xFFFF_FFFF
PAIR = re.compile(rb"CYC=([0-9a-f]{8}) REF=([0-9a-f]{8})$")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default="/dev/ttyUSB1")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--expect", default="TinyNES AE350 OK")
    parser.add_argument("--clock", type=int, default=0, metavar="N",
                        help="measure the core clock over N report intervals")
    args = parser.parse_args()

    link = serial.Serial()
    link.port = args.port
    link.baudrate = 115200
    link.timeout = 0.25
    link.dtr = False
    link.rts = False
    link.open()
    deadline = time.monotonic() + args.timeout
    received = bytearray()
    matched = False
    pairs = []
    try:
        while time.monotonic() < deadline:
            received.extend(link.read(128))
            *lines, rest = received.split(b"\r\n")
            received = bytearray(rest[-4096:])
            for line in lines:
                if line.startswith((b"BAD ", b"NOBOOT ")) or b" AHB=E " in line:
                    print(f"FAIL: AE350 bus check {line.decode('ascii', 'replace')}")
                    return 1
                if not line.startswith(args.expect.encode("ascii")):
                    continue
                if not matched:
                    print(f"PASS: {line.decode('ascii', 'replace')}")
                    matched = True
                found = PAIR.search(line)
                if args.clock and found:
                    pair = (int(found[1], 16), int(found[2], 16))
                    if not pairs or pair != pairs[-1]:
                        pairs.append(pair)
            if matched and len(pairs) > args.clock:
                break
    finally:
        link.close()
    if not matched:
        print(f"FAIL: no {args.expect!r} report; received {bytes(received[-128:])!r}")
        return 1
    if not args.clock:
        return 0
    rates = []
    for (cyc0, ref0), (cyc1, ref1) in zip(pairs, pairs[1:]):
        ref = (ref1 - ref0) & MASK
        if ref == 0:
            continue
        rates.append(((cyc1 - cyc0) & MASK) * REF_HZ / ref)
        print(f"core clock {rates[-1] / 1e6:.4f} MHz over {ref / REF_HZ:.3f} s")
    if len(rates) < args.clock:
        print(f"FAIL: {len(rates)} of {args.clock} clock intervals measured")
        return 1
    print(f"core clock mean {sum(rates) / len(rates) / 1e6:.4f} MHz")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
