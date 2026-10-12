// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// Behavioural model of one W9825G6KH-6 (16-bit SDR SDRAM, 4 banks, 13 row
// and 9 column bits) for the AE350 SDRAM testbench, with the datasheet
// checks this design depends on. Only burst length 1 is modelled. It stops
// the simulation on:
//   - a command other than NOP or PRECHARGE ALL first, a MODE before two
//     AUTO REFRESHes, or an ACTIVE before MODE;
//   - ACTIVE to an open bank, READ or WRITE to a closed one, REFRESH or MODE
//     with a bank open, auto precharge, or a burst length other than 1;
//   - tRCD, tRP, tRAS, tRC or tRFC shorter than T_* ns, tWR shorter than two
//     clocks, or more than T_REFI ns between AUTO REFRESHes once running.
// Read data leaves the pins T_AC ns after the clock edge CL - 1 clocks
// after the READ and holds until T_OH ns after the next one, then goes to
// X (or Z with nothing behind it), so a controller must capture it near
// the edge CL clocks after the READ.
//
// Storage is kept small: each bank stores 29 rows, row r in slot r mod 29,
// and each slot remembers which full row wrote it last, so a read of any
// other row in that slot returns X. Row 0 and the 13 one-hot rows all have
// slots of their own, so a walk of the address lines can catch any that is
// stuck, swapped or missing.
module sdram_model #(
    parameter real T_AC = 5.0,
    parameter real T_OH = 3.0,
    parameter real T_RCD = 15.0,
    parameter real T_RP = 15.0,
    parameter real T_RAS = 42.0,
    parameter real T_RC = 60.0,
    parameter real T_REFI = 7812.5
) (
    input  wire        clk,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [1:0]  ba,
    input  wire [12:0] a,
    input  wire [1:0]  dqm,
    inout  wire [15:0] dq
);
    localparam integer SLOTS = 4 * 32;

    reg [15:0] mem [0:SLOTS*512-1];
    reg [12:0] owner [0:SLOTS-1];
    reg owned [0:SLOTS-1];

    reg [15:0] dq_drive = 16'bz;
    assign dq = dq_drive;

    reg open [0:3];
    reg [12:0] open_row [0:3];
    real t_active [0:3];
    real t_precharge [0:3];
    integer write_cycle [0:3];
    real t_refresh = -1.0e9;
    integer refreshes = 0;
    reg mode_set = 1'b0;
    reg started = 1'b0;
    integer cas_latency = 3;
    integer cycle = 0;

    // Reads due out: the data for the edge it must be captured at.
    reg due [0:63];
    reg [15:0] due_data [0:63];

    integer reads = 0;
    integer writes = 0;
    integer i;

    initial begin
        for (i = 0; i < 4; i = i + 1) begin
            open[i] = 1'b0;
            t_active[i] = -1.0e9;
            t_precharge[i] = -1.0e9;
            write_cycle[i] = -100;
        end
        for (i = 0; i < SLOTS; i = i + 1)
            owned[i] = 1'b0;
        for (i = 0; i < 64; i = i + 1)
            due[i] = 1'b0;
    end

    function integer row_slot(input [1:0] bank, input [12:0] row);
        row_slot = 32 * bank + row % 29;
    endfunction

    task check(input ok, input [8*48-1:0] what);
        if (!ok)
            $fatal(1, "SDRAM model at %0.1f ns: %0s", $realtime, what);
    endtask

    wire [3:0] command = {cs_n, ras_n, cas_n, we_n};
    integer b;
    integer slot;
    integer index;
    real now;

    always @(posedge clk) begin
        now = $realtime;
        cycle = cycle + 1;

        // Drive the read due at the next edge; release the one due now.
        if (due[cycle % 64]) begin
            due[cycle % 64] = 1'b0;
            if (due[(cycle + 1) % 64])
                dq_drive <= #(T_OH) 16'bx;
            else
                dq_drive <= #(T_OH) 16'bz;
        end
        if (due[(cycle + 1) % 64])
            dq_drive <= #(T_AC) due_data[(cycle + 1) % 64];

        if (command !== 4'b0111 && command[3] === 1'b0) begin
            if (!started)
                check(command == 4'b0010 && a[10], "first command is not PRECHARGE ALL");
            started = 1'b1;
            b = ba;
            case (command)
                4'b0011: begin // ACTIVE
                    check(mode_set, "ACTIVE before MODE");
                    check(!open[b], "ACTIVE to an open bank");
                    check(now - t_precharge[b] >= T_RP, "tRP");
                    check(now - t_active[b] >= T_RC, "tRC");
                    check(now - t_refresh >= T_RC, "tRFC");
                    open[b] = 1'b1;
                    open_row[b] = a;
                    t_active[b] = now;
                end
                4'b0101, 4'b0100: begin // READ, WRITE
                    check(open[b], "READ or WRITE to a closed bank");
                    check(now - t_active[b] >= T_RCD, "tRCD");
                    check(!a[10], "auto precharge");
                    slot = row_slot(b, open_row[b]);
                    index = 512 * slot + a[8:0];
                    if (command == 4'b0100) begin
                        writes = writes + 1;
                        write_cycle[b] = cycle;
                        if (!owned[slot] || owner[slot] != open_row[b]) begin
                            owned[slot] = 1'b1;
                            owner[slot] = open_row[b];
                            for (i = 0; i < 512; i = i + 1)
                                mem[512 * slot + i] = 16'bx;
                        end
                        if (!dqm[0])
                            mem[index][7:0] = dq[7:0];
                        if (!dqm[1])
                            mem[index][15:8] = dq[15:8];
                    end else begin
                        reads = reads + 1;
                        due[(cycle + cas_latency) % 64] = 1'b1;
                        due_data[(cycle + cas_latency) % 64] =
                            (owned[slot] && owner[slot] == open_row[b]) ?
                            mem[index] : 16'bx;
                    end
                end
                4'b0010: begin // PRECHARGE
                    for (i = 0; i < 4; i = i + 1) begin
                        if ((a[10] || i == b) && open[i]) begin
                            check(now - t_active[i] >= T_RAS, "tRAS");
                            check(cycle - write_cycle[i] >= 2, "tWR");
                            open[i] = 1'b0;
                            t_precharge[i] = now;
                        end
                    end
                end
                4'b0001: begin // AUTO REFRESH
                    for (i = 0; i < 4; i = i + 1) begin
                        check(!open[i], "REFRESH with a bank open");
                        check(now - t_precharge[i] >= T_RP, "tRP before REFRESH");
                    end
                    check(now - t_refresh >= T_RC, "tRFC between REFRESHes");
                    if (mode_set)
                        check(now - t_refresh <= T_REFI, "refresh interval");
                    t_refresh = now;
                    refreshes = refreshes + 1;
                end
                4'b0000: begin // MODE REGISTER SET
                    for (i = 0; i < 4; i = i + 1)
                        check(!open[i], "MODE with a bank open");
                    check(refreshes >= 2, "MODE before two REFRESHes");
                    check(a[2:0] == 3'd0, "burst length is not 1");
                    check(a[6:4] == 3'd2 || a[6:4] == 3'd3, "CAS latency");
                    cas_latency = a[6:4];
                    mode_set = 1'b1;
                end
                default: check(1'b0, "unsupported command");
            endcase
        end
    end
endmodule
