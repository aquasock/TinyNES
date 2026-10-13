// SPDX-License-Identifier: MIT
// Stereo I2S output for a Pmod I2S2's CS4344 DAC, with a sample FIFO the CPU
// fills through registers.
//
// Every clock is made from the bus clock by counting, so the unit adds no
// clock to the clock network: MCLK is the bus clock divided by MCLK_DIV
// (75 MHz / 6 = 12.5 MHz, high for three bus clocks and low for three), SCLK
// is MCLK / 4 and LRCK is MCLK / 256, so the sample rate is 75 MHz / 1536 =
// 48,828.125 Hz. The CS4344 takes a 256x MCLK at 2 to 50 kHz in single-speed
// mode, and needs MCLK, SCLK and LRCK synchronous with no set phase.
//
// The frame is I2S, 64 SCLKs: LRCK low for the left channel, high for the
// right. LRCK and SDIN change as SCLK falls and the DAC samples as it rises.
// Each channel's first SCLK is the I2S delay bit; the 16-bit sample follows
// MSB first, then zeros, so the DAC sees a 24-bit word with the sample in
// its top bits. Both channels of a frame come from one FIFO entry, taken as
// the frame starts. With the unit disabled, or the FIFO empty, the frame is
// silence; an empty FIFO while enabled counts as an underrun. The clocks run
// from reset, so the DAC is initialised long before a program plays.
//
// Registers, offsets from the unit's base (0xe8050000), 32-bit accesses only;
// any other access gets an AHB ERROR:
//   0x000  ID, read: ID_VALUE.
//   0x004  CTRL, read and write: bit 0 enables playback; writing bit 1 set
//          empties the FIFO (it reads 0).
//   0x008  STATUS, read: bits 11:0 the FIFO level in sample pairs, bits
//          31:16 underruns (wraps).
//   0x00c  DATA, write: one sample pair, left in bits 31:16 and right in
//          bits 15:0, two's complement. A write to a full FIFO is dropped.
//   0x010  FRAMES, read: LRCK frames sent since reset (wraps).
//   0x014  DROPS, read: writes dropped because the FIFO was full (wraps).
// Every transfer completes with no wait state.
module i2s_out #(
    parameter [31:0] ID_VALUE = 32'h544e4131, // "TNA1"
    parameter integer MCLK_DIV = 6,           // bus clocks per MCLK, even
    parameter integer DEPTH_BITS = 11         // 2048 sample pairs
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire [11:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hsel,
    input  wire        hwrite,
    input  wire [2:0]  hsize,
    input  wire [31:0] hwdata,
    input  wire        hready_in,
    output reg  [31:0] hrdata,
    output reg         hready,
    output reg         hresp,

    output reg         mclk,
    output reg         lrck,
    output reg         sclk,
    output reg         sdin
);
    localparam integer DEPTH = 1 << DEPTH_BITS;

    // ------------------------------------------------------------ clocks

    // div counts bus clocks within an MCLK; tick is the MCLK index within
    // the frame: tick[1:0] the MCLK within a bit, tick[6:2] the bit within
    // the channel and tick[7] the channel.
    reg [3:0] div = 4'd0;
    reg [7:0] tick = 8'd0;
    wire mclk_end = div == MCLK_DIV - 1;
    wire frame_start = mclk_end && tick == 8'd255;

    // ------------------------------------------------------------ FIFO

    reg [31:0] mem [0:DEPTH-1];
    reg [DEPTH_BITS-1:0] wr_ptr = 0, rd_ptr = 0;
    reg [DEPTH_BITS:0] level = 0;
    reg [31:0] head;
    // The entry at rd_ptr is in head two clocks after it was written, so a
    // pop looks at the level as it was two clocks ago.
    reg [DEPTH_BITS:0] level_d1 = 0, level_d2 = 0;
    reg enable = 1'b0;
    reg [15:0] underruns = 16'd0;
    reg [31:0] frames = 32'd0, drops = 32'd0;

    reg [31:0] frame = 32'd0;   // the pair being sent
    reg [31:0] shift = 32'd0;

    // ------------------------------------------------------------ bus

    reg ctrl_write = 1'b0, data_write = 1'b0;
    reg err2 = 1'b0;

    wire accept = hready_in && hsel && htrans[1];
    wire word = hsize == 3'd2 && haddr[1:0] == 2'b00;
    wire [9:0] reg_n = haddr[11:2];
    wire readable = reg_n <= 10'd5 && reg_n != 10'd3;
    wire writable = reg_n == 10'd1 || reg_n == 10'd3;
    wire ok = word && (hwrite ? writable : readable);

    wire flush = ctrl_write && hwdata[1];
    wire push = data_write && !flush && level != DEPTH;
    wire pop = frame_start && enable && level_d2 != 0 && !flush;
    // The level after this clock, which a STATUS read in the clock after a
    // DATA write must already show.
    wire [DEPTH_BITS:0] level_next = flush ? 0 :
        level + (push ? 1'b1 : 1'b0) - (pop ? 1'b1 : 1'b0);
    // The left channel is loaded in the clock that takes the new frame.
    wire [31:0] next_frame = pop ? head : 32'd0;

    always @(posedge clk) begin
        if (push)
            mem[wr_ptr] <= hwdata;
        head <= mem[rd_ptr];
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            div <= 4'd0;
            tick <= 8'd0;
            mclk <= 1'b0;
            lrck <= 1'b0;
            sclk <= 1'b0;
            sdin <= 1'b0;
            wr_ptr <= 0;
            rd_ptr <= 0;
            level <= 0;
            level_d1 <= 0;
            level_d2 <= 0;
            enable <= 1'b0;
            underruns <= 16'd0;
            frames <= 32'd0;
            drops <= 32'd0;
            frame <= 32'd0;
            shift <= 32'd0;
            ctrl_write <= 1'b0;
            data_write <= 1'b0;
            err2 <= 1'b0;
            hrdata <= 32'd0;
            hready <= 1'b1;
            hresp <= 1'b0;
        end else begin
            // Clocks. Every output is a register set from the counters, so
            // each changes once per edge with no glitch.
            div <= mclk_end ? 4'd0 : div + 4'd1;
            if (mclk_end)
                tick <= tick + 8'd1;
            mclk <= mclk_end ? 1'b0 : div == MCLK_DIV / 2 - 1 ? 1'b1 : mclk;
            if (mclk_end) begin
                // The edges below take effect at the start of MCLK tick + 1.
                sclk <= tick[1:0] == 2'd1 ? 1'b1 : tick[1:0] == 2'd3 ? 1'b0 : sclk;
                if (tick[1:0] == 2'd3) begin
                    // SCLK falls: the next bit, and LRCK at a channel start.
                    lrck <= tick[7:2] >= 6'd31 && tick[7:2] != 6'd63;
                    if (tick[6:2] == 5'd31) begin
                        // The delay bit; load the channel about to start.
                        sdin <= 1'b0;
                        shift <= tick[7] ? {next_frame[31:16], 16'd0}
                                         : {frame[15:0], 16'd0};
                    end else begin
                        sdin <= shift[31];
                        shift <= {shift[30:0], 1'b0};
                    end
                end
            end
            if (frame_start) begin
                frames <= frames + 32'd1;
                frame <= next_frame;
                if (enable && !pop && !flush)
                    underruns <= underruns + 16'd1;
            end

            // FIFO pointers.
            if (flush) begin
                wr_ptr <= 0;
                rd_ptr <= 0;
                level <= 0;
                level_d1 <= 0;
                level_d2 <= 0;
            end else begin
                if (push)
                    wr_ptr <= wr_ptr + 1'b1;
                if (pop)
                    rd_ptr <= rd_ptr + 1'b1;
                level <= level_next;
                // A pop also leaves the delayed levels, so they never count
                // an entry that has gone.
                level_d1 <= level - (pop ? 1'b1 : 1'b0);
                level_d2 <= level_d1 - (pop ? 1'b1 : 1'b0);
            end
            if (data_write && !flush && level == DEPTH)
                drops <= drops + 32'd1;
            if (ctrl_write)
                enable <= hwdata[0];

            // Bus. A write's data comes a clock after its address.
            ctrl_write <= accept && ok && hwrite && reg_n == 10'd1;
            data_write <= accept && ok && hwrite && reg_n == 10'd3;
            if (err2) begin
                err2 <= 1'b0;
                hready <= 1'b1;
            end else begin
                hresp <= 1'b0;
                hrdata <= 32'd0;
                if (accept && !ok) begin
                    hready <= 1'b0;
                    hresp <= 1'b1;
                    err2 <= 1'b1;
                end else if (accept && !hwrite) begin
                    case (reg_n[2:0])
                        3'd0: hrdata <= ID_VALUE;
                        3'd1: hrdata <= {31'd0, ctrl_write ? hwdata[0] : enable};
                        3'd2: hrdata <= {underruns, {(16 - DEPTH_BITS - 1){1'b0}}, level_next};
                        3'd4: hrdata <= frames;
                        default: hrdata <= drops;
                    endcase
                end
            end
        end
    end

endmodule
