#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Two-wire deploy: put the AE350 SoC image on TinyTang's SD card and load it
# into the FPGA with the BL616's own JTAG programmer. Uses TinyTang's host
# tools, which ask the console whether it is at a shell prompt before sending.
#
#   tools/deploy_tinytang.sh [image.bin]
#
# The desk layer is turned off first: its mirror sends display frames to
# whatever core is loaded, and the AE350's UART would receive them.
# Programs are then loaded with tools/load_ae350.py --tinytang.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tinytang="${TINYTANG_DIR:-$(dirname "$root")/TinyTang}"
port="${TINYTANG_PORT:-/dev/ttyACM0}"
image="${1:-$root/build/ae350_soc/ae350_soc.bin}"
remote="${TINYNES_REMOTE:-/cores/console138k/tinynes.bin}"

[[ -f "$image" ]] || { echo "missing image: $image (run tools/build_ae350_soc.sh)" >&2; exit 2; }
[[ -f "$tinytang/tools/tinytang_put.py" ]] ||
    { echo "missing TinyTang tools in $tinytang (set TINYTANG_DIR)" >&2; exit 2; }

sha256sum "$image"
python3 "$tinytang/tools/tinytang_put.py" --port "$port" "$image" "$remote"
# The last command is sent only once the prompt is back, so the script ends
# after tangload has.
python3 "$tinytang/tools/tinytang_run.py" --port "$port" --wait 120 --seconds 1 \
    "osd desk off" "tangload $remote" "echo tinynes: deployed $remote"
