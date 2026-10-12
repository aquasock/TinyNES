// SPDX-License-Identifier: MIT
// First TinyNES hardware gate: the AE350 writes a sequence of data patterns
// over AHB; fabric checks every address and data bit and reports the result
// periodically on the FPGA UART at 115200 8N1.
// The program then keeps storing its mcycle count, which fabric pairs with
// a count of the 50 MHz board oscillator to measure the core clock.
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

    // The board oscillator is independent of the AE350 PLL. Its count
    // crosses into the bus domain in Gray code, so every synchronized value
    // is one the counter actually held.
    reg [31:0] ref_count_sys = 32'd0;
    reg [31:0] ref_gray_sys = 32'd0;
    reg [31:0] ref_gray_meta = 32'd0;
    reg [31:0] ref_gray_sync = 32'd0;
    reg [31:0] ref_count_bus = 32'd0;
    integer ref_bit;
    always @(posedge sys_clk) begin
        ref_count_sys <= ref_count_sys + 1'b1;
        ref_gray_sys <= ref_count_sys ^ (ref_count_sys >> 1);
    end
    always @(posedge bus_clk) begin
        ref_gray_meta <= ref_gray_sys;
        ref_gray_sync <= ref_gray_meta;
        for (ref_bit = 0; ref_bit < 32; ref_bit = ref_bit + 1)
            ref_count_bus[ref_bit] <= ^(ref_gray_sync >> ref_bit);
    end

    // Reset vector 0x80000000. The program stores 0xa5a5a5a5, 0x5a5a5a5a,
    // 0xffffffff, 0 and then a walking one to 0xe8000000, so each EXTS_HWDATA
    // bit is seen at 0 and 1, alone and against its neighbours. It then loops
    // storing mcycle to 0xe8000004. These are RV32I/Zicsr words.
    wire [31:0] rom_addr;
    wire [1:0] rom_trans;
    reg rom_addr_seen = 1'b0;
    reg rom_seen = 1'b0;
    reg [31:0] rom_data;
    always @* begin
        case (rom_addr[6:2])
            5'd0:  rom_data = 32'he80002b7; // lui t0, 0xe8000
            5'd1:  rom_data = 32'ha5a5a337; // lui t1, 0xa5a5a
            5'd2:  rom_data = 32'h5a530313; // addi t1, t1, 0x5a5
            5'd3:  rom_data = 32'h0062a023; // sw t1, 0(t0)
            5'd4:  rom_data = 32'hfff34313; // xori t1, t1, -1
            5'd5:  rom_data = 32'h0062a023; // sw t1, 0(t0)
            5'd6:  rom_data = 32'hfff00313; // addi t1, zero, -1
            5'd7:  rom_data = 32'h0062a023; // sw t1, 0(t0)
            5'd8:  rom_data = 32'h0002a023; // sw zero, 0(t0)
            5'd9:  rom_data = 32'h00100313; // addi t1, zero, 1
            5'd10: rom_data = 32'h0062a023; // sw t1, 0(t0)
            5'd11: rom_data = 32'h00131313; // slli t1, t1, 1
            5'd12: rom_data = 32'hfe031ce3; // bne t1, zero, -8
            5'd13: rom_data = 32'hb0002373; // csrr t1, mcycle
            5'd14: rom_data = 32'h0062a223; // sw t1, 4(t0)
            5'd15: rom_data = 32'hff9ff06f; // jal zero, -8
            default: rom_data = 32'h0000006f; // jal zero, 0
        endcase
    end

    wire [31:0] exts_addr;
    wire [31:0] exts_wdata;
    wire exts_sel;
    wire [1:0] exts_trans;
    wire exts_write;
    localparam [31:0] STATUS_ADDR = 32'he8000000;
    localparam [31:0] CYCLE_ADDR = 32'he8000004;
    localparam [5:0] PATTERN_COUNT = 6'd36;
    reg write_pending = 1'b0;
    reg cycle_pending = 1'b0;
    reg other_pending = 1'b0;
    reg [31:0] pending_addr = 32'd0;
    reg [5:0] pattern_index = 6'd0;
    // cpu_started: every pattern arrived intact. bus_error: the first
    // mismatched or unexpected write, with its pattern index, address and data.
    reg cpu_started = 1'b0;
    reg bus_error = 1'b0;
    reg [5:0] error_index = 6'd0;
    reg [31:0] error_addr = 32'd0;
    reg [31:0] error_data = 32'd0;
    reg [31:0] cpu_cycles = 32'd0;
    reg [31:0] ref_cycles = 32'd0;

    function [31:0] expected_pattern(input [5:0] index);
        case (index)
            6'd0: expected_pattern = 32'ha5a5a5a5;
            6'd1: expected_pattern = 32'h5a5a5a5a;
            6'd2: expected_pattern = 32'hffffffff;
            6'd3: expected_pattern = 32'h00000000;
            default: expected_pattern = 32'd1 << (index - 6'd4);
        endcase
    endfunction

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

    wire exts_write_start = exts_sel && exts_trans[1] && exts_write;
    wire status_bad = write_pending &&
                      (pattern_index == PATTERN_COUNT ||
                       exts_wdata != expected_pattern(pattern_index));

    // AHB-Lite places write data one bus cycle after address/control. All
    // 32 address bits are decoded; any other write address is an error.
    always @(posedge bus_clk or negedge resetn) begin
        if (!resetn) begin
            write_pending <= 1'b0;
            cycle_pending <= 1'b0;
            other_pending <= 1'b0;
            pending_addr <= 32'd0;
            pattern_index <= 6'd0;
            cpu_started <= 1'b0;
            bus_error <= 1'b0;
            error_index <= 6'd0;
            error_addr <= 32'd0;
            error_data <= 32'd0;
            cpu_cycles <= 32'd0;
            ref_cycles <= 32'd0;
        end else begin
            if ((status_bad || other_pending) && !bus_error) begin
                bus_error <= 1'b1;
                error_index <= pattern_index;
                error_addr <= pending_addr;
                error_data <= exts_wdata;
            end else if (write_pending && !bus_error) begin
                pattern_index <= pattern_index + 1'b1;
                if (pattern_index == PATTERN_COUNT - 1'b1)
                    cpu_started <= 1'b1;
            end
            // Pair each mcycle value with the oscillator count taken in its
            // data phase.
            if (cycle_pending) begin
                cpu_cycles <= exts_wdata;
                ref_cycles <= ref_count_bus;
            end
            write_pending <= exts_write_start && exts_addr == STATUS_ADDR;
            cycle_pending <= exts_write_start && exts_addr == CYCLE_ADDR;
            other_pending <= exts_write_start && exts_addr != STATUS_ADDR &&
                             exts_addr != CYCLE_ADDR;
            pending_addr <= exts_addr;
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
    reg [25:0] report_wait = 26'd0;
    reg [5:0] char_index = 6'd0;
    // The normal line is chosen at its first character and held to its end.
    reg report_bad = 1'b0;
    wire line_bad = (char_index == 6'd0) ? bus_error : report_bad;
    wire [5:0] report_last_index = (FORCE_UART == 2) ? 6'd45 :
                                   (FORCE_UART == 1 || !line_bad) ? 6'd17 :
                                   6'd31;
    // The trace line freezes one cycle pair before printing either field.
    reg [31:0] report_cycles = 32'd0;
    reg [31:0] report_ref = 32'd0;
    reg [9:0] tx_shift = 10'h3ff;
    reg [3:0] bits_left = 4'd0;
    reg [9:0] baud_wait = 10'd0;

    function [7:0] hex_char(input [3:0] value);
        hex_char = (value < 4'd10) ? ("0" + value) : ("a" + value - 4'd10);
    endfunction

    function [7:0] report_char(
        input [5:0] index,
        input rom_addr_seen_in,
        input rom_seen_in,
        input cpu_started_in,
        input bus_error_in,
        input line_bad_in,
        input [5:0] error_index_in,
        input [31:0] error_addr_in,
        input [31:0] error_data_in,
        input [31:0] cycles_in,
        input [31:0] ref_in
    );
        if (FORCE_UART == 2) begin
            if (index >= 6'd23 && index <= 6'd30)
                report_char = hex_char(cycles_in >> (4 * (6'd30 - index)));
            else if (index >= 6'd36 && index <= 6'd43)
                report_char = hex_char(ref_in >> (4 * (6'd43 - index)));
            else case (index)
                6'd0: report_char = "A";
                6'd1: report_char = "D";
                6'd2: report_char = "D";
                6'd3: report_char = "R";
                6'd4: report_char = "=";
                6'd5: report_char = rom_addr_seen_in ? "1" : "0";
                6'd6: report_char = " ";
                6'd7: report_char = "R";
                6'd8: report_char = "O";
                6'd9: report_char = "M";
                6'd10: report_char = "=";
                6'd11: report_char = rom_seen_in ? "1" : "0";
                6'd12: report_char = " ";
                6'd13: report_char = "A";
                6'd14: report_char = "H";
                6'd15: report_char = "B";
                6'd16: report_char = "=";
                6'd17: report_char = bus_error_in ? "E" :
                                     cpu_started_in ? "1" : "0";
                6'd18: report_char = " ";
                6'd19: report_char = "C";
                6'd20: report_char = "Y";
                6'd21: report_char = "C";
                6'd22: report_char = "=";
                6'd31: report_char = " ";
                6'd32: report_char = "R";
                6'd33: report_char = "E";
                6'd34: report_char = "F";
                6'd35: report_char = "=";
                6'd44: report_char = 8'h0d;
                default: report_char = 8'h0a;
            endcase
        end else if (FORCE_UART == 1) begin
            case (index)
                6'd0:  report_char = "U";
                6'd1:  report_char = "A";
                6'd2:  report_char = "R";
                6'd3:  report_char = "T";
                6'd4:  report_char = " ";
                6'd5:  report_char = "D";
                6'd6:  report_char = "I";
                6'd7:  report_char = "A";
                6'd8:  report_char = "G";
                6'd9:  report_char = "N";
                6'd10: report_char = "O";
                6'd11: report_char = "S";
                6'd12: report_char = "T";
                6'd13: report_char = "I";
                6'd14: report_char = "C";
                6'd15: report_char = "!";
                6'd16: report_char = 8'h0d;
                default: report_char = 8'h0a;
            endcase
        end else if (line_bad_in) begin
            if (index == 6'd6)
                report_char = hex_char({2'b00, error_index_in[5:4]});
            else if (index == 6'd7)
                report_char = hex_char(error_index_in[3:0]);
            else if (index >= 6'd11 && index <= 6'd18)
                report_char = hex_char(error_addr_in >> (4 * (6'd18 - index)));
            else if (index >= 6'd22 && index <= 6'd29)
                report_char = hex_char(error_data_in >> (4 * (6'd29 - index)));
            else case (index)
                6'd0:  report_char = "B";
                6'd1:  report_char = "A";
                6'd2:  report_char = "D";
                6'd4:  report_char = "N";
                6'd5:  report_char = "=";
                6'd9:  report_char = "A";
                6'd10: report_char = "=";
                6'd20: report_char = "D";
                6'd21: report_char = "=";
                6'd30: report_char = 8'h0d;
                6'd31: report_char = 8'h0a;
                default: report_char = " ";
            endcase
        end else case (index)
            6'd0:  report_char = "T";
            6'd1:  report_char = "i";
            6'd2:  report_char = "n";
            6'd3:  report_char = "y";
            6'd4:  report_char = "N";
            6'd5:  report_char = "E";
            6'd6:  report_char = "S";
            6'd7:  report_char = " ";
            6'd8:  report_char = "A";
            6'd9:  report_char = "E";
            6'd10: report_char = "3";
            6'd11: report_char = "5";
            6'd12: report_char = "0";
            6'd13: report_char = " ";
            6'd14: report_char = "O";
            6'd15: report_char = "K";
            6'd16: report_char = 8'h0d;
            default: report_char = 8'h0a;
        endcase
    endfunction

    assign uart_tx = (bits_left == 0) ? 1'b1 : tx_shift[0];
    always @(posedge bus_clk or negedge resetn) begin
        if (!resetn) begin
            report_wait <= 26'd0;
            char_index <= 6'd0;
            report_bad <= 1'b0;
            report_cycles <= 32'd0;
            report_ref <= 32'd0;
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
            end else if ((cpu_started || bus_error || FORCE_UART != 0) &&
                         report_wait == 0) begin
                tx_shift <= {1'b1, report_char(char_index, rom_addr_seen,
                                               rom_seen, cpu_started,
                                               bus_error, line_bad,
                                               error_index, error_addr,
                                               error_data, report_cycles,
                                               report_ref),
                             1'b0};
                report_bad <= line_bad;
                if (char_index == 6'd18) begin
                    report_cycles <= cpu_cycles;
                    report_ref <= ref_cycles;
                end
                bits_left <= 4'd10;
                baud_wait <= UART_DIV - 1;
                if (char_index == report_last_index) begin
                    char_index <= 6'd0;
                    report_wait <= 26'h3ffffff;
                end else begin
                    char_index <= char_index + 1'b1;
                end
            end
        end
    end
endmodule
