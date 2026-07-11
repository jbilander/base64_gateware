// ============================================================================
// fx68k_fmax_top.sv — Milestone 2: fx68k fmax trial (fredrequin fork)
//
// Answers ONE question: does fx68k close timing at 85 MHz with phase enables
// every clock (= 42.5 MHz effective CPU)?  Runs on the bare iCESugar-Pro
// (USB power, HW-USBN-2A). Load via Diamond "Fast Program" (SRAM).
//
// Ports match fredrequin/fx68k (adds E_rise/E_fall; eab is [31:1]).
//
// EN_SPACING sets the trial speed:
//   1 -> phi every clock       -> 42.5 MHz effective  (the big question)
//   2 -> phi every 2nd clock   -> 21.3 MHz effective  (fallback target)
//   6 -> phi every 6th clock   ->  7.09 MHz equivalent (compat-mode load)
//
// Read the result in the Place & Route Trace report (.twr): look at the
// FREQUENCY NET "clk_sys" preference — PASS/FAIL and worst slack.
// ============================================================================
`default_nettype none

module fx68k_fmax_top #(
    parameter EN_SPACING = 1
) (
    input  wire clk_25m,     // P6, on-module oscillator
    output wire led_r_n,     // B11
    output wire led_g_n,     // A11
    output wire led_b_n      // A12
);

    // ---- PLL: 25 MHz -> 85.0 MHz (bench stand-in for the 12x carrier clock) ----
    wire clk_sys, pll_locked;
    pll_25_85 pll (.clk_in(clk_25m), .clk_out(clk_sys), .locked(pll_locked));

    // ---- reset / power-up ----
    reg [15:0] rst_cnt = 16'd0;
    wire pwrup_done = rst_cnt[15];
    always @(posedge clk_sys)
        if (pll_locked && !pwrup_done) rst_cnt <= rst_cnt + 16'd1;

    // ---- phase enables ----
    localparam CW = (EN_SPACING <= 2) ? 2 : $clog2(EN_SPACING+1);
    reg [CW-1:0] sp = '0;
    reg phase = 1'b0, enphi1 = 1'b0, enphi2 = 1'b0;
    always @(posedge clk_sys) begin
        enphi1 <= 1'b0;
        enphi2 <= 1'b0;
        if (sp >= (EN_SPACING-1)) begin
            sp     <= '0;
            phase  <= ~phase;
            enphi1 <= ~phase;
            enphi2 <=  phase;
        end else begin
            sp <= sp + 1'b1;
        end
    end

    // ---- LFSR "memory": the CPU fetches noise, takes exceptions forever ----
    reg [15:0] lfsr = 16'hACE1;
    always @(posedge clk_sys)
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

    // ---- core signals ----
    wire        rw_n, as_n, lds_n, uds_n, vma_n, bg_n;
    wire        e_clk, e_rise, e_fall, oreset_n, ohalted_n;
    wire        fc0, fc1, fc2;
    wire [15:0] edb_out;
    wire [31:1] eab;

    // ---- auto-DTACK: assert a few phi-ticks after AS ----
    reg [2:0] as_age = 3'd0;
    reg dtack_n = 1'b1;
    always @(posedge clk_sys) begin
        if (as_n) begin
            as_age  <= 3'd0;
            dtack_n <= 1'b1;
        end else if (enphi1 || enphi2) begin
            if (!(&as_age)) as_age <= as_age + 3'd1;
            if (as_age >= 3'd3) dtack_n <= 1'b0;
        end
    end

    // ---- slow IPL wiggle so interrupt logic isn't optimized flat ----
    reg [23:0] slow = 24'd0;
    always @(posedge clk_sys) slow <= slow + 24'd1;
    wire [2:0] ipl_n = {2'b11, ~(slow[23] & ~slow[22])};

    fx68k cpu (
        .clk      (clk_sys),
        .enPhi1   (enphi1),
        .enPhi2   (enphi2),
        .HALTn    (1'b1),
        .extReset (~pwrup_done),
        .pwrUp    (~pwrup_done),
        .oRESETn  (oreset_n),
        .oHALTEDn (ohalted_n),
        .E        (e_clk),
        .E_rise   (e_rise),
        .E_fall   (e_fall),
        .VPAn     (1'b1),
        .VMAn     (vma_n),
        .ASn      (as_n),
        .eRWn     (rw_n),
        .LDSn     (lds_n),
        .UDSn     (uds_n),
        .FC2      (fc2),
        .FC1      (fc1),
        .FC0      (fc0),
        .DTACKn   (dtack_n),
        .BERRn    (1'b1),
        .BRn      (1'b1),
        .BGn      (bg_n),
        .BGACKn   (1'b1),
        .IPL2n    (ipl_n[2]),
        .IPL1n    (ipl_n[1]),
        .IPL0n    (ipl_n[0]),
        .iEdb     (lfsr),
        .oEdb     (edb_out),
        .eab      (eab)
    );

    // ---- keep-alive fold: prevent any output from being optimized away ----
    reg fold = 1'b0;
    reg [21:0] act = 22'd0;
    always @(posedge clk_sys) begin
        fold <= (^eab) ^ (^edb_out) ^ rw_n ^ as_n ^ lds_n ^ uds_n ^ e_clk
                ^ e_rise ^ e_fall ^ vma_n ^ bg_n ^ fc0 ^ fc1 ^ fc2
                ^ oreset_n ^ ohalted_n;
        if (enphi1 && !as_n) act <= act + 22'd1;   // count bus cycles
    end

    assign led_b_n = fold;         // dim flicker = core alive
    assign led_g_n = ~act[21];     // toggles as bus cycles accumulate
    assign led_r_n = pwrup_done;   // red until reset releases

endmodule
