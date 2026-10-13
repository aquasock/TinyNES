// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// The FPGA UART's link mode: exts_uart and desk_link together, driven by
// an AHB master for the CPU, a UART sender for TinyTang and a UART receiver
// that the checks read the line from byte by byte or frame by frame. The
// report and text timings are shortened; the UART runs at 2,000,000 baud
// from 75 MHz as on the board.
module desk_link_tb;
    localparam real CLK_NS = 1000.0 / 75.0;
    localparam real BIT_NS = 500.0;
    localparam integer REPORT_CLOCKS = 20000;
    localparam integer REFRESH_REPORTS = 4;
    localparam integer TAP_REPORTS = 3;
    localparam integer TEXT_MAX = 128;
    localparam integer TEXT_IDLE_CLOCKS = 3000;
    localparam [31:0] BASE = 32'he8000000;

    reg clk = 1'b0;
    always #(CLK_NS / 2.0) clk = !clk;
    reg resetn = 1'b0;

    reg [31:0] haddr = 32'd0;
    reg [1:0] htrans = 2'b00;
    reg hsel = 1'b0, hwrite = 1'b0;
    reg [31:0] hwdata = 32'd0;
    wire [31:0] hrdata;
    wire hready, hresp;

    wire link, rx_link_valid, txt_valid, txt_ready, ln_valid, ln_ready;
    wire link_idle, link_flush, cpu_owns, tx;
    wire [7:0] rx_link_data, txt_data, ln_data;
    wire [31:0] link_status;
    reg rx = 1'b1;
    reg [15:0] pad_held = 16'd0;
    wire cell_valid, layer_on;
    wire [11:0] cell_addr;
    wire [36:0] cell_data;
    reg cell_ready = 1'b0;

    exts_uart #(.UART_DIV2(75)) regs (
        .clk(clk), .resetn(resetn), .haddr(haddr), .htrans(htrans), .hsel(hsel),
        .hwrite(hwrite), .hwdata(hwdata), .hready_in(hready), .hrdata(hrdata),
        .hready(hready), .hresp(hresp),
        .fb_valid(1'b0), .fb_data(8'd0), .fb_ready(), .cpu_owns(cpu_owns),
        .link(link), .rx_link_valid(rx_link_valid), .rx_link_data(rx_link_data),
        .txt_valid(txt_valid), .txt_data(txt_data), .txt_ready(txt_ready),
        .ln_valid(ln_valid), .ln_data(ln_data), .ln_ready(ln_ready),
        .link_idle(link_idle), .link_flush(link_flush), .link_status(link_status),
        .tx(tx), .rx(rx)
    );

    desk_link #(
        .REPORT_CLOCKS(REPORT_CLOCKS), .REFRESH_REPORTS(REFRESH_REPORTS),
        .TAP_REPORTS(TAP_REPORTS), .TEXT_MAX(TEXT_MAX),
        .TEXT_IDLE_CLOCKS(TEXT_IDLE_CLOCKS)
    ) desk (
        .clk(clk), .resetn(resetn), .link(link),
        .rx_valid(rx_link_valid), .rx_data(rx_link_data),
        .txt_valid(txt_valid), .txt_data(txt_data), .txt_ready(txt_ready),
        .flush(link_flush),
        .ln_valid(ln_valid), .ln_data(ln_data), .ln_ready(ln_ready),
        .idle(link_idle), .pad_held(pad_held),
        .cell_valid(cell_valid), .cell_addr(cell_addr), .cell_data(cell_data),
        .cell_ready(cell_ready), .layer_on(layer_on), .status(link_status)
    );

    // ----------------------------------------------------------- the CPU --
    task ahb(input [31:0] addr, input write, input [31:0] wdata,
                       output [31:0] rdata, output err);
        integer cycles;
        begin
            @(negedge clk);
            haddr = addr;
            htrans = 2'b10;
            hwrite = write;
            hsel = 1'b1;
            @(posedge clk);
            while (hready !== 1'b1)
                @(posedge clk);
            @(negedge clk);
            htrans = 2'b00;
            hsel = 1'b0;
            hwdata = wdata;
            cycles = 0;
            @(posedge clk);
            while (hready !== 1'b1) begin
                cycles = cycles + 1;
                if (cycles > 2000000)
                    $fatal(1, "AHB transfer at %08x timed out", addr);
                @(posedge clk);
            end
            rdata = hrdata;
            err = hresp;
        end
    endtask

    task wr(input [31:0] offset, input [31:0] value);
        reg [31:0] d;
        reg e;
        begin
            ahb(BASE + offset, 1'b1, value, d, e);
            if (e !== 1'b0)
                $fatal(1, "write %02x got ERROR", offset);
        end
    endtask

    task rd(input [31:0] offset, output [31:0] value);
        reg e;
        begin
            ahb(BASE + offset, 1'b0, 32'd0, value, e);
            if (e !== 1'b0)
                $fatal(1, "read %02x got ERROR", offset);
        end
    endtask

    task put_char(input [7:0] c);
        reg [31:0] s;
        begin
            rd(32'h04, s);
            while (!s[0])
                rd(32'h04, s);
            wr(32'h00, {24'd0, c});
        end
    endtask

    // ------------------------------------------------------- the line in --
    task send_byte(input [7:0] value);
        integer i;
        begin
            rx = 1'b0;
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                rx = value[i];
                #(BIT_NS);
            end
            rx = 1'b1;
            #(BIT_NS);
        end
    endtask

    reg [7:0] frame_out [0:2047];
    task send_frame(input [7:0] ftype, input integer n);
        integer i;
        begin
            send_byte(8'haa);
            send_byte((n + 1) >> 8);
            send_byte((n + 1) & 8'hff);
            send_byte(ftype);
            for (i = 0; i < n; i = i + 1)
                send_byte(frame_out[i]);
        end
    endtask

    // ------------------------------------------------------ the line out --
    reg [7:0] line [0:65535];
    integer line_w = 0, line_r = 0;
    initial begin : receiver
        integer i;
        reg [7:0] b;
        forever begin
            @(negedge tx);
            #(BIT_NS / 2.0);
            if (tx !== 1'b0)
                $fatal(1, "UART start bit glitch");
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT_NS);
                b[i] = tx;
            end
            #(BIT_NS);
            if (tx !== 1'b1)
                $fatal(1, "UART stop bit missing");
            line[line_w] = b;
            line_w = line_w + 1;
        end
    end

    task next_byte(output [7:0] b, input integer timeout_us);
        real t0;
        begin
            t0 = $realtime;
            while (line_r == line_w) begin
                #(1000);
                if ($realtime - t0 > timeout_us * 1000.0)
                    $fatal(1, "nothing on the line for %0d us", timeout_us);
            end
            b = line[line_r];
            line_r = line_r + 1;
        end
    endtask

    task expect_raw(input [8*32-1:0] text, input integer n);
        integer i;
        reg [7:0] b;
        begin
            for (i = n - 1; i >= 0; i = i - 1) begin
                next_byte(b, 2000);
                if (b !== text[8*i +: 8])
                    $fatal(1, "raw byte %0d is %02x, expected %02x", n - 1 - i, b,
                           text[8*i +: 8]);
            end
        end
    endtask

    // The next frame; joypad reports are kept as the newest and skipped
    // unless want is 0x03.
    reg [7:0] f_type;
    integer f_len;
    reg [7:0] f_body [0:2047];
    reg [15:0] j1_last = 16'hffff;
    integer pads_seen = 0;
    task next_frame(input [7:0] want, input integer timeout_us);
        reg [7:0] b, hi, lo;
        integer i;
        reg done;
        real t0;
        begin
            done = 1'b0;
            t0 = $realtime;
            while (!done) begin
                if ($realtime - t0 > timeout_us * 1000.0)
                    $fatal(1, "no frame of type %02x in %0d us", want, timeout_us);
                next_byte(b, timeout_us);
                if (b !== 8'haa)
                    $fatal(1, "frame starts with %02x", b);
                next_byte(hi, 100);
                next_byte(lo, 100);
                if (hi >= 8'd8 || {hi, lo} == 16'd0)
                    $fatal(1, "frame length %02x%02x", hi, lo);
                next_byte(f_type, 100);
                f_len = {hi, lo} - 1;
                for (i = 0; i < f_len; i = i + 1)
                    next_byte(f_body[i], 100);
                if (f_type == 8'h03) begin
                    if (f_len != 4 || f_body[2] !== 8'd0 || f_body[3] !== 8'd0)
                        $fatal(1, "bad joypad report, %0d bytes", f_len);
                    j1_last = {f_body[0], f_body[1]};
                    pads_seen = pads_seen + 1;
                end
                done = f_type == want || f_type != 8'h03;
            end
            if (f_type !== want)
                $fatal(1, "frame type %02x, expected %02x", f_type, want);
        end
    endtask

    task expect_text(input [8*160-1:0] text, input integer n);
        integer i;
        begin
            next_frame(8'h20, 5000);
            if (f_len != n)
                $fatal(1, "text frame of %0d bytes, expected %0d", f_len, n);
            for (i = 0; i < n; i = i + 1)
                if (f_body[i] !== text[8*(n - 1 - i) +: 8])
                    $fatal(1, "text byte %0d is %02x, expected %02x", i, f_body[i],
                           text[8*(n - 1 - i) +: 8]);
        end
    endtask

    // Report j1 within a few ticks.
    task expect_pad(input [15:0] j1);
        integer tries;
        begin
            tries = 0;
            next_frame(8'h03, 2000);
            while (j1_last !== j1) begin
                tries = tries + 1;
                if (tries > 4)
                    $fatal(1, "joypad report %04x, expected %04x", j1_last, j1);
                next_frame(8'h03, 2000);
            end
        end
    endtask

    // ---------------------------------------------------- the cell store --
    reg [36:0] store [0:4095];
    integer cell_writes = 0;
    reg [15:0] lfsr = 16'hace1;
    always @(posedge clk) begin
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        cell_ready <= lfsr[0] & lfsr[3];
        if (cell_valid && cell_ready) begin
            store[cell_addr] <= cell_data;
            cell_writes <= cell_writes + 1;
        end
    end
    integer link_bytes_in_loader = 0;
    always @(posedge clk)
        if (rx_link_valid && !link)
            link_bytes_in_loader <= link_bytes_in_loader + 1;

    function [36:0] cell_word(input [7:0] ch, input [15:0] fg, input [15:0] bg);
        cell_word = {ch[6:0], fg[14:0], bg[14:0]};
    endfunction

    task put_cells(input integer x, input integer y, input integer n,
                             input integer seed);
        integer i;
        begin
            frame_out[0] = x;
            frame_out[1] = y;
            send_frame(8'h13, 2);
            for (i = 0; i < n; i = i + 1) begin
                frame_out[5*i] = 8'h21 + (seed + i) % 94;
                frame_out[5*i+1] = (seed * 7 + i) & 8'h7f;
                frame_out[5*i+2] = (seed * 13 + i * 3) & 8'hff;
                frame_out[5*i+3] = (seed * 3 + i * 5) & 8'h7f;
                frame_out[5*i+4] = (seed * 11 + i * 9) & 8'hff;
            end
            send_frame(8'h14, 5 * n);
        end
    endtask

    task check_cells(input integer x, input integer y, input integer n,
                               input integer seed);
        integer i, a;
        reg [36:0] want;
        reg [7:0] fh, fl, bh, bl;
        begin
            for (i = 0; i < n; i = i + 1) begin
                a = 80 * y + x + i;
                fh = (seed * 7 + i) & 8'h7f;
                fl = (seed * 13 + i * 3) & 8'hff;
                bh = (seed * 3 + i * 5) & 8'h7f;
                bl = (seed * 11 + i * 9) & 8'hff;
                want = cell_word(8'h21 + (seed + i) % 94, {fh, fl}, {bh, bl});
                if (a < 3600 && store[a] !== want)
                    $fatal(1, "cell %0d is %h, expected %h", a, store[a], want);
            end
        end
    endtask

    task wait_clocks(input integer n);
        repeat (n) @(posedge clk);
    endtask

    // ----------------------------------------------------------- the test --
    integer i, writes0;
    reg [31:0] v;
    reg e;
    reg [8*160-1:0] long_text;
    initial begin
        for (i = 0; i < 4096; i = i + 1)
            store[i] = 37'd0;
        repeat (20) @(posedge clk);
        resetn = 1'b1;
        repeat (20) @(posedge clk);

        // Loader mode: raw bytes both ways, nothing parsed.
        rd(32'h14, v);
        if (v !== 32'd0)
            $fatal(1, "CTRL after reset is %08x", v);
        put_char("o");
        put_char("k");
        put_char(8'h0a);
        expect_raw("ok\n", 3);
        send_byte(8'haa);
        send_byte(8'h00);
        send_byte(8'h01);
        send_byte(8'h01);
        wait_clocks(400);
        for (i = 0; i < 4; i = i + 1) begin
            rd(32'h10, v);
            if (v !== {23'd0, 1'b1, i == 0 ? 8'haa : i == 1 ? 8'h00 : 8'h01})
                $fatal(1, "loader RX byte %0d is %08x", i, v);
        end
        wait_clocks(5000);
        if (line_r != line_w)
            $fatal(1, "a core ID was answered in loader mode");
        if (link_bytes_in_loader != 0)
            $fatal(1, "bytes reached the link in loader mode");
        $display("PASS: loader mode keeps raw bytes and the receive buffer");

        // Link mode, the core ID and frames TinyTang sends.
        wr(32'h14, 32'd1);
        rd(32'h14, v);
        if (v !== 32'd1)
            $fatal(1, "CTRL is %08x after setting link mode", v);
        send_frame(8'h01, 0);
        next_frame(8'h01, 2000);
        if (f_len != 1 || f_body[0] !== 8'h4e)
            $fatal(1, "core ID reply of %0d bytes, %02x", f_len, f_body[0]);
        rd(32'h04, v);
        if (v[2])
            $fatal(1, "a link byte reached the receive buffer");
        $display("PASS: link mode answers the core ID with 0x4e");

        put_cells(3, 2, 3, 1);
        put_cells(70, 44, 12, 2);   // the last ten cells of the grid, then two off it
        put_cells(0, 10, 80, 3);    // a whole row
        wait_clocks(2000);
        check_cells(3, 2, 3, 1);
        check_cells(70, 44, 12, 2);
        check_cells(0, 10, 80, 3);
        if (cell_writes != 3 + 10 + 80)
            $fatal(1, "%0d cell writes, expected 93", cell_writes);
        // A cursor off the grid drops the cells after it.
        writes0 = cell_writes;
        put_cells(80, 0, 2, 4);
        put_cells(0, 45, 2, 5);
        // A frame of another type, its payload full of 0xaa, then a length
        // too large: both skipped without losing the next frame.
        for (i = 0; i < 14; i = i + 1)
            frame_out[i] = 8'haa;
        send_frame(8'h10, 14);
        send_byte(8'haa);
        send_byte(8'h09);
        put_cells(5, 5, 4, 6);
        wait_clocks(2000);
        if (cell_writes != writes0 + 4)
            $fatal(1, "%0d cell writes after the skipped frames, expected %0d",
                   cell_writes, writes0 + 4);
        check_cells(5, 5, 4, 6);
        rd(32'h18, v);
        if (v[3] || v[31:16] != 16'd97)
            $fatal(1, "LINK status %08x: lost or wrong cell count", v);
        $display("PASS: cells from the cursor, off the grid dropped, other frames skipped");

        // The overlay and the enable.
        frame_out[0] = 8'h01;
        send_frame(8'h15, 1);
        wait_clocks(100);
        if (layer_on)
            $fatal(1, "layer on with the overlay off");
        send_frame(8'h08, 1);
        wait_clocks(100);
        rd(32'h18, v);
        if (!layer_on || v[2:0] !== 3'b111)
            $fatal(1, "layer not on, LINK status %08x", v);
        frame_out[0] = 8'h00;
        send_frame(8'h08, 1);
        wait_clocks(100);
        rd(32'h18, v);
        if (layer_on || v[2:0] !== 3'b100)
            $fatal(1, "layer still on, LINK status %08x", v);
        $display("PASS: the layer shows while the overlay and the enable are both on");

        // Joypad reports.
        pad_held = 16'd1 << 8;            // up
        expect_pad(16'h0010);
        pad_held = (16'd1 << 9) | (16'd1 << 14);   // left and B
        expect_pad(16'h0140);
        pad_held = (16'd1 << 7) | (16'd1 << 13);   // right and Y
        expect_pad(16'h0081);
        pad_held = (16'd1 << 6) | (16'd1 << 4) | (16'd1 << 2);  // down, - and +
        expect_pad(16'h0020);
        pad_held = 16'd0;
        expect_pad(16'h0000);
        pads_seen = 0;
        wait_clocks(REPORT_CLOCKS * REFRESH_REPORTS * 3);
        while (line_r != line_w)
            next_frame(8'h03, 100);
        if (pads_seen < 2 || pads_seen > 4)
            $fatal(1, "%0d refresh reports in %0d ticks", pads_seen, REFRESH_REPORTS * 3);
        $display("PASS: joypad reports on change and refreshed");

        // A tap of HOME: LB for TAP_REPORTS ticks. HOME with another
        // button pressed meanwhile is not a tap.
        pad_held = 16'd1 << 3;
        wait_clocks(REPORT_CLOCKS / 3);
        pad_held = 16'd0;
        expect_pad(16'h0400);
        pads_seen = 0;
        expect_pad(16'h0000);
        if (pads_seen < 1)
            $fatal(1, "LB was not cleared by a report");
        pad_held = 16'd1 << 3;
        wait_clocks(REPORT_CLOCKS / 3);
        pad_held = (16'd1 << 3) | (16'd1 << 4);
        expect_pad(16'h0000);
        pad_held = 16'd1 << 3;
        wait_clocks(REPORT_CLOCKS / 3);
        pad_held = 16'd0;
        wait_clocks(REPORT_CLOCKS * (REFRESH_REPORTS + 2));
        while (line_r != line_w) begin
            next_frame(8'h03, 100);
            if (j1_last[10])
                $fatal(1, "LB after HOME was held with -");
        end
        $display("PASS: a tap of HOME is LB for %0d reports, HOME with - is not", TAP_REPORTS);

        // Text: a line, a long run cut at TEXT_MAX, and a short one sent
        // after it falls quiet, with joypad reports between frames only.
        pad_held = 16'd1 << 8;
        long_text = "TinyNES LINK\r\n";
        for (i = 0; i < 14; i = i + 1)
            put_char(long_text[8*(13 - i) +: 8]);
        expect_text("TinyNES LINK\r\n", 14);
        for (i = 0; i < 300; i = i + 1) begin
            put_char("a" + i % 26);
            if (i % 37 == 0)
                pad_held = pad_held ^ (16'd1 << 6);
        end
        for (i = 0; i < 3; i = i + 1) begin : long_check
            integer k, n;
            n = i < 2 ? TEXT_MAX : 300 - 2 * TEXT_MAX;
            next_frame(8'h20, 5000);
            if (f_len != n)
                $fatal(1, "long text frame %0d of %0d bytes, expected %0d", i, f_len, n);
            for (k = 0; k < n; k = k + 1)
                if (f_body[k] !== "a" + (i * TEXT_MAX + k) % 26)
                    $fatal(1, "long text frame %0d byte %0d is %02x", i, k, f_body[k]);
        end
        put_char("x");
        put_char("y");
        rd(32'h04, v);
        if (v[1])
            $fatal(1, "STATUS %08x says idle with link text buffered", v);
        expect_text("xy", 2);
        $display("PASS: link text in frames: lines, %0d-byte cuts and quiet flushes", TEXT_MAX);

        // Back to loader mode with text buffered: the CTRL write sends it
        // first, then the CPU's bytes go out raw again.
        put_char("e");
        put_char("n");
        put_char("d");
        wr(32'h14, 32'd0);
        rd(32'h04, v);
        if (v[1:0] !== 2'b11)
            $fatal(1, "STATUS %08x after leaving link mode, expected idle", v);
        expect_text("end", 3);
        if (line_r != line_w) begin : trailing
            // A joypad report may have been under way.
            next_frame(8'h03, 100);
        end
        if (line_r != line_w)
            $fatal(1, "bytes after the flushed text");
        put_char("R");
        put_char(8'h0a);
        expect_raw("R\n", 2);
        rd(32'h18, v);
        if (layer_on || v[2:0] !== 3'b000)
            $fatal(1, "LINK status %08x after leaving link mode", v);
        wait_clocks(REPORT_CLOCKS * (REFRESH_REPORTS + 1));
        if (line_r != line_w)
            $fatal(1, "joypad reports in loader mode");
        send_byte(8'h5a);
        wait_clocks(400);
        rd(32'h10, v);
        if (v !== 32'h15a)
            $fatal(1, "loader RX after link mode is %08x", v);
        $display("PASS: leaving link mode flushes its text, then raw bytes and the buffer");
        $finish;
    end
endmodule
