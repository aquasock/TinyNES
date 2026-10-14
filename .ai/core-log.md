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

## 13 COMMIT Unreleased 2026-10-12T18:16:06-07:00

#### Coming From:

Unreleased a331d15

#### Purpose:

Give the A25 an HDMI picture, as the user approved: a 1280x720 60 Hz output showing a 256x240 indexed frame buffer at three times its size, with FCEUmm's palette and colour emphasis applied in FPGA logic.

#### Outcome:

`fpga/ae350_soc/video.sv` adds the video unit on the EXTS window at `0xe8010000`: control, status, frame count and ID registers, a 768-entry palette, per-line emphasis and two frame buffers, with CEA-861 720p timing, fabric colour bars until a program turns the buffers on, and TinyTang's MIT TMDS encoder; `ae350_soc.sv` adds the two HDMI PLLs, the `CLKDIV`, the serialisers and the EXTS mux, `firmware/include/tinynes.h` names the registers, `firmware/apps/video_test/` draws a test picture with a moving square, `tests/video_tb.sv` decodes whole frames from the TMDS words against a model, and `tests/ae350_soc_tb.sv` checks video transfers beside the UART registers; both testbenches passed throughout. On the board the first images showed the colour bars but the A25 never printed its boot lines, and after each such load the debug bridge's UART stayed silent for every image until a power cycle (BRD-012). Bisection with fabric-only beacons, an off-bus variant and a powered supply ruled out power, the HDMI PLLs and the video logic; at the user's choice the A25's bus ports were given a timing model measured from Gowin's timing analyser, committed as aquasock/apicula `860ada4` and aquasock/nextpnr `67293958` (DEV-015), which did not cure it. The cause was the clock branch: when the pixel clock was added nextpnr fed the AE350's bus clock taps from global branch GB20 instead of GB10, and only the GB10 images boot (DEV-016); a temporary nextpnr knob, `NPNR_GOWIN_CLK_FIRST` in aquasock/nextpnr `7d1b131c`, routes `bus_clk` first, and `tools/build_ae350_soc.sh` now sets it and fails if nextpnr did not apply it. The GB10 image ran `video_test` but the picture was black; a gate-level simulation of the netlist was correct, and the new `TINY_NES_SOC_DIAG=3` build, which colours pixels by palette index (`DEBUG_INDEX`), showed the emphasis RAM working and every frame-buffer pixel zero. Apicula's 1-bit two-clock block RAM, which Yosys chose for the frame buffers, reads zero on this chip, though a decode of Gowin and Apicula builds of the same test RAMs found matching attributes and routing (TOOL-020); the user asked whether decrypting Gowin's encrypted netlists would go against the project's spirit, was told it would and is not done, and agreed. At the user's choice of a shortcut over a hardware fuse hunt, the frame buffers are now built as 4Kx4 arrays that map to 4-bit block RAM. That build, `build/ae350_soc/ae350_soc.fs` with SHA-256 `3937428fe63aa77e5c7e1f5ff3358ae1aac1475d048fc3766ff4dae46175db23`, bus Fmax 125.60 MHz and pixel Fmax 83.03 MHz, is reproduced byte for byte by the script with the committed forks; the agent loaded it in one-wire mode and `video_test` printed `TinyNES VIDEO OK FRAMES=600 PERIOD=16666 COPY=2253 FB=27270 VBL=600` and exited 0. The user saw the moving square but a distorted picture, which they will show later, and closed the cycle without accepting it; the cause of the distortion is not investigated. `tools/designs/ae350_soc.json` gained `video.sv` so sweeps build again, the README documents the video unit, its tests and the toolchain knob, and DEV-015, DEV-016, BRD-011, BRD-012 and TOOL-020 are new. In the Apicula fork `tests/test_ae350_tap_directions.py` expects 453 decided output taps and now finds 495 with none wrong, a stale count from its earlier port-map commit `d8eb183` that was left unchanged. The core-syntax audit passed.

#### Next Steps:

The next cycle should start from the user's photograph of the distorted picture and locate the fault, using the `TINY_NES_SOC_DIAG=3` build to tell the palette from the frame buffers and pixel pipeline, and get the user's acceptance of the `video_test` picture before FCEUmm's frames are sent to it; the GB20 fault (DEV-016), the 1-bit block RAM fault (TOOL-020) and the stale Apicula test count remain open in the toolchain forks.

#### Files Modified:

- README.md
- firmware/apps/video_test/Makefile
- firmware/apps/video_test/main.c
- firmware/include/tinynes.h
- fpga/ae350_soc/ae350_soc.cst
- fpga/ae350_soc/ae350_soc.sdc
- fpga/ae350_soc/ae350_soc.sv
- fpga/ae350_soc/exts_uart.sv
- fpga/ae350_soc/video.sv
- tests/ae350_soc_tb.sv
- tests/video_tb.sv
- tools/build_ae350_soc.sh
- tools/designs/ae350_soc.json

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: FAIL

---

## 14 COMMIT Unreleased 2026-10-12T21:53:08-07:00

#### Coming From:

Unreleased f7b8385

#### Purpose:

Find and fix the distorted HDMI picture of entry 13 so that `video_test` shows the whole test picture on the board, as the user approved, moving the frame buffers into the SDRAM when block RAM proved unusable.

#### Outcome:

The user's capture card recorded the entry-13 image and the captured frames, decoded per pixel, showed each 4Kx4 frame-buffer block either readable, reading zero or missing bits 1 and 3, and the palette black from entry 256 up; 2Kx9 DPX9B frame buffers then read zero on all eight placement seeds while a 512x9 emphasis store on the same two clocks read correctly. At the user's choice the frame buffers moved to the top 128 KiB of the SDRAM: `fpga/ae350_soc/ahb_sdram.sv` gained a video channel that reads a 256-byte line in one row ahead of A25 transfers and behind refresh, `fpga/ae350_soc/video.sv` fetches each line into two flip-flop line buffers and keeps the palette and emphasis in block RAM on the pixel clock only, with bus writes handed across, a LATE count of lines shown before their fetch ended, and diagnostic PIXELS, BITS and line-buffer readback registers, and a pipeline stage before the TMDS encoders keeps the pixel clock above 74.25 MHz. `firmware/rt/link.ld` stops the heap below the buffers, `firmware/include/tinynes.h` names them and the new registers, and `video_test` writes the buffers through the D-cache, writes it back with MCCTL command 6, reads them back from the SDRAM and fails on LATE or on PIXELS differing from the picture. The line buffers read back correctly over the bus, yet seeds showed pixel bits stuck at 0, and BITS with the routed netlists sorted every `pixel1` flip-flop by the spine feeding its clock branch: SPINE17 and SPINE18, reached through `(27,94) CBRIDGEOUT_BOTTOM0` and `BOTTOM2`, never clocked, SPINE26 through `(27,96)` and `(81,96) BOTTOM2` always did. Raising the pixel clock constraint to 150 MHz gave byte-identical bitstreams, so nextpnr's placement is not timing-driven here and the timing explanation was dropped. A first fork change sending the CLKDIV into the TOP entry, as DEV-009 does for the PLL, left the pixel clock dead on all eight seeds and the user's monitor without signal, and was reverted. A Gowin IDE 1.9.11.03 build of the same clock chain, run headless (TOOL-021) and decoded with gowin_unpack, entered at `(54,88) SPINE19` through `BOTTOM3`. The aquasock Apicula fork at `cd3893f` now drops the three dead bridge pips and lets the CLKDIV wires enter only at `(54,88) SPINE18`, with `tests/test_clock_bridge_138c.py`; its existing `test_ae350_tap_directions.py` still expects the stale 453 of entry 13. `tools/build_ae350_soc.sh` now fails unless the pixel clock reaches the spines only through `SPINE26 <= CBRIDGEOUT_BOTTOM2` and every video block RAM has one clock. With the fork, all eight seeds passed the check and, loaded by the agent in one-wire mode while the user watched the monitor, printed `PIXELS=468378 WANT=468378 BITS=ffff` and `VIDEO OK FRAMES=600 PERIOD=16666 VBL=600 LATE=0`; the unseeded image, SHA-256 `1b9ad22e5b3a5ad55fe661664e2c61c69f7399917a9915824bf34c3c9161ac3c` with bus Fmax 82.80 MHz and pixel Fmax 88.64 MHz, did the same, and `rt_test` on it printed `HEAP=32448K` and `SDRAM OK 32448K MISS=379`, the video fetches of the held picture costing about 2.5 percent of SDRAM throughput. Both `ae350_soc_tb` modes, including a new line fetch through the SDRAM model beside a RAM-port read, passed, as did `tests/video_tb.sv` with its new fetch, LATE, PIXELS, BITS and line-buffer readback checks. The user watched every seed and accepted the result. DEV-017 and TOOL-021 are new, TOOL-020 is rewritten, and DEV-009, DEV-011 and BRD-011 are revised. The core-syntax audit passed.

