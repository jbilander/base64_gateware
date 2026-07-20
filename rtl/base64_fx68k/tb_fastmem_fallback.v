`timescale 1ns/1ps
`default_nettype none
module tb_fallback;
  reg clk=0; always #5.87 clk=~clk;
  reg reset=1, cfgin_n=0, as_n=1, uds_n=1, lds_n=1, rw=1;
  reg [23:1] a=0; reg [15:0] d_in=0;
  wire fm_space,fm_active,cfgout_n; wire [15:0] fm_dout; wire fm_dtack_n;
  wire req,we; wire [23:0] saddr; wire [15:0] wdata; wire [1:0] byte_en;
  wire ack; wire [15:0] rdata; wire ready;
  fastmem_zii #(.OFFER_SPLIT(1'b0)) fm(.clk(clk),.reset(reset),.cfgin_n(cfgin_n),
    .as_n(as_n),.uds_n(uds_n),.lds_n(lds_n),.rw(rw),.a(a),.d_in(d_in),
    .fm_space(fm_space),.fm_dout(fm_dout),.fm_dtack_n(fm_dtack_n),.fm_active(fm_active),
    .cfgout_n(cfgout_n),.req(req),.we(we),.saddr(saddr),.wdata(wdata),.byte_en(byte_en),
    .ack(ack),.rdata(rdata),.sdram_ready(ready));
  wire [12:0] sa; wire [1:0] sba; wire [15:0] dq; wire [1:0] dqm;
  wire sclk,scke,scs,sras,scas,swe;
  sdram_ctrl #(.T_INIT_US(1)) ctrl(.clk(clk),.reset(reset),.req(req),.we(we),.addr(saddr),
    .wdata(wdata),.byte_en(byte_en),.ack(ack),.rdata(rdata),.ready(ready),
    .sdram_a(sa),.sdram_ba(sba),.sdram_dq(dq),.sdram_dqm(dqm),.sdram_clk(sclk),
    .sdram_cke(scke),.sdram_cs_n(scs),.sdram_ras_n(sras),.sdram_cas_n(scas),.sdram_we_n(swe));
  is42s16160b_model sdram(.clk(clk),.cke(scke),.cs_n(scs),.ras_n(sras),.cas_n(scas),
    .we_n(swe),.a(sa),.ba(sba),.dq(dq),.dqm(dqm));
  integer errors=0;
  task ac_write(input [7:0] regw, input [3:0] nib); begin
    @(negedge clk); a[8:1]<=regw; a[23:16]<=8'hE8; rw<=0; d_in<={nib,12'h000};
    @(negedge clk); as_n<=0; @(negedge clk); uds_n<=0; lds_n<=0;
    repeat(3)@(negedge clk); as_n<=1; uds_n<=1; lds_n<=1; rw<=1; repeat(2)@(negedge clk); end endtask
  initial begin
    sdram.bank_active=0; sdram.dq_en=0;
    repeat(6)@(negedge clk); reset=0; wait(ready); repeat(4)@(negedge clk);
    // Tell it to shut up on 8M (write reg 0x26)
    ac_write(8'h26, 4'h0);
    if (fm.ac_state !== 3'd1) begin $display("FAIL: after 8M shutup, state=%0d (want OFFER_4M=1)",fm.ac_state); errors=errors+1; end
    else $display("PASS: 8M refused -> now offering 4M");
    // Now KS places 4M at region $4 (nibble 4 -> slots 2..5)
    ac_write(8'h24, 4'h4);
    if (fm.addr_match !== 8'b00111100) begin $display("FAIL: 4M@4 addr_match=%b (want 00111100)",fm.addr_match); errors=errors+1; end
    else $display("PASS: 4M placed at region 4 -> addr_match=00111100, configured=%b",fm.configured);
    // verify a read/write lands in that block
    @(negedge clk); a<=(24'h400000>>1)|4; rw<=0; d_in<=16'hDA7A;
    @(negedge clk); as_n<=0; @(negedge clk); uds_n<=0; lds_n<=0;
    begin:w integer t; t=0; while(fm_dtack_n&&t<100)begin @(negedge clk);t=t+1;end
      if(t>=100)begin $display("FAIL no dtack write");errors=errors+1;end end
    as_n<=1;uds_n<=1;lds_n<=1;rw<=1; repeat(3)@(negedge clk);
    @(negedge clk); a<=(24'h400000>>1)|4; rw<=1;
    @(negedge clk); as_n<=0; uds_n<=0; lds_n<=0;
    begin:r integer t; t=0; while(fm_dtack_n&&t<100)begin @(negedge clk);t=t+1;end end
    if (fm_dout!==16'hDA7A) begin $display("FAIL 4M readback=%h",fm_dout); errors=errors+1; end
    else $display("PASS: 4M block read/write = %h", fm_dout);
    as_n<=1;uds_n<=1;lds_n<=1;
    if(errors==0)$display("== FALLBACK ALL PASS =="); else $display("== %0d ERRORS ==",errors);
    $finish;
  end
  initial begin #6000000 $display("TIMEOUT"); $finish; end
endmodule
