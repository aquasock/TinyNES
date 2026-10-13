// SPDX-License-Identifier: MIT
// Fabric registers in the AE350's uncached EXTS window, and the FPGA UART
// (8N1) they drive. Offsets from 0xe8000000:
//   0x00  write: byte to transmit (bits 7:0). The transfer waits while the
//         holding register is full.
//   0x04  read: status; bit 0 a byte may be written to 0x00, bit 1 the
//         transmitter is also idle with nothing left to send (link text
//         included), bit 2 a received byte is waiting, bit 3
//         a byte arrived while the receive buffer was full and was lost, bit
//         4 a byte arrived without its stop bit and was dropped.
//         write: a 1 in bit 3 or 4 clears that flag.
//   0x08  read: ID_VALUE.
//   0x0c  read and write: 32-bit scratch register.
//   0x10  read: the oldest received byte in bits 7:0 with bit 8 set, which
//         removes it from the buffer, or zero when none is waiting.
//   0x14  read and write: CTRL, bit 0 link mode (0 after reset). A write
//         completes once everything written before it has left the pin,
//         buffered link text included, which it sends at once.
//   0x18  read: LINK, desk_link's status (link_status).
// All 32 address bits are decoded; any other address, or a write to a
// read-only register or a read of 0x00, gets an AHB ERROR response.
//
// A bit lasts UART_DIV2 / 2 bus clocks. When UART_DIV2 is odd, bits
// alternate between the two neighbouring whole counts, so the rate is exact
// on average: 75 MHz with UART_DIV2 = 75 gives 2,000,000 baud. The receiver
// buffers RX_DEPTH bytes, samples each bit at its middle and drops a start
// bit that is gone by then.
//
// Until the CPU writes its first byte or CTRL, fabric may transmit through
// the fallback input instead (fb_valid, fb_data, fb_ready); after it, only
// the CPU does. cpu_owns reports which.
//
// In loader mode, the mode after reset, the CPU's bytes go to the pin and
// received bytes to the receive buffer. In link mode (desk_link.sv) the
// CPU's bytes go to the link as text (txt_valid, txt_data, txt_ready),
// received bytes go to the link (rx_link_valid, rx_link_data) instead of
// the buffer, and the link's frames go to the pin (ln_valid, ln_data,
// ln_ready). link_idle says the link has nothing buffered or in flight, and
// link_flush asks it to send its text while a CTRL write waits.
module exts_uart #(
    parameter integer UART_DIV2 = 75,
    parameter integer RX_DEPTH = 512,
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
    input  wire        hready_in, // the EXTS port's HREADY
    output reg  [31:0] hrdata,
    output reg         hready,
    output reg         hresp,
    input  wire        fb_valid,
    input  wire [7:0]  fb_data,
    output wire        fb_ready,
    output reg         cpu_owns,
    output reg         link,
    output reg         rx_link_valid,
    output reg  [7:0]  rx_link_data,
    output wire        txt_valid,
    output wire [7:0]  txt_data,
    input  wire        txt_ready,
    input  wire        ln_valid,
    input  wire [7:0]  ln_data,
    output wire        ln_ready,
    input  wire        link_idle,
    output wire        link_flush,
    input  wire [31:0] link_status,
    output wire        tx,
    input  wire        rx
);
    localparam integer DIV_LO = UART_DIV2 / 2;
    localparam integer DIV_HI = UART_DIV2 - DIV_LO;
    localparam integer RX_AW = $clog2(RX_DEPTH);

    localparam [31:0] BASE = 32'he8000000;
    localparam [2:0] REG_TX = 3'd0;
    localparam [2:0] REG_STATUS = 3'd1;
    localparam [2:0] REG_ID = 3'd2;
    localparam [2:0] REG_SCRATCH = 3'd3;
    localparam [2:0] REG_RX = 3'd4;
    localparam [2:0] REG_CTRL = 3'd5;
    localparam [2:0] REG_LINK = 3'd6;
    localparam [2:0] REG_NONE = 3'd7;

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
    reg tx_long = 1'b0;
    wire tx_idle = bits_left == 4'd0;

    // Receiver: a two-flop synchroniser, then the bit sampler.
    localparam [1:0] RX_IDLE = 2'd0;
    localparam [1:0] RX_START = 2'd1;
    localparam [1:0] RX_DATA = 2'd2;
    localparam [1:0] RX_STOP = 2'd3;
    reg rx_meta = 1'b1;
    reg rx_line = 1'b1;
    reg rx_prev = 1'b1;
    reg [1:0] rx_state = RX_IDLE;
    reg [15:0] rx_wait = 16'd0;
    reg rx_long = 1'b0;
    reg [2:0] rx_bit = 3'd0;
    reg [7:0] rx_shift = 8'd0;
    reg rx_overrun = 1'b0;
    reg rx_frame_error = 1'b0;

    // Receive buffer. A byte written at one edge is counted at the next, by
    // when rx_head has read it, so a byte is never offered before it is
    // there to read.
    reg [7:0] rx_mem [0:RX_DEPTH-1];
    reg [RX_AW-1:0] rx_wr = {RX_AW{1'b0}};
    reg [RX_AW-1:0] rx_rd = {RX_AW{1'b0}};
    reg [RX_AW:0] rx_count = {(RX_AW+1){1'b0}};
    reg rx_push = 1'b0;
    reg rx_pushed = 1'b0;
    reg rx_pop = 1'b0;
    reg [7:0] rx_head = 8'd0;
    wire rx_waiting = rx_count != 0;

    always @(posedge clk) begin
        if (rx_push)
            rx_mem[rx_wr] <= rx_shift;
        rx_head <= rx_mem[rx_rd];
    end

    assign tx = tx_idle ? 1'b1 : tx_shift[0];
    assign fb_ready = !cpu_owns && !hold_full;
    // A CPU byte waiting in its data phase: to the link in link mode, else
    // to the holding register, which the link's frames then wait for.
    wire cpu_tx = pending && target == REG_TX && DROP_CPU_TX == 0;
    assign txt_valid = cpu_tx && link;
    assign txt_data = hwdata[7:0];
    assign ln_ready = !hold_full && !(cpu_tx && !link);
    assign link_flush = pending && target == REG_CTRL;
    wire all_sent = tx_idle && !hold_full && link_idle;

    function [2:0] decode(input [31:0] addr, input is_write);
        if (addr == BASE + 32'h0 && is_write)
            decode = REG_TX;
        else if (addr == BASE + 32'h4)
            decode = REG_STATUS;
        else if (addr == BASE + 32'h8 && !is_write)
            decode = REG_ID;
        else if (addr == BASE + 32'hc)
            decode = REG_SCRATCH;
        else if (addr == BASE + 32'h10 && !is_write)
            decode = REG_RX;
        else if (addr == BASE + 32'h14)
            decode = REG_CTRL;
        else if (addr == BASE + 32'h18 && !is_write)
            decode = REG_LINK;
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
            link <= 1'b0;
            rx_link_valid <= 1'b0;
            rx_link_data <= 8'd0;
            tx_shift <= 10'h3ff;
            bits_left <= 4'd0;
            baud_wait <= 16'd0;
            tx_long <= 1'b0;
            rx_meta <= 1'b1;
            rx_line <= 1'b1;
            rx_prev <= 1'b1;
            rx_state <= RX_IDLE;
            rx_wait <= 16'd0;
            rx_long <= 1'b0;
            rx_bit <= 3'd0;
            rx_shift <= 8'd0;
            rx_overrun <= 1'b0;
            rx_frame_error <= 1'b0;
            rx_wr <= {RX_AW{1'b0}};
            rx_rd <= {RX_AW{1'b0}};
            rx_count <= {(RX_AW+1){1'b0}};
            rx_push <= 1'b0;
            rx_pushed <= 1'b0;
            rx_pop <= 1'b0;
        end else begin
            // Transmitter: shift a byte out, then take the next one.
            if (!tx_idle) begin
                if (baud_wait == 0) begin
                    baud_wait <= (tx_long ? DIV_HI : DIV_LO) - 1;
                    tx_long <= !tx_long;
                    tx_shift <= {1'b1, tx_shift[9:1]};
                    bits_left <= bits_left - 1'b1;
                end else begin
                    baud_wait <= baud_wait - 1'b1;
                end
            end else if (hold_full) begin
                tx_shift <= {1'b1, hold, 1'b0};
                bits_left <= 4'd10;
                baud_wait <= (tx_long ? DIV_HI : DIV_LO) - 1;
                tx_long <= !tx_long;
                hold_full <= 1'b0;
            end

            // Receiver.
            rx_meta <= rx;
            rx_line <= rx_meta;
            rx_prev <= rx_line;
            rx_push <= 1'b0;
            rx_link_valid <= 1'b0;
            if (rx_wait != 0)
                rx_wait <= rx_wait - 1'b1;
            case (rx_state)
                RX_IDLE:
                    if (rx_prev && !rx_line) begin
                        rx_wait <= UART_DIV2 / 4 - 1;
                        rx_state <= RX_START;
                    end
                RX_START:
                    if (rx_wait == 0) begin
                        if (rx_line) begin
                            rx_state <= RX_IDLE;
                        end else begin
                            rx_wait <= (rx_long ? DIV_HI : DIV_LO) - 1;
                            rx_long <= !rx_long;
                            rx_bit <= 3'd0;
                            rx_state <= RX_DATA;
                        end
                    end
                RX_DATA:
                    if (rx_wait == 0) begin
                        rx_shift <= {rx_line, rx_shift[7:1]};
                        rx_wait <= (rx_long ? DIV_HI : DIV_LO) - 1;
                        rx_long <= !rx_long;
                        rx_bit <= rx_bit + 1'b1;
                        if (rx_bit == 3'd7)
                            rx_state <= RX_STOP;
                    end
                RX_STOP:
                    if (rx_wait == 0) begin
                        rx_state <= RX_IDLE;
                        if (!rx_line) begin
                            rx_frame_error <= 1'b1;
                        end else if (link) begin
                            rx_link_valid <= 1'b1;
                            rx_link_data <= rx_shift;
                        end else if (rx_count + rx_pushed == RX_DEPTH)
                            rx_overrun <= 1'b1;
                        else begin
                            rx_push <= 1'b1;
                        end
                    end
            endcase
            if (rx_push)
                rx_wr <= rx_wr + 1'b1;
            rx_pushed <= rx_push;
            rx_count <= rx_count + rx_pushed - rx_pop;
            rx_pop <= 1'b0;

            if (fb_valid && fb_ready) begin
                hold <= fb_data;
                hold_full <= 1'b1;
            end
            if (ln_valid && ln_ready) begin
                hold <= ln_data;
                hold_full <= 1'b1;
            end

            // AHB slave.
            error_second <= 1'b0;
            if (hready) begin
                hresp <= 1'b0;
                if (hready_in && hsel && htrans[1]) begin
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
                        end else if (link) begin
                            if (txt_ready) begin
                                cpu_owns <= 1'b1;
                                pending <= 1'b0;
                                hready <= 1'b1;
                            end
                        end else if (!hold_full) begin
                            hold <= hwdata[7:0];
                            hold_full <= 1'b1;
                            cpu_owns <= 1'b1;
                            pending <= 1'b0;
                            hready <= 1'b1;
                        end
                    REG_STATUS: begin
                        if (write) begin
                            if (hwdata[3])
                                rx_overrun <= 1'b0;
                            if (hwdata[4])
                                rx_frame_error <= 1'b0;
                        end
                        hrdata <= {27'd0, rx_frame_error, rx_overrun, rx_waiting,
                                   all_sent, link ? txt_ready : !hold_full};
                        pending <= 1'b0;
                        hready <= 1'b1;
                    end
                    REG_RX: begin
                        if (rx_waiting) begin
                            hrdata <= {23'd0, 1'b1, rx_head};
                            rx_rd <= rx_rd + 1'b1;
                            rx_pop <= 1'b1;
                        end else begin
                            hrdata <= 32'd0;
                        end
                        pending <= 1'b0;
                        hready <= 1'b1;
                    end
                    REG_CTRL:
                        if (!write) begin
                            hrdata <= {31'd0, link};
                            pending <= 1'b0;
                            hready <= 1'b1;
                        end else if (all_sent) begin
                            link <= hwdata[0];
                            cpu_owns <= 1'b1;
                            hrdata <= 32'd0;
                            pending <= 1'b0;
                            hready <= 1'b1;
                        end
                    REG_LINK: begin
                        hrdata <= link_status;
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
