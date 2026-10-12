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
