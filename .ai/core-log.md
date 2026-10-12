## 1 COMMIT Unreleased 2026-10-12T06:30:29-07:00

#### Coming From:

Unreleased e6a0556

#### Purpose:

Establish the first open-flow AE350 hardware gate, in which a minimal AE350 ROM program writes an AHB status word and FPGA fabric reports it on the FPGA UART, and record its first hardware results.

#### Outcome:

Added `fpga/ae350_uart/ae350_uart.sv` with its `.cst` and `.sdc`, the open-flow build script `tools/build_ae350_uart.sh` (Yosys, the GW5AST-138C nextpnr-himbaechel fork and the Apicula fork; no Gowin EDA or generated vendor IP), the one-wire UART probe `tools/check_ae350_uart.py`, the testbench `tests/ae350_uart_tb.sv`, a README describing the gate and its diagnostics, and an MIT `LICENSE`. `TINY_NES_UART_DIAG=1` builds a fabric-only UART diagnostic and `TINY_NES_UART_DIAG=2` builds a CPU-bus trace that reports `ADDR`, `ROM` and `AHB` latches, which observe the reset-vector region on the ROM address bus, a valid ROM AHB transfer, and the expected status write. The available open chip database omits `ROM_HADDR29`, `EXTS_HWDATA3`, `EXTS_HWDATA0` and `EXTS_HADDR31`, so the status write uses mapped data bit 4 and the select; this is an open-toolchain mapping gap, not a silicon limit. All three builds passed, and the normal, diagnostic and trace simulations passed. On hardware in one-wire mode (FT2232 `0403:6010`, UART on `/dev/ttyUSB1`), SRAM loads with `openFPGALoader -b tangmega138k` completed with `DONE`. The normal image was silent on two loads. The fabric-only diagnostic printed `UART DIAGNOSTIC!` on two separate occasions, proving the 50 MHz input, PLL, reset release, UART logic, U15 pin and serial path, but not the AE350 core clock. Earlier trace images with `TRST_IN` at 0 and then 1 both reported `ROM=0 AHB=0`, so deasserting JTAG test reset did not help. The final trace image with `ADDR` observation, SHA-256 `89fc136ef7fbcb0b69919193a207a9aaca1f8d6bbc896765adf3be96a91c3fd1` and 184.16 MHz reported bus Fmax, was loaded after a cold boot at the user's direction; the first load produced no UART bytes while the control diagnostic passed immediately afterward, and a reload of the same trace image then reported `ADDR=0 ROM=0 AHB=0` on every line. The AE350 therefore never presents its reset-vector region on the ROM address bus, which directs attention to its clock, reset or output-port mapping in the open flow rather than to ROM contents. The probe matches `--expect` only as a complete CRLF-terminated line, so partial patterns report failure. The milestone `TinyNES AE350 OK` was not observed. The core-syntax audit passed.

#### Next Steps:

Compare the AE350 clock, reset and output-port connections in `fpga/ae350_uart/ae350_uart.sv` against Tang-Phosphor's working Gowin-flow AE350 smoke design and the Apicula AE350 port map, covering every reset and power-on-reset input, any clock enable or gate, and which PLL output drives the core clock, then propose a corrected trace image with a core-clock activity indicator for hardware testing.

#### Files Modified:

- .gitignore
- LICENSE
- README.md
- fpga/ae350_uart/ae350_uart.sv
- fpga/ae350_uart/ae350_uart.cst
- fpga/ae350_uart/ae350_uart.sdc
- tests/ae350_uart_tb.sv
- tools/build_ae350_uart.sh
- tools/check_ae350_uart.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: FAIL

---

## 2 COMMIT Unreleased 2026-10-12T08:02:35-07:00

#### Coming From:

Unreleased 0a4437d

#### Purpose:

Isolate why the open-flow AE350 trace image reported `ADDR=0 ROM=0 AHB=0` while the same RTL built by Gowin EDA passed, and correct the open toolchain so the AE350 fetches and writes over AHB.

#### Outcome:

The AE350 core clock in `fpga/ae350_uart/ae350_uart.sv` was lowered to 75 MHz (`ODIV1_SEL` 10) for bring-up. A Gowin IDE 1.9.11.03 build of the same RTL, used only as an out-of-product control, passed with `ADDR=1 ROM=1 AHB=1`, which ruled out the RTL and silicon. Three toolchain diagnostics did not change the open-flow result: a 75 MHz core clock, the PLL attribute 211 value 2 measured from the vendor bitstream (B), and routing `PLL_R[0]` `CLKOUT0` onto the global network through `TRPLL0CLK0` (C). A Gowin vehicle that pinned all 495 `AE350_SOC` outputs and all 415 inputs to registers showed that the Apicula output map agreed with the vendor on only 2 of 495 bits while the input map and every constant tie matched, so the measured output map (E) was committed to the Apicula fork as `d8eb183` on `aquasock` `epic/gw5ast138c`. Bit-level repacks of the open-flow design, changing only the centre clock-spine mux, the core-clock hop bits, the vendor clock-routing bits and the vendor bitstream header, all still failed, while our packer writing the vendor's tile image passed with or without our extra PLL and spine-enable bits and without the vendor's unused-IO defaults, which placed the fault in clock routing or placed logic rather than in the bitstream writer. In the build with B, C and E, the AE350 bus-clock taps were fed from row-0 `GB10` through `GBO0` at column 165, but no row-10 bits programmed that column's `GT00` from a spine, whereas the vendor feeds column 162 `GT00` from `SPINE27` at row 10. With B and C reverted, the chipdb regenerated and nextpnr rebuilt, all three images built, the normal and diagnostic simulations passed, and the trace image, SHA-256 `fa79e598f9005b486f0b71a7be56d91d9347f615e32908350ad051f6e3918539` at 184.16 MHz reported bus Fmax, loaded with `DONE` and reported `ADDR=1 ROM=1 AHB=1` on two separate loads, the first open-flow proof that the AE350 fetches its reset vector and completes the status write. That image routes `AHB_CLK`, `APB_CLK`, `DDR_CLK` and `RTC_CLK` through general fabric wires rather than the global clock network, so the pass depends on placement: the normal image, SHA-256 `65ed28074be6ae72918b2980ecabc85a7af6997470f9bb24172936bb6f3d55eb`, received a different fabric clock route, loaded with `DONE` and stayed silent for 20 seconds with the probe already listening. These hardware results came from agent-run probes in one-wire mode, and the milestone `TinyNES AE350 OK` was not observed. The core-syntax audit passed.

