// Take a high-frequency system clock and the 7MHz clock from the host system
// and generate pos- and neg-edge enables in the system clock domain,
// and also an e clock.

import base64_m68k_pkg::*;

module hostclocks #(parameter phase=2) (
	input clk7,
	input clk85,
	input fpgaclk,
	output m68k_clocks cpu_clocks
);

wire sysclk;
wire ramclk;
wire slowclk;

// * CURRENTLY DISABLED - using asynchronous clock instead. *
// Clocking - derive a fast internal clock from the incoming 14MHz/85MHz clock.
// (Will be synchronous to the motherboard clock - could use the incoming 25MHz clock
// to create an asynchronous clock if we have any trouble with this.)

wire pll_locked=1'b1;

//clocks clocks (
//	.CLKI(clk2x),
//	.CLKOP(sysclk),
//	.CLKOS(ramclk),
//	.LOCK(pll_locked)
//);

assign cpu_clocks.sysclk = sysclk;
assign cpu_clocks.ramclk = ramclk;

// Supervisor clock, derived from the incoming 25MHz clk
wire svclk;
wire svlocked;
supervisorclk svclocks (
	.CLKI(fpgaclk),
	.CLKOP(svclk),
	.CLKOS(sysclk),
	.CLKOS2(ramclk),
	.CLKOS3(slowclk),
	.LOCK(svlocked)
);
assign cpu_clocks.svclk = svclk;


// Reset signals
// Created by anding the "locked" signals from the two PLLs
// then synchronising the reset into each clock domain.

wire reset_n = svlocked & pll_locked;

reg [1:0] reset_n_sys;
always @(posedge sysclk) begin
	reset_n_sys<={reset_n_sys[0],reset_n};
end
assign cpu_clocks.reset_n_sys = reset_n_sys[1];

reg [1:0] reset_n_sv;
always @(posedge svclk) begin
	reset_n_sv<={reset_n_sv[0],reset_n};
end
assign cpu_clocks.reset_n_sv = reset_n_sv[1];


// Synchronise the incoming clock signal. Shouldn't be necessary if we're using a system
// clock derived from the motherboard clock, but might as well allow for an async clock later on.

reg [2:0] clk7_s;
always @(posedge sysclk)
	clk7_s <= {clk7_s[1:0],clk7};

// Maintain an average count of clock durations.

reg [7:0] clk_acc=(100/7)*7;
reg [4:0] clk_avg=13;

always @(posedge sysclk) begin
	clk_acc <= clk_acc + 1;
	if (clk7_s[1] && !clk7_s[2]) begin // rising edge
		clk_avg <= clk_acc[7:3]; // Divide by 8
		clk_acc <= clk_acc - {3'b0,clk_avg}; // Subtract the current average
	end
end

// posedge
reg [4:0] posctr;

always @(posedge sysclk) begin
	posctr <= posctr - 1;
	if(clk7_s[1] && !clk7_s[2]) begin // Pos edge
		posctr <= clk_avg;
	end
end

wire clk7_en_p = clk7_s[2:1] == 2'b01 ? 1'b1 : 1'b0; // posctr == phase ? 1'b1 : 1'b0;
assign cpu_clocks.clk7_en_p = clk7_en_p;

// negedge
reg [4:0] negctr;

always @(posedge sysclk) begin
	negctr <= negctr - 1;
	if(clk7_s[2] && !clk7_s[1]) begin // Neg edge
		negctr <= clk_avg;
	end
end

wire clk7_en_n = clk7_s[2:1] == 2'b10 ? 1'b1 : 1'b0; // negctr == phase ? 1'b1 : 1'b0;
assign cpu_clocks.clk7_en_n = clk7_en_n;

assign cpu_clocks.clk7 = clk7;

// Generate an E clock
reg [3:0] e_ctr;
reg e;
always @(posedge sysclk) begin
	if(cpu_clocks.clk7_en_n) begin	// Transition on falling edge of clk7
		e_ctr<=e_ctr-1;
		if(e_ctr==4'd0) begin
			e_ctr<=4'd9;
			e<=1'b1;
		end
		if(e_ctr==4'd6) begin
			e<=1'b0;
		end
	end
end
assign cpu_clocks.e_internal=e;

endmodule
