# TinyNES

TinyNES is an open-source NES project for the Tang Console 138K. Its planned
emulator runs on the FPGA's hard AE350 RISC-V CPU. FPGA logic will handle board
I/O and the memory and display paths. The emulator candidate is the
[Nestopia libretro core](https://github.com/libretro/nestopia); it is not part
of this repository yet.

## First hardware gate: AE350 UART

The first image proves only that an AE350 program starts, reaches the fabric
AHB bus, and sets a status word. The fabric then sends `TinyNES AE350 OK` over
the board's FPGA UART (U15) at 115200 8N1 about once per second. The program is
six RV32I words in `fpga/ae350_uart/ae350_uart.sv`; after the status write it
keeps storing its `mcycle` count so the core clock can be measured. The A25
core runs at 750 MHz from `PLL_R[0]` `CLKOUT1` and the AHB bus at 75 MHz from
`CLKOUT0`. It has no DDR3, NES emulator, video, audio, or BL616 dependency.

The status check uses write-data bit 4 and the AHB select signal rather than a
full address and data decode.

The build uses Yosys, a GW5AST-138C-capable nextpnr-himbaechel, and Apicula's
open-source bitstream packer. It does not invoke Gowin EDA or use generated
vendor IP. The available GW5AST-138C device database was generated from vendor
device data; this remains a provenance limitation of the current open flow.

```sh
bash tools/build_ae350_uart.sh
iverilog -g2012 -s ae350_uart_tb -o build/ae350_uart/uart_tb \
  ~/oss-cad-suite/share/yosys/gowin/cells_xtra_gw5a.v \
  fpga/ae350_uart/ae350_uart.sv tests/ae350_uart_tb.sv
vvp build/ae350_uart/uart_tb
```

If the hardware report is silent, build the isolated UART diagnostic. It sends
`UART DIAGNOSTIC!` from fabric logic after PLL lock without waiting for an AE350
write. A received diagnostic line therefore narrows the fault to the CPU or
its AHB path; silence still needs a check of the clock, output pin, and host
connection.

```sh
TINY_NES_UART_DIAG=1 bash tools/build_ae350_uart.sh
iverilog -g2012 -s ae350_uart_tb -Pae350_uart_tb.FORCE_UART=1 \
  -o build/ae350_uart_diag/uart_tb \
  ~/oss-cad-suite/share/yosys/gowin/cells_xtra_gw5a.v \
  fpga/ae350_uart/ae350_uart.sv tests/ae350_uart_tb.sv
vvp build/ae350_uart_diag/uart_tb
```

The script defaults to the locally installed oss-cad-suite, nextpnr and Apicula
fork. Override `OSS_CAD_SUITE`, `NEXTPNR_HIMBAECHEL`, `APICULA_FORK` or `PYDEPS`
if they are elsewhere. The output is `build/ae350_uart/ae350_uart.fs`.

For a hardware check, cold boot the board in one-wire debug mode, then SRAM
load the image with the open-source loader and read the FT2232 UART:

```sh
source ~/oss-cad-suite/environment
openFPGALoader -b tangmega138k build/ae350_uart/ae350_uart.fs
python3 tools/check_ae350_uart.py --port /dev/ttyUSB1
```

For the isolated diagnostic, load `build/ae350_uart_diag/ae350_uart.fs` and
probe with:

```sh
python3 tools/check_ae350_uart.py --port /dev/ttyUSB1 --expect 'UART DIAGNOSTIC!'
```

If the isolated UART works but the normal image is silent, build the AE350
trace image with `TINY_NES_UART_DIAG=2 bash tools/build_ae350_uart.sh`. It
reports `ADDR=1` once the reset-vector address appears on the ROM bus,
`ROM=1` once an active ROM transfer appears, and `AHB=1` once the expected
status write is captured. Each field stays set once seen. The line then gives
the last `mcycle` value the CPU stored (`CYC`) and the count of the 50 MHz
board oscillator taken in the same bus cycle (`REF`), both in hex. The image is
`build/ae350_uart_trace/ae350_uart.fs`. To measure the core clock from four
consecutive pairs:

```sh
python3 tools/check_ae350_uart.py --expect 'ADDR=1 ROM=1 AHB=1' --clock 4 --timeout 10
```

The AE350 bus clocks currently reach the hard core through general fabric
routing, so a placement can fail nextpnr's hold check or run silent on
hardware. `TINY_NES_SEED=N` passes a placement seed to nextpnr.

The load is volatile. The host check needs Python `pyserial`. It does not
alter BL616 firmware or the FPGA's configuration flash.

## Build sweeps

`tools/sweep.py` builds design variants over many nextpnr seeds in parallel
and tabulates them. It never loads the board. A design is described by a JSON
file in `tools/designs/` (sources, top, constraints, device, target frequency
and named variants as parameter overrides). Each variant is synthesised once,
then placed and routed once per seed:

```sh
python3 tools/sweep.py ae350_uart --variants normal,trace --seeds 1-16 --jobs 16 --pack clean
```

Each run records its nextpnr status and first error, Fmax per clock, hold
violations, used resources, placement wirelength, the number of sinks each
net failed to reach on dedicated clock routing, each clock net's route length
in pips, and run time and peak memory. `--pack clean` or `--pack all` also
packs bitstreams and records their SHA-256; packs run `--pack-jobs` at a time
(default 4) because each holds about 1.7 GB. `--nextpnr-arg` passes extra
nextpnr options. Results go to `build/sweep/<design>-<time>/` as
`results.csv`, `results.json` and `summary.txt`, with every run's logs.

## References and licensing

The board pin and AE350 clock facts come from the project reference library
and the Tang-PSX/Tang-Phosphor hardware reports cited there. The RTL here is
original MIT-licensed code. CERN's colibri and its SystemVerilog port are
design practice references; their modules are not included. Nestopia carries
GPL-2.0-or-later terms and will receive its own attribution when incorporated.
