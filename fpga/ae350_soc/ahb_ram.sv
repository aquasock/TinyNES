// SPDX-License-Identifier: MIT
// The AE350's 64-bit RAM AHB port (DDR_H*): block RAM at BASE for BYTES
// bytes, and the SDRAM at SDRAM_BASE for SDRAM_BYTES bytes through the
// ahb_sdram back end (sd_* below). A data transfer to any other address
// gets an AHB ERROR response, and an erroneous write changes nothing. An
// instruction fetch (HPROT[0] 0) to any other address reads zero with an
// OKAY response instead: the A25 fetches down mispredicted paths, address
// 0 included, and with both of its caches on it stops for good after such
// a line fill gets ERROR (core-log entry 7). Zero is an illegal
// instruction, so a fetch that is really executed still traps. stray
// pulses as each transfer outside both windows completes. Byte, halfword,
// word and doubleword writes update only their own byte lanes. Burst type
// is not needed: every beat is a complete transfer here.
//
// As in ahb_boot_rom, the transfer is registered when accepted and the
// macro's inputs come from flip-flops. A block RAM write is done in the
// cycle after it is accepted, when its data is on the bus (one wait state);
// a read takes two wait states, the second registering the block RAM
// output. An SDRAM transfer is passed on in the cycle after it is accepted,
// with its write data, and completes in the cycle after sd_ack.
module ahb_ram #(
    parameter integer BYTES = 65536,
    parameter [31:0] BASE = 32'h60000000,
    parameter integer SDRAM_BYTES = 32 * 1024 * 1024,
    parameter [31:0] SDRAM_BASE = 32'h40000000
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hwrite,
    input  wire [2:0]  hsize,
    input  wire        hprot0,
    input  wire [63:0] hwdata,
    output reg  [63:0] hrdata,
    output reg         hready,
    output reg         hresp,
    output reg         stray,

    output reg         sd_req,
    output reg         sd_write,
    output reg  [24:3] sd_addr,
    output reg  [7:0]  sd_lanes,
    output reg  [63:0] sd_wdata,
    input  wire        sd_ack,
    input  wire [63:0] sd_rdata
);
    localparam integer WORDS = BYTES / 8;
    localparam integer ADDR_BITS = $clog2(WORDS);
    localparam integer SPAN_BITS = ADDR_BITS + 3;
    localparam integer SDRAM_SPAN_BITS = $clog2(SDRAM_BYTES);

    function [7:0] lane_mask(input [2:0] addr, input [2:0] size);
        case (size)
            3'd0: lane_mask = 8'h01 << addr;
            3'd1: lane_mask = 8'h03 << {addr[2:1], 1'b0};
            3'd2: lane_mask = 8'h0f << {addr[2], 2'b00};
            default: lane_mask = 8'hff;
        endcase
    endfunction

    reg [ADDR_BITS-1:0] word = 0;
    reg write = 1'b0;
    reg hit = 1'b0;
    reg sd_hit = 1'b0;
    reg fetch = 1'b0;
    reg [7:0] lanes = 8'd0;
    // stage[0]: the cycle after acceptance; stage[1]: a block RAM read's
    // second wait state; stage[2]: the first cycle of an ERROR response;
    // stage[3]: waiting for sd_ack.
    reg [3:0] stage = 4'b0000;
    wire [63:0] q;

    genvar lane;
    generate
        for (lane = 0; lane < 8; lane = lane + 1) begin : lane_ram
            reg [7:0] mem [0:WORDS-1];
            reg [7:0] lane_q;
            always @(posedge clk) begin
                if (stage[0] && hit && write && lanes[lane])
                    mem[word] <= hwdata[8 * lane +: 8];
                lane_q <= mem[word];
            end
            assign q[8 * lane +: 8] = lane_q;
        end
    endgenerate

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            word <= 0;
            write <= 1'b0;
            hit <= 1'b0;
            sd_hit <= 1'b0;
            fetch <= 1'b0;
            lanes <= 8'd0;
            stage <= 4'b0000;
            hrdata <= 64'd0;
            hready <= 1'b1;
            hresp <= 1'b0;
            stray <= 1'b0;
            sd_req <= 1'b0;
            sd_write <= 1'b0;
            sd_addr <= 22'd0;
            sd_lanes <= 8'd0;
            sd_wdata <= 64'd0;
        end else begin
            stage <= 4'b0000;
            stray <= 1'b0;
            if (hready) begin
                hresp <= 1'b0;
                if (htrans[1]) begin
                    word <= haddr[SPAN_BITS-1:3];
                    write <= hwrite;
                    hit <= (haddr >> SPAN_BITS) == (BASE >> SPAN_BITS);
                    sd_hit <= (haddr >> SDRAM_SPAN_BITS) == (SDRAM_BASE >> SDRAM_SPAN_BITS);
                    sd_addr <= haddr[24:3];
                    sd_write <= hwrite;
                    sd_lanes <= lane_mask(haddr[2:0], hsize);
                    fetch <= !hprot0 && !hwrite;
                    lanes <= lane_mask(haddr[2:0], hsize);
                    stage <= 4'b0001;
                    hready <= 1'b0;
                end
            end
            if (stage[0]) begin
                if (sd_hit) begin
                    sd_req <= 1'b1;
                    sd_wdata <= hwdata;
                    stage <= 4'b1000;
                end else if (!hit && !fetch) begin
                    hresp <= 1'b1;
                    stage <= 4'b0100;
                end else if (write) begin
                    hready <= 1'b1;
                end else begin
                    stage <= 4'b0010;
                end
            end
            if (stage[3]) begin
                if (sd_ack) begin
                    sd_req <= 1'b0;
                    hrdata <= sd_rdata;
                    hready <= 1'b1;
                end else begin
                    stage <= 4'b1000;
                end
            end
            if (stage[1]) begin
                hrdata <= hit ? q : 64'd0;
                hready <= 1'b1;
                stray <= !hit;
            end
            if (stage[2]) begin
                hready <= 1'b1;
                stray <= 1'b1;
            end
        end
    end
endmodule
