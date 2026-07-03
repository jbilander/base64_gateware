// ============================================================================
// fx68k_sys.sv — fx68k presented as a synchronous "propose cycle / complete
// cycle" CPU, for integration behind a tg68wrapper-style decode FSM.
//
// Contract (mirrors how the FSM consumes TG68, minus clkena weaving):
//   * cyc_req pulses high for exactly one sysclk when fx68k begins a bus
//     (sub-)cycle. addr/wr/ds/ifetch/wdata are stable from that clock until
//     cyc_done is pulsed.
//   * The system performs the access, then pulses cyc_done for one clock,
//     with rdata valid on that clock (reads). This asserts DTACK internally;
//     fx68k finishes the cycle and continues. Wait states are implicit —
//     fx68k idles in S4 as long as cyc_done hasn't arrived (its native
//     mechanism; nothing is frozen, no clkena pacing games).
//   * TAS (read-modify-write) arrives as TWO cyc_req events under one AS:
//     detection is strobe-based (UDS/LDS), not AS-based, on purpose.
//   * Interrupt acknowledge cycles are internally autovectored (VPA) by
//     default, matching the tg68wrapper setup (IPL_autovector semantics on
//     the Amiga: the motherboard autovectors via VPA — when this core sits
//     behind the bridge, the FSM never sees IACK cycles).
//
// The phase enables come either from the internal pacer (bench/turbo: one
// 68k cycle per 2*PACE sysclks) or externally from hostclocks (compat mode:
// 7M-phase-locked enPhi1/enPhi2) when USE_EXT_PHASES=1.
//
// NOTE: reset semantics follow fx68k: assert ext_reset_in (with pwr_up on
// coldstart) like RESET+HALT into a real 68000. reset_out mirrors the RESET
// instruction for cpu_req.reset-style plumbing (feedback loop avoided by
// the consumer, as in tg68wrapper).
// ============================================================================
`default_nettype none

module fx68k_sys #(
    parameter USE_EXT_PHASES = 0,
    parameter PACE = 2              // internal pacer: enables every PACE clocks
                                    // (PACE=2 -> Fcpu = sysclk/4)
) (
    input  wire        sysclk,
    input  wire        reset_n,      // system reset (like sm_reset)
    input  wire        pwr_up,       // asserted with reset on coldstart

    // External phase enables (compat mode), ignored unless USE_EXT_PHASES
    input  wire        ext_enphi1,
    input  wire        ext_enphi2,

    // Cycle interface to the decode/peripheral FSM
    output reg         cyc_req,      // 1-clock pulse: cycle proposed
    output wire [23:1] addr,
    output wire        wr,           // 1 = write
    output wire [1:0]  ds,           // {upper, lower} byte enables, active high
    output wire        ifetch,       // program-space access (FC[1:0]==2'b10)
    output wire [15:0] wdata,
    input  wire        cyc_done,     // 1-clock pulse: cycle complete
    input  wire [15:0] rdata,        // valid with cyc_done

    // Sideband
    input  wire [2:0]  ipl_n,        // active-low, raw from socket (synced here)
    output wire [2:0]  fc,
    output wire        reset_out,    // RESET instruction executing (active high)
    output wire        halted        // double bus fault
);

    // ---------------- phase enables ----------------
    reg [$clog2(PACE):0] pace_cnt;
    reg phase;                        // 0: next enable is phi1
    reg int_enphi1, int_enphi2;

    always @(posedge sysclk) begin
        int_enphi1 <= 1'b0;
        int_enphi2 <= 1'b0;
        if (pace_cnt == PACE-1) begin
            pace_cnt <= '0;
            phase    <= ~phase;
            int_enphi1 <= ~phase;
            int_enphi2 <=  phase;
        end else
            pace_cnt <= pace_cnt + 1'b1;
    end

    wire enphi1 = USE_EXT_PHASES ? ext_enphi1 : int_enphi1;
    wire enphi2 = USE_EXT_PHASES ? ext_enphi2 : int_enphi2;

    // ---------------- IPL sync ----------------
    reg [2:0] ipl_s0, ipl_s1;
    always @(posedge sysclk) begin
        ipl_s0 <= ipl_n;
        ipl_s1 <= ipl_s0;
    end

    // ---------------- fx68k ----------------
    wire        core_rw, core_as_n, core_lds_n, core_uds_n;
    wire        core_e, core_vma_n, core_bg_n;
    wire        core_fc0, core_fc1, core_fc2;
    wire        core_oreset_n, core_ohalted_n;
    wire [15:0] core_dout;
    wire [23:1] core_a;

    reg         dtack_n;
    reg  [15:0] rdata_hold;

    // Interrupt acknowledge cycles (FC=7, A19:16=F) are autovectored via VPA,
    // which on fx68k must be asserted during the IACK cycle. Behind the
    // bridge this is the right default; a real IACK forwarding path can be
    // added later if a vector-supplying expansion ever matters.
    wire iack_cycle = core_fc0 & core_fc1 & core_fc2 & ~core_as_n;
    wire vpa_n = ~iack_cycle;

    fx68k cpu (
        .clk      (sysclk),
        .HALTn    (1'b1),
        .extReset (~reset_n),
        .pwrUp    (pwr_up),
        .enPhi1   (enphi1),
        .enPhi2   (enphi2),

        .eRWn     (core_rw),
        .ASn      (core_as_n),
        .LDSn     (core_lds_n),
        .UDSn     (core_uds_n),
        .E        (core_e),
        .VMAn     (core_vma_n),
        .FC0      (core_fc0),
        .FC1      (core_fc1),
        .FC2      (core_fc2),
        .BGn      (core_bg_n),
        .oRESETn  (core_oreset_n),
        .oHALTEDn (core_ohalted_n),

        .DTACKn   (dtack_n),
        .VPAn     (vpa_n),
        .BERRn    (1'b1),            // as in tg68wrapper (berr tied off)
        .BRn      (1'b1),            // no arbitration behind the bridge
        .BGACKn   (1'b1),
        .IPL0n    (ipl_s1[0]),
        .IPL1n    (ipl_s1[1]),
        .IPL2n    (ipl_s1[2]),

        .iEdb     (rdata_hold),
        .oEdb     (core_dout),
        .eab      (core_a)
    );

    // ---------------- cycle extraction ----------------
    // Strobe-based, so TAS's two halves generate two requests under one AS.
    // For word/byte cycles strobes assert with (writes: after) AS; a request
    // fires on the first clock any strobe is low and no request is pending.
    wire strobe_active = ~(core_lds_n & core_uds_n) & ~iack_cycle;

    reg pending;   // request issued, waiting for cyc_done
    always @(posedge sysclk) begin
        cyc_req <= 1'b0;

        if (!reset_n) begin
            pending <= 1'b0;
            dtack_n <= 1'b1;
        end else begin
            if (strobe_active & ~pending & dtack_n) begin
                cyc_req <= 1'b1;
                pending <= 1'b1;
            end

            if (pending & cyc_done) begin
                rdata_hold <= rdata;
                dtack_n    <= 1'b0;     // terminate the cycle
                pending    <= 1'b0;
            end

            // Release DTACK when the strobes negate (end of this
            // (sub-)cycle; for TAS the read half's DTACK clears before
            // the write half raises its own request).
            if (~dtack_n & core_lds_n & core_uds_n)
                dtack_n <= 1'b1;
        end
    end

    assign addr      = core_a;
    assign wr        = ~core_rw;
    assign ds        = {~core_uds_n, ~core_lds_n};
    assign ifetch    = ~core_fc1 ? 1'b0 : ~core_fc0;   // FC[1:0]==2'b10
    assign wdata     = core_dout;
    assign fc        = {core_fc2, core_fc1, core_fc0};
    assign reset_out = ~core_oreset_n;
    assign halted    = ~core_ohalted_n;

endmodule
