// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module ae350_uart_tb #(
    parameter integer FORCE_UART = 0
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
            receive_byte("A"); receive_byte("D"); receive_byte("D");
            receive_byte("R"); receive_byte("="); receive_byte("1");
            receive_byte(" ");
            receive_byte("R"); receive_byte("O"); receive_byte("M");
            receive_byte("="); receive_byte("1"); receive_byte(" ");
            receive_byte("A"); receive_byte("H"); receive_byte("B");
            receive_byte("="); receive_byte("0");
            receive_byte(8'h0d); receive_byte(8'h0a);
            if (dut.rom_addr_seen !== 1'b1 || dut.rom_seen !== 1'b1 ||
                dut.cpu_started !== 1'b0)
                $fatal(1, "trace state did not match the simulated bus activity");
            $display("PASS: trace UART reports ROM address and fetch without AHB write");
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
            force dut.exts_sel = 1'b1;
            @(negedge clk);
            force dut.exts_sel = 1'b0;
            repeat (2) @(negedge clk);
            if (dut.cpu_started !== 1'b1)
                $fatal(1, "AHB status write was not captured");

            receive_byte("T"); receive_byte("i"); receive_byte("n");
            receive_byte("y"); receive_byte("N"); receive_byte("E");
            receive_byte("S"); receive_byte(" "); receive_byte("A");
            receive_byte("E"); receive_byte("3"); receive_byte("5");
            receive_byte("0"); receive_byte(" "); receive_byte("O");
            receive_byte("K"); receive_byte(8'h0d); receive_byte(8'h0a);
            $display("PASS: AHB write starts the complete UART report");
        end
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "UART report timed out");
    end
endmodule
