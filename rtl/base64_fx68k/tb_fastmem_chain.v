`timescale 1ns/1ps
`default_nettype none
// Chain test v2: now REQUIRES fastmem to return a valid autoconfig ID nibble
// before configuring (the check that was missing and hid the no-read-data bug).
module tb_chain2;
  reg clk=0; always #5.87 clk=~clk;
  reg reset=1, cfgin_n=0, as_n=1, uds_n=1, lds_n=1, rw=1;
  reg [23:1] a=0; reg [15:0] d_in=0;
  wire [15:12] ac_dout; wire ac_oe, ac_access, sd_configured, ac_dtack_n, sd_cfgout_n;
  wire [7:0] base_sd;
  autoconfig_zii_b64 sdac(.clk(clk),.reset(reset),.cfgin_n(cfgin_n),
    .as_n(as_n),.uds_n(uds_n),.lds_n(lds_n),.rw(rw),
    .a_high(a[23:16]),.a_low(a[6:1]),.d_in(d_in[15:12]),
    .d_out(ac_dout),.data_oe(ac_oe),.ac_access(ac_access),
    .base_sd(base_sd),.sd_configured(sd_configured),.cfgout_n(sd_cfgout_n),.dtack_n(ac_dtack_n));
  wire fm_cfgin_n = sd_cfgout_n;
  wire fm_space,fm_active,fm_dtack_n,fm_cfgout_n; wire [15:0] fm_dout;
  wire fm_ac_access, fm_ac_oe, fm_ac_dtack_n; wire [3:0] fm_ac_dout;
  wire req,we; wire [23:0] saddr; wire [15:0] wdata; wire [1:0] be;
  fastmem_zii fm(.clk(clk),.reset(reset),.cfgin_n(fm_cfgin_n),
    .as_n(as_n),.uds_n(uds_n),.lds_n(lds_n),.rw(rw),.a(a),.d_in(d_in),
    .fm_space(fm_space),.fm_dout(fm_dout),.fm_dtack_n(fm_dtack_n),.fm_active(fm_active),
    .cfgout_n(fm_cfgout_n),.fm_ac_access(fm_ac_access),.fm_ac_dout(fm_ac_dout),
    .fm_ac_oe(fm_ac_oe),.fm_ac_dtack_n(fm_ac_dtack_n),
    .req(req),.we(we),.saddr(saddr),.wdata(wdata),.byte_en(be),
    .ack(1'b0),.rdata(16'd0),.sdram_ready(1'b1));
  integer errors=0;
  task ac_write(input [7:0] regw, input [3:0] nib); begin
    @(negedge clk); a[8:1]<=regw; a[23:16]<=8'hE8; rw<=0; d_in<={nib,12'h000};
    @(negedge clk); as_n<=0; @(negedge clk); uds_n<=0; lds_n<=0;
    repeat(3)@(negedge clk); as_n<=1; uds_n<=1; lds_n<=1; rw<=1; repeat(2)@(negedge clk); end endtask
  task ac_read(input [7:0] regw, output [3:0] nib); begin
    @(negedge clk); a[8:1]<=regw; a[23:16]<=8'hE8; rw<=1;
    @(negedge clk); as_n<=0; uds_n<=0; lds_n<=0;
    repeat(2)@(negedge clk); nib = fm_ac_oe ? fm_ac_dout : 4'hz;
    as_n<=1; uds_n<=1; lds_n<=1; repeat(2)@(negedge clk); end endtask
  reg [3:0] n;
  initial begin
    repeat(6)@(negedge clk); reset=0; repeat(6)@(negedge clk);
    // configure SD first so its cfgout passes to fm
    ac_write(8'h25, 4'hE); ac_write(8'h24, 4'h9);
    if(!sd_configured)begin $display("FAIL SD didn't configure");errors=errors+1;end
    else $display("PASS SD configured, cfgout asserted -> fm CFGIN=%b",fm_cfgin_n);
    repeat(2)@(negedge clk);
    // NOW: read fastmem autoconfig ID nibbles (what KS actually does first)
    ac_read(8'h00, n); $display("fm reg00 nib=%h (expect E: Zorro II)", n);
    if(n!==4'hE)begin $display("FAIL fm reg00 read");errors=errors+1;end else $display("PASS fm reg00 ID read");
    ac_read(8'h01, n); $display("fm reg01 nib=%h (expect 0: 8MB size)", n);
    if(n!==4'h0)begin $display("FAIL fm reg01 size");errors=errors+1;end else $display("PASS fm reg01 size read");
    // product id reg 0x02 = ~PROD_ID[7:4]; PROD_ID=12=0x0C -> ~0=F
    ac_read(8'h02, n); $display("fm reg02 nib=%h", n);
    // now configure fm
    ac_write(8'h24, 4'h2);
    if(fm.configured && fm.addr_match==8'hFF) $display("PASS fm configured 8MB addr_match=FF");
    else begin $display("FAIL fm config: cfg=%b am=%b",fm.configured,fm.addr_match);errors=errors+1;end
    if(errors==0)$display("== CHAIN v2 ALL PASS =="); else $display("== %0d ERRORS ==",errors);
    $finish;
  end
  initial begin #3000000 $display("TIMEOUT"); $finish; end
endmodule