#### Next Steps:

Route the AE350 bus clocks over the global clock network into the row-0 `AE350_SOC` clock taps the way the vendor does, by fixing nextpnr's global router or the Apicula row-0 branch and row-10 tap description so a `GBO0` branch used by row 0 is always fed from a spine, then rebuild the normal image and have the user confirm `TinyNES AE350 OK` on hardware. Because the output map is now complete, the status write can then decode the full `EXTS_HADDR` and `EXTS_HWDATA` instead of the bit-4 and select workaround.

#### Files Modified:

- fpga/ae350_uart/ae350_uart.sv

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: FAIL

---

## 3 COMMIT Unreleased 2026-10-12T08:38:26-07:00

#### Coming From:

Unreleased ce92755

#### Purpose:

Raise the AE350 A25 core clock to 750 MHz and measure the rate it actually runs at on hardware before fixing the bus-clock routing.

#### Outcome:

`fpga/ae350_uart/ae350_uart.sv` now divides the 750 MHz VCO by 1 on `PLL_R[0]` `CLKOUT1` for `CORE_CLK` and keeps the 75 MHz bus on `CLKOUT0`. After the status write, the ROM program loops storing `mcycle` to `0xe8000004`, and fabric pairs each stored value with a Gray-coded count of the 50 MHz board oscillator taken in the same bus cycle, so the measured rate does not depend on the PLL configuration. The trace line now ends with `CYC` and `REF` hex fields, `tools/check_ae350_uart.py --clock N` derives the core clock from consecutive pairs and matches only complete lines that begin with the expected text, the testbench checks the pairing and both fields, `tools/build_ae350_uart.sh` accepts `TINY_NES_SEED` for the nextpnr placement seed, and the README describes the measurement. The normal, diagnostic and trace simulations passed. The normal and diagnostic images built; the default-seed trace build failed nextpnr's hold check on seven `bus_clk` paths with up to 2.14 ns of clock skew, a consequence of the fabric-routed bus clock recorded in entry 2, and a seed sweep gave hold-clean results for seeds 2, 3, 5, 6 and 7 but not 4. The seed-2 trace image, SHA-256 `0fc643d5ff77307993a3e8d40693e9f9be9bb2fb4025950cadbb19ddb4f15ee7` at 138.12 MHz reported bus Fmax with the dedicated core-clock hop present, was first silent, as was a rebuilt diagnostic from `ce92755`, until the user power-cycled the board, which re-enumerated the FT2232 bridge. After that, three separate loads of the trace image each reported `ADDR=1 ROM=1 AHB=1` with an advancing cycle pair, and every 0.899 s interval measured 750.0000 MHz, so the A25 runs at full rate under the open flow. The normal image, SHA-256 `c854bec0964fb19c5acc58d3fc1013f9d2526ebd1be2cccd7a9187ed7d94922f`, loaded with `DONE` and stayed silent with the probe already listening, consistent with its different fabric bus-clock route. Reference record DEV-008 records the clock source, the measured rate and Gowin's 200 MHz bus limit. The user accepted the measurement as a pass. The core-syntax audit passed.

#### Next Steps:

Route the AE350 bus clocks over the global clock network into the row-0 `AE350_SOC` clock taps the way the vendor does, by fixing nextpnr's global router or the Apicula row-0 branch and row-10 tap description so a `GBO0` branch used by row 0 is always fed from a spine, then rebuild the normal image without a seed and have the user confirm `TinyNES AE350 OK` on hardware before replacing the bit-4 and select status check with a full `EXTS_HADDR` and `EXTS_HWDATA` decode.

#### Files Modified:

- README.md
- fpga/ae350_uart/ae350_uart.sv
- tests/ae350_uart_tb.sv
- tools/build_ae350_uart.sh
- tools/check_ae350_uart.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 4 COMMIT Unreleased 2026-10-12T08:49:40-07:00

#### Coming From:

Unreleased c3567bc

#### Purpose:

Add a general parallel build-sweep tool that compares design variants across nextpnr seeds for timing, resource use and clock routing without loading the board.

#### Outcome:

