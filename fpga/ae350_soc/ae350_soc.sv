// SPDX-License-Identifier: MIT
// TinyNES AE350 system: the A25 boots C firmware from a block-RAM ROM on the
// ROM port (ahb_boot_rom), keeps its data and stack in block RAM on the RAM
// port at 0x40000000 (ahb_ram), and prints on the FPGA UART at 115200 8N1
// through registers in the EXTS window (exts_uart).
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
    parameter integer UART_DIV = 651, // 75 MHz / 115200
    parameter integer NOBOOT_BITS = 27,
    // Diagnostics: CPU_HOLD 1 holds the A25 in reset; CPU_TX_DROP 1 lets it
    // run but drops its UART bytes. Either way only NOBOOT reports.
    parameter integer CPU_HOLD = 0,
    parameter integer CPU_TX_DROP = 0
) (
    input  wire sys_clk,
    output wire uart_tx
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

    wire [31:0] exts_addr;
    wire [31:0] exts_wdata;
    wire exts_sel;
    wire [1:0] exts_trans;
    wire exts_write;
    wire [31:0] exts_rdata;
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
        .stray(ram_stray)
    );

    wire fb_valid;
    wire [7:0] fb_data;
    wire fb_ready;
    wire cpu_owns;

    exts_uart #(.UART_DIV(UART_DIV), .DROP_CPU_TX(CPU_TX_DROP)) regs (
        .clk(bus_clk),
        .resetn(resetn),
        .haddr(exts_addr),
        .htrans(exts_trans),
        .hsel(exts_sel),
        .hwrite(exts_write),
        .hwdata(exts_wdata),
        .hrdata(exts_rdata),
        .hready(exts_ready),
        .hresp(exts_resp),
        .fb_valid(fb_valid),
        .fb_data(fb_data),
        .fb_ready(fb_ready),
        .cpu_owns(cpu_owns),
        .tx(uart_tx)
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