#### Next Steps:

The next cycle should propose sending FCEUmm's 8-bit frames and palette to the video unit, drawing into the SDRAM frame buffers in place of the RGB565 conversion that entry 12 measured, for user approval; any new clock source on this chip needs its clock-plane entry measured as DEV-017 describes, and the NPNR_GOWIN_CLK_FIRST workaround of DEV-016 and the stale Apicula test count remain open.

#### Files Modified:

- README.md
- firmware/apps/video_test/main.c
- firmware/include/tinynes.h
- firmware/rt/link.ld
- fpga/ae350_soc/ae350_soc.sv
- fpga/ae350_soc/ahb_sdram.sv
- fpga/ae350_soc/video.sv
- tests/ae350_soc_tb.sv
- tests/video_tb.sv
- tools/build_ae350_soc.sh

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 15 COMMIT Unreleased 2026-10-12T22:42:08-07:00

#### Coming From:

Unreleased 5d14d74

#### Purpose:

Show FCEUmm's own 8-bit frames on HDMI by having its core draw straight into the SDRAM frame buffers, as the user approved, removing the RGB565 conversion that kept the NES benchmark at the frame limit.

#### Outcome:

FCEUmm's core needs only four FCEUD callbacks, GetKeyboard and nine timing globals from its driver, and its PPU writes lines 0 to 240 of `XBuf`, each at most 272 bytes from its start, with each line's emphasis in `XDBuf` and its palette set as entries 0 to 767 in the video unit's layout, so `firmware/apps/nes_bench/main.cpp` now replaces FCEUmm's `libretro.c` with its own driver: it sets the power-on RAM fill, sound rate and volume of the libretro driver's defaults, loads the built-in image, points `XBuf` at the SDRAM frame buffer not shown before each `FCEUI_Emulate`, sends palette writes to the video unit, writes the D-cache back and any changed line emphasis after each frame, asks for the buffer at the next vertical blank and starts the next frame once it is shown, reporting `SHOW`, `LATE` and `MISSED` where `BLIT` was, and the Makefile builds the core without `libretro.c` and `libretro_dipswitch.c`. The libretro driver had never been answered on its sound-rate hint and ran at 48 kHz, which the new driver keeps, and the README's earlier 32 kHz is corrected. The PC build gave the same checksums on two runs and its dumped frames show the title, gate, courtyard and castle hall in correct colours. On the board, with the image of entry 14 (`1b9ad22e`) loaded by the agent in one-wire mode, the 753,044-byte program started in 64,194 us and played 1,800 frames of the Castlevania script at an average of 10,824 us (3,992 to 12,016) against 16,639 us, `OVER=0 SPEED=153.7% LATE=0 MISSED=0` with `SHOW` 615 us, and all 16 checksum lines matched the PC build; the user watched the game on HDMI, said it looked perfect and accepted the result. EMU-004 is new, EMU-003 is revised and the README's benchmark section describes the new driver and output. The core-syntax audit passed.

#### Next Steps:

The next cycle should propose making the benchmark a playable NES for user approval: sound output, which the core already mixes at 48 kHz, a real controller in place of the script, and a run that does not stop after 1,800 frames.

#### Files Modified:

- README.md
- firmware/apps/nes_bench/Makefile
- firmware/apps/nes_bench/main.cpp

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 16 COMMIT Unreleased 2026-10-13T00:04:20-07:00

#### Coming From:

Unreleased b9c2900

#### Purpose:

Read four Wii Classic Controller extension buses on PMOD0 so the AE350 can use real controller inputs.

#### Outcome:

`wii_pads.sv` adds four independent open-drain I2C masters with unencrypted wake-up, Classic identity checks, six-byte polling, clock stretching, retry and memory-mapped status and input registers at `0xe8040000`; `ae350_soc.sv`, its constraints and build manifest connect them to PMOD0, while `tinynes.h` and `pad_test` expose decoded controls over UART. The two-controller simulation, both SoC test modes and the firmware build passed. The seed-3 FPGA image `4d1b27e8d8e4969ebe66bd132ae3374cc327fafd63e1506a0e6bd97e09810d5d` passed bus timing at 77.64 MHz and pixel timing at 80.85 MHz and loaded to SRAM through the FTDI one-wire debugger. On PMOD0 pins 1, 7, 5 and 6, the user's color-verified Classic Controller Pro returned ID `01 00 A4 20 01 01` at the default about-100-kHz rate; PAD1 reported thousands of successful samples with zero I2C failures, and changing face, D-pad, shoulder, system, stick and trigger values. The user confirmed that the reported values matched their actions. The program's final exit line was not captured because the host test was interrupted for a pause after the live pass; the other three buses were simulated but not populated with controllers. The README and PMOD-007 and WII-001 record the wiring and measured behavior. The core-syntax audit passed.

#### Next Steps:

Make FCEUmm playable by feeding the pad registers into its input callbacks and running the emulator continuously, then add sound playback. The user requested two-wire mode for future firmware updates because the FTDI one-wire path is slow; the current AE350 upload tool only uses the one-wire UART, so a two-wire transport is still needed before that preference can be used for TinyNES program uploads. The three unused controller buses and other extension variants remain available for later hardware checks.

#### Files Modified:

- README.md
- firmware/apps/pad_test/Makefile
- firmware/apps/pad_test/main.c
- firmware/include/tinynes.h
- fpga/ae350_soc/ae350_soc.cst
- fpga/ae350_soc/ae350_soc.sv
- fpga/ae350_soc/wii_pads.sv
- tests/ae350_soc_tb.sv
- tests/wii_pads_tb.sv
- tools/build_ae350_soc.sh
- tools/designs/ae350_soc.json

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 17 COMMIT Unreleased 2026-10-13T00:37:19-07:00

#### Coming From:

Unreleased ba2a269

#### Purpose:

Make FCEUmm playable with the Wii Classic Controllers and move deployment to two-wire mode, as the user directed, by loading the FPGA image with TinyTang's tangload and the AE350 programs through a new TinyTang pass-through.

#### Outcome:

At the user's direction `tools/build_ae350_soc.sh` now also writes `ae350_soc.bin`, packed by `tools/fs_to_bin.py`, which is TinyTang's MIT converter copied with credit; the rebuild reproduced the cycle-16 seed-3 `ae350_soc.fs` byte for byte as `4d1b27e8` and gave a 4,666,860-byte `.bin`, SHA-256 `ec3f0593f16be1748742510c9bb2c8b820ffd2edfc399b55e87af5d0c71e4bab`, exactly one eighth of its bits. The user declined a speed comparison with one-wire. TinyTang `9061ead`, its entry 46, adds the shell command `fpgapipe`, which passes the USB console through to the FPGA UART until the host drops DTR, and the BL616 was reflashed with it over two-wire and power-cycled. `tools/deploy_tinytang.sh` puts the `.bin` on the card with TinyTang's `tinytang_put.py`, turns the desk layer off so its frames do not reach the AE350's UART, and runs `tangload`, 17 s in all; `tools/load_ae350.py --tinytang` raises DTR, checks the console is at a prompt with the status probe, runs `fpgapipe` and then the unchanged load protocol, `--run-timeout 0` follows a program until it exits, and Ctrl-C closes cleanly. `nes_bench` built with `PLAY=1` into `build/firmware/apps/nes_play/` reads PMOD0 buses 1 and 2 as players 1 and 2 and runs until HOME and `-` are held; after the first run the user chose the Classic's B as the NES's A and Y as its B with A and X unused. The default benchmark's PC checksums were unchanged at `VIDEO=f2160661 AUDIO=b2bc0018`. On the board `rt_test` loaded through `fpgapipe` at 185.9 KB/s and passed, the shell answered at its prompt afterwards, and three play runs loaded at 186.5 KB/s and averaged 11.34 to 11.53 ms a frame, maximum 12.50 ms, with no frame over the period, `LATE=0`, `MISSED=0` and exit 0. The user played Castlevania on HDMI, called it perfect and confirmed every button. TOOL-022 and EMU-005 are new, and the README documents the two-wire flow, the `.bin` and the play build. The core-syntax audit passed.

