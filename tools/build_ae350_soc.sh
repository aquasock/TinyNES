#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
src="$root/fpga/ae350_soc"
# TINY_NES_SOC_DIAG=1 holds the A25 in reset; 2 lets it run but drops its
# UART bytes. Either way the fabric's NOBOOT report is the only output.
case "${TINY_NES_SOC_DIAG:-0}" in
    0) synth_param=""; default_out="$root/build/ae350_soc" ;;
    1) synth_param="chparam -set CPU_HOLD 1 ae350_soc_top"; default_out="$root/build/ae350_soc_hold" ;;
    2) synth_param="chparam -set CPU_TX_DROP 1 ae350_soc_top"; default_out="$root/build/ae350_soc_drop" ;;
    *) echo "TINY_NES_SOC_DIAG must be 0, 1 or 2" >&2; exit 2 ;;
esac
out="${TINY_NES_BUILD_DIR:-$default_out}"
suite="${OSS_CAD_SUITE:-$HOME/oss-cad-suite}"
nextpnr="${NEXTPNR_HIMBAECHEL:-$HOME/tools/nextpnr-mathieufro/nextpnr-himbaechel}"
apycula="${APICULA_FORK:-$(dirname "$root")/apicula-mathieufro}"
pydeps="${PYDEPS:-$HOME/tools/pydeps}"
device=GW5AST-LV138PG484AC1/I0
family=GW5AST-138C

[[ -f "$suite/environment" ]] || { echo "missing open toolchain: $suite" >&2; exit 2; }
# shellcheck disable=SC1090
source "$suite/environment"
export PYTHONHOME="$suite"
export PYTHONPATH="$apycula:$pydeps:${PYTHONPATH:-}"

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
    read_verilog -sv $src/ahb_boot_rom.sv $src/ahb_ram.sv $src/exts_uart.sv $src/ae350_soc.sv
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
    ${TINY_NES_SEED:+--seed "$TINY_NES_SEED"} \
    >"$out/nextpnr.log" 2>&1 || {
        tail -80 "$out/nextpnr.log" >&2
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
PY
"$suite/py3bin/python3" -m apycula.gowin_pack \
    -d "$family" \
    -o "$out/ae350_soc.fs" \
    "$out/ae350_soc-routed.json" \
    >"$out/pack.log" 2>&1 || {
        tail -80 "$out/pack.log" >&2
        exit 1
    }

sha256sum "$out/ae350_soc.fs"
echo "Ready to SRAM load: $out/ae350_soc.fs"
