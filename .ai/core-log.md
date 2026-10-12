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
