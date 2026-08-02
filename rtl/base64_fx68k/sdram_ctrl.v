`timescale 1ns / 1ps
`default_nettype none
//
// sdram_ctrl.v — SDR SDRAM controller for the IS42S16160B, OPEN-ROW optimised.
//
// Drop-in replacement for the simple controller: IDENTICAL req/ack interface,
// so fastmem_zii and base64_top are unchanged. The difference is internal:
// instead of a full activate -> R/W-with-auto-precharge on every access, this
// version keeps the active row OPEN in each bank and skips the activate on a
// same-row hit. Only when the requested row differs from the open row in that
// bank do we precharge the old row and activate the new one.
//
// Why this matters: spatially-local access (code loops, sequential data — e.g.
// a Dhrystone loop) mostly hits the already-open row, dropping an access from
// ~8-10 clocks (activate+CAS+precharge) to ~3-4 (just CAS+data). At 7 MHz that
// clears the 68000's S4 DTACK-sample point with margin -> no wait state. At
// turbo (42 MHz) it's the difference between the SDRAM keeping up or not.
//
// Correctness notes:
//  * We never use auto-precharge (A10=0 on R/W commands) so rows stay open.
//  * Refresh requires all banks precharged first: before an auto-refresh we
//    precharge-all and mark every bank closed, then refresh.
//  * tRAS (activate-to-precharge min) and tRC are respected via the row being
//    open across multiple accesses; a lone activate+immediate-precharge path
//    (row change) waits tRCD then the access then tRP.
//  * Read/write to an open row: issue the command, honour CAS latency, done.
//
// TIMING params in clk cycles (defaults for ~85 MHz, conservative for a -7
// grade part). Same as the simple controller plus tRAS.
//
module sdram_ctrl #(
    parameter integer CLK_HZ      = 85_130_000,
    parameter integer T_RCD       = 2,    // activate -> r/w
    parameter integer T_RP        = 2,    // precharge
    parameter integer T_RAS       = 5,    // activate -> precharge (min row open)
    parameter integer T_RFC       = 6,    // refresh
    parameter integer CAS_LAT     = 2,
    parameter integer T_MRD       = 2,
    parameter integer T_REFI      = 640,
    parameter integer T_INIT_US   = 100
)(
    input  wire        clk,
    input  wire        reset,

    // ---- CPU-side request/ack handshake (UNCHANGED) ----
    input  wire        req,
    input  wire        we,
    input  wire        wr_valid,     // 1 = wdata/byte_en are valid (gate WRITE)
    input  wire [23:0] addr,          // word address {row[12:0],bank[1:0],col[8:0]}
    input  wire [15:0] wdata,
    input  wire [1:0]  byte_en,
    output reg         ack,
    // Combinational ack, asserted in the SAME cycle the CAS data lands on dq
    // rather than the cycle after. Worth one master clock, which is exactly
    // what separates one wait state from none at 6x.
    //
    // This is NOT the unsafe "EARLY_ACK" that green-screened the machine.
    // That acked on the MOTHERBOARD's DTACK, before the slave had driven
    // data. Here the data is demonstrably on dq -- we are sampling it on this
    // very edge -- so the value handed over is real.
    output wire        ack_early,
    output wire [15:0] rdata_live,
    output reg  [15:0] rdata,
    output wire        ready,

    // ---- SDRAM pins ----
    output reg  [12:0] sdram_a,
    output reg  [1:0]  sdram_ba,
    inout  wire [15:0] sdram_dq,
    output reg  [1:0]  sdram_dqm,
    output wire        sdram_clk,
    output reg         sdram_cke,
    output reg         sdram_cs_n,
    output reg         sdram_ras_n,
    output reg         sdram_cas_n,
    output reg         sdram_we_n
);

    // ---- address split ----
    wire [8:0]  a_col  = addr[8:0];
    wire [1:0]  a_bank = addr[10:9];
    wire [12:0] a_row  = addr[23:11];

    assign sdram_clk = clk;    // real pin driven via ODDR in the top

    // ---- DQ tristate ----
    reg [15:0] dq_out;
    reg        dq_oe;
    assign sdram_dq = dq_oe ? dq_out : 16'bz;

    // ---- commands {cs,ras,cas,we} ----
    assign ack_early  = (state == S_RD_DONE) || (state == S_WR_DONE);
    assign rdata_live = sdram_dq;

    localparam CMD_NOP      = 4'b0111;
    localparam CMD_ACTIVE   = 4'b0011;
    localparam CMD_READ     = 4'b0101;
    localparam CMD_WRITE    = 4'b0100;
    localparam CMD_PRECHG   = 4'b0010;
    localparam CMD_REFRESH  = 4'b0001;
    localparam CMD_LOADMODE = 4'b0000;
    localparam CMD_NOP_DES  = 4'b1111;

    task set_cmd(input [3:0] c);
        begin
            sdram_cs_n  <= c[3];
            sdram_ras_n <= c[2];
            sdram_cas_n <= c[1];
            sdram_we_n  <= c[0];
        end
    endtask

    localparam [2:0]  CL3 = CAS_LAT[2:0];
    localparam [12:0] MODE_REG = {3'b000, 1'b0, 2'b00, CL3, 1'b0, 3'b000};

    localparam integer INIT_CYCLES = (CLK_HZ/1_000_000)*T_INIT_US;
    localparam integer INITW = 14;
    reg [INITW-1:0] init_cnt;

    reg [10:0] refresh_timer;
    reg        refresh_due;

    // ---- open-row tracking: one open row + valid flag per bank ----
    // Refresh deferral: bounded so refresh can never actually be starved.
    localparam [7:0] REF_DEFER = 8'd64;
    reg  [7:0] ref_defer = 8'd0;
    wire       ref_urgent = (ref_defer >= REF_DEFER);
    reg [12:0] open_row [0:3];
    reg [3:0]  row_open;          // bit b = bank b has an open row
    reg [3:0]  ras_timer [0:3];   // per-bank tRAS since activate (saturating)

    // ---- FSM ----
    localparam S_INIT_WAIT = 4'd0,
               S_INIT_PRE  = 4'd1,
               S_INIT_REF1 = 4'd2,
               S_INIT_REF2 = 4'd3,
               S_INIT_MODE = 4'd4,
               S_IDLE      = 4'd5,
               S_PRECHG    = 4'd6,   // close wrong row before activating
               S_ACTIVE    = 4'd7,   // activate target row
               S_RW        = 4'd8,   // issue read/write to open row
               S_RD_WAIT   = 4'd9,
               S_RD_DONE   = 4'd10,
               S_WR_DONE   = 4'd11,
               S_REF_PRE   = 4'd12,  // precharge-all before refresh
               S_REFRESH   = 4'd13,
               S_ACK_WAIT  = 4'd14;  // hold after ack until req deasserts

    reg [3:0]  state;
    reg [3:0]  timer;
    reg        init_done;
    reg [1:0]  cur_bank;
    reg [12:0] cur_row;
    reg [8:0]  cur_col;
    reg        cur_we;

    assign ready = init_done;

    integer b;

    always @(posedge clk) begin
        if (reset) begin
            state       <= S_INIT_WAIT;
            init_cnt    <= INIT_CYCLES[INITW-1:0];
            sdram_cke   <= 1'b0;
            set_cmd(CMD_NOP_DES);
            sdram_a     <= 13'd0;
            sdram_ba    <= 2'd0;
            sdram_dqm   <= 2'b11;
            dq_oe       <= 1'b0;
            dq_out      <= 16'd0;
            ack         <= 1'b0;
            rdata       <= 16'd0;
            timer       <= 4'd0;
            refresh_timer <= 11'd0;
            refresh_due <= 1'b0;
            init_done   <= 1'b0;
            row_open    <= 4'b0000;
            for (b=0;b<4;b=b+1) begin open_row[b] <= 13'd0; ras_timer[b] <= 4'd0; end
        end else begin
            ack   <= 1'b0;
            set_cmd(CMD_NOP);
            dq_oe <= 1'b0;

            // refresh interval timer
            if (init_done) begin
                if (refresh_timer >= T_REFI[10:0]) begin
                    refresh_timer <= 11'd0;
                    refresh_due   <= 1'b1;
                end else
                    refresh_timer <= refresh_timer + 11'd1;
            end

            // saturating per-bank tRAS counters
            // NOTE the begin/end. The original for-loop body was a single
            // statement with no begin/end; inserting the ref_defer lines
            // above it silently pushed the tRAS counter OUT of the loop,
            // where b holds its terminal value 4 -- out of range for both
            // row_open[3:0] and ras_timer[0:3]. ras_timer then never
            // incremented, so "ras_timer[a_bank] >= T_RAS" was never true and
            // every row miss on an already-open bank stalled in S_IDLE until
            // the next refresh cleared row_open. That is the 2992 -> 1354
            // regression: not timing, a missing begin/end.
            for (b=0;b<4;b=b+1) begin
                if (row_open[b] && ras_timer[b] != 4'hF)
                    ras_timer[b] <= ras_timer[b] + 4'd1;
            end
            if (refresh_due && ref_defer < 8'hFF) ref_defer <= ref_defer + 8'd1;
            if (!refresh_due)                     ref_defer <= 8'd0;

            case (state)
            // ---------------- INIT ----------------
            S_INIT_WAIT: begin
                sdram_cke <= 1'b1;
                sdram_dqm <= 2'b11;
                if (init_cnt == 0) state <= S_INIT_PRE;
                else               init_cnt <= init_cnt - 1'b1;
            end
            S_INIT_PRE: begin
                set_cmd(CMD_PRECHG);
                sdram_a[10] <= 1'b1;
                timer <= T_RP[3:0];
                state <= S_INIT_REF1;
            end
            S_INIT_REF1: begin
                if (timer != 0) timer <= timer - 1'b1;
                else begin
                    set_cmd(CMD_REFRESH);
                    timer <= T_RFC[3:0];
                    state <= S_INIT_REF2;
                end
            end
            S_INIT_REF2: begin
                if (timer != 0) timer <= timer - 1'b1;
                else begin
                    set_cmd(CMD_REFRESH);
                    timer <= T_RFC[3:0];
                    state <= S_INIT_MODE;
                end
            end
            S_INIT_MODE: begin
                if (timer != 0) timer <= timer - 1'b1;
                else begin
                    set_cmd(CMD_LOADMODE);
                    sdram_ba <= 2'b00;
                    sdram_a  <= MODE_REG;
                    timer    <= T_MRD[3:0];
                    state    <= S_IDLE;
                    init_done <= 1'b1;
                end
            end
            // ---------------- IDLE / dispatch ----------------
            S_IDLE: begin
                sdram_dqm <= 2'b11;
                if (timer != 0) begin
                    timer <= timer - 1'b1;
                end else if (refresh_due && (!req || ref_urgent)) begin
                    // A pending CPU access now takes priority over refresh.
                    // Previously refresh_due was tested BEFORE req, so a
                    // refresh falling due while the 68000 was mid-cycle
                    // inserted precharge-all + tRFC + a guaranteed row miss
                    // into that cycle -- the source of the 22-CPU-clock
                    // outliers. Refresh has enormous slack (one per 640
                    // clocks against a 64 ms window), so deferring it by up
                    // to REF_DEFER clocks costs nothing and is bounded.
                    refresh_due <= 1'b0;
                    ref_defer   <= 8'd0;
                    // must close all rows before refresh
                    if (row_open != 4'b0000) begin
                        // NOTE: restoring the evicted row after refresh was
                        // tried and measured a wash (w2 556->561 but w3/w4
                        // 514->511), so it is deliberately NOT done. The
                        // post-refresh miss is cheaper than the extra
                        // ACTIVATE plus tRCD it would cost.
                        set_cmd(CMD_PRECHG);
                        sdram_a[10] <= 1'b1;         // precharge all
                        row_open <= 4'b0000;
                        timer <= T_RP[3:0];
                        state <= S_REF_PRE;
                    end else begin
                        set_cmd(CMD_REFRESH);
                        timer <= T_RFC[3:0];
                        state <= S_REFRESH;
                    end
                end else if (req) begin
                    // latch the request. Only the ADDRESS and direction are
                    // captured here. Write DATA is NOT latched - it is sampled
                    // live at the WRITE command, which is gated on wr_valid.
                    // This lets a write request start early (address valid at
                    // AS) before the 68000 has driven the data (DS asserts a
                    // period later on writes). cur_we is the single source of
                    // truth for read vs write in S_RW.
                    cur_bank  <= a_bank;
                    cur_row   <= a_row;
                    cur_col   <= a_col;
                    cur_we    <= we;
                    // open-row decision
                    if (row_open[a_bank] && open_row[a_bank] == a_row) begin
                        // HIT: row already open. OPT B -- issue the READ in
                        // THIS cycle rather than spending one getting to
                        // S_RW. Writes still route via S_RW because the
                        // WRITE command has to wait for wr_valid.
                        timer <= 4'd0;
                        if (!we) begin
                            sdram_ba  <= a_bank;
                            sdram_a   <= {4'b0000, a_col};  // A10=0, no auto-pre
                            set_cmd(CMD_READ);
                            sdram_dqm <= 2'b00;
                            timer     <= CAS_LAT[3:0];
                            state     <= S_RD_WAIT;
                        end else begin
                            state <= S_RW;
                        end
                    end else if (row_open[a_bank]) begin
                        // wrong row open: precharge it (respect tRAS), then activate
                        if (ras_timer[a_bank] >= T_RAS[3:0]) begin
                            set_cmd(CMD_PRECHG);
                            sdram_ba <= a_bank;
                            sdram_a[10] <= 1'b0;     // this bank only
                            row_open[a_bank] <= 1'b0;
                            timer <= T_RP[3:0];
                            state <= S_PRECHG;
                        end
                        // else tRAS not met: stay in IDLE and retry next cycle
                    end else begin
                        // bank closed: activate directly
                        set_cmd(CMD_ACTIVE);
                        sdram_ba <= a_bank;
                        sdram_a  <= a_row;
                        open_row[a_bank] <= a_row;
                        row_open[a_bank] <= 1'b1;
                        ras_timer[a_bank] <= 4'd0;
                        timer <= T_RCD[3:0];
                        state <= S_ACTIVE;
                    end
                end
            end
            // wait tRP after precharging the wrong row, then activate target
            S_PRECHG: begin
                if (timer != 0) timer <= timer - 1'b1;
                else begin
                    set_cmd(CMD_ACTIVE);
                    sdram_ba <= cur_bank;
                    sdram_a  <= cur_row;
                    open_row[cur_bank] <= cur_row;
                    row_open[cur_bank] <= 1'b1;
                    ras_timer[cur_bank] <= 4'd0;
                    timer <= T_RCD[3:0];
                    state <= S_ACTIVE;
                end
            end
            // wait tRCD after activate, then issue R/W
            S_ACTIVE: begin
                if (timer != 0) timer <= timer - 1'b1;
                else state <= S_RW;
            end
            // issue read or write to the (now open) row
            S_RW: begin
                if (timer != 0) begin
                    timer <= timer - 1'b1;      // finishing tRCD after activate
                end else if (!cur_we) begin
                    // READ: issue immediately (row is open/active)
                    sdram_ba <= cur_bank;
                    sdram_a  <= {4'b0000, cur_col};   // A10=0: NO auto-precharge
                    set_cmd(CMD_READ);
                    sdram_dqm <= 2'b00;
                    timer <= CAS_LAT[3:0];
                    state <= S_RD_WAIT;
                end else if (wr_valid) begin
                    // WRITE: the row is already active (possibly started early
                    // at AS). Issue the WRITE only once the data is valid
                    // (wr_valid). Sample wdata/byte_en LIVE here - by now the
                    // 68000 has driven them. This is what removes the write
                    // wait state: the activate overlapped the CPU's data-drive
                    // delay instead of starting after it.
                    sdram_ba <= cur_bank;
                    sdram_a  <= {4'b0000, cur_col};   // A10=0: NO auto-precharge
                    set_cmd(CMD_WRITE);
                    sdram_dqm <= ~byte_en;
                    dq_out    <= wdata;
                    dq_oe     <= 1'b1;
                    state     <= S_WR_DONE;
                end
                // else (write, data not yet valid): hold here with row open,
                // waiting for wr_valid. No command issued (NOP), no timeout -
                // the CPU will assert data strobes within a couple of clocks.
            end
            S_RD_WAIT: begin
                if (timer > 1) timer <= timer - 1'b1;
                else state <= S_RD_DONE;
            end
            S_RD_DONE: begin
                rdata <= sdram_dq;
                ack   <= 1'b1;
                state <= S_ACK_WAIT;          // row stays OPEN; wait req low
            end
            // Wait for the requester to drop req before accepting a new access.
            // Prevents a lingering req (deasserted a cycle after ack) from being
            // re-accepted with stale cur_we/data - which would hang a following
            // read behind a phantom write, or vice versa.
            S_ACK_WAIT: begin
                if (!req) state <= S_IDLE;
            end
            S_WR_DONE: begin
                ack   <= 1'b1;
                state <= S_ACK_WAIT;          // row stays OPEN; wait req low
            end
            // ---------------- REFRESH ----------------
            S_REF_PRE: begin
                if (timer != 0) timer <= timer - 1'b1;
                else begin
                    set_cmd(CMD_REFRESH);
                    timer <= T_RFC[3:0];
                    state <= S_REFRESH;
                end
            end
            S_REFRESH: begin
                if (timer != 0) timer <= timer - 1'b1;
                else state <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
