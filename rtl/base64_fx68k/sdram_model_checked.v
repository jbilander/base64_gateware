`timescale 1ns/100ps
//
// sdram_model_checked.v -- behavioural SDRAM with TIMING ENFORCEMENT.
//
// The point of this model is to FAIL, loudly, when the controller violates a
// timing parameter. The previous model decoded commands and pipelined CAS but
// enforced nothing, which is why it happily reported "faster" for a controller
// that stalled on real silicon.
//
// Defaults are for a 143 MHz -7 grade part at CL3, matching the iCESugar Pro.
// All timings are in NANOSECONDS so the model stays valid at any clock rate.
//
module sdram_model_checked #(
    parameter integer CAS_LAT  = 3,
    parameter real    T_RCD_NS = 20.0,   // ACTIVATE -> READ/WRITE, same bank
    parameter real    T_RP_NS  = 20.0,   // PRECHARGE -> ACTIVATE, same bank
    parameter real    T_RAS_NS = 45.0,   // ACTIVATE -> PRECHARGE, same bank (min)
    parameter real    T_RC_NS  = 65.0,   // ACTIVATE -> ACTIVATE, same bank
    parameter real    T_RFC_NS = 65.0,   // REFRESH -> any command
    parameter real    T_REFI_NS= 7800.0, // average refresh interval
    parameter integer ADDR_BITS= 20      // linear word address width
)(
    input  wire        clk,
    input  wire [12:0] a,
    input  wire [1:0]  ba,
    inout  wire [15:0] dq,
    input  wire [1:0]  dqm,
    input  wire        cke, cs_n, ras_n, cas_n, we_n
);
    // ---- storage ---------------------------------------------------------
    reg [15:0] mem [0:(1<<ADDR_BITS)-1];
    reg [12:0] row  [0:3];
    reg        active[0:3];

    // ---- per-bank timestamps --------------------------------------------
    real t_act [0:3];      // last ACTIVATE
    real t_pre [0:3];      // last PRECHARGE
    real t_ref;            // last REFRESH
    real t_last_ref;       // for interval checking

    // ---- CAS pipeline ----------------------------------------------------
    reg [15:0] pipe  [0:7];
    reg [7:0]  pipe_v;
    reg [15:0] dq_o;
    reg        dq_oe;

    integer i, n_err, n_ref;
    integer init_done;

    assign dq = dq_oe ? dq_o : 16'bz;
    wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};

    localparam [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_RD  = 4'b0101,
                     C_WR  = 4'b0100, C_PRE = 4'b0010, C_REF = 4'b0001,
                     C_MRS = 4'b0000;

    function [ADDR_BITS-1:0] lin(input [12:0] r, input [1:0] b, input [8:0] c);
        lin = {r[ADDR_BITS-12:0], b, c};
    endfunction

    task err(input [255:0] msg);
        begin
            n_err = n_err + 1;
            $display("  *** SDRAM TIMING VIOLATION @%0.1f ns: %0s", $realtime, msg);
        end
    endtask

    initial begin
        dq_oe = 0; pipe_v = 0; n_err = 0; n_ref = 0; init_done = 0;
        t_ref = 0.0; t_last_ref = 0.0;
        for (i=0;i<4;i=i+1) begin
            row[i]=0; active[i]=0; t_act[i]=-1e9; t_pre[i]=-1e9;
        end
        for (i=0;i<(1<<ADDR_BITS);i=i+1) mem[i] = 16'hA5A5;
    end

    always @(posedge clk) if (cke) begin
        // CAS pipeline
        for (i=7;i>0;i=i-1) begin pipe[i] <= pipe[i-1]; pipe_v[i] <= pipe_v[i-1]; end
        pipe_v[0] <= 1'b0;

        case (cmd)
        // ------------------------------------------------------------------
        C_ACT: begin
            if (active[ba])
                err("ACTIVATE to a bank that is already ACTIVE (missing PRECHARGE)");
            if (($realtime - t_pre[ba]) < T_RP_NS)
                err("tRP violated: ACTIVATE too soon after PRECHARGE");
            if (($realtime - t_act[ba]) < T_RC_NS)
                err("tRC violated: ACTIVATE to ACTIVATE, same bank, too close");
            if (($realtime - t_ref) < T_RFC_NS)
                err("tRFC violated: command issued too soon after REFRESH");
            row[ba] = a; active[ba] = 1'b1; t_act[ba] = $realtime;
        end
        // ------------------------------------------------------------------
        C_RD: begin
            if (!active[ba])
                err("READ to a bank that is not ACTIVE");
            if (($realtime - t_act[ba]) < T_RCD_NS)
                err("tRCD violated: READ too soon after ACTIVATE");
            if (($realtime - t_ref) < T_RFC_NS)
                err("tRFC violated: READ too soon after REFRESH");
            pipe[0]   <= mem[lin(row[ba], ba, a[8:0])];
            pipe_v[0] <= 1'b1;
        end
        // ------------------------------------------------------------------
        C_WR: begin
            if (!active[ba])
                err("WRITE to a bank that is not ACTIVE");
            if (($realtime - t_act[ba]) < T_RCD_NS)
                err("tRCD violated: WRITE too soon after ACTIVATE");
            if (!dqm[0]) mem[lin(row[ba], ba, a[8:0])][7:0]  = dq[7:0];
            if (!dqm[1]) mem[lin(row[ba], ba, a[8:0])][15:8] = dq[15:8];
        end
        // ------------------------------------------------------------------
        C_PRE: begin
            for (i=0;i<4;i=i+1)
                if (a[10] || (i == ba)) begin
                    if (active[i] && ($realtime - t_act[i]) < T_RAS_NS)
                        err("tRAS violated: PRECHARGE too soon after ACTIVATE");
                    if (active[i]) t_pre[i] = $realtime;
                    active[i] = 1'b0;
                end
        end
        // ------------------------------------------------------------------
        C_REF: begin
            for (i=0;i<4;i=i+1)
                if (active[i]) err("REFRESH issued with a bank still ACTIVE");
            if (init_done && ($realtime - t_last_ref) > T_REFI_NS*2.0)
                err("refresh interval exceeded 2x tREFI - retention at risk");
            t_ref = $realtime; t_last_ref = $realtime;
            n_ref = n_ref + 1;
        end
        C_MRS: init_done = 1;
        default: ;
        endcase

        if (pipe_v[CAS_LAT-1]) begin dq_o <= pipe[CAS_LAT-1]; dq_oe <= 1'b1; end
        else                        dq_oe <= 1'b0;
    end

    task report;
        begin
            $display("  SDRAM model: %0d refreshes, %0d TIMING VIOLATIONS %0s",
                     n_ref, n_err, (n_err==0) ? "" : "   <<<<<< BAD");
        end
    endtask
endmodule