#### Next Steps:

The next cycle should propose sound output for user approval: FCEUmm already mixes 48 kHz samples inside the frame, about 4 ms of each frame is spare, and the output path, HDMI audio in `video.sv` or an I2S module on PMOD1 since PMOD0 now carries the controllers, needs its source recorded first. The second controller bus is untested on hardware, and the DEV-016 workaround and the stale Apicula test count remain open.

#### Files Modified:

- README.md
- firmware/apps/nes_bench/Makefile
- firmware/apps/nes_bench/main.cpp
- tools/build_ae350_soc.sh
- tools/deploy_tinytang.sh
- tools/fs_to_bin.py
- tools/load_ae350.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 18 COMMIT Unreleased 2026-10-13T01:42:39-07:00

#### Coming From:

Unreleased a575c7b

#### Purpose:

Play FCEUmm's sound through a Digilent Pmod I2S2 on PMOD1, as the user approved, and follow the SD card's new layout under `/root` in the two-wire deploy.

#### Outcome:

`fpga/ae350_soc/i2s_out.sv` is a new EXTS unit at `0xe8050000` that counts MCLK (12.5 MHz), SCLK and LRCK from the 75 MHz bus clock, so it adds no clock to the clock network, sends 48,828.125 Hz I2S to the CS4344 within DS613F2's 256x limit of 50 kHz, and feeds it from a 2,048-pair block-RAM FIFO with level, underrun, frame and drop counters; `ae350_soc.sv` and `ae350_soc.cst` put it on PMOD1 pins W19, F19, E22 and E21, and `firmware/include/tinynes.h` names its registers. `tests/i2s_out_tb.sv` decodes SDIN as the DAC does and caught seven planted faults, and the SoC testbench's pipelined master found a STATUS read in a DATA write's data phase missing the write, which `level_next` fixed and the unit test now checks; both SoC testbench modes passed. The first seed-3 build failed pixel-clock hold, and a 16-seed sweep then ran without `NPNR_GOWIN_CLK_FIRST` applied because Yosys had named the bus clock net `audio.clk` after the new instance; the build script's check caught it at seed 13, the instance was renamed `sound`, `tools/sweep.py` now fails such runs, and the repeated sweep was 12 of 16 clean. The seed-12 image, now the default, is `ae350_soc.fs` SHA-256 `7cc7acb95af25665e3bb9de945c8a60efce0863e1bf799a4d02fcea3c821c44b` and `ae350_soc.bin` `2cbcc063005e96c79aa4a3b302f86ea2f52daf5890b7f79c40ef6998b9d0f7c9`, bus Fmax 84.84 MHz and pixel Fmax 85.73 MHz. The user moved the card's folders under `/root`, so `tools/deploy_tinytang.sh` now writes `/root/cores/console138k/tinynes.bin` with TinyTang `f590643` (its entry 47) on the board. In two-wire mode `firmware/apps/audio_test/` measured 48,827.968 Hz, played five seconds with no underrun or drop, and the user heard 1 kHz left and 2 kHz right. The game was silent: nes_bench's own driver had never set FCEUmm's APU channel volumes, which `FCEUI_Initialize` leaves at 0, so every sample since entry 15 was zero; `firmware/apps/nes_bench/fceu_settings.c` now sets them to 256 as the libretro driver does. The benchmark then ran at 153.5 percent with its checksums matching the PC build, now `VIDEO=f2160661 AUDIO=4512be2f`, and the `PLAY=1` build, which runs FCEUmm at 48,909 Hz so a frame makes one HDMI frame's samples and steers the FIFO level by one sample a frame, played 5,866 frames at 147.9 percent with no underrun or drop and reports the pairs sent and played and the frames shown; the user said it looked and sounded perfect and closed the cycle. Two things seen this cycle are unexplained: one earlier play run overflowed the FIFO (437 drops in 1,582 frames) while two others did not, and with this image the monitor twice failed to wake or flickered, recovering after the USB cable was unplugged or the board power-cycled, while `video_test` read the picture correct inside the FPGA. AUD-001, PMOD-008 and EMU-006 are new, EMU-004, EMU-005 and DEV-016 are revised, and BLE-012, DEV-006, TCTL-006, TDESK-011, TOOL-017 and TOOL-022 follow the card's new paths. The README documents the unit, its test, the play build's sound and the corrected benchmark. The core-syntax audit passed.

#### Next Steps:

If the HDMI loss returns, the next cycle should first run the board with the I2S2 removed and then with another clean seed to tell the I2S clocks beside the HDMI port from the placement, and should watch the play build's PUSHED, PLAYED and VBL figures for a repeat of the FIFO overflow; otherwise the next cycle should propose the next step for user approval, such as loading cartridges from `/root/data/nes` instead of building one into the program, or player 2.

#### Files Modified:

- README.md
- firmware/apps/audio_test/Makefile
- firmware/apps/audio_test/main.c
- firmware/apps/nes_bench/Makefile
- firmware/apps/nes_bench/fceu_settings.c
- firmware/apps/nes_bench/main.cpp
- firmware/include/tinynes.h
- fpga/ae350_soc/ae350_soc.cst
- fpga/ae350_soc/ae350_soc.sv
- fpga/ae350_soc/i2s_out.sv
- tests/ae350_soc_tb.sv
- tests/i2s_out_tb.sv
- tools/build_ae350_soc.sh
- tools/deploy_tinytang.sh
- tools/designs/ae350_soc.json
- tools/sweep.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 19 COMMIT Unreleased 2026-10-13T02:06:43-07:00

#### Coming From:

Unreleased 710d52e

#### Purpose:

Make a `.nes` file opened on TinyTang's desktop play on TinyNES and return to the desktop, as the user approved, with the play build taking its cartridge from the card instead of having one built in.

#### Outcome:

`firmware/apps/nes_bench/main.cpp` built with `PLAY=1` no longer links a cartridge: it allocates a 2 MiB buffer, prints `TinyNES WANT <address> <bytes>` and receives one more image in the load protocol through the boot ROM's own `firmware/boot/load.c`, compiled into the program unchanged, holding `TNR1`, the length and the `.nes` file, and fails with `TinyNES NES BAD CART` if none arrives in 30 s. `tools/load_ae350.py --file` answers that request, and from the PC it sent Castlevania (USA) (Rev A) in 0.71 s and the game started with good video and audio. TinyTang `121d334` (its entry 48) adds `ae350run`, which does the same from the card, and a TinyDesk rule that runs `/root/scripts/open/<ext>.tdsh` with `FILE` set for an opened file. `scripts/open/nes.tdsh` loads the core, runs `ae350run /root/ae350/tinynes-play.elf "$FILE"` and reloads the desktop core, and `tools/deploy_tinytang.sh` now installs the player stripped of debug sections, 840,516 bytes with SHA-256 `414aa0530c2d440e595ae57cc5405f7016b028579a259463bec64e371876e303`, and the script beside the unchanged seed-12 image `2cbcc063`, and no longer turns the desk layer off, which had left the screen blank after the first test's return until the user typed. Started from the shell, the launcher loaded the 625,292-byte player and Castlevania (USA) (Rev 1) from `/root/data/nes`, CRC `12a6cb14`, which ran 2,400 frames at 156.8 percent with `LATE=0`, `MISSED=0`, no underrun or drop, exited 0 and returned to the desktop core; the user then double-clicked a `.nes` file on the desktop, played, returned to the desktop and passed the cycle. The default benchmark and PC builds are unchanged. During the cycle the user saw the picture and sound turn glitchy, with a repeating pattern, after a PC-driven run whose tool had closed the port while the game kept running; the cause is not investigated and it is recorded with the HDMI fault of entry 18. TOOL-022 and EMU-005 are revised and the README describes the cartridge request, `--file` and playing from the desktop. The core-syntax audit passed.

