`timescale 1ns / 1ps
`default_nettype none
//
// tb_sd_zii.v -- bench for autoconfig_zii + sd_subsystem as integrated into
// Base64.
//
// The two changes made to Niklas Ekstrom's SF2000 sources for this board are
// both decode changes, which is the category that elaborates cleanly and then
// misbehaves on hardware. This bench exists to check them:
//
//   * the a[31:24] == $00 guard. fx68k drives A31-A24 and fastmem_zii claims
//     a[31:24] == $08 for the 16 MB CPU window, so an unguarded compare would
//     let $08<base>xxxx be claimed by both the SD device and fastmem at once.
//     Two slaves driving iEdb and DTACK together, and 64 KB of corruption
//     inside the 16 MB window.
//   * the registered sd_space compare, which must NOT delay sd_space relative
//     to AS or sdcard.v's ACCESS contract changes.
//
// It also checks the ROM overlay actually serves sfsd.mem at the odd-byte
// addresses the DiagArea expects, since a silently empty ROM looks exactly
// like a decode fault -- as it did for turbomem.
//
//   iverilog -g2005 -o tb tb_sd_zii.v autoconfig_zii.v sd_subsystem.v \
//       sdcard.v fifo.v shifter.v rx_cpu_buf.v tx_cpu_buf.v && ./tb
//
module tb_sd_zii;

localparam CLK_NS = 11.746;     // 85.13 MHz

reg         clk = 1'b0;
reg         reset = 1'b1;
reg         cfgin_n = 1'b1;
reg         as_n = 1'b1, uds_n = 1'b1, lds_n = 1'b1, rw = 1'b1;
reg  [31:1] a = 31'd0;
reg  [15:0] d_in = 16'd0;

wire [3:0]  sd_ac_dout;
wire        sd_ac_oe, sd_ac_access, sd_ac_dtack_n, cfgout_n, sd_configured;
wire [7:0]  base_sd;
wire        sd_space, sd_dtack_n;
wire [15:0] sd_dout;
wire        sd_ss_n, sd_sclk, sd_mosi;

integer errors = 0;
integer i;

always #(CLK_NS/2.0) clk = ~clk;

autoconfig_zii #(
    .MFG_ID(16'h144A), .SD_PROD_ID(8'd11), .SERIAL(16'd0)
) u_ac (
    .clk(clk), .reset(reset), .cfgin_n(cfgin_n),
    .as_n(as_n), .uds_n(uds_n), .lds_n(lds_n), .rw(rw),
    .a_high(a[31:16]), .a_low(a[6:1]), .d_in(d_in[15:12]),
    .d_out(sd_ac_dout), .data_oe(sd_ac_oe), .ac_access(sd_ac_access),
    .base_sd(base_sd), .sd_configured(sd_configured),
    .cfgout_n(cfgout_n), .dtack_n(sd_ac_dtack_n)
);

sd_subsystem #(.ROM_INIT_FILE("sfsd.mem")) u_sd (
    .clk(clk), .reset(reset),
    .a(a), .as_n(as_n), .uds_n(uds_n), .lds_n(lds_n), .rw(rw), .d_in(d_in),
    .sd_configured(sd_configured), .base_sd(base_sd),
    .sd_space(sd_space), .d_out(sd_dout), .dtack_n(sd_dtack_n),
    .rom_we(1'b0), .rom_waddr(15'd0), .rom_wdata(8'd0),
    .sd_miso(1'b1), .sd_cd_n(1'b0),
    .sd_ss_n(sd_ss_n), .sd_sclk(sd_sclk), .sd_mosi(sd_mosi)
);

