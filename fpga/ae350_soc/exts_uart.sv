// SPDX-License-Identifier: MIT
// Fabric registers in the AE350's uncached EXTS window, and the FPGA UART
// transmitter (8N1) they drive. Offsets from 0xe8000000:
//   0x00  write: byte to transmit (bits 7:0). The transfer waits while the
//         holding register is full.
//   0x04  read: status; bit 0 the holding register is free, bit 1 the
//         transmitter is also idle.
//   0x08  read: ID_VALUE.
//   0x0c  read and write: 32-bit scratch register.
// All 32 address bits are decoded; any other address, or a write to a
// read-only register or a read of 0x00, gets an AHB ERROR response.
//
// Until the CPU writes its first byte, fabric may transmit through the
// fallback input instead (fb_valid, fb_data, fb_ready); after it, only the
// CPU does. cpu_owns reports which.
module exts_uart #(
    parameter integer UART_DIV = 651,
    parameter [31:0] ID_VALUE = 32'h544e3031,
    // Diagnostic: 1 completes CPU transmit writes without sending them, so
    // the fallback keeps the transmitter.
    parameter integer DROP_CPU_TX = 0
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hsel,
    input  wire        hwrite,
    input  wire [31:0] hwdata,
    output reg  [31:0] hrdata,
    output reg         hready,
    output reg         hresp,
    input  wire        fb_valid,
    input  wire [7:0]  fb_data,
    output wire        fb_ready,
    output reg         cpu_owns,
    output wire        tx
);
    localparam [31:0] BASE = 32'he8000000;
    localparam [2:0] REG_TX = 3'd0;
    localparam [2:0] REG_STATUS = 3'd1;
    localparam [2:0] REG_ID = 3'd2;
    localparam [2:0] REG_SCRATCH = 3'd3;
    localparam [2:0] REG_NONE = 3'd4;

    reg [2:0] target = REG_NONE;
    reg write = 1'b0;
    reg pending = 1'b0;
    reg error_second = 1'b0;
    reg [31:0] scratch = 32'd0;

    reg [7:0] hold = 8'd0;
    reg hold_full = 1'b0;
    reg [9:0] tx_shift = 10'h3ff;
    reg [3:0] bits_left = 4'd0;
    reg [15:0] baud_wait = 16'd0;
    wire tx_idle = bits_left == 4'd0;

    assign tx = tx_idle ? 1'b1 : tx_shift[0];
    assign fb_ready = !cpu_owns && !hold_full;

    function [2:0] decode(input [31:0] addr, input is_write);
        if (addr == BASE + 32'h0 && is_write)
            decode = REG_TX;
        else if (addr == BASE + 32'h4 && !is_write)
            decode = REG_STATUS;
        else if (addr == BASE + 32'h8 && !is_write)
            decode = REG_ID;
        else if (addr == BASE + 32'hc)
            decode = REG_SCRATCH;
        else
            decode = REG_NONE;
    endfunction

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            target <= REG_NONE;
            write <= 1'b0;
            pending <= 1'b0;
            error_second <= 1'b0;
            scratch <= 32'd0;
            hrdata <= 32'd0;
            hready <= 1'b1;
            hresp <= 1'b0;
            hold <= 8'd0;
            hold_full <= 1'b0;
            cpu_owns <= 1'b0;
            tx_shift <= 10'h3ff;
            bits_left <= 4'd0;
            baud_wait <= 16'd0;
        end else begin
            // Transmitter: shift a byte out, then take the next one.
            if (!tx_idle) begin
                if (baud_wait == 0) begin
                    baud_wait <= UART_DIV - 1;
                    tx_shift <= {1'b1, tx_shift[9:1]};
                    bits_left <= bits_left - 1'b1;
                end else begin
                    baud_wait <= baud_wait - 1'b1;
                end
            end else if (hold_full) begin
                tx_shift <= {1'b1, hold, 1'b0};
                bits_left <= 4'd10;
                baud_wait <= UART_DIV - 1;
                hold_full <= 1'b0;
            end

            if (fb_valid && fb_ready) begin
                hold <= fb_data;
                hold_full <= 1'b1;
            end

            // AHB slave.
            error_second <= 1'b0;
            if (hready) begin
                hresp <= 1'b0;
                if (hsel && htrans[1]) begin
                    target <= decode(haddr, hwrite);
                    write <= hwrite;
                    pending <= 1'b1;
                    hready <= 1'b0;
                end
            end
            if (pending) begin
                case (target)
                    REG_TX:
                        if (DROP_CPU_TX != 0) begin
                            pending <= 1'b0;
                            hready <= 1'b1;
                        end else if (!hold_full) begin
                            hold <= hwdata[7:0];
                            hold_full <= 1'b1;
                            cpu_owns <= 1'b1;
                            pending <= 1'b0;
                            hready <= 1'b1;
                        end
                    REG_STATUS: begin
                        hrdata <= {30'd0, tx_idle && !hold_full, !hold_full};
                        pending <= 1'b0;
                        hready <= 1'b1;
                    end
                    REG_ID: begin
                        hrdata <= ID_VALUE;
                        pending <= 1'b0;
                        hready <= 1'b1;
                    end
                    REG_SCRATCH: begin
                        if (write)
                            scratch <= hwdata;
                        hrdata <= scratch;
                        pending <= 1'b0;
                        hready <= 1'b1;
                    end
                    default: begin
                        hresp <= 1'b1;
                        pending <= 1'b0;
                        error_second <= 1'b1;
                    end
                endcase
            end
            if (error_second)
                hready <= 1'b1;
        end
    end
endmodule
