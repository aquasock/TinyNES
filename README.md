# TinyNES

TinyNES is an open-source NES project for the Tang Console 138K. Its planned
emulator runs on the FPGA's hard AE350 RISC-V CPU. FPGA logic will handle board
I/O and the memory and display paths. The emulator is the libretro
[FCEUmm](https://github.com/libretro/libretro-fceumm) core, fetched at a
pinned commit for a headless benchmark; its source is not part of this
repository. libretro [Nestopia](https://github.com/libretro/nestopia) was
measured the same way and dropped as the slower of the two on the A25.

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
| RAM (64-bit) | `0x60000000` | 64 KiB block RAM (`ahb_ram.sv`) holding the firmware's data and stack |
| RAM (64-bit) | `0x40000000` | 32 MiB SDRAM on the dock's J9 module (`ahb_sdram.sv`), its top 128 KiB the video frame buffers; a data access to any address on this port outside the two RAMs gets an AHB ERROR, and an instruction fetch reads zero |
| EXTS (uncached) | `0xe8000000` | UART data `+0x00`, UART status `+0x04`, ID `0x544e3031` ("TN01") `+0x08`, scratch `+0x0c`, UART receive `+0x10`, UART mode `+0x14`, link status `+0x18` (`exts_uart.sv`, `desk_link.sv`); HDMI video from `+0x10000` (`video.sv`, below) |

The clocks are the same as in the UART gate: the core runs at 750 MHz and the
buses at 75 MHz. The UART is the same FPGA UART, transmitting on U15 and
receiving on V14, but at 2,000,000 baud 8N1; in one-wire mode it is
`/dev/ttyUSB1`. The receiver samples each bit at its centre, 37 or 38 bus
clocks apart, and keeps up to 512 received bytes in a block RAM buffer.
Reading `+0x10` takes the oldest byte, returned as `0x100` plus the byte, or
0 when the buffer is empty. The status register's bits are:

| Bit | Meaning |
|---|---|
| 0 | The transmitter can take a byte |
| 1 | The transmitter is idle: the last byte has left the pin, and in link mode no text is waiting |
| 2 | A received byte is waiting |
| 3 | A byte arrived to a full buffer and was lost; stays set until 1 is written to it |
| 4 | A byte had no stop bit; stays set until 1 is written to it |

Both RAMs are cacheable. The SDRAM is the module Sipeed fits to the Tang
Console 138K: two Winbond W9825G6KH-6 on J9, driven as one 32 MiB x16 device
on its single chip select (J10 is left empty). The controller runs on the
75 MHz bus clock at CAS latency 3, with the SDRAM clock an inverted copy from
an `ODDR`. It keeps one 32-byte line in a read buffer, filled critical word
first, merges posted writes into it, and opens and closes a row for each
access.

The A25 fetches instructions down mispredicted paths, and some of those
fetches go to address 0, which lands on the RAM port. With both caches on, a
line fill that gets ERROR there stops the core for good. So the RAM port
answers an instruction fetch outside both RAMs with zero and OKAY; zero is
an illegal instruction, so a fetch that is really executed still traps.

`firmware/boot/` is the boot program, in C with a short assembly start-up.
It checks the EXTS registers. Then it tests the block RAM and the SDRAM with
the A25 caches off and again with them on; each cached pass writes back and
invalidates the D-cache, so the data crosses the bus as cache-line bursts.
The SDRAM tests here are quick: byte and halfword lanes, cached and not, and
every address line. The full SDRAM test is a loaded program (below). Then it
waits for a program on the UART, reporting once a second:

```text
TinyNES AE350 boot ROM
TinyNES AE350 C OK UNC=<cycles> CAC=<cycles>
TinyNES SDRAM OK 32M
TinyNES LOAD
```

`UNC` and `CAC` are the core cycles each block RAM test took, in hex. On the
board they are `UNC=0491d418 CAC=001f696a`: the cached test is about 37
times faster. A failed check or a trap prints a line starting with `BAD`, and
the ROM then loads nothing. If the CPU has written nothing to
the UART about 1.8 s after reset, the fabric reports instead, once a second
until the CPU writes:

```text
NOBOOT ROM=<count> LAST=<address> RAM=<count> EXT=<count> RAML=<address> ST=<state> S1=<address> SL=<address>
```

The counts are the transfers each port has accepted. `LAST` and `RAML` are
the addresses of the last ROM and RAM transfers. `S1` and `SL` are the
addresses of the first and last stray RAM transfers, those outside both
RAMs. `ST` holds, from the top byte down:

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
Makefiles look in `~/tools/xpack-riscv-none-elf-gcc-15.2.0-1`; set `RISCV_BIN`
or `CROSS` to use another installation. The boot ROM links only `libgcc`,
with no C library. The build script compiles it into
`build/firmware/boot/boot.hex`, which Yosys loads into the ROM, then builds
the bitstream `build/ae350_soc/ae350_soc.fs` for one-wire SRAM loads, and
packs it with `tools/fs_to_bin.py` into `build/ae350_soc/ae350_soc.bin`, the
same bits eight to a byte, which TinyTang's `tangload` loads from the SD card
in two-wire mode:

```sh
bash tools/build_ae350_soc.sh
```

The SoC build uses nextpnr seed 1 by default, the placement the board runs:
with the pad's first bus on USB-A, all 8 seeds were clean in a sweep with the
pixel clock routed first, and seed 1, at 87.17 MHz on the bus and 85.46 MHz
on the pixel clock against 75 and 74.25, with the pixel clock on
SPINE16+SPINE25, has the best margin on both clocks together and is the
image that was tested on the board. The default has
to stay the tested seed, because `tools/deploy_tinytang.sh` takes this build's
image unless given another. Set `TINY_NES_SEED=N` to evaluate another
placement.

The build needs the forks of nextpnr and Apicula on their `epic/gw5ast138c`
branches, which add a timing model for the AE350's AHB ports, measured from
the vendor's timing reports, so the bus paths into and out of the A25 are
timed. The A25's bus dies when its clock reaches it through global clock
branch `GB20`, and works through `GB10`; the cause is not yet known. Until it
is, the script sets `NPNR_GOWIN_CLK_FIRST=bus_clk`, a temporary knob in the
nextpnr fork that routes the bus clock first so that it takes `GB10`, and
fails if nextpnr did not apply it. A sweep of `ae350_soc` (below) needs the
same variable set. The Apicula fork must be at `cd3893f` or later, which
keeps the HDMI pixel clock off clock-bridge paths that clock nothing on this
chip (reference record DEV-017); the script fails unless the pixel clock
reaches the clock spines through a bridge path measured to work — SPINE26
alone, or SPINE16+SPINE25, which the HDMI transmitter image uses — and unless
every video block RAM is written and read on one clock.

The HDMI transmitter under `fpga/hdmi/` is hdl-util's
(https://github.com/hdl-util/hdmi, MIT, Copyright (c) 2019 Sameer Puri),
vendored whole with its licence in `fpga/hdmi/LICENSE-MIT`; `video.sv` is now
only the pixel source that drives it. The transmitter carries the same audio
the Pmod I2S2 gets: `i2s_out` flips a toggle once per frame and holds that
frame's pair, the pixel side latches the pair when it sees the flip and raises
the transmitter's `clk_audio` for one pixel clock, and the clock regeneration
packet measures CTS against the pixel clock so it declares the true frame rate,
75 MHz / 1536 = 48,828.125 Hz, with no table for it. The first two attempts
failed on that handoff rather than on the packets: a free-running 48 kHz clock
from the bus domain carried nothing, and sampling the FIFO's pop-cycle value at
a frame boundary handed over zeros.

The testbench drives each AHB port directly. `TEST=0` covers the ROM, the RAM's
byte lanes, ERROR responses and zero-reading fetches, the EXTS registers, the
CPU UART, the UART receiver (byte order, senders 5% fast and slow, glitches,
missing stop bits, overrun and the status bits), and the SDRAM controller
against `tests/sdram_model.sv`, a W9825G6KH-6 model that checks command
order and timing, that video transfers reach the video unit beside the UART
registers, and that the video unit fetches frame-buffer lines through the
SDRAM controller while the RAM port reads the SDRAM. `TEST=1` covers the `NOBOOT` report and the CPU taking the
UART over:

```sh
mkdir -p build/ae350_soc_tb
for t in 0 1; do
  iverilog -g2012 -s ae350_soc_tb -Pae350_soc_tb.TEST=$t \
    -o build/ae350_soc_tb/tb$t \
    ~/oss-cad-suite/share/yosys/gowin/cells_xtra_gw5a.v \
    fpga/ae350_soc/*.sv tests/sdram_model.sv tests/ae350_soc_tb.sv
  vvp build/ae350_soc_tb/tb$t
done
```

On hardware, load it the same way as the UART gate. The checker fails on
`BAD`, `NOBOOT` or `AHB=E` lines and prints the line that passed:

```sh
source ~/oss-cad-suite/environment
openFPGALoader -b tangmega138k build/ae350_soc/ae350_soc.fs
python3 tools/check_ae350_uart.py --port /dev/ttyUSB1 --baud 2000000 --expect 'TinyNES LOAD'
```

### Loading and running programs

Programs run from the SDRAM. `tools/load_ae350.py` takes an ELF file, sends
its loadable segments to the boot ROM as one image, then shows the program's
output until it exits:

```sh
python3 tools/load_ae350.py build/firmware/apps/rt_test/rt_test.elf \
  --expect 'TinyNES RT OK' --expect 'TinyNES SDRAM OK'
```

It fails on a `BAD` or `NOBOOT` line, a non-zero exit, or a missing
`--expect` line, and prints `PASS` otherwise. `--port`, `--baud`,
`--timeout`, `--run-timeout` and `--retries` change its defaults;
`--run-timeout 0` follows the program until it exits or Ctrl-C.

In two-wire mode the BL616 runs TinyTang and holds the FPGA UART, so both
the image and the programs go through it. `tools/deploy_tinytang.sh` puts
`build/ae350_soc/ae350_soc.bin` on the SD card as
`/root/cores/console138k/tinynes.bin` with TinyTang's `tinytang_put.py` and loads
it with `tangload`, and also installs the NES player (see *Playing from the
desktop*). It leaves the
desk layer as it is: whatever talks to the AE350 holds the UART meanwhile, and
the boot ROM's loader skips any display frames the layer sent in between.
`load_ae350.py --tinytang` then uses
TinyTang's USB console, `/dev/ttyACM0`: it checks the shell is at a prompt
with the console status probe and runs TinyTang's `fpgapipe`, which passes
the console's bytes to the FPGA UART and back unchanged until the tool
closes the port. The load protocol is the same as in one-wire mode. TinyTang
must be checked out beside this repository, or named with `TINYTANG_DIR`:

```sh
tools/deploy_tinytang.sh
python3 tools/load_ae350.py --tinytang build/firmware/apps/rt_test/rt_test.elf \
  --expect 'TinyNES RT OK' --expect 'TinyNES SDRAM OK'
```

The protocol, defined in `firmware/include/tinynes.h` and implemented in
`firmware/boot/load.c`, is little-endian:

- The host sends a 24-byte header: the magic `TNL1` (`0x314c4e54`), the load
  address, the length, the entry address, the image's CRC-32 and the
  header's own CRC-32.
- Then the image in 8 KiB blocks, the last one shorter if need be, each
  followed by its CRC-32.
- The ROM answers the header and each block with ACK (`0x06`), or with NAK
  (`0x15`) and a reason letter: `T` a byte took over 100 ms, `H` header CRC,
  `A` the image is not inside the SDRAM, `C` block CRC, `O` the receive
  buffer overflowed, `I` the image read back from the SDRAM after writing
  back the D-cache does not match. A NAKed block is sent again, up to five
  times. A NAKed header or image ends the load: the ROM goes back to
  waiting, and `load_ae350.py` reports the failure.
- After the final ACK the ROM prints `TinyNES RUN <entry>`, waits until that
  line has been sent, runs `fence.i` and jumps to the entry with both caches
  on. If no block arrives for 2 s the ROM gives up and reports again.

On the board the 138,072-byte `rt_test` image loads in 0.76 s, 182 KB/s.

### Runtime

`firmware/rt/` lets programs use C and C++ with newlib and libstdc++,
including exceptions, RTTI and static constructors. A program's Makefile
names its sources and includes `rt.mk`:

```make
APP     := rt_test
SOURCES := main.cpp ../../common/memtest.c

include ../../rt/rt.mk
```

`make -C firmware/apps/<name>` builds `build/firmware/apps/<name>/<name>.elf`.
The program occupies the bottom of the SDRAM. The heap runs from its end to
the start of the video frame buffers, 128 KiB below the top of the SDRAM, and
the stack is the top of the 64 KiB block RAM.
`stdout` and `stderr` go to the UART, with `\n` sent as `\r\n`.
Returning from `main` or calling `exit` prints `TinyNES EXIT <code>`, and a
trap prints `BAD TRAP C=<mcause> P=<mepc> V=<mtval>`. Either way the program
writes back the D-cache and restarts the boot ROM, which tests the memory
again and waits for the next program.

`firmware/apps/rt_test/` checks the runtime and finishes the SDRAM testing:

```text
TinyNES RT OK MISA=<misa> HEAP=<KiB>K
TinyNES SDRAM OK <KiB>K MISS=<cycles> RD=<KB/s> WR=<KB/s> FULL=<ms>
```

`MISA` is the A25's `misa` register: `4094312d` on the board, an RV32 core
with I, M, A, F, D and C, and so with a double-precision FPU, plus N, S, U
and X. `HEAP` is the largest block `malloc` gives; on the board it is
32,576 KiB. The SDRAM line tests that block with a pattern and its inverse,
caches on. `MISS` is the core cycles per cache line read from the SDRAM,
`RD` and `WR` the rates reading and writing 1 MiB with the caches on, and
`FULL` the time the pattern test took. On the board they are
`MISS=370 RD=61604 WR=34071 FULL=2989`.

The programs are compiled for `rv32imac` with soft float, matching the
compiler's default libraries; the FPU is not used yet.

There are no files or directories: `open`, `stat` and `opendir` fail with
`ENOENT`. `firmware/rt/include/sys/dirent.h` stands in for newlib's, which
refuses to build, so that `<dirent.h>` compiles. A program can also build third-party
code with its own flags: `LIB_SOURCES` are compiled with `ARCHFLAGS`, `OPT`
(`-O2` unless `make OPT=<flags>` replaces it, as it does for all code),
`LIB_CPPFLAGS` and `LIB_CFLAGS` or `LIB_CXXFLAGS` instead of the TinyNES
warning and language flags, and `EXTRA_OBJECTS` are linked in.

`tests/test_loader_host.py` runs the ROM's real `load.c` on the PC against
`tools/load_ae350.py`, through a pseudo-terminal, with a 32 MiB buffer mapped
at `0x40000000`. It checks a clean load byte for byte, and that dropped,
corrupted and overflowed bytes, bad headers, addresses outside the SDRAM, an
image that reads back wrong, and a sender that stops are each handled. It
needs `gcc` and `pyserial`, and `rt_test` built first:

```sh
make -C firmware/apps/rt_test
python3 -m unittest tests/test_loader_host.py
```

### NES emulator benchmark

`firmware/apps/nes_bench/` runs FCEUmm's NES emulation core on a cartridge
image built into the program, with a scripted controller, shows the game on
HDMI and times each emulated frame against the NES frame period.
`tools/fetch_fceumm.sh` clones commit
`ac0d00a7fc01166f84c7bac01d1084ebfd2b865e` into `third_party/`, which git
ignores, applies TinyNES's patches from `patches/fceumm/` (see *Accuracy
tests and the FCEUmm patches*), and checks that the tree is exactly that
commit with them. The Makefile includes the core's
own `Makefile.common` and builds it as upstream does for unix, but without
the NTSC filter, the HD texture packs and FCEUmm's libretro driver
(`src/drivers/libretro/libretro.c`): `main.cpp` takes the driver's place, so
the core's own 8-bit picture is shown as it is. The cartridge image is the
user's own and is never committed:

```sh
tools/fetch_fceumm.sh
make -C firmware/apps/nes_bench ROM=<file.nes>          # AE350 program
make -C firmware/apps/nes_bench ROM=<file.nes> host     # the same for the PC
python3 tools/load_ae350.py build/firmware/apps/nes_bench/nes_bench.elf --run-timeout 600
build/firmware/apps/nes_bench/host/nes_bench
```

`PLAY=1` builds the playable version into
`build/firmware/apps/nes_play/` (AE350 only). It has no cartridge built in:
it prints `TinyNES WANT <address> <bytes>` and takes one more image in the
load protocol at that address, `TNR1`, the cartridge's length and the `.nes`
file, received by the boot ROM's own `firmware/boot/load.c` compiled into it,
into a 2 MiB buffer. `load_ae350.py --file <rom>` answers it, as TinyTang's
`ae350run` does on the board. The file may also be a `.zip` holding one
`.nes`: `cart_zip.c` finds that entry through the zip's central directory,
inflates it with libretro-common's DEFLATE decoder, already in the fetched
FCEUmm tree under the MIT licence, checks the CRC-32 the zip stores, and
prints `TinyNES NES ZIP <name> <bytes>`, or `TinyNES NES BAD ZIP <why>` and
ends as for a bad cartridge. `tests/test_cart_zip.sh <folder>` runs the same
code on the PC over every `.zip` in a folder and compares each with the
`.nes` of the same name beside it. The Wii Classic Controllers on
buses 0 and 1, USB-A port 2 and PMOD0's second pair (see *Wii Classic
Controller inputs*), are players 1 and 2: the D-pad or the left stick
for the directions, B for the NES's A, Y for its B, `-` for Select and `+`
for Start; A and X do nothing. A controller that is absent or not a Classic reads as
nothing pressed. The game runs until HOME and `-` are held together, prints
`TinyNES NES PLAY PAD1=<state> PAD2=<state>` (`classic`, `other` or
`absent`) at the start and its `F=` lines once a minute, and ends with the
usual summary. The play build's sound plays on the I2S2 (see *I2S audio on
PMOD1*): FCEUmm runs at 48,909 Hz, the DAC's 48,828.125 Hz times the NES's
60.0988 frames a second over HDMI's 60, so each frame makes the samples one
HDMI frame plays, and a one-sample correction a frame holds the FIFO near
1,100 pairs. The summary adds an `AUDIO` line with underruns, dropped
samples, the FIFO level range, the corrections and the time to send a
frame's sound, and the program fails on any underrun or drop. HOME with L
and HOME with R save and load the game's save state (see *Save states*).

