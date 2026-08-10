import base64_m68k_pkg::*;
import sdram_pkg::*;
import cpu_pkg::*;

`default_nettype none

module tg68wrapper # (
	parameter sysclk_freq
) (
	input m68k_clocks clocks,
	input cpu_response cpu_resp,
	output cpu_request cpu_req,
	input m68k_misc_in socket_miscin, // for IPL, etc.
	input sdram_in sdr_in,
	output sdram_out sdr_out,
	input rxd,
	output txd,
	input spi_cipo,
	output spi_copi,
	output reg spi_cs,
	output spi_clk,
	input reset_btn
);

// Reset signal controllable over JTAG - set initial state here.
reg jtag_reset_n = 1'b1;


// State machine states

typedef enum logic[3:0] {
	RESET,
	INIT,
	REQ,
	DECODE,
	WAIT,
	WAIT_INTERNAL,
	PERIPHERAL,
	FASTRAM,
	AUTOCONFIG,
	ROM,
	SPI,
	CLKENA
} state_t;

state_t state=RESET;


// CPU clkena pulses must be at least 4 clocks apart.
reg clkena;
reg [2:0] slower;

always @(posedge clocks.sysclk) begin
	slower<={1'b1,slower[2:1]};
	if(clkena)
		slower<=0;
end


// Main CPU signals

wire [31:0] tg68_addr;
reg  [15:0] tg68_din;
wire [15:0] tg68_dout;
wire tg68_lds,tg68_uds,tg68_wr;
wire [1:0] tg68_state;
wire [2:0] tg68_fc;
wire tg68_reset_out;
reg  tg68_reset_in;

// Address decoding

// We need the decode the following regions:
// First n kb for boot ROM
// UART and SPI register block at 0x01000000
// 32-bit Fast RAM, most likely at 0x40000000
// 24-bit Fast RAM at 0x200000
// Kickstart ROM at 0xf80000 - either forward to motherboard or handle ourselves
// Autoconfig range at 0xe80000
// CIA at 0xbfe001 - for control of OVL bit
// (Maybe Akiko at 0xb80000 for C2P converter?)


// These are critical timewise, so we generate them combinationally:

wire sel_24bit = tg68_addr[31:24] == 8'h0 ? 1'b1 : 1'b0;
wire sel_fast24_2 = tg68_addr[23:21] == 3'h1 ? 1'b1 : 1'b0; // 0x200000 - 0x3fffff
wire sel_fast24_4 = tg68_addr[23:21] == 3'h2 ? 1'b1 : 1'b0; // 0x400000 - 0x5fffff
wire sel_fast24_6 = tg68_addr[23:21] == 3'h3 ? 1'b1 : 1'b0; // 0x600000 - 0x7fffff
wire sel_fast24_8 = tg68_addr[23:21] == 3'h4 ? 1'b1 : 1'b0; // 0x800000 - 0x9fffff

wire sel_fast24 = sel_24bit & (sel_fast24_2 | sel_fast24_4 | sel_fast24_6 | sel_fast24_8);

wire sel_fast32 = tg68_addr[31:27] == 5'h0 && tg68_addr[26]==1'b1 ? 1'b1 : 1'b0;

// The rest can be handled on a more relaxed schedule, so we use a latched copy
// of the address. We also mux between the CPU and JTAG interface here.

localparam DEVICE_CPU=1'b0;
localparam DEVICE_JTAG=1'b1;
reg selecteddevice;

reg [31:0] tg68_addr_d;
always @(posedge clocks.sysclk) begin
	case (selecteddevice)
		DEVICE_JTAG : begin
				tg68_addr_d <= jtag_user_addr;
			end
		default : begin
				tg68_addr_d <= tg68_addr;
			end
	endcase
end

reg softkick_ena;
reg softkick_overlay;

wire sel_slowram = tg68_addr_d[31:20] == 12'h00c ? 1'b1 : 1'b0;
wire sel_autoconfig = ((!ac_done) && (tg68_addr_d[31:16] == 16'h00e8)) ? 1'b1 : 1'b0;
wire sel_bootrom = tg68_addr_d[31:16] == 16'h0000 && bootrom_ena ? 1'b1 : 1'b0;
wire sel_kickoverlay = tg68_addr_d[31:16] == 16'h0000 && softkick_ena && softkick_overlay ? 1'b1 : 1'b0;
wire sel_softkick = (tg68_addr_d[31:20] == 12'hfff || tg68_addr_d[31:20] == 12'h00f) && tg68_addr_d[19]==1'b1 && softkick_ena ? 1'b1 : 1'b0;
wire sel_cia = tg68_addr_d[31:16] == 16'h00bf ? 1'b1 : 1'b0;
wire sel_peripherals = tg68_addr_d[31:24] == 8'h01 ? 1'b1 : 1'b0;
wire sel_serdat = tg68_addr_d[31:0] == 32'h00dff030 ? 1'b1 : 1'b0;


// Interface between JTAG user codes
// and the Amiga.
reg [31:0] jtag_user_addr;
reg [31:0] jtag_user_d;
reg [31:0] jtag_user_q;
reg jtag_user_req;
reg jtag_user_ack;
reg jtag_user_wr;
reg jtag_user_stb;

// JTAG SDRAM select signals
wire jtag_sel_fast24 = jtag_user_addr[31:24] == 8'h0 && (jtag_user_addr[23:20] == 4'h2) ? 1'b1 : 1'b0; // FIXME - decode up to 8 meg here
wire jtag_sel_fast32 = jtag_user_addr[31:27] == 5'h0 && jtag_user_addr[26]==1'b1 ? 1'b1 : 1'b0;


// Boot ROM

reg bootrom_ena;
reg  [15:0] bootrom_d;
wire [15:0] bootrom_q;
reg bootrom_we;
reg  [1:0] bootrom_bs;
wire [15:1] bootrom_a;

Firmware_ROM #(
	.addr_width(15)
	) rom_inst (
	.clk(clocks.sysclk),
	.addr(bootrom_a),
	.q(bootrom_q),
	.d(bootrom_d),
	.we(bootrom_we),
	.bs(bootrom_bs)
);

assign bootrom_a = tg68_addr_d[15:1];


// Peripherals:
// UART

reg  [7:0] uart_d;
reg  uart_stb;
wire [7:0] uart_q;
wire uart_rxint;
wire uart_txready;
reg  uart_rxpending;

uart uart_inst (
	.clk(clocks.sysclk),
	.reset_n(clocks.reset_n_sys),
	.clkdiv(16'((sysclk_freq * 10000) / 1152)),
	.d(uart_d),
	.d_stb(uart_stb),
	.q(uart_q),
	.rxint(uart_rxint),
	.txready(uart_txready),
	.txint(),
	.rxd(rxd),
	.txd(txd)
);

localparam STATE_FETCH = 2'b00;
localparam STATE_INTERNAL = 2'b01;
localparam STATE_READ = 2'b10;
localparam STATE_WRITE = 2'b11;

reg [1:0] tg68_reset_s;
reg [10:0] reset_debounce_ctr=0;
wire reset_debounced = reset_debounce_ctr[10];

always @(posedge clocks.sysclk) begin
	if(!reset_debounced)
		reset_debounce_ctr<=reset_debounce_ctr+1;

	tg68_reset_s <= {tg68_reset_s[0],socket_miscin.reset};
	if(!tg68_reset_s[1])
		reset_debounce_ctr<=0;
end


// SD card

localparam spi_speed_slow = (sysclk_freq * 10 ) / 4;
localparam spi_speed_fast = sysclk_freq  / 25;
reg spi_speed_sel;
wire [7:0] spi_speed;
wire spi_busy;
reg [7:0] spi_d;
reg spi_d_stb;
wire [7:0] spi_q;

assign spi_speed = spi_speed_sel ? spi_speed_fast : spi_speed_slow;

spi spi_inst (
	.clk(clocks.sysclk),
	.reset_n(clocks.reset_n_sys),
	.d(spi_d),
	.d_stb(spi_d_stb),
	.q(spi_q),
	.busy(spi_busy),
	.speed(spi_speed),
	.copi(spi_copi),
	.cipo(spi_cipo),
	.sck(spi_clk)
);

// SDRAM 

wire sdram_ready;

sdram_request sdr_req[0:0];
sdram_response sdr_resp[0:0];

assign sdr_req[0].addr[18:0] =  tg68_addr_d[18:0];
assign sdr_req[0].addr[24:19] = sel_kickoverlay ? 6'h3f :
                             sel_softkick ? 6'h3f :
                             tg68_addr_d[24:19];

sdram #(
	.ports(1),
	.sysclk_freq(sysclk_freq)
) sdram_ctrl (
	.sd_in(sdr_in),
	.sd_out(sdr_out),

	.clk(clocks.sysclk),
	.reset_n(clocks.reset_n_sys),
	.ready(sdram_ready),

	.port_req(sdr_req),
	.port_resp(sdr_resp)
);

// CPU to peripheral bridge state machine

wire initialreset = clocks.reset_n_sys & reset_btn & sdram_ready;
wire sm_reset = initialreset & jtag_reset_n & reset_debounced;

reg jtag_romsel_stb;
reg jtag_romsel;

reg cpureset_d;

reg [15:0] ac_d;
wire [15:0] ac_q;
reg ac_wr;
wire ac_done;

// Autoconfig module
autoconfig ac_inst (
	.clk(clocks.sysclk),
	.reset_n(sm_reset),
	.address_in(tg68_addr_d[8:1]),
	.data_out(ac_q),
	.data_in(ac_d),
	.wr(ac_wr),
	.fastram_config(2'b10),
	.m68020(1'b0),
	.board_configured(),
	.autoconfig_done(ac_done)
);

always @(posedge clocks.sysclk) begin
	clkena <= 1'b0;

	cpureset_d <= tg68_reset_out;

	cpu_req.reset <= jtag_reset_n & (tg68_reset_out | ~cpureset_d); // We need to avoid a feedback loop on cpu-triggered resets

    tg68_reset_in <= sm_reset;

	bootrom_we <= 1'b0;
	uart_stb <= 1'b0;

	spi_d_stb <= 1'b0;

	jtag_user_stb <= 1'b0;

	case(state)
		RESET: begin
			uart_rxpending <= 1'b0;
			cpu_req.req <= 1'b0;
			clkena <= 1'b0;
            tg68_reset_in <= 1'b0;
            sdr_req[0].req <= 1'b0;
			sdr_req[0].burst <= 1'b0;
			state <= INIT;
		end

		INIT: begin
			state <= DECODE;
		end

		DECODE: begin
			if(jtag_user_req != jtag_user_ack) begin
				if(selecteddevice==DEVICE_CPU) begin
					selecteddevice<=DEVICE_JTAG; // Switch to JTAG mode and give 
					state <= WAIT_INTERNAL;      // address decoding time to catch up.
				end else begin
					state <= REQ;
				end
			end else begin
				if(tg68_state == STATE_INTERNAL) begin
					if(slower[1] && !clkena) begin
						clkena <= 1'b1;
						state <= WAIT_INTERNAL;
					end
				end else if(slower[1] && !clkena) begin
					if(sel_fast24 || sel_fast32) begin // We need to handle Fast RAM requests as promptly as possible
						sdr_req[0].we <= tg68_state == STATE_WRITE ? 1'b1 : 1'b0;
						sdr_req[0].d <= tg68_dout;
						sdr_req[0].dm <= {tg68_uds,tg68_lds};
						sdr_req[0].burst <= 1'b0;
						sdr_req[0].req <= 1'b1;
						state <= FASTRAM;
					end else begin
						state <= REQ;	// Handle other requests a cycle later
					end
				end
			end
		end
		
		FASTRAM : begin
			if(sdr_resp[0].ack) begin
				sdr_req[0].req <= 1'b0;
				case(selecteddevice)
					DEVICE_JTAG : begin
							jtag_user_d <= {16'b0,sdr_resp[0].q};
							selecteddevice <= DEVICE_CPU;
							jtag_user_ack <= jtag_user_req;
							jtag_user_stb <= 1'b1;
							state <= WAIT_INTERNAL;
						end
					default : begin
							tg68_din <= sdr_resp[0].q;
							clkena <= 1'b1;
							state <= DECODE;
						end
				endcase
			end
		end

		ROM: begin
			tg68_din <= bootrom_q;
			clkena <= 1'b1;
			state <= DECODE;
		end

		REQ: begin
			if(sel_peripherals) begin
				case(tg68_addr_d[11:8])
				
					4'd0: begin // UART
						uart_d <= tg68_dout[7:0];
						tg68_din <= {6'b0,uart_rxpending,uart_txready,uart_q};
						if(tg68_state == STATE_WRITE) begin
							if(uart_txready) begin
								uart_stb <= 1'b1;
								clkena <= 1'b1;
								state <= DECODE;
							end
						end else begin
							uart_rxpending<=1'b0;
							clkena <= 1'b1;
							state <= DECODE;
						end

					end

					4'd1: begin // SPI SD card
						if(tg68_addr_d[2] && ~spi_busy) begin // Data register
							spi_d <= tg68_dout[7:0];
							if(tg68_state == STATE_WRITE)
								spi_d_stb <= 1'b1;
							state <= SPI;
						end else if(~spi_busy) begin // CS register
							if(tg68_state == STATE_WRITE) begin
								spi_speed_sel <= tg68_dout[8];
								spi_cs <= ~tg68_dout[0];
							end
							tg68_din <= {spi_busy,15'd0};
							clkena <= 1'b1;
							state <= DECODE;
						end
					end

					4'd2 : begin // Control register
						if(tg68_state == STATE_WRITE && tg68_addr_d[2]==1'b0) begin
							bootrom_ena <= tg68_dout[0];
							softkick_ena <= tg68_dout[1];
							clkena <= 1'b1;
							state <= RESET;
						end
					end

					default : begin
						clkena <= 1'b1;
						state <= DECODE;
					end
				endcase
			end else if(sel_bootrom) begin
				bootrom_d <= tg68_dout;
				bootrom_bs <= {~tg68_uds,~tg68_lds};
				bootrom_we <= ~tg68_wr;
				state <= ROM;

			end else if(sel_autoconfig && !ac_done) begin
				// Autoconfig - once we've configured our own devices
				// the autoconfig address range goes to the motherboard
				// where any "real" autoconfig devices will be configured
				// as usual.
				ac_wr<=(tg68_state == STATE_WRITE) ? 1'b1 : 1'b0;
				ac_d <= tg68_dout;
				state <= AUTOCONFIG;

			end else if(sel_slowram) begin // Temporarily disable slowram

				tg68_din <= 16'hffff;
				clkena <= 1'b1;
				state <= DECODE;

			end else if(sel_kickoverlay || sel_softkick) begin
				sdr_req[0].we <= 1'b0;
				sdr_req[0].dm <= 2'b00;
				sdr_req[0].req <= 1'b1;
				state <= FASTRAM;
			end else begin

				if(sel_cia && tg68_state == STATE_WRITE) // First write to CIA registers cancels overlay
					softkick_overlay <= 1'b0;

				cpu_req.addr <= tg68_addr_d;
				if(selecteddevice==DEVICE_JTAG) begin
					if(jtag_sel_fast24 || jtag_sel_fast32) begin // SDRAM
						sdr_req[0].we <= jtag_user_wr;
						sdr_req[0].d <= jtag_user_q[15:0];
						sdr_req[0].dm <= 2'b00;
						sdr_req[0].req <= 1'b1;
						state <= FASTRAM;
					end else begin
						cpu_req.d <= jtag_user_q[15:0];
						cpu_req.dm <= 2'b11; // Probably don't need byte-level access over JTAG.
						cpu_req.wr <= jtag_user_wr;
						cpu_req.ifetch <= 1'b0;
						cpu_req.req<=~cpu_resp.ack;
						state <= WAIT;
					end	
				end else begin
					cpu_req.d <= tg68_dout;
					cpu_req.dm <= {~tg68_uds,~tg68_lds};				
					case(tg68_state)
						STATE_FETCH: begin // Instruction fetch
								cpu_req.req<=~cpu_resp.ack;
								cpu_req.wr <= 1'b0;
								cpu_req.ifetch <= 1'b1;
							end
						STATE_INTERNAL: begin // Internal cycle
							end
						STATE_READ: begin // Data read
								cpu_req.req<=~cpu_resp.ack;
								cpu_req.wr <= 1'b0;
								cpu_req.ifetch <= 1'b0;
							end
						STATE_WRITE: begin // Data write
								cpu_req.req<=~cpu_resp.ack;
								cpu_req.wr <= 1'b1;
								cpu_req.ifetch <= 1'b0;
								if(sel_serdat) begin
									uart_d <= tg68_dout[7:0];
									uart_stb <= 1'b1;
								end
							end			
					endcase
					state <= WAIT;
				end
			end
		end

		PERIPHERAL : begin
		
		end

		AUTOCONFIG : begin
			tg68_din <= ac_q;
			ac_wr <= 1'b0;
			state <= CLKENA;
		end

		SPI : begin
			if(!spi_busy) begin
				tg68_din <= {8'd0,spi_q};
				clkena <= 1'b1;
				state <= DECODE;
			end
		end

		WAIT: begin
			if(slower[0] && (cpu_resp.ack==cpu_req.req)) begin
				case(selecteddevice)
					DEVICE_JTAG : begin
							jtag_user_d <= {16'b0,cpu_resp.q};
							selecteddevice <= DEVICE_CPU;
							jtag_user_ack <= jtag_user_req;
							jtag_user_stb <= 1'b1;
							state <= WAIT_INTERNAL;
						end
					default : begin
							tg68_din <= cpu_resp.q;
							// clkena <=1'b1;
							state <= CLKENA;
						end
				endcase
			end
		end

		CLKENA: begin
			clkena <=1'b1;
			state <= DECODE;
		end

		WAIT_INTERNAL :
			state <= DECODE;

		default :
			state <= INIT;

	endcase

	if(uart_rxint)
		uart_rxpending<=1'b1;

	if(!initialreset) begin
		bootrom_ena <= 1'b1;
		softkick_ena <= 1'b0;
	end	

	if(jtag_romsel_stb) begin
		softkick_ena <= jtag_romsel;
		bootrom_ena <= 1'b0;
		state <= RESET;
	end

	if(!sm_reset) begin
		state <= RESET;
		spi_speed_sel <= 1'b0;
		spi_cs <= 1'b1;
		softkick_overlay <= 1'b1;
		jtag_user_ack <= 1'b0;
	end

end

reg [2:0] ipl;
reg [2:0] ipl_prev;

always @(posedge clocks.sysclk) begin	// Sample IPL on the clk7 posedge and do some basic filtering.
	if(clocks.clk7_en_p) begin
		ipl_prev <= socket_miscin.ipl;
		if(socket_miscin.ipl==ipl_prev)
			ipl <= ipl_prev;
	end
end

TG68KdotC_Kernel tg68 (
	.clk(clocks.sysclk),
	.nReset(tg68_reset_in),
	.clkena_in(clkena),
	.data_in(tg68_din),
	.IPL(ipl),
	.IPL_autovector(1'b0),
	.berr(1'b0),
	.CPU(2'b11),
	.addr_out(tg68_addr),
	.data_write(tg68_dout),
	.nWr(tg68_wr),
	.nUDS(tg68_uds),
	.nLDS(tg68_lds),
	.busstate(tg68_state),
	.longword(),
	.nResetOut(tg68_reset_out),
	.FC(tg68_fc),
	.clr_berr(),
	.skipFetch(),
	.regin_out(),
	.CACR_out(),
	.VBR_out()
);

reg screenwhite;
always @(posedge clocks.sysclk) begin
	if(tg68_addr[23:0] == 24'hdff180 && tg68_dout[11:0] == 12'hfff && clkena==1'b1)
		screenwhite <= 1'b1;
	if(!tg68_reset_in)
		screenwhite <= 1'b0;
end

// JTAG capture module to monitor the cpu bus lines
// Capturewidth must be wide enough to accommodate
// the command set for remote 
localparam capturewidth = 43;
localparam capturedepth = 12;
wire [capturewidth-1:0] jtag_d;
wire [capturewidth-1:0] jtag_q;
wire jtag_update;

assign jtag_d[1:0] = tg68_state;
assign jtag_d[2] = tg68_reset_in;
assign jtag_d[34:3] = tg68_addr_d;
assign jtag_d[35] = socket_miscin.dtack;
assign jtag_d[39:36] = state;
assign jtag_d[40] = sel_autoconfig;
assign jtag_d[41] = clkena;
assign jtag_d[42] = 1'b0; // Eaten by compression

/* The capture happens one clock after trigger conditions are met.
   Delaying the clkena stb by a couple of cycles means the data
   from TG68 should have stabilised. */
reg [2:0] jtag_stb;
always @(posedge clocks.sysclk) begin
	jtag_stb <= {clkena,jtag_stb[2:1]};
end

wire [3:0] user_ir;

jcapture #(
    .capturewidth(capturewidth),
    .capturedepth(capturedepth),
    .triggerwidth(capturewidth),
    .designid(16'h68ff)
) capture_inst (
	.clk(clocks.sysclk),
    .stb(jtag_stb[0]),
	.reset_n(clocks.reset_n_sys), // clocks.reset_n_sys),
	.capture_d(jtag_d),
	.user_ir(user_ir),
	.user_ir_update(),
	.user_d({11'b0,jtag_user_d}),
	.user_q(jtag_q),
	.user_update(jtag_update)
);

// Need a way to remotely upload a ROM, which means
// defining a command set.

localparam usercmd_reset = 4'd0; 
localparam usercmd_kickselect = 4'd1;
localparam usercmd_address = 4'd2;
localparam usercmd_read = 4'd3;
localparam usercmd_write = 4'd4;

always @(posedge clocks.sysclk) begin
	jtag_romsel_stb <= 1'b0;
	if(jtag_update) begin
		case(user_ir)

			usercmd_reset : begin
				jtag_reset_n <= ~jtag_q[0];
			end

			usercmd_kickselect : begin
				jtag_romsel <= jtag_q[0];
				jtag_romsel_stb <= 1'b1;
			end

			usercmd_address : begin
				jtag_user_addr <= jtag_q[31:0];
			end

			usercmd_read : begin
				jtag_user_wr <= 1'b0;
				jtag_user_req <= ~jtag_user_ack;
			end

			usercmd_write : begin
				jtag_user_wr <= 1'b1;
				jtag_user_q <= jtag_q[31:0];
				jtag_user_req <= ~jtag_user_ack;
			end

			default : 
				;

		endcase

		if(jtag_user_stb) // Increment address - FIXME : not working - why?
			jtag_user_addr <= jtag_user_addr + 2;
	end
end

endmodule