#### Next Steps:

The next cycle should be proposed to the user; open items are the patterned glitch and the HDMI loss of entry 18, which should first be tried with the I2S2 removed and with another seed, battery saves to the card, player 2, and the 30-second cartridge wait and 300-second silence limit if a slow card or a quiet program ever trips them.

#### Files Modified:

- README.md
- firmware/apps/nes_bench/Makefile
- firmware/apps/nes_bench/main.cpp
- scripts/open/nes.tdsh
- tools/deploy_tinytang.sh
- tools/load_ae350.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 20 COMMIT Unreleased 2026-10-13T02:16:00-07:00

#### Coming From:

Unreleased 97dcd60

#### Purpose:

Record, for an agent handoff, the investigation and the design for swapping between TinyDesk and a running NES game with a tap of HOME or F12, which the user asked for as the next cycle.

#### Outcome:

The user asked that one tap of HOME on the Wii controller or F12 swap the picture between TinyDesk and the NES game. TinyTang draws TinyDesk inside the FPGA core with its desk-layer frames, which the TinyNES core does not carry, so two options were put to the user: giving the TinyNES core its own desk layer (A) or swapping cores with an FCEUmm save state, 10 to 15 s a swap (B). The user chose A, confirmed it is how TinyTang's patched nestang core works, and asked that the game keep running behind the desktop as nestang's does. Reading TinyTang `121d334` showed that its F12 handling flips the overlay, that its desk task also flips it on a rising edge of LB (`0x400`) in a core's `0x03` joypad report and drives the desktop pointer from the same word, so a TinyNES core that reports the Wii pad that way with a HOME tap as LB needs no TinyTang change for either toggle; the cell format and frames are recorded as PROT-010. TinyTang's desk-layer HDL and nestang's font are GPL-3.0-only, so TinyNES must write its own. The resulting design, a loader and link mode for UART1 so program images never reach the frame parser, a frame parser answering core ID `0x4E`, a joypad and framed-text sender, an 80x45 layer and public-domain font held on the pixel clock, the player setting link mode after its cartridge and gating its input while the overlay is up, and `ae350run` handing over the UART on `TinyNES LINK`, is in `docs/desk-layer-plan.md`. It was presented to the user, who asked for this handoff before confirming it; nothing was built or deployed. The core-syntax audit passed.

#### Next Steps:

Present the design in `docs/desk-layer-plan.md` to the user for approval and, if approved, implement it as one cycle across TinyNES and TinyTang with its simulations, a seed sweep with `NPNR_GOWIN_CLK_FIRST` enforced, and the board tests the document lists; the HDMI loss and patterned glitch of entries 18 and 19 remain open.

#### Files Modified:

- docs/desk-layer-plan.md

#### Status:

- Build: N/A
- Deployment: N/A
- User Test: N/A

---

## 21 COMMIT Unreleased 2026-10-13T08:47:19-07:00

#### Coming From:

Unreleased 2146d46

#### Purpose:

Swap the HDMI picture between a running NES game and TinyDesk with one tap of HOME on the Wii controller or F12, the game running on behind the desktop, as the design in `docs/desk-layer-plan.md` that the user approved describes.

#### Outcome:

`fpga/ae350_soc/exts_uart.sv` gained a link mode, set by a new mode register at `0xe8000014` whose write completes only once everything before it has been sent: in it received bytes go to the new `fpga/ae350_soc/desk_link.sv` instead of the receive buffer, and CPU bytes become text frames. `desk_link.sv` parses TinyTang's 0xAA frames, answering core ID 0x01 with 0x4e and taking 0x08, 0x13, 0x14 and 0x15, and sends whole frames: the ID, the `0x03` joypad report from Wii pad 1 (new `pad0_held` output of `wii_pads.sv`) every 20 ms on change and every 500 ms, with LB held 260 ms after a HOME tap, and the CPU's text as type 0x20 frames cut at a line feed, 128 bytes or 2 ms of quiet; its status is at `0xe8000018`. `video.sv` draws the 80x45 layer of 16x16 cells over the whole picture from the next vertical blank, its cell store and font on the pixel clock only; the font is the public-domain font8x8, fetched at `8e279d2` by `tools/fetch_font8x8.sh` and written as `fpga/ae350_soc/desk_font.hex` by `tools/gen_desk_font.py` (PROV-008). Yosys first mapped the cell store to 4Kx4 DPB blocks, a mode never shown to work in the video unit, so it is now five 9-bit slices in DPX9B mode and `tools/build_ae350_soc.sh` fails on a video block RAM width that is not a multiple of 9. The boot ROM writes loader mode first, `nes_bench`'s `PLAY=1` player prints `TinyNES LINK` and sets link mode after its cartridge and gives the game no input while the layer is shown, and `tools/load_ae350.py` unwraps the text frames after that line; TinyTang `ccbf8a7` (its entry 49) makes `ae350run` hand the link back to the desk layer at `TinyNES LINK`. The new `tests/desk_link_tb.sv` passed its eight checks, and planted faults in the length byte, the receive routing, the mode write's wait, the busy status, the tap, the cell packing, the cursor, the length check, the refresh and the quiet flush each failed it, while removing the redundant loader-mode guards or the sender's one-clock gap did not; it crashed both installed vvp versions until its tasks were made static. `tests/video_tb.sv`, extended with the layer over the bars and over the picture, the picture after it and a rewritten cell, passed with no mismatch, as did both `ae350_soc_tb` modes and `tests/test_loader_host.py`. A 16-seed sweep with `NPNR_GOWIN_CLK_FIRST` enforced was 6 of 16 clean against 12 of 16 in entry 18, every failure pixel-clock hold on block RAM inputs; seed 5, now the default, built with every check passing at bus Fmax 80.85 MHz and pixel Fmax 86.17 MHz, `ae350_soc.fs` SHA-256 `998fb9ba66ce8155d309fe4615f4bd8cc489e697cc662f81f58e4f835a1efa41` and `ae350_soc.bin` `a9cd9a781c28fa024cd2ce30af9dd3a25e1a1817ce463cc4ecc289cf11ac9db6`, using 9.9 percent of the LUTs and 66 of 340 block RAMs. It was deployed in two-wire mode with `tools/deploy_tinytang.sh` beside the 840,580-byte stripped player `b7f70131`, and `video_test` on it printed `PIXELS=468378 WANT=468378 BITS=ffff` and `LATE=0` over 600 frames. The user double-clicked a `.nes` file, tapped HOME to bring TinyDesk over the running game and back, and reported that all tests passed. PROT-010 is now VERIFIED, PROV-008 is new, and TOOL-020, TOOL-022 and EMU-005 are revised; the README documents link mode, the frames, the layer and the tests. The core-syntax audit passed.

#### Next Steps:

The next cycle should be proposed to the user; open items are the halved clean-seed rate from pixel-clock hold, which a register stage or placement constraint on the cell store's write path might restore, the HDMI loss and patterned glitch of entries 18 and 19, the DEV-016 workaround and the stale Apicula test count, battery saves, player 2, and the lead in TinyTang's PROT-010 that a core-ID probe during a linked game could drain the exit line.

#### Files Modified:

- README.md
- docs/desk-layer-plan.md
- firmware/apps/nes_bench/main.cpp
- firmware/boot/main.c
- firmware/include/tinynes.h
- fpga/ae350_soc/ae350_soc.sv
- fpga/ae350_soc/desk_font.hex
- fpga/ae350_soc/desk_link.sv
- fpga/ae350_soc/exts_uart.sv
- fpga/ae350_soc/video.sv
- fpga/ae350_soc/wii_pads.sv
- scripts/open/nes.tdsh
- tests/desk_link_tb.sv
- tests/video_tb.sv
- tools/build_ae350_soc.sh
- tools/designs/ae350_soc.json
- tools/fetch_font8x8.sh
- tools/gen_desk_font.py
- tools/load_ae350.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 22 COMMIT Unreleased 2026-10-13T09:32:40-07:00