### Save states

A save state is FCEUmm's own (`src/state.c`): the CPU, its RAM, the PPU,
the APU, the controller ports and the cartridge's mapper and RAM in one
buffer, about 22 KB for Castlevania and Zelda and 14 KB for Kirby's
Adventure. There is one state per cartridge, as on the NES Classic: HOME
with L saves the game into the player's slot in the SDRAM and HOME with R
loads it, at once and only while the game has the controller; neither is a
tap of HOME, so TinyDesk stays where it is. On the A25 a save takes about
0.93 ms and a load 1.07 ms. A save also goes to the card in the background:
two `TinyNES STATE BEGIN` lines, `TinyNES STATE DATA <bytes> <crc32>`, then
the file as bytes, 256 a frame, about 1.5 s for 22 KB, with nothing else
printed until it has gone and a save made meanwhile sent after it. TinyTang
keeps it as `/root/states/nes/<cartridge>.state`, written as a `.part`, read
back and checked against the CRC-32 before it replaces the old one, so a
lost frame leaves the previous state in place. At launch the player asks
for that file (`TinyNES STATE WANT <address> <bytes>`) and takes it into the
slot without loading it, so R loads it in a later session, and the game
never resumes on its own; nothing is sent or loaded at exit. A state file is
a 32-byte header, `TNS1`, the CRC-32 of the `.nes` it was taken in, the first
32 bits of FCEUmm's commit, the patch series' checksum, the frame, the
state's length and its CRC-32, then FCEUmm's state; R refuses a state for
another cartridge or one that does not match its CRC (`TinyNES NES STATE LOAD
REFUSED <why>`), and a different core is reported as `CORE=OTHER` and loaded,
as FCEUmm loads states across its versions. The player prints `TinyNES NES
STATE SLOT=<bytes>`, `STATE READY F=<frame>` for a state taken from the card,
and `STATE SAVE OK`, `LOAD OK`, `LOAD EMPTY`, `STATE SENT` as they happen. The
TinyNES window's Saves page shows the state of the cartridge selected in the
Library: its file, size and CRC-32, the game's CRC-32 and frame, and the core;
there is no creation time while the board has no clock. A state can be
swapped by copying `.state` files in TinyDesk's Files app. The state holds
the cartridge's battery RAM, so a loaded state's RAM is what is written back
as the battery save at exit: the state wins.

