import cpu_pkg::*;
import base64_m68k_pkg::*;

module m68k_bridge (
	input  m68k_clocks clks,
	output m68k_address_ctrl m_addr,
	output m68k_data_out m_data_out,
	input  m68k_data_in m_data_in,
	output m68k_misc_out m_misc_out,
	input  m68k_misc_in m_misc_in,
	input  cpu_request cpu_req,
	output cpu_response cpu_resp
);

typedef enum logic[3:0] {
	RESET,
	INIT,
	S[0:7],
	P[5:7],
	B[1:2]
} m68k_state;

m68k_state state;

reg reset_pending;

// Sychronise BG and BGACK;
reg br_i,bgack_i;

always @(posedge clks.sysclk) begin
	if(clks.clk7_en_n) begin // Falling edge of clk7 according to 68000 UM
		br_i <= m_misc_in.br;
		bgack_i <= m_misc_in.bgack;
	end
end

always @(posedge clks.sysclk) begin
	case(state)
		RESET: begin
				m_addr.a_en<=1'b0;
				m_addr.drive<=1'b0;
				m_addr.as<=1'b1;
				m_addr.lds<=1'b1;
				m_addr.uds<=1'b1;
				m_addr.rw<=1'b1;
				m_data_out.dq_en<=1'b0;
				m_data_out.drive<=1'b0;
				m_misc_out.vma<=1'b1;
				m_misc_out.bg<=1'b1;
				m_misc_out.reset<=1'b0;
				if(clks.clk7_en_p)
					state <= INIT;
			end
		INIT: begin
			if(clks.clk7_en_p) begin
				m_misc_out.reset<=1'b1;
				state <= S0;
			end
		end

		S0: begin
				// STATE 0 (posedge):
				// The read cycle starts in state 0 (S0). The processor places valid function
				// codes on FC0–FC2 and drives R/W high to identify a read cycle.
				if(clks.clk7_en_p) begin
					m_addr.rw<= 1'b1;
					m_addr.as<=1'b1;
					m_addr.uds<=1'b1;
					m_addr.lds<=1'b1;
					m_addr.a_en<=1'b0;
					m_addr.drive<=1'b0; // Address bus still needs to be high-z.
					m_data_out.drive<=1'b0;
					m_data_out.dq_en<=1'b0; // Data bus high-z

					// Bus arbitration
					if(!br_i) begin // External device wants the bus
						state <= B1;
					end else if(cpu_req.req!=cpu_resp.ack) begin // Regular cycle
						m_misc_out.fc<={cpu_req.supervisor,cpu_req.ifetch,~cpu_req.ifetch};
						state <= S1;
					end
				end
			end
			
		S1: begin
				// STATE 1 (negedge)
				// Entering state 1 (S1), the processor drives a valid address on the address bus.
				if(clks.clk7_en_n) begin
					m_addr.a <= cpu_req.addr[23:1];
					m_addr.a_en<=1'b1;
					m_addr.drive <= 1'b1;
					state <= S2;
				end
			end
			
		S2: begin
				// STATE 2 (posedge)
				// On the rising edge of state 2 (S2), the processor asserts AS and UDS, LDS, or DS (read cycles).
				// asserts AS and drives R/W low (write cycles)
				if(clks.clk7_en_p) begin
					m_addr.as <= 1'b0;
					if(cpu_req.wr) begin
						m_addr.rw <= 1'b0;
					end else begin
						m_addr.uds <= ~cpu_req.dm[1];
						m_addr.lds <= ~cpu_req.dm[0];
					end
					state <= S3;
				end
			end
			
		S3: begin
				// STATE 3 (negedge)
				// During state 3 (S3), no bus signals are altered (read cycles).
				// The data bus is driven out of the high-impedance state as the
				// data to be written is placed on the bus (write cycles).
				if(clks.clk7_en_n) begin
					m_data_out.dq_en<=1'b1;
					if(cpu_req.wr) begin
						m_data_out.q <= cpu_req.d;
						m_data_out.drive <= 1'b1;
					end
					state <= S4;
				end
			end

		S4: begin
				// STATE 4 (posedge)
				// During state 4 (S4), the processor waits for a cycle termination signal
				// (DTACK or BERR) or VPA, an M6800 peripheral signal. When VPA is
				// asserted during S4, the cycle becomes a peripheral cycle (refer to
				// Appendix B M6800 Peripheral Interface). If neither termination signal is
				// asserted before the falling edge at the end of S4, the processor inserts wait
				// states (full clock cycles) until either DTACK or BERR is asserted.
				if(clks.clk7_en_p) begin
					if(cpu_req.wr) begin
						m_addr.uds <= ~cpu_req.dm[1];
						m_addr.lds <= ~cpu_req.dm[0];
					end

					// The test for DTACK should happen at the negedge...
					state <= S5;
				end
			end

		S5: begin
				// STATE 5 (negedge)
				// During state 5 (S5), no bus signals are altered.

				// On the entry to this state (i.e. clock negedge), check for DTACK, etc.
				if(clks.clk7_en_n) begin
					if(m_misc_in.dtack==1'b0) begin
						state <= S6;
					end
					if(m_misc_in.berr==1'b0) begin
						state <= S6;
					end
					if(m_misc_in.vpa==1'b0) begin
						if(!clks.e_internal && !m_misc_out.e) begin // E clock low
							m_misc_out.vma <= 1'b0;
							state <= P5;
						end
					end
				end
			end

		S6: begin
				// STATE 6 (posedge)
				// During state 6 (S6), data from the device is driven onto the data bus.
				if(clks.clk7_en_p) begin
					state <= S7;
				end
			end
			
		S7: begin
				// STATE 7 (negedge)
				// On the falling edge of the clock entering state 7 (S7), the processor latches
				// data from the addressed device and negates AS, U D S, and LDS. At
				// the rising edge of S7, the processor places the address bus in the high-
				// impedance state. The device negates DTACK or BERR at this time.
				cpu_resp.q <= m_data_in.d;
				if(clks.clk7_en_n) begin
					cpu_resp.ack <= cpu_req.req;
					m_addr.as<=1'b1;
					m_addr.uds<=1'b1;
					m_addr.lds<=1'b1;
					state <= S0;
				end
			end
		
		P5: begin
				if(clks.e_internal && !m_misc_out.e) begin // E clock high
					state <= P6;
				end
			end
			
		P6: begin
				if(!clks.e_internal && clks.clk7_en_p) begin // Falling edge of E clock
					cpu_resp.q <= m_data_in.d;
					cpu_resp.ack <= cpu_req.req;
					state <= P7;
				end
			end
		
		P7: begin
				if(clks.clk7_en_n) begin
					m_addr.as<=1'b1;
					m_addr.uds<=1'b1;
					m_addr.lds<=1'b1;
					m_misc_out.vma<=1'b1;
					state <= S0;				
				end
			end

		// Bus arbitration - assert _BG and wait for _BR to drop
		B1: begin
				m_misc_out.bg <= 1'b0;
				if(clks.clk7_en_p) begin
					if(br_i) begin	// External device has dropped _BR
						state <= B2;
					end
				end
			end

		// Bus arbitration - _BR has dropped, release _BG and wait for BGACK to drop
		B2: begin
				m_misc_out.bg <= 1'b1;
				if(clks.clk7_en_p) begin
					if(bgack_i) begin
						state <= S0;
					end
				end
			end
				
		default: begin
				state <= RESET;
			end

	endcase

	if((!clks.reset_n_sys) || (!cpu_req.reset)) begin
		state <= RESET;
		cpu_resp.ack <= 1'b0;
	end

end

always @(posedge clks.sysclk) begin
	if(clks.clk7_en_n) begin // E clock lags behind internal copy by one clock
		m_misc_out.e <= clks.e_internal;
	end
end


endmodule
