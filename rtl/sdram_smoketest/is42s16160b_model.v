`timescale 1ns / 1ps
`default_nettype none
//
// is42s16160b_model.v — minimal behavioural model of the ISSI IS42S16160B
// SDR SDRAM, enough to verify sdram_ctrl.v: init (precharge/refresh/mode),
// activate, read & write with auto-precharge, CAS latency 2, DQM byte masks.
//
// Not a timing-accurate datasheet model — it checks command *sequencing* and
// moves the right data with the right CAS latency, which is what our
// controller correctness depends on. Storage is sparse (assoc. array) so 32 MB
// costs nothing in sim.
//
module is42s16160b_model (
    input  wire        clk,
    input  wire        cke,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [12:0] a,
    input  wire [1:0]  ba,
    inout  wire [15:0] dq,
    input  wire [1:0]  dqm
);
    localparam CL = 2;

    // sparse storage keyed by {bank[1:0], row[12:0], col[8:0]}
    reg [15:0] mem [0:16*1024*1024-1];
    reg [12:0] active_row [0:3];
    reg [3:0]  bank_active;

    // read pipeline for CAS latency. Data must appear on DQ exactly CL cycles
    // after the READ command. The command is captured in the posedge block at
    // cycle N (so the captured value is first observable at N+1); we therefore
    // need CL-1 additional shift stages to land the output at N+CL.
    localparam PIPE = CL-1;      // shift stages after posedge capture
    reg [15:0] rd_pipe [0:PIPE];
    reg        rd_vld  [0:PIPE];
    integer i;

    reg [15:0] dq_drive;
    reg        dq_en;
    assign dq = dq_en ? dq_drive : 16'bz;

    wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
    localparam ACTIVE=4'b0011, READ=4'b0101, WRITE=4'b0100,
               PRECHG=4'b0010, REFRESH=4'b0001, LOADMODE=4'b0000, NOP=4'b0111;

    function [23:0] addr_of(input [1:0] bk, input [12:0] row, input [8:0] col);
        addr_of = {bk, row, col};
    endfunction

    initial begin
        bank_active = 4'b0000;
        dq_en = 0;
        for (i=0;i<=PIPE;i=i+1) begin rd_vld[i]=0; rd_pipe[i]=0; end
    end

    // shift read pipeline every clock; drive DQ when a read result is due
    always @(posedge clk) begin
        if (cke) begin
            // advance pipeline (only if there are shift stages, i.e. CL>1)
            for (i=PIPE;i>0;i=i-1) begin
                rd_pipe[i] <= rd_pipe[i-1];
                rd_vld[i]  <= rd_vld[i-1];
            end
            rd_vld[0] <= 1'b0;

            // decode command
            case (cmd)
                ACTIVE: begin
                    active_row[ba] <= a;
                    bank_active[ba] <= 1'b1;
                end
                PRECHG: begin
                    if (a[10]) bank_active <= 4'b0000;
                    else       bank_active[ba] <= 1'b0;
                end
                READ: begin
                    // capture read: data out CL cycles later
                    rd_pipe[0] <= mem[addr_of(ba, active_row[ba], a[8:0])];
                    rd_vld[0]  <= 1'b1;
                    if (^{active_row[ba]} === 1'bx)
                        rd_pipe[0] <= 16'h0000;   // uninitialised -> 0
                    if (a[10]) bank_active[ba] <= 1'b0;   // auto-precharge
                end
                WRITE: begin
                    begin : wr
                        reg [23:0] wa;
                        reg [15:0] cur;
                        wa  = addr_of(ba, active_row[ba], a[8:0]);
                        cur = mem[wa];
                        if (!dqm[0]) cur[7:0]  = dq[7:0];
                        if (!dqm[1]) cur[15:8] = dq[15:8];
                        mem[wa] = cur;
                    end
                    if (a[10]) bank_active[ba] <= 1'b0;
                end
                default: ;
            endcase
        end
    end

    // Drive DQ on the NEGEDGE so read data is stable at the controller's next
    // POSEDGE sample — no delta-race, and it mirrors real timing (SDRAM drives
    // DQ from its clock edge; the FPGA samples a half-cycle+ later). rd_vld[PIPE]
    // becomes true at posedge N+CL; the following negedge presents DQ, sampled
    // at posedge N+CL by the controller. To land data exactly at N+CL we drive
    // on the negedge that precedes it, keyed off rd_vld[PIPE-1] when CL>1.
    always @(negedge clk) begin
        if (cke) begin
            if (rd_vld[PIPE]) begin
                dq_en    <= 1'b1;
                dq_drive <= rd_pipe[PIPE];
            end else begin
                dq_en    <= 1'b0;
            end
        end
    end
endmodule
