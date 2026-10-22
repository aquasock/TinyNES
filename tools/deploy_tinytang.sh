#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Two-wire deploy: put the AE350 SoC image on TinyTang's SD card and load it
# into the FPGA with the BL616's own JTAG programmer, and put the NES player
# (nes_bench's PLAY=1 build, without its debug sections) beside it, so the
# TinyNES app's Library tab can start a cartridge (TinyTang's tang_core_load
# and tang_ae350_run). Uses
# TinyTang's host tools, which ask the console whether it is at a shell
# prompt before sending.
#
#   tools/deploy_tinytang.sh [image.bin]
#
# The desk layer is left as it is: ae350run and fpgapipe hold the UART while
# they talk to the AE350, and the boot ROM's loader hunts for its magic past
# any display frames the layer sent between them.
# Programs are then loaded with tools/load_ae350.py --tinytang.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tinytang="${TINYTANG_DIR:-$(dirname "$root")/TinyTang}"
port="${TINYTANG_PORT:-/dev/ttyACM0}"
image="${1:-$root/build/ae350_soc/ae350_soc.bin}"
remote="${TINYNES_REMOTE:-/root/cores/console138k/tinynes.bin}"
player="$root/build/firmware/apps/nes_play/nes_bench.elf"
player_remote=/root/ae350/tinynes-play.elf
strip="${RISCV_BIN:-$HOME/tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin}/riscv-none-elf-strip"

[[ -f "$image" ]] || { echo "missing image: $image (run tools/build_ae350_soc.sh)" >&2; exit 2; }
[[ -f "$tinytang/tools/tinytang_put.py" ]] ||
    { echo "missing TinyTang tools in $tinytang (set TINYTANG_DIR)" >&2; exit 2; }

[[ -f "$player" ]] || { echo "missing player: $player (make -C firmware/apps/nes_bench PLAY=1)" >&2; exit 2; }
stripped="$root/build/firmware/apps/nes_play/tinynes-play.elf"
"$strip" --strip-debug -o "$stripped" "$player"

sha256sum "$image" "$stripped"
python3 "$tinytang/tools/tinytang_run.py" --port "$port" --seconds 1 \
    "echo tinynes: console ready"
python3 "$tinytang/tools/tinytang_put.py" --port "$port" "$image" "$remote"
python3 "$tinytang/tools/tinytang_put.py" --port "$port" "$stripped" "$player_remote"
# Nothing else is installed: a cartridge starts from the TinyNES app's Library
# tab, which loads and runs in-process. An older card still holding
# /root/scripts/open/nes.tdsh is inert, because no firmware reads that folder
# any more.
# The last command is sent only once the prompt is back, so the script ends
# after tangload has.
python3 "$tinytang/tools/tinytang_run.py" --port "$port" --wait 120 --seconds 1 \
    "tangload $remote" "echo tinynes: deployed $remote"
