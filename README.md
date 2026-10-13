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
| RAM (64-bit) | `0x40000000` | 32 MiB SDRAM on the dock's J9 module (`ahb_sdram.sv`); a data access to any address on this port outside the two RAMs gets an AHB ERROR, and an instruction fetch reads zero |
| EXTS (uncached) | `0xe8000000` | UART data `+0x00`, UART status `+0x04`, ID `0x544e3031` ("TN01") `+0x08`, scratch `+0x0c`, UART receive `+0x10` (`exts_uart.sv`); HDMI video from `+0x10000` (`video.sv`, below) |

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
| 1 | The transmitter is idle: the last byte has left the pin |
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
the bitstream `build/ae350_soc/ae350_soc.fs`:

```sh
bash tools/build_ae350_soc.sh
```

The build needs the forks of nextpnr and Apicula on their `epic/gw5ast138c`
branches, which add a timing model for the AE350's AHB ports, measured from
the vendor's timing reports, so the bus paths into and out of the A25 are
timed. The A25's bus dies when its clock reaches it through global clock
branch `GB20`, and works through `GB10`; the cause is not yet known. Until it
is, the script sets `NPNR_GOWIN_CLK_FIRST=bus_clk`, a temporary knob in the
nextpnr fork that routes the bus clock first so that it takes `GB10`, and
fails if nextpnr did not apply it. A sweep of `ae350_soc` (below) needs the
same variable set.

The testbench drives each AHB port directly. `TEST=0` covers the ROM, the RAM's
byte lanes, ERROR responses and zero-reading fetches, the EXTS registers, the
CPU UART, the UART receiver (byte order, senders 5% fast and slow, glitches,
missing stop bits, overrun and the status bits), and the SDRAM controller
against `tests/sdram_model.sv`, a W9825G6KH-6 model that checks command
order and timing, and that video transfers reach the video unit beside the
UART registers. `TEST=1` covers the `NOBOOT` report and the CPU taking the
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
`--timeout`, `--run-timeout` and `--retries` change its defaults.

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
the top of the SDRAM, and the stack is the top of the 64 KiB block RAM.
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

`firmware/apps/nes_bench/` runs the libretro FCEUmm core with no video, sound
or controller, on a cartridge image built into the program, and times each
`retro_run` against the NES frame period. `tools/fetch_fceumm.sh` clones
commit `ac0d00a7fc01166f84c7bac01d1084ebfd2b865e` into `third_party/`, which
git ignores, and checks that it is unmodified. The Makefile includes the
core's own `Makefile.common` and builds it as upstream does for unix, but
without the NTSC filter and HD texture packs, which run only when their
options are chosen, and with RGB565 frames in place of XRGB8888, which halve
the frame's SDRAM writes; `WANT_32BPP=1` restores XRGB8888. The cartridge
image is the user's own and is never committed:

```sh
tools/fetch_fceumm.sh
make -C firmware/apps/nes_bench ROM=<file.nes>          # AE350 program
make -C firmware/apps/nes_bench ROM=<file.nes> host     # the same for the PC
python3 tools/load_ae350.py build/firmware/apps/nes_bench/nes_bench.elf --run-timeout 600
build/firmware/apps/nes_bench/host/nes_bench
```

The programs contain the core and the cartridge image, so they are GPL builds
for local use only and stay in `build/`. `MCACHE=<mask>` builds a program
that sets those `mcache_ctl` bits for its run, and `OPT=<flags>` replaces
`-O2` (an `rt.mk` setting); such builds want their own `BUILD=<dir>`.

The harness answers the libretro environment with no system or save files,
the pixel format the core asks for (RGB565 or XRGB8888) and RAM filled with
`0x00` at power-on, so every run is the same. It describes the built-in image
through `GET_GAME_INFO_EXT`, as RetroArch does, because FCEUmm otherwise
reads the game from its path. It plays a controller script, by default 1,800
frames of Castlevania: Start at frame 120, then walking right through the
first stage from frame 720 with whips and jumps. `FRAMES=<n>` and
`INPUT="<first>+<frames>=<button> ..."` replace them at build time. On the
PC, `NES_DUMP=<dir>` saves the checked frames as PPM images. It prints:

```text
TinyNES NES CORE=fceumm ROM=<bytes> CRC=<crc32> START=<us>
TinyNES NES CACHE MICM=<micm_cfg> MDCM=<mdcm_cfg> I=<bytes>/<ways>/<line> D=<bytes>/<ways>/<line> MCTL=<mcache_ctl>
TinyNES NES F=<frame> AVG=<us> MAX=<us> BLIT=<us> VIDEO=<crc> AUDIO=<crc>
TinyNES NES FRAMES=<n> AVG=<us> MIN=<us> MAX=<us> BLIT=<us> OVER=<n> SPEED=<x.y>%
TinyNES NES VIDEO=<crc> AUDIO=<crc>
```

`START` is `retro_init` and `retro_load_game`. `CACHE` (AE350 only) decodes
the A25's cache configuration registers and reads back `mcache_ctl`. An `F=`
line covers the 120 frames before it. `BLIT` is the part of the frame
average that the core spends turning its 8-bit picture into the output
frame, timed from its request for a frontend framebuffer, which the harness
refuses, to its video callback. `VIDEO` is a CRC-32 of every 60th frame and
`AUDIO` of every frame's samples, both taken outside the timed calls; the
core emulates and mixes the sound (32 kHz, its default low quality) inside
`retro_run`, but nothing plays it. `OVER` counts frames slower than the NES
frame period and `SPEED` is that period over the average frame time.
Matching `VIDEO` and `AUDIO` on the board and the PC show the A25 emulates
the same frames.

Results with Castlevania (USA) (Rev A) on the board, against a 16.64 ms
frame period, with 32 KiB 4-way caches of 32-byte lines; every run's 16
checksum lines match the PC build of the same program:

| Build | Frame average (range) | `BLIT` | Slow frames | `SPEED` |
|---|---|---|---|---|
| Nestopia `135dfa6`, XRGB8888 | 23.16 ms (14.36 to 25.28) | not timed | 1,717 | 71.8% |
| FCEUmm, XRGB8888 | 19.14 ms (12.36 to 20.41) | 8.23 ms | 1,715 | 86.9% |
| FCEUmm, XRGB8888, `MCACHE=0x600` | 19.09 ms (12.34 to 20.14) | 8.23 ms | 1,715 | 87.1% |
| FCEUmm, XRGB8888, `MCACHE=0x2000` | 19.20 ms (12.36 to 20.50) | 8.23 ms | 1,718 | 86.6% |
| FCEUmm, XRGB8888, `OPT=-O3` | 19.40 ms (12.44 to 20.47) | 8.25 ms | 1,715 | 85.7% |
| FCEUmm, RGB565 (default) | 15.85 ms (9.09 to 17.06) | 5.01 ms | 607 | 104.9% |

On the PC the core takes about 0.20 ms a frame, of which `BLIT` is 0.016 ms;
on the A25, writing the frame to the SDRAM is most of `BLIT`, and the rest of
the frame is about 10.9 ms. `mcache_ctl` reads back `0x3` with the prefetch
(`0x600`) or write-around (`0x2000`) bits set, so the A25 here does not have
them. With RGB565 the stage's walk right, from frame 720, runs at about
16.6 ms a frame, at the limit. The Nestopia row is the program of commit
`a9c21fa` built with `CORE=nestopia` (and `tools/fetch_nestopia.sh`, since
removed), before `BLIT` was timed; on the PC it was 1.8 times as slow as
FCEUmm.

### HDMI video

`fpga/ae350_soc/video.sv` drives the board's HDMI port with 1280x720 at
60 Hz (CEA-861 timing, 74.25 MHz pixel clock, positive syncs), as DVI. It
shows a 256x240 frame buffer at three times its size, 768x720, centred
between black side bars. Until a program turns the frame buffers on it shows
eight colour bars made by the fabric. There are two frame buffers of 8-bit
palette indices, a 768-entry palette and a 3-bit colour emphasis for each
line, all in block RAM. A pixel's palette index follows FCEUmm's: the pixel
itself when its line's emphasis is 0, otherwise 256 + 64 x emphasis + the
pixel's low six bits. Offsets are from `0xe8000000`, and
`firmware/include/tinynes.h` names them:

| Offset | Access | Contents |
|---|---|---|
| `0x10000` | read, write | CTRL: bit 0 shows the frame buffers, bit 1 picks the buffer; both take effect at the next vertical blank |
| `0x10004` | read | STATUS: bit 0 in vertical blank, bit 1 the buffer shown, bit 2 the frame buffers are shown |
| `0x10008` | read | FRAMES: vertical blanks since reset |
| `0x1000c` | read | ID `0x544e5631` ("TNV1") |
| `0x11000 + 4i` | write | Palette entry i, red in bits 23:16, green 15:8, blue 7:0 |
| `0x12000 + 4(256b + y)` | write | Emphasis, bits 2:0, of line y of buffer b |
| `0x20000 + 0x10000b + 256y + x` | write | Pixel (x, y) of buffer b, as bytes, halfwords or words |

Registers, palette and emphasis take 32-bit transfers only; any other access,
including a read of a write-only area, gets an AHB ERROR. Every other transfer
completes with no wait state. The 371.25 MHz serial clock comes from two PLLs
fed by the 50 MHz oscillator, and a `CLKDIV` in the right side's clock block
beside the TMDS pins divides it by five for the pixel clock. The build fails
unless the pixel clock meets 74.25 MHz. The TMDS encoder is TinyTang's
(`fpga/hdmi_test/hdmi_test.v`, MIT).

Each byte lane of each frame buffer is written as eight 4Kx4 arrays, so that
each maps to one block RAM in 4-bit mode. Left to itself, synthesis picks
1-bit mode, and Apicula's 1-bit mode reads back as zero on this chip.

`tests/video_tb.sv` tests the unit on its own: registers and error responses,
then whole frames decoded from the TMDS words and compared pixel by pixel with
a model of the bars and of both frame buffers with palette and emphasis, the
sync timing and the buffer flip. It takes several minutes:

```sh
mkdir -p build/video_tb
iverilog -g2012 -s video_tb -o build/video_tb/tb fpga/ae350_soc/video.sv tests/video_tb.sv
vvp -n build/video_tb/tb
```

`firmware/apps/video_test/` loads its own palette and emphasis, then for 600
frames copies a test picture into the buffer not shown, draws a moving white
square on it, and flips buffers at the next vertical blank:

```sh
make -C firmware/apps/video_test
python3 tools/load_ae350.py build/firmware/apps/video_test/video_test.elf \
  --run-timeout 60 --expect 'TinyNES VIDEO OK'
```

```text
TinyNES VIDEO OK FRAMES=<n> PERIOD=<us> COPY=<us> FB=<KB/s> VBL=<n>
```

`PERIOD` is the mean time per frame, `COPY` the mean time to write a whole
frame buffer with 32-bit stores, `FB` that rate and `VBL` the vertical blanks
the fabric counted meanwhile. On the board it reports
`FRAMES=600 PERIOD=16666 COPY=2253 FB=27270 VBL=600`, and the moving square
can be seen. The picture is distorted, though, and the fault is not yet
found. `TINY_NES_SOC_DIAG=3` builds the SoC with the palette bypassed, each
pixel coloured from its palette index alone (`build/ae350_soc_index/`), to
tell palette faults from frame buffer faults.

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
is TinyTang's, also MIT. CERN's colibri and its SystemVerilog port are
design practice references; their modules are not included.

FCEUmm descends from BERO's
FCE and Xodnizel's FCE Ultra, with code by CaH4e3 and the others in its
`Authors` file; it is distributed under GPL-2.0 (its `Copying`), most of its
files allow any later version, and a few carry other notices, such as
`boards/pic16c5x.c` under BSD-3-Clause. The libretro ports and
libretro-common are maintained by the libretro team. TinyNES fetches the
core with `tools/fetch_fceumm.sh` and does not distribute it. The `nes_bench`
harness is MIT-licensed, but programs built with the core are GPL and cartridge images belong to their owners; neither is
committed.