Added `tools/sweep.py` and the design description `tools/designs/ae350_uart.json`, and documented them in the README. The tool synthesises each variant once, places and routes every variant and seed in a parallel pool, optionally packs the results in a smaller pool, and writes `results.csv`, `results.json` and `summary.txt` with each run's nextpnr status and first error, Fmax per clock, hold violations, used resources, placement wirelength, dedicated clock-routing misses per net, clock route length in pips, run time and peak memory. Measured per run, synthesis took 0.6 s, nextpnr about 3 s and 120 MB, and an Apicula pack about 7 s and 1.7 GB, so 16 parallel place-and-route jobs fit this 28-thread, 15 GB machine while packing defaults to four at a time. A three-seed trace check reproduced the seed-2 trace image byte for byte as SHA-256 `0fc643d5ff77307993a3e8d40693e9f9be9bb2fb4025950cadbb19ddb4f15ee7` and the two seed-4 hold violations, so place and route is deterministic per seed. The sweep of normal and trace over seeds 1 to 16 with 16 jobs and clean packing finished place and route 7.6 s after synthesis and packed 27 images by 57.8 s. All 16 normal runs were hold-clean, with `bus_clk` Fmax from 144.53 to 186.25 MHz, while 11 of 16 trace runs were clean and seeds 4, 11, 13, 14 and 16 failed with 2, 1, 8, 4 and 8 hold violations, with clean `bus_clk` Fmax from 131.53 to 179.34 MHz. In every run, `bus_clk` missed dedicated clock routing on every sink, 70 in normal and 297 in trace, so the whole bus clock, including all fabric registers and not only the four `AE350_SOC` taps, is carried on general routing with a seed-dependent route of 127 to 210 pips in normal and 370 to 638 in trace; only `sys_clk` used a global buffer, and `core_clk` always took its one-pip dedicated hop. Hold failures therefore grow with the number of bus-clock registers, and the routing fix has to bring `PLL_R[0]` `CLKOUT0` onto the global network for all of its sinks. No image from this cycle was loaded, and the user did not test hardware. The core-syntax audit passed.

#### Next Steps:

Make nextpnr route `PLL_R[0]` `CLKOUT0` onto the global clock network for every `bus_clk` sink, including the row-0 `AE350_SOC` taps fed from a row-10 spine the way the vendor does, then use the sweep to confirm that dedicated-routing misses drop to zero and hold failures disappear across seeds before the user checks `TinyNES AE350 OK` on hardware.

#### Files Modified:

- README.md
- tools/designs/ae350_uart.json
- tools/sweep.py

#### Status:

- Build: PASS
- Deployment: N/A
- User Test: N/A

---

## 5 COMMIT Unreleased 2026-10-12T10:05:09-07:00

#### Coming From:

Unreleased 4f93827

#### Purpose:

Route the AE350 bus clock from `PLL_R[0]` `CLKOUT0` over the global clock network for every sink so that the normal image runs on hardware and hold failures stop depending on the placement seed.

#### Outcome:

The aquasock forks on `epic/gw5ast138c` carry the fix: Apicula `f20633a` links `PLL_R[0]` `CLKOUT0` to the clock-plane wire `TRPLL0CLK0` (change C) and drops the centre-mux entries from top-edge PLL wires into the BOTTOM-half spines, and nextpnr `5796d407` lets the global router take a PLL output through such a wire as its first hop. With C alone, the sweep was clean but every image was silent on hardware, including with PLL attribute 211 set to 2 (B), because nextpnr took `bus_clk` in at `(54,88) SPINE16` and out through `CBRIDGEOUT_BOTTOM0`. A PLL-to-UART test design built with both flows printed `PLL OK` from the open flow's `(54,93) SPINE8` entry and went silent with that bridge mux cleared. Repacking the silent AE350 trace image with only the entry and the `(27,96)` and `(81,87)` bridge muxes moved to `(54,93) SPINE10` and `CBRIDGEOUT_TOP2` made it report `ADDR=1 ROM=1 AHB=1` on two loads while the unpatched image stayed silent, which reference record DEV-009 records. With the restricted chipdb regenerated and nextpnr rebuilt, `tools/sweep.py` over normal and trace with seeds 1 to 16 was 32 of 32 clean with no hold violations and one dedicated-routing miss per run, `bus_clk` Fmax was 162.39 to 193.84 MHz in normal and 127.16 to 174.16 MHz in trace, and every seed entered at `(54,93)`. Trace seeds 1 and 2 reported `ADDR=1 ROM=1 AHB=1` at 750 MHz and normal seeds 1 and 2 printed `TinyNES AE350 OK`, the first open-flow pass of the milestone. B was then reverted, and the seed-2 repacks without it passed again: trace SHA-256 `d77e89e74a10047c9e3f72f3c135f9d804e135f10d00780c44e423e4e6af8fe5` and normal SHA-256 `f32a72cd0a4bcd19abe84017af0304cbc0e554acfb5bacb884ff91b6a3c0ee55`. These were agent-run SRAM loads in one-wire mode with the user's board, and the user approved the revised plan and the results. The core-syntax audit passed.

#### Next Steps:

Replace the bit-4 and select status check in the AE350 gate with a full `EXTS_HADDR` and `EXTS_HWDATA` decode, and confirm `TinyNES AE350 OK` on hardware from an unseeded normal build.

#### Files Modified:

None.

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 6 COMMIT Unreleased 2026-10-12T10:15:49-07:00

#### Coming From:

Unreleased 6534144

#### Purpose:

Replace the AE350 gate's bit-4 and select status check with a full `EXTS_HADDR` and `EXTS_HWDATA` decode so that `TinyNES AE350 OK` proves every address and data bit of the measured AE350 output map on hardware.

#### Outcome:

The ROM in `fpga/ae350_uart/ae350_uart.sv` is now sixteen RV32I words, encoded by hand and checked with the capstone disassembler, that store `0xa5a5a5a5`, `0x5a5a5a5a`, `0xffffffff`, `0` and a walking one to `0xe8000000`, 36 writes in all, before the `mcycle` loop to `0xe8000004`. Unused ROM addresses now return a self-jump. The gate compares all 32 bits of `EXTS_HADDR` with those two addresses and each status write's data with the expected pattern. `TinyNES AE350 OK` is sent only after all 36 match. The first write to any other address, any data mismatch, or an extra pattern write instead sends `BAD N=nn A=aaaaaaaa D=dddddddd` with the pattern index, address and received data, and the trace field shows `AHB=E`. `tests/ae350_uart_tb.sv` drives the writes back to back with overlapping address and data phases and gains a `FAULT` parameter. The normal, diagnostic and trace simulations passed, as did a flipped data bit, which reported `BAD N=05 A=e8000000 D=00000003`, and a cleared address bit 31, which reported `BAD N=09 A=68000000 D=00000020`. `tools/check_ae350_uart.py` now fails at once on a `BAD` or `AHB=E` line and prints it, and the README describes the decode. Unseeded builds passed with bus Fmax 113.33 MHz for normal and 103.22 MHz for trace. `tools/sweep.py` over normal and trace with seeds 1 to 16 was 32 of 32 clean with no hold violations. `bus_clk` Fmax was 99.44 to 118.26 MHz in normal and 97.49 to 108.67 MHz in trace, down from entry 5 because of the comparators but above the 75 MHz target. In one-wire mode the unseeded normal image, SHA-256 `ae9babe6643fc360b227b46e1d74bc715d2391c9d3fb4db0c2f498f8b3327e5f`, printed `TinyNES AE350 OK` on two loads. The unseeded trace image, SHA-256 `d12c2c1911fe82182e162b93cdab400b93888fd28790760dba60a7f2f2ba3421`, reported `ADDR=1 ROM=1 AHB=1` with the core clock measured at 750.0000 MHz over four intervals. The measured Apicula output map is therefore exact for every `EXTS_HADDR` and `EXTS_HWDATA` bit, including `EXTS_HADDR31`, `EXTS_HWDATA0` and `EXTS_HWDATA3`, which entry 1 recorded as missing. These were agent-run SRAM loads on the user's board, and the user accepted the result. The core-syntax audit passed.

#### Next Steps:

The AE350 UART gate is complete, so the next cycle should propose the next TinyNES milestone for user approval. The README paragraph that says the AE350 bus clocks reach the core through general fabric routing has been out of date since entry 5 and should be corrected in that cycle.

#### Files Modified:

- README.md
- fpga/ae350_uart/ae350_uart.sv
- tests/ae350_uart_tb.sv
- tools/check_ae350_uart.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 7 COMMIT Unreleased 2026-10-12T12:02:53-07:00

#### Coming From:

Unreleased 9efedb5

#### Purpose:

Give the AE350 a boot ROM, RAM and fabric registers so that C firmware built with an installed RISC-V toolchain runs on the A25 and tests its RAM with the caches off and on, as the first step from the UART gate toward running Nestopia.

#### Outcome:

xPack GNU RISC-V Embedded GCC 15.2.0-1 is installed in `~/tools` and recorded as TOOL-018. `firmware/boot/` builds a 32 KiB boot image with `-nostdlib` and libgcc alone. `fpga/ae350_soc/` puts it in a block-RAM boot ROM on the ROM port at `0x80000000`, a 64 KiB block RAM on the RAM port at `0x40000000`, and UART, ID and scratch registers in the EXTS window. The firmware checks the registers, tests the RAM with the caches off and then on, and prints `TinyNES AE350 C OK UNC=<cycles> CAC=<cycles>`. If the CPU writes nothing, the fabric prints a `NOBOOT` report of the port counts instead. The testbench `tests/ae350_soc_tb.sv` and gate-level checks of the boot ROM and RAM against the Gowin primitive models passed. `tools/build_ae350_soc.sh` builds the image, and `tools/sweep.py` gained a `prebuild` step and `tools/designs/ae350_soc.json`. The first image was silent on hardware. A `CPU_HOLD` diagnostic (`TINY_NES_SOC_DIAG=1`) showed the fabric and UART working. A `CPU_TX_DROP` diagnostic (`TINY_NES_SOC_DIAG=2`) showed the firmware passing every uncached test and then stopping straight after it set `mcache_ctl` to 3 and ran `fence.i`. The `NOBOOT` report gained the last RAM address, a port state word, and the first and last addresses of RAM-port transfers outside the RAM window. Varying only the cache bits showed that the A25 makes instruction fetches to address 0 on the RAM port, which it does not execute: single reads with the caches off and 32-byte WRAP4 line fills with the I-cache on. They got ERROR without trapping when one cache or neither was on, but with both caches on the core stopped for good after one at `0x18`. `ahb_ram.sv` now answers an instruction fetch outside its window with zero and OKAY and keeps ERROR for data accesses there, which reference record DEV-010 records. The cause of the fetches themselves is unknown. With the fix, the default-seed image, SHA-256 `e74ab2eec341b01dcf06de060c395e9fa697670cb796b33e1cf9b369a4cbecd9` with bus Fmax 201.65 MHz, printed `TinyNES AE350 C OK UNC=03bc52c0 CAC=001e33e1`, so the cached test ran about 32 times faster, and `tools/check_ae350_uart.py` passed. The drop diagnostic of the fixed design showed four such fetches answered with the CPU running on. `tools/sweep.py` over seeds 1 to 16 was 16 of 16 clean with no hold violations, with bus Fmax 144.8 to 218.53 MHz, median 199.07 MHz. The README describes the system, the stray-fetch rule, the extended `NOBOOT` report and both diagnostic builds, and corrects the bus clock paragraph that entry 6 flagged. Reference records TOOL-017 and BRD-008 were revised. These were agent-run SRAM loads in one-wire mode on the user's board, and the user accepted the result. The core-syntax audit passed.

