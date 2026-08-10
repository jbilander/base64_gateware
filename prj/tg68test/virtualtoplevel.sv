import sdram_pkg::*;
import base64_m68k_pkg::*;
import cpu_pkg::*;

module virtualtoplevel # (
	parameter sysclk_freq = 85
) (
	input m68k_clocks        clocks,
	
	// m68k socket
	output m68k_address_ctrl socket_addr_ctrl,
	input  m68k_data_in      socket_din,
	output m68k_data_out     socket_dout,
	input  m68k_misc_in      socket_miscin,
	output m68k_misc_out     socket_miscout,

	// SDRAM
	input  sdram_in          sdr_in,
	output sdram_out         sdr_out,

	// SD card
	output spi_cs,
	output spi_copi,
	input  spi_cipo,
	output spi_clk,
	
	// LEDs
	output led_red,
	output led_green,
	output led_blue,
	
	// UART
	input rxd,
	output txd,
	input reset_btn
);


cpu_request cpu_req;
cpu_response cpu_resp;

tg68wrapper #(
	.sysclk_freq(sysclk_freq)
) cpuwrapper (
	.clocks(clocks),
	.cpu_req(cpu_req),
	.cpu_resp(cpu_resp),
	.socket_miscin(socket_miscin),
	.sdr_in(sdr_in),
	.sdr_out(sdr_out),
	.rxd(rxd),
	.txd(txd),
	.spi_cs(spi_cs),
	.spi_clk(spi_clk),
	.spi_copi(spi_copi),
	.spi_cipo(spi_cipo),
	.reset_btn(reset_btn)
);

m68k_bridge bridge (
	.clks(clocks),
	.m_addr(socket_addr_ctrl),
	.m_data_out(socket_dout),
	.m_data_in(socket_din),
	.m_misc_in(socket_miscin),
	.m_misc_out(socket_miscout),
	.cpu_req(cpu_req),
	.cpu_resp(cpu_resp)
);


// JTAG capture module to monitor the cpu
wire [0:0] jtag_q;
wire jtag_update;
//wire interrupt = &socket_miscin.ipl;
//cpu_probe #(.outwidth(1)) probe (
//    .clocks(clocks),
//    .m_addr(socket_addr_ctrl),
//    .m_data_in(socket_din),
//    .m_data_out(socket_dout),
//    .m_misc_in(socket_miscin),
//    .m_misc_out(socket_miscout),
//    .extra(interrupt),
//    .update(jtag_update),
//    .q(jtag_q)
//);

reg ledr;
always @(posedge clocks.svclk) begin
	if(jtag_update)
		ledr <= jtag_q[0];
end
assign led_red = ledr;

reg [25:1] sctr;
always @(posedge clocks.sysclk) begin
	sctr<=sctr+1;
end
assign led_green = sctr[25];

endmodule
