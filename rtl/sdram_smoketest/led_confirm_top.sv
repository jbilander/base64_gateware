// led_confirm_top.sv — confirm the active-HIGH fix. Lights ONLY green, steady.
// Expected on hardware: steady GREEN, nothing else. If you instead see red/blue,
// the mapping differs and we adjust. clk_12x = L1 (in-socket clock).
`default_nettype none
module led_confirm_top (
    input  wire clk_12x,
    output wire led_r_n, output wire led_g_n, output wire led_b_n
);
    (* keep *) reg t=1'b0; always @(posedge clk_12x) t<=~t;
    assign led_r_n = 1'b0;   // off
    assign led_g_n = 1'b1;   // GREEN on (active-high)
    assign led_b_n = 1'b0;   // off
endmodule
