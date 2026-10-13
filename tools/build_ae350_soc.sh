#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
src="$root/fpga/ae350_soc"
# TINY_NES_SOC_DIAG=1 holds the A25 in reset; 2 lets it run but drops its
# UART bytes. Either way the fabric's NOBOOT report is the only output.
# 3 makes the video unit colour each pixel from its palette index instead of
# the palette, to tell palette faults from frame-buffer faults.
case "${TINY_NES_SOC_DIAG:-0}" in
    0) synth_param=""; default_out="$root/build/ae350_soc" ;;
    1) synth_param="chparam -set CPU_HOLD 1 ae350_soc_top"; default_out="$root/build/ae350_soc_hold" ;;
    2) synth_param="chparam -set CPU_TX_DROP 1 ae350_soc_top"; default_out="$root/build/ae350_soc_drop" ;;
    3) synth_param="chparam -set DEBUG_INDEX 1 video"; default_out="$root/build/ae350_soc_index" ;;
    *) echo "TINY_NES_SOC_DIAG must be 0, 1, 2 or 3" >&2; exit 2 ;;
esac
out="${TINY_NES_BUILD_DIR:-$default_out}"
suite="${OSS_CAD_SUITE:-$HOME/oss-cad-suite}"
nextpnr="${NEXTPNR_HIMBAECHEL:-$HOME/tools/nextpnr-mathieufro/nextpnr-himbaechel}"
apycula="${APICULA_FORK:-$(dirname "$root")/apicula-mathieufro}"
pydeps="${PYDEPS:-$HOME/tools/pydeps}"
device=GW5AST-LV138PG484AC1/I0
family=GW5AST-138C
# Placement decides pixel-clock hold and bus-clock Fmax. With the desk
# layer, 6 of 16 seeds were clean in a sweep with bus_clk routed first, all
# failures pixel-clock hold; seed 5 had the best margin on both clocks
# together and is repeatable.
seed="${TINY_NES_SEED:-5}"

[[ -f "$suite/environment" ]] || { echo "missing open toolchain: $suite" >&2; exit 2; }
# shellcheck disable=SC1090
source "$suite/environment"
export PYTHONHOME="$suite"
export PYTHONPATH="$apycula:$pydeps:${PYTHONPATH:-}"
# Temporary: the A25 bus dies when its clock reaches the AE350 through global
# branch GB20, and works through GB10. The nextpnr fork's experimental knob
# routes bus_clk first so it takes GB10. Remove once the GB20 fault is fixed.
export NPNR_GOWIN_CLK_FIRST="${NPNR_GOWIN_CLK_FIRST:-bus_clk}"

[[ -x "$nextpnr" ]] || { echo "missing open nextpnr: $nextpnr" >&2; exit 2; }
[[ -f "$apycula/apycula/$family.msgpack.xz" ]] || {
    echo "missing local Apicula device database in $apycula/apycula" >&2; exit 2;
}
mkdir -p "$out"

echo "Boot ROM firmware"
make -s -C "$root/firmware/boot"

# The boot ROM's INIT_FILE is relative to the repository root.
cd "$root"
echo "Yosys synthesis"
yosys -Q -T -q -l "$out/synth.log" -p "
    read_verilog -lib $suite/share/yosys/gowin/cells_xtra_gw5a.v
    read_verilog -sv $src/ahb_boot_rom.sv $src/ahb_ram.sv $src/ahb_sdram.sv $src/exts_uart.sv $src/desk_link.sv $src/video.sv $src/wii_pads.sv $src/i2s_out.sv $src/ae350_soc.sv
    $synth_param
    synth_gowin -family gw5a -top ae350_soc_top
    write_json $out/ae350_soc.json
"

echo "nextpnr placement and routing"
"$nextpnr" \
    --json "$out/ae350_soc.json" \
    --write "$out/ae350_soc-routed.json" \
    --device "$device" \
    --freq 75 \
    --vopt cst="$src/ae350_soc.cst" \
    --sdc "$src/ae350_soc.sdc" \
    --report "$out/timing.json" \
    --seed "$seed" \
    >"$out/nextpnr.log" 2>&1 || {
        tail -80 "$out/nextpnr.log" >&2
        exit 1
    }
