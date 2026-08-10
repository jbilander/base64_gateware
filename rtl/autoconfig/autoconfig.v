// Minimig autoconfig logic

`default_nettype none

module autoconfig #(
	parameter AC_BOARDS = 4
) (
	input clk,
	input reset_n,
	input [8:1] address_in,	//cpu address bus input
	output [15:0] data_out,
	input [15:0] data_in,
	input wr,
	input [1:0] fastram_config,
	input m68020,
	output reg [AC_BOARDS-1:0] board_configured,
	output reg autoconfig_done
);


reg [2:0] acdevice;
reg [3:0] ramsize;
wire [8:0] roma_rd;
reg [8:0] roma_wr;
wire [3:0] rom_q;
reg rom_we;

assign roma_rd[5:0] = address_in[6:1];
assign roma_rd[8:6] = acdevice;
assign data_out = {rom_q,12'hfff};

autoconfig_rom acrom
(
	.clk(clk),
	.a_read(roma_rd),
	.a_write(roma_wr),	// We only write to change the size of the ZII RAM board
	.we(rom_we),
	.d(ramsize),
	.q(rom_q)
);

reg init;

always @(posedge clk)
begin
	rom_we<=1'b0;

	if(!reset_n)
	begin
		init<=1'b1;
		board_configured<={AC_BOARDS{1'b0}};
		acdevice<=3'b000;
		ramsize<=4'b1111;	// Disable RAM briefly at reset
		roma_wr<=9'h001;
		autoconfig_done<=1'b0;
	end
	
	if(init)
	begin
		case(fastram_config)
			2'b00 : ramsize <= 4'b1111;  // don't care, disabled
			2'b01 : ramsize <= 4'b0110;	// 2 Meg
			2'b10 : ramsize <= 4'b0111;	// 4 Meg
			2'b11	: ramsize <= 4'b0000;  // 8 Meg
		endcase
		roma_wr[8:0] <= 9'h001;	// Write address for modifying size of ZII RAM.
		rom_we<=1'b1;
	
		// Either 1st board (ZII fast RAM) or null board if RAM is disabled
		acdevice <= |fastram_config ? 3'b000 : 3'b111;
		init<=1'b0;
	end
	else
	begin
		autoconfig_done <= (acdevice==3'b111) ? 1'b1 : 1'b0;
	
		if(wr) begin

			case({address_in,1'b0})
				9'h048 : begin	// Zorro II configures at 48
					case(acdevice)
						3'b000 : begin // ZII RAM
								roma_wr[8:6] <= 3'b001;	// First ZIII entry
								roma_wr[5:0] <= 6'h01;	// Write address for modifying size of 1st ZIII RAM.
								ramsize <= 4'b0000; // 16 meg
								rom_we<=1'b1;

								board_configured[0] <= 1'b1;
								acdevice<=(&fastram_config & m68020) ? 3'b001 : 3'b111; // ZIII RAM or Toccata next
							end
						default :
							;
					endcase
				end
				9'h044 : begin // Zorro III configures at 44 if in ZIII space, should be 48 in ZII space but seems to configure twice?
					case(acdevice)
						3'b001 : begin // ZIII RAM
								board_configured[1] <= 1'b1;
								
								roma_wr[8:6] <= 3'b011;	// Third ZIII entry
								roma_wr[5:0] <= 6'h05;	// Write address for modifying size of 3rd ZIII RAM.
								ramsize <= 4'b0111; // 4 meg 
								rom_we<=1'b1;
								// skip straight to 3'b011 on 32 meg platforms
								acdevice <= 3'b011;	// Leftover space next on 32-meg platforms
							end
						3'b011 : begin // ZIII RAM 3 - Use leftover space in the memory map.
								board_configured[2] <= 1'b1;
								acdevice<= 3'b111; // NULL device to terminate the chain
							end
						3'b100 : begin // ETH
								board_configured[3] <= 1'b1;
								acdevice<=3'b111; // NULL device to terminate the chain
							end
						default:
							;
					endcase
				end
				9'h04c : begin // Zorro II / III shut up register
					case(acdevice)
						3'b101: begin // Shut up Toccata Sound card
								acdevice<=3'b111; // Either control board or NULL device to terminate the chain
							end
						3'b110: begin // Shut up Control board
								acdevice<=3'b111; // NULL device to terminate the chain
							end
						default:
							;
					endcase
				end
				default:
					;
			endcase
		end
	end
end

endmodule
