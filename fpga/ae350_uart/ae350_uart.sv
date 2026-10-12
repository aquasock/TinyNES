// SPDX-License-Identifier: MIT
// First TinyNES hardware gate: the AE350 writes a status word over AHB;
// fabric reports that event periodically on the FPGA UART at 115200 8N1.
module ae350_uart #(
    parameter integer FORCE_UART = 0
) (
    input  wire sys_clk,
    output wire uart_tx
);
    wire pll_locked;
    wire bus_clk;
    wire core_clk;

    // The AE350's dedicated clock input is PLL_R[0] CLKOUT1 on this part.
    // 50 MHz * 15 = 750 MHz VCO; CLKOUT0 / 10 = 75 MHz AHB bus.
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

    // Reset vector 0x80000000. The program writes bit 4 to 0xe8000000,
    // then loops. These words are RV32I LUI, ADDI, SW, JAL.
    wire [31:0] rom_addr;
    wire [1:0] rom_trans;
    reg rom_addr_seen = 1'b0;
    reg rom_seen = 1'b0;
    reg [31:0] rom_data;
    always @* begin
        case (rom_addr[3:2])
            2'd0: rom_data = 32'he80002b7; // lui t0, 0xe8000
            2'd1: rom_data = 32'h01000313; // addi t1, zero, 16
            2'd2: rom_data = 32'h0062a023; // sw t1, 0(t0)
            default: rom_data = 32'h0000006f; // jal zero, 0
        endcase
    end

    wire [31:0] exts_addr;
    wire [31:0] exts_wdata;
    wire exts_sel;
    wire [1:0] exts_trans;
    wire exts_write;
    reg write_pending = 1'b0;
    reg cpu_started = 1'b0;

    always @(posedge bus_clk or negedge resetn) begin
        if (!resetn)
            rom_addr_seen <= 1'b0;
        else if (rom_addr[31])
            rom_addr_seen <= 1'b1;
    end

    always @(posedge bus_clk or negedge resetn) begin
        if (!resetn)
            rom_seen <= 1'b0;
        else if (rom_trans[1])
            rom_seen <= 1'b1;
    end

    // AHB-Lite places write data one bus cycle after address/control.
    always @(posedge bus_clk or negedge resetn) begin
        if (!resetn) begin
            write_pending <= 1'b0;
            cpu_started <= 1'b0;
        end else begin
            // The current open chipdb omits EXTS_HWDATA[0,3] and
            // EXTS_HADDR[31]. This diagnostic uses mapped bit 4 and HSEL.
            if (write_pending && exts_wdata[4])
                cpu_started <= 1'b1;
            write_pending <= exts_sel && exts_trans[1] && exts_write &&
                             (exts_addr[7:2] == 6'd0);
        end
    end

    AE350_SOC cpu (
        .POR_N(1'b1),
        .HW_RSTN(resetn),
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
        .ROM_HRDATA(rom_data),
        .ROM_HREADY(1'b1),
        .ROM_HRESP(1'b0),
        .APB_PRDATA(32'b0),
        .APB_PREADY(1'b1),
        .APB_PSLVERR(1'b0),
        .EXTS_HADDR(exts_addr),
        .EXTS_HSEL(exts_sel),
        .EXTS_HTRANS(exts_trans),
        .EXTS_HWRITE(exts_write),
        .EXTS_HWDATA(exts_wdata),
        .EXTS_HRDATA({31'd0, cpu_started}),
        .EXTS_HREADYIN(1'b1),
        .EXTS_HRESP(1'b0),
        .EXTM_HADDR(32'b0),
        .EXTM_HBURST(3'b0),
        .EXTM_HPROT(4'b0),
        .EXTM_HREADY(1'b1),
        .EXTM_HSEL(1'b0),
        .EXTM_HSIZE(3'b0),
        .EXTM_HTRANS(2'b0),
        .EXTM_HWDATA(64'b0),
        .EXTM_HWRITE(1'b0),
        .DDR_HRDATA(64'b0),
        .DDR_HREADY(1'b1),
        .DDR_HRESP(1'b0),
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

    // The FT2232 one-wire bridge is slow to deliver sustained data. Send a
    // short line every 2^26 bus clocks, about 0.895 s at 75 MHz.
    localparam integer UART_DIV = 651; // 75 MHz / 115200 ~= 651
    localparam [4:0] REPORT_LAST_INDEX = (FORCE_UART == 2) ? 5'd19 : 5'd17;
    reg [25:0] report_wait = 26'd0;
    reg [4:0] char_index = 5'd0;
    reg [9:0] tx_shift = 10'h3ff;
    reg [3:0] bits_left = 4'd0;
    reg [9:0] baud_wait = 10'd0;

    function [7:0] report_char(
        input [4:0] index,
        input rom_addr_seen_in,
        input rom_seen_in,
        input cpu_started_in
    );
        if (FORCE_UART == 2) begin
            case (index)
                5'd0: report_char = "A";
                5'd1: report_char = "D";
                5'd2: report_char = "D";
                5'd3: report_char = "R";
                5'd4: report_char = "=";
                5'd5: report_char = rom_addr_seen_in ? "1" : "0";
                5'd6: report_char = " ";
                5'd7: report_char = "R";
                5'd8: report_char = "O";
                5'd9: report_char = "M";
                5'd10: report_char = "=";
                5'd11: report_char = rom_seen_in ? "1" : "0";
                5'd12: report_char = " ";
                5'd13: report_char = "A";
                5'd14: report_char = "H";
                5'd15: report_char = "B";
                5'd16: report_char = "=";
                5'd17: report_char = cpu_started_in ? "1" : "0";
                5'd18: report_char = 8'h0d;
                default: report_char = 8'h0a;
            endcase
        end else if (FORCE_UART == 1) begin
            case (index)
                5'd0:  report_char = "U";
                5'd1:  report_char = "A";
                5'd2:  report_char = "R";
                5'd3:  report_char = "T";
                5'd4:  report_char = " ";
                5'd5:  report_char = "D";
                5'd6:  report_char = "I";
                5'd7:  report_char = "A";
                5'd8:  report_char = "G";
                5'd9:  report_char = "N";
                5'd10: report_char = "O";
                5'd11: report_char = "S";
                5'd12: report_char = "T";
                5'd13: report_char = "I";
                5'd14: report_char = "C";
                5'd15: report_char = "!";
                5'd16: report_char = 8'h0d;
                default: report_char = 8'h0a;
            endcase
        end else case (index)
            5'd0:  report_char = "T";
            5'd1:  report_char = "i";
            5'd2:  report_char = "n";
            5'd3:  report_char = "y";
            5'd4:  report_char = "N";
            5'd5:  report_char = "E";
            5'd6:  report_char = "S";
            5'd7:  report_char = " ";
            5'd8:  report_char = "A";
            5'd9:  report_char = "E";
            5'd10: report_char = "3";
            5'd11: report_char = "5";
            5'd12: report_char = "0";
            5'd13: report_char = " ";
            5'd14: report_char = "O";
            5'd15: report_char = "K";
            5'd16: report_char = 8'h0d;
            default: report_char = 8'h0a;
        endcase
    endfunction

    assign uart_tx = (bits_left == 0) ? 1'b1 : tx_shift[0];
    always @(posedge bus_clk or negedge resetn) begin
        if (!resetn) begin
            report_wait <= 26'd0;
            char_index <= 5'd0;
            tx_shift <= 10'h3ff;
            bits_left <= 4'd0;
            baud_wait <= 10'd0;
        end else begin
            if (report_wait != 0)
                report_wait <= report_wait - 1'b1;
            if (bits_left != 0) begin
                if (baud_wait == 0) begin
                    baud_wait <= UART_DIV - 1;
                    tx_shift <= {1'b1, tx_shift[9:1]};
                    bits_left <= bits_left - 1'b1;
                end else begin
                    baud_wait <= baud_wait - 1'b1;
                end
            end else if ((cpu_started || FORCE_UART != 0) && report_wait == 0) begin
                tx_shift <= {1'b1, report_char(char_index, rom_addr_seen,
                                               rom_seen, cpu_started), 1'b0};
                bits_left <= 4'd10;
                baud_wait <= UART_DIV - 1;
                if (char_index == REPORT_LAST_INDEX) begin
                    char_index <= 5'd0;
                    report_wait <= 26'h3ffffff;
                end else begin
                    char_index <= char_index + 1'b1;
                end
            end
        end
    end
endmodule
