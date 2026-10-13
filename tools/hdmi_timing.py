#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Report the timing of TinyNES's HDMI output stage from an open-flow build.

nextpnr times no path into or out of an OSER10 on the GW5AST-138C (core
reference TOOL-023), so this reads the delays it wrote (--sdf) and the routed
netlist (--write) and works the stage out by hand:

  - for each OSER10 data input, the path from the TMDS encoder register that
    drives it: the pixel clock's arrival at that register, its clock to Q, and
    the route to the OSER10, against the pixel clock's arrival at the OSER10's
    PCLK one period later (setup) and at the same edge (hold); the OSER10's own
    setup and hold are not modelled anywhere and are taken as 0;
  - the serial clock's delay from the HDMI PLL to each OSER10's FCLK, and the
    pixel clock's delay from the divider to each PCLK, whose phase the OSER10
    needs fixed;
  - the TMDS clock lane's route from the divider to its output buffer;
  - the pixel-clock flip-flops whose clock is not on the global network.

Every delay is given at the speed grade the build used (C1/I0) and scaled to
the fork's other tables, C2/I1 (x 0.8) and unidentified_2 (x 0.6896), which
are uniform scalings of the same data (TOOL-023); none is a characterised
temperature corner.

  tools/hdmi_timing.py <routed.json> <design.sdf> [--period 13.468]
