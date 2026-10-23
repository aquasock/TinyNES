// SPDX-License-Identifier: MIT
// The video unit on its own: registers and error responses over AHB, and
// whole 1280x720 frames compared, pixel by pixel, with a model of the colour
// bars and of both frame buffers with palette and emphasis. The raster is
// driven as hdl-util's HDMI transmitter drives it, cx 0..1649 and cy 0..749
// free-running, and the transmitter takes the colour for cx one clock after
// it presents cx, so each RGB is checked against the pixel cx named a clock
// earlier: a pipeline its look-ahead does not match puts every pixel in the
// wrong column (PROT-009). The frame buffers are a model of ahb_sdram's video
// channel with a set latency. Also checks the buffer flip,
// the line fetch addresses and the LATE count when fetches are too slow,
// and the desk layer: every cell of the 80x45 grid written through its
// handshake and the whole frame compared with a model of the font, over the
// colour bars and over the picture, and the picture back without it.
`timescale 1ns / 1ps

module video_tb;
    reg clk = 1'b0;
    reg pix_clk = 1'b0;
    always #6.667 clk = !clk;     // 75 MHz
    always #6.734 pix_clk = !pix_clk; // 74.25 MHz

    reg resetn = 1'b0;
    reg pix_reset = 1'b1;

    reg [31:0] haddr = 32'd0;
    reg [1:0] htrans = 2'd0;
    reg hsel = 1'b0;
    reg hwrite = 1'b0;
    reg [2:0] hsize = 3'd2;
    reg [31:0] hwdata = 32'd0;
    wire [31:0] hrdata;
    wire hready, hresp;
    // The raster, as the transmitter counts it, and the pixel the current
    // RGB is for: cx and cy one clock ago.
    reg [10:0] cx = 11'd0, px = 11'd0;
    reg [9:0] cy = 10'd0, py = 10'd0;
    wire [23:0] rgb;
    always @(posedge pix_clk) begin
        if (cx == 11'd1649) begin
            cx <= 11'd0;
            cy <= cy == 10'd749 ? 10'd0 : cy + 1'b1;
        end else begin
            cx <= cx + 1'b1;
        end
        px <= cx;
        py <= cy;
    end
    wire vstart;
    wire [24:8] vaddr;
    reg vvalid = 1'b0, vdone = 1'b0;
    reg [6:0] vindex = 7'd0;
    reg [15:0] vdata = 16'd0;
    reg layer_on = 1'b0, cell_valid = 1'b0;
    reg [11:0] cell_addr = 12'd0;
    reg [36:0] cell_data = 37'd0;
    wire cell_ready;

    video dut (
        .clk(clk), .resetn(resetn),
        .haddr(haddr[17:0]), .htrans(htrans), .hsel(hsel), .hwrite(hwrite),
        .hsize(hsize), .hwdata(hwdata), .hready_in(hready),
        .hrdata(hrdata), .hready(hready), .hresp(hresp),
        .vstart(vstart), .vaddr(vaddr), .vvalid(vvalid), .vindex(vindex),
        .vdata(vdata), .vdone(vdone),
        .layer_on(layer_on), .cell_valid(cell_valid), .cell_addr(cell_addr),
        .cell_data(cell_data), .cell_ready(cell_ready),
        .pix_clk(pix_clk), .pix_reset(pix_reset),
        .cx(cx), .cy(cy), .rgb(rgb)
    );

    integer errors = 0;
    task fail(input [8*64-1:0] what);
        begin
            errors = errors + 1;
            if (errors < 20)
                $display("FAIL %0s", what);
        end
    endtask

    // ------------------------------------------------------- AHB master --
    task ahb(input wr, input [31:0] a, input [2:0] size, input [31:0] wd,
             output [31:0] rd, output err);
        begin
            @(negedge clk);
            haddr = a; htrans = 2'b10; hsel = 1'b1; hwrite = wr; hsize = size;
            @(negedge clk);
            htrans = 2'b00; hsel = 1'b0; hwdata = wd;
            while (!hready) @(negedge clk);
            rd = hrdata;
            err = hresp;
        end
    endtask

    reg [31:0] rd;
    reg err;
    task wr32(input [31:0] a, input [31:0] d);
        begin
            ahb(1'b1, a, 3'd2, d, rd, err);
            if (err) begin
                $display("unexpected ERROR writing %h", a);
                fail("write error");
            end
        end
    endtask
    task rd32(input [31:0] a, output [31:0] d);
        begin
            ahb(1'b0, a, 3'd2, 32'd0, d, err);
            if (err) begin
                $display("unexpected ERROR reading %h", a);
                fail("read error");
            end
        end
    endtask
    task expect_error(input wr, input [31:0] a, input [2:0] size);
        begin
            ahb(wr, a, size, 32'h12345678, rd, err);
            if (!err) begin
                $display("no ERROR for %s %h size %0d", wr ? "write" : "read", a, size);
                fail("missing error");
            end
        end
    endtask

    // ------------------------------------------------------------ model --
    localparam [31:0] REGS = 32'he8010000, PAL = 32'he8011000,
                      EMPH = 32'he8012000, FB = 32'he8020000;

    // ahb_sdram's video channel: after fetch_delay clocks, the line's 128
    // halfwords in order with a gap after every seventh, then vdone.
    reg [7:0] fbmem [0:131071];   // buffer b's pixel (x, y) at {b, y, x}
    integer fetch_delay = 40, fetches = 0, bad_fetches = 0, k;
    initial forever begin
        @(posedge clk);
        if (vstart) begin
            if (vaddr[24:17] !== 8'hff || vaddr[15:8] >= 240) begin
                if (bad_fetches < 5) $display("fetch of %h", vaddr);
                bad_fetches = bad_fetches + 1;
            end
            repeat (fetch_delay) @(posedge clk);
            for (k = 0; k < 128; k = k + 1) begin
                vvalid <= 1'b1;
                vindex <= k;
                vdata <= {fbmem[{vaddr[16:8], k[6:0], 1'b1}], fbmem[{vaddr[16:8], k[6:0], 1'b0}]};
                @(posedge clk);
                if (k % 7 == 6) begin
                    vvalid <= 1'b0;
                    @(posedge clk);
                end
            end
            vvalid <= 1'b0;
            vdone <= 1'b1;
            @(posedge clk);
            vdone <= 1'b0;
            fetches = fetches + 1;
        end
    end

    function [23:0] pal_rgb(input [9:0] i);
        pal_rgb = {i[7:0] ^ 8'ha5, i[9:2], i[7:0] * 8'd13};
    endfunction
    function [7:0] fb_pix(input b, input [7:0] x, input [7:0] y);
        fb_pix = b ? x ^ (y * 8'd5) : x + y * 8'd3;
    endfunction
    function [2:0] emph(input b, input [7:0] y);
        emph = y[1:0] == 2'd1 ? y[4:2] + b : 3'd0;
    endfunction
    // The desk layer's cells and the font they are drawn in.
    reg [7:0] font [0:1023];
    initial $readmemh("fpga/ae350_soc/desk_font.hex", font);
    function [36:0] desk_cell(input [11:0] i);
        reg [14:0] fg, bg;
        begin
            fg = {i[4:0], 5'd31 - i[4:0], i[9:5]} ^ 15'h1234;
            bg = {i[11:7], i[6:2], i[1:0], 3'd5};
            desk_cell = {7'h20 + i[6:0] % 7'd96, fg, bg};
        end
    endfunction
    function [23:0] rgb15(input [14:0] c);
        rgb15 = {c[4:0], c[4:2], c[9:5], c[9:7], c[14:10], c[14:12]};
    endfunction
    // Picture checks run while `checking`. These come before `expected`
    // because that function reads them: a Verilog function may only see
    // variables declared above it, and Icarus says so.
    reg checking = 1'b0, check_bars = 1'b0, check_buf = 1'b0, check_layer = 1'b0;
    integer mismatches = 0;
    // The aspect the picture check expects, as the unit's own register holds
    // it: 0 = 8:7, 1 = 1:1, 2 = 4:3.
    reg [1:0] check_aspect = 2'd1;

    function [23:0] expected(input bars, input b, input [10:0] col, input [9:0] row);
        reg [7:0] nx, ny, p;
        reg [2:0] e, bar;
        reg [9:0] idx;
        reg [36:0] c;
        reg [9:0] w;
        reg [10:0] x0;
        begin
            // The picture the ASPECT register asks for: 878, 768 or 960 of
            // the 1280 columns, centred.
            w = check_aspect == 2'd0 ? 10'd878 : check_aspect == 2'd2 ? 10'd960 : 10'd768;
            x0 = (11'd1280 - w) >> 1;
            if (check_layer) begin
                c = desk_cell(80 * (row / 16) + col / 16);
                expected = font[{c[36:30], row[3:1]}][col[3:1]] ? rgb15(c[29:15]) : rgb15(c[14:0]);
            end else if (bars) begin
                bar = col / 160;
                expected = {(bar == 0 || bar == 1 || bar == 4 || bar == 5) ? 8'd192 : 8'd16,
                            (bar == 0 || bar == 1 || bar == 2 || bar == 3) ? 8'd192 : 8'd16,
                            (bar == 0 || bar == 2 || bar == 4 || bar == 6) ? 8'd192 : 8'd16};
            end else if (col < x0 || col >= x0 + w) begin
                expected = 24'd0;
            end else begin
                // Which source pixel an output column draws: the unit walks
                // the line buffer with an accumulator that adds 256 for each
                // column and takes a step when it reaches w, so after c
                // columns it has taken floor(256 * c / w) steps.
                nx = (256 * (col - x0)) / w;
                ny = row / 3;
                p = fb_pix(b, nx, ny);
                e = emph(b, ny);
                idx = e == 3'd0 ? {2'b00, p} : 10'd256 + {1'b0, e, 6'd0} + {4'd0, p[5:0]};
                expected = pal_rgb(idx);
            end
        end
    endfunction

    // Every visible pixel while checking, and the first line of vertical
    // blank, which is where one frame ends and the next is chosen.
    wire de = px < 11'd1280 && py < 10'd720;
    wire frame_end = px == 11'd0 && py == 10'd720;
    always @(posedge pix_clk) if (!pix_reset) begin
        if (de && checking && rgb !== expected(check_bars, check_buf, px, py)) begin
            if (mismatches < 5)
                $display("pixel (%0d, %0d) %h, expected %h", px, py, rgb,
                         expected(check_bars, check_buf, px, py));
            mismatches <= mismatches + 1;
        end
    end

    task wait_vsync;
        begin
            @(posedge pix_clk);
            while (!frame_end) @(posedge pix_clk);
            @(posedge pix_clk);
        end
    endtask

    // A whole frame, from one vertical sync to the next.
    task check_frame(input bars, input b);
        integer start;
        begin
            wait_vsync;
            start = mismatches;
            check_bars = bars;
            check_buf = b;
            checking = 1'b1;
            wait_vsync;
            checking = 1'b0;
            if (mismatches != start)
                fail("picture mismatch");
            $display("frame %s buffer %0d: %0d mismatches", bars ? "bars" : "picture", b,
                     mismatches - start);
        end
    endtask

    integer x, y, i, f0, f1;
    reg [31:0] w;
    initial begin
        repeat (5) @(posedge clk);
        resetn = 1'b1;
        @(posedge pix_clk);
        pix_reset = 1'b0;

        rd32(REGS + 32'hc, w);
        if (w !== 32'h544e5631) fail("ID");
        rd32(REGS, w);
        if (w !== 32'd0) fail("CTRL reset value");

        // Errors, each followed by a good transfer.
        expect_error(1'b0, PAL, 3'd2);
        expect_error(1'b0, EMPH, 3'd2);
        expect_error(1'b0, FB, 3'd2);
        expect_error(1'b1, FB, 3'd2);
        // ASPECT is the eighth register: readable, writable, and 1:1 out of
        // reset. It used to sit outside the window, where a read was an error.
        rd32(REGS + 32'h1c, w);
        if (w !== 32'd1) begin
            $display("ASPECT reset value %h", w);
            fail("ASPECT reset");
        end
        wr32(REGS + 32'h1c, 32'd1);
        expect_error(1'b1, REGS + 32'h18, 3'd2);
        expect_error(1'b1, REGS + 32'h4, 3'd2);
        expect_error(1'b1, REGS + 32'hc, 3'd2);
        expect_error(1'b1, REGS, 3'd0);
        expect_error(1'b0, REGS + 32'h2, 3'd1);
        expect_error(1'b1, PAL + 32'h1, 3'd0);
        expect_error(1'b1, EMPH, 3'd1);
        expect_error(1'b1, REGS + 32'h10, 3'd2);
        expect_error(1'b0, REGS + 32'h3000, 3'd2);
        expect_error(1'b1, EMPH + 32'h800, 3'd2);
        expect_error(1'b1, FB + 32'h1, 3'd2);
        expect_error(1'b1, FB + 32'h1, 3'd1);
        expect_error(1'b1, REGS - 32'h10000, 3'd2);
        rd32(REGS + 32'hc, w);
        if (w !== 32'h544e5631) fail("ID after errors");

        // Colour bars until the frame buffers are enabled.
        check_frame(1'b1, 1'b0);

        for (i = 0; i < 768; i = i + 1)
            wr32(PAL + 4 * i, {8'hee, pal_rgb(i)});
        // Back to back, so each waits for the one before to cross.
        for (i = 0; i < 512; i = i + 1)
            wr32(EMPH + 4 * i, {29'h1234567, emph(i[8], i[7:0])});
        for (i = 0; i < 2; i = i + 1)
            for (y = 0; y < 256; y = y + 1)
                for (x = 0; x < 256; x = x + 1)
                    fbmem[{i[0], y[7:0], x[7:0]}] = y < 240 ? fb_pix(i[0], x, y) : 8'hxx;

        rd32(REGS + 32'h4, w);
        if (w[2:1] !== 2'b00) fail("STATUS before enable");
        wr32(REGS, 32'hfffffff1);
        rd32(REGS, w);
        if (w !== 32'd1) fail("CTRL readback");
        do rd32(REGS + 32'h4, w); while (!w[2]);
        if (w[1]) fail("STATUS buffer after enable");
        check_frame(1'b0, 1'b0);
        f0 = fetches;
        wait_vsync;
        if (fetches - f0 != 240) begin
            $display("%0d line fetches in a frame", fetches - f0);
            fail("fetches per frame");
        end
        f1 = 0;
        for (y = 0; y < 240; y = y + 1)
            for (x = 0; x < 256; x = x + 1)
                f1 = f1 + (fb_pix(0, x, y) != 8'd0);
        rd32(REGS + 32'h14, w);
        if (w !== 9 * f1) begin
            $display("PIXELS %0d, expected %0d", w, 9 * f1);
            fail("PIXELS");
        end
        rd32(REGS + 32'h18, w);
        if (w !== 32'h0000ffff) begin
            $display("BITS %h", w);
            fail("BITS");
        end
        rd32(REGS + 32'h10, w);
        if (w !== 32'd0) fail("LATE with prompt fetches");

        // vblank in STATUS, and FRAMES counts frames.
        wait_vsync;
        rd32(REGS + 32'h4, w);
        if (!w[0]) fail("STATUS vblank in sync");
        rd32(REGS + 32'h8, f0);
        wait_vsync;
        wait_vsync;
        rd32(REGS + 32'h8, f1);
        if (f1 - f0 != 2) begin
            $display("FRAMES %0d then %0d", f0, f1);
            fail("FRAMES");
        end
        @(posedge pix_clk);
        while (!de) @(posedge pix_clk);
        rd32(REGS + 32'h4, w);
        if (w[0]) fail("STATUS vblank in picture");

        // Flip to buffer 1; the picture changes only at a frame boundary.
        wr32(REGS, 32'd3);
        do rd32(REGS + 32'h4, w); while (!w[1]);
        check_frame(1'b0, 1'b1);

        // Fetches slower than a line (66.7 us) are counted once per line.
        wait_vsync;
        fetch_delay = 5200;
        wait_vsync;
        wait_vsync;
        fetch_delay = 40;
        rd32(REGS + 32'h10, w);
        if (w < 32'd200) begin
            $display("LATE %0d after slow fetches", w);
            fail("LATE with slow fetches");
        end
        wait_vsync;
        rd32(REGS + 32'h10, f0);
        check_frame(1'b0, 1'b1);
        rd32(REGS + 32'h10, f1);
        if (f1 != f0) fail("LATE after fetches recover");

        wr32(REGS, 32'd2);
        do rd32(REGS + 32'h4, w); while (w[2]);
        f0 = fetches;
        check_frame(1'b1, 1'b0);
        if (fetches != f0) fail("fetches with the bars shown");
        if (bad_fetches != 0) fail("fetch address");
        // The line buffers keep the last two lines fetched, 238 and 239 of
        // buffer 1, and read back through the diagnostic window.
        for (i = 0; i < 256; i = i + 1) begin
            rd32(REGS + 32'h800 + 4 * i, w);
            y = 238 + i / 128;
            x = 2 * (i % 128);
            if (w !== {16'd0, fbmem[{1'b1, y[7:0], x[7:0] + 8'd1}], fbmem[{1'b1, y[7:0], x[7:0]}]}) begin
                if (errors < 5) $display("line buffer %0d reads %h", i, w);
                fail("line buffer readback");
            end
        end
        expect_error(1'b1, REGS + 32'h800, 3'd2);

        // The desk layer. The font file is the one built in; 'A' is
        // checked against font8x8's own rendering of it.
        if ({font[8*65], font[8*65+1], font[8*65+2], font[8*65+3], font[8*65+4],
             font[8*65+5], font[8*65+6], font[8*65+7]} !== 64'h0c1e33333f333300)
            fail("font glyph A");
        for (i = 0; i < 3600; i = i + 1) begin
            @(negedge clk);
            cell_valid = 1'b1;
            cell_addr = i;
            cell_data = desk_cell(i);
            @(posedge clk);
            while (!cell_ready) @(posedge clk);
            @(negedge clk);
            cell_valid = 1'b0;
        end
        layer_on = 1'b1;
        wait_vsync;
        check_layer = 1'b1;
        check_frame(1'b1, 1'b0);
        wr32(REGS, 32'd1);
        do rd32(REGS + 32'h4, w); while (!w[2]);
        check_frame(1'b0, 1'b0);
        layer_on = 1'b0;
        wait_vsync;
        check_layer = 1'b0;
        check_frame(1'b0, 1'b0);
        // One cell rewritten while the layer is up.
        layer_on = 1'b1;
        @(negedge clk);
        cell_valid = 1'b1;
        cell_addr = 12'd0;
        cell_data = {7'h41, 15'h7fff, 15'h0000};
        @(posedge clk);
        while (!cell_ready) @(posedge clk);
        @(negedge clk);
        cell_valid = 1'b0;
        wait_vsync;
        wait_vsync;
        @(posedge pix_clk);
        while (!(de && px == 11'd0)) @(posedge pix_clk);
        // The first line of cell 0 shows glyph 'A' row 0, 0x0c: columns 2
        // and 3 white, drawn at pixels 4 to 7.
        for (i = 0; i < 16; i = i + 1) begin
            if (rgb !== ((i / 2 == 2 || i / 2 == 3) ? 24'hffffff : 24'h000000)) begin
                $display("cell 0 pixel %0d is %h", i, rgb);
                fail("rewritten cell");
            end
            @(posedge pix_clk);
        end
        layer_on = 1'b0;

        // The pixel aspect. The picture widens to 878 or 960 columns and the
        // side bars shrink to match, every source pixel still drawn but one
        // into three columns or four rather than always three. The register
        // is taken at the vertical blank, so each is checked a frame later.
        for (i = 0; i < 3; i = i + 1) begin
            wr32(REGS + 32'h1c, i[1:0]);
            rd32(REGS + 32'h1c, w);
            if (w !== i) begin
                $display("ASPECT reads %h after writing %0d", w, i);
                fail("ASPECT readback");
            end
            check_aspect = i[1:0];
            check_frame(1'b0, 1'b0);
        end
        // Back to 1:1, which is the geometry every check above assumes.
        wr32(REGS + 32'h1c, 2'd1);
        check_aspect = 2'd1;

        if (errors == 0)
            $display("PASS video_tb");
        else
            $display("FAIL video_tb: %0d errors", errors);
        $finish;
    end

    initial begin
        #700_000_000;
        $display("FAIL video_tb: timeout");
        $finish;
    end
endmodule
