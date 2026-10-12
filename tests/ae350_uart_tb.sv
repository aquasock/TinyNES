// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module ae350_uart_tb #(
    parameter integer FORCE_UART = 0,
    // 0: intact bus. 1: pattern 5 (0x00000002) arrives with data bit 0 set.
    // 2: pattern 9 is written with address bit 31 clear.
    parameter integer FAULT = 0
);
    reg clk = 1'b0;
    wire tx;
    always #5 clk = ~clk;

    ae350_uart #(.FORCE_UART(FORCE_UART)) dut (.sys_clk(clk), .uart_tx(tx));

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

    function [7:0] hex_char(input [3:0] value);
        hex_char = (value < 4'd10) ? ("0" + value) : ("a" + value - 4'd10);
    endfunction

    task automatic receive_hex(input [31:0] value);
        integer nibble;
        begin
            for (nibble = 7; nibble >= 0; nibble = nibble - 1)
                receive_byte(hex_char(value >> (4 * nibble)));
        end
    endtask

    function [31:0] pattern(input integer index);
        case (index)
            0: pattern = 32'ha5a5a5a5;
            1: pattern = 32'h5a5a5a5a;
            2: pattern = 32'hffffffff;
            3: pattern = 32'h00000000;
            default: pattern = 32'd1 << (index - 4);
        endcase
    endfunction

    // Issue back-to-back AHB writes as the AE350 program would: each address
    // phase overlaps the previous write's data phase. The last write is the
    // mcycle store to 0xe8000004.
    task write_patterns;
        integer index;
        reg [31:0] addr;
        reg [31:0] data;
        begin
            for (index = 0; index <= 37; index = index + 1) begin
                if (index <= 36) begin
                    addr = (index == 36) ? 32'he8000004 : 32'he8000000;
                    if (FAULT == 2 && index == 9)
                        addr = addr & 32'h7fffffff;
                    force dut.exts_addr = addr;
                    force dut.exts_sel = 1'b1;
                end else begin
                    force dut.exts_sel = 1'b0;
                end
                if (index > 0) begin
                    data = (index == 37) ? 32'h1234abcd : pattern(index - 1);
                    if (FAULT == 1 && index - 1 == 5)
                        data = data | 32'd1;
                    force dut.exts_wdata = data;
                end
                @(negedge clk);
            end
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic receive_bad(input [7:0] index, input [31:0] addr,
                               input [31:0] data);
        begin
            receive_byte("B"); receive_byte("A"); receive_byte("D");
            receive_byte(" "); receive_byte("N"); receive_byte("=");
            receive_byte(hex_char(index[7:4])); receive_byte(hex_char(index[3:0]));
            receive_byte(" "); receive_byte("A"); receive_byte("=");
            receive_hex(addr);
            receive_byte(" "); receive_byte("D"); receive_byte("=");
            receive_hex(data);
            receive_byte(8'h0d); receive_byte(8'h0a);
        end
    endtask

    initial begin
        // A black-box FPGA primitive has no simulation model here. Drive
        // only its clock-lock and AHB outputs to exercise our own logic.
        force dut.bus_clk = clk;
        force dut.pll_locked = 1'b1;
        force dut.exts_addr = 32'he8000000;
        force dut.exts_trans = 2'b10;
        force dut.exts_write = 1'b1;
        force dut.exts_wdata = 32'h00000010;
        force dut.exts_sel = 1'b0;
        force dut.rom_trans = 2'b00;

        if (FORCE_UART == 2) begin
            force dut.rom_addr = 32'h80000000;
            force dut.rom_trans = 2'b10;
        end

        wait (dut.resetn);
        repeat (3) @(negedge clk);
        if (FORCE_UART == 2) begin
            // One mcycle store to 0xe8000004; its data phase follows.
            force dut.exts_addr = 32'he8000004;
            force dut.exts_sel = 1'b1;
            @(negedge clk);
            force dut.exts_sel = 1'b0;
            force dut.exts_wdata = 32'h1234abcd;
            repeat (2) @(negedge clk);
            force dut.exts_addr = 32'he8000000;
            force dut.exts_wdata = 32'h00000010;
            if (dut.cpu_cycles !== 32'h1234abcd || dut.ref_cycles == 32'd0)
                $fatal(1, "mcycle store was not paired with the oscillator count");
            receive_byte("A"); receive_byte("D"); receive_byte("D");
            receive_byte("R"); receive_byte("="); receive_byte("1");
            receive_byte(" ");
            receive_byte("R"); receive_byte("O"); receive_byte("M");
            receive_byte("="); receive_byte("1"); receive_byte(" ");
            receive_byte("A"); receive_byte("H"); receive_byte("B");
            receive_byte("="); receive_byte("0");
            receive_byte(" "); receive_byte("C"); receive_byte("Y");
            receive_byte("C"); receive_byte("=");
            receive_hex(32'h1234abcd);
            receive_byte(" "); receive_byte("R"); receive_byte("E");
            receive_byte("F"); receive_byte("=");
            if (dut.report_ref !== dut.ref_cycles)
                $fatal(1, "report did not freeze the captured oscillator count");
            receive_hex(dut.report_ref);
            receive_byte(8'h0d); receive_byte(8'h0a);
            if (dut.rom_addr_seen !== 1'b1 || dut.rom_seen !== 1'b1 ||
                dut.cpu_started !== 1'b0)
                $fatal(1, "trace state did not match the simulated bus activity");
            $display("PASS: trace UART reports ROM fetch, no status write, and the cycle pair");
        end else if (FORCE_UART == 1) begin
            receive_byte("U"); receive_byte("A"); receive_byte("R");
            receive_byte("T"); receive_byte(" "); receive_byte("D");
            receive_byte("I"); receive_byte("A"); receive_byte("G");
            receive_byte("N"); receive_byte("O"); receive_byte("S");
            receive_byte("T"); receive_byte("I"); receive_byte("C");
            receive_byte("!"); receive_byte(8'h0d); receive_byte(8'h0a);
            if (dut.cpu_started !== 1'b0)
                $fatal(1, "diagnostic unexpectedly saw an AHB write");
            $display("PASS: diagnostic UART report runs without AE350 write");
        end else begin
            if (tx !== 1'b1) $fatal(1, "UART transmitted before CPU report");
            write_patterns();
            if (FAULT == 1) begin
                if (dut.cpu_started !== 1'b0 || dut.bus_error !== 1'b1)
                    $fatal(1, "flipped data bit was not reported");
                receive_bad(8'h05, 32'he8000000, 32'h00000003);
                $display("PASS: flipped data bit gives the BAD report");
            end else if (FAULT == 2) begin
                if (dut.cpu_started !== 1'b0 || dut.bus_error !== 1'b1)
                    $fatal(1, "wrong write address was not reported");
                receive_bad(8'h09, 32'h68000000, 32'h00000020);
                $display("PASS: wrong write address gives the BAD report");
            end else begin
                if (dut.cpu_started !== 1'b1 || dut.bus_error !== 1'b0 ||
                    dut.cpu_cycles !== 32'h1234abcd)
                    $fatal(1, "AHB pattern sequence was not accepted");
                receive_byte("T"); receive_byte("i"); receive_byte("n");
                receive_byte("y"); receive_byte("N"); receive_byte("E");
                receive_byte("S"); receive_byte(" "); receive_byte("A");
                receive_byte("E"); receive_byte("3"); receive_byte("5");
                receive_byte("0"); receive_byte(" "); receive_byte("O");
                receive_byte("K"); receive_byte(8'h0d); receive_byte(8'h0a);
                $display("PASS: all AHB address and data patterns start the OK report");
            end
        end
        $finish;
    end

    initial begin
        #4000000;
        $fatal(1, "UART report timed out");
    end
endmodule
