// SPDX-License-Identifier: MIT
// The video unit on its own: registers and error responses over AHB, and
// whole 1280x720 frames decoded from the TMDS words and compared, pixel by
// pixel, with a model of the colour bars and of both frame buffers with
// palette and emphasis. The frame buffers are a model of ahb_sdram's video
// channel with a set latency. Also checks the sync timing, the buffer flip,
// the line fetch addresses and the LATE count when fetches are too slow.
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
    wire [9:0] tmds_b, tmds_g, tmds_r;
    wire vstart;
    wire [24:8] vaddr;
    reg vvalid = 1'b0, vdone = 1'b0;
    reg [6:0] vindex = 7'd0;
    reg [15:0] vdata = 16'd0;

    video dut (
        .clk(clk), .resetn(resetn),
        .haddr(haddr[17:0]), .htrans(htrans), .hsel(hsel), .hwrite(hwrite),
        .hsize(hsize), .hwdata(hwdata), .hready_in(hready),
        .hrdata(hrdata), .hready(hready), .hresp(hresp),
        .vstart(vstart), .vaddr(vaddr), .vvalid(vvalid), .vindex(vindex),
        .vdata(vdata), .vdone(vdone),
        .pix_clk(pix_clk), .pix_reset(pix_reset),
        .tmds_blue(tmds_b), .tmds_green(tmds_g), .tmds_red(tmds_r)
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
    function [23:0] expected(input bars, input b, input [10:0] col, input [9:0] row);
        reg [7:0] nx, ny, p;
        reg [2:0] e, bar;
        reg [9:0] idx;
        begin
            if (bars) begin
                bar = col / 160;
                expected = {(bar == 0 || bar == 1 || bar == 4 || bar == 5) ? 8'd192 : 8'd16,
                            (bar == 0 || bar == 1 || bar == 2 || bar == 3) ? 8'd192 : 8'd16,
                            (bar == 0 || bar == 2 || bar == 4 || bar == 6) ? 8'd192 : 8'd16};
            end else if (col < 256 || col >= 1024) begin
                expected = 24'd0;
            end else begin
                nx = (col - 256) / 3;
                ny = row / 3;
                p = fb_pix(b, nx, ny);
                e = emph(b, ny);
                idx = e == 3'd0 ? {2'b00, p} : 10'd256 + {1'b0, e, 6'd0} + {4'd0, p[5:0]};
                expected = pal_rgb(idx);
            end
        end
    endfunction

    // ----------------------------------------------------- TMDS decoder --
    function [10:0] tmds_decode(input [9:0] q); // {is_data, ctrl[1:0] or data}
        reg [7:0] d, o;
        integer k;
        begin
            case (q)
                10'b1101010100: tmds_decode = {1'b0, 8'd0, 2'b00};
                10'b0010101011: tmds_decode = {1'b0, 8'd0, 2'b01};
                10'b0101010100: tmds_decode = {1'b0, 8'd0, 2'b10};
                10'b1010101011: tmds_decode = {1'b0, 8'd0, 2'b11};
                default: begin
                    d = q[9] ? ~q[7:0] : q[7:0];
                    o[0] = d[0];
                    for (k = 1; k < 8; k = k + 1)
                        o[k] = q[8] ? d[k] ^ d[k-1] : ~(d[k] ^ d[k-1]);
                    tmds_decode = {1'b1, o, 2'b00};
                end
            endcase
        end
    endfunction

    wire [10:0] db = tmds_decode(tmds_b), dg = tmds_decode(tmds_g), dr = tmds_decode(tmds_r);
    wire de = db[10];
    wire hs = !de && db[0];
    wire vs = !de && db[1];
    wire [23:0] rgb = {dr[9:2], dg[9:2], db[9:2]};

    // Raster checks run from the first vertical sync (the encoders send zeros,
    // which decode as data, in reset); picture checks while `checking`.
    reg prev_de = 1'b0, prev_hs = 1'b0, prev_vs = 1'b0;
    integer since_hs = -1, de_len = 0, lines = -1, de_lines = 0, vs_lines = 0;
    integer bp_lines = 0, col = 0, row = 0;
    reg seen_de_since_vs = 1'b0;
    integer vs_edges = 0;
    reg checking = 1'b0, check_bars = 1'b0, check_buf = 1'b0;
    integer mismatches = 0;
    integer raster_errors = 0;

    wire armed = vs_edges > 0;
    always @(posedge pix_clk) if (!pix_reset) begin
        if (since_hs >= 0)
            since_hs <= since_hs + 1;
        if (armed && de && (dr[10] !== 1'b1 || dg[10] !== 1'b1))
            raster_errors <= raster_errors + 1;
        if (hs && !prev_hs) begin
            if (armed && since_hs != 1649) begin
                if (raster_errors < 5) $display("hsync period %0d", since_hs + 1);
                raster_errors <= raster_errors + 1;
            end
            since_hs <= 0;
            lines <= lines + 1;
            if (vs)
                vs_lines <= vs_lines + 1;
            if (!vs && !seen_de_since_vs && lines >= 0)
                bp_lines <= bp_lines + 1;
        end
        if (armed && !hs && prev_hs && since_hs != 39) begin
            if (raster_errors < 5) $display("hsync width %0d", since_hs + 1);
            raster_errors <= raster_errors + 1;
        end
        if (de && !prev_de) begin
            if (armed && since_hs != 259) begin
                if (raster_errors < 5) $display("hsync to active %0d", since_hs + 1);
                raster_errors <= raster_errors + 1;
            end
            de_len <= 1;
            col <= 1;
        end else if (de) begin
            de_len <= de_len + 1;
            col <= col + 1;
        end
        if (!de && prev_de) begin
            if (armed && de_len != 1280) begin
                if (raster_errors < 5) $display("active length %0d", de_len);
                raster_errors <= raster_errors + 1;
            end
            de_lines <= de_lines + 1;
            row <= row + 1;
            seen_de_since_vs <= 1'b1;
        end
        if (de && checking && rgb !== expected(check_bars, check_buf, de && !prev_de ? 0 : col, row)) begin
            if (mismatches < 5)
                $display("pixel (%0d, %0d) %h, expected %h", de && !prev_de ? 0 : col, row, rgb,
                         expected(check_bars, check_buf, de && !prev_de ? 0 : col, row));
            mismatches <= mismatches + 1;
        end
        if (vs && !prev_vs) begin
            vs_edges <= vs_edges + 1;
            if (lines >= 0 && vs_edges > 0) begin
                if (lines != 750 || de_lines != 720 || vs_lines != 5 || bp_lines != 20) begin
                    $display("frame: %0d lines, %0d active, %0d sync, %0d back porch",
                             lines, de_lines, vs_lines, bp_lines);
                    raster_errors <= raster_errors + 1;
                end
            end
            lines <= 0;
            de_lines <= 0;
            vs_lines <= 0;
            bp_lines <= 0;
            row <= 0;
            seen_de_since_vs <= 1'b0;
        end
        prev_de <= de;
        prev_hs <= hs;
        prev_vs <= vs;
    end

    task wait_vsync;
        begin
            @(posedge pix_clk);
            while (!(vs && !prev_vs)) @(posedge pix_clk);
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
        expect_error(1'b0, REGS + 32'h1c, 3'd2);
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

        if (raster_errors != 0) fail("raster timing");
        if (errors == 0)
            $display("PASS video_tb");
        else
            $display("FAIL video_tb: %0d errors", errors);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL video_tb: timeout");
        $finish;
    end
endmodule