#### Next Steps:

The next cycle should propose the next step toward running Nestopia for user approval, most likely a larger RAM behind the RAM port and a C runtime able to host the emulator core, and any new RAM-port slave must answer stray instruction fetches as DEV-010 requires.

#### Files Modified:

- README.md
- firmware/boot/Makefile
- firmware/boot/crt0.S
- firmware/boot/link.ld
- firmware/boot/main.c
- firmware/boot/tinynes.h
- fpga/ae350_soc/ae350_soc.cst
- fpga/ae350_soc/ae350_soc.sdc
- fpga/ae350_soc/ae350_soc.sv
- fpga/ae350_soc/ahb_boot_rom.sv
- fpga/ae350_soc/ahb_ram.sv
- fpga/ae350_soc/exts_uart.sv
- tests/ae350_soc_tb.sv
- tools/build_ae350_soc.sh
- tools/check_ae350_uart.py
- tools/designs/ae350_soc.json
- tools/sweep.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 8 COMMIT Unreleased 2026-10-12T12:49:40-07:00

#### Coming From:

Unreleased 9c4935b

#### Purpose:

Put the dock's SDRAM module behind the AE350 RAM port as 32 MiB of cacheable main memory, tested from the A25, as the memory the Nestopia port will run in.

#### Outcome:

`fpga/ae350_soc/ahb_sdram.sv` is a new SDRAM controller on the 75 MHz bus clock at CAS latency 3, with the SDRAM clock an inverted copy of the bus clock from an `ODDR`, read capture on the falling edge, a one-line 32-byte read buffer filled critical word first, posted writes merged into that buffer, a row opened and closed per access, and periodic refresh. `ahb_ram.sv` moved the 64 KiB block RAM to `0x60000000`, sends `0x40000000` to `0x41ffffff` to the controller, and keeps the DEV-010 rule outside both windows; `ae350_soc.sv` and `ae350_soc.cst` add the 38 J9 pins, and the firmware's `link.ld` follows the block RAM. The pins and the module, two W9825G6KH-6 on J9 driven as one 32 MiB device on its single chip select with J10 empty, are recorded as BRD-010, and the RAM port's decode and caching of both windows as DEV-011; DEV-010, BRD-008 and PSX-005 were revised. `tests/sdram_model.sv` is a new W9825G6KH-6 model that checks command order, timing, refresh interval and bank state and aliases rows so that address faults read X, and `tests/ae350_soc_tb.sv` runs the controller against it at 75 MHz; deliberate controller faults in capture timing, tRCD, tRC, tWR, refresh rate, row and column address bits, write merging and DQM were each caught, and both testbench modes passed. The firmware tests the SDRAM's byte and halfword lanes with the caches off and on, walks every address line, runs a pattern and its inverse over all 32 MiB with the caches on, and measures the SDRAM. The first FPGA build failed in Yosys because the controller's wait counter had an initial value different from its asynchronous reset value; matching them fixed it. The default-seed image, SHA-256 `8be6c686f2d14986873cb5ceeb82940c0313a5c2b88e8f66eac70520d0e76812` with bus Fmax 175.59 MHz, was loaded by the agent to SRAM in one-wire mode and printed `TinyNES AE350 C OK UNC=03f15308 CAC=001e33f4` and `TinyNES SDRAM OK 32M MISS=370 RD=61607 WR=34072 FULL=3044`, so an SDRAM cache-line miss costs 370 core cycles, cached reads run at 61,607 KB/s and writes at 34,072 KB/s, and the full 32 MiB test took 3,044 ms; `tools/check_ae350_uart.py` passed on the SDRAM line. `tools/sweep.py` over seeds 1 to 16 was 16 of 16 clean with no hold violations, with bus Fmax 152.72 to 184.81 MHz, median 166.835 MHz. The README documents the memory map, the controller and the new report line. The user accepted the result. The core-syntax audit passed.

#### Next Steps:

The next cycle should propose a C and C++ runtime and program loader for the AE350, with the heap and large data in SDRAM, as the next step toward a headless Nestopia benchmark, for user approval; the module's second chip stays unused until the pin that selects it is found.

#### Files Modified:

- README.md
- firmware/boot/link.ld
- firmware/boot/main.c
- firmware/boot/tinynes.h
- fpga/ae350_soc/ae350_soc.cst
- fpga/ae350_soc/ae350_soc.sv
- fpga/ae350_soc/ahb_ram.sv
- fpga/ae350_soc/ahb_sdram.sv
- tests/ae350_soc_tb.sv
- tests/sdram_model.sv
- tools/build_ae350_soc.sh
- tools/designs/ae350_soc.json

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 9 COMMIT Unreleased 2026-10-12T13:41:29-07:00

