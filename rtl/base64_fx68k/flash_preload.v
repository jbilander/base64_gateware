`timescale 1ns / 1ps
`default_nettype none
//
// flash_preload.v — streams the 32KB driver ROM from the W25Q256JV config
// flash into the sd_subsystem BRAM during the power-up hold. OPTIONAL: the
// BRAM already initialises from sfsd.mem in the bitstream, so this module is
// only needed once you want to update the driver with ecpprog instead of a
// rebuild:
//
//     ecpprog -d i:0x0403:0x6010 -I A -o 0x100000 sfsd.rom
//
// Runs ONCE per power-up (FSM starts from initial values, no reset input —
// BRAM contents persist across warm resets, matching real ROM behaviour).
//
// SPI: mode 0, command 0x03 (READ), 3-byte address (0x100000 is within the
// 16MB 3-byte window of the W25Q256JV, which powers up in 3-byte mode).
// SCK = clk/4 = 21.28 MHz (0x03 is good to 50 MHz on this part, so ample
// margin). Load time: 32768 bytes * 8 bits / 21.28 MHz ~= 12.3 ms + 96 us
// settle — comfortably inside the existing ~98 ms pwrup hold.
//
// The ECP5's MCLK pin is only reachable through the USRMCLK primitive; CS_n,
// MOSI (SISPI) and MISO are ordinary user I/O after configuration. On the
// iCESugar-Pro v1.3: CS_n = N8, MOSI = T8, MISO = T7.
//
// Integration: gate the power-up hold on load_done, e.g.
//     pwrup_done = pwrup_cnt[23] & load_done;
// and connect rom_we/rom_waddr/rom_wdata to sd_subsystem.
//
// If the first byte read back looks wrong, the likely cause is the flash
// left in a continuous-read mode by configuration; prepend a mode-reset
// (0xFF 0xFF with CS low, then CS high) or a 0x66/0x99 software reset state
// before HDR. Not expected with standard-SPI SYSCONFIG, so omitted here.
//
module flash_preload #(
    parameter [23:0] FLASH_ADDR = 24'h100000,
    parameter [15:0] LEN_M1     = 16'd32767    // bytes - 1
)(
    input  wire        clk,          // 85.13 MHz
    output reg         load_done = 1'b0,
    // BRAM write port
    output reg         rom_we    = 1'b0,
    output reg  [14:0] rom_waddr = 15'd0,
    output reg  [7:0]  rom_wdata = 8'd0,
    // SPI flash pins (SCK internal via USRMCLK)
    output reg         spi_cs_n  = 1'b1,
    output wire        spi_mosi,
    input  wire        spi_miso
);

reg sck = 1'b0;

// The only path to the config-flash clock pin on ECP5.
USRMCLK usrmclk_i (
    .USRMCLKI (sck),
    .USRMCLKTS(1'b0)
) /* synthesis syn_noprune = 1 */;

reg [7:0] shreg = 8'h00;
assign spi_mosi = shreg[7];

localparam [1:0] W_SETTLE = 2'd0,
                 HDR      = 2'd1,   // 0x03 + 3 address bytes
                 DATA     = 2'd2,
                 DONE     = 2'd3;

reg [1:0]  state   = W_SETTLE;
reg [12:0] settle  = 13'd0;     // ~96 us at 85.13 MHz
reg [1:0]  phase   = 2'd0;      // clk/4 -> SCK 21.28 MHz
reg [2:0]  bitcnt  = 3'd7;
reg [1:0]  hdr_idx = 2'd0;
reg [7:0]  rx      = 8'd0;
reg [15:0] bcnt    = 16'd0;

always @(posedge clk) begin
    rom_we <= 1'b0;

    case (state)
        W_SETTLE: begin
            spi_cs_n <= 1'b1;
            sck      <= 1'b0;
            settle   <= settle + 13'd1;
            if (&settle) begin
                state    <= HDR;
                spi_cs_n <= 1'b0;
                shreg    <= 8'h03;      // READ
                hdr_idx  <= 2'd0;
                bitcnt   <= 3'd7;
                phase    <= 2'd0;
            end
        end

        HDR, DATA: begin
            phase <= phase + 2'd1;
            if (phase == 2'd1) begin
                sck <= 1'b1;                        // rising edge: sample
                rx  <= {rx[6:0], spi_miso};
            end else if (phase == 2'd3) begin
                sck <= 1'b0;                        // falling edge: shift
                if (bitcnt == 3'd0) begin
                    bitcnt <= 3'd7;
                    if (state == HDR) begin
                        case (hdr_idx)
                            2'd0: shreg <= FLASH_ADDR[23:16];
                            2'd1: shreg <= FLASH_ADDR[15:8];
                            2'd2: shreg <= FLASH_ADDR[7:0];
                            2'd3: begin
                                shreg <= 8'hFF;     // don't-care during read
                                state <= DATA;
                                bcnt  <= 16'd0;
                            end
                        endcase
                        hdr_idx <= hdr_idx + 2'd1;
                    end else begin                  // DATA: byte complete in rx
                        rom_we    <= 1'b1;
                        rom_waddr <= bcnt[14:0];
                        rom_wdata <= rx;
                        shreg     <= 8'hFF;
                        if (bcnt == LEN_M1)
                            state <= DONE;
                        bcnt <= bcnt + 16'd1;
                    end
                end else begin
                    bitcnt <= bitcnt - 3'd1;
                    shreg  <= {shreg[6:0], 1'b1};
                end
            end
        end

        DONE: begin
            spi_cs_n  <= 1'b1;
            sck       <= 1'b0;
            load_done <= 1'b1;
        end
    endcase
end

endmodule
