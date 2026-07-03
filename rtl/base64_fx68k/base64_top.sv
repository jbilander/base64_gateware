// ============================================================================
// base64_top.sv — Base64 revC carrier + iCESugar-Pro v1.3 (LFE5U-25F-6BG256C)
// Phase 1: cycle-exact 68000 drop-in replacement using fx68k, compatibility
// mode only (effective CPU clock = bus 7M, phase-locked via ICS570B x12).
//
// Pairs with base64.lpf. Toolchain: Lattice Diamond / Synplify Pro.
// ============================================================================

module base64_top (
    // Clocks
    input  wire        clk_7m,        // buffered motherboard 7.09/7.16 MHz (C7)
    input  wire        clk_12x,       // ICS570B x12 ≈ 85.1 MHz, phase-locked to 7M (L1)
    input  wire        clk_25m,       // module 25 MHz osc (P6) — config-time helper

    // 68000 socket (3.3V side of CBTD switches)
    output wire [23:1] cpu_a,
    inout  wire [15:0] cpu_d,
    output wire        cpu_as_n,
    output wire        cpu_uds_n,
    output wire        cpu_lds_n,
    output wire        cpu_rw,        // 1 = read
    output wire [2:0]  cpu_fc,
    output wire        cpu_vma_n,
    output wire        cpu_e,         // free-running, never tri-stated
    output wire        cpu_bg_n,
    input  wire        cpu_dtack_n,
    input  wire        cpu_vpa_n,
    input  wire        cpu_berr_n,
    input  wire        cpu_br_n,
    input  wire        cpu_bgack_n,
    input  wire [2:0]  cpu_ipl_n,
    inout  wire        cpu_reset_n,   // open-drain bidirectional
    inout  wire        cpu_halt_n,    // open-drain bidirectional

    // Autoconfig daisy chain (J2)
    input  wire        cfgin_n,
    output wire        cfgout_n,

    // CBT bus-switch enables (active low). U5/U6 are hardwired on.
    output wire        cbt_oe_d0_7_n,
    output wire        cbt_oe_d8_15_n,
    output wire        cbt_oe_ctl_hi_n,   // RW/LDS/UDS/AS + A18..A23
    output wire        cbt_oe_a8_17_n,
    output wire        cbt_oe_a1_7_n,

    // Module resources — idled in phase 1, used in later phases
    output wire [12:0] sdram_a,
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

    output wire        led_r_n,
    output wire        led_g_n,
    output wire        led_b_n,
    output wire        uart_tx,       // to iCELink USB-CDC (ball B9)
    input  wire        uart_rx        // from iCELink USB-CDC (ball A9)
);

    // ------------------------------------------------------------------
    // Master clock domain: everything runs on clk_12x (mesochronous with
    // the 7M bus clock thanks to the ICS570B zero-delay loop).
    // ------------------------------------------------------------------
    wire clk = clk_12x;

    // ------------------------------------------------------------------
    // Power-up + reset generation
    // fx68k wants pwrUp asserted together with extReset at coldstart,
    // then extReset alone behaves like RESET+HALT driven into a real 68000.
    // ------------------------------------------------------------------
    reg  [15:0] pwrup_cnt = 16'd0;
    wire        pwrup_done = pwrup_cnt[15];
    always @(posedge clk)
        if (!pwrup_done) pwrup_cnt <= pwrup_cnt + 16'd1;

    // Synchronize asynchronous inputs (2FF). DTACK is sampled by fx68k on
    // its internal phase; a clean 2FF sync into the 85 MHz domain adds at
    // most ~2 master clocks (~24 ns) which is well inside the S4 window.
    reg [1:0] s_dtack_n, s_vpa_n, s_berr_n, s_br_n, s_bgack_n;
    reg [1:0] s_reset_n, s_halt_n, s_cfgin_n, s_7m;
    reg [2:0] s_ipl_n_a, s_ipl_n;
    always @(posedge clk) begin
        s_dtack_n <= {s_dtack_n[0], cpu_dtack_n};
        s_vpa_n   <= {s_vpa_n[0],   cpu_vpa_n};
        s_berr_n  <= {s_berr_n[0],  cpu_berr_n};
        s_br_n    <= {s_br_n[0],    cpu_br_n};
        s_bgack_n <= {s_bgack_n[0], cpu_bgack_n};
        s_reset_n <= {s_reset_n[0], cpu_reset_n};
        s_halt_n  <= {s_halt_n[0],  cpu_halt_n};
        s_cfgin_n <= {s_cfgin_n[0], cfgin_n};
        s_7m      <= {s_7m[0],      clk_7m};
        s_ipl_n_a <= cpu_ipl_n;      // IPL must change coherently; fx68k
        s_ipl_n   <= s_ipl_n_a;      // double-samples internally as well
    end

    // ------------------------------------------------------------------
    // Phase generator: divide clk_12x by 12, aligned to the external 7M.
    // enPhi1/enPhi2 are the two half-cycle enables of the emulated CPU
    // clock. PHASE_OFS lets you trim the alignment of the emulated CLK
    // against the real 7M once you can observe both with Reveal — E-clock
    // and CIA (VPA) timing depend on this alignment being right.
    // ------------------------------------------------------------------
    localparam [3:0] PHASE_OFS = 4'd1;   // counter value loaded at 7M rising edge — TUNE ON HW

    reg  [3:0] ph_cnt = 4'd0;
    reg        r_7m_d;
    wire       edge_7m = s_7m[1] & ~r_7m_d;
    always @(posedge clk) begin
        r_7m_d <= s_7m[1];
        if (edge_7m)               ph_cnt <= PHASE_OFS;
        else if (ph_cnt == 4'd11)  ph_cnt <= 4'd0;
        else                       ph_cnt <= ph_cnt + 4'd1;
    end

    // Compatibility mode: one full 68k cycle per 12 master clocks.
    // (Turbo mode later: alternate enables every clock -> 42.5 MHz, with a
    //  bus bridge FSM re-timing external cycles onto these 7M phases.)
    wire en_phi1 = (ph_cnt == 4'd0);
    wire en_phi2 = (ph_cnt == 4'd6);

    // ------------------------------------------------------------------
    // fx68k core
    // ------------------------------------------------------------------
    wire        core_rw, core_as_n, core_lds_n, core_uds_n;
    wire        core_e, core_vma_n;
    wire        core_fc0, core_fc1, core_fc2;
    wire        core_bg_n, core_oreset_n, core_ohalted_n;
    wire [15:0] core_dout;
    wire [23:1] core_a;

    // External reset: a real 68000 resets when RESET & HALT are both driven
    // low externally (the Amiga asserts both). Mask out our own open-drain
    // drive so the RESET instruction doesn't reset us.
    wire ext_reset = (~s_reset_n[1] & ~s_halt_n[1] & core_oreset_n & core_ohalted_n)
                     | ~pwrup_done;

    fx68k cpu (
        .clk      (clk),
        .HALTn    (s_halt_n[1] | ~core_ohalted_n), // external halt only
        .extReset (ext_reset),
        .pwrUp    (~pwrup_done),
        .enPhi1   (en_phi1),
        .enPhi2   (en_phi2),

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

        .DTACKn   (s_dtack_n[1]),
        .VPAn     (s_vpa_n[1]),
        .BERRn    (s_berr_n[1]),
        .BRn      (s_br_n[1]),
        .BGACKn   (s_bgack_n[1]),
        .IPL0n    (s_ipl_n[0]),
        .IPL1n    (s_ipl_n[1]),
        .IPL2n    (s_ipl_n[2]),

        .iEdb     (cpu_d),        // registered/sampled internally on phases
        .oEdb     (core_dout),
        .eab      (core_a)
    );

    // ------------------------------------------------------------------
    // Bus ownership & tri-state control.
    // A real 68000 releases A, D, AS, UDS, LDS, R/W, FC and VMA while the
    // bus is granted (BGACK asserted, or BG given & AS negated). E and BG
    // remain driven.
    // ------------------------------------------------------------------
    wire bus_released = ~s_bgack_n[1] | (~core_bg_n & core_as_n & ~s_br_n[1]);
    wire drv_bus = ~bus_released;

    assign cpu_a     = drv_bus ? core_a : 23'bz;
    assign cpu_as_n  = drv_bus ? core_as_n  : 1'bz;
    assign cpu_uds_n = drv_bus ? core_uds_n : 1'bz;
    assign cpu_lds_n = drv_bus ? core_lds_n : 1'bz;
    assign cpu_rw    = drv_bus ? core_rw    : 1'bz;
    assign cpu_fc    = drv_bus ? {core_fc2, core_fc1, core_fc0} : 3'bz;
    assign cpu_vma_n = drv_bus ? core_vma_n : 1'bz;
    assign cpu_bg_n  = core_bg_n;
    assign cpu_e     = core_e;              // always driven

    // Data bus: drive during write cycles we own (AS asserted, R/W low).
    wire drv_data = drv_bus & ~core_as_n & ~core_rw;
    assign cpu_d = drv_data ? core_dout : 16'bz;

    // Open-drain RESET / HALT (OPENDRAIN=ON in LPF: driving 1 == Hi-Z,
    // but be explicit and portable):
    assign cpu_reset_n = core_oreset_n  ? 1'bz : 1'b0;  // RESET instruction
    assign cpu_halt_n  = core_ohalted_n ? 1'bz : 1'b0;  // double bus fault

    // ------------------------------------------------------------------
    // Autoconfig: transparent pass-through until implemented.
    // ------------------------------------------------------------------
    assign cfgout_n = s_cfgin_n[1];

    // ------------------------------------------------------------------
    // CBT switches: enabled once the power-up counter expires. While the
    // FPGA is unconfigured its weak pull-ups hold these high (isolated).
    // ------------------------------------------------------------------
    assign cbt_oe_d0_7_n   = ~pwrup_done;
    assign cbt_oe_d8_15_n  = ~pwrup_done;
    assign cbt_oe_ctl_hi_n = ~pwrup_done;
    assign cbt_oe_a8_17_n  = ~pwrup_done;
    assign cbt_oe_a1_7_n   = ~pwrup_done;

    // ------------------------------------------------------------------
    // Idle the unused module resources safely (phase 4/6 will use them).
    // ------------------------------------------------------------------
    assign sdram_a = 13'd0;  assign sdram_ba = 2'd0;
    assign sdram_dq = 16'bz; assign sdram_dqm = 2'b11;
    assign sdram_clk = 1'b0; assign sdram_cke = 1'b0;
    assign sdram_ras_n = 1'b1; assign sdram_cas_n = 1'b1;
    assign sdram_we_n = 1'b1;  assign sdram_cs_n = 1'b1;
    assign sd_clk = 1'b0; assign sd_cmd = 1'bz; assign sd_d = 4'bz;
    assign uart_tx = 1'b1;

    // Heartbeat: green breathes with E-clock divider = "core alive",
    // red on while held in reset.
    reg [21:0] hb;
    always @(posedge clk) if (en_phi1) hb <= hb + 22'd1;
    assign led_g_n = ~hb[21];
    assign led_r_n = ~ext_reset;   // red = held in reset
    assign led_b_n = 1'b1;

endmodule