#### Coming From:

Unreleased 838f2ed

#### Purpose:

Find where in the video path the intermittent HDMI lines and signal loss that the user sees only on TinyNES arise, as the user approved, with a diagnostic player and no change to the FPGA image.

#### Outcome:

`firmware/apps/nes_bench/main.cpp` built with `PLAY=1 DIAG=1` (new in its Makefile, into `build/firmware/apps/nes_diag/`) plays as the normal player and, since the A25's cycle counter and the pixel clock both come from the 50 MHz oscillator, timestamps every vertical blank it sees while waiting and checks each period against 12,500,000 core cycles, compares the video unit's `PIXELS` and `BITS` with its own count of each frame it handed over, and prints a summary each second and a line at once for each press of X or Start on a controller; the normal player is unchanged, 562,248 bytes of code as before. The user reported that TinyTang's open-flow `desktop.bin`, nestang and Tang-Phosphor never show the fault on the same monitor and cable, that it happens with only a power cable as well as with the PC attached, perhaps 10 to 20 percent more with the PC, and that sound stays clean. On the seed-5 image of entry 21, loaded by the agent in two-wire mode with Castlevania (USA) (Rev 1), a 559 s session of 33,841 frames ran with the user marking lines with X at 88 to 117 s and reporting flicker and instability on a paused frame at about 143 s that cleared during the pause, and through it every period was 12,500,000 cycles within plus or minus 100, all 33,825 checked frames matched `PIXELS` and `BITS`, and `LATE`, `MISSED`, underruns and drops were 0; the program exited 0 at 141.5 percent speed. So the SDRAM, the line buffers, the pixel counters and the pixel clock's frequency and lock as seen per frame are ruled out, and the fault lies after the pixel stage. The routed design shows the 371.25 MHz serial clock crossing the die from `hdmi_pll` at PLL_L[3] on 23 E8 hops of general routing into the right side's HCLK, the serialisers' PCLK on global branch GB20, and the clock lane driven straight from `pix_clk`; a cooling test was not conclusive. The user asked whether the board has a temperature sensor: none is on record, and the FPGA's on-die ADCs, which have a temperature mode, cannot yet be configured by the open flow (DEV-019). DEV-018 records the defect and what is ruled out, and the README describes the diagnostic build. The core-syntax audit passed.

#### Next Steps:

The user will run a heating and cooling test with a contact sensor on the FPGA under the diagnostic player; then the proposed fix cycle compares the routed HDMI clocks of TinyTang's fault-free open-flow desktop core with TinyNES's, changes TinyNES's serialiser clocking to match or to the vendor's arrangement, and checks each candidate in long sessions with the diagnostic player while the user watches.

#### Files Modified:

- README.md
- firmware/apps/nes_bench/Makefile
- firmware/apps/nes_bench/main.cpp

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 23 COMMIT Unreleased 2026-10-13T09:50:48-07:00

#### Coming From:

Unreleased b247c13

#### Purpose:

Test whether the HDMI fault of DEV-018 depends on temperature, as the user proposed, and compare TinyNES's HDMI clocking with TinyTang's fault-free open-flow desktop core, before choosing a fix.

#### Outcome:

With the seed-5 image of entry 21 and the `DIAG=1` player of entry 22 loaded by the agent in two-wire mode, the user heated the FPGA's surface with a hair dryer from 32.8 C to 41.1 C, read with a contact sensor, and the picture glitched badly within one to two minutes, too fast to mark with X; cooled with air to 28 C and then 25.1 C it stayed clean for the rest of the 298 s session, which exited 0, and every internal check (frame period within 100 core cycles of 12,500,000, `PIXELS` and `BITS` of every frame, `LATE`, `MISSED`, underruns and drops) stayed clean throughout, as in the first session. Entry 22 overstated what `PIXELS` and `BITS` show: they catch a pixel turning zero or non-zero and a bit stuck within a frame, not one non-zero value changed for another, which DEV-018 now says. The seed-5 netlist feeds six pixel-clock pins, those of five `pixel1` bits and two `nx` bits, over general routing instead of the global network. A rebuild of TinyTang's desktop core at seed 2 with the current forks failed one hold check, so it is not the card's `desktop.bin`, but its routed netlist clocks the OSER10s exactly as TinyNES does, the HDMI PLL at X1Y81 with the 371.25 MHz clock over 22 E8 hops, PCLK on GB20 through `SPINE26 <= CBRIDGEOUT_BOTTOM2`, the clock lane straight from the pixel clock, and 17 pixel-clock pins off the global network, so neither the serialiser clocking nor off-network pixel flip-flops alone explains why only TinyNES shows the fault, and the lead is that TinyNES's busy A25 and SDRAM run the die hotter, to a margin the shared open-flow clocking has. The user did not want to change the plan now and asked that the test be logged for later. The user asked whether the board has a temperature sensor during the cycle; DEV-019 of entry 22 holds the answer. DEV-018 is revised. The core-syntax audit passed.

#### Next Steps:

The user has set the HDMI fault aside for other work. When it is taken up, the agreed first step is three tests with no build: `desktop.bin` and nestang heated to 45 to 50 C while the user watches, and the idle surface temperature of each core; if the open-flow desktop core also fails when hot and nestang does not, the fix cycle moves TinyNES's HDMI clocking to the vendor's arrangement (the serial clock on dedicated wiring from a nearby PLL, the clock lane through an OSER10), and if neither fails it looks at TinyNES's own pixel path, each candidate heat-tested with the `DIAG=1` player.

#### Files Modified:

None.

#### Status:

- Build: N/A
- Deployment: PASS
- User Test: PASS

---

## 24 COMMIT Unreleased 2026-10-13T10:29:16-07:00

#### Coming From:

Unreleased e48fa9e

#### Purpose:

Measure what the open-flow build and Gowin's analysis say about the HDMI output stage's timing at the ends of the temperature range, as the user approved as Phase A of the HDMI fix cycle, and record the board and toolchain facts the user asked about.

#### Outcome:

The aquasock Apicula fork times GW5AST-138C cells at C1/I0, derived as 1.25 x the `.tm`'s C2/I1 table per DS1239E and not yet checked against Gowin's analysis, with family-generic routing delays and no IO, IOLOGIC or PLL timing, so nextpnr times nothing into or out of an OSER10 (TOOL-023). nextpnr's Gowin back end could not reload a routed design (an `array2d` assertion), so the seed-5 place and route was repeated with `--sdf` and routed all 33,687 nets as the board image did; the new `tools/hdmi_timing.py` read its delays and gave the encoder-to-OSER10 paths at least 10.52 ns of setup and 0.46 ns of hold slack at C1/I0, 0.32 ns of hold on the fork's fastest table, with the OSER10's own requirements unmodelled, the 371.25 MHz clock 9.86 ns from `hdmi_pll` to the OSER10s over general routing with no duty-cycle distortion modelled, PCLK 0.644 ns behind FCLK plus the CLKDIV's unmodelled delay, and six pixel-clock pins off the global network. The new `tools/gowin_hdmi_timing.sh` built the same RTL and constraints with Gowin EDA 1.9.11.03 headless, as a measurement only, in about a minute; in Gowin's placement, setup analysed at Slow 0.855 V 0 C and hold at Fast 0.945 V 85 C, the pixel clock reached 85.88 MHz with no violation, the encoder-to-OSER10 paths had 7.9 to 8.3 ns of setup and over 0.56 ns of hold slack, the OSER10 reset from `pix_reset_sync` failed recovery against the serial clock by up to 5.80 ns, a one-time release at power-up, no FCLK-to-PCLK check was made, and the bus clock failed at 61.65 MHz. Every timed data path into the OSER10s thus has margin at both ends in both flows, leaving the serial clock's waveform after 9.86 ns of general routing and the OSER10s' own requirements as the lead for DEV-018. The user asked whether the board has a temperature sensor: BRD-013 records that Sipeed lists none, a fixed 5 V fan connector and two ADC inputs, beside DEV-019. TOOL-023 and BRD-013 are new, DEV-018 is revised, and the README describes both tools. No image was built for the board. The core-syntax audit passed.

#### Next Steps:

