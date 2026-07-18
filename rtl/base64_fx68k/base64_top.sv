// ============================================================================
// base64_top.sv  —  Base64 carrier + iCESugar-Pro, COMPAT MODE (7.09 MHz)
//
// Cycle-exact 68000 replacement. fx68k (upstream ijor) driven by phase
// enables locked to the motherboard 7M clock via the ICS570B x12 (85.1 MHz).
// One 68k cycle per 12 master clocks -> effective 7.09/7.16 MHz, indistin-
// guishable from a stock 68000. Turbo is a later, separate build.
//
// NEW: Zorro II autoconfig SD-card device (SF2000 adaptation). As the CPU,
// our own 64KB I/O space is served by the INTERNAL-MUX pattern: cycles to
// the board go out on the physical bus unchanged (AS/addr/strobes as always,
// Gary's auto-DTACK is simply ignored), while the core's DTACKn / iEdb /
// VPAn / BERRn inputs are muxed to internal sources. Zero changes to the
// tristate / CBT / arbitration logic; internal cycles even complete during
// DMA grants. Modules: autoconfig_zii_b64.v, sd_subsystem.v (which wraps the
// UNCHANGED sdcard.v/shifter.v/fifo.v/tx_cpu_buf.v/rx_cpu_buf.v), boot ROM
// in EBR initialised from sfsd.mem.
//
// BUILD TRAP: sfsd.mem joins microrom.mem/nanorom.mem — must be present in
// prj/base64_fx68k/impl1/ before build; Diamond "Clean" deletes it.
//
// Pairs with base64.lpf. Toolchain: Diamond / Synplify Pro.
// fx68k ports match UPSTREAM ijor/fx68k (no E_rise/E_fall, eab[23:1]).
//
// FIRST-CONTACT SAFETY: CBT switch OEs are held OFF (bus isolated) until the
// PLL is locked and the power-up counter expires, so the FPGA never drives
// the Amiga bus with indeterminate values while configuring.
// ============================================================================
`default_nettype none

module base64_top (
    // Clocks from carrier
    input  wire        clk_7m,        // C7  buffered motherboard 7M (74LVC1G17)
    input  wire        clk_12x,       // L1  ICS570B x12 (85.1 MHz, PLL-locked to 7M)

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

    // Idle module resources safely in compat mode
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

    // On-module micro-SD slot, used in SPI mode:
    //   sd_clk = SCLK, sd_cmd = MOSI, sd_d[0] = MISO, sd_d[3] = CS_n,
    //   sd_d[2:1] released (add PULLMODE=UP in the LPF on sd_cmd/sd_d).
    //   The slot has no card-detect line; CD is tied "present" internally.
    output wire        sd_clk,
    inout  wire        sd_cmd,
    inout  wire [3:0]  sd_d,

    output wire        led_r_n,
    output wire        led_g_n,
    output wire        led_b_n,
    output wire        uart_tx,
    input  wire        uart_rx
);

    // ------------------------------------------------------------------
    // Master clock domain: everything on clk_12x. The ICS570B loop makes it
    // mesochronous with the 7M bus, so 7M is treated as *data* (2FF-synced)
    // and its edge reloads the divide-by-12 phase counter.
    // ------------------------------------------------------------------
    wire clk = clk_12x;

    // --- power-up / reset sequencing ---
    // Long cold-boot hold: ~98 ms after configuration before the core's
    // first fetch, so the USB ROM board, ICS570B lock, rails and the
    // Amiga's own POR are all settled long before we fetch the reset
    // vector. Cures the cold-boot double-fault wedge (dim LED / random
    // early guru colors, recoverable with Ctrl-A-A). Warm resets are
    // unaffected: this counter runs once per FPGA configuration.
    reg  [23:0] pwrup_cnt = 24'd0;
    wire        pwrup_done = pwrup_cnt[23];
    always @(posedge clk)
        if (!pwrup_done) pwrup_cnt <= pwrup_cnt + 24'd1;

    // --- synchronize async inputs (2FF) ---
    reg [1:0] s_dtack_n, s_vpa_n, s_berr_n, s_br_n, s_bgack_n;
    reg [1:0] s_reset_n, s_halt_n, s_cfgin_n, s_7m;
    reg [2:0] s_ipl_a, s_ipl_n;

    // 7M capture hardening: the ICS570B is a zero-delay multiplier, so 7M
    // edges arrive at the FPGA coincident with clk_12x edges. Sampling
    // clk_7m directly on the rising edge is therefore a race decided by the
    // (unconstrained) routing delta between the clock tree and the 7m data
    // path - it can flip by one cycle between builds, shifting the
    // EFFECTIVE phase alignment and requiring a different PHASE_OFS per
    // build (observed: the original build wanted 4'd3, later fuller builds
    // 4'd2). Capturing on the FALLING edge puts the sample 5.86 ns away
    // from the coincident edge - far outside the +/-1-2 ns routing
    // variation - making the captured cycle deterministic across builds
    // and seeds. NOTE: after this change PHASE_OFS is calibrated once and
    // is then stable forever (try current value first, then +/-1).
    reg s_7m_fall;
    always @(negedge clk) s_7m_fall <= clk_7m;

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
        s_ipl_n   <= s_ipl_a;
    end

    // --- phase generator: divide clk_12x by 12, aligned to 7M ---
    // PHASE_OFS trims where the emulated CPU clock edges fall vs the real 7M
    // (C1/C3). Tune on hardware with Reveal against E and the 7M edge.
    localparam [3:0] PHASE_OFS = 4'd2;
    reg  [3:0] ph_cnt = 4'd0;
    reg        r_7m_d;
    wire       edge_7m = s_7m[1] & ~r_7m_d;
    always @(posedge clk) begin
        r_7m_d <= s_7m[1];
        if (edge_7m)              ph_cnt <= PHASE_OFS;
        else if (ph_cnt == 4'd11) ph_cnt <= 4'd0;
        else                      ph_cnt <= ph_cnt + 4'd1;
    end

    // COMPAT: one full 68k cycle per 12 master clocks.
    // fx68k wants enPhi1 asserted the cycle before the CPU-clock high phase,
    // enPhi2 the cycle before the low phase.
    wire en_phi1 = (ph_cnt == 4'd0);
    wire en_phi2 = (ph_cnt == 4'd6);

    // ------------------------------------------------------------------
    // fx68k core (upstream ijor)
    // ------------------------------------------------------------------
    wire        core_rw, core_as_n, core_lds_n, core_uds_n;
    wire        core_e, core_vma_n;
    wire        core_fc0, core_fc1, core_fc2;
    wire        core_bg_n, core_oreset_n, core_ohalted_n;
    wire [15:0] core_dout;
    wire [23:1] core_a;

    // External reset: a real 68000 resets when RESET & HALT are both driven
    // low externally. Mask our own open-drain drive so the RESET instruction
    // doesn't reset the core itself.
    // External reset: RESET & HALT both low resets the core. Masked ONLY
    // while the core itself executes the RESET instruction (oRESETn low),
    // since we drive the shared /RST net then. Deliberately NOT masked by
    // oHALTEDn: a double-bus-faulted (halted) 68000 must respond to
    // external reset - that's how a real Amiga recovers from a guru. (We
    // drive HALT low while halted; the resulting low net asserts ext_reset
    // and the core resets itself out of the halt, exactly like real
    // silicon on the A500's tied RESET+HALT net.)
    wire ext_reset = (~s_reset_n[1] & ~s_halt_n[1] & core_oreset_n)
                     | ~pwrup_done;

    // ------------------------------------------------------------------
    // Autoconfig + SD-card device (internal bus slaves)
    // ------------------------------------------------------------------
    // Device reset: must fire on EVERY /RST assertion, including the RESET
    // instruction (which loops back through the open-drain pin into
    // s_reset_n) - Kickstart executes RESET early in boot and then expects
    // all expansions unconfigured, so this must NOT use ext_reset (which
    // deliberately masks the RESET instruction for the core itself).
    wire devices_reset = ~s_reset_n[1] | ~pwrup_done;

    wire         ac_oe, ac_access, sd_configured, ac_dtack_n;
    wire [15:12] ac_dout;
    wire [7:0]   base_sd;
    wire         cfgout_int_n;

    wire         sd_space, sd_dtack_n;
    wire [15:0]  sd_dout;
    wire         sd_miso_w, sd_ss_n_w, sd_sclk_w, sd_mosi_w;

    autoconfig_zii_b64 autoconfig (
        .clk          (clk),
        .reset        (devices_reset),
        .cfgin_n      (s_cfgin_n[1]),
        .as_n         (core_as_n),
        .uds_n        (core_uds_n),
        .lds_n        (core_lds_n),
        .rw           (core_rw),
        .a_high       (core_a[23:16]),
        .a_low        (core_a[6:1]),
        .d_in         (core_dout[15:12]),
        .d_out        (ac_dout),
        .data_oe      (ac_oe),
        .ac_access    (ac_access),
        .base_sd      (base_sd),
        .sd_configured(sd_configured),
        .cfgout_n     (cfgout_int_n),
        .dtack_n      (ac_dtack_n)
    );

    sd_subsystem sdsys (
        .clk          (clk),
        .reset        (devices_reset),
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
        .rom_we       (1'b0),          // flash_preload lands here in phase 3b
        .rom_waddr    (15'd0),
        .rom_wdata    (8'd0),
        .sd_miso      (sd_miso_w),
        .sd_cd_n      (1'b0),          // no CD line on the module slot: present
        .sd_ss_n      (sd_ss_n_w),
        .sd_sclk      (sd_sclk_w),
        .sd_mosi      (sd_mosi_w)
    );

    // Core input muxes - the whole internal-slave trick. own_space decode is
    // glitch-safe: the 68000 holds the address stable from before AS to after
    // AS, and sd_configured/base_sd/cfgout_n only change at cycle boundaries
    // (cfgout_n is registered on the rising edge of AS).
    //
    // REGISTERED: the core's inputs must come from flops, exactly as they did
    // pre-SD (s_*_n[1] were 2FF outputs feeding the core directly). Muxing
    // combinationally in front of iEdb/DTACKn added logic levels to paths the
    // 85 MHz build has no margin for. The one-clock (11.7 ns) added latency
    // is invisible at 7 MHz bus pace: worst case DTACK is recognised one
    // master clock later, i.e. the same category of delay as the existing
    // 2FF synchronisers, and slaves hold DTACK until AS ends anyway.
    wire own_space = ac_access | sd_space;

    reg        core_dtack_n;
    reg [15:0] core_iedb;
    reg        core_vpa_n, core_berr_n;
    always @(posedge clk) begin
        core_dtack_n <= ac_access ? ac_dtack_n :
                        sd_space  ? sd_dtack_n :
                                    s_dtack_n[1];

        core_iedb    <= ac_oe                 ? {ac_dout, 12'hFFF} :
                        (sd_space && core_rw) ? sd_dout            :
                                                cpu_d;

        // Never let external VPA/BERR terminate an internal cycle.
        core_vpa_n   <= own_space ? 1'b1 : s_vpa_n[1];
        core_berr_n  <= own_space ? 1'b1 : s_berr_n[1];
    end

    fx68k cpu (
        .clk      (clk),
        .enPhi1   (en_phi1),
        .enPhi2   (en_phi2),
        .HALTn    (s_halt_n[1] | ~core_oreset_n | ~core_ohalted_n),
        .extReset (ext_reset),
        .pwrUp    (~pwrup_done),
        .oRESETn  (core_oreset_n),
        .oHALTEDn (core_ohalted_n),
        .E        (core_e),
        .VPAn     (core_vpa_n),
        .VMAn     (core_vma_n),
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
        .IPL2n    (s_ipl_n[2]),
        .IPL1n    (s_ipl_n[1]),
        .IPL0n    (s_ipl_n[0]),
        .iEdb     (core_iedb),
        .oEdb     (core_dout),
        .eab      (core_a)
    );

    // ------------------------------------------------------------------
    // Bus ownership & tri-state. A real 68000 releases A/D/AS/UDS/LDS/RW/FC/
    // VMA while the bus is granted; E and BG stay driven.
    // ------------------------------------------------------------------
    // Released when BGACK is asserted, or when we've granted BG and our own
    // AS is idle. Deliberately NOT dependent on BR: a requester may legally
    // release BR before/as it asserts BGACK; re-driving in that window
    // would cause contention. fx68k holds BG until BGACK is seen, so the
    // second term covers the handoff and the first term the DMA burst.
    // NOTE: cycles to our own autoconfig/SD space intentionally still go out
    // on the bus (AS/addr/strobes, data on writes) - nothing on the A500
    // decodes E8/E9 onto the data bus, the core ignores external DTACK for
    // those cycles via the mux above, and this keeps the proven tristate
    // logic completely untouched.
    wire bus_released = ~s_bgack_n[1] | (~core_bg_n & core_as_n);
    wire drv_bus = ~bus_released;

    assign cpu_a     = drv_bus ? core_a : 23'bz;
    assign cpu_as_n  = drv_bus ? core_as_n    : 1'bz;
    assign cpu_uds_n = drv_bus ? core_uds_n   : 1'bz;
    assign cpu_lds_n = drv_bus ? core_lds_n   : 1'bz;
    assign cpu_rw    = drv_bus ? core_rw      : 1'bz;
    assign cpu_fc    = drv_bus ? {core_fc2, core_fc1, core_fc0} : 3'bz;
    assign cpu_vma_n = drv_bus ? core_vma_n   : 1'bz;
    assign cpu_bg_n  = core_bg_n;
    assign cpu_e     = core_e;

    // Data bus: drive only during write cycles we own.
    wire drv_data = drv_bus & ~core_as_n & ~core_rw;
    assign cpu_d = drv_data ? core_dout : 16'bz;

    // ------------------------------------------------------------------
    // Halt watchdog: a double-bus-faulted 68000 just halts; on the A500 the
    // only true recovery is a MACHINE reset (the CIAs must reset so the ROM
    // overlay at $0 is restored - a CPU-only reset refetches garbage from
    // chip RAM and faults again forever). So when the core halts, drive the
    // shared /RST net low for ~25 ms (like Gary's POR), resetting Gary and
    // the CIAs, then release: overlay restored, vector fetched from ROM,
    // clean system-wide restart. Turns any guru/cold-boot crash into
    // authentic self-recovery.
    reg        auto_rst = 1'b0;
    reg [21:0] auto_rst_cnt = 22'd0;
    always @(posedge clk) begin
        if (!auto_rst) begin
            auto_rst_cnt <= 22'd0;
            // trigger: core halted (double fault), not our RESET instruction
            if (pwrup_done && !core_ohalted_n && core_oreset_n)
                auto_rst <= 1'b1;
        end else begin
            auto_rst_cnt <= auto_rst_cnt + 22'd1;
            if (auto_rst_cnt[21])            // ~24.6 ms at 85.13 MHz
                auto_rst <= 1'b0;
        end
    end

    // Open-drain RESET / HALT (drive low or release to the board pull-up).
    // Driven low by the RESET instruction (oRESETn), by a halted core
    // (oHALTEDn, as real silicon does), or by the halt watchdog above.
    assign cpu_reset_n = (core_oreset_n  & ~auto_rst) ? 1'bz : 1'b0;
    assign cpu_halt_n  = (core_ohalted_n & ~auto_rst) ? 1'bz : 1'b0;

    // Autoconfig chain: CFGOUT asserts once our board is configured or shut
    // up (registered at end-of-cycle inside the shell), then downstream
    // boards see their CFGIN. Replaces the old transparent pass-through.
    assign cfgout_n = cfgout_int_n;

    // ------------------------------------------------------------------
    // CBT switches: connect the bus only once locked & powered up. Until the
    // bitstream loads, ECP5 weak pull-ups hold these high (isolated).
    // ------------------------------------------------------------------
    // CBT switches: connect only when powered up AND bus owned. During a
    // bus grant the switches OPEN, physically isolating D0-15 (U2/U3),
    // AS/UDS/LDS/RW/A18-23 (U4) and A1-17 (U7/U8). NOTE: FC0-2 (U6) and
    // VMA (U5) ride ALWAYS-ON switches, so for those two the internal
    // tristate (drv_bus ? ... : 'bz) is the sole and required protection -
    // both are implemented above. E and BG (U5) stay driven, as on a real
    // 68000. All remaining U5/U6 channels are inputs to us. Registered so
    // the OE pins are glitch-free; the one-clock lag is the safe order on
    // both edges (pins tristate before the switch opens; the switch closes
    // before the core can start its next cycle).
    reg bus_enable = 1'b0;
    always @(posedge clk) bus_enable <= pwrup_done & drv_bus;
    assign cbt_oe_d0_7_n   = ~bus_enable;
    assign cbt_oe_d8_15_n  = ~bus_enable;
    assign cbt_oe_ctl_hi_n = ~bus_enable;
    assign cbt_oe_a8_17_n  = ~bus_enable;
    assign cbt_oe_a1_7_n   = ~bus_enable;

    // ------------------------------------------------------------------
    // Idle module resources (SDRAM/uart still unused in compat mode)
    // ------------------------------------------------------------------
    assign sdram_a = 13'd0;  assign sdram_ba = 2'd0;
    assign sdram_dq = 16'bz; assign sdram_dqm = 2'b11;
    assign sdram_clk = 1'b0; assign sdram_cke = 1'b0;
    assign sdram_ras_n = 1'b1; assign sdram_cas_n = 1'b1;
    assign sdram_we_n = 1'b1;  assign sdram_cs_n = 1'b1;
    assign uart_tx = 1'b1;

    // ------------------------------------------------------------------
    // SD slot in SPI mode (replaces the old idle assigns).
    // CS_n idles high out of reset (slave_select resets 0), so the card
    // stays deselected until the driver talks to it.
    // ------------------------------------------------------------------
    assign sd_clk    = sd_sclk_w;      // SCLK
    assign sd_cmd    = sd_mosi_w;      // MOSI (always driven; card only
                                       // listens while CS_n low)
    assign sd_d[3]   = sd_ss_n_w;      // CS_n
    assign sd_d[2:1] = 2'bzz;          // unused in SPI mode; pull up in LPF
    assign sd_d[0]   = 1'bz;           // MISO - input to us
    assign sd_miso_w = sd_d[0];

    // ------------------------------------------------------------------
    // Status LEDs (active low): green pulses with E (core running),
    // red on while held in reset, blue = bus isolated.
    // ------------------------------------------------------------------
    reg [20:0] e_div;
    reg e_d;
    always @(posedge clk) e_d <= core_e;
    always @(posedge clk) if (core_e & ~e_d) e_div <= e_div + 21'd1;
    assign led_g_n = ~e_div[20];
    assign led_r_n = ~ext_reset;      // lit while in reset
    assign led_b_n =  bus_enable;     // lit while isolated (incl. during DMA grants)

    // ------------------------------------------------------------------
    // Phase 3b (not yet enabled): flash_preload streams the driver ROM from
    // the W25Q256 at 0x100000 into the sd_subsystem BRAM during the pwrup
    // hold. When enabling: instantiate flash_preload, route its rom_we/
    // rom_waddr/rom_wdata into sdsys, add flash CS/MOSI/MISO pins (N8/T8/T7)
    // to the port list + LPF, and gate the hold:
    //     wire pwrup_done = pwrup_cnt[23] & load_done;
    // ------------------------------------------------------------------

endmodule