#### Coming From:

Unreleased 86e3207

#### Purpose:

Give the AE350 a way to receive programs over the UART and a C and C++ runtime to run them from the SDRAM, as the base the headless Nestopia benchmark will be built on.

#### Outcome:

`fpga/ae350_soc/exts_uart.sv` gained a receiver on V14 with the pull-up on, and the UART now runs at 2,000,000 baud 8N1 both ways: each bit lasts 37 or 38 bus clocks in turn, the receiver samples at bit centres and drops a start bit that is gone by then, and received bytes go into a 512-byte block RAM buffer read from a new register at `0xe8000010`, with the status register now reporting a waiting byte and sticky overrun and missing-stop-bit flags that a write clears. `tests/ae350_soc_tb.sv` gained a receiver test covering byte order, senders 3 and 5 percent fast and slow, reads while bytes arrive, a glitch, a missing stop bit, a 513-byte overrun and the buffer pointers wrapping; every deliberate receiver fault was caught except one that cannot change behaviour, and both testbench modes passed. The firmware was split: `firmware/include/tinynes.h` holds the register map and the load protocol, `firmware/common/` the memory tests and UART output shared by the ROM and loaded programs, and `firmware/boot/` the boot ROM, which now runs only quick memory tests, the full SDRAM test having moved to a loaded program, and then waits for a program, which `firmware/boot/load.c` receives in 8 KiB blocks with CRC-32 checks, NAK reasons and timeouts, checks again after reading the whole image back from the SDRAM, and starts with `fence.i` and both caches on. `firmware/rt/` is the runtime for loaded programs, with newlib and libstdc++, exceptions and RTTI, a heap over the rest of the SDRAM and the stack in the block RAM; on exit or a trap it reports and restarts the boot ROM. `firmware/apps/rt_test/` checks the runtime and carries the full SDRAM test and its speed measurements. `tools/load_ae350.py` sends an ELF file's segments, resends NAKed blocks and follows the program's output to its exit, and `tools/check_ae350_uart.py` gained `--baud`. `tests/test_loader_host.py` runs the ROM's real `load.c` on the PC against `load_ae350.py` through a pseudo-terminal, with lost, corrupted and overflowed bytes, bad headers, addresses outside the SDRAM, a bad read-back and a sender that stops; all six tests passed, and four bugs planted in `load.c` one at a time were each caught. The default-seed image, SHA-256 `4daa055507ed2a32e79801c8bf941fef252a02651500fbe88c2afd947dc5b899`, has bus Fmax 146.09 MHz, and `tools/sweep.py` over seeds 1 to 16 was 16 of 16 clean with no hold violations, bus Fmax 120.45 to 153.28 MHz, median 136.845 MHz, lower than entry 8's but still above 75 MHz. The agent's first SRAM load used openFPGALoader v0.13.1 from `/usr/bin`, which had not finished after more than three minutes and was stopped; oss-cad-suite's v1.1.1 then loaded the image in one-wire mode. The ROM printed `TinyNES AE350 C OK UNC=0491d418 CAC=001f696a`, `TinyNES SDRAM OK 32M` and `TinyNES LOAD` once a second, and `check_ae350_uart.py --baud 2000000` passed on the last. `load_ae350.py` loaded the 138,072-byte `rt_test` image in 0.76 s, 182.2 KB/s, with no block resent, and it printed `TinyNES RT OK MISA=4094312d HEAP=32576K` and `TinyNES SDRAM OK 32576K MISS=370 RD=61604 WR=34071 FULL=2989` and exited with 0; a second load straight after gave the same lines, so the restart back to the ROM works. The misa value is recorded as DEV-012, showing a double-precision FPU the soft-float firmware does not use; PSX-003 is now verified, as the system runs on V22 and moved every byte over V14 and U15; TOOL-018 records the runtime's libraries; DEV-011 follows the moved files. The README documents the receiver, the boot ROM's new report, the load protocol and tool, the runtime, `rt_test` and the host test, and `.gitignore` now ignores Python caches. The user accepted the result. The core-syntax audit passed.

#### Next Steps:

The next cycle should propose a headless Nestopia benchmark for user approval: Nestopia's libretro core fetched as a separate dependency under its GPL-2.0-or-later terms rather than copied into this repository, built with the runtime, fed a test ROM and timed per frame on the A25, with whether to use the FPU decided in that plan.

#### Files Modified:

- .ai/core-reference.md
- .gitignore
- README.md
- firmware/apps/rt_test/Makefile
- firmware/apps/rt_test/main.cpp
- firmware/boot/Makefile
- firmware/boot/load.c
- firmware/boot/load.h
- firmware/boot/main.c
- firmware/boot/tinynes.h
- firmware/common/memtest.c
- firmware/common/memtest.h
- firmware/common/uart.c
- firmware/common/uart.h
- firmware/include/tinynes.h
- firmware/rt/crt0.S
- firmware/rt/link.ld
- firmware/rt/rt.mk
- firmware/rt/syscalls.c
- fpga/ae350_soc/ae350_soc.cst
- fpga/ae350_soc/ae350_soc.sv
- fpga/ae350_soc/exts_uart.sv
- tests/ae350_soc_tb.sv
- tests/host_loader.c
- tests/test_loader_host.py
- tools/check_ae350_uart.py
- tools/load_ae350.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 10 COMMIT Unreleased 2026-10-12T14:02:31-07:00