`make ROM=<file.nes> STATE=<n>` builds the benchmark to save a state before
frame `n`, load it once the run ends and play the frames after it again with
the same script, reporting

```text
TinyNES NES STATE AT=<n> BYTES=<bytes> SAVE=<us> LOAD=<us>
    VIDEO=<run>/<replay> AUDIO=<run>/<replay> MATCH
```

and failing unless the replay's checksums are the run's own, the replay
loading only through the header check, which must first refuse the state
for another cartridge and with one byte changed. Castlevania,
Zelda and Kirby's Adventure match from frames 300, 900 and 1500 on the PC,
and Castlevania from 900 on the A25 with the PC's checksums.

After the cartridge and any battery save, the player prints `TinyNES SETTINGS
WANT <address> <bytes>` and takes its settings, headerless, straight into its
own `HostSettings`: player 1's and player 2's button mappings, eight bytes
each, then the pixel aspect (the video unit's `ASPECT` values) and the palette,
an index into the names `tools/gen_fceumm_palettes.py` lists. TinyTang's
`ae350run` answers it from `/nes.ini` (`[video] palette = <name>`), sending no
more bytes than were asked for, and a host that sends fewer leaves the
compiled-in defaults, which are `/nes.ini`'s own: so the two repositories can
be deployed in either order. The player prints `TinyNES NES PALETTE=<name>`
for the palette it used.

```sh
make -C firmware/apps/nes_bench PLAY=1
python3 tools/load_ae350.py --tinytang build/firmware/apps/nes_play/nes_bench.elf \
  --file <file.nes> --run-timeout 0
```

### Playing from the desktop

With no PC attached, a cartridge is started from TinyTang's **TinyNES**
window: its **Library** tab browses `/root/media/nes` and the folders under it,
lists the `.nes` and `.zip` cartridges, and starts the one chosen. No shell is
involved. The window loads `tinynes.bin`, runs TinyTang's `ae350run` on
`/root/ae350/tinynes-play.elf`, which sends the player and then the cartridge
from the card and follows the game to its end (HOME and `-`), and loads the
desktop core again. It does that in a task of its own, through the same
routines `tangload` and `ae350run` call, because a script started from the open
desktop could be refused its worker task or its line table and printed `not
enough memory to load the script` instead of starting a game. That is TinyTang
`d399c9b` and later. A launch takes about ten seconds: the core, the 625 KB
player at the link's 186 KB/s, and the cartridge. `tools/deploy_tinytang.sh`
installs the core image and the player without its debug sections (about
840 KB), and nothing else.

That window is the only way to start TinyNES. A cartridge double-clicked in
the Files app or on the desktop is neither launched nor opened as text: it
says where cartridges start, so a ROM cannot be opened in the Editor and saved
over. The desktop's `/root/scripts/open/<ext>.tdsh` handler mechanism went
with it, so there is no `nes.tdsh` and none is installed.

The same window's Input, Video and Saves tabs hold the settings it used to
keep in a second window. `ae350run` names the save after the file with its
extension replaced, so `Game.zip` and `Game.nes` share
`/root/saves/nes/Game.sav`.

### Accuracy tests and the FCEUmm patches

`tools/fetch_accuracycoin.sh` fetches 100th Coin's AccuracyCoin test cartridge
(MIT) at commit `6bee919529289c555803b612b8c9e4f7eaaeeabb`, and
`tools/accuracycoin.py` runs it on the PC build of `nes_bench`, the same core
and driver as the board. A scripted controller marks tests to skip, B on a
test or on a page's index, and presses Start on the index; the program then
writes the NES's work RAM at the end of the run (`NES_RAM_DUMP=<file>`, PC
only), and the script reads each test's result byte at `$0400`-`$04FF`, using
the cartridge's own source for the pages, the tests and their addresses. It
prints every test with its success or error code and a summary, and with
`--expect <file>` lists each change against a saved run and fails if a passing
test stops passing. Page 19's Misaligned OAM Behavior waits for a sprite zero
hit FCEUmm never produces and hangs the run, so it is skipped by default:

