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
# Placement decides pixel-clock hold and bus-clock Fmax. With the HDMI PLLs
# at PLL_R[1] and PLL_R[3], 8 of 16 seeds were clean in a sweep with bus_clk
# routed first, all failures pixel-clock hold; seed 10 had the best margin on
# both clocks together and the fewest pixel-clock pins off the global
# network, and is repeatable.  The aspect register and its column picker moved
# the placement, and in a second sweep on 2026-10-14 seed 10 failed with four
# pixel-clock holds while 8 of 16 were still clean; seed 11 is that sweep's
# pick by the same rule -- 85.03 MHz on bus_clk and 85.24 on pix_clk against
# 75 and 74.25, with the fewest pixel-clock pins off the global network (2)
# and the shortest pixel-clock route (482 pips) of any seed.  The HDMI
# transmitter and its audio handoff moved it again: in the eight-seed sweep of
# 2026-10-21 with pix_clk routed first, 7 of 8 were clean, and seed 8 -- 79.38
# MHz on bus_clk and 92.15 on pix_clk, the pixel clock on SPINE16+SPINE25 --
# is the image the board was tested on (core-log entry 42).  The default must
# stay the seed that was tested, since tools/deploy_tinytang.sh takes this
# build's image unless told otherwise.
seed="${TINY_NES_SEED:-8}"

[[ -f "$suite/environment" ]] || { echo "missing open toolchain: $suite" >&2; exit 2; }
# shellcheck disable=SC1090
source "$suite/environment"
export PYTHONHOME="$suite"
export PYTHONPATH="$apycula:$pydeps:${PYTHONPATH:-}"
# Temporary: the A25 bus dies when its clock reaches the AE350 through global
# branch GB20, and works through GB10. The nextpnr fork's experimental knob
# routes bus_clk first so it takes GB10. Remove once the GB20 fault is fixed.
# The pixel clock is routed first: with the HDMI transmitter folded in, routing
# bus_clk first sends the pixel clock onto SPINE19+SPINE26 (+SPINE27 on five
# of eight seeds), none of which is measured, while pix_clk-first lands it on
# SPINE16+SPINE25, which this board runs (core-log entry 41).
export NPNR_GOWIN_CLK_FIRST="${NPNR_GOWIN_CLK_FIRST:-pix_clk}"

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

# The HDMI transmitter is hdl-util's, whose ports are unpacked arrays that
# Yosys's classic front end rejects, so the design goes through read_slang.
# Primitive visibility needs the cell libraries twice over: once as -v sources
# and once as --blackboxed-module, or a primitive is dropped without a word.
shim="$out/shim"
mkdir -p "$shim"
datdir=$(yosys-config --datdir 2>/dev/null)
[[ -n "${datdir:-}" && -d "$datdir/gowin" ]] || datdir="$suite/share/yosys"
awk '/^[[:space:]]*specify[[:space:]]*$/ { skip=1 }
     !skip { print }
     /^[[:space:]]*endspecify[[:space:]]*$/ { skip=0 }' \
    "$datdir/gowin/cells_sim.v" > "$shim/cells_sim_nospecify.v"
cp "$datdir/gowin/cells_xtra_gw5a.v" "$shim/cells_xtra_gw5a.v"

export LC_ALL=C
libmods=$(grep -hoE '^[[:space:]]*module [A-Za-z_][A-Za-z0-9_]*' "$shim"/cells_*.v |
          awk '{print $2}' | sort -u)
dnames=$(grep -rhoE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*' "$src" "$root/fpga/hdmi" \
              --include=*.v --include=*.sv 2>/dev/null |
         sed 's/^[[:space:]]*//' | sort -u)
bb=$(comm -12 <(echo "$libmods") <(echo "$dnames")) || true
bbflags=$(echo "$bb" | sed 's/^/--blackboxed-module /' | paste -sd' ')

yosys -Q -T -q -l "$out/synth.log" -p "
    read_verilog -lib $shim/cells_xtra_gw5a.v
    read_slang --std 1800-2017 -U SYNTHESIS -D GW_IDE --allow-use-before-declare --allow-lib-module-redef $bbflags -v $shim/cells_sim_nospecify.v -v $shim/cells_xtra_gw5a.v -I $root/fpga/hdmi $root/fpga/hdmi/hdmi_silent.sv $root/fpga/hdmi/hdmi.sv $root/fpga/hdmi/packet_assembler.sv $root/fpga/hdmi/packet_picker.sv $root/fpga/hdmi/audio_sample_packet.sv $root/fpga/hdmi/audio_clock_regeneration_packet.sv $root/fpga/hdmi/audio_info_frame.sv $root/fpga/hdmi/auxiliary_video_information_info_frame.sv $root/fpga/hdmi/source_product_description_info_frame.sv $root/fpga/hdmi/serializer.sv $root/fpga/hdmi/tmds_channel.sv
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
# Measured on this board (core-log entry 41): SPINE26 alone (the DVI image) and
# SPINE16+SPINE25 together (the HDMI transmitter at seed 7, where Castlevania
# played).  SPINE17 and SPINE18 clock nothing (DEV-017), and every other set is
# still unmeasured, so it is refused rather than guessed at.
measured = [{"SPINE26/CBRIDGEOUT_BOTTOM2"},
            {"SPINE16/CBRIDGEOUT_BOTTOM2", "SPINE25/CBRIDGEOUT_BOTTOM2"}]
if set(bridges) not in measured:
    raise SystemExit(f"pixel clock uses unmeasured clock bridge pips: {bridges}")
print("Pixel clock bridges: " + ", ".join(bridges))
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
