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
