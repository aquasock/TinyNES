// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// AHB-Lite master standing in for one AE350 port. push() queues transfers;
// run() issues them back to back, each address phase overlapping the
// previous data phase, and records each transfer's read data and response.
module tb_ahb_master #(
    parameter integer DW = 32
) (
    input  wire          clk,
    input  wire          hready,
    input  wire          hresp,
    input  wire [DW-1:0] hrdata,
    output reg  [31:0]   haddr,
    output reg  [1:0]    htrans,
    output reg           hwrite,
    output reg  [2:0]    hsize,
    output reg  [DW-1:0] hwdata
);
    localparam integer MAX = 128;
    reg [31:0] q_addr [0:MAX-1];
    reg q_write [0:MAX-1];
    reg [2:0] q_size [0:MAX-1];
    reg [DW-1:0] q_wdata [0:MAX-1];
    reg q_seq [0:MAX-1];
    reg [DW-1:0] r_data [0:MAX-1];
    reg r_err [0:MAX-1];
    integer count = 0;

    initial begin
        haddr = 32'd0;
        htrans = 2'b00;
        hwrite = 1'b0;
        hsize = 3'd2;
        hwdata = {DW{1'b0}};
    end

    task clear;
        count = 0;
    endtask

    task push(input [31:0] addr, input write, input [2:0] size,
              input [DW-1:0] data, input seq);
        begin
            q_addr[count] = addr;
            q_write[count] = write;
            q_size[count] = size;
            q_wdata[count] = data;
            q_seq[count] = seq;
            count = count + 1;
        end
    endtask

    task drive_address(input integer index);
        if (index < count) begin
            haddr = q_addr[index];
            htrans = q_seq[index] ? 2'b11 : 2'b10;
            hwrite = q_write[index];
            hsize = q_size[index];
        end else begin
            htrans = 2'b00;
            hwrite = 1'b0;
        end
    endtask

    task run;
        integer next;
        integer data;
        integer cycles;
        reg done;
        begin
            next = 0;
            data = -1;
            cycles = 0;
            done = 1'b0;
            @(negedge clk);
            drive_address(0);
            while (!done) begin
                @(posedge clk);
                cycles = cycles + 1;
                if (cycles > 200000)
                    $fatal(1, "AHB transfer %0d timed out", data);
                if (hready === 1'b1) begin
                    if (data >= 0) begin
                        r_data[data] = hrdata;
                        r_err[data] = hresp;
                    end
                    if (next >= count) begin
                        done = 1'b1;
                    end else begin
                        data = next;
                        next = next + 1;
                        @(negedge clk);
                        drive_address(next);
                        if (q_write[data])
                            hwdata = q_wdata[data];
                    end
                end
            end
        end
    endtask

    task expect_ok(input integer index, input [DW-1:0] value);
        if (r_err[index] !== 1'b0 || r_data[index] !== value)
            $fatal(1, "transfer %0d at %08x: got %x err %b, expected %x",
                   index, q_addr[index], r_data[index], r_err[index], value);
    endtask

    task expect_write_ok(input integer index);
        if (r_err[index] !== 1'b0)
            $fatal(1, "write %0d at %08x got an ERROR response", index,
                   q_addr[index]);
    endtask

    task expect_error(input integer index);
        if (r_err[index] !== 1'b1)
            $fatal(1, "transfer %0d at %08x was not given an ERROR response",
                   index, q_addr[index]);
    endtask
endmodule

module ae350_soc_tb #(
    // 0: every port, register and UART path. 1: the NOBOOT report and the
    // CPU taking the UART over from it.
    parameter integer TEST = 0
);
    localparam integer NOBOOT_BITS = 15;
    reg clk = 1'b0;
    wire tx;
    always #5 clk = ~clk;

    ae350_soc_top #(.NOBOOT_BITS(NOBOOT_BITS)) dut (
        .sys_clk(clk),
        .uart_tx(tx)
    );

    wire rom_ready = dut.rom_ready;
    wire [31:0] rom_rdata = dut.rom_rdata;
    wire ram_ready = dut.ram_ready;
    wire ram_resp = dut.ram_resp;
    wire [63:0] ram_rdata = dut.ram_rdata;
    wire exts_ready = dut.exts_ready;
    wire exts_resp = dut.exts_resp;
    wire [31:0] exts_rdata = dut.exts_rdata;

    wire [31:0] rom_haddr;
    wire [1:0] rom_htrans;
    wire rom_hwrite;
    wire [2:0] rom_hsize;
    wire [31:0] rom_hwdata;
    wire [31:0] ram_haddr;
    wire [1:0] ram_htrans;
    wire ram_hwrite;
    wire [2:0] ram_hsize;
    wire [63:0] ram_hwdata;
    wire [31:0] ext_haddr;
    wire [1:0] ext_htrans;
    wire ext_hwrite;
    wire [2:0] ext_hsize;
    wire [31:0] ext_hwdata;
    wire ext_hsel = ext_htrans[1];

    tb_ahb_master #(.DW(32)) rom_m (
        .clk(clk), .hready(rom_ready), .hresp(1'b0), .hrdata(rom_rdata),
        .haddr(rom_haddr), .htrans(rom_htrans), .hwrite(rom_hwrite),
        .hsize(rom_hsize), .hwdata(rom_hwdata)
    );
    tb_ahb_master #(.DW(64)) ram_m (
        .clk(clk), .hready(ram_ready), .hresp(ram_resp), .hrdata(ram_rdata),
        .haddr(ram_haddr), .htrans(ram_htrans), .hwrite(ram_hwrite),
        .hsize(ram_hsize), .hwdata(ram_hwdata)
    );
    tb_ahb_master #(.DW(32)) ext_m (
        .clk(clk), .hready(exts_ready), .hresp(exts_resp), .hrdata(exts_rdata),
        .haddr(ext_haddr), .htrans(ext_htrans), .hwrite(ext_hwrite),
        .hsize(ext_hsize), .hwdata(ext_hwdata)
    );

    // HPROT[0] the RAM master drives: 1 data, 0 instruction fetch.
    reg ram_data = 1'b1;
    wire [3:0] ram_prot = {3'b001, ram_data};

    reg [31:0] image [0:8191];
    initial $readmemh("build/firmware/boot/boot.hex", image);

    task automatic receive_byte(input [7:0] expected);
        reg [7:0] value;
        integer bit_index;
        begin
            wait (tx == 1'b0);
            repeat (325) @(posedge clk);
            if (tx !== 1'b0) $fatal(1, "missing UART start bit");
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                repeat (651) @(posedge clk);
                value[bit_index] = tx;
            end
            repeat (651) @(posedge clk);
            if (tx !== 1'b1) $fatal(1, "missing UART stop bit");
            if (value !== expected)
                $fatal(1, "UART byte mismatch: got %02x, expected %02x", value, expected);
        end
    endtask

    task automatic receive_text(input [8*64-1:0] text, input integer length);
        integer index;
        for (index = length - 1; index >= 0; index = index - 1)
            receive_byte(text[8 * index +: 8]);
    endtask

    function [7:0] hex_char(input [3:0] value);
        hex_char = (value < 4'd10) ? ("0" + value) : ("a" + value - 4'd10);
    endfunction

    task automatic receive_hex(input [31:0] value);
        integer nibble;
        for (nibble = 7; nibble >= 0; nibble = nibble - 1)
            receive_byte(hex_char(value >> (4 * nibble)));
    endtask

    task automatic receive_noboot(input [31:0] rom, input [31:0] last,
                                  input [31:0] ram, input [31:0] ext,
                                  input [31:0] raml, input [31:0] state,
                                  input [31:0] e1, input [31:0] el);
        begin
            receive_text("NOBOOT ROM=", 11);
            receive_hex(rom);
            receive_text(" LAST=", 6);
            receive_hex(last);
            receive_text(" RAM=", 5);
            receive_hex(ram);
            receive_text(" EXT=", 5);
            receive_hex(ext);
            receive_text(" RAML=", 6);
            receive_hex(raml);
            receive_text(" ST=", 4);
            receive_hex(state);
            receive_text(" S1=", 4);
            receive_hex(e1);
            receive_text(" SL=", 4);
            receive_hex(el);
            receive_byte(8'h0d);
            receive_byte(8'h0a);
        end
    endtask

    task automatic expect_quiet(input integer cycles);
        integer count;
        for (count = 0; count < cycles; count = count + 1) begin
            @(posedge clk);
            if (tx !== 1'b1)
                $fatal(1, "unexpected UART output");
        end
    endtask

    task test_rom;
        integer index;
        begin
            rom_m.clear();
            for (index = 0; index < 16; index = index + 1)
                rom_m.push(32'h80000000 + 4 * index, 1'b0, 3'd2, 0, index != 0);
            rom_m.push(32'h80007ffc, 1'b0, 3'd2, 0, 1'b0);
            rom_m.push(32'h80008000, 1'b0, 3'd2, 0, 1'b0);
            rom_m.push(32'h80000400, 1'b0, 3'd2, 0, 1'b0);
            rom_m.run();
            for (index = 0; index < 16; index = index + 1)
                rom_m.expect_ok(index, image[index]);
            rom_m.expect_ok(16, image[8191]);
            rom_m.expect_ok(17, image[0]);
            rom_m.expect_ok(18, image[256]);
            if (image[0] === 32'd0 || image[0] === 32'hx)
                $fatal(1, "firmware image is missing");
            $display("PASS: ROM port returns the firmware image, back to back");
        end
    endtask

    task test_ram;
        integer index;
        begin
            ram_m.clear();
            ram_m.push(32'h40000000, 1'b1, 3'd3, 64'h0123456789abcdef, 1'b0); // 0
            ram_m.push(32'h40000008, 1'b1, 3'd2, 64'h55555555_deadbeef, 1'b0);
            ram_m.push(32'h4000000c, 1'b1, 3'd2, 64'hcafef00d_aaaaaaaa, 1'b0);
            for (index = 0; index < 8; index = index + 1)                    // 3-10
                ram_m.push(32'h40000010 + index, 1'b1, 3'd0,
                           {8{8'hee}} ^ ({8{8'hee}} & (64'hff << (8 * index))) |
                           ((64'h10 + index) << (8 * index)), 1'b0);
            ram_m.push(32'h40000018, 1'b1, 3'd3, 64'hffffffff_ffffffff, 1'b0); // 11
            ram_m.push(32'h40000018, 1'b1, 3'd1, 64'h00000000_00001122, 1'b0);
            ram_m.push(32'h4000001e, 1'b1, 3'd1, 64'h3344eeee_eeeeeeee, 1'b0);
            ram_m.push(32'h4000fff8, 1'b1, 3'd3, 64'hfedcba98_76543210, 1'b0);
            ram_m.push(32'h00000000, 1'b1, 3'd3, 64'h11111111_11111111, 1'b0); // 15
            ram_m.push(32'h40010000, 1'b1, 3'd3, 64'h22222222_22222222, 1'b0);
            ram_m.push(32'h40000000, 1'b0, 3'd3, 0, 1'b0);                    // 17
            ram_m.push(32'h40000008, 1'b0, 3'd3, 0, 1'b1);
            ram_m.push(32'h40000010, 1'b0, 3'd3, 0, 1'b1);
            ram_m.push(32'h40000018, 1'b0, 3'd3, 0, 1'b1);
            ram_m.push(32'h4000fff8, 1'b0, 3'd3, 0, 1'b0);
            ram_m.push(32'h80000000, 1'b0, 3'd3, 0, 1'b0);                    // 22
            ram_m.push(32'h40000020, 1'b1, 3'd3, 64'ha1a2a3a4_a5a6a7a8, 1'b0);
            ram_m.push(32'h40000020, 1'b0, 3'd3, 0, 1'b0);
            ram_m.push(32'h40000020, 1'b1, 3'd2, 64'h00000000_b1b2b3b4, 1'b0);
            ram_m.push(32'h40000020, 1'b0, 3'd2, 0, 1'b0);                    // 26
            ram_m.run();
            for (index = 0; index <= 14; index = index + 1)
                ram_m.expect_write_ok(index);
            ram_m.expect_error(15);
            ram_m.expect_error(16);
            ram_m.expect_ok(17, 64'h0123456789abcdef);
            ram_m.expect_ok(18, 64'hcafef00d_deadbeef);
            ram_m.expect_ok(19, 64'h17161514_13121110);
            ram_m.expect_ok(20, 64'h3344ffff_ffff1122);
            ram_m.expect_ok(21, 64'hfedcba98_76543210);
            ram_m.expect_error(22);
            ram_m.expect_write_ok(23);
            ram_m.expect_ok(24, 64'ha1a2a3a4_a5a6a7a8);
            ram_m.expect_write_ok(25);
            ram_m.expect_ok(26, 64'ha1a2a3a4_b1b2b3b4);
            // Instruction fetches: zero with OKAY outside the window.
            ram_data = 1'b0;
            ram_m.clear();
            ram_m.push(32'h00000018, 1'b0, 3'd3, 0, 1'b0);
            ram_m.push(32'h00000000, 1'b0, 3'd3, 0, 1'b1);
            ram_m.push(32'h40000020, 1'b0, 3'd3, 0, 1'b0);
            ram_m.push(32'h80000000, 1'b0, 3'd2, 0, 1'b0);
            ram_m.run();
            ram_m.expect_ok(0, 64'd0);
            ram_m.expect_ok(1, 64'd0);
            ram_m.expect_ok(2, 64'ha1a2a3a4_b1b2b3b4);
            ram_m.expect_ok(3, 64'd0);
            ram_data = 1'b1;
            $display("PASS: RAM port byte lanes, ERROR outside 0x4000xxxx, read after write, fetches outside read zero");
        end
    endtask

    task test_registers;
        integer index;
        begin
            ext_m.clear();
            ext_m.push(32'he8000008, 1'b0, 3'd2, 0, 1'b0);
            ext_m.push(32'he8000004, 1'b0, 3'd2, 0, 1'b0);
            for (index = 0; index < 32; index = index + 1) begin
                ext_m.push(32'he800000c, 1'b1, 3'd2, 32'd1 << index, 1'b0);
                ext_m.push(32'he800000c, 1'b0, 3'd2, 0, 1'b0);
            end
            ext_m.push(32'he8000000, 1'b0, 3'd2, 0, 1'b0); // 66
            ext_m.push(32'he8000004, 1'b1, 3'd2, 32'd1, 1'b0);
            ext_m.push(32'he8000010, 1'b0, 3'd2, 0, 1'b0);
            ext_m.push(32'he9000008, 1'b0, 3'd2, 0, 1'b0);
            ext_m.push(32'he800000c, 1'b0, 3'd2, 0, 1'b0); // 70
            ext_m.run();
            ext_m.expect_ok(0, 32'h544e3031);
            ext_m.expect_ok(1, 32'd3);
            for (index = 0; index < 32; index = index + 1) begin
                ext_m.expect_write_ok(2 + 2 * index);
                ext_m.expect_ok(3 + 2 * index, 32'd1 << index);
            end
            for (index = 66; index <= 69; index = index + 1)
                ext_m.expect_error(index);
            ext_m.expect_ok(70, 32'h80000000);
            if (dut.cpu_owns !== 1'b0 || tx !== 1'b1)
                $fatal(1, "register accesses moved the UART");
            $display("PASS: EXTS ID, status, scratch walking one and ERROR decode");
        end
    endtask

    task cpu_transmit(input [8*8-1:0] text, input integer length);
        integer index;
        begin
            ext_m.clear();
            for (index = length - 1; index >= 0; index = index - 1)
                ext_m.push(32'he8000000, 1'b1, 3'd2,
                           {24'hffffff, text[8 * index +: 8]}, 1'b0);
            ext_m.run();
            for (index = 0; index < length; index = index + 1)
                ext_m.expect_write_ok(index);
        end
    endtask

    initial begin
        // The PLL and the AE350 are black boxes here: drive the PLL lock,
        // the bus clock and the AE350's AHB outputs from the masters above.
        force dut.bus_clk = clk;
        force dut.pll_locked = 1'b1;
        force dut.rom_addr = rom_haddr;
        force dut.rom_trans = rom_htrans;
        force dut.ram_addr = ram_haddr;
        force dut.ram_trans = ram_htrans;
        force dut.ram_write = ram_hwrite;
        force dut.ram_size = ram_hsize;
        force dut.ram_burst = 3'b000;
        force dut.ram_prot = ram_prot;
        force dut.ram_wdata = ram_hwdata;
        force dut.exts_addr = ext_haddr;
        force dut.exts_trans = ext_htrans;
        force dut.exts_sel = ext_hsel;
        force dut.exts_write = ext_hwrite;
        force dut.exts_wdata = ext_hwdata;

        wait (dut.resetn);
        repeat (3) @(negedge clk);
        if (TEST == 0) begin
            test_rom();
            test_ram();
            test_registers();
            // The second write waits for the first byte to leave the holding
            // register; the rest wait in turn while the line is sent.
            fork
                cpu_transmit("OK\r\n", 4);
                receive_text("OK\r\n", 4);
            join
            if (dut.cpu_owns !== 1'b1)
                $fatal(1, "a CPU write did not take the UART");
            expect_quiet(3 << NOBOOT_BITS);
            $display("PASS: CPU UART writes are sent in order and NOBOOT stays silent");
        end else begin
            rom_m.clear();
            rom_m.push(32'h80000000, 1'b0, 3'd2, 0, 1'b0);
            rom_m.push(32'h80000004, 1'b0, 3'd2, 0, 1'b1);
            rom_m.push(32'h80000008, 1'b0, 3'd2, 0, 1'b1);
            rom_m.run();
            ram_m.clear();
            ram_m.push(32'h40000000, 1'b1, 3'd2, 64'h1, 1'b0);
            ram_m.push(32'h00000010, 1'b0, 3'd2, 0, 1'b0);
            ram_m.push(32'h40000000, 1'b0, 3'd2, 0, 1'b0);
            ram_m.run();
            ram_m.expect_error(1);
            ext_m.clear();
            ext_m.push(32'he8000008, 1'b0, 3'd2, 0, 1'b0);
            ext_m.run();
            receive_noboot(32'd3, 32'h80000008, 32'd3, 32'd1, 32'h40000000, 32'h82d00001,
                           32'h00000010, 32'h00000010);
            rom_m.clear();
            rom_m.push(32'h80000010, 1'b0, 3'd2, 0, 1'b0);
            rom_m.run();
            receive_noboot(32'd4, 32'h80000010, 32'd3, 32'd1, 32'h40000000, 32'h82d00001,
                           32'h00000010, 32'h00000010);
            fork
                cpu_transmit("Z", 1);
                receive_byte("Z");
            join
            expect_quiet(3 << NOBOOT_BITS);
            $display("PASS: NOBOOT reports the port counts and stray RAM transfers until the CPU writes");
        end
        $finish;
    end

    initial begin
        #100000000;
        $fatal(1, "simulation timed out");
    end
endmodule