Phase B, approved by the user: decode how Gowin's build routes the serial clock, move the HDMI PLLs beside the HDMI bank if the fork can route that, send the TMDS clock lane through a fourth OSER10, release the OSER10s' reset in the serial clock's domain, then sweep, build, report the open-flow numbers of `tools/hdmi_timing.py` to the user, and accept only if the `DIAG=1` player stays clean with the package surface heated to 55 to 60 C.

#### Files Modified:

- README.md
- tools/gowin_hdmi_timing.sh
- tools/hdmi_timing.py

#### Status:

- Build: N/A
- Deployment: N/A
- User Test: N/A

---

## 25 COMMIT Unreleased 2026-10-13T11:00:47-07:00

#### Coming From:

Unreleased cf55509

#### Purpose:

Cure the heat-dependent HDMI fault of DEV-018 by shortening the serial clock's route and serialising the clock lane, as Phase B of the cycle the user approved, and show the user the open-flow timing of the new output stage.

#### Outcome:

`fpga/ae350_soc/ae350_soc.cst` moves `hdmi_pll` from PLL_L[3] to PLL_R[3], row 81 beside the CLKDIV's HCLK block, and `hdmi_pll27` from PLL_L[1] to PLL_R[1], and `fpga/ae350_soc/ae350_soc.sv` sends the TMDS clock lane through a fourth OSER10 with `1111100000` per pixel instead of driving it from the pixel clock; both SoC testbench modes passed. The planned release of the OSER10 reset in the serial clock's domain was left out, because it would need fabric flip-flops on the 371.25 MHz clock and the release happens once at power-up. A 16-seed sweep with `NPNR_GOWIN_CLK_FIRST` enforced was 8 of 16 clean against 6 before, all failures pixel-clock hold, with the serial clock's route 15 to 20 pips instead of 35 to 40, and seed 10, now the default, built with every check passing at bus Fmax 83.14 MHz and pixel Fmax 86.93 MHz, `ae350_soc.fs` SHA-256 `6b0c433a5c7e0783d6a06e557f9878ffb9cfac4d432072f2acf8b5dbb62640a8` and `ae350_soc.bin` `bafc2cf2ea79fc9e36a948b948afda62df07b9c5698da738d46eaaeb516ddfcf`. A `--sdf` re-run routed all 33,748 nets identically, and `tools/hdmi_timing.py` gave the serial clock 2.12 ns from the PLL to the OSER10s against 9.86 ns, encoder-to-OSER10 hold slack 0.756 ns against 0.46 (0.521 against 0.317 on the fork's fastest table), setup slack 10.45 ns, and three pixel-clock pins off the global network against six; the agent showed the user these figures. The image was deployed in two-wire mode with `tools/deploy_tinytang.sh` and `video_test` printed `PIXELS=468378 WANT=468378 BITS=ffff` and `LATE=0`. At the user's request both Pmods were unplugged, and the `DIAG=1` player of entry 22 ran Castlevania's title screen for 308 s while the user heated the package with a hair dryer to 57 C and then 62 C, where the old image had failed at about 41 C, and the picture stayed perfect with every internal check clean; the user then let it cool, and the session ended when the board's USB disconnected. In the session's first second the sound FIFO dropped 344 samples, with none after, like the overflow entry 18 left unexplained. DEV-018, BRD-011 and TOOL-023 are revised, and the README describes the HDMI clocking. The core-syntax audit passed.

#### Next Steps:

Repeat the heat test to 55 to 60 C with the Wii controller on PMOD0 and the I2S2 on PMOD1, which would settle that the PLL move and not the missing Pmod load cured the fault and let DEV-018 be closed; then the next cycle should be proposed to the user, with the startup sound FIFO overflow, the OSER10 reset's recovery against the serial clock, the halved clean-seed rate and the other items of entry 21 open.

#### Files Modified:

- README.md
- fpga/ae350_soc/ae350_soc.cst
- fpga/ae350_soc/ae350_soc.sv
- tools/build_ae350_soc.sh

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 26 COMMIT Unreleased 2026-10-13T11:52:41-07:00

#### Coming From:

Unreleased 046c2f0

#### Purpose:

Correct the project-control records that read this project's HDMI fault as peculiar to TinyNES, after the user saw TinyTang's open-flow desktop image glitch while the board was hot, and re-check the source cited behind the HDMI pin record.

#### Outcome:

TinyTang's core-log entry 50 records that the user saw the card's open-flow desktop image glitch while the Tang was hot and recover on cooling, and TinyTang commit a6db9eb applies this project's temperature fix to that core as an unproven candidate, so `DEV-018` was revised in place: its statement no longer says the user's other cores never show the fault and instead names the desktop core's hot-board glitch, with nestang and Tang-Phosphor untested hot; its consequence moves the lead from TinyNES running its die hotter to the shared open-flow HDMI clocking margin itself, records that the desktop core now carries the same unbuilt fix, and keeps the Pmod heat test and the OSER10 reset's recovery failure against the serial clock open; a source citing TinyTang's `.ai/core-log.md` entry 50 and `fpga/desktop/desktop.cst` at `a6db9eb` was added, and the revision was noted in verification. `BRD-011`'s source citation to TinyTang's `fpga/desktop/desktop.cst` was re-read at `a6db9eb` and its TMDS pins are unchanged, which its verification now says. `TOOL-017` claimed nothing about the clock network needs changing for HDMI; that claim is now scoped to the dark-HDMI fault it was found for, since the later thermal fault required the HDMI PLL move and the CLKDIV's pinned site, and TinyTang's `a6db9eb` applies the same arrangement to the desktop core. The risk note in `docs/desk-layer-plan.md` said the HDMI loss was unexplained; it now names the serial clock's long general route and `DEV-018` as the cause cured in entry 25, leaving only the patterned glitch of entry 19 open. No build, deployment or hardware test applies to this cycle. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed and no settled log entry was rewritten, and validated this entry's six sections, sequential number, prose, Status values and the log's 100-entry limit.

#### Next Steps:

Resume when the user requests it; the open work is unchanged. The heat test of the seed-10 image with the Wii controller on PMOD0 and the I2S2 on PMOD1 would close `DEV-018`, beside the OSER10 reset's recovery against the serial clock, the halved clean-seed rate, the startup sound FIFO overflow, the DEV-016 workaround and the stale Apicula test count. On the TinyTang side the desktop core's thermal fix is an unproven candidate, so a route that keeps its main `clk` on fabric with the pixel and serial clocks on valid HCLK resources has to be found before the card's desktop image is replaced.

#### Files Modified:

- docs/desk-layer-plan.md

#### Status:

- Build: N/A
- Deployment: N/A
- User Test: N/A

---

## 27 COMMIT Unreleased 2026-10-13T14:58:05-07:00

#### Coming From:

Unreleased e39380f

#### Purpose:

Repeat the cycle-25 heat test with the Wii controller on PMOD0 and the I2S2 on PMOD1, the acceptance condition of entry 24, to settle that the serial-clock PLL move and not the absent Pmod load cured the HDMI fault and to close DEV-018.

#### Outcome:

The seed-10 image (`ae350_soc.bin` bafc2cf2) and the `PLAY=1 DIAG=1` player were deployed in two-wire mode with `tools/deploy_tinytang.sh`, and Castlevania (USA) (Rev 1), CRC-32 `12a6cb14`, was played through `tools/load_ae350.py --tinytang` with both PMOD sockets loaded: the Wii Classic Controller on PMOD0, which the player reported as `PAD1=classic`, and the Pmod I2S2 on PMOD1, whose sound the user heard throughout. The package idled at 30.9 C, the game started at 31.9 C, the user heated it to a peak of 69.8 C and then let it fall to 35.4 C, and across 552 one-second samples of frames every frame's `PIXELS` and `BITS` matched the player's own count and `LATE`, `MISSED`, audio underruns and FIFO drops were all zero; four samples' vertical-blank periods read 104 core cycles against the 12,500,000-cycle frame, 4 cycles or 8 ppm outside the +-100 polling window, which is the instrument's noise floor. No `MARK` line was written, the user saw no glitch at any temperature and accepted the result, and the log is `build/diag/session4.log` (not committed). The same image had reached only 62 C in entry 25 with both Pmods unplugged, so the absent Pmod load is ruled out as the reason the earlier image failed. A cold test was attempted with canned air, which could not take the package below about 32 C, at or above its own 30.9 C idle, so the sub-ambient corner is recorded as unmeasured rather than passed. DEV-018 now carries the accepted result, drops its pending Pmod run, and moves from INFERRED to VERIFIED, the mechanism remaining a lead. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed and no settled log entry was rewritten, and validated this entry's six sections, sequential number, prose, Status values and the log's 100-entry limit.

