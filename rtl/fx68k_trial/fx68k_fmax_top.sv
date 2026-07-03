// ============================================================================
// Milestone 2: fx68k fmax trial. Runs on the bare module (bench, USB power).
//
// Purpose: ONE number — does fx68k close timing at 85 MHz with enables
// alternating every clock (= 42.5 MHz effective CPU)?
//
// The core is wrapped in a synthetic environment so nothing optimizes away:
//   * auto-DTACK responder (3 phi after AS), data bus fed from an LFSR
//   * IPL wiggled slowly from a counter
//   * every core output XOR-folded into the blue LED
// Green breathes at a rate proportional to executed cycles (garbage code
// execution — the CPU fetches LFSR noise and takes illegal-instruction
// exceptions forever, which is fine: it exercises the microcode paths).
//
// TRIAL SPEED is set by EN_SPACING:
//   1 = phi every clock      -> 42.5 MHz effective  (the big question)
//   2 = phi every 2nd clock  -> 21.3 MHz effective  (fallback target)
//   6 = phi every 6th clock  ->  7.09 MHz equivalent (compat-mode load)
// Read results in the Place & Route Trace report (.twr): the FREQUENCY
// preference on net clk_sys, worst slack, and the failing endpoints.
// ============================================================================
`default_nettype none

module fx68k_fmax_top #(
    parameter EN_SPACING = 1
) (
    input  wire clk_25m,
    output wire led_r_n,
    output wire led_g_n,
    output wire led_b_n
);
    wire clk_sys, pll_locked;
    pll_25_85 pll (.clk_in(clk_25m), .clk_out(clk_sys), .locked(pll_locked));

    // reset / power-up
    reg [15:0] rst_cnt = 16'd0;
    wire pwrup_done = rst_cnt[15];
    always @(posedge clk_sys)
        if (pll_locked && !pwrup_done) rst_cnt <= rst_cnt + 16'd1;

    // phase enables
    reg [$clog2(EN_SPACING+1):0] sp;
    reg phase, enphi1, enphi2;
    always @(posedge clk_sys) begin
        enphi1 <= 1'b0;
        enphi2 <= 1'b0;
        if (sp >= EN_SPACING-1) begin
            sp     <= '0;
            phase  <= ~phase;
            enphi1 <= ~phase;
            enphi2 <=  phase;
        end else
            sp <= sp + 1'b1;
    end

    // LFSR "memory"
    reg [15:0] lfsr = 16'hACE1;
    always @(posedge clk_sys)
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

    // core signals
    wire        rw_n, as_n, lds_n, uds_n, e_clk, vma_n, bg_n;
    wire        fc0, fc1, fc2, oreset_n, ohalted_n;
    wire [15:0] edb_out;
    wire [31:1] eab;              // fredrequin fork: 32-bit; we use [23:1]

    // auto-DTACK: assert 3 phi-ticks after AS asserts
    reg [2:0] as_age;
    reg dtack_n;
    always @(posedge clk_sys) begin
        if (as_n) begin
            as_age  <= 3'd0;
            dtack_n <= 1'b1;
        end else if (enphi1 || enphi2) begin
            if (!(&as_age)) as_age <= as_age + 3'd1;
            if (as_age >= 3'd3) dtack_n <= 1'b0;
        end
    end

    // slow IPL wiggle (mostly idle, occasional level-1)
    reg [23:0] slow;
    always @(posedge clk_sys) slow <= slow + 24'd1;
    wire [2:0] ipl_n = {2'b11, ~slow[23] | slow[22]};

    fx68k cpu (
        .clk      (clk_sys),
        .HALTn    (1'b1),
        .extReset (~pwrup_done),
        .pwrUp    (~pwrup_done),
        .enPhi1   (enphi1),
        .enPhi2   (enphi2),

        .eRWn     (rw_n),
        .ASn      (as_n),
        .LDSn     (lds_n),
        .UDSn     (uds_n),
        .E        (e_clk),
        .VMAn     (vma_n),
        .FC0      (fc0), .FC1 (fc1), .FC2 (fc2),
        .BGn      (bg_n),
        .oRESETn  (oreset_n),
        .oHALTEDn (ohalted_n),

        .DTACKn   (dtack_n),
        .VPAn     (1'b1),
        .BERRn    (1'b1),
        .BRn      (1'b1),
        .BGACKn   (1'b1),
        .IPL0n    (ipl_n[0]), .IPL1n (ipl_n[1]), .IPL2n (ipl_n[2]),

        .iEdb     (lfsr),
        .oEdb     (edb_out),
        .eab      (eab)
    );

    // keep-alive folds: prevent any output from optimizing away
    reg fold;
    reg [21:0] act;
    always @(posedge clk_sys) begin
        fold <= (^eab) ^ (^edb_out) ^ rw_n ^ as_n ^ lds_n ^ uds_n ^ e_clk
                ^ vma_n ^ bg_n ^ fc0 ^ fc1 ^ fc2 ^ oreset_n ^ ohalted_n;
        if (enphi1 && !as_n) act <= act + 22'd1;   // count bus cycles
    end

    assign led_b_n = fold;         // flickers dimly = core alive
    assign led_g_n = ~act[21];     // toggles as bus cycles accumulate
    assign led_r_n = pwrup_done;   // red until reset releases

endmodule
