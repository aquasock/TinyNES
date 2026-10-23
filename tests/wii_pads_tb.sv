// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// A byte-level Wii extension on an open-drain bus. It checks the command
// order and lets the test unplug and replug a controller during polling.
module wii_classic_model #(
    parameter integer INDEX = 0
) (
    input wire clk,
    input wire attached,
    input wire scl,
    input wire sda,
    output reg scl_low = 1'b0,
    output reg sda_low = 1'b0,
    output reg [15:0] polls = 16'd0,
    output reg [7:0] wakes = 8'd0,
    output reg stretched = 1'b0
);
    reg woke_f0 = 1'b0, woke_fb = 1'b0;
    reg [7:0] pointer = 8'hff;
    reg [7:0] byte_in;
    reg ack_in;
    integer i;

    task receive_byte(output reg [7:0] value, input reg acknowledge);
        begin
            value = 8'd0;
            for (integer bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                @(posedge scl);
                value[bit_index] = sda;
                @(negedge scl);
            end
            sda_low = acknowledge;
            @(posedge scl);
            @(negedge scl);
            sda_low = 1'b0;
            if (INDEX == 1 && !stretched && acknowledge) begin
                // Keep SCL low beyond the master's own low half once.
                scl_low = 1'b1;
                repeat (35) @(posedge clk);
                scl_low = 1'b0;
                stretched = 1'b1;
            end
        end
    endtask

    function automatic [7:0] read_byte(input [7:0] ptr, input integer index);
        if (ptr == 8'hfa)
            case (index)
                0: read_byte = INDEX == 0 ? 8'h00 : 8'h01;
                1: read_byte = 8'h00;
                2: read_byte = 8'ha4;
                3: read_byte = 8'h20;
                4: read_byte = 8'h01;
                default: read_byte = 8'h01;
            endcase
        else
            case (index)
                0: read_byte = 8'h20 + INDEX;
                1: read_byte = 8'h21 + INDEX;
                2: read_byte = 8'h22 + INDEX;
                3: read_byte = 8'h23 + INDEX;
                4: read_byte = 8'hff;
                default: read_byte = 8'hfb; // Up held, all others released.
            endcase
    endfunction

    task send_byte(input [7:0] value, input reg last);
        begin
            for (integer bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                sda_low = !value[bit_index];
                @(posedge scl);
                @(negedge scl);
            end
            sda_low = 1'b0;
            @(posedge scl);
            if (last ? sda !== 1'b1 : sda !== 1'b0)
                $fatal(1, "pad %0d: master ACK/NACK wrong on byte %0d", INDEX, value);
            @(negedge scl);
        end
    endtask

    initial forever begin
        @(negedge sda);
        if (scl === 1'b1) begin
            @(negedge scl);
            receive_byte(byte_in, attached);
            if (attached) begin
                if (byte_in == 8'ha4) begin
                    receive_byte(byte_in, 1'b1);
                    pointer = byte_in;
                    if (pointer == 8'hf0 || pointer == 8'hfb) begin
                        receive_byte(byte_in, 1'b1);
                        if (pointer == 8'hf0) begin
                            if (byte_in != 8'h55)
                                $fatal(1, "bad F0 wake value %02x", byte_in);
                            woke_f0 = 1'b1;
                            woke_fb = 1'b0;
                            wakes = wakes + 1'b1;
                        end else begin
                            if (!woke_f0 || byte_in != 8'h00)
                                $fatal(1, "bad FB wake sequence");
                            woke_fb = 1'b1;
                        end
                    end else if (pointer != 8'hfa && pointer != 8'h00) begin
                        $fatal(1, "unexpected pointer %02x", pointer);
                    end
                end else if (byte_in == 8'ha5) begin
                    if (!woke_fb || (pointer != 8'hfa && pointer != 8'h00))
                        $fatal(1, "read before wake or pointer");
                    for (i = 0; i < 6; i = i + 1)
                        send_byte(read_byte(pointer, i), i == 5);
                    if (pointer == 8'h00)
                        polls = polls + 1'b1;
                end else begin
                    $fatal(1, "unexpected I2C address %02x", byte_in);
                end
            end else begin
                woke_f0 = 1'b0;
                woke_fb = 1'b0;
            end
        end
    end
endmodule

module wii_pads_tb;
    reg clk = 1'b0;
    always #5 clk = !clk;
    reg resetn = 1'b0;
    reg [11:0] haddr = 12'd0;
    reg [1:0] htrans = 2'b00;
    reg hsel = 1'b0, hwrite = 1'b0;
    reg [2:0] hsize = 3'd2;
    reg [31:0] hwdata = 32'd0;
    wire [31:0] hrdata;
    wire hready, hresp;
    wire [3:0] scl_in, sda_in, scl_low, sda_low;
    wire [15:0] polls [0:3];
    wire [7:0] wakes [0:3];
    wire [3:0] stretched;
    reg [3:0] attached = 4'b0011;
    // A dead bus has no pull-ups, as USB-A's pair does with nothing powered
    // on it, where the dock's pull-downs hold both lines low.
    reg [3:0] dead = 4'b0000;
    wire [3:0] model_scl_low, model_sda_low;

    genvar n;
    generate for (n = 0; n < 4; n = n + 1) begin : bus
        assign scl_in[n] = !(dead[n] || scl_low[n] || model_scl_low[n]);
        assign sda_in[n] = !(dead[n] || sda_low[n] || model_sda_low[n]);
        wii_classic_model #(.INDEX(n)) controller (
            .clk(clk), .attached(attached[n]),
            .scl(scl_in[n]), .sda(sda_in[n]),
            .scl_low(model_scl_low[n]), .sda_low(model_sda_low[n]),
            .polls(polls[n]), .wakes(wakes[n]), .stretched(stretched[n])
        );
    end endgenerate

    wii_pads #(.US_CLOCKS(1), .QUARTER_RESET(4), .CONVERT_US(10)) dut (
        .clk(clk), .resetn(resetn), .haddr(haddr), .htrans(htrans),
        .hsel(hsel), .hwrite(hwrite), .hsize(hsize), .hwdata(hwdata),
        .hready_in(hready), .hrdata(hrdata), .hready(hready), .hresp(hresp),
        .scl_in(scl_in), .sda_in(sda_in), .scl_low(scl_low), .sda_low(sda_low)
    );

    task read_reg(input [11:0] address, output reg [31:0] value);
        begin
            @(negedge clk);
            haddr = address; hsel = 1'b1; htrans = 2'b10; hwrite = 1'b0; hsize = 3'd2;
            @(posedge clk); #1;
            if (hresp || !hready)
                $fatal(1, "read response at %03x", address);
            value = hrdata;
            @(negedge clk);
            hsel = 1'b0; htrans = 2'b00;
        end
    endtask

    task write_ctrl(input [11:0] value);
        begin
            @(negedge clk);
            haddr = 12'h004; hsel = 1'b1; htrans = 2'b10; hwrite = 1'b1;
            @(posedge clk);
            @(negedge clk);
            hsel = 1'b0; htrans = 2'b00; hwrite = 1'b0; hwdata = {20'd0, value};
            @(posedge clk);
        end
    endtask

    reg [31:0] status, value, data2;
    integer timeout;
    initial begin
        repeat (5) @(posedge clk);
        resetn = 1'b1;
        read_reg(12'h000, value);
        if (value != 32'h544e5031) $fatal(1, "ID %08x", value);
        timeout = 0;
        status = 0;
        while ((status & 32'h2) == 0 && timeout < 100000) begin
            read_reg(12'h010, status);
            timeout = timeout + 1;
        end
        if ((status & 32'h3) != 3 || timeout >= 100000)
            $fatal(1, "pad 0 did not identify: %08x", status);
        timeout = 0;
        status = 0;
        while ((status & 32'h2) == 0 && timeout < 100000) begin
            read_reg(12'h020, status);
            timeout = timeout + 1;
        end
        if ((status & 32'h3) != 3 || !stretched[1])
            $fatal(1, "pad 1 did not identify/stretch: %08x", status);
        timeout = 0;
        while (polls[0] == 0 && timeout < 100000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 100000)
            $fatal(1, "pad 0 did not poll");
        timeout = 0;
        status = 0;
        while ((status & 32'h0000ff00) == 0 && timeout < 100000) begin
            read_reg(12'h010, status);
            timeout = timeout + 1;
        end
        if (timeout >= 100000)
            $fatal(1, "pad 0 data not stored");
        read_reg(12'h014, value);
        read_reg(12'h018, data2);
        if (value != 32'h23222120 || data2[15:0] != 16'hfbff || data2[31:16] != 16'h0101)
            $fatal(1, "sample mismatch: DATA=%08x DATA2=%08x", value, data2);
        read_reg(12'h01c, value);
        if (value != 32'h20a40000)
            $fatal(1, "identity mismatch: %08x", value);
        if (polls[0] == 0 || polls[1] == 0)
            $fatal(1, "polls missing");
        read_reg(12'h030, status);
        if (status & 1)
            $fatal(1, "absent port present");
        // LINES: a dead bus reads 0 on both lines, and the bits follow the
        // pins back up once the bus has pull-ups again.
        dead[2] = 1'b1;
        @(posedge clk);
        read_reg(12'h008, value);
        if (value[31:8] != 24'd0 || value[2] || value[6])
            $fatal(1, "LINES with bus 2 dead: %08x", value);
        dead[2] = 1'b0;
        timeout = 0;
        value = 0;
        while ((value & 32'h44) != 32'h44 && timeout < 100000) begin
            read_reg(12'h008, value);
            timeout = timeout + 1;
        end
        if (timeout >= 100000)
            $fatal(1, "LINES bus 2 never read high: %08x", value);
        attached[0] = 1'b0;
        repeat (5000) @(posedge clk);
        read_reg(12'h010, status);
        if (status & 1)
            $fatal(1, "unplug was not detected: %08x", status);
        attached[0] = 1'b1;
        repeat (150000) @(posedge clk);
        read_reg(12'h010, status);
        if ((status & 3) != 3 || wakes[0] < 2)
            $fatal(1, "replug failed: %08x wakes=%0d", status, wakes[0]);
        write_ctrl(12'd8);
        read_reg(12'h004, value);
        if (value != 8)
            $fatal(1, "CTRL write failed: %08x", value);
        repeat (70000) @(posedge clk);
        read_reg(12'h010, status);
        if ((status & 3) != 3 || wakes[0] < 3)
            $fatal(1, "pad did not resume at new divider: %08x wakes=%0d", status, wakes[0]);
        $display("WII PADS PASS polls=%0d,%0d wakes=%0d,%0d", polls[0], polls[1], wakes[0], wakes[1]);
        $finish;
    end
    initial begin
        #5000000;
        $fatal(1, "test timeout");
    end
endmodule
