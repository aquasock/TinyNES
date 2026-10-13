// SPDX-License-Identifier: MIT
// TinyNES AE350 system: the A25 boots C firmware from a block-RAM ROM on the
// ROM port (ahb_boot_rom), keeps its data and stack in block RAM on the RAM
// port at 0x60000000 (ahb_ram), has the dock's 32 MiB SDRAM on J9 at
// 0x40000000 on the same port (ahb_sdram), and sends and receives on the
// FPGA UART at 2,000,000 baud 8N1 through registers in the EXTS window
// (exts_uart), and drives the HDMI port at 1280x720 60 Hz (video) from two
// frame buffers in the top 128 KiB of the SDRAM, read through the SDRAM's
// video channel, with its registers, palette and emphasis in the EXTS
// window at 0xe8010000. Four Wii Classic Controllers on PMOD0 are read at
// 0xe8040000 (wii_pads), and stereo I2S for a Pmod I2S2 on PMOD1 is fed
// through a sample FIFO at 0xe8050000 (i2s_out). In the UART's link mode
// (desk_link) the line carries TinyTang's frames instead, and TinyDesk's
// layer is drawn over the picture.
//
// If the CPU has written nothing to the UART 2^NOBOOT_BITS bus clocks after
// reset (about 1.8 s), fabric reports instead, about once a second until the
// CPU writes, how many transfers each port has accepted, the addresses of the
// last ROM and RAM transfers, the RAM port state (see ST below) and the
// addresses of the first and last RAM transfers outside the RAM window:
//   NOBOOT ROM=<count> LAST=<address> RAM=<count> EXT=<count>
//          RAML=<address> ST=<state> S1=<address> SL=<address>   (one line)
module ae350_soc_top #(
    parameter INIT_FILE = "build/firmware/boot/boot.hex",
    parameter integer UART_DIV2 = 75, // 2 * 75 MHz / 2,000,000 baud
    parameter integer NOBOOT_BITS = 27,
    parameter integer SDRAM_INIT_CYCLES = 15000, // 200 us at 75 MHz
    // Diagnostics: CPU_HOLD 1 holds the A25 in reset; CPU_TX_DROP 1 lets it
    // run but drops its UART bytes. Either way only NOBOOT reports.
    parameter integer CPU_HOLD = 0,
    parameter integer CPU_TX_DROP = 0
) (
    input  wire        sys_clk,
    output wire        uart_tx,
    input  wire        uart_rx,

    output wire        sdram_clk,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [1:0]  sdram_ba,
    output wire [12:0] sdram_a,
    output wire [1:0]  sdram_dqm,
    inout  wire [15:0] sdram_dq,

    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,
    output wire [2:0]  tmds_d_n,
    inout  wire [7:0]  pmod0,
    // Pmod I2S2 seated normally on PMOD1: its DAC's MCLK, LRCK, SCLK and
    // SDIN on Digilent pins 1-4. Pins 7-10, the ADC, are left unused.
    output wire [3:0]  pmod1_dac
);
    wire pll_locked;
    wire bus_clk;
    wire core_clk;

    // The AE350's dedicated clock input is PLL_R[0] CLKOUT1 on this part.
    // 50 MHz * 15 = 750 MHz VCO; CLKOUT0 / 10 = 75 MHz AHB bus;
    // CLKOUT1 / 1 = 750 MHz core.
    PLL #(
        .FCLKIN("50"),
        .IDIV_SEL(1),
        .FBDIV_SEL(1),
        .MDIV_SEL(15),
        .ODIV0_SEL(10),
        .ODIV1_SEL(1),
        .CLKOUT0_EN("TRUE"),
        .CLKOUT1_EN("TRUE")
    ) cpu_pll (
        .CLKIN(sys_clk),
        .CLKFB(1'b0),
        .RESET(1'b0),
        .PLLPWD(1'b0),
        .RESET_I(1'b0),
        .RESET_O(1'b0),
        .FBDSEL(6'b0),
        .IDSEL(6'b0),
        .MDSEL(7'b0),
        .MDSEL_FRAC(3'b0),
        .ODSEL0(7'b0),
        .ODSEL0_FRAC(3'b0),
        .ODSEL1(7'b0),
        .ODSEL2(7'b0),
        .ODSEL3(7'b0),
        .ODSEL4(7'b0),
        .ODSEL5(7'b0),
        .ODSEL6(7'b0),
        .DT0(4'b0),
        .DT1(4'b0),
        .DT2(4'b0),
        .DT3(4'b0),
        .ICPSEL(6'b0),
        .LPFRES(3'b0),
        .LPFCAP(2'b0),
        .PSSEL(3'b0),
        .PSDIR(1'b0),
        .PSPULSE(1'b0),
        .ENCLK0(1'b1),
        .ENCLK1(1'b1),
        .ENCLK2(1'b0),
        .ENCLK3(1'b0),
        .ENCLK4(1'b0),
        .ENCLK5(1'b0),
        .ENCLK6(1'b0),
        .SSCPOL(1'b0),
        .SSCON(1'b0),
        .SSCMDSEL(7'b0),
        .SSCMDSEL_FRAC(3'b0),
        .LOCK(pll_locked),
        .CLKOUT0(bus_clk),
        .CLKOUT1(core_clk),
        .CLKOUT2(),
        .CLKOUT3(),
        .CLKOUT4(),
        .CLKOUT5(),
        .CLKOUT6(),
        .CLKFBOUT()
    );

    reg [7:0] reset_count = 8'd0;
    reg resetn = 1'b0;
    always @(posedge bus_clk or negedge pll_locked) begin
        if (!pll_locked) begin
            reset_count <= 8'd0;
            resetn <= 1'b0;
        end else if (!resetn) begin
            reset_count <= reset_count + 1'b1;
            if (&reset_count)
                resetn <= 1'b1;
        end
    end

    wire [31:0] rom_addr;
    wire [1:0] rom_trans;
    wire [31:0] rom_rdata;
    wire rom_ready;

    wire [31:0] ram_addr;
    wire [1:0] ram_trans;
    wire ram_write;
    wire [2:0] ram_size;
    wire [63:0] ram_wdata;
    wire [63:0] ram_rdata;
    wire ram_ready;
    wire ram_resp;
    wire ram_stray;
    wire [2:0] ram_burst;
    wire [3:0] ram_prot;

    wire sd_req;
    wire sd_write;
    wire [24:3] sd_addr;
    wire [7:0] sd_lanes;
    wire [63:0] sd_wdata;
    wire sd_ack;
    wire [63:0] sd_rdata;

    wire vid_start;
    wire [24:8] vid_addr;
    wire vid_valid;
    wire [6:0] vid_index;
    wire [15:0] vid_data;
    wire vid_done;

    wire [31:0] exts_addr;
    wire [31:0] exts_wdata;
    wire exts_sel;
    wire [1:0] exts_trans;
    wire exts_write;
    wire [31:0] exts_rdata;
    wire [2:0] exts_size;
    wire exts_ready;
    wire exts_resp;

    ahb_boot_rom #(.INIT_FILE(INIT_FILE)) boot_rom (
        .clk(bus_clk),
        .resetn(resetn),
        .haddr(rom_addr),
        .htrans(rom_trans),
        .hrdata(rom_rdata),
        .hready(rom_ready)
    );

    ahb_ram ram (
        .clk(bus_clk),
        .resetn(resetn),
        .haddr(ram_addr),
        .htrans(ram_trans),
        .hwrite(ram_write),
        .hsize(ram_size),
        .hprot0(ram_prot[0]),
        .hwdata(ram_wdata),
        .hrdata(ram_rdata),
        .hready(ram_ready),
        .hresp(ram_resp),
        .stray(ram_stray),
        .sd_req(sd_req),
        .sd_write(sd_write),
        .sd_addr(sd_addr),
        .sd_lanes(sd_lanes),
        .sd_wdata(sd_wdata),
        .sd_ack(sd_ack),
        .sd_rdata(sd_rdata)
    );

    ahb_sdram #(.INIT_CYCLES(SDRAM_INIT_CYCLES)) sdram (
        .clk(bus_clk),
        .resetn(resetn),
        .req(sd_req),
        .write(sd_write),
        .addr(sd_addr),
        .lanes(sd_lanes),
        .wdata(sd_wdata),
        .ack(sd_ack),
        .rdata(sd_rdata),
        .ready(),
        .vstart(vid_start),
        .vaddr(vid_addr),
        .vvalid(vid_valid),
        .vindex(vid_index),
        .vdata(vid_data),
        .vdone(vid_done),
        .sdram_clk(sdram_clk),
        .sdram_cs_n(sdram_cs_n),
        .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n),
        .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba),
        .sdram_a(sdram_a),
        .sdram_dqm(sdram_dqm),
        .sdram_dq(sdram_dq)
    );

    wire fb_valid;
    wire [7:0] fb_data;
    wire fb_ready;
    wire cpu_owns;

    wire link, rx_link_valid, txt_valid, txt_ready, ln_valid, ln_ready;
    wire link_idle, link_flush;
    wire [7:0] rx_link_data, txt_data, ln_data;
    wire [31:0] link_status;
    wire [15:0] pad0_held;
    wire layer_on, cell_valid, cell_ready;
    wire [11:0] cell_addr;
    wire [36:0] cell_data;

    // The EXTS window: 0xe8010000 selects video, 0xe8040000 selects the
    // Wii pads, 0xe8050000 the audio, and 0xe8000000 selects UART. The open flow has no
    // timing model for the AE350's ports, so each path to or from them has
    // at most one LUT: HREADY is the AND of the slaves' registered HREADYs,
    // HRESP their OR, and read data a mux on a registered UART select.
    wire video_hit = !exts_addr[18] && (exts_addr[17] | exts_addr[16]);
    wire pads_hit = exts_addr[18] && !(exts_addr[17] | exts_addr[16]);
    wire audio_hit = exts_addr[18] && !exts_addr[17] && exts_addr[16];
    reg data_uart = 1'b1;
    wire [31:0] uart_rdata, video_rdata, pads_rdata, audio_rdata;
    wire uart_ready, uart_resp, video_ready, video_resp, pads_ready, pads_resp;
    wire audio_ready, audio_resp;
    always @(posedge bus_clk or negedge resetn)
        if (!resetn)
            data_uart <= 1'b1;
        else if (exts_ready)
            data_uart <= !video_hit && !pads_hit && !audio_hit;
    assign exts_rdata = data_uart ? uart_rdata
                                  : (video_rdata | pads_rdata | audio_rdata);
    assign exts_ready = uart_ready & video_ready & pads_ready & audio_ready;
    assign exts_resp = uart_resp | video_resp | pads_resp | audio_resp;

    exts_uart #(.UART_DIV2(UART_DIV2), .DROP_CPU_TX(CPU_TX_DROP)) regs (
        .clk(bus_clk),
        .resetn(resetn),
        .haddr(exts_addr),
        .htrans(exts_trans),
        .hsel(exts_sel && !video_hit && !pads_hit && !audio_hit),
        .hready_in(exts_ready),
        .hwrite(exts_write),
        .hwdata(exts_wdata),
        .hrdata(uart_rdata),
        .hready(uart_ready),
        .hresp(uart_resp),
        .fb_valid(fb_valid),
        .fb_data(fb_data),
        .fb_ready(fb_ready),
        .cpu_owns(cpu_owns),
        .link(link),
        .rx_link_valid(rx_link_valid),
        .rx_link_data(rx_link_data),
        .txt_valid(txt_valid),
        .txt_data(txt_data),
        .txt_ready(txt_ready),
        .ln_valid(ln_valid),
        .ln_data(ln_data),
        .ln_ready(ln_ready),
        .link_idle(link_idle),
        .link_flush(link_flush),
        .link_status(link_status),
        .tx(uart_tx),
        .rx(uart_rx)
    );

    // The instance name sorts after "bus_clk" (DEV-016; see sound below).
    desk_link desk (
        .clk(bus_clk), .resetn(resetn), .link(link),
        .rx_valid(rx_link_valid), .rx_data(rx_link_data),
        .txt_valid(txt_valid), .txt_data(txt_data), .txt_ready(txt_ready),
        .flush(link_flush),
        .ln_valid(ln_valid), .ln_data(ln_data), .ln_ready(ln_ready),
        .idle(link_idle),
        .pad_held(pad0_held),
        .cell_valid(cell_valid), .cell_addr(cell_addr), .cell_data(cell_data),
        .cell_ready(cell_ready),
        .layer_on(layer_on),
        .status(link_status)
    );

    wire [3:0] pad_scl_in, pad_sda_in, pad_scl_low, pad_sda_low;
    genvar pad_index;
    generate
        for (pad_index = 0; pad_index < 4; pad_index = pad_index + 1) begin : pad_io
            // Digilent pins 1-4 are SCL, pins 7-10 are SDA. Sipeed's IO
            // numbering interleaves the rows: each controller uses a pair.
            IOBUF scl_buf (
                .I(1'b0), .OEN(!pad_scl_low[pad_index]),
                .O(pad_scl_in[pad_index]), .IO(pmod0[2*pad_index])
            );
            IOBUF sda_buf (
                .I(1'b0), .OEN(!pad_sda_low[pad_index]),
                .O(pad_sda_in[pad_index]), .IO(pmod0[2*pad_index+1])
            );
        end
    endgenerate

    wii_pads pads (
        .clk(bus_clk), .resetn(resetn),
        .haddr(exts_addr[11:0]), .htrans(exts_trans),
        .hsel(exts_sel && pads_hit), .hwrite(exts_write),
        .hsize(exts_size), .hwdata(exts_wdata), .hready_in(exts_ready),
        .hrdata(pads_rdata), .hready(pads_ready), .hresp(pads_resp),
        .scl_in(pad_scl_in), .sda_in(pad_sda_in),
        .scl_low(pad_scl_low), .sda_low(pad_sda_low),
        .pad0_held(pad0_held)
    );

    // The instance name sorts after "bus_clk": Yosys names a flattened net
    // after the alphabetically first of its names, and nextpnr's
    // NPNR_GOWIN_CLK_FIRST finds the bus clock only as bus_clk (DEV-016).
    i2s_out sound (
        .clk(bus_clk), .resetn(resetn),
        .haddr(exts_addr[11:0]), .htrans(exts_trans),
        .hsel(exts_sel && audio_hit), .hwrite(exts_write),
        .hsize(exts_size), .hwdata(exts_wdata), .hready_in(exts_ready),
        .hrdata(audio_rdata), .hready(audio_ready), .hresp(audio_resp),
        .mclk(pmod1_dac[0]), .lrck(pmod1_dac[1]),
        .sclk(pmod1_dac[2]), .sdin(pmod1_dac[3])
    );

    // HDMI: 50 MHz -> 27 MHz -> 371.25 MHz serial clock (hdmi_pll), divided
    // by 5 to the 74.25 MHz pixel clock. 50 * 27 = 1350 MHz VCO / 50; 27 * 55
    // = 1485 MHz VCO / 4.
    wire clk27;
    wire pix_clk5;
    wire pix_clk;
    PLL #(
        .FCLKIN("50"),
        .IDIV_SEL(1),
        .FBDIV_SEL(1),
        .MDIV_SEL(27),
        .ODIV0_SEL(50),
        .CLKOUT0_EN("TRUE")
    ) hdmi_pll27 (
        .CLKIN(sys_clk),
        .CLKFB(1'b0),
        .RESET(1'b0),
        .PLLPWD(1'b0),
        .RESET_I(1'b0),
        .RESET_O(1'b0),
        .FBDSEL(6'b0),
        .IDSEL(6'b0),
        .MDSEL(7'b0),
        .MDSEL_FRAC(3'b0),
        .ODSEL0(7'b0),
        .ODSEL0_FRAC(3'b0),
        .ODSEL1(7'b0),
        .ODSEL2(7'b0),
        .ODSEL3(7'b0),
        .ODSEL4(7'b0),
        .ODSEL5(7'b0),
        .ODSEL6(7'b0),
        .DT0(4'b0),
        .DT1(4'b0),
        .DT2(4'b0),
        .DT3(4'b0),
        .ICPSEL(6'b0),
        .LPFRES(3'b0),
        .LPFCAP(2'b0),
        .PSSEL(3'b0),
        .PSDIR(1'b0),
        .PSPULSE(1'b0),
        .ENCLK0(1'b1),
        .ENCLK1(1'b0),
        .ENCLK2(1'b0),
        .ENCLK3(1'b0),
        .ENCLK4(1'b0),
        .ENCLK5(1'b0),
        .ENCLK6(1'b0),
        .SSCPOL(1'b0),
        .SSCON(1'b0),
        .SSCMDSEL(7'b0),
        .SSCMDSEL_FRAC(3'b0),
        .LOCK(),
        .CLKOUT0(clk27),
        .CLKOUT1(),
        .CLKOUT2(),
        .CLKOUT3(),
        .CLKOUT4(),
        .CLKOUT5(),
        .CLKOUT6(),
        .CLKFBOUT()
    );
    PLL #(
        .FCLKIN("27"),
        .IDIV_SEL(1),
        .FBDIV_SEL(1),
        .MDIV_SEL(55),
        .ODIV0_SEL(4),
        .CLKOUT0_EN("TRUE")
    ) hdmi_pll (
        .CLKIN(clk27),
        .CLKFB(1'b0),
        .RESET(1'b0),
        .PLLPWD(1'b0),
        .RESET_I(1'b0),
        .RESET_O(1'b0),
        .FBDSEL(6'b0),
        .IDSEL(6'b0),
        .MDSEL(7'b0),
        .MDSEL_FRAC(3'b0),
        .ODSEL0(7'b0),
        .ODSEL0_FRAC(3'b0),
        .ODSEL1(7'b0),
        .ODSEL2(7'b0),
        .ODSEL3(7'b0),
        .ODSEL4(7'b0),
        .ODSEL5(7'b0),
        .ODSEL6(7'b0),
        .DT0(4'b0),
        .DT1(4'b0),
        .DT2(4'b0),
        .DT3(4'b0),
        .ICPSEL(6'b0),
        .LPFRES(3'b0),
        .LPFCAP(2'b0),
        .PSSEL(3'b0),
        .PSDIR(1'b0),
        .PSPULSE(1'b0),
        .ENCLK0(1'b1),
        .ENCLK1(1'b0),
        .ENCLK2(1'b0),
        .ENCLK3(1'b0),
        .ENCLK4(1'b0),
        .ENCLK5(1'b0),
        .ENCLK6(1'b0),
        .SSCPOL(1'b0),
        .SSCON(1'b0),
        .SSCMDSEL(7'b0),
        .SSCMDSEL_FRAC(3'b0),
        .LOCK(),
        .CLKOUT0(pix_clk5),
        .CLKOUT1(),
        .CLKOUT2(),
        .CLKOUT3(),
        .CLKOUT4(),
        .CLKOUT5(),
        .CLKOUT6(),
        .CLKFBOUT()
    );

    reg [7:0] hdmi_reset_count = 8'd255;
    reg hdmi_resetn = 1'b0;
    always @(posedge sys_clk) begin
        if (hdmi_reset_count != 8'd0)
            hdmi_reset_count <= hdmi_reset_count - 1'b1;
        else
            hdmi_resetn <= 1'b1;
    end

    CLKDIV #(.DIV_MODE("5")) pix_div (
        .CLKOUT(pix_clk),
        .HCLKIN(pix_clk5),
        .RESETN(hdmi_resetn),
        .CALIB(1'b0)
    );

    reg [2:0] pix_reset_sync = 3'b111;
    always @(posedge pix_clk or negedge hdmi_resetn)
        if (!hdmi_resetn)
            pix_reset_sync <= 3'b111;
        else
            pix_reset_sync <= {pix_reset_sync[1:0], 1'b0};
    wire pix_reset = pix_reset_sync[2];

    wire [9:0] tmds_ch [0:2];   // blue, green, red
    video screen (
        .clk(bus_clk),
        .resetn(resetn),
        .haddr(exts_addr[17:0]),
        .htrans(exts_trans),
        .hsel(exts_sel && video_hit),
        .hwrite(exts_write),
        .hsize(exts_size),
        .hwdata(exts_wdata),
        .hready_in(exts_ready),
        .hrdata(video_rdata),
        .hready(video_ready),
        .hresp(video_resp),
        .vstart(vid_start),
        .vaddr(vid_addr),
        .vvalid(vid_valid),
        .vindex(vid_index),
        .vdata(vid_data),
        .vdone(vid_done),
        .layer_on(layer_on),
        .cell_valid(cell_valid),
        .cell_addr(cell_addr),
        .cell_data(cell_data),
        .cell_ready(cell_ready),
        .pix_clk(pix_clk),
        .pix_reset(pix_reset),
        .tmds_blue(tmds_ch[0]),
        .tmds_green(tmds_ch[1]),
        .tmds_red(tmds_ch[2])
    );

    wire [3:0] tmds;   // {clock lane, red, green, blue}
    genvar lane;
    generate
        for (lane = 0; lane < 3; lane = lane + 1) begin : hdmi_ser
            OSER10 ser (
                .Q(tmds[lane]),
                .D0(tmds_ch[lane][0]), .D1(tmds_ch[lane][1]), .D2(tmds_ch[lane][2]),
                .D3(tmds_ch[lane][3]), .D4(tmds_ch[lane][4]), .D5(tmds_ch[lane][5]),
                .D6(tmds_ch[lane][6]), .D7(tmds_ch[lane][7]), .D8(tmds_ch[lane][8]),
                .D9(tmds_ch[lane][9]),
                .PCLK(pix_clk),
                .FCLK(pix_clk5),
                .RESET(pix_reset)
            );
        end
    endgenerate
    assign tmds[3] = pix_clk;
    ELVDS_OBUF tmds_buf [3:0] (
        .I(tmds),
        .O({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n})
    );

    AE350_SOC cpu (
        .POR_N(1'b1),
        .HW_RSTN(CPU_HOLD ? 1'b0 : resetn),
        .CORE_CLK(core_clk),
        .DDR_CLK(bus_clk),
        .AHB_CLK(bus_clk),
        .APB_CLK(bus_clk),
        .DBG_TCK(1'b1),
        .RTC_CLK(bus_clk),
        .CORE_CE(1'b1),
        .AXI_CE(1'b1),
        .DDR_CE(1'b1),
        .AHB_CE(1'b1),
        .APB_CE(8'b00000001),
        .APB2AHB_CE(1'b1),
        .GP_INT(16'b0),
        .DMA_REQ(8'b0),
        .WAKEUP_IN(1'b0),
        .SCAN_TEST(1'b0),
        .SCAN_EN(1'b0),
        .SCAN_IN(20'hfffff),
        .TEST_CLK(1'b0),
        .TEST_MODE(1'b0),
        .TEST_RSTN(1'b1),
        .INTEG_TCK(1'b1),
        .INTEG_TDI(1'b1),
        .INTEG_TMS(1'b1),
        .INTEG_TRST(1'b0),
        .PGEN_CHAIN_I(1'b1),
        .EMA(3'b011),
        .EMAW(2'b01),
        .EMAS(1'b0),
        .RET1N(1'b1),
        .RET2N(1'b1),
        .ROM_HADDR(rom_addr),
        .ROM_HTRANS(rom_trans),
        .ROM_HRDATA(rom_rdata),
        .ROM_HREADY(rom_ready),
        .ROM_HRESP(1'b0),
        .APB_PRDATA(32'b0),
        .APB_PREADY(1'b1),
        .APB_PSLVERR(1'b0),
        .EXTS_HADDR(exts_addr),
        .EXTS_HSEL(exts_sel),
        .EXTS_HTRANS(exts_trans),
        .EXTS_HWRITE(exts_write),
        .EXTS_HSIZE(exts_size),
        .EXTS_HWDATA(exts_wdata),
        .EXTS_HRDATA(exts_rdata),
        .EXTS_HREADYIN(exts_ready),
        .EXTS_HRESP(exts_resp),
        .EXTM_HADDR(32'b0),
        .EXTM_HBURST(3'b0),
        .EXTM_HPROT(4'b0),
        .EXTM_HREADY(1'b1),
        .EXTM_HSEL(1'b0),
        .EXTM_HSIZE(3'b0),
        .EXTM_HTRANS(2'b0),
        .EXTM_HWDATA(64'b0),
        .EXTM_HWRITE(1'b0),
        .DDR_HADDR(ram_addr),
        .DDR_HTRANS(ram_trans),
        .DDR_HWRITE(ram_write),
        .DDR_HSIZE(ram_size),
        .DDR_HBURST(ram_burst),
        .DDR_HPROT(ram_prot),
        .DDR_HWDATA(ram_wdata),
        .DDR_HRDATA(ram_rdata),
        .DDR_HREADY(ram_ready),
        .DDR_HRESP(ram_resp),
        .TMS_IN(1'b1),
        // Keep the AE350 JTAG test-reset deasserted, as in the working
        // Tang-Phosphor smoke design.
        .TRST_IN(1'b1),
        .TDI_IN(1'b1),
        .SPI2_HOLDN_IN(1'b1),
        .SPI2_WPN_IN(1'b1),
        .SPI2_CLK_IN(1'b1),
        .SPI2_CSN_IN(1'b1),
        .SPI2_MISO_IN(1'b1),
        .SPI2_MOSI_IN(1'b1),
        .I2C_SCL_IN(1'b1),
        .I2C_SDA_IN(1'b1),
        .UART1_RXD(1'b1),
        .UART1_CTSN(1'b1),
        .UART1_DSRN(1'b1),
        .UART1_DCDN(1'b1),
        .UART1_RIN(1'b1),
        .UART2_RXD(1'b1),
        .UART2_CTSN(1'b1),
        .UART2_DSRN(1'b1),
        .UART2_DCDN(1'b1),
        .UART2_RIN(1'b1),
        .GPIO_IN(32'b0)
    );

    // Transfers accepted on each port, for the NOBOOT report.
    reg [31:0] rom_count = 32'd0;
    reg [31:0] rom_last = 32'd0;
    reg [31:0] ram_count = 32'd0;
    reg [31:0] ext_count = 32'd0;
    reg [31:0] ram_last = 32'd0;
    reg [7:0] ram_info = 8'd0;
    reg [7:0] stray_info = 8'd0;
    reg [31:0] stray_first = 32'd0;
    reg [31:0] stray_last = 32'd0;
    reg [15:0] stray_count = 16'd0;
    always @(posedge bus_clk or negedge resetn) begin
        if (!resetn) begin
            rom_count <= 32'd0;
            rom_last <= 32'd0;
            ram_count <= 32'd0;
            ext_count <= 32'd0;
            ram_last <= 32'd0;
            ram_info <= 8'd0;
            stray_info <= 8'd0;
            stray_first <= 32'd0;
            stray_last <= 32'd0;
            stray_count <= 16'd0;
        end else begin
            if (rom_ready && rom_trans[1]) begin
                rom_count <= rom_count + 1'b1;
                rom_last <= rom_addr;
            end
            if (ram_ready && ram_trans[1]) begin
                ram_count <= ram_count + 1'b1;
                ram_last <= ram_addr;
                ram_info <= {ram_prot[0], ram_burst, ram_write, ram_size};
            end
            // ram_last still holds the transfer that stray completes.
            if (ram_stray) begin
                stray_count <= stray_count + 1'b1;
                stray_info <= ram_info;
                stray_last <= ram_last;
                if (stray_count == 16'd0)
                    stray_first <= ram_last;
            end
            if (exts_ready && exts_sel && exts_trans[1])
                ext_count <= ext_count + 1'b1;
        end
    end

    // ST: the last stray transfer's {HPROT[0], HBURST} (HPROT[0] is 0 for an
    // instruction fetch) and {HWRITE, HSIZE}, then the live
    // {ROM HREADY, RAM HREADY, RAM HRESP, EXTS HREADY} and {RAM HTRANS,
    // ROM HTRANS}, then the number of stray transfers (16 bits).
    wire [31:0] noboot_state = {stray_info,
                                rom_ready, ram_ready, ram_resp, exts_ready,
                                ram_trans, rom_trans, stray_count};

    // Hex fields at characters 11, 25, 38, 51, 65, 77, 89 and 101; CR at 109
    // and LF at 110.
    localparam [8*109-1:0] NOBOOT_TEXT =
        {"NOBOOT ROM=........ LAST=........ RAM=........ EXT=........ ",
         "RAML=........ ST=........ S1=........ SL=........"};
    reg [NOBOOT_BITS-1:0] noboot_wait = 0;
    reg noboot_armed = 1'b0;
    reg [6:0] noboot_index = 7'd0;
    reg [31:0] line_rom = 32'd0;
    reg [31:0] line_last = 32'd0;
    reg [31:0] line_ram = 32'd0;
    reg [31:0] line_ext = 32'd0;
    reg [31:0] line_raml = 32'd0;
    reg [31:0] line_state = 32'd0;
    reg [31:0] line_e1 = 32'd0;
    reg [31:0] line_el = 32'd0;

    function [7:0] hex_char(input [3:0] value);
        hex_char = (value < 4'd10) ? ("0" + value) : ("a" + value - 4'd10);
    endfunction

    function [7:0] hex_field(input [6:0] index, input [6:0] first,
                             input [31:0] value);
        hex_field = hex_char(value >> (4 * (first + 7'd7 - index)));
    endfunction

    function [7:0] noboot_char(input [6:0] index);
        if (index >= 7'd11 && index <= 7'd18)
            noboot_char = hex_field(index, 7'd11, line_rom);
        else if (index >= 7'd25 && index <= 7'd32)
            noboot_char = hex_field(index, 7'd25, line_last);
        else if (index >= 7'd38 && index <= 7'd45)
            noboot_char = hex_field(index, 7'd38, line_ram);
        else if (index >= 7'd51 && index <= 7'd58)
            noboot_char = hex_field(index, 7'd51, line_ext);
        else if (index >= 7'd65 && index <= 7'd72)
            noboot_char = hex_field(index, 7'd65, line_raml);
        else if (index >= 7'd77 && index <= 7'd84)
            noboot_char = hex_field(index, 7'd77, line_state);
        else if (index >= 7'd89 && index <= 7'd96)
            noboot_char = hex_field(index, 7'd89, line_e1);
        else if (index >= 7'd101 && index <= 7'd108)
            noboot_char = hex_field(index, 7'd101, line_el);
        else if (index == 7'd109)
            noboot_char = 8'h0d;
        else if (index == 7'd110)
            noboot_char = 8'h0a;
        else
            noboot_char = NOBOOT_TEXT[8 * (7'd108 - index) +: 8];
    endfunction

    assign fb_valid = noboot_armed && noboot_wait == 0 && !cpu_owns;
    assign fb_data = noboot_char(noboot_index);

    always @(posedge bus_clk or negedge resetn) begin
        if (!resetn) begin
            noboot_wait <= 0;
            noboot_armed <= 1'b0;
            noboot_index <= 7'd0;
            line_rom <= 32'd0;
            line_last <= 32'd0;
            line_ram <= 32'd0;
            line_ext <= 32'd0;
            line_raml <= 32'd0;
            line_state <= 32'd0;
            line_e1 <= 32'd0;
            line_el <= 32'd0;
        end else if (!noboot_armed) begin
            noboot_wait <= noboot_wait - 1'b1;
            if (noboot_wait == 1)
                noboot_armed <= 1'b1;
        end else if (noboot_wait != 0) begin
            noboot_wait <= noboot_wait - 1'b1;
        end else if (fb_valid && fb_ready) begin
            if (noboot_index == 7'd0) begin
                line_rom <= rom_count;
                line_last <= rom_last;
                line_ram <= ram_count;
                line_ext <= ext_count;
                line_raml <= ram_last;
                line_state <= noboot_state;
                line_e1 <= stray_first;
                line_el <= stray_last;
            end
            if (noboot_index == 7'd110) begin
                noboot_index <= 7'd0;
                noboot_wait <= {1'b0, {(NOBOOT_BITS - 1){1'b1}}};
            end else begin
                noboot_index <= noboot_index + 1'b1;
            end
        end
    end
endmodule
