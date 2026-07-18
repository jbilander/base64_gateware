`timescale 1ns / 1ps
`default_nettype none
//
// sd_subsystem.v — Base64 internal SD-card device (replaces SF2000 sdio.v +
// external ROM chip + the main_top.v glue around sdcard.v).
//
// Wraps Niklas Ekström's sdcard.v UNCHANGED. The physical 32KB boot ROM of the
// SF2000 is replaced by a 32K x 8 EBR block, initialised from sfsd.mem
// ($readmemh) and optionally overwritable at power-up by flash_preload.v.
//
// Bus contract (identical to SF2000, derived from DISASSEMBLING sfsd.rom's
// DiagArea — see sd_autoboot_adaptation.md):
//   * 64KB Zorro II I/O space at base_sd << 16.
//   * While sd_enabled == 0, reads in the space return ROM byte n at BYTE
//     offset 2n+1 (ROM vector = 0x0001: the ROM logically lives at ODD
//     addresses on the LOW data lane, D[7:0], like a classic byte-wide diag
//     ROM). We mirror the byte on both lanes ({rom_q, rom_q}) since the
//     software only ever does byte reads here. The DiagArea is nybble-packed
//     (KS <= 1.3 lacks DAC_BYTEWIDE): KS takes bits 7:4 of each odd byte;
//     the bootloader's own callback composes the driver payload from odd
//     bytes at base + romvec + 0xCC0 stepping by 2.
//   * The first WRITE anywhere in the space sets sd_enabled: reads then go to
//     the sdcard register file. Writes always go to sdcard.v. Reset clears
//     sd_enabled so the overlay returns for the next autoconfig pass.
//   * DTACK for the whole space (ROM reads included) comes from sdcard.v's
//     internal generator, as on the SF2000. CPU_SPEED_SWITCH MUST be tied 0
//     (solid DTACK, the SF2000's proven 7 MHz-mode config): with 1 the
//     generator pulses DTACK low 1-in-4 clks, and fx68k samples DTACK once
//     per 12 clks with 12 mod 4 = 0, so the phase-locked sample can miss the
//     pulse forever (hung bus cycle at the DiagArea copy). ROM read data is
//     valid ~2 clk after AS, long before the core recognises DTACK (~S4).
//
module sd_subsystem #(
    parameter ROM_INIT_FILE = "sfsd.mem"
)(
    input  wire         clk,        // 85.13 MHz core clock
    input  wire         reset,      // active high: ~s_reset_n[1] | ~pwrup_done
    // core-side bus (fx68k outputs, clk domain)
    input  wire [23:1]  a,
    input  wire         as_n,
    input  wire         uds_n,
    input  wire         lds_n,
    input  wire         rw,         // 1 = read
    input  wire [15:0]  d_in,       // core write data (oEdb)
    // from autoconfig
    input  wire         sd_configured,
    input  wire [7:0]   base_sd,
    // to base64_top muxes
    output wire         sd_space,   // this bus cycle belongs to the SD device
    output wire [15:0]  d_out,      // read data for iEdb mux (valid when sd_space & rw)
    output wire         dtack_n,    // internal DTACK for SD-space cycles
    // ROM preload write port (tie rom_we=0 if flash_preload not instantiated)
    input  wire         rom_we,
    input  wire [14:0]  rom_waddr,
    input  wire [7:0]   rom_wdata,
    // SD card pins (iCESugar-Pro on-module micro-SD slot, SPI mode)
    input  wire         sd_miso,
    input  wire         sd_cd_n,    // tie 1'b0 at instantiation: slot has no CD line
    output wire         sd_ss_n,
    output wire         sd_sclk,
    output wire         sd_mosi
);

wire ds_n = uds_n & lds_n;

assign sd_space = sd_configured && (a[23:16] == base_sd) && !as_n;

// ---------------------------------------------------------------------------
// Boot ROM overlay enable — first write to the space switches reads from ROM
// to the sdcard register file (SF2000 main_top.v sd_enabled logic).
// ---------------------------------------------------------------------------
reg sd_enabled = 1'b0;
always @(posedge clk) begin
    if (reset)
        sd_enabled <= 1'b0;
    else if (sd_space && !ds_n && !rw)
        sd_enabled <= 1'b1;
end

// ---------------------------------------------------------------------------
// 32 KB boot ROM in EBR (16 blocks), true dual use: read port on the bus
// address, write port for the optional flash preloader. Initialised at
// configuration time from sfsd.mem (one 2-digit hex byte per line).
// NOTE Diamond build trap: like microrom.mem/nanorom.mem, sfsd.mem must be
// present in the impl1/ working directory and is deleted by "Clean".
// ---------------------------------------------------------------------------
reg [7:0] rom_mem [0:32767];
initial $readmemh(ROM_INIT_FILE, rom_mem);

reg [7:0] rom_q;
always @(posedge clk) begin
    if (rom_we)
        rom_mem[rom_waddr] <= rom_wdata;
end
always @(posedge clk) begin
    rom_q <= rom_mem[a[15:1]];
end

// ---------------------------------------------------------------------------
// SPI SD controller — Niklas Ekström's module, byte-identical source.
// C100M and CLKCPU are the same 85.13 MHz clock here; the internal 3FF
// wr/rd_sync edge detectors simply add a couple of cycles of latency.
// Effective SCLK = 85.13 MHz / (2 * (clk_div + 1)) — ~15% slower than the
// SF2000 at the same driver clk_div values, everywhere within SD spec.
// ---------------------------------------------------------------------------
wire [15:0] sd_data_out;
wire        sd_data_oe;   // read indicator from sdcard.v (unused: iEdb mux keys on sd_space & rw)

sdcard sdcontrol(
    .C100M           (clk),
    .CLKCPU          (clk),
    .RESET_n         (~reset),
    .ADDR            (a[4:1]),
    .ACCESS          (sd_space),
    .RW_n            (rw),
    .UDS_n           (uds_n),
    .LDS_n           (lds_n),
    .AS_CPU_n        (as_n),
    .DS_n            (ds_n),
    .D_IN            (d_in),
    .MISO            (sd_miso),
    .CD_n            (sd_cd_n),
    .CPU_SPEED_SWITCH(1'b0),      // MUST be 0: with 1 the DTACK generator
                                  // PULSES (low 1-in-4 clks); fx68k samples
                                  // DTACK once per 12 clks and 12 mod 4 = 0,
                                  // so the sample is phase-locked and can
                                  // permanently miss the pulse -> hung cycle.
                                  // 0 = solid DTACK, the SF2000's proven
                                  // 7 MHz-mode configuration.
    .DATA_OE         (sd_data_oe),
    .INT2_n          (),          // not used (driver polls); future: inject via IPL mux
    .SS_n            (sd_ss_n),
    .SCLK            (sd_sclk),
    .MOSI            (sd_mosi),
    .DTACK_n         (dtack_n),
    .DATA_OUT        (sd_data_out)
);

// ROM byte mirrored on BOTH lanes. The proven access protocol (from
// disassembling the DiagArea) is byte reads at ODD addresses (ROM vector =
// 0x0001 -> low lane, D[7:0]): both the KS nibble copy (nibble = bits 7:4 of
// the byte read) and the bootloader's read-longword callback (move.b (a4);
// addq.l #2,a4 from base+romvec+0xCC0, an odd address) use LDS byte reads.
// Mirroring also covers even-address reads for monitor peeking/robustness.
assign d_out = sd_enabled ? sd_data_out : {rom_q, rom_q};

endmodule
