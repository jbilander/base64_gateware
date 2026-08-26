`timescale 1ns / 1ps
`default_nettype none
//
// tb_turbomem_zii.v — self-checking bench for the Zorro II diag ROM board.
//
// Walks the sequence expansion.library actually performs: read the $40 ID
// nybble pairs out of $E8xxxx, reassemble them into an ExpansionRom struct,
// check every field, write the base address to $4A then $48, then read the
// DiagArea back out of the assigned window and compare it word for word
// against turbomem.mem.
//
// Also checks the two things that turn into a dead machine rather than a
// wrong answer: that the window does NOT claim $000000 before configuration,
// and that a write into the window is acked instead of hanging the bus.
//
//   iverilog -g2005 -o tb tb_turbomem_zii.v turbomem_zii.v && ./tb
//
module tb_turbomem_zii;

localparam CLK_NS = 11.746;     // 85.13 MHz

reg         clk = 1'b0;
reg         reset = 1'b1;
reg         cfgin_n = 1'b1;
reg         as_n = 1'b1, uds_n = 1'b1, lds_n = 1'b1, rw = 1'b1;
reg  [31:1] a = 31'd0;
reg  [15:0] d_in = 16'd0;

wire        tm_space, tm_dtack_n, tm_active;
wire [15:0] tm_dout;
wire        tm_ac_access, tm_ac_oe, tm_ac_dtack_n;
wire [3:0]  tm_ac_dout;
wire        cfgout_n, tm_configured;
wire [7:0]  tm_base;

localparam [63:0] STAT_TEST = 64'h1234_0003_0006_544D;
wire mr_load, mr_active;
integer errors = 0;
integer i;

always #(CLK_NS/2.0) clk = ~clk;

