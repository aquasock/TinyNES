#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Test the boot ROM loader against tools/load_ae350.py, on the host.

Builds tests/host_loader.c with firmware/boot/load.c, connects the two over a
pseudo-terminal, loads build/firmware/apps/rt_test/rt_test.elf (build it
first) and checks the SDRAM image, then the NAK and recovery paths with
dropped, corrupted and overrun bytes and bad headers.

    python3 tests/test_loader_host.py
"""

import os
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import zlib

import serial

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import load_ae350  # noqa: E402

BUILD = os.path.join(ROOT, "build", "host_loader")
HARNESS = os.path.join(BUILD, "host_loader")
ELF = os.path.join(ROOT, "build", "firmware", "apps", "rt_test", "rt_test.elf")
HEADER = 24
BLOCK = load_ae350.BLOCK + 4


def build():
    os.makedirs(BUILD, exist_ok=True)
    subprocess.run(
        ["gcc", "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror",
         "-I", "firmware/include", "-I", "firmware/common", "-I", "firmware/boot",
         "-o", HARNESS, "tests/host_loader.c", "firmware/boot/load.c",
         "firmware/common/uart.c"], cwd=ROOT, check=True)


def block_byte(block, offset=100):
    """The index of a byte of an image block among all bytes received."""
    return HEADER + block * BLOCK + offset


class LoaderTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build()
        cls.base, cls.image, cls.entry = load_ae350.read_image(ELF)
        cls.blocks = -(-len(cls.image) // load_ae350.BLOCK)
        assert cls.blocks >= 4

    def start(self, *faults):
        self.dir = tempfile.TemporaryDirectory()
        self.dump = os.path.join(self.dir.name, "sdram.bin")
        self.harness = subprocess.Popen(
            [HARNESS, self.dump, *map(str, faults)], stdout=subprocess.PIPE,
            text=True)
        self.port = self.harness.stdout.readline().strip()
        self.assertTrue(self.port.startswith("/dev/pts/"), self.port)

    def tearDown(self):
        self.harness.kill()
        self.harness.wait()
        self.harness.stdout.close()
        self.dir.cleanup()

    def run_loader(self, *extra):
        result = subprocess.run(
            [sys.executable, os.path.join(ROOT, "tools", "load_ae350.py"), ELF,
             "--port", self.port, "--run-timeout", "5", *extra],
            capture_output=True, text=True, timeout=60)
        return result.returncode, result.stdout + result.stderr

    def check_sdram(self):
        with open(self.dump, "rb") as f:
            sdram = f.read()
        offset = self.base - load_ae350.SDRAM[0]
        self.assertEqual(sdram[offset:offset + len(self.image)], self.image)
        self.assertEqual(sdram[:offset].count(0), offset)
        rest = sdram[offset + len(self.image):]
        self.assertEqual(rest.count(0), len(rest))

    def raw(self):
        link = serial.Serial(self.port, 2_000_000, timeout=0.05)
        board = load_ae350.Board(link)
        board.wait_line(b"TinyNES LOAD", 3, echo=False)
        return board

    def send_header(self, board, address, length, entry, image_crc):
        header = struct.pack("<5I", load_ae350.MAGIC, address, length, entry,
                             image_crc)
        board.link.write(header + struct.pack("<I", zlib.crc32(header)))

    def test_clean_load(self):
        self.start()
        code, out = self.run_loader("--expect", "TinyNES EXIT 0")
        self.assertEqual(code, 0, out)
        self.assertIn(f"TinyNES RUN {self.entry:08x}", out)
        self.assertNotIn("sending again", out)
        self.check_sdram()

    def test_block_naks_are_retried(self):
        last = self.blocks - 1
        self.start("flip", block_byte(1), "drop", block_byte(2),
                   "overrun", block_byte(3), "flip", block_byte(last, 0),
                   "drop", block_byte(0, BLOCK - 1))
        code, out = self.run_loader()
        self.assertEqual(code, 0, out)
        for reason in ("block CRC", "byte timeout", "receive overrun"):
            self.assertIn(f"NAK: {reason}, sending again", out)
        self.assertEqual(out.count("sending again"), 5, out)
        self.check_sdram()

    def test_too_many_naks_fail(self):
        faults = []
        for attempt in range(3):
            faults += ["flip", block_byte(1 + attempt)]
        self.start(*faults)
        # Each retry of block 1 shifts later indices by one block.
        code, out = self.run_loader("--retries", "2")
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL: NAK: block CRC", out)

    def test_bad_headers_then_recovery(self):
        self.start("flip", 7, "drop", HEADER + 5)
        code, out = self.run_loader()
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL: NAK: header CRC", out)
        code, out = self.run_loader()
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL: NAK: byte timeout", out)

        board = self.raw()
        for address, length, entry in (
                (0x3FFF_FFF0, 64, 0x4000_0000),     # below the SDRAM
                (0x41FF_FF00, 0x200, 0x41FF_FF00),  # past its end
                (0x4000_0000, 0, 0x4000_0000),      # empty
                (0x4000_0000, 64, 0x4000_0040),     # entry past the image
                (0x4000_0000, 64, 0x4000_0011),     # odd entry
                (0xFFFF_FF00, 0x200, 0xFFFF_FF00)): # wraps
            self.send_header(board, address, length, entry, 0)
            with self.assertRaisesRegex(load_ae350.LoadError,
                                        "outside the SDRAM"):
                board.reply(2)
        board.link.close()

        code, out = self.run_loader("--expect", "TinyNES EXIT 0")
        self.assertEqual(code, 0, out)
        self.check_sdram()

    def test_image_crc_mismatch(self):
        self.start()
        board = self.raw()
        body = bytes(range(256)) * 8
        self.send_header(board, 0x4000_1000, len(body), 0x4000_1000,
                         zlib.crc32(body) ^ 1)
        board.reply(2)
        board.link.write(body + struct.pack("<I", zlib.crc32(body)))
        board.reply(2)
        with self.assertRaisesRegex(load_ae350.LoadError,
                                    "image CRC after loading"):
            board.reply(2)
        board.link.close()

    def test_sender_gone_returns_to_waiting(self):
        self.start()
        board = self.raw()
        self.send_header(board, 0x4000_0000, 64, 0x4000_0000, 0)
        board.reply(2)
        started = time.monotonic()
        board.wait_line(b"TinyNES LOAD", 5, echo=False)
        self.assertGreater(time.monotonic() - started, 1.8)
        board.link.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
