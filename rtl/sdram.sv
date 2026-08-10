//
// sdram.v
//
// sdram controller implementation for the Tang Primer 25k / MiSTer SDRAM
// 
// Copyright (c) 2024 Till Harbaum <till@harbaum.org> 
// Modified by AMR
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//

import sdram_pkg::*;
import board_pkg::*;

`default_nettype none

module sdram #(
	parameter ports = 1,
	parameter sysclk_freq = 85
) (
	input             sdram_in sd_in,
	output            sdram_out sd_out,
	
	// cpu/chipset interface
	input             clk,
	input             reset_n,
	output		      ready, // ram is ready and has been initialized

	// Ports
	input             sdram_request port_req [ports-1:0],
	output            sdram_response port_resp [ports-1:0]
);

localparam tCK = 1000 / sysclk_freq;
localparam tRCD = 15;

localparam RASCAS_DELAY   = tRCD/tCK + 1;
localparam BURST = 8;

localparam BURST_LOG2     = 3'($clog2(BURST)); // 000=1, 001=2, 010=4, 011
localparam ACCESS_TYPE    = 1'b0;   // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd2;   // 2/3 allowed
localparam OP_MODE        = 2'b00;  // only 00 (standard operation) allowed
localparam NO_WRITE_BURST = 1'b1;   // 0= write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LOG2}; 

// ---------------------------------------------------------------------
// ------------------------ cycle state machine ------------------------
// ---------------------------------------------------------------------

localparam STATE_IDLE      = 5'd0;   // first state in cycle
localparam STATE_RAS       = 5'd1;
localparam STATE_BEGIN     = 5'd2;
localparam STATE_CAS       = 5'd3; // STATE_IDLE + RASCAS_DELAY; // command can be continued
localparam STATE_TERMINATE = 5'd5; // STATE_CAS + 2
localparam STATE_READ      = 5'd7; // STATE_CMD_CONT + CAS_LATENCY + 2;
localparam STATE_LAST      = 5'd16; // STATE_READ + BURST + 1;  // last state in cycle

// ---------------------------------------------------------------------
// --------------------------- startup/reset ---------------------------
// ---------------------------------------------------------------------

reg [4:0] state;
reg [4:0] init_state;

// wait 1ms (32 8Mhz cycles) after FPGA config is done before going
// into normal operation. Initialize the ram in the last 16 reset cycles (cycles 15-0)
assign ready = !(|init_state);


//
// Port arbitration
//

reg portatn;
localparam portbits=$clog2(ports)+1;
reg [portbits-1:0] port;
reg [portbits-1:0] nextport;

always @(*) begin // Can move this to being registered if need be.
	portatn = 1'b0;
	nextport = portbits'(0);
	for(int portno=0; portno<ports; ++portno) begin
		if(port_req[portno].req && !port_resp[portno].ack) begin
			portatn =1'b1;
			nextport = portbits'(portno);
		end
	end
end


// ---------------------------------------------------------------------
// ------------------ generate ram control signals ---------------------
// ---------------------------------------------------------------------

// all possible commands
localparam CMD_NOP             = 3'b111;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_BURST_TERMINATE = 3'b110;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

`define sd_cmd {sd_out.ras,sd_out.cas,sd_out.we}

reg [15:0] sd_din;
always @(posedge clk)
	sd_din <= sd_in.d;

//
// Refresh scheduling
//

reg refresh_pending;
localparam refresh_rows = 2**SDRAM_ROW_BITS;
localparam refreshes_per_second = (1000 * refresh_rows) / 64;
localparam refresh_schedule = (sysclk_freq * 1000000) / refreshes_per_second - 1;
reg [10:0] refresh_counter;

reg refreshing;

always @(posedge clk) begin 
	if(refreshing)
		refresh_pending <= 1'b0;

	refresh_counter<=refresh_counter-1;	
	if(refresh_counter[10]) begin // underflow
		refresh_counter <= refresh_schedule[10:0];
		refresh_pending <= 1'b1;
	end