```sh
tools/fetch_accuracycoin.sh
python3 tools/accuracycoin.py [--skip 19.7] [--expect FILE] [--write FILE]
```

`tests/accuracycoin_expected.txt` is the run with the current series, which
each new patch is checked against with `--expect`.

The fixes are a patch series, `patches/fceumm/NNNN-*.patch`, applied in name
order by `tools/fetch_fceumm.sh`, which accepts the checkout only as the
pinned commit or that commit with exactly the series, and refuses anything
else rather than overwrite work not yet saved. `tools/fceumm_patch.sh <name>
"<subject>"` saves changes made in `third_party/fceumm` as the next patch. The
patches are GPL-2.0-or-later like the code they change
(`patches/fceumm/README.md`), and where one follows 100th Coin's TriCNES
emulator (MIT) its header says so. The first seven fix the SH* opcodes'
address on a page cross, palette reads' open-bus bits, the PPU open bus's
decay, sprite zero under the left mask, OAM writes and DMA at the OAM address,
the dummy-read address on a page cross, and the CPU data bus around writes,
`$4015` and the controller ports; `main.cpp` also turns FCEUmm's Four Score
off, as its libretro driver does. With them the harness's run goes from 83 to
90 of 146 passing, Castlevania, Zelda and Chip 'n Dale give the same checksums
as without them, and on the A25 the benchmark averaged 11.08 ms a frame
against 10.93 ms. The eighth is a speed fix: FCEUmm rebuilt a 256-entry
background palette table on every partial-line render, and a game polling
`$2002`, as Zelda II's title screen does about 1,900 times a frame, renders
once per read, so the intro took 17.45 ms a frame on the A25 against the
16.64 ms period and played slow with broken sound. Rebuilding the table only
when its 16 palette bytes change leaves every checksum as it was and brings
the intro to 9.95 ms and the Castlevania benchmark to 9.03 ms. The ninth is
a save-state fix: FCEUmm's state left out the DMC's fetched sample byte and
the sweep and envelope restart flags, so after a load Kirby's Adventure played
the right picture with wrong sound for up to 36 frames; with them saved,
`STATE=<n>` (see *Save states*) replays every frame exactly.

### Diagnosing the HDMI picture

`make -C firmware/apps/nes_bench PLAY=1 DIAG=1` builds the player into
`build/firmware/apps/nes_diag/` with checks of the video path that run while
the game is played. The A25's cycle counter and the pixel clock both come
from the 50 MHz oscillator, so every 1650x750 frame is exactly 12,500,000
core cycles; the player timestamps each vertical blank it sees while waiting
for a frame to be shown and checks the period. It also counts the non-zero
pixels and the bits seen 1 and 0 of each frame it hands over and compares
them with the video unit's `PIXELS` and `BITS` for that frame. Once a second
it prints a `TinyNES DIAG S=` line with the frames, vertical blanks, period
extremes, odd periods, matched and mismatched frames, late lines, missed
frames, the slowest frame, the sound FIFO's range, underruns, drops and the
link status, and at once a `MARK` line for each press of X on a controller
and a `START` line for each Start, so faults seen on the screen can be marked
in the log. Run it from the PC with the log kept:

