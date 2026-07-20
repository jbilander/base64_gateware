`timescale 1ns/1ps
`default_nettype none
module tb_or3;
  reg clk=0; always #5.87 clk=~clk;
  reg reset=1, req=0, we=0; reg [23:0] addr=0; reg [15:0] wdata=0; reg [1:0] be=2'b11;
  wire ack, ready; wire [15:0] rdata;
  wire [12:0] sa; wire [1:0] sba; wire [15:0] dq; wire [1:0] dqm;
  wire sclk,scke,scs,sras,scas,swe;
  sdram_ctrl #(.T_INIT_US(1)) dut(.clk(clk),.reset(reset),.req(req),.we(we),.addr(addr),
    .wdata(wdata),.byte_en(be),.ack(ack),.rdata(rdata),.ready(ready),
    .sdram_a(sa),.sdram_ba(sba),.sdram_dq(dq),.sdram_dqm(dqm),.sdram_clk(sclk),
    .sdram_cke(scke),.sdram_cs_n(scs),.sdram_ras_n(sras),.sdram_cas_n(scas),.sdram_we_n(swe));
  is42s16160b_model sdram(.clk(clk),.cke(scke),.cs_n(scs),.ras_n(sras),.cas_n(scas),
    .we_n(swe),.a(sa),.ba(sba),.dq(dq),.dqm(dqm));
  integer errors=0, cnt=0, t0, lat;
  reg [15:0] d;
  always @(posedge clk) cnt<=cnt+1;

  task acc(input dwe, input [23:0] a, input [15:0] wd);
    begin
      @(negedge clk); while(ack) @(negedge clk);   // ensure prior ack cleared
      addr<=a; we<=dwe; wdata<=wd; be<=2'b11; req<=1; t0=cnt;
      @(posedge clk); while(!ack) @(posedge clk);
      lat=cnt-t0; d=rdata;
      @(negedge clk); req<=0; @(negedge clk); @(negedge clk);
    end
  endtask

  integer Lmiss, Lhit, Lchg;
  initial begin
    sdram.bank_active=0; sdram.dq_en=0;
    repeat(4)@(negedge clk); reset=0; wait(ready); repeat(4)@(negedge clk);
    // MISS: row5 bank0
    acc(1, {13'd5,2'd0,9'd10}, 16'h1111); Lmiss=lat;
    // HIT: same row, diff col
    acc(1, {13'd5,2'd0,9'd20}, 16'h2222); Lhit=lat;
    // ROW CHANGE: diff row same bank
    acc(1, {13'd6,2'd0,9'd10}, 16'h4444); Lchg=lat;
    $display("miss=%0d hit=%0d change=%0d", Lmiss, Lhit, Lchg);
    if(Lhit<Lmiss) $display("PASS hit faster than miss"); else begin $display("FAIL hit>=miss"); errors=errors+1; end
    if(Lhit<Lchg) $display("PASS hit faster than row-change"); else begin $display("FAIL hit>=change"); errors=errors+1; end
    // data integrity
    acc(0, {13'd5,2'd0,9'd10}, 0);
    if(d!==16'h1111)begin $display("FAIL d1=%h",d);errors=errors+1;end else $display("PASS d1");
    acc(0, {13'd5,2'd0,9'd20}, 0);
    if(d!==16'h2222)begin $display("FAIL d2=%h",d);errors=errors+1;end else $display("PASS d2");
    acc(0, {13'd6,2'd0,9'd10}, 0);
    if(d!==16'h4444)begin $display("FAIL d3=%h",d);errors=errors+1;end else $display("PASS d3");
    // multi-bank independence
    acc(1, {13'd100,2'd1,9'd5}, 16'hAAAA);
    acc(1, {13'd200,2'd2,9'd5}, 16'hBBBB);
    acc(0, {13'd100,2'd1,9'd5}, 0);
    if(d!==16'hAAAA)begin $display("FAIL bank1=%h",d);errors=errors+1;end else $display("PASS bank1 open lat=%0d",lat);
    // refresh survival
    repeat(700)@(negedge clk);
    acc(0, {13'd5,2'd0,9'd10}, 0);
    if(d!==16'h1111)begin $display("FAIL postref=%h",d);errors=errors+1;end else $display("PASS survives refresh");
    if(errors==0)$display("== OPENROW ALL PASS =="); else $display("== %0d ERR ==",errors);
    $finish;
  end
  initial begin #8000000 $display("TIMEOUT"); $finish; end
endmodule
