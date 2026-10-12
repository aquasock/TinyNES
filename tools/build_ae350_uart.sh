#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
src="$root/fpga/ae350_uart"
diag="${TINY_NES_UART_DIAG:-0}"
if [[ "$diag" == 1 ]]; then
    out="${TINY_NES_BUILD_DIR:-$root/build/ae350_uart_diag}"
    synth_param="chparam -set FORCE_UART 1 ae350_uart"
elif [[ "$diag" == 2 ]]; then
    out="${TINY_NES_BUILD_DIR:-$root/build/ae350_uart_trace}"
    synth_param="chparam -set FORCE_UART 2 ae350_uart"
elif [[ "$diag" == 0 ]]; then
    out="${TINY_NES_BUILD_DIR:-$root/build/ae350_uart}"
    synth_param=""
else
    echo "TINY_NES_UART_DIAG must be 0, 1, or 2" >&2
    exit 2
fi
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

echo "Yosys synthesis"
yosys -Q -T -q -l "$out/synth.log" -p "
    read_verilog -lib $suite/share/yosys/gowin/cells_xtra_gw5a.v
    read_verilog -sv $src/ae350_uart.sv
    $synth_param
    synth_gowin -family gw5a -top ae350_uart
    write_json $out/ae350_uart.json
"

echo "nextpnr placement and routing"
"$nextpnr" \
    --json "$out/ae350_uart.json" \
    --write "$out/ae350_uart-routed.json" \
    --device "$device" \
    --freq 75 \
    --vopt cst="$src/ae350_uart.cst" \
    --sdc "$src/ae350_uart.sdc" \
    --report "$out/timing.json" \
    ${TINY_NES_SEED:+--seed "$TINY_NES_SEED"} \
    >"$out/nextpnr.log" 2>&1 || {
        tail -80 "$out/nextpnr.log" >&2
        exit 1
    }

echo "Apicula bitstream packing"
"$suite/py3bin/python3" - "$out" "$diag" <<'PY'
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
design = json.loads((out / "ae350_uart-routed.json").read_text())
if sys.argv[2] != "1":
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
    -o "$out/ae350_uart.fs" \
    "$out/ae350_uart-routed.json" \
    >"$out/pack.log" 2>&1 || {
        tail -80 "$out/pack.log" >&2
        exit 1
    }

sha256sum "$out/ae350_uart.fs"
echo "Ready to SRAM load: $out/ae350_uart.fs"