```sh
python3 -u tools/load_ae350.py --tinytang build/firmware/apps/nes_diag/nes_bench.elf \
  --file "<cartridge.nes>" --run-timeout 0 | tee build/diag/session.log
```

`tools/hdmi_timing.py <routed.json> <design.sdf>` works out the HDMI output
stage that nextpnr does not time on this chip (no IOLOGIC model): the paths
from the TMDS encoder registers into the OSER10s, the serial and pixel
clocks' delays to them, the clock lane, and the pixel-clock pins off the
global network, at the build's speed grade and scaled to the fork's other
tables. It takes nextpnr's `--write` and `--sdf` outputs; a run with the
build script's arguments and seed reproduces the build's routing.
`tools/gowin_hdmi_timing.sh` builds the same RTL with Gowin EDA, headless,
as a measurement only, to read the vendor's slow- and fast-model timing of
that stage in `build/gowin_hdmi/impl/pnr/ae350_soc.tr`.

### TinyDesk over a running game

Once the player has its cartridge it prints `TinyNES LINK` and sets bit 0
of the UART mode register, link mode. The UART then speaks TinyTang's frame
protocol, `0xAA len_hi len_lo type payload` with the length counting the
type byte, so TinyTang's desk layer can draw TinyDesk over the game the way
it does over its patched nestang core. One tap of HOME on controller 1, or
F12 on a keyboard TinyTang reads, swaps the picture between the game and
TinyDesk; the game keeps running behind the desktop, with its sound, and
gets no controller input while the desktop is shown. TinyTang needs no
change for either toggle; its `ae350run` hands the UART back to the desk
layer when it sees `TinyNES LINK` and follows the program's text in frames
until `TinyNES EXIT`.