// base64_top's muxes, in miniature.
wire [15:0] iedb      = sd_ac_oe ? {sd_ac_dout, 12'hFFF}
                      : sd_space ? sd_dout : 16'hFFFF;
wire        int_dtack = ~sd_dtack_n | ~sd_ac_dtack_n;
wire        int_space = sd_space | sd_ac_access;

// Golden copy of the ROM image.
reg [7:0] gold [0:32767];
initial $readmemh("sfsd.mem", gold);

task check;
    input [255:0] name; input [31:0] got; input [31:0] exp;
    begin
        if (got !== exp) begin
            $display("  FAIL  %0s: got %h expected %h", name, got, exp);
            errors = errors + 1;
        end else $display("  ok    %0s = %h", name, got);
    end
endtask

task bus_read;
    input  [31:1] addr; input lds_only; output [15:0] data;
    integer to;
    begin
        @(negedge clk); a = addr; rw = 1'b1;
        @(negedge clk); as_n = 1'b0; uds_n = lds_only; lds_n = 1'b0;
        to = 0;
        while (!int_dtack && to < 300) begin @(posedge clk); to = to + 1; end
        if (to >= 300) begin
            $display("  FAIL  read %h: no DTACK", {addr, 1'b0});
            errors = errors + 1; data = 16'hDEAD;
        end else data = iedb;
        @(negedge clk); as_n = 1'b1; uds_n = 1'b1; lds_n = 1'b1;
        @(negedge clk);
    end
endtask

task bus_write;
    input [31:1] addr; input [15:0] data;
    integer to;
    begin
        @(negedge clk); a = addr; rw = 1'b0;
        @(negedge clk); as_n = 1'b0;
        @(negedge clk); @(negedge clk);
        d_in = data; uds_n = 1'b0; lds_n = 1'b0;
        to = 0;
        while (!int_dtack && to < 300) begin @(posedge clk); to = to + 1; end
        if (to >= 300) begin
            $display("  FAIL  write %h: no DTACK", {addr, 1'b0});
            errors = errors + 1;
        end
        @(negedge clk); as_n = 1'b1; uds_n = 1'b1; lds_n = 1'b1; rw = 1'b1;
        @(negedge clk);
    end
endtask

task ac_byte;
    input [7:0] ofs; input invert; output [7:0] val;
    reg [15:0] hi, lo;
    begin
        bus_read({8'h00, 8'hE8, 8'd0, ofs[7:1]},        1'b0, hi);
        bus_read({8'h00, 8'hE8, 8'd0, ofs[7:1] + 7'd1}, 1'b0, lo);
        val = {hi[15:12], lo[15:12]};
        if (invert) val = ~val;
    end
endtask

reg [15:0] w;
reg [7:0]  b0, b1;
reg [15:0] mfg, dvec;
reg        claimed;

initial begin
    $display("\n=== sd_subsystem + autoconfig_zii ===\n");
    repeat (8) @(posedge clk); reset = 1'b0; repeat (4) @(posedge clk);

    // ---- 1. silent until CFGIN ------------------------------------------
    $display("[1] CFGIN high: silent");
    @(negedge clk); a = {8'h00, 8'hE8, 15'd0}; as_n = 1'b0; lds_n = 1'b0; uds_n = 1'b0;
    repeat (24) @(posedge clk);
    check("ac_access", {31'd0, sd_ac_access}, 32'd0);
    check("int_dtack", {31'd0, int_dtack},    32'd0);
    @(negedge clk); as_n = 1'b1; uds_n = 1'b1; lds_n = 1'b1;
    cfgin_n = 1'b0; repeat (4) @(posedge clk);

    // ---- 2. the upper-byte guard, during autoconfig ----------------------
    // Without it, $01E8xxxx is an alias of the autoconfig space.
    $display("\n[2] a[31:24] guard: $01E80000 must not be claimed");
    claimed = 1'b0;
    @(negedge clk); a = {8'h01, 8'hE8, 15'd0}; rw = 1'b1;
    @(negedge clk); as_n = 1'b0; uds_n = 1'b0; lds_n = 1'b0;
    repeat (24) begin @(posedge clk); if (sd_ac_access || int_dtack) claimed = 1'b1; end
    check("claimed $01E80000", {31'd0, claimed}, 32'd0);
    @(negedge clk); as_n = 1'b1; uds_n = 1'b1; lds_n = 1'b1;

    // ---- 3. the ExpansionRom --------------------------------------------
    $display("\n[3] ExpansionRom");
    ac_byte(8'h00, 1'b0, b0);
    check("er_Type", {24'd0, b0}, 32'h000000D1);
    if (b0[4] !== 1'b1) begin
        $display("  FAIL  ERTF_DIAGVALID clear - no boot ROM will be read");
        errors = errors + 1;
    end
    ac_byte(8'h04, 1'b1, b1);
    check("er_Product (must stay 11)", {24'd0, b1}, 32'd11);
    ac_byte(8'h10, 1'b1, b0); ac_byte(8'h14, 1'b1, b1);
    mfg = {b0, b1};
    check("er_Manufacturer", {16'd0, mfg}, 32'h0000144A);
    ac_byte(8'h28, 1'b1, b0); ac_byte(8'h2C, 1'b1, b1);
    dvec = {b0, b1};
    check("er_InitDiagVec (odd byte, low lane)", {16'd0, dvec}, 32'h00000001);

    // ---- 4. assign the base ---------------------------------------------
    $display("\n[4] Base assignment to $EA0000");
    bus_write({8'h00, 8'hE8, 8'd0, 7'h25}, 16'hA000);
    bus_write({8'h00, 8'hE8, 8'd0, 7'h24}, 16'hE000);
    check("sd_configured", {31'd0, sd_configured}, 32'd1);
    check("base_sd",       {24'd0, base_sd},       32'h000000EA);
    check("cfgout_n low",  {31'd0, cfgout_n},      32'd0);

    // ---- 5. the window guard --------------------------------------------
    // $08EA0000 is inside fastmem's 16 MB CPU window. If the SD device
    // claims it too, both drive iEdb and DTACK and 64 KB of that window is
    // corrupted. This is the check that matters most.
    $display("\n[5] a[31:24] guard: $08EA0000 must not be claimed");
    claimed = 1'b0;
    @(negedge clk); a = {8'h08, 8'hEA, 15'd0}; rw = 1'b1;
    @(negedge clk); as_n = 1'b0; uds_n = 1'b0; lds_n = 1'b0;
    repeat (24) begin @(posedge clk); if (sd_space || int_dtack) claimed = 1'b1; end
    check("claimed $08EA0000", {31'd0, claimed}, 32'd0);
    @(negedge clk); as_n = 1'b1; uds_n = 1'b1; lds_n = 1'b1;

    // ---- 6. sd_space is not delayed by the registered compare -----------
    // It must assert in the SAME clock as AS falls, or sdcard.v's ACCESS
    // contract changes.
    $display("\n[6] sd_space asserts with AS, not a clock later");
    @(negedge clk); a = {8'h00, 8'hEA, 15'd0}; rw = 1'b1;
    @(negedge clk); as_n = 1'b0; uds_n = 1'b1; lds_n = 1'b0;
    @(posedge clk);
    check("sd_space at first edge after AS", {31'd0, sd_space}, 32'd1);
    check("int_space",                       {31'd0, int_space}, 32'd1);
    while (!int_dtack) @(posedge clk);
    @(negedge clk); as_n = 1'b1; uds_n = 1'b1; lds_n = 1'b1;

    // ---- 7. ROM overlay at the odd byte addresses -----------------------
    // ROM byte n lives at byte offset 2n+1: LDS reads on the low lane.
    $display("\n[7] ROM overlay: byte n at offset 2n+1");
    for (i = 0; i < 16; i = i + 1) begin
        bus_read({8'h00, 8'hEA, i[14:0]}, 1'b1, w);
        if (w[7:0] !== gold[i]) begin
            $display("  FAIL  rom byte %0d: got %02h expected %02h",
                     i, w[7:0], gold[i]);
            errors = errors + 1;
        end
    end
    $display("  ok    first 16 ROM bytes match sfsd.mem (%02h %02h %02h ...)",
             gold[0], gold[1], gold[2]);
    bus_read({8'h00, 8'hEA, 15'h0660}, 1'b1, w);   // deep into the image
    check("rom byte $660", {24'd0, w[7:0]}, {24'd0, gold[16'h0660]});
    check("mirrored on both lanes", {16'd0, w}, {16'd0, gold[16'h0660], gold[16'h0660]});

    // ---- 8. first write lifts the overlay -------------------------------
    $display("\n[8] First write switches reads to the sdcard registers");
    bus_write({8'h00, 8'hEA, 15'd1}, 16'h0000);
    bus_read ({8'h00, 8'hEA, 15'd0}, 1'b1, w);
    if (w[7:0] === gold[0]) begin
        $display("  FAIL  still reading ROM after a write - overlay stuck");
        errors = errors + 1;
    end else
        $display("  ok    overlay lifted, reads now from sdcard.v");

    $display("\n=== %0d error(s) ===\n", errors);
    if (errors == 0) $display("PASS\n"); else $display("FAIL\n");
    $finish;
end

endmodule
