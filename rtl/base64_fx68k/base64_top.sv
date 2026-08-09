// ============================================================================
// base64_top_6x.sv — Base64 carrier + iCESugar-Pro, TURBO MODE (6x = 42.6 MHz)
//
// fx68k runs at CPU_MULT x the motherboard 7M rate. Every cycle that has to
// reach the Amiga is re-issued by a BUS BRIDGE (BIU) that reproduces a real
// 68000 S0..S7 bus cycle on the 7M grid. The core is held in wait states
// (DTACK withheld) until the bridge completes.
//
// ARCHITECTURAL NOTE — THIS IS NOT A CLOCK DOMAIN CROSSING.
//   There is exactly ONE clock in this design: clk_12x. The 7M "domain" is a
//   set of clock enables derived from a divide-by-12 counter that is phase-
//   locked to the motherboard 7M. The fast CPU "domain" is another set of
//   enables (clk/2). Handshakes between them are ordinary synchronous logic:
//   no metastability, no gray coding, no request/ack synchronisers. The only
//   true asynchronous inputs are the motherboard pins (DTACK/VPA/BERR/BR/
//   BGACK/IPL/RESET/HALT and the 7M clock itself), which are the only places
//   that need 2FF synchronisers.
//
// WHAT CHANGED vs THE 1x BUILD (all of these silently break at 6x):
//   1. E is generated HERE at 7M/10 (6 low / 4 high). The core's own E runs
//      CPU_MULT times too fast and is discarded.
//   2. VPA/VMA 6800-style cycles are run by the bridge against OUR E, not by
//      the core. The core's VPAn is tied deasserted.
//   3. IACK cycles terminate with DTACK + autovector number (24+level), which
//      is behaviourally identical to a VPA autovector but needs no E timing.
//   4. The RESET instruction is stretched to >=124 * 141 ns. At 6x the core
//      only holds oRESETn for ~2.9 us, which is too short to reset the CIAs.
//   5. IPL is re-sampled on the 7M grid with a 2-of-2 filter. At 6x the
//      core's own two-sample debounce window shrinks to 47 ns and would latch
//      Paula's INTREQ update glitches.
//   6. BG is retimed onto the 7M grid.
//   7. The bridge, not the core, owns the physical pins (latched address /
//      data / strobes), because the core moves on as soon as it is acked.
//
// PHASE_OFS is KEPT and now has a physical meaning: it aligns our internal
// notion of the 7M rising edge with the real one at Gary/Agnus, absorbing the
// 74LVC1G17 delay, the FPGA input path, the capture pipeline and the output
// path. See DESIGN_NOTES_6x.md for the budget.
//
// Pairs with base64_6x.fdc. Toolchain: Diamond / Synplify Pro.
// fx68k ports match UPSTREAM ijor/fx68k (no E_rise/E_fall, eab[23:1]).
// SDRAM, the turbomem ROM board and the SD card device are all live. The
// autoconfig chain is cfgin -> fastmem -> turbomem -> SD -> cfgout.
// ============================================================================
`default_nettype none

module base64_top #(
    // ---- speed ----------------------------------------------------------
    // 12 master clocks per 7M period. CPU_MULT must divide 12 evenly:
    //   6 -> 2 master clocks/CPU clock (42.6 MHz)  <-- target
    //   4 -> 3, 3 -> 4, 2 -> 6, 1 -> 12 (bit-identical to the old build)
    // See DESIGN_NOTES: only CPU_MULT<=3 relaxes the fx68k Fmax requirement.
    parameter integer CPU_MULT   = 6,

    // ---- 7M grid alignment ----------------------------------------------
    // Larger PHASE_OFS moves our S-state grid EARLIER relative to the real
    // 7M edge, in 11.75 ns steps. Calibrate once (see notes), then leave it.
    parameter integer PWRUP_BIT  = 23,   // sim override only
    parameter [4:0]   PHASE_OFS  = 5'd2,

    // Master clocks between the nominal S4 falling edge and the instant we
    // read the 2FF-synchronised DTACK/VPA/BERR. Set equal to the synchroniser
    // depth (2) so the value we act on is the pin value AT the S4 falling
    // edge — i.e. exactly the sample point of a real 68000.
    // DTACK_LAT positions the sample point. SMP_N master clocks after the
    // S5 tick we read s_dtack_n[1], which lags the pin by 2 -- so DTACK_LAT=2
    // acts on the pin value exactly AT S5, a real 68000's sample point.
    //
    // But a real 68000 drives AS straight off its internal grid, whereas our
    // AS goes out through a pin register, the output buffer (SLEWRATE=SLOW)
    // and a CBTD FET: measured 35.2 ns, i.e. 3 master clocks. Gary's DTACK
    // comes back that much later, so our sample point has to move with it.
    // Hence 2 (synchroniser) + 3 (our AS output delay) = 5, and 4 already
    // recovers the clock in simulation.
    //
    // This is the knob PHASE_OFS cannot substitute for: PHASE_OFS slides the
    // whole grid, moving AS and the sample point together, which is exactly
    // why PHASE_OFS 1 and 2 measured identically on hardware. DTACK_LAT is
    // the only parameter that moves the sample point RELATIVE to AS.
    //
    // Sweep 2..6 and watch LAT_DEBUG: 5 blinks = losing a clock, 4 = fixed.
    // Do not exceed 6 -- the sample must land before the S6 tick.
    parameter integer DTACK_LAT  = 4,

    // Master clocks by which the core's DTACK leads the bridge's data-latch
    // edge. 1 is derived in the notes; 2 buys margin for back-to-back cycles
    // at the cost of nothing. MUST be >=1 and <=5.
    parameter integer ACK_LEAD   = 2,
    // EXPERIMENTAL, DEFAULT OFF -- acking the core the moment DTACK is
    // stable rather than at tick_ack. This is the right IDEA (see the
    // ST_S6 comment) but this implementation is WRONG: Verilator against
    // the real core drops from 50 loop iterations to 1, i.e. the core goes
    // off the rails. Acking this early makes the core negate AS while the
    // bridge is still in S6/S7, and the ack-clear path then races the
    // FSM. Needs the request/ack handshake reworked, not a parameter.
    // EARLY_ACK: DEAD END, leave at 0. Measured, not guessed.
    //
    // The idea was to ack the core as soon as DTACK is stable so it could
    // turn its next cycle around inside our S5/S6/S7. It works in a model
    // where the slave drives read data for the whole of AS-low, and it
    // green-screens real hardware, because real slaves assert DTACK BEFORE
    // the data is on the bus. A 68000 tolerates that: it latches at S7,
    // ~141 ns after DTACK. Acking early collapses that margin to a few
    // master clocks -- at 6x we destroy the exact safety margin the 68000
    // bus protocol is built around.
    //
    // Simulated against the real core, with DTACK at AS+294 ns (as
    // captured on hardware) and data valid only at AS+400 ns:
    //     EARLY_ACK=0 -> 50 loop iterations, clean
    //     EARLY_ACK=1 ->  0 loop iterations, dead
    // Restricting it to writes only is safe but measured no gain at all
    // (34 iterations either way), so it is not worth the complexity.
    // RETIME: 0 = bridge (re-synthesised S0..S7), 1 = SF2000-style
    // pass-through with the core's strobes gated onto the 7M grid.
    parameter         RETIME     = 1'b1,
    parameter         EARLY_ACK  = 1'b0,
    parameter         DBG_BUNDLE = 1'b0,   // debug done -- keep 0 now

    // e_cnt value at which VMA is asserted during a 6800 cycle. E is low for
    // e_cnt 0..5, high for 6..9, so 1 gives ~700 ns of VMA setup before E
    // rises. Anything in 0..3 is safe.
    parameter [3:0]   E_VMA_AT   = 4'd1,

    // 1 = terminate IACK cycles internally with 24+level (recommended).
    parameter         IACK_AV    = 1'b1,

    // 1 = green LED blinks the shortest observed external cycle length in 7M
    // clocks (4 = no wait states, 5 = one wait state, ...).
    parameter         LAT_DEBUG  = 1'b0
)(
    // Clocks from carrier
    input  wire        clk_7m,        // C7  buffered motherboard 7M (74LVC1G17)
    input  wire        clk_12x,       // L1  ICS570B x12 (85.1 MHz, PLL-locked)

    // 68000 socket (3.3V side of the CBTD switches)
    output wire [23:1] cpu_a,
    inout  wire [15:0] cpu_d,
    output wire        cpu_as_n,
    output wire        cpu_uds_n,
    output wire        cpu_lds_n,
    output wire        cpu_rw,        // 1 = read
    output wire [2:0]  cpu_fc,
    output wire        cpu_vma_n,
    output wire        cpu_e,         // free-running E, never tri-stated
    output wire        cpu_bg_n,
    input  wire        cpu_dtack_n,
    input  wire        cpu_vpa_n,
    input  wire        cpu_berr_n,
    input  wire        cpu_br_n,
    input  wire        cpu_bgack_n,
    input  wire [2:0]  cpu_ipl_n,
    inout  wire        cpu_reset_n,   // open-drain bidirectional
    inout  wire        cpu_halt_n,    // open-drain bidirectional

    // Autoconfig daisy chain (J2). CFGIN jumpered to GND = first in chain.
    input  wire        cfgin_n,
    output wire        cfgout_n,

    // CBT switch output enables (active low = connected). U5/U6 hardwired on.
    output wire        cbt_oe_d0_7_n,
    output wire        cbt_oe_d8_15_n,
    output wire        cbt_oe_ctl_hi_n,
    output wire        cbt_oe_a8_17_n,
    output wire        cbt_oe_a1_7_n,

    // Idled in turbo bring-up (ports kept so base64.lpf is unchanged)
    output wire [12:0] sdram_a,   // driven by sdram_ctrl
    output wire [1:0]  sdram_ba,
    inout  wire [15:0] sdram_dq,
    output wire [1:0]  sdram_dqm,
    output wire        sdram_clk,
    output wire        sdram_cke,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire        sdram_cs_n,
    output wire        sd_clk,
    inout  wire        sd_cmd,
    inout  wire [3:0]  sd_d,

    output wire        led_r,
    output wire        led_g,
    output wire        led_b
);

    wire clk = clk_12x;

    // Master clocks per emulated CPU clock period, and the phi2 offset.
    // Sized localparams throughout: part-selecting an `integer` parameter is
    // legal SV but not portable across synthesis front ends.
    // CLK_MULT is the ICS570B multiplier on the incoming 7M. It is a
    // parameter only so the 24x experiment is a one-line change -- but read
    // DESIGN_NOTES_6x.md before raising it: doubling the master clock does
    // NOT buy fx68k any settling time, it only makes STA harder. The real
    // lever is the multicycle constraints in base64_6x.fdc.
    localparam integer CLK_MULT = 12;
    localparam [4:0] PH_TOP = CLK_MULT[4:0] - 5'd1;      // counter wrap
    localparam [4:0] PH_HALF= CLK_MULT[4:0] / 5'd2;      // "falling edge"
    localparam [4:0] MC4    = CLK_MULT[4:0] / CPU_MULT;      // 2,3,4,6,12
    localparam [4:0] MCH4   = (CLK_MULT[4:0] / CPU_MULT) / 5'd2;
    localparam [4:0] PH_ACK = PH_HALF - ACK_LEAD;
    localparam [2:0] SMP_N  = DTACK_LAT;
    // CPU_MULT must divide CLK_MULT evenly and give an even MC4.

    // ========================================================================
    // 1. Power-up hold
    // ========================================================================
    // ~98 ms after configuration before the core's first fetch: rails,
    // ICS570B lock and the Amiga's own POR are all settled. Runs once per
    // FPGA configuration; warm resets are unaffected.
    // NOTE (cold boot): see DESIGN_NOTES — the robust fix is to make the FPGA
    // the reset SOURCE at the end of this hold rather than relying on the
    // board is expected to come up on a warm reset (Ctrl-A-A) during bring-up.
    // PWRUP_BIT is a parameter purely so simulation can shorten the ~98 ms
    // hold. Do not lower it in a real build.
    reg  [23:0] pwrup_cnt = 24'd0;
    wire        pwrup_done = pwrup_cnt[PWRUP_BIT];
    always @(posedge clk)
        if (!pwrup_done) pwrup_cnt <= pwrup_cnt + 24'd1;

    // ========================================================================
    // 2. Asynchronous input synchronisers (the ONLY real CDC in the design)
    // ========================================================================
    reg [1:0] s_dtack_n, s_vpa_n, s_berr_n, s_br_n, s_bgack_n;
    reg [1:0] s_reset_n, s_halt_n, s_cfgin_n, s_7m;
    reg [2:0] s_ipl_a, s_ipl_b;

    // 7M capture hardening: the ICS570B is a zero-delay multiplier, so 7M
    // edges arrive coincident with clk_12x edges. Sampling on the FALLING
    // edge puts the sample 5.86 ns away from that coincidence — far outside
    // routing variation — making the captured cycle deterministic across
    // builds and seeds. (This is why PHASE_OFS stopped moving between builds.)
    reg s_7m_fall;
    always @(negedge clk) s_7m_fall <= clk_7m;

    reg s_7m_d;
    always @(posedge clk) begin
        s_dtack_n <= {s_dtack_n[0], cpu_dtack_n};
        s_vpa_n   <= {s_vpa_n[0],   cpu_vpa_n};
        s_berr_n  <= {s_berr_n[0],  cpu_berr_n};
        s_br_n    <= {s_br_n[0],    cpu_br_n};
        s_bgack_n <= {s_bgack_n[0], cpu_bgack_n};
        s_reset_n <= {s_reset_n[0], cpu_reset_n};
        s_halt_n  <= {s_halt_n[0],  cpu_halt_n};
        s_cfgin_n <= {s_cfgin_n[0], cfgin_n};
        s_7m      <= {s_7m[0],      s_7m_fall};
        s_ipl_a   <= cpu_ipl_n;
        s_ipl_b   <= s_ipl_a;
        s_7m_d    <= s_7m[1];
    end
    wire edge_7m = s_7m[1] & ~s_7m_d;

    // ========================================================================
    // 3. 7M grid: divide-by-12, phase-locked, GLITCH IMMUNE
    // ========================================================================
    // The old code reloaded ph_cnt on EVERY 7M edge. With a locked ICS570B
    // that reload is a no-op, but a single jittery or noisy edge would jump
    // the counter — and if the CPU phases were derived from it, that jump
    // would emit two consecutive enPhi1 (or swallow one) and corrupt fx68k.
    // Here the counter free-runs and only hard-reloads after SLIP_TOL
    // consecutive disagreements, i.e. a genuine PLL slip rather than noise.
    // The CPU phase generator (section 4) is independent of it regardless.
    localparam integer SLIP_TOL = 3;

    reg [4:0] ph        = 5'd0;
    reg [1:0] slip_cnt  = 2'd0;
    reg       ph_locked = 1'b0;
    reg       ph_slip   = 1'b0;     // sticky, for LED/Reveal

    always @(posedge clk) begin
        ph <= (ph == PH_TOP) ? 5'd0 : ph + 5'd1;
        if (edge_7m) begin
            if (ph == PHASE_OFS) begin
                slip_cnt  <= 2'd0;
                ph_locked <= 1'b1;
            end else begin
                if (!ph_locked) begin
                    ph <= PHASE_OFS;                 // initial acquisition
                end else if (slip_cnt == SLIP_TOL[1:0]) begin
                    ph       <= PHASE_OFS;           // real slip: re-acquire
                    slip_cnt <= 2'd0;
                    ph_slip  <= 1'b1;
                end else begin
                    slip_cnt <= slip_cnt + 2'd1;     // noise: ignore
                end
            end
        end
    end

    // The two 7M half-clock ticks, and the early tick used to lead the ack.
    wire tick_r   = (ph == 5'd0);      // "rising edge of 7M"  -> S0,S2,S4,S6
    wire tick_f   = (ph == PH_HALF);      // "falling edge of 7M" -> S1,S3,S5,S7
    wire tick_ack = (ph == PH_ACK);    // tick_f minus ACK_LEAD master clocks

    // ========================================================================
    // 4. CPU phase generator — FREE RUNNING, decoupled from the 7M resync
    // ========================================================================
    // Exactly clk/MC, so the emulated CPU clock is exactly CPU_MULT x 7M.
    // Deliberately NOT reloaded by edge_7m: the core does not need to be
    // phase-aligned to the bus any more (the bridge is), and a reload could
    // break the strict phi1/phi2 alternation fx68k requires.
    reg [4:0] cpu_ph = 5'd0;
    always @(posedge clk)
        cpu_ph <= (cpu_ph == MC4 - 5'd1) ? 5'd0 : cpu_ph + 5'd1;

    wire en_phi1 = (cpu_ph == 4'd0);
    wire en_phi2 = (cpu_ph == MCH4);

    // ========================================================================
    // 5. E clock — 7M/10, six low then four high. NEVER tri-stated.
    // ========================================================================
    reg  [3:0] e_cnt = 4'd0;
    reg        e_pin = 1'b0;
    wire [3:0] e_nxt = (e_cnt == 4'd9) ? 4'd0 : e_cnt + 4'd1;
    always @(posedge clk) if (tick_r) begin
        e_cnt <= e_nxt;
        e_pin <= (e_nxt >= 4'd6);
    end
    wire e_fall_tick = tick_r & (e_cnt == 4'd9);   // E goes low on this tick

    // ========================================================================
    // 6. IPL: re-pace onto the 7M grid with a 2-of-2 stability filter
    // ========================================================================
    reg [2:0] ipl_g1 = 3'b111, ipl_g2 = 3'b111, ipl_out = 3'b111;
    always @(posedge clk) if (tick_r) begin
        ipl_g1 <= s_ipl_b;
        ipl_g2 <= ipl_g1;
        if (ipl_g1 == ipl_g2) ipl_out <= ipl_g1;
    end

    // ========================================================================
    // 7. Reset / halt
    // ========================================================================
    wire core_oreset_n, core_ohalted_n;

    // Stretch the RESET instruction to >=124 real 7M clocks (~17.5 us).
    localparam [7:0] RST_HOLD_7M = 8'd132;
    reg        rst_stretch = 1'b0;
    reg  [7:0] rst_cnt     = 8'd0;
    always @(posedge clk) begin
        if (!pwrup_done) begin
            rst_stretch <= 1'b0;
            rst_cnt     <= 8'd0;
        end else if (!core_oreset_n) begin
            rst_stretch <= 1'b1;
            rst_cnt     <= 8'd0;
        end else if (rst_stretch && tick_r) begin
            if (rst_cnt >= RST_HOLD_7M) rst_stretch <= 1'b0;
            else                        rst_cnt <= rst_cnt + 8'd1;
        end
    end

    // ------------------------------------------------------------------
    // /RESET and /HALT are SEPARATE nets on this board, which lets us use
    // real 68000 semantics and delete two hacks that the shared-net
    // assumption had forced:
    //
    //   * The 68000 resets from outside ONLY when /RESET and /HALT are
    //     asserted TOGETHER. A RESET instruction drives /RESET alone, so it
    //     cannot reset us -- no "ignore external reset while we drive it"
    //     guard is needed, and the old we_drive_rst mask is gone. If the
    //     user hits Ctrl-A-A midway through our stretch, /HALT goes low too
    //     and we reset, which is exactly correct.
    //
    //   * The halt watchdog is deleted. It existed to catch a missed cold
    //     boot; warm boot is the agreed bring-up path for now. Nothing
    //     auto-resets the machine any more, so a genuine double bus fault
    //     now HALTS and stays halted -- which is what a real 68000 does and
    //     is far easier to debug than a box that silently reboots itself.
    //     The red LED reports it (section 12).
    // ------------------------------------------------------------------
    wire ext_reset = (~s_reset_n[1] & ~s_halt_n[1]) | ~pwrup_done;

    // Open-drain, and strictly independent: we never drive /HALT because of
    // a RESET instruction, and never drive /RESET because of a halt.
    assign cpu_reset_n = (~core_oreset_n | rst_stretch) ? 1'b0 : 1'bz;
    assign cpu_halt_n  = (~core_ohalted_n)              ? 1'b0 : 1'bz;

    // ========================================================================
    // 8. fx68k core
    // ========================================================================
    wire        core_rw, core_as_n, core_lds_n, core_uds_n;
    wire        core_e_unused, core_vma_n_unused;
    wire        core_fc0, core_fc1, core_fc2;
    wire        core_bg_n;
    wire [15:0] core_dout;
    // Full 32-bit internal address. The fork drives eab[31:1]; the previous
    // [23:1] declaration silently DISCARDED A24..A31, which is fine for a
    // 68000 socket (it has no such pins) but makes anything above 16 MB --
    // Zorro III space, a mapROM shadow region -- impossible to decode.
    //
    // Everything bound for the physical bus still truncates to [23:1], which
    // is exactly what a real 68000 does. Only the INTERNAL decode sees the
    // full width.
    wire [31:1] core_a;

    reg         core_dtack_lo = 1'b0;
    reg         core_berr_lo  = 1'b0;
    reg  [15:0] rd_data       = 16'hFFFF;
    reg         av_valid      = 1'b0;
    reg  [7:0]  av_num        = 8'd0;

    // REATTACH: internal slaves (autoconfig / SD / fastmem) mux in here.
    wire [15:0] core_iedb  =
          fm_ac_oe ? {fm_ac_dout, 12'hFFF}
        : tm_ac_oe ? {tm_ac_dout, 12'hFFF}
        : sd_ac_oe ? {sd_ac_dout, 12'hFFF}
        : fm_space ? fm_dout
        : tm_space ? tm_dout
        : sd_space ? sd_dout
        : RETIME   ? (rt_av ? {8'h00, av_num} : rt_rd)
                   : (av_valid ? {8'h00, av_num} : rd_data);
    wire        int_dtack_lo  = ~fm_dtack_n | ~fm_ac_dtack_n
                              | ~tm_dtack_n | ~tm_ac_dtack_n
                              | ~sd_dtack_n | ~sd_ac_dtack_n;
    wire        core_dtack_n = ~((RETIME ? rt_dtack_lo : core_dtack_lo)
                                 | int_dtack_lo);
    wire        core_berr_n  = ~core_berr_lo;

    fx68k cpu (
        .clk      (clk),
        .enPhi1   (en_phi1),
        .enPhi2   (en_phi2),
        .HALTn    (s_halt_n[1] | ~core_ohalted_n),   // mask our own drive only
        .extReset (ext_reset),
        .pwrUp    (~pwrup_done),
        .oRESETn  (core_oreset_n),
        .oHALTEDn (core_ohalted_n),
        .E        (core_e_unused),      // 6x too fast — discarded, see sec.5
        .VPAn     (1'b1),               // bridge owns all 6800 cycles
        .VMAn     (core_vma_n_unused),
        .ASn      (core_as_n),
        .eRWn     (core_rw),
        .LDSn     (core_lds_n),
        .UDSn     (core_uds_n),
        .FC2      (core_fc2),
        .FC1      (core_fc1),
        .FC0      (core_fc0),
        .DTACKn   (core_dtack_n),
        .BERRn    (core_berr_n),
        .BRn      (s_br_n[1]),
        .BGn      (core_bg_n),
        .BGACKn   (s_bgack_n[1]),
        .IPL2n    (ipl_out[2]),
        .IPL1n    (ipl_out[1]),
        .IPL0n    (ipl_out[0]),
        .iEdb     (core_iedb),
        .oEdb     (core_dout),
        .eab      (core_a)
    );

    wire [2:0] core_fc = {core_fc2, core_fc1, core_fc0};

    // ========================================================================
    // 9. Bus ownership
    // ========================================================================
    reg  bg_pin_n = 1'b1;
    always @(posedge clk) if (tick_r) bg_pin_n <= core_bg_n;   // retime to 7M

    reg  p_as_n = 1'b1;
    wire bx_idle;
    // A real 68000 asserts /BG when /BR arrives but KEEPS USING THE BUS
    // until the requester asserts /BGACK. The old condition also released
    // on (~bg_pin_n & p_as_n & bx_idle), i.e. as soon as /BG went out and
    // we happened to be idle. Verified in Verilator against the real core:
    // holding /BR low with that condition deadlocks the bridge completely
    // -- zero bus cycles, machine dead, not merely slow. Any device that
    // parks /BR low, or a floating /BR, would hang the accelerator.
    wire bus_released = ~s_bgack_n[1];
    wire bus_owned    = ~bus_released;

    // ========================================================================
    // 10. THE BRIDGE (BIU)
    // ========================================================================
    // Reproduces a real 68000 bus cycle on the 7M grid:
    //   S0 (r) FC + R/W high        S1 (f) address valid
    //   S2 (r) AS low, read DS low  S3 (f) write data driven
    //   S4 (r) write DS low         S5 (f) <- DTACK/VPA/BERR sample point
    //   S6 (r)                      S7 (f) latch read data, AS/DS high
    // Wait states loop S5<->S6 in whole 7M periods, exactly like Sw pairs.
    // Cycles chain S7->S0 with no bubble, so external throughput is identical
    // to a stock 68000; only the CPU's internal states run CPU_MULT faster.
    localparam [3:0] ST_IDLE = 4'd0,  ST_S0   = 4'd1,  ST_S1   = 4'd2,
                     ST_S2   = 4'd3,  ST_S3   = 4'd4,  ST_S4   = 4'd5,
                     ST_S5   = 4'd6,  ST_S6   = 4'd7,  ST_S7   = 4'd8,
                     ST_VPAW = 4'd9,  ST_VPAE = 4'd10, ST_VPAH = 4'd11,
                     ST_VPAX = 4'd12;

    reg [3:0] st = ST_IDLE;
    assign bx_idle = (st == ST_IDLE);

    // Latched shadow of the core's cycle
    reg [23:1] bx_a;
    reg [2:0]  bx_fc;
    reg        bx_rw, bx_uds_n, bx_lds_n, bx_iack;

    // Physical pin registers (pack these into IOB — see .fdc / LPF notes)
    reg [23:1] p_a     = 23'd0;
    reg [2:0]  p_fc    = 3'd0;
    reg        p_rw    = 1'b1;
    reg        p_uds_n = 1'b1;
    reg        p_lds_n = 1'b1;
    reg        p_vma_n = 1'b1;
    reg [15:0] p_d     = 16'd0;
    reg        p_d_oe  = 1'b0;

    // Sample machinery
    reg [2:0] smp_cnt = 3'd0;
    reg       term    = 1'b0;   // this cycle may complete
    reg       sync_go = 1'b0;   // ... as a 6800 (VPA) cycle instead
    reg       berr_go = 1'b0;

    // ---- Request tracking ----------------------------------------------
    // bx_req is a LEVEL on the core's AS, and the address/FC/RW snapshot is
    // taken from the core's live outputs when the bridge starts the cycle.
    // That is safe only because the core is still stalled waiting for our
    // DTACK at that moment.
    //
    // An edge-captured 1-deep request queue was tried, to allow acking the
    // core early. It was REVERTED: R/W goes low at S2 and the data strobes
    // at S4, so a snapshot taken on the AS falling edge is stale and writes
    // go out as reads -- a green screen on the Chip RAM test. If you revisit
    // this, capture R/W and UDS/LDS continuously, not once.

    // One ack per BRIDGE cycle. core_dtack_lo alone is not enough: the core
    // negates AS (clearing it), re-asserts for its next cycle, and the early
    // ack condition would then fire again while the bridge is still finishing
    // the PREVIOUS cycle -- acking a request it has not started, with garbage
    // read data. Cleared at consume, not at the core's AS edge.
    reg        bx_acked = 1'b0;
    reg        bx_taken = 1'b0;

    wire bx_req   = ~core_as_n & ~bx_taken;
    wire bx_start = tick_r & bx_req & bus_owned;

    wire [7:0] av_of_level = 8'd24 + {5'd0, core_a[3:1]};

    always @(posedge clk) begin
        if (ext_reset) begin
            st       <= ST_IDLE;
            p_as_n   <= 1'b1;
            p_uds_n  <= 1'b1;
            p_lds_n  <= 1'b1;
            p_vma_n  <= 1'b1;
            p_rw     <= 1'b1;
            p_d_oe   <= 1'b0;
            smp_cnt  <= 3'd0;
            term     <= 1'b0;
            sync_go  <= 1'b0;
            berr_go  <= 1'b0;
            bx_taken <= 1'b0;
            bx_acked <= 1'b0;
            core_dtack_lo <= 1'b0;
            core_berr_lo  <= 1'b0;
            av_valid      <= 1'b0;
        end else begin
            // ---- the core has finished with this cycle -------------------
            // Core-facing DTACK/BERR are held until the core drops its own
            // AS, exactly as a real slave does. (Must live in THIS block:
            // core_dtack_lo is also written by the FSM below, and a second
            // always block driving it would be a multiple-driver error.)
            // Edge, not level: with the early ack the core can negate and
            // re-assert AS inside one of our bus cycles, and a level test
            // would clear the new cycle's ack as well as the old one's.
            if (core_as_n) begin
                bx_taken      <= 1'b0;
                core_dtack_lo <= 1'b0;
                core_berr_lo  <= 1'b0;
                av_valid      <= 1'b0;
            end

            // ---- read data capture ---------------------------------------
            // rd_data TRACKS the bus for as long as the slave is driving it
            // and FREEZES the instant AS negates. The core therefore latches
            // the value the slave presented at the end of the cycle no matter
            // which master clock it happens to latch on. This is what makes
            // ACK_LEAD > 1 safe: without it, acking the core early would let
            // it sample iEdb before the bridge had captured anything.
            // Track for as long as WE hold AS asserted, not just in S6. With
            // the early ack the core can latch iEdb before S6, and a 68000
            // slave guarantees data valid once it asserts DTACK, so the live
            // bus is the right thing to present. Still freezes at AS negation.
            if (bx_rw && ((st == ST_S6) || (st == ST_VPAE && e_pin)))
                rd_data <= cpu_d;

            // ---- delayed sample of the motherboard's response ------------
            // Reading the 2FF output DTACK_LAT clocks after the nominal S4
            // falling edge means we act on the pin value AT that edge: the
            // exact sample point of a real 68000.
            if (smp_cnt != 3'd0) begin
                smp_cnt <= smp_cnt - 3'd1;
                if (smp_cnt == 3'd1) begin
                    if (!s_berr_n[1]) begin
                        berr_go <= 1'b1; term <= 1'b1;
                    end else if (!s_dtack_n[1]) begin
                        term <= 1'b1;
                    end else if (!s_vpa_n[1]) begin
                        // Gary asserts VPA for CIA space AND for FC=7 (IACK).
                        // CIA space -> real 6800 cycle against our E.
                        // IACK      -> terminate here with vector 24+level,
                        //              which is behaviourally identical to a
                        //              VPA autovector but needs no E timing
                        //              and touches no 6800 peripheral. If a
                        //              Zorro card had supplied DTACK + a real
                        //              vector we would already have taken the
                        //              branch above, so vectored interrupts
                        //              still work.
                        if (bx_iack && IACK_AV) begin
                            term     <= 1'b1;
                            av_valid <= 1'b1;
                        end else begin
                            sync_go  <= 1'b1;
                        end
                    end
                end
            end

            case (st)
            // ---------------------------------------------------------------
            ST_IDLE: if (bx_start) begin
                        p_fc     <= core_fc;
                        p_rw     <= 1'b1;            // S0: R/W high
                        bx_a     <= core_a[23:1];
                        bx_fc    <= core_fc;
                        bx_rw    <= core_rw;
                        bx_uds_n <= core_uds_n;
                        bx_lds_n <= core_lds_n;
                        bx_iack  <= (core_fc == 3'b111);
                        av_num   <= av_of_level;
                        av_valid <= 1'b0;
                        term     <= 1'b0;
                        sync_go  <= 1'b0;
                        berr_go  <= 1'b0;
                        bx_taken <= 1'b1;
                        bx_acked <= 1'b0;
                        st       <= ST_S0;
                     end
            // ---------------------------------------------------------------
            ST_S0:  if (tick_f) begin
                        p_a <= bx_a;                 // S1: address valid
                        st  <= ST_S1;
                    end
            ST_S1:  if (tick_r) begin
                        p_as_n <= 1'b0;              // S2: AS low
                        p_rw   <= bx_rw;
                        if (bx_rw) begin
                            p_uds_n <= bx_uds_n;     // reads strobe with AS
                            p_lds_n <= bx_lds_n;
                        end
                        st <= ST_S2;
                    end
            ST_S2:  if (tick_f) begin
                        if (!bx_rw) begin            // S3: drive write data
                            p_d    <= core_dout;
                            p_d_oe <= 1'b1;
                        end
                        st <= ST_S3;
                    end
            ST_S3:  if (tick_r) begin
                        if (!bx_rw) begin            // S4: writes strobe late
                            p_uds_n <= bx_uds_n;
                            p_lds_n <= bx_lds_n;
                        end
                        st <= ST_S4;
                    end
            ST_S4:  if (tick_f) begin                // this IS the S4 fall
                        smp_cnt <= SMP_N;
                        st      <= ST_S5;
                    end
            ST_S5:  begin
                        if (EARLY_ACK && !bx_rw && !bx_iack && s_berr_n[1] && s_vpa_n[1]
                            && !s_dtack_n[1] && !bx_acked) begin
                            core_dtack_lo <= 1'b1;
                            bx_acked      <= 1'b1;
                        end
                        if (tick_r) st <= ST_S6;
                    end
            // ---------------------------------------------------------------
            ST_S6:  begin
                        // Lead the data latch so the core has negated and
                        // re-asserted its AS by our next tick_r -> no bubble.
                        if (tick_ack && term && !bx_acked) begin
                            if (berr_go) core_berr_lo  <= 1'b1;
                            else         core_dtack_lo <= 1'b1;
                            bx_acked <= 1'b1;
                        end
                        // EARLY_ACK: hardware capture (debug_ws.vcd) showed
                        // the core needs ~16 master clocks from our ack to
                        // re-asserting AS. Acking at tick_ack leaves only 8
                        // before the S7 tick_r, so bx_req misses the chain
                        // window and we sit a whole 7M period in ST_IDLE.
                        // Even ACK_LEAD=6 only buys 4 of the 9 clocks needed.
                        // Once DTACK is stable the cycle WILL complete, so
                        // there is nothing to gain by making the core wait
                        // for our S-state bookkeeping.
                        if (EARLY_ACK && !bx_rw && !bx_iack && s_berr_n[1] && s_vpa_n[1]
                            && !s_dtack_n[1] && !bx_acked) begin
                            core_dtack_lo <= 1'b1;
                            bx_acked      <= 1'b1;
                        end
                        if (tick_f) begin
                            if (term) begin
                                p_as_n  <= 1'b1;   // rd_data froze above
                                p_uds_n <= 1'b1;
                                p_lds_n <= 1'b1;
                                st      <= ST_S7;
                            end else if (sync_go) begin
                                st <= ST_VPAW;
                            end else begin
                                smp_cnt <= SMP_N;     // Sw pair
                                st      <= ST_S5;
                            end
                        end
                    end
            // ---------------------------------------------------------------
            ST_S7:  if (tick_r) begin
                        p_rw   <= 1'b1;              // R/W + data held 70 ns
                        p_d_oe <= 1'b0;              // past AS negation
                        if (bx_req && bus_owned) begin
                            p_fc     <= core_fc;
                            bx_a     <= core_a[23:1];
                            bx_fc    <= core_fc;
                            bx_rw    <= core_rw;
                            bx_uds_n <= core_uds_n;
                            bx_lds_n <= core_lds_n;
                            bx_iack  <= (core_fc == 3'b111);
                            bx_taken <= 1'b1;
                            bx_acked <= 1'b0;
                            av_num   <= av_of_level;
                            av_valid <= 1'b0;
                            term     <= 1'b0;
                            sync_go  <= 1'b0;
                            berr_go  <= 1'b0;
                            st       <= ST_S0;       // chain, no bubble
                        end else begin
                            st <= ST_IDLE;
                        end
                    end
            // ---------------------------------------------------------------
            // 6800-style synchronous cycle, run against OUR 709 kHz E.
            // AS stays low throughout, exactly as on a real 68000.
            ST_VPAW: if (tick_r && (e_cnt == E_VMA_AT)) begin
                        p_vma_n <= 1'b0;             // E low, ~700 ns before rise
                        st      <= ST_VPAE;
                     end
            ST_VPAE: begin
                        if (tick_ack && (e_cnt == 4'd9)) core_dtack_lo <= 1'b1;
                        if (tick_f   && (e_cnt == 4'd9)) st <= ST_VPAH;
                     end
            ST_VPAH: if (e_fall_tick) st <= ST_VPAX;        // E falls now
            ST_VPAX: if (tick_f) begin                      // 70 ns of hold
                        p_vma_n <= 1'b1;
                        p_as_n  <= 1'b1;
                        p_uds_n <= 1'b1;
                        p_lds_n <= 1'b1;
                        st      <= ST_S7;
                     end
            default: st <= ST_IDLE;
            endcase

        end
    end

    // ========================================================================
    // 11. Pin drivers
    // ========================================================================
    assign cpu_a     = bus_owned ? (RETIME ? rt_a     : p_a)     : 23'bz;
    assign cpu_as_n  = bus_owned ? (RETIME ? rt_as_n  : p_as_n)  : 1'bz;
    assign cpu_uds_n = bus_owned ? (RETIME ? rt_uds_n : p_uds_n) : 1'bz;
    assign cpu_lds_n = bus_owned ? (RETIME ? rt_lds_n : p_lds_n) : 1'bz;
    assign cpu_rw    = bus_owned ? (RETIME ? rt_rw    : p_rw)    : 1'bz;
    assign cpu_fc    = bus_owned ? (RETIME ? rt_fc    : p_fc)    : 3'bz;
    assign cpu_vma_n = bus_owned ? (RETIME ? rt_vma_n : p_vma_n) : 1'bz;
    assign cpu_d     = RETIME ? ((bus_owned & rt_d_oe) ? rt_d : 16'bz)
                              : ((bus_owned & p_d_oe)  ? p_d  : 16'bz);
    assign cpu_e     = e_pin;         // never tri-stated, as on real silicon
    assign cpu_bg_n  = bg_pin_n;

    reg bus_enable = 1'b0;
    always @(posedge clk) bus_enable <= pwrup_done & bus_owned;
    // Open the switchable CBTs on our own cycles so the CPU<->SDRAM traffic
    // is isolated from the motherboard bus.
    assign cbt_oe_d0_7_n   = ~bus_enable | fm_active | tm_active | sd_space;
    assign cbt_oe_d8_15_n  = ~bus_enable | fm_active | tm_active | sd_space;
    assign cbt_oe_ctl_hi_n = ~bus_enable;
    assign cbt_oe_a8_17_n  = ~bus_enable;
    assign cbt_oe_a1_7_n   = ~bus_enable;

    // Autoconfig chain: transparent pass-through while our own boards are
    // stripped out, so downstream cards still configure. REATTACH here.

    // SD card in SPI mode. DAT1/DAT2 are unused by the SPI protocol and are
    // released rather than driven; DAT0 is an input (MISO) and DAT3 is chip
    // select.
    assign sd_clk      = sd_sclk_i;
    assign sd_cmd      = sd_mosi_i;
    assign sd_d[3]     = sd_ss_n_i;
    assign sd_d[2:1]   = 2'bzz;
    assign sd_d[0]     = 1'bz;

    // ========================================================================
    // 10b. RETIME mode -- SF2000-style pass-through
    // ========================================================================
    // The bridge re-synthesises a whole S0..S7 cycle on the 7M grid. That
    // costs a full 7M period of S0/S1 address setup that the core has ALREADY
    // done in fast time, plus a quantisation wait in ST_IDLE at the end. Six
    // clocks per cycle, measured, against a stock 68000's four-plus-wait.
    //
    // Retiming instead just gates the core's OWN strobes onto the 7M grid:
    //   * AS goes to the motherboard at the first tick_r after the core
    //     asserts it, and drops immediately when the core drops it
    //   * UDS/LDS are re-sampled at every tick_r, NOT snapshotted once --
    //     which is what makes writes work, since a 68000 asserts them two
    //     clocks after AS on a write
    //   * DTACK is passed back to the core only ON a tick_r
    //
    // That last point is the subtle one, and it is why this is safe where
    // EARLY_ACK was not. Quantising the ack to the 7M grid gives the slave's
    // data up to a full 141 ns after DTACK to settle before the core sees
    // the ack -- the same margin a real 68000 gets from S6 to S7. We are not
    // removing the margin, we are re-deriving it from the motherboard clock.
    reg        rt_as_n  = 1'b1, rt_uds_n = 1'b1, rt_lds_n = 1'b1;
    reg        rt_vma_n = 1'b1, rt_dtack_lo = 1'b0, rt_av = 1'b0;
    reg [15:0] rt_rd    = 16'hFFFF, rt_d = 16'd0;
    reg [23:1] rt_a     = 23'd0;
    reg [2:0]  rt_fc    = 3'd0;
    reg        rt_rw    = 1'b1, rt_d_oe = 1'b0;
    reg [1:0]  rt_vst   = 2'd0;
    reg        core_as_d2 = 1'b1;
    always @(posedge clk) core_as_d2 <= core_as_n;

    always @(posedge clk) begin
        if (ext_reset) begin
            rt_as_n <= 1'b1; rt_uds_n <= 1'b1; rt_lds_n <= 1'b1;
            rt_vma_n <= 1'b1; rt_dtack_lo <= 1'b0; rt_d_oe <= 1'b0;
            rt_vst <= 2'd0; rt_av <= 1'b0;
        end else if (core_as_n) begin
            rt_as_n     <= 1'b1;
            rt_uds_n    <= 1'b1;
            rt_lds_n    <= 1'b1;
            rt_vma_n    <= 1'b1;
            rt_dtack_lo <= 1'b0;
            rt_av       <= 1'b0;
            rt_vst      <= 2'd0;
            // One clock of address/data hold past AS negation before the
            // next cycle's address is allowed through.
            // Address, FC, R/W and the write data are all held one clock
            // past AS negation. A 68000 keeps R/W and data valid after AS
            // goes high, and the slave latches a write ON the AS rising
            // edge -- drop them on the same edge and the write is lost.
            if (core_as_d2) begin
                rt_a    <= core_a[23:1];
                rt_fc   <= core_fc;
                rt_rw   <= 1'b1;
                rt_d_oe <= 1'b0;
            end
        end else begin
            if (!core_rw) begin
                rt_d    <= core_dout;
                rt_d_oe <= ~rt_as_n;
            end
            // R/W, UDS and LDS are RE-SAMPLED every tick_r, never snapshotted
            // once. A 68000 drives R/W low at S2 (with AS) and the data
            // strobes at S4 (two clocks after AS) on a write, so anything
            // captured at the AS edge is stale and the cycle goes out as a
            // read. That is what turned the Chip RAM test into a green
            // screen. Until we commit AS, keep tracking R/W so it is stable
            // at the motherboard before AS falls.
            // int_space cycles are answered on-chip: never assert AS to the
            // motherboard for them. This is where the speed comes from --
            // fast RAM runs at the full 42.6 MHz with no 7M quantisation.
            if (tick_r && !int_space) begin
                rt_as_n  <= 1'b0;
                rt_rw    <= core_rw;
                rt_uds_n <= core_uds_n;
                rt_lds_n <= core_lds_n;
            end else if (rt_as_n) begin
                rt_rw    <= core_rw;
            end
            if (core_rw && !rt_as_n &&
                (s_vpa_n[1] ? 1'b1 : (!rt_vma_n && e_pin)))
                rt_rd <= cpu_d;
            if (tick_r && !rt_as_n && s_berr_n[1]) begin
                if (!s_dtack_n[1])
                    rt_dtack_lo <= 1'b1;
                else if (!s_vpa_n[1] && (core_fc == 3'b111)) begin
                    rt_av       <= 1'b1;     // IACK -> autovector
                    rt_dtack_lo <= 1'b1;
                end
            end
            // 6800 cycle against OUR E
            if (!s_vpa_n[1] && !rt_as_n && (core_fc != 3'b111)) begin
                if (rt_vst == 2'd0) begin
                    if (!e_pin && (e_cnt == E_VMA_AT)) begin
                        rt_vma_n <= 1'b0; rt_vst <= 2'd1;
                    end
                end else if (rt_vst == 2'd1) begin
                    if (e_fall_tick) begin
                        rt_vma_n <= 1'b1; rt_dtack_lo <= 1'b1; rt_vst <= 2'd2;
                    end
                end
            end
        end
    end

    // ========================================================================
    // 10c. Internal slaves: SDRAM fast RAM + its autoconfig
    // ========================================================================
    // NOT instantiated: autoconfig_zii (the SD card device). It advertises a
    // boot ROM -- board type 4'b1101 "ROM vector valid" at offset 00 and a
    // vector of 0x0001 at offset 2E -- so Kickstart will try to autoboot from
    // it. With no sd_subsystem behind it that hangs at the boot menu. Bring it
    // back in the same commit as the SD controller, not before.
    //
    // fastmem_zii carries its OWN autoconfig (fm_ac_*). That is deliberate and
    // stays: it is welded to the OFFER_SPLIT size negotiation, and its state
    // order encodes the Kickstart config-overflow workaround where 2M must be
    // offered before 4M.
    //
    // turbomem_zii is therefore a THIRD board on the daisy chain, not a
    // refactor of either of the others:
    //
    //     cfgin(pin) -> fastmem_zii -> turbomem_zii -> cfgout(pin)
    //
    // It serves the turbomem DiagArea so expansion.library copies it into RAM
    // and calls DiagPoint -- which is where turbomem_add() hands the
    // $08000000 window to exec via AddMemList().
    wire        fm_space, fm_active, fm_dtack_n;
    wire [15:0] fm_dout;
    wire        fm_ac_access, fm_ac_oe, fm_ac_dtack_n;
    wire [3:0]  fm_ac_dout;
    wire        tm_space, tm_active, tm_dtack_n;
    wire [15:0] tm_dout;
    wire        tm_ac_access, tm_ac_oe, tm_ac_dtack_n;
    wire [3:0]  tm_ac_dout;
    wire [7:0]  tm_base;
    wire        tm_configured;
    wire        sd_space, sd_dtack_n;
    wire [15:0] sd_dout;
    wire        sd_ac_access, sd_ac_oe, sd_ac_dtack_n;
    wire [3:0]  sd_ac_dout;
    wire [7:0]  base_sd;
    wire        sd_configured;
    wire        ac_chain_n;      // fastmem CFGOUT  -> turbomem CFGIN
    wire        ac_chain2_n;     // turbomem CFGOUT -> SD CFGIN
    wire        sd_req, sd_we, sd_ack, sd_ready, sd_wr_valid, sd_ack_early;
    wire [15:0] sd_rdata_live;
    wire [23:0] sd_saddr;
    wire [15:0] sd_wdata, sd_rdata;
    wire [1:0]  sd_byte_en;

    wire slave_reset = ext_reset;

    // -----------------------------------------------------------------
    // AUTOCONFIG ID ALLOCATION -- manufacturer 5194 ($144A), OAHR
    //
    // This block is the authority for all three IDs. Both modules carry
    // their own PROD_ID defaults, but what the board actually presents is
    // what is overridden here, so change them HERE.
    //
    //   5194/11  SD card         reused from the SF2000 on purpose, so the
    //                            unmodified sfsd.device binds without a
    //                            driver fork. Registered to Niklas Ekstrom
    //                            and Matt Harlum.
    //   5194/13  Fast RAM        Zorro II, up to 8 MB
    //   5194/14  AutoConfig ROM  64 KB Zorro II I/O board carrying the
    //                            DiagArea that AddMemList()s the 16 MB at
    //                            $08000000
    //
    // 13 and 14 are REQUESTED, NOT YET ASSIGNED. OAHR allocates product IDs
    // and does not reserve them in advance, so these can still change until
    // the application comes back. er_SerialNumber is 0 on every board, which
    // is what the application declares.
    // -----------------------------------------------------------------
    fastmem_zii #(.PROD_ID(8'd13), .OFFER_SPLIT(1'b1)) u_fastmem (
        .clk        (clk),
        .reset      (slave_reset),
        .cfgin_n    (s_cfgin_n[1]),
        .as_n       (core_as_n),
        .uds_n      (core_uds_n),
        .lds_n      (core_lds_n),
        .rw         (core_rw),
        .a          (core_a),
        .d_in       (core_dout),
        .fm_space   (fm_space),
        .fm_dout    (fm_dout),
        .fm_dtack_n (fm_dtack_n),
        .fm_active  (fm_active),
        .cfgout_n   (ac_chain_n),
        .fm_ac_access (fm_ac_access),
        .fm_ac_dout   (fm_ac_dout),
        .fm_ac_oe     (fm_ac_oe),
        .fm_ac_dtack_n(fm_ac_dtack_n),
        .req        (sd_req),
        .we         (sd_we),
        .saddr      (sd_saddr),
        .wdata      (sd_wdata),
        .byte_en    (sd_byte_en),
        .wr_valid   (sd_wr_valid),
        .ack        (sd_ack),
        .ack_early  (sd_ack_early),
        .rdata_live (sd_rdata_live),
        .rdata      (sd_rdata),
        .sdram_ready(sd_ready)
    );

    // ROM_FILE: turbomem.mem MUST BE A MEMBER OF THE DIAMOND PROJECT.
    //
    // Putting it in the directory Synplify runs from is NOT enough. Measured
    // on this design: microrom.mem, nanorom.mem, sfsd.mem and turbomem.mem
    // all sat in prj/base64_fx68k/impl1/, and $readmemh found the project
    // members and not the fourth file. Add it via File > Add > Existing File
    // so it appears in the Input Files list.
    //
    // If it is ever not found, the failure is silent and convincing:
    //
    //   log: CG371 Cannot find data file turbomem.mem for task $readmemh
    //   log: CL279 Pruning register bits 15 to 1 of rom_q[15:0]
    //
    // and the array constant-folds to zero. The board then enumerates
    // perfectly at its assigned base while serving 8 KB of zeroes, an
    // all-zero DiagArea reads as DAC_NIBBLEWIDE/DAC_NEVER with a null
    // BootPoint so expansion.library declines to touch it, and the machine
    // boots normally. Every symptom points at the gateware decode. None of
    // them are the gateware decode.
    //
    // The check that cannot lie is the block RAM count: ROM_AWID 12 is
    // 4096x16, which is four EBRs. If "Number of block RAMs" did not rise by
    // four, the ROM is not in the bitstream.
    //
    // An absolute path here also works and cannot fail, if the project route
    // ever gives trouble.
    turbomem_zii #(
        .MFG_ID   (16'h144A),
        .PROD_ID  (8'd14),        // see the ID allocation block above
        .SERIAL   (32'd0),
        .DIAG_VEC (16'h2000),     // BYTE offset, MUST be non-zero: a zero
                                  // vector enumerates fine and is never
                                  // followed. $2000 needs no decode change
                                  // (the image mirrors every 8 KB) and is
                                  // still safe if read as a word offset.
        .ROM_AWID (12),           // 4096 words = 8 KB = 4 EBRs
        .ROM_FILE ("turbomem.mem")
    ) u_turbomem (
        .clk        (clk),
        .reset      (slave_reset),
        .cfgin_n    (ac_chain_n),
        .as_n       (core_as_n),
        .uds_n      (core_uds_n),
        .lds_n      (core_lds_n),
        .rw         (core_rw),
        .a          (core_a),
        .d_in       (core_dout),
        .tm_space   (tm_space),
        .tm_dout    (tm_dout),
        .tm_dtack_n (tm_dtack_n),
        .tm_active  (tm_active),
        .tm_ac_access (tm_ac_access),
        .tm_ac_dout   (tm_ac_dout),
        .tm_ac_oe     (tm_ac_oe),
        .tm_ac_dtack_n(tm_ac_dtack_n),
        .cfgout_n     (ac_chain2_n),
        .tm_base      (tm_base),
        .tm_configured(tm_configured)
    );

    // ---------------------------------------------------------------------
    // SD card: autoconfig shell + subsystem, LAST on the chain.
    //
    // Both are Niklas Ekstrom's SF2000 design. The autoconfig register
    // values and write semantics are byte-identical to it, which is the
    // whole point -- the unmodified sfsd.rom / sfsd.device bind without a
    // driver fork, and that is why this board keeps 5194/11 rather than
    // taking an ID of its own.
    //
    // Two decode changes were needed for Base64 and are documented at the
    // point of change in each file: the a[31:24] == $00 guard (fx68k drives
    // A31-A24; the SF2000's MC68SEC000 physically cannot), and a registered
    // address compare on sd_space.
    //
    // sfsd.mem is a 32 KB byte-wide image = 16 EBRs, taking the design from
    // 5 to 21 of 56. Like turbomem.mem it MUST be a member of the Diamond
    // project, and Clean deletes it from impl1/.
    // ---------------------------------------------------------------------
    autoconfig_zii #(
        .MFG_ID     (16'h144A),
        .SD_PROD_ID (8'd11),      // see the ID allocation block above
        .SERIAL     (16'd0)
    ) u_sd_autoconfig (
        .clk          (clk),
        .reset        (slave_reset),
        .cfgin_n      (ac_chain2_n),
        .as_n         (core_as_n),
        .uds_n        (core_uds_n),
        .lds_n        (core_lds_n),
        .rw           (core_rw),
        .a_high       (core_a[31:16]),
        .a_low        (core_a[6:1]),
        .d_in         (core_dout[15:12]),
        .d_out        (sd_ac_dout),
        .data_oe      (sd_ac_oe),
        .ac_access    (sd_ac_access),
        .base_sd      (base_sd),
        .sd_configured(sd_configured),
        .cfgout_n     (cfgout_n),
        .dtack_n      (sd_ac_dtack_n)
    );

    // SPI-mode wiring onto the slot's SD pins: CLK -> SCLK, CMD -> MOSI,
    // DAT0 -> MISO, DAT3 -> CS. DAT1/DAT2 are unused in SPI mode and left
    // released. The slot has no card-detect line, so CD_n is tied asserted.
    wire sd_ss_n_i, sd_sclk_i, sd_mosi_i;

    sd_subsystem #(
        .ROM_INIT_FILE("sfsd.mem")
    ) u_sd (
        .clk          (clk),
        .reset        (slave_reset),
        .a            (core_a),
        .as_n         (core_as_n),
        .uds_n        (core_uds_n),
        .lds_n        (core_lds_n),
        .rw           (core_rw),
        .d_in         (core_dout),
        .sd_configured(sd_configured),
        .base_sd      (base_sd),
        .sd_space     (sd_space),
        .d_out        (sd_dout),
        .dtack_n      (sd_dtack_n),
        .rom_we       (1'b0),        // flash_preload not instantiated
        .rom_waddr    (15'd0),
        .rom_wdata    (8'd0),
        .sd_miso      (sd_d[0]),
        .sd_cd_n      (1'b0),
        .sd_ss_n      (sd_ss_n_i),
        .sd_sclk      (sd_sclk_i),
        .sd_mosi      (sd_mosi_i)
    );

    wire sdram_clk_int;
    sdram_ctrl #(.CLK_HZ(85_130_000), .CAS_LAT(2)) u_sdram (
        .clk (clk), .reset (slave_reset),
        .req (sd_req), .we (sd_we), .wr_valid (sd_wr_valid),
        .addr (sd_saddr), .wdata (sd_wdata), .byte_en (sd_byte_en),
        .ack (sd_ack), .ack_early (sd_ack_early),
        .rdata_live (sd_rdata_live), .rdata (sd_rdata), .ready (sd_ready),
        .sdram_a (sdram_a), .sdram_ba (sdram_ba), .sdram_dq (sdram_dq),
        .sdram_dqm (sdram_dqm), .sdram_clk (sdram_clk_int),
        .sdram_cke (sdram_cke), .sdram_cs_n (sdram_cs_n),
        .sdram_ras_n (sdram_ras_n), .sdram_cas_n (sdram_cas_n),
        .sdram_we_n (sdram_we_n)
    );

    // SDRAM clock out through an ODDR so it leaves the die on the same path
    // as the data, rather than through fabric. D0/D1 = 0/1 gives the chip a
    // clock edge in the middle of our data window; swap them if the memory
    // proves marginal.
    ODDRX1F u_sdram_clk (.D0(1'b0), .D1(1'b1), .SCLK(clk),
                         .RST(1'b0), .Q(sdram_clk));

    // A cycle that never reaches the motherboard. A missing term here is
    // silent and nasty: the retime FSM would drive AS out to the motherboard
    // for a cycle we are already answering on-chip.
    wire int_space = fm_space | fm_ac_access
                   | tm_space | tm_ac_access
                   | sd_space | sd_ac_access;

    // ========================================================================
    // 11b. Reveal debug bundle
    // ========================================================================
    // syn_keep so none of these get optimised or renamed away -- in Reveal
    // you can then just add the single net "dbg" and get everything.
    //
    //  bit  name            what it tells you
    //  4:0  ph              position on the 7M grid (0 = tick_r, 6 = tick_f)
    //  8:5  st              bridge FSM state (0=IDLE, 1..8=S0..S7)
    //  9    p_as_n          our AS output register
    // 10    cpu_dtack_n     RAW motherboard DTACK, before the 2FF
    // 11    s_dtack_n[1]    DTACK after the 2FF (what the FSM acts on)
    // 12    cpu_vpa_n       RAW VPA (high = normal cycle, low = CIA/IACK)
    // 13    core_as_n       the core's request
    // 14    core_dtack_lo   our ack back to the core
    // 15    bx_req          a cycle is pending in the bridge
    // 16    bus_owned       we own the bus
    // 17    s0_enter        one-clock pulse at the start of every bus cycle
    // 20:18 cpu_a[3:1]      enough address to tell cycles apart
    // 21    p_rw            read(1)/write(0)
    // 22    e_pin           our E clock
    // 23    p_vma_n         our VMA
    // DBG_BUNDLE=0 removes this entirely. syn_keep forces 24 nets to survive
    // optimisation, which costs routing and can push a marginal build over
    // into a Timing Check Error. Turn it off for production builds.
    (* syn_keep = 1 *) wire [23:0] dbg = !DBG_BUNDLE ? 24'd0 : {
        p_vma_n, e_pin, p_rw, p_a[3:1], s0_enter, bus_owned,
        bx_req, core_dtack_lo, core_as_n, cpu_vpa_n, s_dtack_n[1],
        cpu_dtack_n, p_as_n, st, ph
    };

    // ========================================================================
    // 12. LEDs
    // ========================================================================
    // Green: E heartbeat (or blinked cycle length when LAT_DEBUG).
    // Red:   held in reset, OR a sticky 7M phase slip (should never light).
    // Blue:  bus connected.
    reg [20:0] e_div = 21'd0;
    always @(posedge clk) if (e_fall_tick) e_div <= e_div + 21'd1;

    // Shortest observed CYCLE PITCH (S0 -> S0) in 7M clocks.
    //   4 = perfect, chaining back to back like a stock 68000
    //   5 = one extra 7M clock somewhere in the handshake
    // This deliberately measures pitch, NOT AS-low width. AS-low is 2.5
    // clocks on a no-wait 68000 cycle and tells you nothing about whether
    // cycles are chaining; pitch is the number that maps onto SysInfo's
    // chip-speed ratio (4/5 = 0.80).
    reg [7:0] len_ctr = 8'd0, len_min = 8'hFF;
    reg       seen_s0 = 1'b0;
    reg [3:0] st_d    = ST_IDLE;
    always @(posedge clk) st_d <= st;
    // Entry into S0, one master clock after the tick_r that caused it.
    // The previous version tested (tick_r && st == ST_S0), which can NEVER
    // be true: st is assigned ST_S0 ON that tick_r, so it does not read
    // back as ST_S0 until the following clock, by which time tick_r is
    // gone. len_min therefore stayed at its 8'hFF init and the blinker
    // showed the low nibble, 15. Fifteen blinks means "never measured".
    wire s0_enter = (st == ST_S0) && (st_d != ST_S0);
    always @(posedge clk) begin
        if (ext_reset) begin
            len_ctr <= 8'd0; len_min <= 8'hFF; seen_s0 <= 1'b0;
        end else if (s0_enter) begin
            if (seen_s0 && len_ctr != 8'd0 && len_ctr < len_min)
                len_min <= len_ctr;
            len_ctr <= 8'd0;
            seen_s0 <= 1'b1;
        end else if (tick_r && seen_s0 && len_ctr < 8'd60) begin
            len_ctr <= len_ctr + 8'd1;
        end
    end

    reg [23:0] blink_div = 24'd0;
    reg [3:0]  blink_ph  = 4'd0;
    reg        blink_on  = 1'b0, in_pause = 1'b1;
    reg [25:0] pause_div = 26'd0;
    always @(posedge clk) begin
        if (in_pause) begin
            blink_on  <= 1'b0;
            pause_div <= pause_div + 26'd1;
            if (pause_div[25]) begin
                pause_div <= 26'd0; in_pause <= 1'b0;
                blink_ph  <= 4'd0;  blink_div <= 24'd0;
            end
        end else begin
            blink_div <= blink_div + 24'd1;
            if (blink_div == 24'hFFFFFF) begin
                blink_on <= ~blink_on;
                if (blink_on) begin
                    blink_ph <= blink_ph + 4'd1;
                    if (blink_ph + 4'd1 >= len_min[3:0]) in_pause <= 1'b1;
                end
            end
        end
    end

    assign led_g = LAT_DEBUG ? blink_on : e_div[20];
    assign led_r = ph_slip | ~core_ohalted_n;   // PLL slip / double bus fault
    assign led_b = bus_enable;

endmodule

`default_nettype wire
