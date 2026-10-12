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
