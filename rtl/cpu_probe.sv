import base64_m68k_pkg::*;

module cpu_probe #(
    parameter id = 16'h680b,    // TCL scripts will use this ID to ensure they're talking to the correct design
    parameter capturedepth = 9,
    parameter outwidth = 8,
    parameter extrawidth = 1   // Bit width of any extra signals we might want to bring in
) (
	input m68k_clocks       clocks,

	// m68k socket
	input m68k_address_ctrl m_addr,
	input m68k_data_in      m_data_in,
	input m68k_data_out     m_data_out,
	input m68k_misc_in      m_misc_in,
	input m68k_misc_out     m_misc_out,

    input [extrawidth-1:0] extra,

    output update,
    output [outwidth-1:0]  q
);

// JTAG capture module to monitor the cpu bus lines
localparam cpusignalwidth = 75;
localparam capturewidth = cpusignalwidth + extrawidth;
wire [capturewidth-1:0] jtag_d;
wire [capturewidth-1:0] jtag_q;
wire jtag_update;
jcapture #(
    .capturewidth(capturewidth),
    .capturedepth(capturedepth),
    .triggerwidth(capturewidth),
    .designid(id)
) capture_inst (
	.clk(clocks.sysclk),
    .stb(clocks.clk7_en_p | clocks.clk7_en_n),
	.reset_n(clocks.reset_n_sys), // clocks.reset_n_sys),
	.capture_d(jtag_d),
	.user_q(jtag_q),
	.user_update(jtag_update),
    .user_d(0),
    .user_ir(),
    .user_ir_update()
);

assign jtag_d[0] = clocks.clk7;
assign jtag_d[2:1] = {clocks.clk7_en_p,clocks.clk7_en_n};
assign jtag_d[3] = m_misc_in.reset;
assign jtag_d[4] = m_misc_out.e;
assign jtag_d[5] = m_addr.as;
assign jtag_d[6] = m_addr.uds;
assign jtag_d[7] = m_addr.lds;
assign jtag_d[8] = m_addr.rw;
assign jtag_d[9] = m_misc_in.dtack;
assign jtag_d[10] = m_misc_in.vpa;
assign jtag_d[11] = m_misc_out.vma;
assign jtag_d[14:12] = m_misc_in.ipl;
assign jtag_d[30:15] = m_data_out.q;
assign jtag_d[46:31] = m_data_in.d;
assign jtag_d[47] = m_data_out.dq_en;
assign jtag_d[48] = m_data_out.drive;
assign jtag_d[72:49] = {m_addr.a,1'b0};
assign jtag_d[73] = {m_addr.a_en};
assign jtag_d[74] = {m_addr.drive};

assign jtag_d[74+extrawidth:75] = extra;

assign update = jtag_update;
assign q = jtag_q[outwidth-1:0];
	
endmodule
