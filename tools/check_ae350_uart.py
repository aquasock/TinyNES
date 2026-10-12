#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Verify the AE350-started UART report in one-wire debug mode."""

import argparse
import time

import serial


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default="/dev/ttyUSB1")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--expect", default="TinyNES AE350 OK")
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
    try:
        while time.monotonic() < deadline:
            received.extend(link.read(128))
            if (args.expect + "\r\n").encode("ascii") in received:
                print(f"PASS: {args.expect} received")
                return 0
            if len(received) > 4096:
                del received[:-128]
    finally:
        link.close()
    print(f"FAIL: no {args.expect!r} report; received {bytes(received[-128:])!r}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