#### Coming From:

Unreleased 179559c

#### Purpose:

Measure how fast the libretro Nestopia core runs a real game headless on the A25, and whether its output matches a PC build, to show how far the AE350 is from full-speed NES emulation.

#### Outcome:

`tools/fetch_nestopia.sh` clones libretro/nestopia at commit `135dfa6dfda5e7603d61e751b9ddd0cc42546bc3`, the head of master on 2026-10-11, into `third_party/nestopia/`, which `.gitignore` now excludes, and fails if the checkout is at another commit or has local changes, so the GPL-2.0-or-later core is never part of this repository. `firmware/rt/rt.mk` gained `LIB_SOURCES`, third-party sources built with the runtime's architecture, optimisation and include flags plus their own `LIB_CPPFLAGS`, `LIB_CFLAGS` and `LIB_CXXFLAGS` but without this project's warnings and `-Werror`, and `EXTRA_OBJECTS`, and its include path now starts with `firmware/rt/include/`. The board build first failed because newlib's `<sys/dirent.h>` is an `#error` and libretro-common's file layer includes `<dirent.h>`; `firmware/rt/include/sys/dirent.h` now defines the directory types, and `firmware/rt/syscalls.c` gained `opendir`, `readdir` and `closedir`, which always fail, as files already did. `firmware/apps/nes_bench/` is a libretro front end with no video, audio or input device: it links the core's own source list from upstream's `Makefile.common` with upstream's GCC flags, except `-std=gnu++11` where upstream has `-std=c++98`, builds in the cartridge image named by `ROM=`, plays 1,800 frames with a scripted controller, times each `retro_run`, and prints CRC-32s of the picture every 60th frame and of all the sound, with a `host` target that builds the same harness for the PC. The user supplied Castlevania (USA) (Rev A), 131,088 bytes; the PC build ran at about 361 microseconds a frame with identical checksums on two runs, and frame dumps showed the script starting the game and walking Simon through the first stage into the castle hall. The board build linked with no undefined symbols, 2,553,553 bytes of code and 1,032,548 of data, and the agent loaded it in one-wire mode with oss-cad-suite's openFPGALoader and the ae350_soc image of entry 9, after `check_ae350_uart.py` passed. `load_ae350.py` sent 3,586,108 bytes in 19.44 s, 184.5 KB/s; the program printed `START=780965` microseconds for `retro_init` and `retro_load_game`, `CACHE MICM=00439ada MDCM=00439ada I=32768/4/32 D=32768/4/32`, and `FRAMES=1800 AVG=23164 MIN=14360 MAX=25279 OVER=1717 SPEED=71.8%` against the core's 16,639-microsecond frame, and exited with 0; all 15 interval lines and the final line of checksums matched the PC build exactly. A build with upstream's `-std=c++98` also compiled and was not run. The README documents the fetch script, the runtime's directory stand-in and third-party sources, and the benchmark with its results and licensing, and replaces the references section's licensing note with Nestopia's attribution. DEV-013 records the cache geometry, DEV-014 the cache prefetch bits found in U-Boot's Andes header and not yet tried, PROV-006 Nestopia's terms and pinned commit, TOOL-019 the dirent fix and third-party build, and EMU-001, in a new EMU topic, the measured result. The user accepted the result. The core-syntax audit passed.

#### Next Steps:

The next cycle should discuss with the user whether FCEUX, which the user suggested might be a better choice, should be measured with the same harness against Nestopia, and which speed-ups to try: the cache prefetch bits, compiler options, the FPU and placing hot code or data in the block RAM.

#### Files Modified:

- .ai/core-reference.md
- .gitignore
- README.md
- firmware/apps/nes_bench/Makefile
- firmware/apps/nes_bench/main.cpp
- firmware/apps/nes_bench/rom.S
- firmware/rt/include/sys/dirent.h
- firmware/rt/rt.mk
- firmware/rt/syscalls.c
- tools/fetch_nestopia.sh

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 11 COMMIT Unreleased 2026-10-12T14:15:04-07:00

#### Coming From:

Unreleased cf3d25e

#### Purpose:

Measure the libretro FCEUmm core with the same harness, game and script as Nestopia, to decide which core TinyNES should carry forward.

#### Outcome:

