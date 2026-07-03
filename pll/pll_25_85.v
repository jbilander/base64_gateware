// Bench-build PLL: 25 MHz on-module osc -> 85.0 MHz (stand-in for the
// carrier's ICS570B 12x clock, 85.13 MHz, when no carrier is attached).
// Fout = 25 * CLKFB_DIV / CLKI_DIV = 25*17/5 = 85.0 ; VCO = 85*5 = 425 MHz (in 400-800 range)
// If Diamond objects to the hand instantiation, regenerate with
// Clarity Designer (PLL, CLKI=25, CLKOP=85) and keep the port names.
`default_nettype none

module pll_25_85 (
    input  wire clk_in,
    output wire clk_out,
    output wire locked
);
    wire clkop;

    (* FREQUENCY_PIN_CLKI="25.0", FREQUENCY_PIN_CLKOP="85.0" *)
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"), .INTFB_WAKE("DISABLED"),
        .STDBY_ENABLE("DISABLED"), .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"), .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"), .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(5),
        .CLKOP_ENABLE("ENABLED"), .CLKOP_DIV(5),
        .CLKOP_CPHASE(4), .CLKOP_FPHASE(0),
        .FEEDBK_PATH("CLKOP"), .CLKFB_DIV(17)
    ) pll_i (
        .RST(1'b0), .STDBY(1'b0),
        .CLKI(clk_in),
        .CLKOP(clkop),
        .CLKFB(clkop),
        .CLKINTFB(),
        .PHASESEL0(1'b0), .PHASESEL1(1'b0),
        .PHASEDIR(1'b1), .PHASESTEP(1'b1), .PHASELOADREG(1'b1),
        .PLLWAKESYNC(1'b0), .ENCLKOP(1'b0),
        .LOCK(locked)
    );

    assign clk_out = clkop;
endmodule
