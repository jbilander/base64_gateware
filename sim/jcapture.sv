module jcapture # (
    parameter capturewidth,
    parameter capturedepth,
    parameter triggerwidth,
    parameter designid,
    parameter user_ir_width = 4
) (
    input  clk,
    input  reset_n,
	input  stb,
    input  [capturewidth-1:0] capture_d,
    output [capturewidth-1:0] user_q,
    input  [capturewidth-1:0] user_d,
    output [user_ir_width-1:0] user_ir,
    output user_ir_update,
    output user_update
);

endmodule