`tools/fetch_fceumm.sh` clones libretro/libretro-fceumm at commit `ac0d00a7fc01166f84c7bac01d1084ebfd2b865e`, the head of master on 2026-10-11, into the git-ignored `third_party/fceumm/` with the same checks as the Nestopia script; its `Copying` is GPL version 2, most of its files allow any later version, and a few carry a BSD notice or none. `firmware/apps/nes_bench/Makefile` gained `CORE=nestopia`, the default, or `CORE=fceumm`, each built in its own directory under `build/firmware/apps/nes_bench/`; FCEUmm is built from its own `Makefile.common` with upstream's unix defines and `-O2 -DNDEBUG`, without the NTSC filter and HD texture packs, and compiled with no warnings at GCC 15's default language standard. The harness now prints the core's name, answers `fceumm_ramstate` with `fill $00` to match Nestopia's power-on RAM, and answers `RETRO_ENVIRONMENT_GET_GAME_INFO_EXT` with the built-in image, because FCEUmm's first PC run failed opening `rom.nes` as a file; Nestopia does not ask for it, and its PC checksums were unchanged. The board link then stopped on newlib's `_stat_r` needing `_stat`, which `firmware/rt/syscalls.c` now provides, failing with `ENOENT` like its other file calls. On the PC FCEUmm averaged 197 microseconds a frame against Nestopia's 362, started in 0.8 milliseconds, gave identical checksums on two runs, and its frame dumps showed the same script reaching the castle hall. The board program had 801,172 bytes of code and 864,624 of data against Nestopia's 2,553,691 and 1,032,588. The agent loaded the ae350_soc image of entry 9 in one-wire mode; a UART check run without `--expect "TinyNES LOAD"` reported FAIL, and the same check with it passed after the run. `load_ae350.py` sent 1,665,796 bytes in 9.07 s, and the program printed `START=102431`, `FRAMES=1800 AVG=19070 MIN=12344 MAX=20123 OVER=1715 SPEED=87.2%` and exited with 0, with all 16 checksum lines matching the PC build. FCEUmm is therefore 1.21 times as fast as Nestopia on the A25 against 1.84 times on the PC, and needs about 1.15 times more for full speed. The README's benchmark section now covers both cores, with a results table and FCEUmm's attribution and terms. PROV-007 records FCEUmm's terms and pinned commit, EMU-002 its result, and TOOL-019 the new `_stat`. The user accepted the result. The core-syntax audit passed.

#### Next Steps:

The next cycle should ask the user whether to drop Nestopia now that FCEUmm is the faster core, and then propose the speed-ups for FCEUmm in an order the user approves: the cache prefetch bits, compiler options, the FPU, and placing hot code or data in the block RAM, measuring each with the same harness.

#### Files Modified:

- .ai/core-reference.md
- README.md
- firmware/apps/nes_bench/Makefile
- firmware/apps/nes_bench/main.cpp
- firmware/rt/syscalls.c
- tools/fetch_fceumm.sh

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 12 COMMIT Unreleased 2026-10-12T14:36:54-07:00

#### Coming From:

Unreleased a9c21fa

#### Purpose:

Keep FCEUmm as the only core, as the user decided, and try a first round of speed-ups on it, measuring where its frame time goes on the A25.

#### Outcome:

The user asked whether one run could settle the choice of core; the figures of entries 10 and 11 already favoured FCEUmm on frame time, start, load time and program size, and the user chose it without another run. `tools/fetch_nestopia.sh` and `nes_bench`'s `CORE=` option are removed; the Nestopia build remains in git at `a9c21fa`. `firmware/rt/rt.mk` gained an `OPT` setting, `-O2` by default, for all code it builds. The harness now times `BLIT`, the span from FCEUmm's request for a frontend framebuffer, which it refuses, to its video callback, which is the core's per-pixel palette conversion; `MCACHE=<mask>` builds set those `mcache_ctl` bits for the run and every AE350 run prints `mcache_ctl` back as `MCTL=`. The first PC run showed `BLIT=0` because the environment switch strips `RETRO_ENVIRONMENT_EXPERIMENTAL` from the command while the labels kept it, which had also left `GET_INPUT_BITMASKS` unanswered since entry 10; both labels now strip it, and the checksums were unchanged. The agent loaded the ae350_soc image of entry 9 in one-wire mode for four XRGB8888 runs of the 1,800-frame Castlevania script: `-O2` averaged 19,143 microseconds with `BLIT=8231` (86.9 percent), the prefetch bits `0x600` 19,091 (87.1 percent), the write-around bit `0x2000` 19,203 (86.6 percent) and `-O3` 19,404 (85.7 percent), with `BLIT` unchanged in each; both cache-bit builds printed `MCTL=00000003`, so those bits do not exist on this A25. Converting the frame was 43 percent of the A25's frame time against 8 percent on the PC. On the user's approval the core is now built with `WANT_32BPP=0`, so it asks for RGB565 and writes half as many bytes; the harness accepts either format and checksums and dumps it. On the PC two runs gave the same checksums and the dumped frames showed correct colours. On the board the RGB565 program averaged 15,851 microseconds with `BLIT=5013`, minimum 9,092, maximum 17,055 and 607 frames over: `SPEED=104.9%`, with all 16 checksum lines matching the PC build; the walk right from frame 720 averages about 16.6 milliseconds, at the limit. The user asked whether the test includes sound: the core emulates and mixes it at 32 kHz inside the timed call, and only playback is absent. The README's benchmark section now describes FCEUmm alone, with the new options, report fields and a results table that keeps the Nestopia row. DEV-014 is now verified as a negative result, EMU-003 records this round, and EMU-001, EMU-002, PROV-006 and TOOL-019 are revised. `.ai/core.md` still describes TinyNES as a port of Nestopia; it was not edited, and the user was told. The user accepted the result. The core-syntax audit passed.

#### Next Steps:

The next cycle should propose to the user how to remove the remaining 5 milliseconds of frame conversion, which keeps the walk right at the frame limit: the measured route is a display path in which FPGA logic reads FCEUmm's 8-bit picture and applies the palette, and smaller levers to measure first are the FPU, block-RAM placement of hot code or data, and the profile of the emulation itself.

#### Files Modified:

- .ai/core-reference.md
- README.md
- firmware/apps/nes_bench/Makefile
- firmware/apps/nes_bench/main.cpp
- firmware/rt/rt.mk
- tools/fetch_nestopia.sh (removed)

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---
