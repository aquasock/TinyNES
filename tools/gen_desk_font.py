#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Write font8x8's basic Latin glyphs (font8x8_basic.h, public domain) as the
desk layer's font ROM for $readmemh: 1024 lines, one row byte each, glyph c
row r at line 8 * c + r, the least significant bit the leftmost pixel."""
import argparse
import re
import sys


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("header", help="font8x8_basic.h")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()

    text = open(args.header, encoding="ascii").read()
    body = text[text.index("font8x8_basic[128][8]"):]
    rows = re.findall(r"\{([^{}]*)\}", body)
    glyphs = [[int(v, 16) for v in re.findall(r"0x([0-9A-Fa-f]{2})", r)] for r in rows]
    glyphs = [g for g in glyphs if len(g) == 8]
    if len(glyphs) < 128:
        sys.exit(f"{args.header}: {len(glyphs)} glyphs, expected 128")
    with open(args.output, "w", encoding="ascii") as out:
        out.write("// font8x8_basic by Daniel Hepper, public domain (tools/fetch_font8x8.sh)\n")
        for glyph in glyphs[:128]:
            for row in glyph:
                out.write(f"{row:02x}\n")


if __name__ == "__main__":
    main()
