import base64_m68k_pkg::*;
import sdram_pkg::*;
import cpu_pkg::*;

//// module ////
module tb(
  input  wire           clk7,
  input  wire           clk2x,
  input  wire           sysclk,
  input  wire           svclk,
  output wire           e,
  output wire           as,
  output wire           uds,
  output wire           lds,
  output wire           rw,
  output wire [23:0]    a,
  output wire [15:0]    d,
  input  wire [15:0]    q,
  input  wire           rxd,
  output wire           txd
);
/* verilator lint_off MULTIDRIVEN */

// Clocking
m68k_clocks clocks;
hostclocks hostclocks (
	.clk7(clk7),
	.clk85(clk2x),
	.fpgaclk(clk2x),
	.cpu_clocks(clocks)
);

m68k_address_ctrl addr;
m68k_data_in din;
m68k_data_out dout;
m68k_misc_in min;
m68k_misc_out mout;
sdram_in sdr_in;
sdram_out sdr_out;

reg spi_cipo=1'b0;
wire spi_cs,spi_copi,spi_clk;
wire led_red,led_green,led_blue;

virtualtoplevel #(.sysclk_freq(85)) vt (
	.clocks(clocks),
	.socket_addr_ctrl(addr),
	.socket_din(din),
	.socket_dout(dout),
	.socket_miscin(min),
	.socket_miscout(mout),
	.sdr_in(sdr_in),
	.sdr_out(sdr_out),
	.spi_cs(spi_cs),
	.spi_copi(spi_copi),
	.spi_cipo(spi_cipo),
	.spi_clk(spi_clk),
	.led_red(led_red),
	.led_green(led_green),
	.led_blue(led_blue),
	.rxd(rxd),
	.txd(txd),
	.reset_btn(1'b1)
);

reg spi_clk_d;

always @(posedge clocks.sysclk) begin
	spi_clk_d <= spi_clk;
	if(spi_clk && !spi_clk_d)
		spi_cipo <= ~spi_cipo;
end

assign min.dtack = 1'b0; // DTACK grounded!
assign min.vpa = 1'b1;
assign min.reset = 1'b1;
assign min.ipl = 3'b111;
assign e = mout.e;
assign clocks.sysclk=sysclk;
assign clocks.svclk=svclk;

assign a = {addr.a,1'b0};
assign as = addr.as;
assign uds = addr.uds;
assign lds = addr.lds;
assign rw = addr.rw;
assign d =dout.q;
assign din.d = q;

/* verilator lint_on MULTIDRIVEN */

// SDRAM

wire [15:0] SDRAM_DQ;
assign SDRAM_DQ = sdr_out.drive ? sdr_out.q : 16'bzzzzzzzz_zzzzzzzz;
assign sdr_in.d = SDRAM_DQ;

mt48lc16m16a2
sdram (
  .Dq         (SDRAM_DQ),
  .Addr       (sdr_out.a),
  .Ba         (sdr_out.ba),
  .Clk        (~clocks.sysclk),
  .Cke        (sdr_out.cke),
  .Cs_n       (sdr_out.cs),
  .Ras_n      (sdr_out.ras),
  .Cas_n      (sdr_out.cas),
  .We_n       (sdr_out.we),
  .Dqm        (sdr_out.dqm)
);

endmodule

