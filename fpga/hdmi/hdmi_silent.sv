// SPDX-License-Identifier: MIT
// A silent-audio door into hdl-util's HDMI transmitter.
//
// hdmi.sv takes its samples as an unpacked array port, and this project reads
// its own sources with Yosys's classic front end, which models `wire [n:0] x
// [m:0]` as a memory and cannot hand one to an array port.  This wrapper is
// read by read_slang, so the array lives entirely on that side, and the top
// level sees only scalars.
//
// Audio is silence in this image: both words are zero and the rate selector
// says 48 kHz, which is what the transmitter declares in its clock
// regeneration packets.  The pixel source is driven by cx/cy, which is the
// same raster the video unit used to count for itself.

module hdmi_silent #(
    parameter int VIDEO_ID_CODE = 4
) (
    input  wire        clk_pixel,
    input  wire        clk_pixel_x5,
    input  wire        clk_audio,
    input  wire        reset,
    input  wire [23:0] rgb,
    output wire [2:0]  tmds,
    output wire        tmds_clock,
    output wire [10:0] cx,
    output wire [9:0]  cy
);
    logic [15:0] audio_sample_word [1:0];
    assign audio_sample_word[0] = 16'd0;
    assign audio_sample_word[1] = 16'd0;

    hdmi #(
        .VIDEO_ID_CODE(VIDEO_ID_CODE),
        .DVI_OUTPUT(1'b0),
        .AUDIO_BIT_WIDTH(16),
        .VIDEO_REFRESH_RATE(60.0),
        .VENDOR_NAME({"TinyNES", 8'd0}),
        .PRODUCT_DESCRIPTION({"TinyNES", 120'd0})
    ) transmitter (
        .clk_pixel_x5(clk_pixel_x5),
        .clk_pixel(clk_pixel),
        .clk_audio(clk_audio),
        .audio_rate_48k(1'b1),
        .reset(reset),
        .rgb(rgb),
        .audio_sample_word(audio_sample_word),
        .tmds(tmds),
        .tmds_clock(tmds_clock),
        .cx(cx),
        .cy(cy)
    );
endmodule
