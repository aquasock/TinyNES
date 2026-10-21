// SPDX-License-Identifier: MIT
// A silent-audio door into hdl-util's HDMI transmitter.
//
// hdmi.sv takes its samples as an unpacked array port, and this project reads
// its own sources with Yosys's classic front end, which models `wire [n:0] x
// [m:0]` as a memory and cannot hand one to an array port.  This wrapper is
// read by read_slang, so the array lives entirely on that side, and the top
// level sees only scalars.
//
// The audio words are the I2S unit's own stream, clocked by its frame clock,
// which runs at 75 MHz / 1536 = 48,828.125 Hz rather than a nominal 48 kHz.
// The transmitter measures CTS against the pixel clock, so its clock
// regeneration packet states the true rate without a table for it; the rate
// selector keeps the 48 kHz N value, which only sizes the measurement window.
// The pixel source is driven by cx/cy, which is the same raster the video unit
// used to count for itself.

module hdmi_silent #(
    parameter int VIDEO_ID_CODE = 4
) (
    input  wire        clk_pixel,
    input  wire        clk_pixel_x5,
    input  wire        clk_audio,
    input  wire [15:0] audio_left,
    input  wire [15:0] audio_right,
    input  wire        reset,
    input  wire [23:0] rgb,
    output wire [2:0]  tmds,
    output wire        tmds_clock,
    output wire [10:0] cx,
    output wire [9:0]  cy
);
    logic [15:0] audio_sample_word [1:0];
    assign audio_sample_word[0] = audio_left;
    assign audio_sample_word[1] = audio_right;

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
