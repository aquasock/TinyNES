// SPDX-License-Identifier: MIT
// AE350 boot ROM on the ROM AHB port, which the A25 fetches from at its
// reset vector 0x80000000. Block RAM is initialised at synthesis from
// INIT_FILE ($readmemh, one 32-bit word per line). The ROM repeats every
// WORDS words and ignores writes.
//
// Each transfer has two wait states: the address is registered when the
// transfer is accepted, the block RAM is read in the next cycle and its
// output is registered in fabric, so every input of the AE350 macro comes
// straight from a flip-flop.
module ahb_boot_rom #(
    parameter integer WORDS = 8192,
    parameter INIT_FILE = "build/firmware/boot/boot.hex"
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    output reg  [31:0] hrdata,
    output reg         hready
);
    localparam integer ADDR_BITS = $clog2(WORDS);

    reg [31:0] rom [0:WORDS-1];
    initial $readmemh(INIT_FILE, rom);

    reg [ADDR_BITS-1:0] word = 0;
    reg [31:0] q;
    reg [1:0] stage = 2'b00;

    always @(posedge clk)
        q <= rom[word];

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            word <= 0;
            stage <= 2'b00;
            hrdata <= 32'd0;
            hready <= 1'b1;
        end else begin
            stage <= {stage[0], 1'b0};
            if (hready && htrans[1]) begin
                word <= haddr[ADDR_BITS+1:2];
                stage <= 2'b01;
                hready <= 1'b0;
            end
            if (stage[1]) begin
                hrdata <= q;
                hready <= 1'b1;
            end
        end
    end
endmodule
