#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Run 100th Coin's AccuracyCoin test cartridge on the PC build of nes_bench
(the same FCEUmm core and driver as the board) and report every test's result.

The cartridge is fetched by tools/fetch_accuracycoin.sh. A scripted controller
marks the tests given with --skip as skipped (B on a test), returns to the page
index and presses Start, which runs every other test; when the run ends the
program writes the NES's work RAM (NES_RAM_DUMP), and the results are read from
$0400-$04FF using the cartridge's own source: its TestPages suite list gives the
pages in order, each suite's `table` lines the tests and their result bytes, and
the `result_* = $04xx` definitions the addresses.

A result byte's low two bits are 1 for a pass, 2 for a fail and 3 for a test
still running, its upper six bits the success or error code shown on screen
(0-9, then A for 10 and so on); $FF marks a skipped test. DRAW tests print
information and are not counted, as on the cartridge's own results screen.

    tools/accuracycoin.py                      run and print the results
    tools/accuracycoin.py --expect FILE        and compare with FILE
    tools/accuracycoin.py --write FILE         and save them to FILE

With --expect it exits 1 if any test that passed in FILE no longer passes.
Page 19's Misaligned OAM Behavior hangs FCEUmm (it waits for a sprite zero hit
that never comes), so it is skipped unless --skip says otherwise."""
import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CART = os.path.join(ROOT, "third_party", "accuracycoin")
APP = os.path.join(ROOT, "firmware", "apps", "nes_bench")
CODES = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"


def parse_source(path):
    """[(page, index, name, address)] in the cartridge's own order."""
    text = open(path, encoding="latin-1").read()
    addr = {m.group(1): int(m.group(2), 16)
            for m in re.finditer(r"^(result_\w+)\s*=\s*\$([0-9A-Fa-f]+)", text, re.M)}
    start = re.search(r"^TestPages:", text, re.M).start()
    pointers = text[:start]
    suites = re.findall(r"^\s*\.word\s+(Suite_\w+)", pointers, re.M)
    tests = []
    for page, suite in enumerate(suites, 1):
        m = re.search(r"^" + suite + r":\s*\n(.*?)(?=^Suite_\w+:|\Z)", text[start:], re.M | re.S)
        if not m:
            sys.exit(f"{path}: no {suite}")
        index = 0
        # `table "name"`, or `tblf1`/`tblf2` with the name in pieces: a string,
        # then str_* labels (their text) and more strings, then $FF.
        for t in re.finditer(r'^\s*(?:table|tblf1|tblf2)\s+(.*?),\s*\$FF,\s*(result_\w+)',
                             m.group(1), re.M):
            index += 1
            pieces = re.findall(r'"([^"]*)"|str_(\w+)', t.group(1))
            name = " ".join(q or w for q, w in pieces).replace("  ", " ").replace(" ,", ",")
            name = re.sub(r"\s+", " ", name)
            result = t.group(2)
            if result == "result_DrawTest":
                continue
            tests.append((page, index, name, addr[result]))
    return tests


def script(skips):
    """The controller script: mark each skip, back to the index, Start."""
    presses, frame, page = [], 60, 1

    def press(button):
        nonlocal frame
        presses.append(f"{frame}+3={button}")
        frame += 8

    for target_page, index in sorted(skips):
        # index 0 is the page index itself: B there skips the whole page.
        for _ in range(target_page - page):
            press("right")
        page = target_page
        for _ in range(index):
            press("down")
        press("b")
        for _ in range(index):
            press("up")
    frame += 30
    press("start")
    return " ".join(presses)


def decode(byte):
    if byte == 0xFF:
        return "SKIP"
    kind, code = byte & 3, CODES[byte >> 2] if byte >> 2 < len(CODES) else "?"
    if kind == 1:
        return "PASS" if code == "0" else f"PASS {code}"
    if kind == 2:
        return f"FAIL {code}"
    if kind == 3:
        return "RUNNING"
    return "NOT RUN"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--skip", default="19.7",
                    help="comma-separated page.test numbers to skip, or a page number "
                         "for the whole page (default 19.7)")
    ap.add_argument("--frames", type=int, default=6000)
    ap.add_argument("--build", default=os.path.join(ROOT, "build", "accuracycoin"))
    ap.add_argument("--expect", help="compare with a saved result file")
    ap.add_argument("--write", help="save the results to this file")
    args = ap.parse_args()

    rom = os.path.join(CART, "AccuracyCoin.nes")
    if not os.path.exists(rom):
        sys.exit("run tools/fetch_accuracycoin.sh first")
    tests = parse_source(os.path.join(CART, "AccuracyCoin.asm"))
    skips = [(int(s.split(".")[0]), int(s.split(".")[1]) if "." in s else 0)
             for s in args.skip.split(",") if s]

    subprocess.run(["make", "-s", "-C", APP, "-j16", f"ROM={rom}", f"BUILD={args.build}",
                    f"FRAMES={args.frames}", f"INPUT={script(skips)}", "host"],
                   check=True, stdout=subprocess.DEVNULL)
    ram_path = os.path.join(args.build, "ram.bin")
    if os.path.exists(ram_path):
        os.remove(ram_path)
    env = dict(os.environ, NES_RAM_DUMP=ram_path)
    subprocess.run([os.path.join(args.build, "host", "nes_bench")], env=env,
                   check=True, stdout=subprocess.DEVNULL)
    ram = open(ram_path, "rb").read()

    lines, passed, failed, skipped, other = [], 0, 0, 0, 0
    for page, index, name, address in tests:
        result = decode(ram[address])
        lines.append(f"{page:2}.{index}  {result:8}  {name}")
        if result.startswith("PASS"):
            passed += 1
        elif result.startswith("FAIL"):
            failed += 1
        elif result == "SKIP":
            skipped += 1
        else:
            other += 1
    summary = (f"PASSED {passed} / {len(tests)}  FAILED {failed}  SKIPPED {skipped}"
               + (f"  INCOMPLETE {other}" if other else ""))
    print("\n".join(lines))
    print(summary)

    if args.write:
        with open(args.write, "w", encoding="ascii") as out:
            out.write("\n".join(lines) + "\n" + summary + "\n")
    status = 0
    if args.expect:
        old = {}
        for line in open(args.expect, encoding="ascii"):
            m = re.match(r"\s*(\d+\.\d+)\s+(.+?)\s{2,}", line)
            if m:
                old[m.group(1)] = m.group(2).strip()
        for line in lines:
            key, result = line.split()[0], line[6:14].strip()
            before = old.get(key)
            if before is None or before == result:
                continue
            regressed = before.startswith("PASS") and not result.startswith("PASS")
            print(f"{'REGRESSED' if regressed else 'CHANGED  '} {key}: {before} -> {result}")
            status |= regressed
    if other:
        print("the run did not finish: raise --frames, or skip the test still running")
        status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
