`timescale 1ns / 1ps
// Smoke test for autoconfig_zii_b64 + sd_subsystem with unchanged sdcard.v.
// Emulates 68000-style bus cycles at the fx68k wrapper level (clk = 85 MHz).
module tb;

reg clk = 0;
always #5.87 clk = ~clk;   // ~85.13 MHz

reg reset = 1;
reg [23:1] a = 0;
reg as_n = 1, uds_n = 1, lds_n = 1, rw = 1;
reg [15:0] dout_core = 16'h0000;   // core oEdb
reg cfgin_n = 0;                   // first in chain

wire ac_oe, ac_access, sd_configured, ac_dtack_n, cfgout_n;
wire [15:12] ac_dout;
wire [7:0] base_sd;

autoconfig_zii_b64 ac(
    .clk(clk), .reset(reset), .cfgin_n(cfgin_n),
    .as_n(as_n), .uds_n(uds_n), .lds_n(lds_n), .rw(rw),
    .a_high(a[23:16]), .a_low(a[6:1]), .d_in(dout_core[15:12]),
    .d_out(ac_dout), .data_oe(ac_oe), .ac_access(ac_access),
    .base_sd(base_sd), .sd_configured(sd_configured),
    .cfgout_n(cfgout_n), .dtack_n(ac_dtack_n));

wire sd_space, sd_dtack_n;
wire [15:0] sd_dout;
wire ss_n, sclk_o, mosi_o;

sd_subsystem sdsys(
    .clk(clk), .reset(reset),
    .a(a), .as_n(as_n), .uds_n(uds_n), .lds_n(lds_n), .rw(rw),
    .d_in(dout_core),
    .sd_configured(sd_configured), .base_sd(base_sd),
    .sd_space(sd_space), .d_out(sd_dout), .dtack_n(sd_dtack_n),
    .rom_we(1'b0), .rom_waddr(15'd0), .rom_wdata(8'd0),
    .sd_miso(1'b1), .sd_cd_n(1'b0),
    .sd_ss_n(ss_n), .sd_sclk(sclk_o), .sd_mosi(mosi_o));

// core-side muxes as in the integration sketch
wire dtack_mux_n = ac_access ? ac_dtack_n : sd_space ? sd_dtack_n : 1'b1;
wire [15:0] iedb = ac_oe ? {ac_dout,12'hFFF} : (sd_space && rw) ? sd_dout : 16'hZZZZ;

integer errors = 0;

// Model FPGA GSR power-up zeros for the unchanged sdcard.v regs that have no
// reset (they rely on hardware initialisation; sim would otherwise hold X).
initial begin
    tb.sdsys.sdcontrol.cd_sync = 3'b000;
    tb.sdsys.sdcontrol.cd_debounce_counter = 20'd0;
    tb.sdsys.sdcontrol.cd_stable = 1'b0;
    tb.sdsys.sdcontrol.cd_changed = 1'b0;
    tb.sdsys.sdcontrol.delay_counter = 3'd0;
end

task bus_read(input [23:0] addr, output [15:0] data);
    integer t;
    begin
        @(negedge clk); a <= addr[23:1]; rw <= 1;
        @(negedge clk); as_n <= 0; uds_n <= 0; lds_n <= 0;
        t = 0;
        while (dtack_mux_n && t < 200) begin @(negedge clk); t = t + 1; end
        if (t >= 200) begin $display("FAIL: no DTACK on read @%h", addr); errors = errors + 1; end
        repeat (4) @(negedge clk);   // ~S5/S6
        data = iedb;
        as_n <= 1; uds_n <= 1; lds_n <= 1;
        repeat (3) @(negedge clk);
    end
endtask

task bus_read_b(input [23:0] addr, output [15:0] data);   // odd-address byte read: LDS only
    integer t;
    begin
        @(negedge clk); a <= addr[23:1]; rw <= 1;
        @(negedge clk); as_n <= 0; lds_n <= 0;             // uds_n stays 1
        t = 0;
        while (dtack_mux_n && t < 200) begin @(negedge clk); t = t + 1; end
        if (t >= 200) begin $display("FAIL: no DTACK on byte read @%h", addr); errors = errors + 1; end
        repeat (4) @(negedge clk);
        data = iedb;
        as_n <= 1; lds_n <= 1;
        repeat (3) @(negedge clk);
    end
endtask

task bus_write(input [23:0] addr, input [15:0] data);
    integer t;
    begin
        @(negedge clk); a <= addr[23:1]; rw <= 0; dout_core <= data;
        @(negedge clk); as_n <= 0;
        @(negedge clk); uds_n <= 0; lds_n <= 0;    // DS one tick after AS on writes
        t = 0;
        while (dtack_mux_n && t < 200) begin @(negedge clk); t = t + 1; end
        if (t >= 200) begin $display("FAIL: no DTACK on write @%h", addr); errors = errors + 1; end
        repeat (4) @(negedge clk);
        as_n <= 1; uds_n <= 1; lds_n <= 1; rw <= 1;
        repeat (3) @(negedge clk);
    end
endtask

task check(input [15:0] got, input [15:0] mask, input [15:0] exp, input [127:0] name);
    begin
        if ((got & mask) !== (exp & mask)) begin
            $display("FAIL %0s: got %h expected %h (mask %h)", name, got, exp, mask);
            errors = errors + 1;
        end else
            $display("PASS %0s: %h", name, got);
    end
endtask

reg [15:0] d;
initial begin
    repeat (10) @(negedge clk);
    reset = 0;
    repeat (5) @(negedge clk);

    // --- autoconfig reads ---
    bus_read(24'hE80000, d); check(d, 16'hF000, 16'hD000, "AC reg00 (ZorroII+ROM)");
    bus_read(24'hE80002, d); check(d, 16'hF000, 16'h1000, "AC reg02 (64KB)");
    bus_read(24'hE80004, d); check(d, 16'hF000, {~8'd11,8'h0} & 16'hF000, "AC reg04 (~prod hi)");
    bus_read(24'hE80006, d); check(d, 16'hF000, {~4'd11,12'h0}, "AC reg06 (~prod lo)");
    bus_read(24'hE80010, d); check(d, 16'hF000, {~16'h144A} & 16'hF000, "AC reg10 (~mfg n0)");
    bus_read(24'hE8002E, d); check(d, 16'hF000, 16'hE000, "AC reg2E (~romvec=1)");

    // --- KS assigns base 0xE9: write 4A then 48 ---
    bus_write(24'hE8004A, 16'h9FFF);
    bus_write(24'hE80048, 16'hEFFF);
    if (base_sd !== 8'hE9) begin $display("FAIL base_sd=%h", base_sd); errors = errors + 1; end
    else $display("PASS base_sd=E9, configured=%b, cfgout_n=%b", sd_configured, cfgout_n);
    if (cfgout_n !== 1'b0) begin $display("FAIL cfgout_n still high"); errors = errors + 1; end

    // --- ROM overlay reads, REAL protocol (from DiagArea disassembly):
    //     byte reads at ODD addresses, data on the LOW lane (D7:0).
    //     Nybble DiagArea head: 1F 0F 0F 0F 0F 3F ... ---
    bus_read_b(24'hE90001, d); check(d, 16'h00FF, 16'h001F, "ROM byte0 @odd/LDS");
    bus_read_b(24'hE90003, d); check(d, 16'h00FF, 16'h000F, "ROM byte1 @odd/LDS");
    bus_read_b(24'hE9000B, d); check(d, 16'h00FF, 16'h003F, "ROM byte5 @odd/LDS");
    // mirrored on the upper lane too (monitor peeks / robustness)
    bus_read(24'hE90000, d); check(d, 16'hFFFF, 16'h1F1F, "ROM byte0 mirrored both lanes");
    // NOTE: exact payload offset depends on da_Size (0x330 in the original
    // ROM, 0x354 in LIV2's zero-length-hunk-fix ROM), so we don't pin a
    // hardcoded payload address here - the DiagArea head + mirror above
    // fully exercise the ROM-serving hardware, which is size-independent.

    // --- enable write: CLKDIV = 0x00FA, then read back registers ---
    bus_write(24'hE90000, 16'h00FA);
    bus_read(24'hE90000, d); check(d, 16'hFFFF, 16'h00FA, "CLKDIV readback (sd_enabled)");
    repeat (1_100_000) @(negedge clk);   // let the 10 ms CD debounce settle
    bus_read(24'hE90004, d); check(d, 16'h0001, 16'h0001, "CARD_DET=1");
    bus_read(24'hE90006, d); check(d, 16'h007F, 16'h0025, "STATUS: tx he + tx/rx empty");
    // (bit5 tx_half_empty=1, bit2 tx_cb_empty=1, bit0 rx_cb_empty=1 -> 0x25)

    // --- reset restores overlay ---
    reset = 1; repeat (4) @(negedge clk); reset = 0; repeat (4) @(negedge clk);
    if (sd_configured !== 1'b0 || cfgout_n !== 1'b1) begin
        $display("FAIL: reset didn't clear config"); errors = errors + 1;
    end else $display("PASS reset clears config, overlay restored");

    if (errors == 0) $display("== ALL PASS ==");
    else $display("== %0d ERRORS ==", errors);
    $finish;
end

// card-detect debounce needs ~1e6 clks; give it time before CARD_DET read
initial begin
    #40_000_000 $display("TIMEOUT"); $finish;
end

endmodule