end


//
// Main command sequencer
//

sdram_request req;

always @(posedge clk) begin
	sd_out.cke <=1'b1;
	sd_out.cs <= 1'b0;
	sd_out.we <= 1'b1;
	sd_out.drive <= 1'b0;
	`sd_cmd <= CMD_NOP;
	
	for(int i=0 ; i<ports ; ++i)
		port_resp[i].ack<=1'b0;

	// init state machines runs once reset ends
	if(!reset_n) begin
		init_state <= 5'h1f;
		state <= STATE_IDLE;      
	end else begin
		if(init_state != 0)
			state <= state + 5'd1;

		if((state == STATE_LAST) && (init_state != 0))
			init_state <= init_state - 5'd1;
	end

	if(init_state != 0) begin   
		sd_out.dqm <= 2'b11;

		// initialization takes place at the end of the reset
		if(state == STATE_RAS) begin
			if(init_state == 13) begin
				`sd_cmd <= CMD_PRECHARGE;
				sd_out.a[10] <= 1'b1;      // precharge all banks
			end else if(init_state == 2) begin
				`sd_cmd <= CMD_LOAD_MODE;
				sd_out.a <= MODE;
			end else if(init_state<8) begin
				`sd_cmd <= CMD_AUTO_REFRESH;
			end
		end
	end else begin

		// normal operation, start on ... 
		if(state == STATE_IDLE) begin
			sd_out.dqm <= 2'b11;
			port <= nextport;
			req <= port_req[nextport];

			if(refresh_pending) begin
				`sd_cmd <= CMD_AUTO_REFRESH;
				refreshing<=1'b1;
				state <= STATE_BEGIN;
			end else if(portatn) begin
				state <= STATE_RAS;
			end

		end else begin

			// always advance state unless we are in idle state
			state <= state + 5'd1;

			// -------------------  cpu/chipset read/write ----------------------

			// CAS phase 
			if(state == STATE_RAS) begin

				sd_out.dqm <= 2'b11;
				// RAS phase
				`sd_cmd <= CMD_ACTIVE;
				sd_out.a <= req.addr[SDRAM_ROW_BITS+SDRAM_COLUMN_BITS:SDRAM_COLUMN_BITS+1];
				sd_out.ba <= req.addr[SDRAM_ROW_BITS+SDRAM_COLUMN_BITS+2:SDRAM_ROW_BITS+SDRAM_COLUMN_BITS+1];
			end

			// CAS phase 
			if(state == STATE_CAS && !refreshing) begin
				`sd_cmd <= req.we?CMD_WRITE:CMD_READ;
				sd_out.a <= { 4'b0010, req.addr[SDRAM_COLUMN_BITS:1] };
				sd_out.ba <= req.addr[SDRAM_ROW_BITS+SDRAM_COLUMN_BITS+2:SDRAM_ROW_BITS+SDRAM_COLUMN_BITS+1];
				sd_out.we <= ~req.we;
				sd_out.dqm <= req.we ? req.dm : 2'b00;
				sd_out.q <= req.d;
				sd_out.drive <= req.we;
			end

			if(state == (STATE_TERMINATE) && !refreshing) begin
				if(!req.burst) begin
					`sd_cmd <= req.we ? CMD_NOP : CMD_PRECHARGE;
					sd_out.ba <= req.addr[SDRAM_ROW_BITS+SDRAM_COLUMN_BITS+2:SDRAM_ROW_BITS+SDRAM_COLUMN_BITS+1];
				end
			end

			if(state == STATE_READ) begin
				if(refreshing)
					refreshing<=1'b0;
				else begin
					port_resp[port].q <= sd_din;
					port_resp[port].ack <= 1'b1;
					port_resp[port].fill <= req.burst;
				end
				if(!req.burst)
					state <= STATE_LAST;
			end

			if(state == STATE_LAST) begin
				port_resp[port].fill <= 1'b0;
				state <= STATE_IDLE;
			end

		end
	end
end
   
endmodule