#### Next Steps:

DEV-018 is closed, so the next cycle should be proposed to the user from what remains: the OSER10 reset's recovery against the serial clock, which TOOL-023 records as failing Gowin's check by up to 5.80 ns, the halved clean-seed rate of 8 of 16 whose failures are all pixel-clock hold, the startup sound FIFO overflow, the patterned glitch of entry 19, the DEV-016 workaround and the stale Apicula test count. The sub-ambient corner needs a cold source the user does not have, so it stays recorded as unmeasured rather than as a pass.

#### Files Modified:

- README.md

#### Status:

- Build: N/A
- Deployment: PASS
- User Test: PASS

---

## 28 COMMIT Unreleased 2026-10-13T15:53:20-07:00

#### Coming From:

Unreleased 75afcf5

#### Purpose:

Carry TinyTang core-log entry 52 into this project's records: the desktop core's thermal fix is validated with its main PLL on the measured-good clock-plane wire, and the shared build recipe is recorded as not reproducing the card's image.

#### Outcome:

TinyTang's core-log entry 52 records that the card's desktop image came up distorted on a hot boot at about 55 C, that moving its main PLL from PLL_L[0] to PLL_R[0] puts `clk` onto the measured-good clock-plane wire TRPLL0CLK0 instead of the dead TLPLL0CLK0, and that the user then held the desktop picture clean to 60.4 C. Three records here were revised from it. `DEV-018` recorded the desktop core as carrying the same fix unproven; it now records the fix as proven on that board, naming TinyTang commit 9f3ddfb and the two temperatures. `DEV-009` gained the other half of its rule, in consequence and as a revision: a left-side PLL's plane wire is entered by the router and leaves the core dead, while the right side's TRPLL0CLK0 runs the same core. `TOOL-017`, this project's carried copy of the desktop core's record, now states the validated fix and adds that its own build recipe does not reproduce the card's image, because apycula's chipdb is an untracked build product and nothing on this machine regenerates the 2026-10-11 database; the evidence is that an era-matched rebuild, the fork at 93761f4 with that era's own nextpnr, gives `keyboard_link.clk` at 119.29 MHz against the recorded 145.69 and routes `clk` on global resources. That finding is what this project's entries 26 and 27 turned on, and it is now recorded where the desktop core's build is described. No build, deployment or hardware test applies to this cycle. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed and no settled log entry was rewritten, and validated this entry's six sections, sequential number, prose, Status values and the log's 100-entry limit.

#### Next Steps:

Nothing is outstanding here; the desktop core's remaining work is TinyTang's, chiefly promoting the tested image to the card's desktop.bin and pinning or vendoring the chipdb so a build of record can be rebuilt. This project's own open work is unchanged: the OSER10 reset's recovery against the serial clock, the halved clean-seed rate, the startup sound FIFO overflow, the patterned glitch of entry 19, the DEV-016 workaround and the stale Apicula test count.

#### Files Modified:

None.

#### Status:

- Build: N/A
- Deployment: N/A
- User Test: N/A

---

## 29 COMMIT Unreleased 2026-10-13T23:52:01-07:00

#### Coming From:

Unreleased fa557f4

#### Purpose:

Record a handoff so the next agent starts from the project's records rather than reconstructing this session: where the release stands, what is committed and where, and what remains before it is published.

#### Outcome:

The release card was validated on hardware end to end and the defects that validation found are fixed, committed and pushed. The card's assembly is `release_SD`, zipped as `release_SD-0.1.0-draft-20261013.zip`, and the run covered boot, the USB console, pairing a keyboard and mouse over Bluetooth, the desktop, Phosphor and TinyNES, with the user accepting the desktop, the oscilloscope, the I2S2 audio, unwrapped `help` output, working function keys and the corrected boot narration. Three firmware defects were fixed in TinyTang as core-log entry 57 and pushed at commit `26e2b97`: the `help` list wrapped because a line costs two columns of indent, a ten-column name field and one space before the help text, leaving 67 characters at 80 columns, so seven of 116 commands were shortened and `tools/check_help_width.py` now gates the budget; F1-F11 were mapping to nothing because `ports/bl616/tang_key.c` translates HID usages into the ANSI bytes the desktop parses, so a `fkey_sequences` table now emits `ESC [ 11~` through `ESC [ 23~` while F12 stays `TANG_KEY_USAGE_TOGGLE` for the desktop/core swap; and the boot narration could not name the core where it had been placed, because the board has no raster until `tangload` programs a core and `osd desk on` mirrors the console from that point forward rather than replaying it, so the name moved into the post-load line. The firmware built from that commit is 611520 bytes, sha256 `238cee62ce93fbf70d5332e03ea10e61776f1330afa059d99c0f60df1dc90c59`, identity `dba104c-dirty.17f81b2`, and the user flashed it and confirmed it; its identity keeps a `-dirty` suffix because `third_party/tinydesk` carries two patches the build applies on every configure, which TinyTang's `BUILDING.md` now records by digest as its entry 58. The larger fault was the card's AE350 player: `ef1502ed` is a `bench_stream=1` build that waits for the host to stream a file while the firmware only answers the file-request mailbox, so each side waited for the other and every track ended in `the AE350 did not start playing`; the card now carries the `bench_stream=2` player `c7a89035`, and a FLAC plays to 441000 samples at 44.1 kHz with zero underruns, the count Tang-Phosphor's record treats as its qualification. The PMOD arrangement is settled and written down: the Pmod I2S2 belongs on PMOD1, beside the HDMI port, declared as `0xc0 = 0x500`, and the Wii Classic Controllers are on PMOD0, beside the two USB-A ports, read from fixed pins per the NES core's own `ae350_soc.cst`, so a socket declared as I2S2 takes those pins away from the pads; declaring a socket with the module seated in the other silences the Line Out while the clock probe at `0xf8` and `0xfc` still reads normally, because that counter measures the clock and not the lanes. Tang-Phosphor's own bring-up document and play script stated the PMOD0 seating as the rule, which is where this session's detour came from, and both were corrected and pushed there as its entry 84 at commit `c261fcb`. Durable facts from the session are in TinyTang's reference as `TOOL-018`, `TOOL-019` and `TOOL-020`, and the release tree's README hash block was regenerated and verifies ten of ten. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed and no settled log entry was rewritten, and validated this entry's six sections, sequential number, prose, Status values and the log's 100-entry limit; TinyTang's `tools/check_core_log.py` was run against this log and reported every entry conforming.

#### Next Steps:

The next single action is to strip the sixteen commercial ROMs from `root/data/nes/` and re-zip the tree, because the card cannot be published with them. Then set the card's `tang.ini` to the tree's copy: the card still declares `pmod0 = i2s2` from an earlier edit and only played because a live `0xc0 = 0x500` poke was applied, which a reboot discards, so the PMOD will be silent again until the file is replaced, and the README's `tang.ini` hash line should be refreshed afterwards and `sha256sum -c` re-run. Publish with a `v0.1.0` tag on TinyTang, which per the syntax is a `VERSION` entry rather than a `COMMIT` one; TinyTang's `.ai/core.md` Releasing section is still empty, so the release notes are a decision before they are a task, and a final pass on a card built from the finished tree should confirm boot, pairing, the desktop, Phosphor and a cartridge. Two known defects are parked by the user's instruction rather than fixed: the release README's paragraph calling the AE350 player qualified states the opposite of what the hardware showed and belongs to the next build cycle, and `boot.tdsh`'s header comment still offers `nestang-menu.bin` for a rollback this release no longer ships. One loose end in project control: Tang-Phosphor's active log numbers its entries 67 to 83 while its own `core-syntax.md` says an active log begins at entry 1, so its numbering or its archive is out of step and TinyTang's checker cannot gate that repository until it is settled.