turbomem_zii #(
    .MFG_ID   (16'h144A),
    .PROD_ID  (8'd14),
    .SERIAL   (32'd0),
    .DIAG_VEC (16'h2000),
    .ROM_AWID (12),
    .ROM_FILE ("turbomem.mem")
) dut (
    .clk (clk), .reset (reset), .cfgin_n (cfgin_n),
    .as_n (as_n), .uds_n (uds_n), .lds_n (lds_n), .rw (rw),
    .a (a), .d_in (d_in), .status_i (STAT_TEST),
    .tm_space (tm_space), .tm_dout (tm_dout),
    .tm_dtack_n (tm_dtack_n), .tm_active (tm_active),
    .tm_ac_access (tm_ac_access), .tm_ac_dout (tm_ac_dout),
    .tm_ac_oe (tm_ac_oe), .tm_ac_dtack_n (tm_ac_dtack_n),
    .cfgout_n (cfgout_n), .tm_base (tm_base),
    .tm_configured (tm_configured),
    .maprom_load (mr_load), .maprom_active (mr_active)
);

// A SECOND board downstream of the first, so the bench exercises the actual
// CFGIN/CFGOUT chain rather than one board in isolation. This stands in for
// whatever comes next -- the SD card ROM -- and proves the first board hands
// the $E8 space on cleanly once it is configured.
wire        tm2_space, tm2_dtack_n, tm2_active;
wire [15:0] tm2_dout;
wire        tm2_ac_access, tm2_ac_oe, tm2_ac_dtack_n;
wire [3:0]  tm2_ac_dout;
wire        cfgout2_n, tm2_configured;
wire [7:0]  tm2_base;

turbomem_zii #(
    .MFG_ID   (16'h144A),
    .PROD_ID  (8'd15),   // bench-only stand-in, NOT an allocation --
                         // must differ from dut1 so test [12] proves the
                         // chain handed over instead of board 1 replying
    .DIAG_VEC (16'h2000),
    .ROM_AWID (12),
    .ROM_FILE ("turbomem.mem")
) dut2 (
    .clk (clk), .reset (reset), .cfgin_n (cfgout_n),
    .as_n (as_n), .uds_n (uds_n), .lds_n (lds_n), .rw (rw),
    .a (a), .d_in (d_in), .status_i (64'd0),
    .tm_space (tm2_space), .tm_dout (tm2_dout),
    .tm_dtack_n (tm2_dtack_n), .tm_active (tm2_active),
    .tm_ac_access (tm2_ac_access), .tm_ac_dout (tm2_ac_dout),
    .tm_ac_oe (tm2_ac_oe), .tm_ac_dtack_n (tm2_ac_dtack_n),
    .cfgout_n (cfgout2_n), .tm_base (tm2_base),
    .tm_configured (tm2_configured),
    .maprom_load (), .maprom_active ()
);

// What base64_top's core_iedb mux, int_dtack_lo and int_space do, in
// miniature -- including the priority order.
wire [15:0] iedb       = tm_ac_oe  ? {tm_ac_dout,  12'hFFF}
                       : tm2_ac_oe ? {tm2_ac_dout, 12'hFFF}
                       : tm_space  ? tm_dout
                       : tm2_space ? tm2_dout : 16'hFFFF;
wire        int_dtack  = ~tm_dtack_n  | ~tm_ac_dtack_n
                       | ~tm2_dtack_n | ~tm2_ac_dtack_n;
wire        int_space  = tm_space  | tm_ac_access
                       | tm2_space | tm2_ac_access;

// Golden copy of the image.
reg [15:0] gold [0:4095];
initial $readmemh("turbomem.mem", gold);

task check;
    input [255:0] name;
    input [31:0]  got;
    input [31:0]  exp;
    begin
        if (got !== exp) begin
            $display("  FAIL  %0s: got %h expected %h", name, got, exp);
            errors = errors + 1;
        end else begin
            $display("  ok    %0s = %h", name, got);
        end
    end
endtask

// A 68000 read: address at S1, AS and DS together at S2, wait for DTACK.
task bus_read;
    input  [31:1] addr;
    output [15:0] data;
    integer to;
    begin
        @(negedge clk);
        a = addr; rw = 1'b1;
        @(negedge clk);
        as_n = 1'b0; uds_n = 1'b0; lds_n = 1'b0;
        to = 0;
        while (!int_dtack && to < 200) begin @(posedge clk); to = to + 1; end
        if (to >= 200) begin
            $display("  FAIL  read %h: no DTACK", {addr, 1'b0});
            errors = errors + 1;
            data = 16'hDEAD;
        end else begin
            data = iedb;
        end
        @(negedge clk);
        as_n = 1'b1; uds_n = 1'b1; lds_n = 1'b1;
        @(negedge clk);
    end
endtask

// A 68000 write: R/W low with AS at S2, data and DS two clocks later at S4.
task bus_write;
    input [31:1] addr;
    input [15:0] data;
    integer to;
    begin
        @(negedge clk);
        a = addr; rw = 1'b0;
        @(negedge clk);
        as_n = 1'b0;
        @(negedge clk); @(negedge clk);
        d_in = data; uds_n = 1'b0; lds_n = 1'b0;
        to = 0;
        while (!int_dtack && to < 200) begin @(posedge clk); to = to + 1; end
        if (to >= 200) begin
            $display("  FAIL  write %h: no DTACK", {addr, 1'b0});
            errors = errors + 1;
        end
        @(negedge clk);
        as_n = 1'b1; uds_n = 1'b1; lds_n = 1'b1; rw = 1'b1;
        @(negedge clk);
    end
endtask

// Read one autoconfig nybble pair and return the assembled byte.
task ac_byte;
    input  [7:0] ofs;          // register offset, e.g. $04
    input        invert;
    output [7:0] val;
    reg [15:0] hi, lo;
    begin
        bus_read({8'h00, 8'hE8, 8'd0, ofs[7:1]},         hi);
        bus_read({8'h00, 8'hE8, 8'd0, ofs[7:1] + 7'd1},  lo);
        val = {hi[15:12], lo[15:12]};
        if (invert) val = ~val;
    end
endtask

reg [15:0] w, w2;
reg [7:0]  b0, b1, b2, b3;
reg [15:0] mfg, dvec;
reg [31:0] ser;
reg        claimed_low;
integer    img_err;
integer    img_words;

initial begin
    $display("\n=== turbomem_zii ===\n");

    repeat (8) @(posedge clk);
    reset = 1'b0;
    repeat (4) @(posedge clk);

    // ---- 1. Nothing may answer while CFGIN is high -------------------------
    $display("[1] CFGIN high: board is silent");
    @(negedge clk);
    a = {8'h00, 8'hE8, 15'd0}; as_n = 1'b0; uds_n = 1'b0; lds_n = 1'b0;
    repeat (20) @(posedge clk);
    check("ac_access with cfgin high", {31'd0, tm_ac_access}, 32'd0);
    check("dtack with cfgin high",     {31'd0, int_dtack},     32'd0);
    @(negedge clk);
    as_n = 1'b1; uds_n = 1'b1; lds_n = 1'b1;

    cfgin_n = 1'b0;
    repeat (4) @(posedge clk);

    // ---- 2. The window must NOT claim $000000 before configuration ---------
    // An ungated compare against base=$00 would swallow the exception vector
    // table on the first fetch after reset.
    $display("\n[2] Unconfigured: window does not claim low memory");
    claimed_low = 1'b0;
    @(negedge clk);
    a = 31'd4; as_n = 1'b0; uds_n = 1'b0; lds_n = 1'b0;
    repeat (20) begin @(posedge clk); if (tm_space) claimed_low = 1'b1; end
    check("tm_space at $000008", {31'd0, claimed_low}, 32'd0);
    @(negedge clk);
    as_n = 1'b1; uds_n = 1'b1; lds_n = 1'b1;

    // ---- 3. Read the ExpansionRom -----------------------------------------
    $display("\n[3] ExpansionRom as expansion.library assembles it");
    ac_byte(8'h00, 1'b0, b0);                    // er_Type: NOT inverted
    check("er_Type", {24'd0, b0}, 32'h000000D1); // 1101 0001
    if (b0[7:6] !== 2'b11) begin
        $display("  FAIL  er_Type: not Zorro II"); errors = errors + 1;
    end
    if (b0[4] !== 1'b1) begin
        $display("  FAIL  er_Type: ERTF_DIAGVALID clear - no DiagArea will be read");
        errors = errors + 1;
    end
    if (b0[5] !== 1'b0) begin
        $display("  FAIL  er_Type: ERTF_MEMLIST set - KS would add ROM to the free pool");
        errors = errors + 1;
    end
    check("er_Type size field (001 = 64K)", {29'd0, b0[2:0]}, 32'd1);

    ac_byte(8'h04, 1'b1, b1);
    check("er_Product", {24'd0, b1}, 32'd14);

    ac_byte(8'h08, 1'b1, b2);
    check("er_Flags", {24'd0, b2}, 32'h000000C0);

    ac_byte(8'h10, 1'b1, b0);
    ac_byte(8'h14, 1'b1, b1);
    mfg = {b0, b1};
    check("er_Manufacturer", {16'd0, mfg}, 32'h0000144A);

    ac_byte(8'h18, 1'b1, b0); ac_byte(8'h1C, 1'b1, b1);
    ac_byte(8'h20, 1'b1, b2); ac_byte(8'h24, 1'b1, b3);
    ser = {b0, b1, b2, b3};
    check("er_SerialNumber", ser, 32'd0);

    ac_byte(8'h28, 1'b1, b0);
    ac_byte(8'h2C, 1'b1, b1);
    dvec = {b0, b1};
    check("er_InitDiagVec", {16'd0, dvec}, 32'h00002000);

    // ---- 4. Assign the base, $4A first then $48 ---------------------------
    $display("\n[4] Base assignment to $E90000");
    bus_write({8'h00, 8'hE8, 8'd0, 7'h25}, 16'h9000);
    check("configured after $4A", {31'd0, tm_configured}, 32'd0);
    bus_write({8'h00, 8'hE8, 8'd0, 7'h24}, 16'hE000);
    check("configured after $48", {31'd0, tm_configured}, 32'd1);
    check("base", {24'd0, tm_base}, 32'h000000E9);
    check("cfgout_n dropped",  {31'd0, cfgout_n}, 32'd0);

    // ---- 5. The board must vanish from $E8xxxx -----------------------------
    $display("\n[5] Configured: no longer answers $E8xxxx");
    @(negedge clk);
    a = {8'h00, 8'hE8, 15'd0}; as_n = 1'b0; uds_n = 1'b0; lds_n = 1'b0;
    repeat (20) @(posedge clk);
    check("ac_access after config", {31'd0, tm_ac_access}, 32'd0);
    @(negedge clk);
    as_n = 1'b1; uds_n = 1'b1; lds_n = 1'b1;

    // ---- 6. The DiagArea, where expansion.library will look for it ---------
    // Read at the advertised vector, and again at twice it. Both must land
    // on the DiagArea: byte-offset readers use the first, and a word-offset
    // reader would use the second. The 8 KB mirroring makes both true, which
    // is the whole reason $2000 was picked.
    $display("\n[6] DiagArea at board+$2000 (er_InitDiagVec) and board+$4000");
    bus_read({8'h00, 8'hE9, 3'b001, 12'd0}, w);
    check("da_Config/da_Flags at +$2000", {16'd0, w}, {16'd0, gold[0]});
    bus_read({8'h00, 8'hE9, 3'b001, 11'd0, 1'b1}, w);
    check("da_Size at +$2002",            {16'd0, w}, {16'd0, gold[1]});
    bus_read({8'h00, 8'hE9, 3'b010, 12'd0}, w);
    check("da_Config/da_Flags at +$4000", {16'd0, w}, {16'd0, gold[0]});

    // ---- 7. Whole image, word for word ------------------------------------
    // Self-sizing: entries past the end of the file stay X, so walk until
    // the first one. The image grows every time the payload changes and a
    // hard-coded count would quietly stop covering the tail.
    img_words = 0;
    while (img_words < 4096 && gold[img_words] !== 16'hxxxx)
        img_words = img_words + 1;
    $display("\n[7] Full image compare, %0d words", img_words);
    img_err = errors;
    for (i = 0; i < img_words; i = i + 1) begin
        bus_read({8'h00, 8'hE9, i[14:0]}, w);
        if (w !== gold[i]) begin
            $display("  FAIL  word %0d: got %h expected %h", i, w, gold[i]);
            errors = errors + 1;
        end
    end
    if (errors == img_err)
        $display("  ok    all %0d words match turbomem.mem", img_words);

    // ---- 8. int_space must be asserted so the top suppresses AS -----------
    $display("\n[8] int_space on a ROM cycle");
    @(negedge clk);
    a = {8'h00, 8'hE9, 15'd0}; rw = 1'b1;
    @(negedge clk);
    as_n = 1'b0; uds_n = 1'b0; lds_n = 1'b0;
    @(posedge clk);
    check("int_space", {31'd0, int_space}, 32'd1);
    check("tm_active", {31'd0, tm_active}, 32'd1);
    while (!int_dtack) @(posedge clk);
    @(negedge clk);
    as_n = 1'b1; uds_n = 1'b1; lds_n = 1'b1;

    // ---- 9. A write into the window is acked, not hung --------------------
    $display("\n[9] Stray write into the ROM window");
    bus_write({8'h00, 8'hE9, 15'd0}, 16'hBEEF);
    bus_read ({8'h00, 8'hE9, 15'd0}, w);
    check("image unchanged by write", {16'd0, w}, {16'd0, gold[0]});

    // ---- 10. Mirroring ----------------------------------------------------
    $display("\n[10] Image mirrors every 8 KB inside the 64 KB window");
    bus_read({8'h00, 8'hE9, 3'b011, 12'd0}, w);   // board + $6000
    check("board+$6000 mirrors board+0", {16'd0, w}, {16'd0, gold[0]});

    // ---- 11. The window answers at its base and nowhere else --------------
    $display("\n[11] No response at an address we were not assigned");
    claimed_low = 1'b0;
    @(negedge clk);
    a = {8'h00, 8'hEA, 15'd0}; rw = 1'b1;
    @(negedge clk);
    as_n = 1'b0; uds_n = 1'b0; lds_n = 1'b0;
    repeat (24) begin @(posedge clk); if (tm_space) claimed_low = 1'b1; end
    check("tm_space at $EA0000", {31'd0, claimed_low}, 32'd0);
    @(negedge clk);
    as_n = 1'b1; uds_n = 1'b1; lds_n = 1'b1;

    // ---- 12. The chain handed $E8 to the next board -----------------------
    $display("\n[12] Daisy chain: second board now owns $E8xxxx");
    check("board 1 CFGOUT low", {31'd0, cfgout_n},  32'd0);
    check("board 2 CFGOUT high", {31'd0, cfgout2_n}, 32'd1);
    ac_byte(8'h04, 1'b1, b1);
    check("er_Product now board 2's", {24'd0, b1}, 32'd15);

    // ---- 13. Shut-up path -------------------------------------------------
    // A board told to shut up must go silent and pass the chain on. If it
    // does not, autoconfig stalls and the machine dies with no diagnostics.
    $display("\n[13] Shut up board 2 at $4C");
    bus_write({8'h00, 8'hE8, 8'd0, 7'h26}, 16'h0000);
    check("board 2 configured", {31'd0, tm2_configured}, 32'd0);
    check("board 2 CFGOUT dropped", {31'd0, cfgout2_n}, 32'd0);
    claimed_low = 1'b0;
    @(negedge clk);
    a = {8'h00, 8'hE8, 15'd0}; rw = 1'b1;
    @(negedge clk);
    as_n = 1'b0; uds_n = 1'b0; lds_n = 1'b0;
    repeat (24) begin
        @(posedge clk);
        if (tm2_ac_access || tm2_space || int_dtack) claimed_low = 1'b1;
    end
    check("board 2 fully silent", {31'd0, claimed_low}, 32'd0);
    @(negedge clk);
    as_n = 1'b1; uds_n = 1'b1; lds_n = 1'b1;

    // ---- 14. Status window at $F000 --------------------------------------
    $display("\n[14] Status window at +$F000 does not disturb the ROM");
    bus_read({8'h00, 8'hE9, 4'hF, 11'd0}, w);
    check("magic at +$F000",  {16'd0, w}, 32'h0000544D);
    bus_read({8'h00, 8'hE9, 4'hF, 10'd0, 1'b1}, w);
    check("flags at +$F002",  {16'd0, w}, 32'h00000006);
    bus_read({8'h00, 8'hE9, 4'hF, 9'd0, 2'b10}, w);
    check("retries at +$F004",{16'd0, w}, 32'h00000003);
    bus_read({8'h00, 8'hE9, 4'hF, 9'd0, 2'b11}, w);
    check("boot_ms at +$F006",{16'd0, w}, 32'h00001234);
    bus_read({8'h00, 8'hE9, 3'b001, 12'd0}, w);
    check("ROM at +$2000 still intact", {16'd0, w}, {16'd0, gold[0]});

    // ---- 15. mapROM control register at +$F008 ---------------------------
    // A stray write must not be able to switch Kickstart fetches to an
    // unfilled shadow: that is an instant, undiagnosable death.
    $display("\n[15] mapROM control register");
    check("both bits clear at reset", {30'd0, mr_active, mr_load}, 32'd0);

    bus_write({8'h00, 8'hE9, 4'hF, 8'd0, 3'b100}, 16'h0003);   // no key
    check("unkeyed write ignored", {30'd0, mr_active, mr_load}, 32'd0);
    bus_write({8'h00, 8'hE9, 4'hF, 8'd0, 3'b100}, 16'hFFFF);   // stray -1
    check("stray \$FFFF ignored",  {30'd0, mr_active, mr_load}, 32'd0);

    bus_write({8'h00, 8'hE9, 4'hF, 8'd0, 3'b100}, 16'h5A01);   // load
    check("keyed write sets load", {30'd0, mr_active, mr_load}, 32'd1);
    bus_read ({8'h00, 8'hE9, 4'hF, 8'd0, 3'b100}, w);
    check("reads back",           {16'd0, w}, 32'h00000001);

    bus_write({8'h00, 8'hE9, 4'hF, 8'd0, 3'b100}, 16'h5A02);   // active
    check("active only",          {30'd0, mr_active, mr_load}, 32'd2);
    bus_write({8'h00, 8'hE9, 4'hF, 8'd0, 3'b100}, 16'h5A00);   // off
    check("cleared",              {30'd0, mr_active, mr_load}, 32'd0);

    bus_read({8'h00, 8'hE9, 3'b001, 12'd0}, w);
    check("ROM at +\$2000 intact", {16'd0, w}, {16'd0, gold[0]});

    $display("\n=== %0d error(s) ===\n", errors);
    if (errors == 0) $display("PASS\n"); else $display("FAIL\n");
    $finish;
end

endmodule