grep -q "routing '$NPNR_GOWIN_CLK_FIRST' first" "$out/nextpnr.log" || {
    echo "nextpnr did not route $NPNR_GOWIN_CLK_FIRST first (needs the fork's NPNR_GOWIN_CLK_FIRST knob)" >&2
    exit 1
}

echo "Apicula bitstream packing"
"$suite/py3bin/python3" - "$out" <<'PY'
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
design = json.loads((out / "ae350_soc-routed.json").read_text())
route = design["modules"]["top"]["netnames"]["core_clk"]["attributes"]["ROUTING"]
if "AE350_CORE_CLK_PLLR0" not in route:
    raise SystemExit("AE350 dedicated PLL clock hop is absent from routed design")
print("AE350 dedicated PLL clock hop present")
timing = json.loads((out / "timing.json").read_text())["fmax"]["bus_clk"]
if timing["constraint"] < 75 or timing["achieved"] < 75:
    raise SystemExit(f"75 MHz AHB bus timing failed: {timing}")
print(f"Bus Fmax {timing['achieved']:.2f} MHz")
# The HDMI pixel clock must have been timed at its real rate, not a default.
pixel = [t for t in json.loads((out / "timing.json").read_text())["fmax"].values()
         if abs(t["constraint"] - 74.25) < 0.05]
if not pixel:
    raise SystemExit("HDMI pixel clock was not constrained at 74.25 MHz")
if min(t["achieved"] for t in pixel) < 74.25:
    raise SystemExit(f"74.25 MHz HDMI pixel clock timing failed: {pixel}")
print(f"Pixel Fmax {min(t['achieved'] for t in pixel):.2f} MHz")
# Block RAM written on one clock and read on another reads back wrong in the
# open flow on this chip (core-log entry 14), so every block RAM in the video
# unit must have both ports on one clock; its line buffers are flip-flops.
cells = design["modules"]["top"]["cells"]
video_rams = {n: c for n, c in cells.items() if n.startswith("screen.")
              and any(p.startswith("CLKB") for p in c["connections"])}
two_clock = sorted(n for n, c in video_rams.items()
                   if c["connections"]["CLKA"] != c["connections"]["CLKB"])
if two_clock:
    raise SystemExit(f"video block RAMs on two clocks: {two_clock[:4]}")
print(f"Video block RAMs: {len(video_rams)}, each on one clock")
# Only the 9-bit block RAM modes have been shown to read back correctly in
# the video unit on this chip (core-log entry 14), so its stores, the desk
# layer's included, must map to them.
other_modes = sorted(n for n, c in cells.items() if n.startswith("screen.")
                     and any(k.startswith("BIT_WIDTH") and int(v, 2) % 9
                             for k, v in c["parameters"].items()))
if other_modes:
    raise SystemExit(f"video block RAMs not in 9-bit mode: {other_modes[:4]}")
# The pixel clock must reach the spines only through the bridge pips measured
# to clock (core-log entry 14): (27,96) and (81,96) SPINE26 <= CBRIDGEOUT_BOTTOM2.
pix_route = design["modules"]["top"]["netnames"]["pix_clk"]["attributes"]["ROUTING"].split(";")
bridges = sorted({p.split("/", 1)[1] for p in pix_route[1::3] if "/CBRIDGEOUT" in p})
if bridges != ["SPINE26/CBRIDGEOUT_BOTTOM2"]:
    raise SystemExit(f"pixel clock uses unmeasured clock bridge pips: {bridges}")
print("Pixel clock bridge: SPINE26 <= CBRIDGEOUT_BOTTOM2 only")
PY
"$suite/py3bin/python3" -m apycula.gowin_pack \
    -d "$family" \
    -o "$out/ae350_soc.fs" \
    "$out/ae350_soc-routed.json" \
    >"$out/pack.log" 2>&1 || {
        tail -80 "$out/pack.log" >&2
        exit 1
    }

# One-wire SRAM loads take the text .fs; TinyTang's tangload in two-wire mode
# takes the same bits packed eight to a byte as a .bin on the SD card.
"$suite/py3bin/python3" "$root/tools/fs_to_bin.py" "$out/ae350_soc.fs" -o "$out/ae350_soc.bin" >/dev/null

sha256sum "$out/ae350_soc.fs" "$out/ae350_soc.bin"
echo "Ready to SRAM load (one-wire): $out/ae350_soc.fs"
echo "Ready to tangload (two-wire):  $out/ae350_soc.bin"