In link mode (`fpga/ae350_soc/desk_link.sv`) received bytes go to a frame
parser and never to the receive buffer, so a program image is never taken
for a frame and a frame never reaches the CPU. It answers the core ID
request `0x01` with `0x4e`, an ID TinyTang sends no PMOD declarations to,
and takes `0x08` (overlay, bit 0), `0x13 x y` (the layer's cursor), `0x14`
(cells from the cursor, 5 bytes each: the character's low 7 bits, then a
big-endian 15-bit `{b, g, r}` foreground and background) and `0x15` (the
layer's enable, bit 0); other types are skipped by their length. It sends,
a whole frame at a time:

| Frame | When | Payload |
|---|---|---|
| `0x01` | asked | `0x4e` |
| `0x03` | every 20 ms when it changes, and every 500 ms | controller 1 as TinyTang's pad word, then a zero word: D-pad up `0x010`, down `0x020`, left `0x040`, right `0x080`, the Classic's B as `0x100`, its Y as `0x001`, and LB `0x400` for 260 ms after a tap of HOME (pressed and released with nothing else pressed) |
| `0x20` | after a line feed, 128 bytes, or 2 ms without a byte | the CPU's text |

TinyTang flips its overlay on LB's rising edge and reads the newest report
about every 40 ms, so LB is held for 13 reports. While the desktop is shown
the same word moves its pointer and clicks. The CPU's bytes wait while a
frame of text is queued or sent. A write to the mode register completes
only once everything before it has been sent, including text still
buffered, which it sends at once, and the boot ROM writes 0 to it first
thing, so a program that exits in link mode leaves the ROM in loader mode
with its last line sent. The link status register at `+0x18` has bit 0 set
while the layer is shown (link, overlay and enable on), bits 1 and 2 the
overlay and the enable, bit 3 a lost cell write, and the frames received
and cells written in bits 15:8 and 31:16.

The layer (`video.sv`) is 80x45 cells of 16x16 pixels, each an 8x8 glyph
drawn twice its size, and replaces the whole 1280x720 picture, side bars
and colour bars included, from the vertical blank after it is turned on.
Cells are handed from the bus clock to the pixel clock like palette writes,
and the cell store and the font are block RAM on the pixel clock only. The
font is Daniel Hepper's public-domain font8x8 (`font8x8_basic.h`), which
`tools/fetch_font8x8.sh` fetches at commit `8e279d2` and
`tools/gen_desk_font.py` writes as `fpga/ae350_soc/desk_font.hex`; TinyTang
maps box-drawing characters to ASCII before sending them.

`tools/load_ae350.py` follows a program into link mode too, unwrapping its
text frames and dropping the joypad reports. `tests/desk_link_tb.sv` runs
the UART and the link together with an AHB master, a UART sender and a
receiver that reads the line as frames: loader mode untouched, the core ID,
cells from the cursor with those off the grid dropped, other frame types
and bad lengths skipped, the overlay and enable, the joypad word, a HOME tap
and HOME with `-`, text cut at line feeds, 128 bytes and quiet, and leaving
link mode with text buffered. Planted faults in the length byte, the
routing of received bytes, the mode write's wait, the busy status, the tap,
the cell packing, the cursor, the length check, the refresh and the quiet
flush each failed it. `tests/video_tb.sv` checks the layer pixel by pixel
over the colour bars and over the picture, the picture back after it, and a
cell rewritten while it is shown:

```sh
mkdir -p build/desk_link_tb
iverilog -g2012 -s desk_link_tb -o build/desk_link_tb/tb \
  fpga/ae350_soc/exts_uart.sv fpga/ae350_soc/desk_link.sv tests/desk_link_tb.sv
vvp -n build/desk_link_tb/tb
```

The programs contain the core, and the benchmark also the cartridge image,
so they are GPL builds for local use only: they stay in `build/` and, for the
player, on the user's own card. `MCACHE=<mask>` builds a program
that sets those `mcache_ctl` bits for its run, and `OPT=<flags>` replaces
`-O2` (an `rt.mk` setting); such builds want their own `BUILD=<dir>`.

The driver gives the core the few callbacks and settings it needs from a
driver, with power-on RAM filled with `0x00` so every run is the same and
the libretro driver's sound settings (48 kHz, volume 150, and each APU
channel at full volume, which `fceu_settings.c` sets because
`FCEUI_Initialize` leaves them at 0 and FCEUmm has no setter for them),
loads the built-in image and calls `FCEUI_Emulate` once a frame. On the AE350 it
points the core's picture buffer at the SDRAM frame buffer not being shown,
so the PPU draws straight into it; FCEUmm's palette, 768 entries with the
colour-emphasis tables, goes to the video unit's palette as the core sets
it; and after each frame it writes the D-cache back, writes any line whose
emphasis changed and asks for the buffer at the next vertical blank. It
starts the next frame once that one is on screen, so the game runs at 60
frames a second while the emulation keeps up, and the last frame stays up.
It plays a controller script, by default 1,800 frames of Castlevania: Start
at frame 120, then walking right through the first stage from frame 720
with whips and jumps. `FRAMES=<n>` and `INPUT="<first>+<frames>=<button> ..."`
replace them at build time, and `STATE=<n>` adds a save state round trip
(see *Save states*). The palette is FCEUmm's own unless `PALETTE=<n>`
picks one of the 23 presets of FCEUmm's libretro driver, which
`tools/gen_fceumm_palettes.py` generates into the build directory from the
fetched `src/drivers/libretro/libretro.c`, so no GPL table is committed here;
the script fails if upstream's names or order change, because the index is
what TinyTang sends. A Vs. System game keeps the palette its own PPU has, as
under the libretro driver. On the PC, `NES_DUMP=<dir>` saves the checked
frames as PPM images. It prints:

```text
TinyNES NES CORE=fceumm ROM=<bytes> CRC=<crc32> START=<us>
TinyNES NES PALETTE=<name>
TinyNES NES CACHE MICM=<micm_cfg> MDCM=<mdcm_cfg> I=<bytes>/<ways>/<line> D=<bytes>/<ways>/<line> MCTL=<mcache_ctl>
TinyNES NES F=<frame> AVG=<us> MAX=<us> SHOW=<us> VIDEO=<crc> AUDIO=<crc>
TinyNES NES FRAMES=<n> AVG=<us> MIN=<us> MAX=<us> SHOW=<us> OVER=<n> SPEED=<x.y>% LATE=<n> MISSED=<n>
TinyNES NES VIDEO=<crc> AUDIO=<crc>
```

`START` is initialising the core and loading the game. `CACHE` (AE350 only)
decodes the A25's cache configuration registers and reads back
`mcache_ctl`. An `F=` line covers the 120 frames before it. The frame times
are `FCEUI_Emulate` alone, which emulates the frame and mixes its sound;
the benchmark does not play it, the `PLAY=1` build does. `SHOW` is the mean time to hand a frame to the
video unit (0 on the PC). `VIDEO` is a CRC-32 of the picture and each
line's emphasis of every 60th frame and `AUDIO` of every frame's samples,
both taken outside the timed calls; `VIDEO` covers palette indices, not
colours, so it is the same in every palette. `OVER` counts frames slower than the
NES frame period and `SPEED` is that period over the average frame time.
`LATE` counts lines the video unit showed before their SDRAM fetch ended and
`MISSED` frames shown later than the vertical blank after they were asked
for; the program fails if `LATE` is not 0. Matching `VIDEO` and `AUDIO` on
the board and the PC show the A25 emulates the same frames.

Results with Castlevania (USA) (Rev A) on the board, against a 16.64 ms
frame period, with 32 KiB 4-way caches of 32-byte lines; every run's 16
checksum lines match the PC build of the same program. The rows above the
last used FCEUmm's libretro driver, whose `BLIT` was its conversion of the
8-bit picture into the frame format it asked for:

| Build | Frame average (range) | `BLIT` or `SHOW` | Slow frames | `SPEED` |
|---|---|---|---|---|
| Nestopia `135dfa6`, XRGB8888 | 23.16 ms (14.36 to 25.28) | not timed | 1,717 | 71.8% |
| FCEUmm libretro, XRGB8888 | 19.14 ms (12.36 to 20.41) | 8.23 ms | 1,715 | 86.9% |
| FCEUmm libretro, XRGB8888, `MCACHE=0x600` | 19.09 ms (12.34 to 20.14) | 8.23 ms | 1,715 | 87.1% |
| FCEUmm libretro, XRGB8888, `MCACHE=0x2000` | 19.20 ms (12.36 to 20.50) | 8.23 ms | 1,718 | 86.6% |
| FCEUmm libretro, XRGB8888, `OPT=-O3` | 19.40 ms (12.44 to 20.47) | 8.25 ms | 1,715 | 85.7% |
| FCEUmm libretro, RGB565 | 15.85 ms (9.09 to 17.06) | 5.01 ms | 607 | 104.9% |
| FCEUmm, own driver, on HDMI, channels muted | 10.82 ms (3.99 to 12.02) | 0.62 ms | 0 | 153.7% |
| FCEUmm, own driver, on HDMI (default) | 10.84 ms (3.93 to 12.07) | 0.61 ms | 0 | 153.5% |

Until 2026-10-13 the driver left FCEUmm's APU channel volumes at 0, so the
core mixed silence and the `AUDIO` checksums of the row above covered zeros;
with the channels on, mixing real sound costs nothing measurable, and the
default build's last line is `VIDEO=f2160661 AUDIO=4512be2f` on the board
and the PC.

The last run showed every frame at the next vertical blank (`LATE=0
MISSED=0`), started in 64 ms against the libretro build's 102 ms, and its
program is 753 KB against 1.67 MB. `SHOW` is mostly writing the D-cache back.
`mcache_ctl` reads back `0x3` with the prefetch (`0x600`) or write-around
(`0x2000`) bits set, so the A25 here does not have them. The Nestopia row is
the program of commit `a9c21fa` built with `CORE=nestopia` (and
`tools/fetch_nestopia.sh`, since removed), before `BLIT` was timed; on the
PC it was 1.8 times as slow as FCEUmm. The libretro rows are the program of
commit `a331d15`.

### HDMI video

`fpga/ae350_soc/video.sv` drives the board's HDMI port with 1280x720 at
60 Hz (CEA-861 timing, 74.25 MHz pixel clock, positive syncs), as DVI. It
shows a 256x240 frame buffer with each pixel three rows tall and either
three or four columns wide, by the ASPECT register: 768x720 with square
pixels, 878x720 at the NES's authentic 8:7 pixel aspect, or 960x720
stretched to the 4:3 television frame, centred between black side bars that
shrink with the picture. Until a program turns the frame buffers on it shows
eight colour bars made by the fabric. A pixel's palette index follows
FCEUmm's: the pixel itself when its line's emphasis is 0, otherwise
256 + 64 x emphasis + the pixel's low six bits.

The two frame buffers of 8-bit palette indices are the top 128 KiB of the
SDRAM: pixel (x, y) of buffer b is at `0x41fe0000 + 0x10000b + 256y + x`
(`TN_VIDEO_FB(b)`). Programs write them through the D-cache and must write
it back (`tn_dcache_wbinval`) before asking for a buffer to be shown. While
each line is shown, the unit fetches the next 256-byte line through a video
channel of the SDRAM controller, which serves it ahead of the A25 and behind
refresh, into the other of two line buffers built from flip-flops. The
768-entry palette and the 3-bit emphasis of each line are block RAM written
and read on the pixel clock; a bus write to them is handed across and holds
the bus for a few clocks. No block RAM is written on one clock and read on
another, as that did not work in the open flow here (reference record
TOOL-020). Offsets are from `0xe8000000`, and `firmware/include/tinynes.h`
names them:

| Offset | Access | Contents |
|---|---|---|
| `0x10000` | read, write | CTRL: bit 0 shows the frame buffers, bit 1 picks the buffer; both take effect at the next vertical blank |
| `0x10004` | read | STATUS: bit 0 in vertical blank, bit 1 the buffer shown, bit 2 the frame buffers are shown |
| `0x10008` | read | FRAMES: vertical blanks since reset |
| `0x1000c` | read | ID `0x544e5631` ("TNV1") |
| `0x10010` | read | LATE: lines shown before their SDRAM fetch had finished |
| `0x10014` | read | PIXELS (diagnostic): screen pixels of the last frame whose value was not 0, nine per NES pixel |
| `0x10018` | read | BITS (diagnostic): bit n set if pixel bit n was ever 1 in the last frame, bit 8 + n if ever 0 |
| `0x1001c` | read, write | ASPECT: 0 is 8:7, 1 is 1:1 (the reset value), 2 is 4:3; taken at the next vertical blank |
| `0x10800 + 4i` | read | Line buffer halfword i (diagnostic), one wait state |
| `0x11000 + 4i` | write | Palette entry i, red in bits 23:16, green 15:8, blue 7:0 |
| `0x12000 + 4(256b + y)` | write | Emphasis, bits 2:0, of line y of buffer b |

Registers and palette and emphasis take 32-bit transfers only; any other
access, including a read of a write-only area or of the old frame-buffer
window at `0x20000`, gets an AHB ERROR. The 371.25 MHz serial clock comes
from two PLLs on the right edge (`PLL_R[1]` and `PLL_R[3]`) fed by the 50 MHz
oscillator, and a `CLKDIV` in the right side's clock block beside the TMDS
pins divides it by five for the pixel clock; all four TMDS lanes, the clock
lane included (`1111100000` per pixel), leave through OSER10s on those two
clocks. With the serial-clock PLL at `PLL_L[3]` its clock crossed the die on
9.86 ns of general routing and the picture broke up with lines and lost
signal once the FPGA was warm (about 41 C on the package); at `PLL_R[3]` the
route is 2.12 ns and the picture held the game clean from 31 C to 69.8 C with
both PMOD sockets loaded (core reference DEV-018). The
build fails unless the pixel clock meets 74.25 MHz. The TMDS
encoder is TinyTang's (`fpga/hdmi_test/hdmi_test.v`, MIT).

`tests/video_tb.sv` tests the unit on its own with a model of the SDRAM's
video channel: registers and error responses, whole frames decoded from the
TMDS words and compared pixel by pixel with a model of the bars and of both
frame buffers with palette and emphasis, the sync timing, the buffer flip,
the fetch addresses, the LATE count when fetches are made too slow, the
PIXELS and BITS registers and the line-buffer readback, and a checked frame
at each of the three pixel aspects, whose model widens the picture and
spreads the 256 source pixels across it the way the unit's accumulator
does. It takes several
minutes:

```sh
mkdir -p build/video_tb
iverilog -g2012 -s video_tb -o build/video_tb/tb fpga/ae350_soc/video.sv tests/video_tb.sv
vvp -n build/video_tb/tb
```

`firmware/apps/video_test/` loads its own palette and emphasis, writes both
buffers and reads them back from the SDRAM after writing the D-cache back,
then for 600 frames copies a test picture into the buffer not shown, draws a
moving white square on it, writes the D-cache back and flips buffers at the
next vertical blank. It then checks what the fabric shows of the last buffer
with PIXELS:

```sh
make -C firmware/apps/video_test
python3 tools/load_ae350.py build/firmware/apps/video_test/video_test.elf \
  --run-timeout 60 --expect 'TinyNES VIDEO OK'
```

```text
VIDEO PIXELS=<n> WANT=<n> BITS=<hex> LB0=<hex> LB1=<hex>
TinyNES VIDEO OK FRAMES=<n> PERIOD=<us> COPY=<us> FB=<KB/s> VBL=<n> LATE=<n>
```

`PERIOD` is the mean time per frame, `COPY` the mean time to write a whole
frame buffer and write the D-cache back, `FB` that rate, `VBL` the vertical
blanks the fabric counted meanwhile and `LATE` the lines shown late, which
fails the test, as does PIXELS differing from WANT. On the board it reports
`PIXELS=468378 WANT=468378 BITS=ffff` and `FRAMES=600 PERIOD=16666 COPY=2832
FB=21694 VBL=600 LATE=0`, with the whole picture shown. `TINY_NES_SOC_DIAG=3`
builds the SoC with the palette bypassed, each pixel coloured from its
palette index alone (`build/ae350_soc_index/`).

### Wii Classic Controller inputs

The SoC polls four Wii extension controllers on four separate open-drain I2C
buses. Controller 1, player 1 and the one whose HOME tap shows TinyDesk, is
on USB-A port 2, the populated port, whose data pair reaches the FPGA: D+
(H13) is SDA and D- (G13) is SCL, the arrangement TinyGBC proved. It goes
through Adafruit's Wii Nunchuck Breakout Adapter fed from the port's 5 V
VBUS: the adapter's 10K pull-ups divide against the dock's 15K USB host
pull-downs to about 3.0 V at the pin, so no level shifting is needed, and
with nothing powered on the pair both lines read low. Controllers 2 to 4
are on PMOD0: controller 2 uses Digilent pins 2 and 8 (G21/G22) for SCL and
SDA, controller 3 pins 3 and 9 (F18/E18), and controller 4 pins 4 and 10
(C22/B22); PMOD0's first pair, pins 1 and 7, is no longer read. Power a
PMOD0 controller from PMOD0's 3.3 V on pin 6 or 12 and ground on pin 5 or
11. The signals use
internal pull-ups first; an external pull-up or a slower clock may be needed
if the measured rise time is too long. Do not feed 5 V into the signal pins.
For a four-wire Wii extension cable, red/white/yellow/green often mean
3.3 V/ground/SCL/SDA, respectively, but cable colors vary. Check the cable's
contacts or breakout labels with a continuity meter before applying power.
On the tested red/white/yellow/green cable, the user confirmed that mapping.
With the board's component side up and HDMI at the top, PMOD0 is the lower
socket on the right. Its holes run this way (inside column, outside column);
the first pair is shown as it was wired before controller 1 moved to USB-A:

```text
toward HDMI:       1 yellow SCL    7 green SDA
                   2               8
                   3               9
                   4              10
                   5 white GND    11 GND
toward USB-A:      6 red 3.3 V    12 3.3 V
```

Each bus wakes a controller at I2C address `0x52` without encryption, reads
its six-byte identity, then polls six data bytes from register `0x00`. A NACK
or SCL held low for 1 ms marks it absent; it retries after 100 ms. The reset
clock is about 100 kHz on the 75 MHz bus. All registers are 32-bit accesses
under the EXTS base `0xe8040000`:

| Offset | Access | Meaning |
| --- | --- | --- |
| `0x000` | read | ID `TNP1` (`0x544e5031`) |
| `0x004` | read/write | Quarter-bit clocks; write a nonzero value to change it and restart all four buses (`187` for about 100 kHz, `375` for 50 kHz) |
| `0x008` | read | LINES: each bus's pin levels, SDA in bits 7:4 and SCL in bits 3:0, bit n for bus n; a bus with no pull-ups reads 0 |
| `0x010 + 0x10n` | read | Pad n status: present bit 0, Classic identity bit 1, successful reads bits 23:8, failures bits 31:24 |
| `0x014 + 0x10n` | read | Data bytes 0-3; captures bytes 4-5 for the next DATA2 read |
| `0x018 + 0x10n` | read | Captured data bytes 4-5 in bits 15:0, identity bytes 4-5 in bits 31:16 |
| `0x01c + 0x10n` | read | Identity bytes 0-3 |

Pad n is numbered 0 to 3 in the register map. Classic Controller format 1
has 15 active-low buttons in data bytes 4-5, two sticks and two triggers.
`firmware/apps/pad_test/` prints decoded values whenever they change:

```sh
mkdir -p build/wii_pads_tb
iverilog -g2012 -s wii_pads_tb -o build/wii_pads_tb/tb \
  fpga/ae350_soc/wii_pads.sv tests/wii_pads_tb.sv
vvp build/wii_pads_tb/tb
make -C firmware/apps/pad_test
python3 tools/load_ae350.py build/firmware/apps/pad_test/pad_test.elf \
  --run-timeout 140 --expect 'TinyNES PAD OK'
```

The testbench models two controllers and two empty sockets, checks identity,
data bytes, clock stretching, unplug and retry, the writable clock divider,
and LINES reading 0 for a bus with no pull-ups and following it back up.
`pad_test` prints LINES at the start and with each status line, which tells
an open cable or an unpowered adapter (both lines 0 on USB-A) from a
controller that is wired but not answering. On 2026-10-13 the Classic Controller Pro on PMOD0 pins 1/7/5/6
reported a Classic Pro identity, zero PAD1 I2C failures, changing buttons,
both sticks and both triggers at the default clock; the user confirmed the
reports matched their inputs. The other three buses remain untested with pads.
The program watches the pads for 120 seconds and exits successfully if it
found a Classic controller and sampled its data; it prints any input changes
during that time.
If the internal pull-ups do not give a fast enough rise for another controller,
build a 50 kHz diagnostic separately with `make -C firmware/apps/pad_test
BUILD=$PWD/build/firmware/apps/pad_test_50k PAD_QUARTER=375`, then load that
directory's `pad_test.elf`.

### I2S audio on PMOD1

`fpga/ae350_soc/i2s_out.sv` sends stereo I2S to a Digilent Pmod I2S2 seated
normally on PMOD1: its CS4344 DAC's MCLK, LRCK, SCLK and SDIN on Digilent
pins 1-4 (FPGA W19, F19, E22 and E21); pins 7-10, the ADC, are unused. Every
audio clock is counted down from the 75 MHz bus clock, so the unit adds no
clock to the clock network: MCLK is 12.5 MHz (bus / 6, 50% duty), SCLK
MCLK / 4 and LRCK MCLK / 256, a sample rate of 48,828.125 Hz, inside the
CS4344's 2 to 50 kHz range for a 256x MCLK. The frame is I2S, 64 SCLKs: LRCK
low for left, a delay bit, then the 16-bit sample MSB first and zeros. The
clocks run from reset with silence. A 2,048-pair FIFO in block RAM feeds the
DAC one pair a frame; an empty FIFO plays silence and counts an underrun.
Its registers are at `0xe8050000`:

| Offset | Register | Use |
|---|---|---|
| `0x000` | ID | `TNA1` (`0x544e4131`) |
| `0x004` | CTRL | bit 0 enables playback; writing bit 1 empties the FIFO |
| `0x008` | STATUS | bits 11:0 FIFO level in pairs, bits 31:16 underruns |
| `0x00c` | DATA | write one pair: left in bits 31:16, right in 15:0 |
| `0x010` | FRAMES | frames sent since reset |
| `0x014` | DROPS | writes dropped because the FIFO was full |

Other accesses get an AHB ERROR. `tests/i2s_out_tb.sv` decodes SDIN at
rising SCLK edges as the DAC does and checks the clock ratios and duty, that
LRCK and SDIN change only as SCLK falls, the delay bit and zero padding, the
sample order through the FIFO, silence and the underrun count when it runs
dry, dropped writes when it is full, the flush, a STATUS read in a DATA
write's data phase, and the ERROR responses. `firmware/apps/audio_test/`
measures the frame rate against the A25's cycle counter and plays 1 kHz on
the left and 2 kHz on the right for five seconds:

```sh
mkdir -p build/i2s_out_tb
iverilog -g2012 -s i2s_out_tb -o build/i2s_out_tb/tb \
  fpga/ae350_soc/i2s_out.sv tests/i2s_out_tb.sv
vvp build/i2s_out_tb/tb
make -C firmware/apps/audio_test
python3 tools/load_ae350.py --tinytang build/firmware/apps/audio_test/audio_test.elf \
  --expect 'TinyNES AUDIO OK'
```

Connect Line Out to powered speakers or an amplifier, starting at a low
volume; the board has no headphone amplifier. On the board `audio_test`
measured 48,827.968 Hz (a quarter-second count, so 16 Hz is one frame),
played five seconds with no underrun or dropped write, and the user heard
the tones in the right channels. The `PLAY=1` build of `nes_bench` then
played Castlevania's sound with the game for 5,866 frames with no underrun.

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
original MIT-licensed code, apart from the TMDS encoder in `video.sv`, which
is TinyTang's, also MIT; `tools/fs_to_bin.py` is likewise TinyTang's MIT
converter, copied with its notice. The desk layer's font,
`fpga/ae350_soc/desk_font.hex`, is generated from Daniel Hepper's font8x8,
which is in the public domain and is itself based on public-domain VGA
fonts by Marcel Sondaar and IBM. CERN's colibri and its SystemVerilog port are
design practice references; their modules are not included.

FCEUmm descends from BERO's
FCE and Xodnizel's FCE Ultra, with code by CaH4e3 and the others in its
`Authors` file; it is distributed under GPL-2.0 (its `Copying`), most of its
files allow any later version, and a few carry other notices, such as
`boards/pic16c5x.c` under BSD-3-Clause. The libretro ports and
libretro-common are maintained by the libretro team. TinyNES fetches the
core with `tools/fetch_fceumm.sh` and does not distribute it; the patches it
applies, in `patches/fceumm/`, are GPL-2.0-or-later. The player's zip
reader links libretro-common's DEFLATE decoder from the same fetched tree,
which carries its own MIT notice (the RetroArch team). 100th Coin's AccuracyCoin
and TriCNES are MIT; the cartridge is fetched by
`tools/fetch_accuracycoin.sh` and TriCNES is a reference only. The `nes_bench`
harness is MIT-licensed, but programs built with the core are GPL and cartridge images belong to their owners; neither is
committed.
