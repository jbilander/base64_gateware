`timescale 1ns / 1ps
`default_nettype none
//
// autoconfig_zii.v — Zorro II autoconfig shell for Base64 (fx68k compat build)
//
// Adapted from Niklas Ekström's SF2000 autoconfig_zii.v. Differences:
//   * SD-card I/O device only (no fastmem device yet — re-add later for SDRAM).
//   * Fully synchronous to the single 85.13 MHz core clock (clk_12x). All bus
//     signals come from the fx68k core itself (clk-domain registered outputs),
//     so there is no metastability and no async C7M/AS clocking.
//   * Generates its own internal DTACK for autoconfig cycles, so the cycle is
//     terminated deterministically regardless of what Gary does with $E8xxxx.
//   * Nybble register values, IDs and write semantics are byte-identical to
//     the SF2000 so the unmodified sfsd.rom / sfsd.device work as-is.
//
// CFGOUT_n is registered on the rising edge of AS (end of cycle), exactly like
// the original, so the E8 decode stays stable for the whole bus cycle in which
// the board becomes configured / shut up.
//
module autoconfig_zii #(
    parameter [15:0] MFG_ID     = 16'h144A, // 5194 - OAHR (Open Amiga Hardware Repository)
    parameter [7:0]  SD_PROD_ID = 8'd11,    // 5194/11 - SD card controller I/O device (64K)
    parameter [15:0] SERIAL     = 16'd0
)(
    input  wire         clk,        // 85.13 MHz core clock
    input  wire         reset,      // active high: ~s_reset_n[1] | ~pwrup_done
    input  wire         cfgin_n,    // synchronized CFGIN pin
    input  wire         as_n,       // core AS
    input  wire         uds_n,      // core UDS
    input  wire         lds_n,      // core LDS
    input  wire         rw,         // core R/W (1 = read)
    input  wire [31:16] a_high,     // core A[31:16] -- see the guard below
    input  wire [6:1]   a_low,      // core A[6:1]
    input  wire [15:12] d_in,       // core write data D[15:12] (oEdb[15:12])
    output reg  [15:12] d_out,      // nybble read data for iEdb mux
    output wire         data_oe,    // 1: select {d_out,12'hFFF} onto iEdb
    output wire         ac_access,  // 1: current bus cycle belongs to autoconfig
    output reg  [7:0]   base_sd,    // assigned base, compared against A[23:16]
    output wire         sd_configured,
    output reg          cfgout_n,   // to CFGOUT pin (replaces cfgin passthrough)
    output reg          dtack_n     // internal DTACK for autoconfig cycles
);

reg configured = 1'b0;
reg shutup     = 1'b0;

assign sd_configured = configured;

wire ds_n = uds_n & lds_n;

// cfgout_n (registered at end-of-cycle) doubles as the "still configuring"
// gate, exactly like the original CFGOUT_n term in autoconfig_access.
// The a[31:24] == $00 guard is REQUIRED on Base64 and cannot matter on the
// SF2000, which is why it is absent from the original. The SF2000 has a
// physical MC68SEC000 with 24 address lines, so $01E8xxxx cannot be
// generated. fx68k drives A31-A24, and fastmem_zii decodes a[31:24] == $08
// for the 16 MB CPU window -- without this guard $08E8xxxx would hit both.
assign ac_access = !cfgin_n && cfgout_n && (a_high == 16'h00E8) && !as_n;
assign data_oe   = ac_access && rw && !ds_n;

// ---------------------------------------------------------------------------
// End-of-cycle edge detect and CFGOUT update
// ---------------------------------------------------------------------------
reg as_n_q;
always @(posedge clk) as_n_q <= as_n;
wire as_rise = as_n & ~as_n_q;

always @(posedge clk) begin
    if (reset)
        cfgout_n <= 1'b1;
    else if (as_rise)
        cfgout_n <= ~(configured | shutup);
end

// ---------------------------------------------------------------------------
// Internal DTACK: assert 8 clk (~94 ns) after AS for our cycles, hold to AS end
// ---------------------------------------------------------------------------
reg [2:0] ack_cnt;
always @(posedge clk) begin
    if (as_n || !ac_access) begin
        dtack_n <= 1'b1;
        ack_cnt <= 3'd0;
    end else begin
        if (ack_cnt == 3'd7)
            dtack_n <= 1'b0;
        else
            ack_cnt <= ack_cnt + 3'd1;
    end
end

// ---------------------------------------------------------------------------
// Read registers (nybbles on D15:12; all inverted except 00, 02, 40, 42)
// Values identical to SF2000 SD device.
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (ac_access && rw) begin
        case (a_low)
            6'h00: d_out <= 4'b1101;            // (00) Zorro II, ROM vector valid
            6'h01: d_out <= 4'b0001;            // (02) 64KB
            6'h02: d_out <= ~SD_PROD_ID[7:4];   // (04) Product number
            6'h03: d_out <= ~SD_PROD_ID[3:0];   // (06) Product number
            6'h04: d_out <= ~4'b1100;           // (08) Can be shut up, 8M preference
            6'h05: d_out <= ~4'b0000;           // (0A) Reserved
            6'h08: d_out <= ~MFG_ID[15:12];     // (10) Manufacturer ID
            6'h09: d_out <= ~MFG_ID[11:8];      // (12)
            6'h0A: d_out <= ~MFG_ID[7:4];       // (14)
            6'h0B: d_out <= ~MFG_ID[3:0];       // (16)
            6'h10: d_out <= ~SERIAL[15:12];     // (20) Serial number
            6'h11: d_out <= ~SERIAL[11:8];      // (22)
            6'h12: d_out <= ~SERIAL[7:4];       // (24)
            6'h13: d_out <= ~SERIAL[3:0];       // (26)
            6'h17: d_out <= ~4'b0001;           // (2E) ROM vector = 0x0001
            6'h20: d_out <= 4'd0;               // (40) No interrupts
            6'h21: d_out <= 4'd0;               // (42) No interrupts
            default: d_out <= 4'hF;             // unimplemented: raw F -> reads 0
        endcase
    end
end

// ---------------------------------------------------------------------------
// Write registers: one-shot strobe per bus cycle (leading edge of DS low).
// 68000 write data is valid before UDS/LDS assert, so d_in is stable here.
// ---------------------------------------------------------------------------
wire ac_wr = ac_access && !ds_n && !rw;
reg  ac_wr_q;
always @(posedge clk) ac_wr_q <= ac_wr;
wire wr_stb = ac_wr & ~ac_wr_q;

always @(posedge clk) begin
    if (reset) begin
        configured <= 1'b0;
        shutup     <= 1'b0;
        base_sd    <= 8'h00;
    end else if (wr_stb) begin
        case (a_low)
            6'h24: begin                    // (48) written second, completes config
                base_sd[7:4] <= d_in;
                configured   <= 1'b1;
            end
            6'h25: base_sd[3:0] <= d_in;    // (4A) written first
            6'h26: shutup <= 1'b1;          // (4C) shut up
            default: ;
        endcase
    end
end

endmodule
