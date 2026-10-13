// SPDX-License-Identifier: MIT
// HDMI (DVI) video for the A25: two 256x240 8-bit indexed frame buffers, a
// 768-entry palette and per-line colour emphasis in block RAM, written over
// the EXTS window, shown at 1280x720 60 Hz with each NES pixel 3x3 and the
// 768x720 picture centred between black side bars. The palette index of a
// pixel follows FCEUmm's: the pixel value itself when its line's emphasis is
// 0, otherwise 256 + emphasis * 64 + (pixel & 63).
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
//   0x1000 + 4 * i, write: palette entry i (0 to 1023; 768 to 1023 unused),
//           red in bits 23:16, green 15:8, blue 7:0.
//   0x2000 + 4 * (256 * b + y), write: emphasis (bits 2:0) of line y of
//           buffer b.
//   0x10000 + 0x10000 * b + 256 * y + x, write: pixel (x, y) of buffer b
//           (y below 240), as
//           bytes, halfwords or words.
// Registers, palette and emphasis take 32-bit transfers only. Any other
// access gets an AHB ERROR response. Every other transfer completes with no
// wait state.
//
// Pixel side (pix_clk, 74.25 MHz): CEA-861 1280x720p60 timing, positive
// syncs. The TMDS encoder is TinyTang's fpga/hdmi_test/hdmi_test.v's (MIT).
module video #(
    parameter [31:0] ID_VALUE = 32'h544e5631, // "TNV1"
    // Diagnostic: colour each pixel from its palette index, not the palette.
    parameter DEBUG_INDEX = 0
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
    // The frame buffers, one 32K x 8 store per byte lane, are built from
    // explicit 4K x 4 arrays below (g_lane/g_bank) so each maps to one block
    // RAM in 4-bit mode. Apicula's 1-bit block RAM mode, which synthesis
    // would otherwise pick, reads back as zero on the GW5AST-138.
    reg [23:0] palette [0:1023];
    reg [2:0] emphasis [0:511];

    // Pixel-side state the bus side reads through synchronisers.
    reg shown_buf = 1'b0;
    reg shown_en = 1'b0;
    reg pix_vblank = 1'b0;

    // ---------------------------------------------------------- bus side --
    localparam [1:0] R_CTRL = 2'd0, R_STATUS = 2'd1, R_FRAMES = 2'd2, R_ID = 2'd3;

    reg [1:0] ctrl = 2'b00;          // {buffer, enable}
    reg [31:0] frames = 32'd0;
    reg [2:0] vblank_sync = 3'b000;  // the last two give an edge
    reg [1:0] shown_buf_sync = 2'b00;
    reg [1:0] shown_en_sync = 2'b00;

    // Data phase of the transfer accepted at the last edge.
    reg d_fb = 1'b0, d_pal = 1'b0, d_emph = 1'b0, d_ctrl = 1'b0;
    reg [3:0] d_lanes = 4'd0;
    reg [14:0] d_fb_addr = 15'd0;
    reg [9:0] d_pal_addr = 10'd0;
    reg [8:0] d_emph_addr = 9'd0;

    wire accept = hready_in && hsel && htrans[1];
    wire word = hsize == 3'd2 && haddr[1:0] == 2'b00;
    wire half = hsize == 3'd1 && !haddr[0];
    wire is_fb = haddr[17];
    wire is_unit = haddr[17:16] == 2'b01;
    wire is_reg = is_unit && haddr[15:12] == 4'h0 && haddr[11:4] == 8'd0;
    wire is_pal = is_unit && haddr[15:12] == 4'h1;
    wire is_emph = is_unit && haddr[15:12] == 4'h2 && haddr[11] == 1'b0;
    wire [3:0] lanes = word ? 4'b1111 :
                       half ? (haddr[1] ? 4'b1100 : 4'b0011) :
                       hsize == 3'd0 ? 4'b0001 << haddr[1:0] : 4'b0000;
    wire ok = is_fb ? hwrite && lanes != 4'b0000 :
              is_reg ? word && (!hwrite || haddr[3:2] == R_CTRL) :
              (is_pal || is_emph) ? word && hwrite : 1'b0;

    always @(posedge clk) begin
        if (d_pal) palette[d_pal_addr] <= hwdata[23:0];
        if (d_emph) emphasis[d_emph_addr] <= hwdata[2:0];
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            ctrl <= 2'b00;
            frames <= 32'd0;
            vblank_sync <= 3'b000;
            shown_buf_sync <= 2'b00;
            shown_en_sync <= 2'b00;
            d_fb <= 1'b0;
            d_pal <= 1'b0;
            d_emph <= 1'b0;
            d_ctrl <= 1'b0;
            hrdata <= 32'd0;
            d_lanes <= 4'd0;
            d_fb_addr <= 15'd0;
            d_pal_addr <= 10'd0;
            d_emph_addr <= 9'd0;
            hready <= 1'b1;
            hresp <= 1'b0;
        end else begin
            vblank_sync <= {vblank_sync[1:0], pix_vblank};
            shown_buf_sync <= {shown_buf_sync[0], shown_buf};
            shown_en_sync <= {shown_en_sync[0], shown_en};
            if (vblank_sync[1] && !vblank_sync[2])
                frames <= frames + 1'b1;

            if (d_ctrl)
                ctrl <= hwdata[1:0];

            d_fb <= 1'b0;
            d_pal <= 1'b0;
            d_emph <= 1'b0;
            d_ctrl <= 1'b0;
            if (!hready) begin
                // Second cycle of an ERROR response.
                hready <= 1'b1;
            end else begin
                hresp <= 1'b0;
                // Read data is registered here, in the address phase; a
                // CTRL write in its data phase now is passed straight on.
                hrdata <= 32'd0;
                if (accept && !hwrite && ok)
                    case (haddr[3:2])
                        R_CTRL: hrdata <= {30'd0, d_ctrl ? hwdata[1:0] : ctrl};
                        R_STATUS: hrdata <= {29'd0, shown_en_sync[1], shown_buf_sync[1], vblank_sync[1]};
                        R_FRAMES: hrdata <= frames;
                        default: hrdata <= ID_VALUE;
                    endcase
                if (accept) begin
                    d_lanes <= lanes;
                    d_fb_addr <= haddr[16:2];
                    d_pal_addr <= haddr[11:2];
                    d_emph_addr <= haddr[10:2];
                    if (!ok) begin
                        hready <= 1'b0;
                        hresp <= 1'b1;
                    end else if (hwrite) begin
                        d_fb <= is_fb;
                        d_pal <= is_pal;
                        d_emph <= is_emph;
                        d_ctrl <= is_reg;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------- pixel side --
    reg [1:0] ctrl_meta = 2'b00, ctrl_sync = 2'b00;

    reg [10:0] hcnt = 11'd0;
    reg [9:0] vcnt = 10'd0;
    reg [7:0] nx = 8'd0, ny = 8'd0;   // the NES pixel at (hcnt, vcnt)
    reg [1:0] hsub = 2'd0, vsub = 2'd0;
    wire h_last = hcnt == H_TOTAL - 1;
    wire [10:0] h_next = h_last ? 11'd0 : hcnt + 1'b1;
    wire [9:0] v_next = vcnt == V_TOTAL - 1 ? 10'd0 : vcnt + 1'b1;

    always @(posedge pix_clk) begin
        ctrl_meta <= ctrl;
        ctrl_sync <= ctrl_meta;
        if (pix_reset) begin
            hcnt <= 11'd0;
            vcnt <= 10'd0;
            nx <= 8'd0;
            hsub <= 2'd0;
            ny <= 8'd0;
            vsub <= 2'd0;
            shown_buf <= 1'b0;
            shown_en <= 1'b0;
            pix_vblank <= 1'b0;
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
                if (v_next == 10'd0) begin
                    ny <= 8'd0;
                    vsub <= 2'd0;
                end else if (vsub == 2'd2) begin
                    ny <= ny + 1'b1;
                    vsub <= 2'd0;
                end else begin
                    vsub <= vsub + 1'b1;
                end
                // The new buffer and mode are taken as vertical blank begins.
                if (v_next == V_ACTIVE) begin
                    shown_buf <= ctrl_sync[1];
                    shown_en <= ctrl_sync[0];
                    pix_vblank <= 1'b1;
                end else if (v_next == 10'd0) begin
                    pix_vblank <= 1'b0;
                end
            end
        end
    end

    // Stage 0: the raster position, above. Stage 1: the frame-buffer word
    // and the line's emphasis. Stage 2: the palette index. Stage 3: the
    // colour. The encoders register stage 3.
    wire de0 = hcnt < H_ACTIVE && vcnt < V_ACTIVE;
    wire pic0 = hcnt >= X0 && hcnt < X0 + 768 && vcnt < V_ACTIVE;
    wire hs0 = hcnt >= H_ACTIVE + H_FP && hcnt < H_ACTIVE + H_FP + H_SYNC;
    wire vs0 = vcnt >= V_ACTIVE + V_FP && vcnt < V_ACTIVE + V_FP + V_SYNC;
    wire [2:0] bar0 = hcnt < BAR ? 3'd0 : hcnt < 2 * BAR ? 3'd1 :
                      hcnt < 3 * BAR ? 3'd2 : hcnt < 4 * BAR ? 3'd3 :
                      hcnt < 5 * BAR ? 3'd4 : hcnt < 6 * BAR ? 3'd5 :
                      hcnt < 7 * BAR ? 3'd6 : 3'd7;
    wire [14:0] fb_addr0 = {shown_buf, ny, nx[7:2]};

    // {de, pic, hs, vs, en, bar} per stage.
    reg [7:0] ctl1 = 8'd0, ctl2 = 8'd0, ctl3 = 8'd0;
    wire [7:0] q [0:31];             // {lane, bank}
    reg [2:0] bank1 = 3'd0;
    reg [1:0] lane1 = 2'd0;
    reg [2:0] emph1 = 3'd0;
    reg [9:0] index2 = 10'd0;
    reg [23:0] rgb3 = 24'd0;

    genvar gl, gb;
    generate
        for (gl = 0; gl < 4; gl = gl + 1) begin : g_lane
            for (gb = 0; gb < 8; gb = gb + 1) begin : g_bank
                reg [3:0] lo [0:4095];
                reg [3:0] hi [0:4095];
                reg [7:0] rd = 8'd0;

                always @(posedge clk)
                    if (d_fb && d_lanes[gl] && d_fb_addr[14:12] == gb) begin
                        lo[d_fb_addr[11:0]] <= hwdata[8 * gl +: 4];
                        hi[d_fb_addr[11:0]] <= hwdata[8 * gl + 4 +: 4];
                    end

                always @(posedge pix_clk)
                    rd <= {hi[fb_addr0[11:0]], lo[fb_addr0[11:0]]};

                assign q[8 * gl + gb] = rd;
            end
        end
    endgenerate

    always @(posedge pix_clk) begin
        bank1 <= fb_addr0[14:12];
        emph1 <= emphasis[{shown_buf, ny}];
        if (DEBUG_INDEX == 0)
            rgb3 <= palette[index2];
        else
            rgb3 <= index2 == 10'd0 ? 24'd0 :
                    {index2[7:0] | 8'h20, index2[4:0], 3'b111, index2[2:0], 5'b11111};
    end

    wire [7:0] pixel1 = q[{lane1, bank1}];

    always @(posedge pix_clk) begin
        ctl1 <= {de0, pic0, hs0, vs0, shown_en, bar0};
        ctl2 <= ctl1;
        ctl3 <= ctl2;
        lane1 <= nx[1:0];
        index2 <= emph1 == 3'd0 ? {2'b00, pixel1} :
                  10'd256 + {1'b0, emph1, 6'd0} + {4'd0, pixel1[5:0]};
    end

    // white, yellow, cyan, green, magenta, red, blue, black
    wire [2:0] bar3 = ctl3[2:0];
    wire r_on = bar3 == 3'd0 || bar3 == 3'd1 || bar3 == 3'd4 || bar3 == 3'd5;
    wire g_on = bar3 == 3'd0 || bar3 == 3'd1 || bar3 == 3'd2 || bar3 == 3'd3;
    wire b_on = bar3 == 3'd0 || bar3 == 3'd2 || bar3 == 3'd4 || bar3 == 3'd6;
    wire de3 = ctl3[7], pic3 = ctl3[6], hs3 = ctl3[5], vs3 = ctl3[4], en3 = ctl3[3];
    wire [23:0] colour3 = !en3 ? {r_on ? 8'd192 : 8'd16, g_on ? 8'd192 : 8'd16,
                                  b_on ? 8'd192 : 8'd16} :
                          pic3 ? rgb3 : 24'd0;

    tmds_encoder enc_blue (.clk(pix_clk), .reset(pix_reset), .de(de3), .ctrl({vs3, hs3}),
                           .d(colour3[7:0]), .q(tmds_blue));
    tmds_encoder enc_green (.clk(pix_clk), .reset(pix_reset), .de(de3), .ctrl(2'b00),
                            .d(colour3[15:8]), .q(tmds_green));
    tmds_encoder enc_red (.clk(pix_clk), .reset(pix_reset), .de(de3), .ctrl(2'b00),
                          .d(colour3[23:16]), .q(tmds_red));
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
