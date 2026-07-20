`timescale 1ns / 1ps
`default_nettype none
//
// sdram_ctrl.v  —  SDR SDRAM controller for the iCESugar-Pro's IS42S16160B
//                  (ISSI, 4 banks x 8192 rows x 512 cols x 16 bit = 32 MB).
//
// Stage 1 of the Base64 fast-RAM path. Deliberately SIMPLE and verifiable:
// every access is a full Activate -> Read/Write-with-auto-precharge cycle
// (no open-row optimisation yet — that's a later, drop-in upgrade behind the
// same handshake). CAS latency 2. Auto-precharge (A10=1 on the R/W command)
// so we never track open rows and never issue an explicit Precharge in the
// access path — refresh is the only other command.
//
// TURBO-READY BY CONSTRUCTION:
//  * The CPU side talks to this ONLY through a generic req/ack handshake
//    (req, we, addr, wdata, byte_en -> ack, rdata). Nothing here knows about
//    the 68000, the 7 MHz bus, Zorro II vs III, or the CPU clock. When the
//    core goes to 42.5 MHz, THIS MODULE DOES NOT CHANGE — the CPU simply
//    waits fewer of its own cycles for the same ack.
//  * Runs on its own clock (clk, = 85.13 MHz now and at turbo). SDRAM speed
//    is independent of CPU speed; that decoupling is the whole point of fast
//    RAM and is what the CBT-isolation in the bus wrapper exploits.
//  * addr is a WORD address (16-bit words), 24 bits = 16M words = 32 MB.
//    Mapping to {bank,row,col} is fixed here and independent of how the
//    Amiga-side decoder (Z2 now, Z2+Z3 later) produces that linear address.
//
// TIMING (parameters below are in clk cycles @ ~85 MHz / 11.75 ns; adjust if
// the SDRAM clock ever changes). Values are conservative for a -7 (143 MHz)
// speed-grade IS42S16160B and give margin at 85 MHz:
//   tRC   (activate-to-activate / ref) ~63 ns  -> 6 clk
//   tRCD  (activate-to-r/w)           ~21 ns  -> 2 clk
//   tRP   (precharge)                 ~21 ns  -> 2 clk
//   CL    (CAS latency)                2 clk
//   tRFC  (refresh)                   ~63 ns  -> 6 clk
//   tREFI (avg refresh interval)      ~7.8 us -> 664 clk (we use 640 margin)
//   tMRD  (mode reg)                  2 clk
//   power-up stable                   100 us  -> ~8500 clk
//
module sdram_ctrl #(
    parameter integer CLK_HZ      = 85_130_000,
    // timing in clocks (defaults computed for ~85 MHz; override if needed)
    parameter integer T_RC        = 6,
    parameter integer T_RCD       = 2,
    parameter integer T_RP        = 2,
    parameter integer T_RFC       = 6,
    parameter integer CAS_LAT     = 2,
    parameter integer T_MRD       = 2,
    parameter integer T_REFI      = 640,     // issue a refresh at least this often
    parameter integer T_INIT_US   = 100      // power-up wait, microseconds
)(
    input  wire        clk,
    input  wire        reset,        // active high, synchronous

    // ---- CPU-side request/ack handshake ----
    input  wire        req,          // hold high until ack
    input  wire        we,           // 1 = write, 0 = read
    input  wire [23:0] addr,         // WORD address (16M words = 32 MB)
    input  wire [15:0] wdata,
    input  wire [1:0]  byte_en,      // {high byte, low byte}, 1 = write that byte
    output reg         ack,          // 1-cycle strobe when access completes
    output reg  [15:0] rdata,        // valid the cycle ack is high (reads)
    output wire        ready,        // 1 once init done (for gating pwrup)

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

    // ---- address split: 24-bit word addr -> bank[1:0], row[12:0], col[8:0] ----
    // Column is 9 bits (512), row 13 bits (8192), bank 2 bits (4).
    // Layout chosen so sequential words walk columns first (best for a later
    // open-row upgrade): addr = { row[12:0], bank[1:0], col[8:0] }.
    wire [8:0]  a_col  = addr[8:0];
    wire [1:0]  a_bank = addr[10:9];
    wire [12:0] a_row  = addr[23:11];

    // ---- SDRAM clock: forward the controller clock to the DRAM ----
    // On ECP5 the clean way is a DDR output (ODDRX1F) or a clock pin; for
    // simulation and a first cut we mirror clk. In synthesis, replace with an
    // ODDRX1F driving {1,0} so the SDRAM clock is phase-aligned to internal
    // logic. (Placeholder here keeps the behavioural model happy.)
    assign sdram_clk = clk;

    // ---- tristate DQ: drive only during writes ----
    reg [15:0] dq_out;
    reg        dq_oe;
    assign sdram_dq = dq_oe ? dq_out : 16'bz;

    // ---- SDRAM command encoding {cs,ras,cas,we} ----
    localparam CMD_NOP      = 4'b0111;  // (cs=0 always while running)
    localparam CMD_ACTIVE   = 4'b0011;
    localparam CMD_READ     = 4'b0101;
    localparam CMD_WRITE    = 4'b0100;
    localparam CMD_PRECHG   = 4'b0010;
    localparam CMD_REFRESH  = 4'b0001;
    localparam CMD_LOADMODE = 4'b0000;
    localparam CMD_NOP_DES  = 4'b1111;  // deselect (cs=1), used pre-init

    task set_cmd(input [3:0] c);
        begin
            sdram_cs_n  <= c[3];
            sdram_ras_n <= c[2];
            sdram_cas_n <= c[1];
            sdram_we_n  <= c[0];
        end
    endtask

    // Mode register: CAS latency 2, sequential burst length 1, write burst
    // single-location. A[9]=0 (burst read+write), A[8:7]=00, A[6:4]=CL,
    // A[3]=0 (sequential), A[2:0]=000 (burst length 1).
    localparam [2:0]  CL3 = CAS_LAT[2:0];
    localparam [12:0] MODE_REG = {3'b000, 1'b0, 2'b00, CL3, 1'b0, 3'b000};

    // ---- init counter ----
    localparam integer INIT_CYCLES = (CLK_HZ/1_000_000)*T_INIT_US;
    // width helpers
    localparam integer INITW = 14;   // 8500 fits in 14 bits
    reg [INITW-1:0] init_cnt;

    // ---- refresh timer ----
    reg [10:0] refresh_timer;
    reg        refresh_due;

    // ---- FSM ----
    localparam S_INIT_WAIT = 4'd0,
               S_INIT_PRE  = 4'd1,
               S_INIT_REF1 = 4'd2,
               S_INIT_REF2 = 4'd3,
               S_INIT_MODE = 4'd4,
               S_IDLE      = 4'd5,
               S_ACTIVE    = 4'd6,
               S_RW        = 4'd7,
               S_RD_WAIT   = 4'd8,
               S_RD_DONE   = 4'd12,
               S_WR_DONE   = 4'd9,
               S_REFRESH   = 4'd10,
               S_RECOVER   = 4'd11;

    reg [3:0]  state;
    reg [3:0]  timer;        // general per-state wait counter
    reg        rd_pending;   // distinguishes read vs write in RW path
    reg        init_done;

    assign ready = init_done;


    always @(posedge clk) begin
        if (reset) begin
            state       <= S_INIT_WAIT;
            init_cnt    <= INIT_CYCLES[INITW-1:0];
            sdram_cke   <= 1'b0;
            set_cmd(CMD_NOP_DES);
            sdram_a     <= 13'd0;
            sdram_ba    <= 2'd0;
            sdram_dqm   <= 2'b11;   // masked / high-Z during init
            dq_oe       <= 1'b0;
            dq_out      <= 16'd0;
            ack         <= 1'b0;
            rdata       <= 16'd0;
            timer       <= 4'd0;
            refresh_timer <= 11'd0;
            refresh_due <= 1'b0;
            rd_pending  <= 1'b0;
            init_done   <= 1'b0;
        end else begin
            // defaults each cycle
            ack       <= 1'b0;
            set_cmd(CMD_NOP);
            dq_oe     <= 1'b0;

            // refresh interval timer (free-running once init done)
            if (init_done) begin
                if (refresh_timer >= T_REFI[10:0]) begin
                    refresh_timer <= 11'd0;
                    refresh_due   <= 1'b1;
                end else begin
                    refresh_timer <= refresh_timer + 11'd1;
                end
            end

            case (state)
            // ---------------- INIT ----------------
            S_INIT_WAIT: begin
                sdram_cke <= 1'b1;          // bring CKE high during the wait
                sdram_dqm <= 2'b11;
                if (init_cnt == 0) state <= S_INIT_PRE;
                else               init_cnt <= init_cnt - 1'b1;
            end
            S_INIT_PRE: begin              // precharge all
                set_cmd(CMD_PRECHG);
                sdram_a[10] <= 1'b1;       // A10=1 -> all banks
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
                    set_cmd(CMD_REFRESH);   // second auto-refresh
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
            // ---------------- IDLE ----------------
            S_IDLE: begin
                sdram_dqm <= 2'b11;         // keep masked when not accessing
                if (timer != 0) begin
                    timer <= timer - 1'b1;  // finish tMRD or prior recovery
                end else if (refresh_due) begin
                    refresh_due <= 1'b0;
                    set_cmd(CMD_REFRESH);
                    timer <= T_RFC[3:0];
                    state <= S_REFRESH;
                end else if (req) begin
                    set_cmd(CMD_ACTIVE);
                    sdram_ba <= a_bank;
                    sdram_a  <= a_row;
                    rd_pending <= ~we;
                    timer <= T_RCD[3:0];
                    state <= S_ACTIVE;
                end
            end
            // ---------------- ACCESS ----------------
            S_ACTIVE: begin
                if (timer != 0) timer <= timer - 1'b1;
                else begin
                    // issue READ or WRITE with auto-precharge (A10=1)
                    sdram_ba <= a_bank;
                    sdram_a  <= {2'b00, 1'b1, 1'b0, a_col}; // A10=1 auto-precharge, A9=0, col in [8:0]
                    if (rd_pending) begin
                        set_cmd(CMD_READ);
                        sdram_dqm <= 2'b00;         // enable both bytes on read
                        // DQ is valid CAS_LAT cycles after this (the READ)
                        // cycle. We enter S_RD_WAIT next cycle; with the model
                        // driving DQ from a registered output, S_RD_DONE must
                        // execute on the valid-data cycle. Load CAS_LAT-1 so
                        // the dwell + handoff lands exactly there.
                        timer <= CAS_LAT[3:0];
                        state <= S_RD_WAIT;
                    end else begin
                        set_cmd(CMD_WRITE);
                        sdram_dqm <= ~byte_en;      // mask bytes not written
                        dq_out    <= wdata;
                        dq_oe     <= 1'b1;
                        state     <= S_WR_DONE;
                    end
                end
            end
            S_RD_WAIT: begin
                // Entered the cycle AFTER the READ command was issued. Dwell
                // until DQ is valid, then hand off to S_RD_DONE which samples.
                if (timer > 1) begin
                    timer <= timer - 1'b1;
                end else begin
                    state <= S_RD_DONE;
                end
            end
            S_RD_DONE: begin
                rdata <= sdram_dq;              // DQ valid & stable this cycle
                ack   <= 1'b1;
                timer <= T_RP[3:0];             // auto-precharge recovery
                state <= S_IDLE;
            end
            S_WR_DONE: begin
                // write data was presented with the WRITE command this-1 cycle;
                // auto-precharge follows internally. Ack now, recover in IDLE.
                ack   <= 1'b1;
                timer <= T_RP[3:0];
                state <= S_IDLE;
            end
            // ---------------- REFRESH ----------------
            S_REFRESH: begin
                if (timer != 0) timer <= timer - 1'b1;
                else state <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