#### Files Modified:

None.

#### Status:

- Build: N/A
- Deployment: N/A
- User Test: N/A

---

## 30 COMMIT Unreleased 2026-10-14T01:18:14-07:00

#### Coming From:

Unreleased c28b0cc

#### Purpose:

Carry the release card's wording of `scripts/open/nes.tdsh` back into this repository, at the user's direction, so the script's example names a cartridge the release ships rather than a commercial one.

#### Outcome:

The release card's `root/scripts/open/nes.tdsh` differed from this repository's only in its usage comment, where the user had changed the example from `Castlevania (USA) (Rev 1).nes` to `nova.nes`, the GPL-3.0 Nova the Squirrel v1.0.6a cartridge the card carries in `root/data/nes/`. The card's file was copied over the repository's, the diff is that one comment line, and the repository copy is now byte-identical to the card's, SHA-256 `77be22ea29c98c413bc179cdeb46d4d8d5b2a8189dbd76ffbaf8efd043d144b0`. The script's behaviour is unchanged, so nothing was built, deployed or tested. TinyTang's `deps.conf` still pins this repository at `fa557f4`, which the user chose to leave until the `v0.1.0` tag. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed and no settled log entry was rewritten, and validated this entry's six sections, sequential number, prose, Status values and the log's 100-entry limit.

#### Next Steps:

None for TinyNES beyond the release itself: TinyTang re-pins this repository when it is tagged.

#### Files Modified:

- scripts/open/nes.tdsh

#### Status:

- Build: N/A
- Deployment: N/A
- User Test: N/A

---

## 31 COMMIT Unreleased 2026-10-14T13:46:31-07:00

#### Coming From:

Unreleased 9e1c027

#### Purpose:

Make NES battery saves work end to end on this board: settle the card's content layout, carry a cartridge's save RAM from the AE350 player to the card and back into the emulator, and repair the desktop's open handler, which had stopped launching a cartridge at all.

#### Outcome:

At the user's direction the card's content moved under `media/` (`nes`, `music`) with machine state under `saves/` and `states/`, checked by a 141-file manifest with no size or mtime drift and all 17 cartridges byte-identical, and the card's `tang.ini` reads `pmod0 = none`, `pmod1 = i2s2`. `firmware/apps/nes_bench/main.cpp` now asks the host for a battery-backed cartridge's save once the game is loaded (`TinyNES NVRAM WANT`) and receives it into the core's own `SaveGame[0]` through the boot ROM's load protocol, then emits it at exit as hex, with `TinyNES NVRAM SAVE` and `DONE` carrying its length and CRC-32, because in link mode the FPGA turns the CPU's bytes into TinyDesk text frames and that receiver drops carriage returns and ends lines on a line feed; `TinyNES LINK` moved after that request, since once link mode is on the host reads frames rather than lines, and `fceu_settings.c` gained `nes_bench_battery()`, exposing FCEUmm's `SaveGame[0]` and `SaveGameLen[0]` from the file that already carries the core's include path. The link loses a chunk at the start of a burst, so three throwaway lines precede the header and each 64-character line is followed by a wait for the link to be idle and a 4 ms pause; that is what made an 8192-byte save arrive whole. The save goes without the `TNR1` payload header the cartridge carries, because it is received straight into the core's save buffer, where a header occupies the first eight bytes and shifts every other byte by eight: the first attempt left `TNR1` and 8192 at the front of the save RAM, and because that shifted data was written back to the card and shifted again on the next load, every round trip made it worse, which is why the game showed an empty slot even after a fresh save. The desktop fault was separate: `scripts/open/nes.tdsh` never ran, which the new `/root/nes-open.log` line proved, and the board's `tang` command then reported one allocation refused since boot, 53 bytes for task `tdsh_script`, so the desktop path had run out of heap, in part because the save was held in a permanent 8 KiB static buffer; the save is now written out as it arrives with an incremental CRC, which returned 8192 bytes to the heap and restored the desktop. In TinyTang, `ae350run` serves and captures the save, `tools/tinytang_put.py` now quotes the remote path, which had been splitting a name with spaces down to its first word, and the Phosphor app reads `/root/media/music`. Against the result: the board resets on an `ebreak` assert in the Bluetooth controller task, crash record `mcause 0x30000003` with `btbleco` in its trail, the class BLE-018 records, which also explains USB dropouts earlier taken for cabling. The user loaded their save and played it. The core-syntax audit passed.

#### Next Steps:

Take up the Bluetooth assert first, since a reset during a save or a core load makes every hardware test unreliable. Then TinyTang's own cycle needs its log entry and commit for the `ae350run` save path, the receive-ring and frame-queue change, the Phosphor media path and the tool fix, none of which is committed there, and the save is still written at exit only, so a power-off mid-game loses it. The card also carries commercial ROMs and cannot be published as it stands, and the release still needs its `v0.1.0` tag.

#### Files Modified:

- README.md
- firmware/apps/nes_bench/fceu_settings.c
- firmware/apps/nes_bench/main.cpp
- scripts/open/nes.tdsh

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 32 COMMIT Unreleased 2026-10-14T16:00:57-07:00

#### Coming From:

Unreleased 9915766

#### Purpose:

Give TinyNES a settings file and a desktop app for it, and make the AE350's controller mapping come from that file rather than from the code.

#### Outcome:

The design is in `docs/tinynes-controls-plan.md`: an app in the approved four-tab layout (Input, Video, Audio, Saves) reading `/nes.ini` at the card root, the same shape as `/tang.ini` with an absent file or key meaning the current behaviour, global rather than per-game and usable with or without a game running, the user swapping between it and the game with F12 the way a MiSTer OSD works. `firmware/apps/nes_bench/main.cpp` now takes the mapping from a `pad_map` array indexed into a `PAD_BIT` table of the controller buttons it can tell apart, and asks the host for it with `TinyNES SETTINGS WANT <addr> <len>`, receiving it headerless into its own array exactly as a save is; the compiled-in default is the mapping this program has always had, so an absent answer changes nothing, and the analogue stick still steers the D-pad whatever the D-pad itself is mapped to. In TinyTang a new `ports/bl616/tinynes_app.cpp` registers "TinyNES Controls" with an NES icon, its four tab headers are buttons whose pages are shown and hidden with `td_widget_set_visible`, and `ports/bl616/tang_nes_ini.c` reads the file and is exercised without GUI code by the `tang` command, which reports how many keys it understood; `ae350run` answers the settings request with a sixteen-byte blob and prints the mapping it sent. The user's tests passed for the tabs, the file loop, the app over a running game with F12, the window lifecycle and the save regression, and a mapping of `p1_a = y` written into `/nes.ini` and carried to the AE350 changed the game's A button while player 2 was left alone, which is the first time a file on the card has changed how a game responds. Against that, two of my own errors cost this cycle time and are recorded rather than smoothed over: the parser read only one `key = value` per line while the file I shipped put four on a line, so all sixteen input keys were silently dropped and the count read nine, and I reported a `25 key(s)` figure that was never board output but an illustration I had written, when the count line is the instrument that catches exactly this and I had bypassed it by not running it. The button set was also wrong: the file offered sixteen controller names and only nine bits of the Classic's word have ever been identified on this board (entry 16), so it now offers the eight the player can honour while HOME stays reserved for the swap to TinyDesk. The heap total is back to 121,304 bytes with 62,324 free, the 8 KiB returned when the save buffer stopped being a permanent array, and `BRD-008` was revised for the free 40-pin header's missing 3.3 V rail. The core-syntax audit passed.

#### Next Steps:

Wire the Input tab to what is now proved: Remap and Restore defaults are inert and Player 1/2 changes state with nothing visible, and the app reads `/nes.ini` once per boot rather than when it opens. A host test for `tang_nes_ini.c` belongs in TinyTang's `tools/tests/` beside the `tang.ini` and Phosphor catalogue tests, since the one-key-per-line fault is what it would have caught. Then the Video and Audio tabs, whose settings still reach nothing, and the Bluetooth assert, which resets the board and can spoil any hardware test.

#### Files Modified:

- docs/tinynes-controls-plan.md
- firmware/apps/nes_bench/main.cpp

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---
