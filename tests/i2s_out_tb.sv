// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// i2s_out against a CS4344-style receiver: SDIN and LRCK are sampled as SCLK
// rises, a channel's word starts one SCLK after LRCK changes, and the 24-bit
// word must carry the 16-bit sample in its top bits. The test checks the
// clock ratios and edges, the sample order through the FIFO, silence and the
// underrun count when the FIFO runs dry, dropped writes when it is full, the
// flush, and the registers' ERROR responses.
module i2s_out_tb;
    reg clk = 1'b0;
    reg resetn = 1'b0;
    always #5 clk = !clk;

    reg [11:0] haddr = 12'd0;
    reg [1:0] htrans = 2'd0;
    reg hwrite = 1'b0;
    reg [2:0] hsize = 3'd2;
    reg [31:0] hwdata = 32'd0;
    wire [31:0] hrdata;
    wire hready, hresp;
    wire mclk, lrck, sclk, sdin;

    i2s_out dut (
        .clk(clk), .resetn(resetn),
        .haddr(haddr), .htrans(htrans), .hsel(1'b1), .hwrite(hwrite),
        .hsize(hsize), .hwdata(hwdata), .hready_in(hready),
        .hrdata(hrdata), .hready(hready), .hresp(hresp),
        .mclk(mclk), .lrck(lrck), .sclk(sclk), .sdin(sdin)
    );

    integer errors = 0;
    task fail(input [8*96-1:0] what);
        begin
            $display("FAIL %0s at %0t", what, $time);
            errors = errors + 1;
        end
    endtask

    // ------------------------------------------------------------ bus

    task bus_write(input [11:0] a, input [31:0] d, input [2:0] size);
        begin
            @(posedge clk); #1;
            haddr = a; htrans = 2'd2; hwrite = 1'b1; hsize = size;
            @(posedge clk); #1;
            htrans = 2'd0; hwrite = 1'b0; hwdata = d;
            while (!hready) begin @(posedge clk); #1; end
        end
    endtask

    task bus_read(input [11:0] a, output [31:0] d, output err);
        begin
            @(posedge clk); #1;
            haddr = a; htrans = 2'd2; hwrite = 1'b0; hsize = 3'd2;
            @(posedge clk); #1;
            htrans = 2'd0;
            err = hresp;
            while (!hready) begin @(posedge clk); #1; err = err | hresp; end
            d = hrdata;
        end
    endtask

    task expect_reg(input [11:0] a, input [31:0] want, input [8*32-1:0] name);
        reg [31:0] got;
        reg err;
        begin
            bus_read(a, got, err);
            if (err || got !== want) begin
                $display("     %0s read %08h err %0d, want %08h", name, got, err, want);
                fail("register value");
            end
        end
    endtask

    task expect_error(input [11:0] a, input write, input [2:0] size);
        reg seen;
        begin
            seen = 1'b0;
            @(posedge clk); #1;
            haddr = a; htrans = 2'd2; hwrite = write; hsize = size;
            @(posedge clk); #1;
            htrans = 2'd0; hwrite = 1'b0;
            if (hresp && !hready) seen = 1'b1;
            @(posedge clk); #1;
            if (!(seen && hresp && hready)) fail("two-cycle ERROR response");
            @(posedge clk); #1;
        end
    endtask

    // ------------------------------------------------------------ clocks

    integer t = 0;                  // bus clocks since reset
    always @(posedge clk) t <= t + 1;

    integer last_mclk_rise = -1, last_sclk_rise = -1, last_lrck_change = -1;
    integer last_sdin_change = -1, last_sclk_fall = -1;
    integer mclk_high_start = -1;
    reg mclk_q = 0, sclk_q = 0, lrck_q = 0, sdin_q = 0;
    integer clock_checks = 0;
    always @(posedge clk) if (resetn) begin
        #2;
        if (mclk && !mclk_q) begin
            if (last_mclk_rise >= 0 && t - last_mclk_rise != 6) fail("MCLK period is not 6 bus clocks");
            last_mclk_rise = t;
            mclk_high_start = t;
        end
        if (!mclk && mclk_q && t - mclk_high_start != 3) fail("MCLK is not high for 3 bus clocks");
        if (sclk && !sclk_q) begin
            if (last_sclk_rise >= 0 && t - last_sclk_rise != 24) fail("SCLK period is not 4 MCLKs");
            last_sclk_rise = t;
            clock_checks = clock_checks + 1;
        end
        if (!sclk && sclk_q) last_sclk_fall = t;
        if (lrck != lrck_q) begin
            if (last_lrck_change >= 0 && t - last_lrck_change != 768) fail("LRCK half period is not 128 MCLKs");
            if (sclk || t != last_sclk_fall) fail("LRCK changed other than as SCLK fell");
            last_lrck_change = t;
        end
        if (sdin != sdin_q && (sclk || t != last_sclk_fall)) fail("SDIN changed other than as SCLK fell");
        // Every clock edge comes from an MCLK edge.
        if ((sclk != sclk_q) && (mclk || !mclk_q)) fail("SCLK edge not on an MCLK falling edge");
        mclk_q = mclk; sclk_q = sclk; lrck_q = lrck; sdin_q = sdin;
    end

    // ------------------------------------------------------------ receiver

    // One decoded frame per LRCK period, left then right.
    reg [15:0] got_l [0:255];
    reg [15:0] got_r [0:255];
    integer got_n = 0;
    reg rx_lrck = 1'b0;
    reg synced = 1'b0;              // a whole channel has been seen
    integer bit_n = 0;
    reg [31:0] word = 32'd0;
    reg [15:0] left_word = 16'd0;
    always @(posedge sclk) if (resetn) begin
        if (lrck != rx_lrck) begin
            // The first rise of a channel samples its delay bit.
            if (sdin) fail("delay bit set");
            if (synced && bit_n != 32) fail("channel not 32 SCLKs");
            if (!synced) begin
                // The channel before was cut by reset; start from here.
            end else if (rx_lrck == 1'b0) begin
                left_word = word[31:16];
            end else if (got_n < 256) begin
                got_l[got_n] = left_word;
                got_r[got_n] = word[31:16];
                got_n = got_n + 1;
            end
            synced = synced || rx_lrck == 1'b1;
            rx_lrck = lrck;
            bit_n = 1;
            word = 32'd0;
        end else begin
            // Rises 1 to 24 carry the 24-bit word, MSB first.
            if (bit_n >= 1 && bit_n <= 24)
                word[32 - bit_n] = sdin;
            else if (sdin)
                fail("padding bit set");
            bit_n = bit_n + 1;
        end
    end

    // ------------------------------------------------------------ test

    localparam [11:0] ID = 12'h000, CTRL = 12'h004, STATUS = 12'h008,
                      DATA = 12'h00c, FRAMES = 12'h010, DROPS = 12'h014;
    reg [31:0] samples [0:7];
    reg [31:0] v;
    reg e;
    integer i, start, first;

    initial begin
        samples[0] = 32'h12345678; samples[1] = 32'h8000_7fff;
        samples[2] = 32'hffff_0001; samples[3] = 32'h0001_ffff;
        samples[4] = 32'h5a5a_a5a5; samples[5] = 32'h7fff_8000;
        samples[6] = 32'h0f0f_f0f0; samples[7] = 32'hdead_beef;

        repeat (5) @(posedge clk);
        resetn = 1'b1;

        expect_reg(ID, 32'h544e4131, "ID");
        expect_reg(CTRL, 32'd0, "CTRL");
        expect_reg(STATUS, 32'd0, "STATUS");
        expect_error(12'h018, 1'b0, 3'd2);
        expect_error(ID, 1'b1, 3'd2);
        expect_error(STATUS, 1'b0, 3'd1);
        expect_error(DATA, 1'b0, 3'd2);

        // Disabled: silence and no underruns.
        repeat (3 * 1536) @(posedge clk);
        if (got_n < 2) fail("no frames while disabled");
        for (i = 0; i < got_n; i = i + 1)
            if (got_l[i] != 0 || got_r[i] != 0) fail("sound while disabled");
        expect_reg(STATUS, 32'd0, "STATUS disabled");

        // A STATUS read in the data phase of a DATA write sees the write.
        @(posedge clk); #1;
        haddr = DATA; htrans = 2'd2; hwrite = 1'b1; hsize = 3'd2;
        @(posedge clk); #1;
        hwdata = 32'h0;
        haddr = STATUS; htrans = 2'd2; hwrite = 1'b0;
        @(posedge clk); #1;
        htrans = 2'd0;
        if (hrdata !== 32'd1) fail("STATUS read after DATA write missed it");
        bus_write(CTRL, 32'd2, 3'd2);

        // Eight pairs back to back, then play them.
        for (i = 0; i < 8; i = i + 1)
            bus_write(DATA, samples[i], 3'd2);
        expect_reg(STATUS, 32'd8, "STATUS after 8 writes");
        start = got_n;
        bus_write(CTRL, 32'd1, 3'd2);
        expect_reg(CTRL, 32'd1, "CTRL enabled");
        repeat (14 * 1536) @(posedge clk);
        first = -1;
        for (i = start; i < got_n; i = i + 1)
            if (first < 0 && (got_l[i] != 0 || got_r[i] != 0)) first = i;
        if (first < 0) fail("no samples played");
        else begin
            for (i = 0; i < 8; i = i + 1)
                if ({got_l[first + i], got_r[first + i]} != samples[i]) begin
                    $display("     frame %0d got %04h %04h want %08h", i,
                             got_l[first + i], got_r[first + i], samples[i]);
                    fail("sample order");
                end
            for (i = first + 8; i < got_n; i = i + 1)
                if (got_l[i] != 0 || got_r[i] != 0) fail("sound after the FIFO emptied");
        end
        bus_read(STATUS, v, e);
        if (v[11:0] != 0) fail("FIFO not empty after playing");
        if (v[31:16] < 3 || v[31:16] > 6) begin
            $display("     underruns %0d", v[31:16]);
            fail("underrun count");
        end
        bus_read(FRAMES, v, e);
        if (v < got_n || v > got_n + 3) begin
            $display("     FRAMES %0d, decoded %0d", v, got_n);
            fail("FRAMES does not match the frames sent");
        end

        // Full: 2048 kept, the rest dropped, then a flush.
        bus_write(CTRL, 32'd0, 3'd2);
        for (i = 0; i < 2051; i = i + 1)
            bus_write(DATA, i, 3'd2);
        bus_read(STATUS, v, e);
        if (v[11:0] != 12'd2048) fail("level not 2048 when full");
        expect_reg(DROPS, 32'd3, "DROPS");
        bus_write(CTRL, 32'd2, 3'd2);
        bus_read(STATUS, v, e);
        if (v[11:0] != 0) fail("flush left entries");
        expect_reg(CTRL, 32'd0, "CTRL after flush");

        if (clock_checks < 100) fail("too few SCLK edges checked");
        if (errors == 0)
            $display("PASS i2s_out: %0d frames decoded, %0d SCLK periods checked", got_n, clock_checks);
        else
            $display("FAIL i2s_out: %0d errors", errors);
        $finish;
    end
endmodule