"""
import argparse
import json
import re
import sys

SCALES = (("C1/I0", 1.0), ("C2/I1", 0.8), ("unidentified_2", 0.862 / 1.25))


def unescape(name):
    return re.sub(r"\\(.)", r"\1", name)


def parse_sdf(path):
    """{(from, to): (min, max)} for INTERCONNECT and {(cell, from, to): (min,
    max)} for IOPATH, in ns, over rise and fall. Read a line at a time: the
    file is tens of megabytes."""
    tup = re.compile(r"\(([-\d.]*):([-\d.]*):([-\d.]*)\)")
    scale = 1.0
    inter, iopath, inst = {}, {}, None

    def mm(line):
        nums = [float(v) for t in tup.findall(line) for v in t if v != ""]
        return (min(nums) * scale, max(nums) * scale) if nums else (0.0, 0.0)

    with open(path) as f:
        for line in f:
            s = line.strip()
            if s.startswith("(TIMESCALE"):
                unit = s[len("(TIMESCALE"):].strip(" )")
                scale = {"1ps": 1e-3, "1ns": 1.0, "10ps": 1e-2, "100ps": 1e-1}.get(unit, 1.0)
            elif s.startswith("(INSTANCE"):
                inst = unescape(s[len("(INSTANCE"):].strip(" )"))
            elif s.startswith("(INTERCONNECT"):
                parts = s.split()
                inter[(unescape(parts[1]), unescape(parts[2]))] = mm(s)
            elif s.startswith("(IOPATH"):
                parts = s.split()
                iopath[(inst, unescape(parts[1]), unescape(parts[2]))] = mm(s)
    return inter, iopath


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("routed")
    ap.add_argument("sdf")
    ap.add_argument("--period", type=float, default=13.468)
    args = ap.parse_args()

    d = json.load(open(args.routed))
    top = next(m for m in d["modules"].values() if m.get("cells") and m["attributes"].get("top"))
    cells, nets = top["cells"], top["netnames"]
    inter, iopath = parse_sdf(args.sdf)
    if not inter:
        sys.exit(f"{args.sdf}: no INTERCONNECT entries")

    driver = {}
    for name, c in cells.items():
        for port, bits in c["connections"].items():
            if c["port_directions"].get(port) == "output":
                for b in bits:
                    if isinstance(b, int):
                        driver[b] = (name, port)

    def net_of(cell, port):
        bits = cells[cell]["connections"].get(port) or [None]
        return bits[0]

    def wire_delay(cell, port):
        """(min, max) route delay to cell/port from its net's driver."""
        b = net_of(cell, port)
        src = driver.get(b) if b is not None else None
        if not src:
            return None, None
        key = (f"{src[0]}/{src[1]}", f"{cell}/{port}")
        return src, inter.get(key)

    sers = sorted(n for n, c in cells.items() if c["type"] == "OSER10")
    out = []
    print(f"HDMI output stage of {args.routed}")
    print(f"pixel clock period {args.period:.3f} ns; OSER10 setup and hold taken as 0 (no model)\n")

    # PCLK and FCLK at each OSER10.
    print("Serialiser clocks (route delay from the clock's source, min..max ns):")
    pclk_at, fclk_at = {}, {}
    for s in sers:
        fsrc, f = wire_delay(s, "FCLK")
        psrc, p = wire_delay(s, "PCLK")
        fclk_at[s], pclk_at[s] = f, p
        print(f"  {s}: FCLK from {fsrc[0]}.{fsrc[1]} {fmt(f)}   PCLK from {psrc[0]}.{psrc[1]} {fmt(p)}")
    div = next((n for n, c in cells.items() if c["type"] == "CLKDIV"), None)
    if div:
        hsrc, h = wire_delay(div, "HCLKIN")
        print(f"  {div}.HCLKIN from {hsrc[0]}.{hsrc[1]} {fmt(h)}; the CLKDIV's own delay is not modelled")
        if h:
            for s in sers:
                if pclk_at[s] and fclk_at[s]:
                    lo = h[0] + pclk_at[s][0] - fclk_at[s][1]
                    hi = h[1] + pclk_at[s][1] - fclk_at[s][0]
                    print(f"  {s}: PCLK lags FCLK by {lo:.3f}..{hi:.3f} ns plus the CLKDIV's delay "
                          f"({lo / 2.694:.2f}..{hi / 2.694:.2f} serial periods)")
    print()

    # Encoder register -> OSER10 D.
    print("Encoder register to OSER10 data inputs (ns at C1/I0):")
    worst = []
    for s in sers:
        for i in range(10):
            src, route = wire_delay(s, f"D{i}")
            if not src or not route:
                print(f"  {s}.D{i}: no driver or no delay")
                continue
            reg = src[0]
            rc = cells[reg]
            clkport = next((p for p in ("CLK",) if p in rc["connections"]), None)
            if clkport is None:
                print(f"  {s}.D{i}: driven by {reg} ({rc['type']}), not a register")
                continue
            _, launch = wire_delay(reg, clkport)
            tco = iopath.get((reg, "CLK", src[1])) or iopath.get((reg, "CLK", "Q")) or (0.0, 0.0)
            cap = pclk_at[s]
            if not launch or not cap:
                continue
            setup = args.period + cap[0] - (launch[1] + tco[1] + route[1])
            hold = launch[0] + tco[0] + route[0] - cap[1]
            worst.append((setup, hold, f"{s}.D{i}", reg, route))
    worst.sort()
    for setup, hold, pin, reg, route in worst[:5]:
        print(f"  {pin} <- {reg}: route {fmt(route)}, setup slack {setup:.3f}, hold slack {hold:.3f}")
    if worst:
        hw = min(worst, key=lambda w: w[1])
        hs = hw[1]
        print(f"  worst hold: {hw[2]} <- {hw[3]}: route {fmt(hw[4])}, hold slack {hs:.3f}")
        print(f"  {len(worst)} paths: worst setup slack {worst[0][0]:.3f} ns, worst hold slack {hs:.3f} ns")
        out.append(("setup", worst[0][0]))
        out.append(("hold", hs))
    print()

    # The clock lane.
    lane = [n for n, c in cells.items() if c["type"] in ("ELVDS_OBUF", "TLVDS_OBUF", "OBUF")
            and any("tmds_clk" in nn for nn, v in nets.items()
                    for b in v["bits"] if b in sum(c["connections"].values(), []))]
    for n in lane:
        src, dl = wire_delay(n, "I")
        if src and dl:
            print(f"Clock lane {n}.I from {src[0]}.{src[1]}: route {fmt(dl)} (no buffer model)")
    print()

    # Pixel-clock sinks off the global network.
    pix = next((nn for nn in ("pix_clk",) if nn in nets), None)
    if pix:
        route = nets[pix]["attributes"].get("ROUTING", "").split(";")
        off = sorted({w.split("/")[0] for w, p in zip(route[0::3], route[1::3])
                      if re.match(r".*/CLK\d$", w) and p and not p.split("/")[2].startswith(("GB", "GT"))})
        print(f"pix_clk clock pins fed off the global network: {len(off)} tiles {', '.join(off)}")
    print()

    print("Scaled to the fork's other tables (same routing):")
    for name, k in SCALES:
        cols = "  ".join(f"{what} {v * k:7.3f}" if what == "hold" else
                         f"{what} {args.period - (args.period - v) * k:7.3f}" for what, v in out)
        print(f"  {name:15s} x{k:.4f}  {cols}")


def fmt(v):
    return "none" if not v else f"{v[0]:.3f}..{v[1]:.3f}"


if __name__ == "__main__":
    main()
