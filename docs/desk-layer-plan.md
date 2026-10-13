# TinyDesk over a running game: design for the next cycle

Status on 2026-10-13: **implemented and passed on the board** (core-log
entry 21, TinyTang `ccbf8a7`). The user chose option A below and asked that
the game keep running behind the desktop. The design was built as written,
with three details settled during the cycle: the joypad report is also
resent every 500 ms, LB is held for 260 ms after a HOME tap so one of
TinyTang's 40 ms reads sees it, and the cell store is five 9-bit block RAM
slices. README.md, *TinyDesk over a running game*, describes the result.

## Goal

A single tap of HOME on the Wii Classic Controller, or F12 on the keyboard,
swaps the HDMI picture between the NES game running on the TinyNES core and
TinyDesk, and back, instantly, with the game still running. This is how
TinyTang's patched nestang core (`nestang-desk.bin`) behaves.

## Options considered

- **A, chosen:** give the TinyNES core its own 80x45 desk layer, driven by
  TinyTang's existing desk protocol, shown in place of the game while the
  overlay is up. Instant; one large cycle.
- **B, rejected:** swap FPGA cores with an FCEUmm save state on the card.
  No FPGA work, but 10 to 15 s per swap and no instant F12.

## Facts the design rests on

Read from TinyTang `121d334` (record PROT-010 in `.ai/core-reference.md`):

- Frames both ways are `0xAA len_hi len_lo type payload`, the length counting
  the type byte (PROT-001). UART1 at 2 Mbaud is shared with the AE350.
- Desk frames the BL616 sends (`ports/bl616/tang_fpga_link.h`,
  `tang_osd_desk.c`): `0x13 x y` moves the layer's write cursor; `0x14`
  writes cells from the cursor, advancing across the 80x45 grid, 5 bytes a
  cell: the character (7 bits, ASCII; TinyTang maps box drawing to ASCII
  before sending), the foreground and the background, each a big-endian
  15-bit `{b[4:0], g[4:0], r[4:0]}`; `0x15 b` with bit 0 enabling the layer;
  `0x08 b` with bit 0 the overlay. The layer shows only while both the
  overlay and the enable are on, and then replaces the whole picture. The
  core ID request is `0x01`, answered `0x01 <id>`.
- The BL616's F12 handling flips the overlay (`tang_osd_toggle`). Its desk
  task also reads the core's joypad report, frame `0x03` with two big-endian
  words (`fpga_frames.c`), and toggles the overlay on a rising edge of LB,
  `0x400`, in word 1; while the desktop is up, the same word moves the
  desktop pointer (D-pad bits 4 to 7) and clicks (A `0x100`, B `0x001`)
  (`tang_pad.h`).
- After `tangload`, TinyTang asks the new core for its ID and, for IDs `0x50`
  and `0x54` only, writes PMOD declarations through the `0x10` register
  protocol (`phosphor/pmod_sockets.cpp`), and re-arms the desk layer
  (`tang_osd_desk_core_reloaded`) by resending the enable a few times.
- TinyTang's desktop core HDL (`fpga/desktop/textdisp_wide.sv`,
  `desktop_link.v`) and nestang's 8x8 font are GPL-3.0-only, so TinyNES (MIT)
  writes its own, from the protocol above, with a public-domain font.
- In this open flow, block RAM written on one clock and read on another read
  back wrong in the video unit (TOOL-020, DEV-017); the video unit's palette
  instead lives on the pixel clock with bus writes handed across.

## Design

TinyNES core (new MIT RTL):

1. **Routing in `exts_uart.sv`.** A mode bit: *loader mode* after reset, in
   which received bytes go to the AE350 as now, and *link mode*, in which they
   go to a new frame parser instead, so a binary program image can never be
   taken for a frame. The boot ROM sets loader mode every time it starts; the
   player sets link mode once its cartridge has arrived.
2. **Frame parser.** Answers `0x01` with a new core ID, `0x4E`, so TinyTang's
   PMOD code leaves it alone; takes `0x08`, `0x13`, `0x14` and `0x15`;
   ignores everything else.
3. **Sending in link mode.** A joypad report `0x03` every 20 ms when it
   changes, from Wii pad 1: D-pad to bits 4 to 7, the Classic's B to A
   (`0x100`), Y to B (`0x001`), and a **tap of HOME** (pressed and released
   with nothing else pressed) as one report with LB (`0x400`) set; the AE350's
   own text wrapped in frames of a new type, so `ae350run` still sees
   `TinyNES EXIT` among the joypad reports; an arbiter between the two.
4. **The layer.** An 80x45 cell store and a 128-glyph 8x8 font on the pixel
   clock only, written through a handshake from the bus side like the
   palette; cells are 16x16 output pixels (8x8 glyphs at 2x); when the
   overlay and the enable are both on, the layer replaces the whole picture,
   bars included.

Player (`firmware/apps/nes_bench`, `PLAY=1`):

- Sets link mode after receiving the cartridge, then prints `TinyNES LINK`.
- Keeps emulating, with sound, behind the desktop; while the overlay is up
  the game gets no controller input.
- A HOME tap toggles the desktop (through the joypad report); HOME held with
  `-` still quits.

TinyTang (`ae350run`):

- On `TinyNES LINK`, releases the UART so the desk layer can draw, re-arms
  and repaints the layer, and follows the framed text until `TinyNES EXIT`.

## Tests

- Simulation of the parser, the routing, the arbiter and the layer, the
  layer checked pixel by pixel against a model as `tests/video_tb.sv` does.
- A seed sweep with `NPNR_GOWIN_CLK_FIRST` enforced, then a build.
- On the board: double-click a `.nes`, play, toggle with HOME and F12 both
  ways, drive the desktop pointer with the D-pad, quit with HOME and `-`.

## Risks

- Two-clock block RAM (TOOL-020) is avoided by design but the new pixel-side
  stores add placement pressure; the HDMI loss and patterned glitch recorded
  in core-log entries 18 and 19 are still unexplained.
- Getting the hand-over between loader and link mode wrong loses desk frames
  or corrupts a program load; the boot ROM must always return to loader mode.
