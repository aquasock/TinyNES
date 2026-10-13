#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Load a program into the TinyNES AE350 SDRAM over the UART and run it.

Waits for the boot ROM's "TinyNES LOAD" line, sends the ELF file's loadable
segments as one image with the protocol in firmware/include/tinynes.h, then
prints the program's output until it exits. Fails if the ROM or the program
prints a line starting with BAD, the ROM reports NOBOOT, the program exits
with a nonzero code, or an --expect prefix never appears.

A program that prints "TinyNES WANT <address> <bytes>" is sent --file the
same way, as a second image at that address holding "TNR1", the file's
length and the file (nes_bench's PLAY=1 build takes its cartridge so).

In one-wire mode the port is the debug bridge's FPGA UART, /dev/ttyUSB1. In
two-wire mode, --tinytang, the port is TinyTang's USB console: the board is
asked whether its shell is at a prompt, and its `fpgapipe` command then
passes the console straight through to the same FPGA UART until this tool
closes the port.
"""

import argparse
import re
import struct
import sys
import time
import zlib

import serial

MAGIC = 0x314C4E54
ACK = 0x06
NAK = 0x15
BLOCK = 8192
SDRAM = (0x4000_0000, 0x4200_0000)
REASONS = {
    b"T": "byte timeout",
    b"H": "header CRC",
    b"A": "image outside the SDRAM",
    b"C": "block CRC",
    b"O": "receive overrun",
    b"I": "image CRC after loading",
}
PT_LOAD = 1
EM_RISCV = 243
# TinyTang's console status probe and its reply; 1 is the shell prompt
# (TinyTang ports/bl616/tdsh_bl616.h).
FILE_MAGIC = b"TNR1"
PROBE = b"\x1b[?77n"
PROBE_REPLY = re.compile(rb"\x1b\[\?77;(\d+)n")


class LoadError(Exception):
    pass


def read_image(path):
    """The loadable segments as (load address, bytes, entry)."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF" or data[4] != 1 or data[5] != 1:
        raise LoadError(f"{path}: not a little-endian 32-bit ELF file")
    (_, machine, _, entry, phoff, _, _, _, phentsize,
     phnum) = struct.unpack_from("<HHIIIIIHHH", data, 16)
    if machine != EM_RISCV:
        raise LoadError(f"{path}: not a RISC-V program")
    segments = []
    for index in range(phnum):
        (kind, offset, _, paddr, filesz, _, _,
         _) = struct.unpack_from("<8I", data, phoff + index * phentsize)
        if kind == PT_LOAD and filesz:
            segments.append((paddr, data[offset:offset + filesz]))
    if not segments:
        raise LoadError(f"{path}: nothing to load")
    base = min(address for address, _ in segments)
    end = max(address + len(body) for address, body in segments)
    if base < SDRAM[0] or end > SDRAM[1]:
        raise LoadError(f"{path}: {base:#x}..{end:#x} is not inside the SDRAM")
    image = bytearray(end - base)
    for address, body in segments:
        image[address - base:address - base + len(body)] = body
    return base, bytes(image), entry


def crc(data):
    return zlib.crc32(data) & 0xFFFF_FFFF


class Board:
    def __init__(self, link):
        self.link = link
        self.text = bytearray()

    def check_line(self, line):
        if line.startswith((b"BAD", b"NOBOOT ")):
            raise LoadError(line.decode("ascii", "replace"))

    def lines(self, deadline):
        """Complete lines received before the deadline."""
        while time.monotonic() < deadline:
            self.text.extend(self.link.read(max(1, self.link.in_waiting)))
            while b"\n" in self.text:
                line, _, rest = self.text.partition(b"\n")
                self.text = bytearray(rest)
                yield line.rstrip(b"\r")

    def wait_line(self, prefix, timeout, echo):
        for line in self.lines(time.monotonic() + timeout):
            if echo:
                print(line.decode("ascii", "replace"))
            self.check_line(line)
            if line.startswith(prefix):
                return
        raise LoadError(f"no {prefix.decode()!r} line in {timeout} s")

    def reply(self, timeout):
        """ACK, or raise with the NAK reason; text in between is kept."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            byte = self.link.read(1)
            if not byte:
                continue
            if byte[0] == ACK:
                return
            if byte[0] == NAK:
                reason = self.link.read(1)
                raise LoadError(f"NAK: {REASONS.get(reason, reason)}")
            self.text.extend(byte)
        raise LoadError(f"no reply in {timeout} s")


def open_pipe(board):
    """Put TinyTang's console through to the FPGA UART with `fpgapipe`."""
    link = board.link
    time.sleep(0.2)
    link.reset_input_buffer()
    link.write(PROBE)
    seen = b""
    deadline = time.monotonic() + 1.5
    while time.monotonic() < deadline:
        seen += link.read(256)
        match = PROBE_REPLY.search(seen)
        if match:
            if match.group(1) != b"1":
                raise LoadError(f"TinyTang console is in state "
                                f"{match.group(1).decode()}, not at a prompt")
            break
    else:
        raise LoadError("TinyTang console did not answer the status probe")
    link.write(b"fpgapipe\r")
    board.wait_line(b"fpgapipe: open", 2.0, echo=False)


def load(board, base, image, entry, retries):
    header = struct.pack("<5I", MAGIC, base, len(image), entry, crc(image))
    board.link.reset_input_buffer()
    board.text.clear()
    board.link.write(header + struct.pack("<I", crc(header)))
    board.reply(2.0)
    for offset in range(0, len(image), BLOCK):
        block = image[offset:offset + BLOCK]
        for attempt in range(retries + 1):
            board.link.write(block + struct.pack("<I", crc(block)))
            try:
                board.reply(2.0)
                break
            except LoadError as error:
                if attempt == retries or "NAK" not in str(error):
                    raise
                print(f"block at {base + offset:#x}: {error}, sending again",
                      file=sys.stderr)
                time.sleep(0.02)
    # The ROM reads the whole image back from the SDRAM to check it.
    board.reply(2.0 + len(image) / 1e6)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("elf")
    parser.add_argument("--port", default=None,
                        help="default /dev/ttyUSB1, or /dev/ttyACM0 with "
                        "--tinytang")
    parser.add_argument("--tinytang", action="store_true",
                        help="two-wire: go through TinyTang's fpgapipe")
    parser.add_argument("--baud", type=int, default=2_000_000)
    parser.add_argument("--timeout", type=float, default=5.0,
                        help="seconds to wait for the ROM's LOAD line")
    parser.add_argument("--run-timeout", type=float, default=30.0,
                        help="seconds the program may run; 0 for no limit")
    parser.add_argument("--retries", type=int, default=5)
    parser.add_argument("--file", help="sent when the program asks for one "
                        "with a TinyNES WANT line")
    parser.add_argument("--expect", action="append", default=[],
                        help="an output line must start with this; repeatable")
    args = parser.parse_args()

    try:
        base, image, entry = read_image(args.elf)
        payload = None
        if args.file:
            with open(args.file, "rb") as f:
                data = f.read()
            payload = FILE_MAGIC + struct.pack("<I", len(data)) + data
    except (OSError, LoadError) as error:
        print(f"FAIL: {error}")
        return 1
    link = serial.Serial()
    link.port = args.port or ("/dev/ttyACM0" if args.tinytang
                              else "/dev/ttyUSB1")
    link.baudrate = args.baud
    link.timeout = 0.05
    # TinyTang sends nothing until a program raises DTR, and ends fpgapipe
    # when it drops; the debug bridge's port is opened without moving a line.
    link.dtr = args.tinytang
    link.rts = False
    link.open()
    board = Board(link)
    expected = [prefix.encode("ascii") for prefix in args.expect]
    run_limit = args.run_timeout or float("inf")
    try:
        if args.tinytang:
            open_pipe(board)
        board.wait_line(b"TinyNES LOAD", args.timeout, echo=True)
        start = time.monotonic()
        load(board, base, image, entry, args.retries)
        seconds = time.monotonic() - start
        print(f"loaded {len(image)} bytes at {base:#x} in {seconds:.2f} s "
              f"({len(image) / seconds / 1000:.1f} KB/s)")
        for line in board.lines(time.monotonic() + run_limit):
            print(line.decode("ascii", "replace"))
            board.check_line(line)
            if line.startswith(b"TinyNES WANT "):
                if payload is None:
                    raise LoadError("the program wants a file; give --file")
                fields = line.split()
                address, room = int(fields[2], 16), int(fields[3], 16)
                if len(payload) > room:
                    raise LoadError(f"{args.file}: {len(payload)} bytes, "
                                    f"room for {room}")
                start = time.monotonic()
                load(board, address, payload, address, args.retries)
                seconds = time.monotonic() - start
                print(f"sent {len(payload)} bytes at {address:#x} in "
                      f"{seconds:.2f} s")
                continue
            expected = [p for p in expected if not line.startswith(p)]
            if line.startswith(b"TinyNES EXIT "):
                code = line.split()[2].decode()
                if code != "0":
                    raise LoadError(f"program exited with {code}")
                if expected:
                    raise LoadError(f"missing {expected[0].decode()!r}")
                print("PASS")
                return 0
        raise LoadError(f"program still running after {args.run_timeout} s")
    except LoadError as error:
        print(f"FAIL: {error}")
        return 1
    except KeyboardInterrupt:
        print("stopped")
        return 130
    finally:
        link.close()


if __name__ == "__main__":
    sys.exit(main())
