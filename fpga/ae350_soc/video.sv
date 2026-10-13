// SPDX-License-Identifier: MIT
// HDMI (DVI) video for the A25: two 256x240 8-bit indexed frame buffers in
// the SDRAM, a 768-entry palette and per-line colour emphasis, shown at
// 1280x720 60 Hz with each NES pixel 3x3 and the 768x720 picture centred
// between black side bars. The palette index of a pixel follows FCEUmm's:
// the pixel value itself when its line's emphasis is 0, otherwise 256 +
// emphasis * 64 + (pixel & 63).
//
// Frame buffer b is the SDRAM at byte FB_BASE + 0x10000 * b, pixel (x, y)
// at 256 * y + x, which the A25 writes through its cached RAM port and
// must write back from its D-cache before asking for the buffer to be
// shown. While each line is shown the unit fetches the next through
// ahb_sdram's video channel into the other of two flip-flop line buffers.
// The palette and emphasis are block RAM written and read on the pixel
// clock, the bus side handing each write across. No block RAM is written on
// one clock and read on the other: Apicula's block RAM reads back wrong in
// that use on the GW5AST-138 (core-log entry 14).
//
// Bus side (clk), offsets from 0xe8010000; the top level selects this unit
// for 0xe8010000 to 0xe803ffff and passes the low 18 address bits:
//   0x0000  CTRL, read and write: bit 0 shows the frame buffers (0 shows
//           fabric colour bars), bit 1 the buffer to show. Both take effect
//           at the next vertical blank.
//   0x0004  STATUS, read: bit 0 in vertical blank, bit 1 the buffer being
//           shown, bit 2 the frame buffers are being shown.
//   0x0008  FRAMES, read: vertical blanks since reset.
//   0x000c  ID, read: ID_VALUE.
//   0x0010  LATE, read: lines shown since reset whose fetch from the SDRAM
//           had not finished, so that the line before was shown again.
//   0x0014  PIXELS, read: screen pixels of the last whole frame shown whose
//           frame-buffer value was not 0, nine for each such NES pixel
//           (diagnostic; it changes at each vertical blank).
//   0x0018  BITS, read: for the last whole frame shown, bit n (0 to 7) set
//           if pixel bit n was ever 1 and bit 8 + n if it was ever 0
//           (diagnostic).
//   0x0800 + 4 * i, read: line-buffer halfword i (0 to 255) in bits 15:0,
//           halfword k of line y at 128 * (y & 1) + k, with one wait state
//           (diagnostic).
//   0x1000 + 4 * i, write: palette entry i (0 to 1023; 768 to 1023 unused),
//           red in bits 23:16, green 15:8, blue 7:0.
//   0x2000 + 4 * (256 * b + y), write: emphasis (bits 2:0) of line y of
//           buffer b.
// Registers, palette and emphasis take 32-bit transfers only. Any other
// access gets an AHB ERROR response. Register transfers complete with no
// wait state; a palette or emphasis write waits until the one before it has
// reached the pixel side, a few clocks.
//
// Pixel side (pix_clk, 74.25 MHz): CEA-861 1280x720p60 timing, positive
// syncs. The TMDS encoder is TinyTang's fpga/hdmi_test/hdmi_test.v's (MIT).
//
// The desk layer (desk_link.sv): 80x45 cells of 16x16 pixels, each an 8x8
// glyph of the font in FONT_FILE (desk_font.hex) drawn twice its size in a
// foreground and a background colour. While layer_on is set, taken at the
// next vertical blank like CTRL, the layer replaces the whole picture, side
// bars and colour bars included. Cells are written from the bus side one at
// a time (cell_valid, cell_ready) and handed to the pixel side, where the
// cell store and the font are kept, as palette writes are.
module video #(
    parameter [31:0] ID_VALUE = 32'h544e5631, // "TNV1"
    // Frame buffer 0's SDRAM byte address, bits 24:17 (bits 16:0 are 0):
    // the top 128 KiB of the 32 MiB.
    parameter [24:17] FB_BASE = 8'hff,
    // Diagnostic: colour each pixel from its palette index, not the palette.
    parameter DEBUG_INDEX = 0,
    // The desk layer's font, relative to the repository root.
    parameter FONT_FILE = "fpga/ae350_soc/desk_font.hex"
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire [17:0] haddr,     // address bits 17:0
    input  wire [1:0]  htrans,
    input  wire        hsel,
    input  wire        hwrite,
    input  wire [2:0]  hsize,
    input  wire [31:0] hwdata,
    input  wire        hready_in, // the EXTS port's HREADY
    output reg  [31:0] hrdata,
    output reg         hready,
    output reg         hresp,

    // ahb_sdram's video channel, on clk.
    output reg         vstart,
    output reg  [24:8] vaddr,
    input  wire        vvalid,
    input  wire [6:0]  vindex,
    input  wire [15:0] vdata,
    input  wire        vdone,

    // The desk layer, on clk.
    input  wire        layer_on,
    input  wire        cell_valid,
    input  wire [11:0] cell_addr,
    input  wire [36:0] cell_data,  // {character, foreground, background}
    output wire        cell_ready,

    input  wire        pix_clk,
    input  wire        pix_reset,
    output wire [9:0]  tmds_blue,
    output wire [9:0]  tmds_green,
    output wire [9:0]  tmds_red
);
    localparam integer H_ACTIVE = 1280, H_FP = 110, H_SYNC = 40, H_BP = 220;
    localparam integer V_ACTIVE = 720, V_FP = 5, V_SYNC = 5, V_BP = 20;
    localparam integer H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
    localparam integer V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;
    localparam integer X0 = (H_ACTIVE - 768) / 2;
    localparam integer BAR = H_ACTIVE / 8;

    // ------------------------------------------------------------ storage --
    // Palette and emphasis, both ports on pix_clk. The emphasis store is 9
    // bits wide, bits 8:3 stored and never read, so that it maps to block
    // RAM in 9-bit mode like the palette.
    reg [23:0] palette [0:1023];
    reg [8:0] emphasis [0:511];

    // Two line buffers, halfword by halfword: line y of the frame is in half
    // y[0]. Written on clk as the fetch arrives and read on pix_clk while
    // they are steady, so they are kept in flip-flops, not block RAM.
    (* ram_style = "logic" *) reg [15:0] lb [0:255];

    // Pixel-side state the bus side reads through synchronisers.
    reg shown_buf = 1'b0;
    reg shown_en = 1'b0;
    reg pix_vblank = 1'b0;
    reg hs_ack = 1'b0;     // the last palette or emphasis write taken
    reg fr_req = 1'b0;     // toggles to ask for line fr_line of fr_buf
    reg fr_buf = 1'b0;
    reg [7:0] fr_line = 8'd0;
    reg late_t = 1'b0;     // toggles for each line shown late

    // ---------------------------------------------------------- bus side --
    localparam [2:0] R_CTRL = 3'd0, R_STATUS = 3'd1, R_FRAMES = 3'd2, R_ID = 3'd3,
                     R_LATE = 3'd4, R_PIXELS = 3'd5, R_BITS = 3'd6;

    reg [1:0] ctrl = 2'b00;          // {buffer, enable}
    reg [31:0] frames = 32'd0;
    reg [31:0] late = 32'd0;
    reg [2:0] vblank_sync = 3'b000;  // the last two give an edge
    reg [2:0] late_sync = 3'b000;
    reg [1:0] shown_buf_sync = 2'b00;
    reg [1:0] shown_en_sync = 2'b00;

    // CTRL write in its data phase; ERROR response second cycle.
    reg d_ctrl = 1'b0, err2 = 1'b0;
    // A line-buffer read in its wait state, and its halfword.
    reg lb_read = 1'b0;
    reg [7:0] lb_index = 8'd0;

    // A palette or emphasis write waiting in its data phase, and the one
    // being handed to the pixel side, which takes it when hs_req changes and
    // answers by copying it to hs_ack.
    reg w_wait = 1'b0, w_emph = 1'b0;
    reg [9:0] w_addr = 10'd0;
    reg hs_req = 1'b0, hs_emph = 1'b0;
    reg [9:0] hs_addr = 10'd0;
    reg [23:0] hs_data = 24'd0;
    reg [1:0] hs_ack_sync = 2'b00;
    wire hs_busy = hs_req != hs_ack_sync[1];

    // A cell write handed to the pixel side the same way.
    reg c_req = 1'b0, c_ack = 1'b0;
    reg [11:0] c_addr = 12'd0;
    reg [36:0] c_data = 37'd0;
    reg [1:0] c_ack_sync = 2'b00;
    assign cell_ready = c_req == c_ack_sync[1];
    always @(posedge clk) begin
        c_ack_sync <= {c_ack_sync[0], c_ack};
        if (cell_valid && cell_ready) begin
            c_req <= !c_req;
            c_addr <= cell_addr;
            c_data <= cell_data;
        end
    end

    wire accept = hready_in && hsel && htrans[1];
    wire word = hsize == 3'd2 && haddr[1:0] == 2'b00;
    wire is_unit = haddr[17:16] == 2'b01;
    wire is_reg = is_unit && haddr[15:12] == 4'h0 && haddr[11:5] == 7'd0;
    wire is_lb = is_unit && haddr[15:12] == 4'h0 && haddr[11:10] == 2'b10;
    wire is_pal = is_unit && haddr[15:12] == 4'h1;
    wire is_emph = is_unit && haddr[15:12] == 4'h2 && haddr[11] == 1'b0;
    wire ok = word && (is_reg ? (hwrite ? haddr[4:2] == R_CTRL : haddr[4:2] <= R_BITS) :
                       is_lb ? !hwrite : (is_pal || is_emph) && hwrite);
    reg [19:0] pixels;               // pixel side, steady between blanks
    reg [15:0] bits;                 // likewise

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            ctrl <= 2'b00;
            frames <= 32'd0;
            late <= 32'd0;
            vblank_sync <= 3'b000;
            late_sync <= 3'b000;
            shown_buf_sync <= 2'b00;
            shown_en_sync <= 2'b00;
            d_ctrl <= 1'b0;
            err2 <= 1'b0;
            w_wait <= 1'b0;
            w_emph <= 1'b0;
            w_addr <= 10'd0;
            lb_read <= 1'b0;
            lb_index <= 8'd0;
            hs_ack_sync <= 2'b00;
            hrdata <= 32'd0;
            hready <= 1'b1;
            hresp <= 1'b0;
        end else begin
            vblank_sync <= {vblank_sync[1:0], pix_vblank};
            late_sync <= {late_sync[1:0], late_t};
            shown_buf_sync <= {shown_buf_sync[0], shown_buf};
            shown_en_sync <= {shown_en_sync[0], shown_en};
            hs_ack_sync <= {hs_ack_sync[0], hs_ack};
            if (vblank_sync[1] && !vblank_sync[2])
                frames <= frames + 1'b1;
            if (late_sync[1] != late_sync[2])
                late <= late + 1'b1;

            if (d_ctrl)
                ctrl <= hwdata[1:0];
            d_ctrl <= 1'b0;

            if (err2) begin
                // Second cycle of an ERROR response.
                err2 <= 1'b0;
                hready <= 1'b1;
            end else if (lb_read) begin
                lb_read <= 1'b0;
                hrdata <= {16'd0, lb[lb_index]};
                hready <= 1'b1;
            end else if (w_wait) begin
                if (!hs_busy) begin
                    hs_req <= !hs_req;
                    hs_emph <= w_emph;
                    hs_addr <= w_addr;
                    hs_data <= hwdata[23:0];
                    w_wait <= 1'b0;
                    hready <= 1'b1;
                end
            end else begin
                hresp <= 1'b0;
                // Read data is registered here, in the address phase; a
                // CTRL write in its data phase now is passed straight on.
                hrdata <= 32'd0;
                if (accept && !hwrite && ok && !is_lb)
                    case (haddr[4:2])
                        R_CTRL: hrdata <= {30'd0, d_ctrl ? hwdata[1:0] : ctrl};
                        R_STATUS: hrdata <= {29'd0, shown_en_sync[1], shown_buf_sync[1], vblank_sync[1]};
                        R_FRAMES: hrdata <= frames;
                        R_ID: hrdata <= ID_VALUE;
                        R_LATE: hrdata <= late;
                        R_PIXELS: hrdata <= {12'd0, pixels};
                        default: hrdata <= {16'd0, bits};
                    endcase
                if (accept) begin
                    w_emph <= is_emph;
                    w_addr <= is_emph ? {1'b0, haddr[10:2]} : haddr[11:2];
                    if (!ok) begin
                        hready <= 1'b0;
                        hresp <= 1'b1;
                        err2 <= 1'b1;
                    end else if (is_lb) begin
                        lb_index <= haddr[9:2];
                        lb_read <= 1'b1;
                        hready <= 1'b0;
                    end else if (hwrite && is_reg) begin
                        d_ctrl <= 1'b1;
                    end else if (hwrite) begin
                        hready <= 1'b0;
                        w_wait <= 1'b1;
                    end
                end
            end
        end
    end

    // Line fetches: when fr_req changes, fetch line fr_line of buffer fr_buf
    // into line-buffer half fr_line[0], then copy fr_req to fd. One fetch is
    // in progress at a time; a request made during one is taken after it.
    reg [1:0] fr_sync = 2'b00;
    reg fr_seen = 1'b0;
    reg fd = 1'b0;
    reg fetching = 1'b0;
    reg lb_half = 1'b0;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            fr_sync <= 2'b00;
            fr_seen <= 1'b0;
            fd <= 1'b0;
            fetching <= 1'b0;
            lb_half <= 1'b0;
            vstart <= 1'b0;
            vaddr <= 17'd0;
        end else begin
            fr_sync <= {fr_sync[0], fr_req};
            vstart <= 1'b0;
            if (!fetching && fr_sync[1] != fr_seen) begin
                fr_seen <= fr_sync[1];
                vaddr <= {FB_BASE, fr_buf, fr_line};
                lb_half <= fr_line[0];
                vstart <= 1'b1;
                fetching <= 1'b1;
            end
            if (vdone) begin
                fetching <= 1'b0;
                fd <= fr_seen;
            end
        end
    end

    always @(posedge clk)
        if (vvalid)
            lb[{lb_half, vindex}] <= vdata;

    // -------------------------------------------------------- pixel side --
    reg [1:0] ctrl_meta = 2'b00, ctrl_sync = 2'b00;
    reg [1:0] fd_sync = 2'b00;
    reg [2:0] hs_req_sync = 3'b000;  // the last two give an edge
    wire hs_take = hs_req_sync[2] != hs_req_sync[1];

    always @(posedge pix_clk) begin
        if (hs_take && !hs_emph)
            palette[hs_addr] <= hs_data;
        if (hs_take && hs_emph)
            emphasis[hs_addr[8:0]] <= hs_data[8:0];
    end

    // The desk layer's cell store and font, both on pix_clk only. The store
    // is five 9-bit slices so that it maps to block RAM in 9-bit mode, as the
    // palette and emphasis do; that mode is the one shown to work on this
    // chip (core-log entry 14, TOOL-020).
    reg [8:0] cells0 [0:4095];
    reg [8:0] cells1 [0:4095];
    reg [8:0] cells2 [0:4095];
    reg [8:0] cells3 [0:4095];
    reg [8:0] cells4 [0:4095];
    wire [44:0] c_wide = {8'd0, c_data};
    reg [7:0] font [0:1023];
    initial $readmemh(FONT_FILE, font);
    reg [2:0] c_req_sync = 3'b000;
    wire c_take = c_req_sync[2] != c_req_sync[1];
    reg [1:0] layer_sync = 2'b00;
    reg layer_shown = 1'b0;
    always @(posedge pix_clk) begin
        c_req_sync <= {c_req_sync[1:0], c_req};
        if (c_take) begin
            cells0[c_addr] <= c_wide[8:0];
            cells1[c_addr] <= c_wide[17:9];
            cells2[c_addr] <= c_wide[26:18];
            cells3[c_addr] <= c_wide[35:27];
            cells4[c_addr] <= c_wide[44:36];
            c_ack <= c_req_sync[1];
        end
        layer_sync <= {layer_sync[0], layer_on};
    end

    reg [10:0] hcnt = 11'd0;
    reg [9:0] vcnt = 10'd0;
    reg [11:0] cell_row = 12'd0;
    reg [7:0] nx = 8'd0, ny = 8'd0;   // the NES pixel at (hcnt, vcnt)
    reg [1:0] hsub = 2'd0, vsub = 2'd0;
    wire h_last = hcnt == H_TOTAL - 1;
    wire [10:0] h_next = h_last ? 11'd0 : hcnt + 1'b1;
    wire [9:0] v_next = vcnt == V_TOTAL - 1 ? 10'd0 : vcnt + 1'b1;
    // At h_last: the next raster line starts NES line ny_next.
    wire new_line = v_next == 10'd0 || (vsub == 2'd2 && v_next < V_ACTIVE);
    wire [7:0] ny_next = v_next == 10'd0 ? 8'd0 : ny + 1'b1;

    always @(posedge pix_clk) begin
        ctrl_meta <= ctrl;
        ctrl_sync <= ctrl_meta;
        fd_sync <= {fd_sync[0], fd};
        hs_req_sync <= {hs_req_sync[1:0], hs_req};
        if (hs_take)
            hs_ack <= hs_req_sync[1];
        if (pix_reset) begin
            hcnt <= 11'd0;
            vcnt <= 10'd0;
            nx <= 8'd0;
            hsub <= 2'd0;
            ny <= 8'd0;
            vsub <= 2'd0;
            shown_buf <= 1'b0;
            shown_en <= 1'b0;
            layer_shown <= 1'b0;
            pix_vblank <= 1'b0;
            cell_row <= 12'd0;
        end else begin
            hcnt <= h_next;
            if (h_next == X0) begin
                nx <= 8'd0;
                hsub <= 2'd0;
            end else if (hsub == 2'd2) begin
                nx <= nx + 1'b1;
                hsub <= 2'd0;
            end else begin
                hsub <= hsub + 1'b1;
            end
            if (h_last) begin
                vcnt <= v_next;
                // The first cell of the cell row the next line is in.
                if (v_next == 10'd0)
                    cell_row <= 12'd0;
                else if (v_next[3:0] == 4'd0)
                    cell_row <= cell_row + 12'd80;
                if (v_next == 10'd0) begin
                    ny <= 8'd0;
                    vsub <= 2'd0;
                end else if (vsub == 2'd2) begin
                    ny <= ny + 1'b1;
                    vsub <= 2'd0;
                end else begin
                    vsub <= vsub + 1'b1;
                end
                // Each NES line, once its fetch is checked, asks for the
                // next; line 0 is asked for as vertical blank begins.
                if (new_line && shown_en) begin
                    if (fd_sync[1] != fr_req)
                        late_t <= !late_t;
                    if (ny_next != 8'd239) begin
                        fr_line <= ny_next + 1'b1;
                        fr_buf <= shown_buf;
                        fr_req <= !fr_req;
                    end
                end
                // The new buffer and mode are taken as vertical blank begins.
                if (v_next == V_ACTIVE) begin
                    shown_buf <= ctrl_sync[1];
                    shown_en <= ctrl_sync[0];
                    layer_shown <= layer_sync[1];
                    pix_vblank <= 1'b1;
                    if (ctrl_sync[0]) begin
                        fr_line <= 8'd0;
                        fr_buf <= ctrl_sync[1];
                        fr_req <= !fr_req;
                    end
                end else if (v_next == 10'd0) begin
                    pix_vblank <= 1'b0;
                end
            end
        end
    end

    // Stage 0: the raster position, above. Stage 1: the line-buffer pixel
    // and the line's emphasis; the layer's cell. Stage 2: the palette index;
    // the cell's glyph row. Stage 3: the colour; the layer's colour. Stage 4:
    // the colour, bars or layer, registered. The encoders register stage 4.
    wire de0 = hcnt < H_ACTIVE && vcnt < V_ACTIVE;
    wire pic0 = hcnt >= X0 && hcnt < X0 + 768 && vcnt < V_ACTIVE;
    wire hs0 = hcnt >= H_ACTIVE + H_FP && hcnt < H_ACTIVE + H_FP + H_SYNC;
    wire vs0 = vcnt >= V_ACTIVE + V_FP && vcnt < V_ACTIVE + V_FP + V_SYNC;
    wire [2:0] bar0 = hcnt < BAR ? 3'd0 : hcnt < 2 * BAR ? 3'd1 :
                      hcnt < 3 * BAR ? 3'd2 : hcnt < 4 * BAR ? 3'd3 :
                      hcnt < 5 * BAR ? 3'd4 : hcnt < 6 * BAR ? 3'd5 :
                      hcnt < 7 * BAR ? 3'd6 : 3'd7;
    wire [15:0] lb_word = lb[{ny[0], nx[7:1]}];
    wire [11:0] cell0 = cell_row + {5'd0, hcnt[10:4]};

    // {layer, de, pic, hs, vs, en, bar} per stage.
    reg [8:0] ctl1 = 9'd0, ctl2 = 9'd0, ctl3 = 9'd0;
    reg [7:0] pixel1 = 8'd0;
    reg [2:0] emph1 = 3'd0;
    reg [9:0] index2 = 10'd0;
    reg [23:0] rgb3 = 24'd0;
    reg [44:0] cell1 = 45'd0;
    reg [2:0] row1 = 3'd0, col1 = 3'd0, col2 = 3'd0;
    reg [29:0] colours2 = 30'd0;
    reg [7:0] glyph2 = 8'd0;
    reg [23:0] lay3 = 24'd0;

    // A 15-bit {b, g, r} colour as 24-bit RGB.
    function [23:0] rgb15(input [14:0] c);
        rgb15 = {c[4:0], c[4:2], c[9:5], c[9:7], c[14:10], c[14:12]};
    endfunction

    always @(posedge pix_clk) begin
        cell1 <= {cells4[cell0], cells3[cell0], cells2[cell0], cells1[cell0], cells0[cell0]};
        row1 <= vcnt[3:1];
        col1 <= hcnt[3:1];
        glyph2 <= font[{cell1[36:30], row1}];
        colours2 <= cell1[29:0];
        col2 <= col1;
        lay3 <= glyph2[col2] ? rgb15(colours2[29:15]) : rgb15(colours2[14:0]);
    end

    always @(posedge pix_clk) begin
        pixel1 <= nx[0] ? lb_word[15:8] : lb_word[7:0];
        emph1 <= emphasis[{shown_buf, ny}][2:0];
        if (DEBUG_INDEX == 0)
            rgb3 <= palette[index2];
        else
            rgb3 <= index2 == 10'd0 ? 24'd0 :
                    {index2[7:0] | 8'h20, index2[4:0], 3'b111, index2[2:0], 5'b11111};
    end

    // Non-zero pixels of the frame being shown, latched as it ends.
    // Likewise the pixel bits seen as 1 and as 0.
    reg [19:0] pixel_count = 20'd0;
    reg [7:0] seen1 = 8'd0, seen0 = 8'd0;
    initial pixels = 20'd0;
    initial bits = 16'd0;
    always @(posedge pix_clk) begin
        if (h_last && v_next == V_ACTIVE) begin
            pixels <= pixel_count;
            bits <= {seen0, seen1};
            pixel_count <= 20'd0;
            seen1 <= 8'd0;
            seen0 <= 8'd0;
        end else if (ctl1[6] && ctl1[3]) begin  // pic and en
            if (pixel1 != 8'd0)
                pixel_count <= pixel_count + 1'b1;
            seen1 <= seen1 | pixel1;
            seen0 <= seen0 | ~pixel1;
        end
    end

    always @(posedge pix_clk) begin
        ctl1 <= {layer_shown, de0, pic0, hs0, vs0, shown_en, bar0};
        ctl2 <= ctl1;
        ctl3 <= ctl2;
        index2 <= emph1 == 3'd0 ? {2'b00, pixel1} :
                  10'd256 + {1'b0, emph1, 6'd0} + {4'd0, pixel1[5:0]};
    end

    // white, yellow, cyan, green, magenta, red, blue, black
    wire [2:0] bar3 = ctl3[2:0];
    wire r_on = bar3 == 3'd0 || bar3 == 3'd1 || bar3 == 3'd4 || bar3 == 3'd5;
    wire g_on = bar3 == 3'd0 || bar3 == 3'd1 || bar3 == 3'd2 || bar3 == 3'd3;
    wire b_on = bar3 == 3'd0 || bar3 == 3'd2 || bar3 == 3'd4 || bar3 == 3'd6;
    wire de3 = ctl3[7], pic3 = ctl3[6], hs3 = ctl3[5], vs3 = ctl3[4], en3 = ctl3[3];
    wire layer3 = ctl3[8];
    wire [23:0] colour3 = layer3 ? lay3 :
                          !en3 ? {r_on ? 8'd192 : 8'd16, g_on ? 8'd192 : 8'd16,
                                  b_on ? 8'd192 : 8'd16} :
                          pic3 ? rgb3 : 24'd0;

    reg [23:0] colour4 = 24'd0;
    reg de4 = 1'b0, hs4 = 1'b0, vs4 = 1'b0;
    always @(posedge pix_clk) begin
        colour4 <= colour3;
        de4 <= de3;
        hs4 <= hs3;
        vs4 <= vs3;
    end

    tmds_encoder enc_blue (.clk(pix_clk), .reset(pix_reset), .de(de4), .ctrl({vs4, hs4}),
                           .d(colour4[7:0]), .q(tmds_blue));
    tmds_encoder enc_green (.clk(pix_clk), .reset(pix_reset), .de(de4), .ctrl(2'b00),
                            .d(colour4[15:8]), .q(tmds_green));
    tmds_encoder enc_red (.clk(pix_clk), .reset(pix_reset), .de(de4), .ctrl(2'b00),
                          .d(colour4[23:16]), .q(tmds_red));
endmodule

// DVI 1.0 TMDS encoder (section 3.3.3); q[0] is the first bit on the wire.
// From TinyTang's fpga/hdmi_test/hdmi_test.v (MIT), without its clock enable.
module tmds_encoder (
    input  wire       clk,
    input  wire       reset,
    input  wire       de,
    input  wire [1:0] ctrl,
    input  wire [7:0] d,
    output reg  [9:0] q
);
    wire [3:0] n1d = d[0] + d[1] + d[2] + d[3] + d[4] + d[5] + d[6] + d[7];
    wire use_xnor = n1d > 4'd4 || (n1d == 4'd4 && d[0] == 1'b0);

    wire [8:0] qm;
    assign qm[0] = d[0];
    genvar k;
    generate
        for (k = 1; k < 8; k = k + 1) begin : stage
            assign qm[k] = use_xnor ? ~(qm[k-1] ^ d[k]) : (qm[k-1] ^ d[k]);
        end
    endgenerate
    assign qm[8] = ~use_xnor;

    wire [3:0] n1q = qm[0] + qm[1] + qm[2] + qm[3] + qm[4] + qm[5] + qm[6] + qm[7];
    wire signed [4:0] diff = $signed({1'b0, n1q}) - $signed(5'd8 - {1'b0, n1q});  // N1 - N0
    wire signed [4:0] two_qm8  = qm[8] ? 5'sd2 : 5'sd0;
    wire signed [4:0] two_nqm8 = qm[8] ? 5'sd0 : 5'sd2;

    reg signed [4:0] cnt = 5'sd0;
    initial q = 10'd0;
    always @(posedge clk)
        if (reset) begin
            cnt <= 5'sd0;
            q   <= 10'd0;
        end else if (!de) begin
            cnt <= 5'sd0;
            case (ctrl)
                2'b00: q <= 10'b1101010100;
                2'b01: q <= 10'b0010101011;
                2'b10: q <= 10'b0101010100;
                2'b11: q <= 10'b1010101011;
            endcase
        end else if (cnt == 5'sd0 || diff == 5'sd0) begin
            q   <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
            cnt <= qm[8] ? cnt + diff : cnt - diff;
        end else if ((cnt > 5'sd0 && diff > 5'sd0) || (cnt < 5'sd0 && diff < 5'sd0)) begin
            q   <= {1'b1, qm[8], ~qm[7:0]};
            cnt <= cnt + two_qm8 - diff;
        end else begin
            q   <= {1'b0, qm[8], qm[7:0]};
            cnt <= cnt - two_nqm8 + diff;
        end
endmodule
