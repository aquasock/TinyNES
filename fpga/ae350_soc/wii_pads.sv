// SPDX-License-Identifier: MIT
// Four Wii extension controllers (Classic Controller, Classic Controller Pro),
// each on its own I2C bus, polled by fabric so the CPU only reads registers.
// Each bus has its own master, open-drain on two pins (it only pulls low, and
// a pull-up raises the line), which on its own:
//
//   wakes the controller unencrypted: writes 0x55 to register 0xF0, waits
//   10 ms, writes 0x00 to 0xFB and waits 20 ms;
//   reads the 6-byte identity at 0xFA;
//   then, about once a millisecond, sets the register pointer to 0x00, waits
//   CONVERT_US and reads the 6 data bytes.
//
// The controller is at I2C address 0x52. A byte it does not acknowledge, or a
// clock line held low for 1 ms, marks the controller absent; the master waits
// 100 ms and wakes it again, so controllers may be plugged in at any time.
// SCL is released and the master waits until it reads high before timing the
// high half of the bit, so a slow pull-up or a controller stretching the
// clock only slows the bus down.
//
// Registers, offsets from the unit's base (0xe8040000), 32-bit reads only
// except CTRL; any other access gets an AHB ERROR:
//   0x000  ID, read: ID_VALUE.
//   0x004  CTRL, read and write: bits 11:0 the quarter bit time in bus clocks
//          (75 MHz / (4 x 187) is 100 kHz, the reset value); a write restarts
//          every master.
//   0x010 + 0x10n, controller n (0 to 3):
//     +0x0  STATUS: bit 0 present (woken and answering), bit 1 its identity
//           is a Classic Controller's, bits 23:8 reads completed, bits 31:24
//           failed transfers (both wrap).
//     +0x4  DATA: data bytes 0 to 3, byte 0 in bits 7:0. Reading it also
//           takes bytes 4 and 5 for DATA2, so the two reads are one sample.
//     +0x8  DATA2: data bytes 4 and 5 in bits 15:0, as taken by the last
//           read of DATA; identity bytes 4 and 5 in bits 31:16.
//     +0xc  IDENT: identity bytes 0 to 3, byte 0 in bits 7:0.
// Every transfer completes with no wait state.
//
// pad0_held gives controller 0's buttons to fabric (desk_link.sv): report
// bytes 4 and 5, byte 4 in bits 7:0, active high, or 0 unless the controller
// is present and a Classic Controller.
module wii_pads #(
    parameter [31:0] ID_VALUE = 32'h544e5031, // "TNP1"
    parameter integer US_CLOCKS = 75,         // bus clocks per microsecond
    parameter [11:0] QUARTER_RESET = 12'd187,
    parameter integer CONVERT_US = 200
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

    input  wire [3:0]  scl_in,
    input  wire [3:0]  sda_in,
    output wire [3:0]  scl_low,  // pull the line low
    output wire [3:0]  sda_low,
    output reg  [15:0] pad0_held
);
    reg [11:0] quarter = QUARTER_RESET;
    reg restart = 1'b0;

    wire [7:0] status_bits [0:3];
    wire [15:0] reads [0:3];
    wire [7:0] fails [0:3];
    wire [47:0] data [0:3];
    wire [47:0] ident [0:3];

    genvar n;
    generate
        for (n = 0; n < 4; n = n + 1) begin : g_pad
            wii_pad_master #(.US_CLOCKS(US_CLOCKS), .CONVERT_US(CONVERT_US)) master (
                .clk(clk), .resetn(resetn), .restart(restart), .quarter(quarter),
                .scl_in(scl_in[n]), .sda_in(sda_in[n]),
                .scl_low(scl_low[n]), .sda_low(sda_low[n]),
                .present(status_bits[n][0]), .classic(status_bits[n][1]),
                .reads(reads[n]), .fails(fails[n]), .data(data[n]), .ident(ident[n])
            );
            assign status_bits[n][7:2] = 6'd0;
        end
    endgenerate

    always @(posedge clk or negedge resetn)
        if (!resetn)
            pad0_held <= 16'd0;
        else
            pad0_held <= status_bits[0][1:0] == 2'b11 ? ~data[0][47:32] : 16'd0;

    // DATA2's data half, taken when DATA is read.
    reg [15:0] taken [0:3];
    reg ctrl_write = 1'b0;

    wire accept = hready_in && hsel && htrans[1];
    wire word = hsize == 3'd2 && haddr[1:0] == 2'b00;
    wire is_id = haddr[11:2] == 10'd0;
    wire is_ctrl = haddr[11:2] == 10'd1;
    wire is_pad = haddr[11:6] == 6'd0 && haddr[5:4] != 2'd0;
    wire [1:0] pad = haddr[5:4] - 2'd1;
    wire is_pad3 = haddr[11:4] == 8'h04;
    wire ok = word && (hwrite ? is_ctrl : (is_id || is_ctrl || is_pad || is_pad3));
    wire [1:0] pad_n = is_pad3 ? 2'd3 : pad;
    reg err2 = 1'b0;

    integer k;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            quarter <= QUARTER_RESET;
            restart <= 1'b0;
            ctrl_write <= 1'b0;
            err2 <= 1'b0;
            hrdata <= 32'd0;
            hready <= 1'b1;
            hresp <= 1'b0;
            for (k = 0; k < 4; k = k + 1)
                taken[k] <= 16'd0;
        end else begin
            ctrl_write <= accept && ok && hwrite;
            restart <= ctrl_write;
            if (ctrl_write && hwdata[11:0] != 12'd0)
                quarter <= hwdata[11:0];
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
                end else if (accept && hwrite) begin
                    // CTRL, its data a cycle later: see below.
                end else if (accept) begin
                    if (is_id)
                        hrdata <= ID_VALUE;
                    else if (is_ctrl)
                        hrdata <= {20'd0, ctrl_write && hwdata[11:0] != 12'd0 ?
                                   hwdata[11:0] : quarter};
                    else
                        case (haddr[3:2])
                            2'd0: hrdata <= {fails[pad_n], reads[pad_n], status_bits[pad_n]};
                            2'd1: begin
                                hrdata <= data[pad_n][31:0];
                                taken[pad_n] <= data[pad_n][47:32];
                            end
                            2'd2: hrdata <= {ident[pad_n][47:32], taken[pad_n]};
                            default: hrdata <= ident[pad_n][31:0];
                        endcase
                end
            end
        end
    end

endmodule

// One I2C bus and the controller on it.
module wii_pad_master #(
    parameter integer US_CLOCKS = 75,
    parameter integer CONVERT_US = 200
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire        restart,
    input  wire [11:0] quarter,
    input  wire        scl_in,
    input  wire        sda_in,
    output reg         scl_low,
    output reg         sda_low,
    output reg         present,
    output reg         classic,
    output reg  [15:0] reads,
    output reg  [7:0]  fails,
    output reg  [47:0] data,
    output reg  [47:0] ident
);
    localparam [7:0] ADDR_W = 8'hA4, ADDR_R = 8'hA5; // 0x52 shifted, R/W bit

    // Synchronised line levels.
    reg [1:0] scl_s = 2'b11, sda_s = 2'b11;
    wire scl = scl_s[1], sda = sda_s[1];

    // A microsecond tick for the sequencer's waits.
    reg [7:0] us_div = 8'd0;
    wire us_tick = us_div == US_CLOCKS - 1;

    // ---------------------------------------------------- transfer layer --
    // go starts one transfer: START, the address byte (read when rd), then
    // len bytes written from wbytes or 6 bytes read into rbytes, then STOP.
    // done pulses at the end, with nack set if a byte was not acknowledged
    // or SCL stayed low for 1 ms.
    localparam [3:0] T_IDLE = 4'd0, T_START0 = 4'd1, T_START1 = 4'd2, T_START2 = 4'd3,
                     T_BIT0 = 4'd4, T_BIT1 = 4'd5, T_BIT2 = 4'd6, T_BIT3 = 4'd7,
                     T_STOP0 = 4'd8, T_STOP1 = 4'd9, T_STOP2 = 4'd10, T_DONE = 4'd11;
    reg [3:0] t = T_IDLE;
    reg go = 1'b0, rd = 1'b0;
    reg [1:0] len = 2'd0;          // bytes written after the address
    reg [15:0] wbytes = 16'd0;     // first in 15:8
    reg [47:0] rbytes = 48'd0;
    reg done = 1'b0, nack = 1'b0;
    reg [11:0] qcount = 12'd0;
    reg [9:0] stretch_us = 10'd0;
    reg [7:0] shift = 8'd0;
    reg [3:0] bitn = 4'd0;         // 8 = the acknowledge bit
    reg [2:0] byten = 3'd0;        // 0 = address
    wire last_byte = rd ? byten == 3'd6 : byten == {1'b0, len};
    wire q_end = qcount == quarter;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            t <= T_IDLE;
            scl_low <= 1'b0;
            sda_low <= 1'b0;
            done <= 1'b0;
            nack <= 1'b0;
            qcount <= 12'd0;
            stretch_us <= 10'd0;
            scl_s <= 2'b11;
            sda_s <= 2'b11;
            us_div <= 8'd0;
        end else begin
            scl_s <= {scl_s[0], scl_in};
            sda_s <= {sda_s[0], sda_in};
            us_div <= us_tick ? 8'd0 : us_div + 1'b1;
            done <= 1'b0;
            qcount <= q_end ? 12'd0 : qcount + 1'b1;
            if (restart) begin
                t <= T_IDLE;
                scl_low <= 1'b0;
                sda_low <= 1'b0;
            end else case (t)
                T_IDLE: begin
                    qcount <= 12'd0;
                    if (go) begin
                        nack <= 1'b0;
                        byten <= 3'd0;
                        bitn <= 4'd0;
                        shift <= rd ? ADDR_R : ADDR_W;
                        scl_low <= 1'b0;
                        sda_low <= 1'b0;
                        stretch_us <= 10'd0;
                        t <= T_START0;
                    end
                end
                // Both lines released and SCL high, then SDA falls, then SCL.
                T_START0:
                    if (!scl) begin
                        qcount <= 12'd0;
                        if (us_tick) stretch_us <= stretch_us + 1'b1;
                        if (stretch_us == 10'd1000) begin
                            nack <= 1'b1;
                            t <= T_DONE;
                        end
                    end else if (q_end) begin
                        sda_low <= 1'b1;
                        t <= T_START1;
                    end
                T_START1:
                    if (q_end) begin
                        scl_low <= 1'b1;
                        t <= T_START2;
                    end
                T_START2:
                    if (q_end)
                        t <= T_BIT0;
                // A bit: SCL low while SDA is set, SCL released, sampled in
                // the high half, SCL pulled low again.
                T_BIT0: begin
                    if (bitn == 4'd8)
                        // Acknowledge: we drive it after a read byte that is
                        // not the last; otherwise SDA is the controller's.
                        sda_low <= rd && byten != 3'd0 && !last_byte;
                    else if (rd && byten != 3'd0)
                        sda_low <= 1'b0;
                    else
                        sda_low <= !shift[7];
                    if (q_end) begin
                        scl_low <= 1'b0;
                        stretch_us <= 10'd0;
                        t <= T_BIT1;
                    end
                end
                T_BIT1:
                    // Wait for SCL to read high: a slow rise or stretching.
                    if (!scl) begin
                        qcount <= 12'd0;
                        if (us_tick) stretch_us <= stretch_us + 1'b1;
                        if (stretch_us == 10'd1000) begin
                            nack <= 1'b1;
                            t <= T_STOP0;
                        end
                    end else if (q_end) begin
                        t <= T_BIT2;
                    end
                T_BIT2:
                    if (q_end) begin
                        if (bitn == 4'd8) begin
                            if (!(rd && byten != 3'd0) && sda)
                                nack <= 1'b1;
                        end else begin
                            shift <= {shift[6:0], sda};
                        end
                        scl_low <= 1'b1;
                        t <= T_BIT3;
                    end
                T_BIT3:
                    if (q_end) begin
                        if (bitn != 4'd8) begin
                            bitn <= bitn + 1'b1;
                            t <= T_BIT0;
                        end else begin
                            bitn <= 4'd0;
                            if (rd && byten != 3'd0)
                                rbytes <= {shift, rbytes[47:8]};
                            if (nack || last_byte) begin
                                sda_low <= 1'b1;
                                t <= T_STOP0;
                            end else begin
                                byten <= byten + 1'b1;
                                shift <= rd ? 8'h00 : (byten == 3'd0 ? wbytes[15:8] : wbytes[7:0]);
                                t <= T_BIT0;
                            end
                        end
                    end
                // SDA low with SCL low, SCL released, then SDA released.
                T_STOP0: begin
                    sda_low <= 1'b1;
                    if (q_end) begin
                        scl_low <= 1'b0;
                        stretch_us <= 10'd0;
                        t <= T_STOP1;
                    end
                end
                T_STOP1:
                    if (!scl) begin
                        qcount <= 12'd0;
                        if (us_tick) stretch_us <= stretch_us + 1'b1;
                        if (stretch_us == 10'd1000) begin
                            nack <= 1'b1;
                            sda_low <= 1'b0;
                            t <= T_DONE;
                        end
                    end else if (q_end) begin
                        sda_low <= 1'b0;
                        t <= T_STOP2;
                    end
                T_STOP2:
                    if (q_end)
                        t <= T_DONE;
                T_DONE: begin
                    scl_low <= 1'b0;
                    sda_low <= 1'b0;
                    done <= 1'b1;
                    t <= T_IDLE;
                end
                default: t <= T_IDLE;
            endcase
        end
    end

    // --------------------------------------------------------- sequencer --
    localparam [3:0] Q_WAIT = 4'd0, Q_WAKE1 = 4'd1, Q_WAKE2 = 4'd2, Q_IDPTR = 4'd3,
                     Q_IDREAD = 4'd4, Q_PTR = 4'd5, Q_READ = 4'd6, Q_BUSY = 4'd7;
    reg [3:0] q = Q_WAIT, q_next = Q_WAKE1;
    reg [16:0] wait_us = 17'd20000;   // the first wake 20 ms after reset
    reg [16:0] after_us = 17'd0;      // the wait after the transfer in flight
    // The read in flight is the identity until the first data read.
    reg ident_pending = 1'b1;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            q <= Q_WAIT;
            q_next <= Q_WAKE1;
            wait_us <= 17'd20000;
            after_us <= 17'd0;
            go <= 1'b0;
            present <= 1'b0;
            classic <= 1'b0;
            reads <= 16'd0;
            fails <= 8'd0;
            data <= 48'd0;
            ident <= 48'd0;
        end else begin
            go <= 1'b0;
            if (restart) begin
                q <= Q_WAIT;
                q_next <= Q_WAKE1;
                wait_us <= 17'd20000;
                present <= 1'b0;
                classic <= 1'b0;
            end else case (q)
                Q_WAIT:
                    if (wait_us == 17'd0)
                        q <= q_next;
                    else if (us_tick)
                        wait_us <= wait_us - 1'b1;
                Q_WAKE1: begin
                    rd <= 1'b0; len <= 2'd2; wbytes <= 16'hF055;
                    after_us <= 17'd10000; q_next <= Q_WAKE2;
                    go <= 1'b1; q <= Q_BUSY;
                end
                Q_WAKE2: begin
                    rd <= 1'b0; len <= 2'd2; wbytes <= 16'hFB00;
                    after_us <= 17'd20000; q_next <= Q_IDPTR;
                    go <= 1'b1; q <= Q_BUSY;
                end
                Q_IDPTR: begin
                    rd <= 1'b0; len <= 2'd1; wbytes <= 16'hFA00;
                    after_us <= CONVERT_US; q_next <= Q_IDREAD;
                    go <= 1'b1; q <= Q_BUSY;
                end
                Q_IDREAD: begin
                    rd <= 1'b1;
                    after_us <= 17'd1000; q_next <= Q_PTR;
                    go <= 1'b1; q <= Q_BUSY;
                end
                Q_PTR: begin
                    rd <= 1'b0; len <= 2'd1; wbytes <= 16'h0000;
                    after_us <= CONVERT_US; q_next <= Q_READ;
                    go <= 1'b1; q <= Q_BUSY;
                end
                Q_READ: begin
                    rd <= 1'b1;
                    after_us <= 17'd1000; q_next <= Q_PTR;
                    go <= 1'b1; q <= Q_BUSY;
                end
                Q_BUSY:
                    if (done) begin
                        if (nack) begin
                            fails <= fails + 1'b1;
                            present <= 1'b0;
                            classic <= 1'b0;
                            wait_us <= 17'd100000;
                            q_next <= Q_WAKE1;
                        end else begin
                            wait_us <= after_us;
                            if (q_next == Q_PTR && rd) begin
                                if (ident_pending) begin
                                    ident <= rbytes;
                                    // 0x0[01] 0x00 0xA4 0x20 0x0[0-3] 0x01
                                    classic <= rbytes[7:1] == 7'd0 && rbytes[15:8] == 8'h00 &&
                                               rbytes[23:16] == 8'hA4 && rbytes[31:24] == 8'h20 &&
                                               rbytes[39:34] == 6'd0 && rbytes[47:40] == 8'h01;
                                    present <= 1'b1;
                                end else begin
                                    data <= rbytes;
                                    reads <= reads + 1'b1;
                                end
                            end
                        end
                        q <= Q_WAIT;
                    end
                default: q <= Q_WAIT;
            endcase
        end
    end

    always @(posedge clk or negedge resetn)
        if (!resetn)
            ident_pending <= 1'b1;
        else if (restart || (q == Q_BUSY && done && nack))
            ident_pending <= 1'b1;
        else if (q == Q_IDREAD)
            ident_pending <= 1'b1;
        else if (q == Q_READ)
            ident_pending <= 1'b0;
endmodule
