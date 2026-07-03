// Milestone 1: verify Diamond -> Synplify -> PAR -> ecpprog flow.
// Needs only the iCESugar-Pro module itself (USB power, FT4232H JTAG).
// Expected: green LED blinks ~1.5 Hz, red/blue off.
`default_nettype none

module blink_top (
    input  wire clk_25m,     // P6, on-module oscillator
    output wire led_r_n,     // B11 \
    output wire led_g_n,     // A11  - common anode, drive LOW to light
    output wire led_b_n      // A12 /
);
    reg [23:0] ctr = 24'd0;
    always @(posedge clk_25m)
        ctr <= ctr + 24'd1;

    assign led_g_n = ctr[23];
    assign led_r_n = 1'b1;
    assign led_b_n = 1'b1;
endmodule
