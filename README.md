# TinyNES

TinyNES is an open-source NES project for the Tang Console 138K. Its planned
emulator runs on the FPGA's hard AE350 RISC-V CPU. FPGA logic will handle board
I/O and the memory and display paths. The emulator candidate is the
[Nestopia libretro core](https://github.com/libretro/nestopia); it is not part
of this repository yet.

## First hardware gate: AE350 UART

The first image proves only that an AE350 program starts and that every
address and data bit of its AHB writes reaches the fabric intact. The program
stores `0xa5a5a5a5`, `0x5a5a5a5a`, `0xffffffff`, `0` and then a walking one to
`0xe8000000`, 36 writes in all. The fabric decodes all 32 address bits and
compares each write with the expected pattern. When all 36 match it sends
`TinyNES AE350 OK` over the board's FPGA UART (U15) at 115200 8N1 about once per
second. The program is sixteen RV32I words in `fpga/ae350_uart/ae350_uart.sv`;
after the patterns it keeps storing its `mcycle` count to `0xe8000004` so the
core clock can be measured. The A25
core runs at 750 MHz from `PLL_R[0]` `CLKOUT1` and the AHB bus at 75 MHz from
`CLKOUT0`. It has no DDR3, NES emulator, video, audio, or BL616 dependency.

A write to any other address, a data mismatch, or an extra pattern write
instead sends `BAD N=nn A=aaaaaaaa D=dddddddd` for the first bad write: `N` is
the pattern index in hex (00-03 for the fixed words, then 04 + bit for the
walking one), `A` the write address and `D` the data received.

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

`-Pae350_uart_tb.FAULT=1` flips one data bit and `-Pae350_uart_tb.FAULT=2`
clears address bit 31 of one write; both runs expect the `BAD` line.

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
`ROM=1` once an active ROM transfer appears, and `AHB=1` once all 36
patterns arrive intact, or `AHB=E` after a bad write. Each field stays set once seen. The line then gives
the last `mcycle` value the CPU stored (`CYC`) and the count of the 50 MHz
board oscillator taken in the same bus cycle (`REF`), both in hex. The image is
`build/ae350_uart_trace/ae350_uart.fs`. To measure the core clock from four
consecutive pairs:

```sh
python3 tools/check_ae350_uart.py --expect 'ADDR=1 ROM=1 AHB=1' --clock 4 --timeout 10
```

The 75 MHz bus clock enters the global clock network from `PLL_R[0]`
`CLKOUT0`, and the build fails unless the core clock takes the dedicated
`AE350_CORE_CLK_PLLR0` hop and the bus meets 75 MHz. `TINY_NES_SEED=N` passes
a placement seed to nextpnr.

The load is volatile. The host check needs Python `pyserial`. It does not
alter BL616 firmware or the FPGA's configuration flash.

## AE350 system: boot ROM, RAM and C firmware

`fpga/ae350_soc/` gives the A25 a small system to run C code in:

| AHB port | Address | What the fabric puts there |
|---|---|---|
| ROM | `0x80000000` | 32 KiB block-RAM boot ROM (`ahb_boot_rom.sv`) holding the firmware image |
| RAM (64-bit) | `0x40000000` | 64 KiB block RAM (`ahb_ram.sv`); a data access to any other address on this port gets an AHB ERROR, and an instruction fetch reads zero |
| EXTS (uncached) | `0xe8000000` | UART data `+0x00`, UART status `+0x04`, ID `0x544e3031` ("TN01") `+0x08`, scratch `+0x0c` (`exts_uart.sv`) |

The clocks are the same as in the UART gate: the core runs at 750 MHz and the
buses at 75 MHz. The UART is the same FPGA UART at 115200 8N1.

The A25 fetches instructions down mispredicted paths, and some of those
fetches go to address 0, which lands on the RAM port. With both caches on, a
line fill that gets ERROR there stops the core for good. So the RAM port
answers an instruction fetch outside its window with zero and OKAY; zero is
an illegal instruction, so a fetch that is really executed still traps.

`firmware/boot/` is the boot program, in C with a short assembly start-up.
It checks the EXTS registers. Then it tests the RAM with the A25 caches off
and again with them on; the cached pass writes back and invalidates the
D-cache, so the data crosses the bus as cache-line bursts. After that it
reports once a second:

```text
TinyNES AE350 boot ROM
TinyNES AE350 C OK UNC=<cycles> CAC=<cycles>
```

`UNC` and `CAC` are the core cycles each RAM test took, in hex. On the board
they are `UNC=03bc52c0 CAC=001e33e1`: the cached test is about 32 times
faster. A failed check
or a trap prints a line starting with `BAD`. If the CPU has written nothing to
the UART about 1.8 s after reset, the fabric reports instead, once a second
until the CPU writes:

```text
NOBOOT ROM=<count> LAST=<address> RAM=<count> EXT=<count> RAML=<address> ST=<state> S1=<address> SL=<address>
```

The counts are the transfers each port has accepted. `LAST` and `RAML` are
the addresses of the last ROM and RAM transfers. `S1` and `SL` are the
addresses of the first and last stray RAM transfers, those outside the RAM
window. `ST` holds, from the top byte down:

- the last stray transfer's `HPROT[0]` (0 for an instruction fetch),
  `HBURST`, `HWRITE` and `HSIZE`;
- the live `HREADY` of the ROM and RAM ports, the RAM port's `HRESP` and the
  EXTS `HREADY`, then the live RAM and ROM `HTRANS`;
- in the low 16 bits, the number of stray RAM transfers.

Two diagnostic builds force the report. `TINY_NES_SOC_DIAG=1` holds the A25
in reset (`build/ae350_soc_hold/`), which checks the fabric alone.
`TINY_NES_SOC_DIAG=2` lets the A25 run but drops its UART bytes
(`build/ae350_soc_drop/`), so the report shows how far the firmware got:

```sh
TINY_NES_SOC_DIAG=2 bash tools/build_ae350_soc.sh
openFPGALoader -b tangmega138k build/ae350_soc_drop/ae350_soc.fs
```

The firmware is built with xPack GNU RISC-V Embedded GCC 15.2.0-1. The
Makefile looks in `~/tools/xpack-riscv-none-elf-gcc-15.2.0-1`; set `RISCV_BIN`
or `CROSS` to use another installation. It links only `libgcc`, with no C
library. The build script compiles the firmware into
`build/firmware/boot/boot.hex`, which Yosys loads into the ROM, then builds
the bitstream `build/ae350_soc/ae350_soc.fs`:

```sh
bash tools/build_ae350_soc.sh
```

The testbench drives each AHB port directly. `TEST=0` covers the ROM, the RAM's
byte lanes, ERROR responses and zero-reading fetches, the EXTS registers and
the CPU UART. `TEST=1`
covers the `NOBOOT` report and the CPU taking the UART over:

```sh
mkdir -p build/ae350_soc_tb
for t in 0 1; do
  iverilog -g2012 -s ae350_soc_tb -Pae350_soc_tb.TEST=$t \
    -o build/ae350_soc_tb/tb$t \
    ~/oss-cad-suite/share/yosys/gowin/cells_xtra_gw5a.v \
    fpga/ae350_soc/*.sv tests/ae350_soc_tb.sv
  vvp build/ae350_soc_tb/tb$t
done
```

On hardware, load it the same way as the UART gate. The checker fails on
`BAD`, `NOBOOT` or `AHB=E` lines and prints the line that passed:

```sh
source ~/oss-cad-suite/environment
openFPGALoader -b tangmega138k build/ae350_soc/ae350_soc.fs
python3 tools/check_ae350_uart.py --port /dev/ttyUSB1 --expect 'TinyNES AE350 C OK'
```

## Build sweeps

`tools/sweep.py` builds design variants over many nextpnr seeds in parallel
and tabulates them. It never loads the board. A design is described by a JSON
file in `tools/designs/`: sources, top, constraints, device, target frequency,
named variants as parameter overrides, and optional `prebuild` commands such
as the firmware build. Each variant is synthesised once, then placed and
routed once per seed:

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
