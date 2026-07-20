`timescale 1ns/1ps
module tb_refresh;
  reg clk=0; always #5.87 clk=~clk;
  reg reset=1, req=0, we=0; reg [23:0] addr=0; reg [15:0] wdata=0; reg [1:0] be=2'b11;
  wire ack, ready; wire [15:0] rdata;
  wire [12:0] sa; wire [1:0] sba; wire [15:0] dq; wire [1:0] dqm;
  wire sclk,scke,scs,sras,scas,swe;
  // tiny refresh interval to force lots of refreshes fast
  sdram_ctrl #(.T_INIT_US(1), .T_REFI(20)) dut(.clk(clk),.reset(reset),.req(req),.we(we),
    .addr(addr),.wdata(wdata),.byte_en(be),.ack(ack),.rdata(rdata),.ready(ready),
    .sdram_a(sa),.sdram_ba(sba),.sdram_dq(dq),.sdram_dqm(dqm),.sdram_clk(sclk),
    .sdram_cke(scke),.sdram_cs_n(scs),.sdram_ras_n(sras),.sdram_cas_n(scas),.sdram_we_n(swe));
  is42s16160b_model sdram(.clk(clk),.cke(scke),.cs_n(scs),.ras_n(sras),.cas_n(scas),
    .we_n(swe),.a(sa),.ba(sba),.dq(dq),.dqm(dqm));
  integer errors=0, i;
  reg [15:0] d;
  task wr(input [23:0] a, input [15:0] v); begin
    @(negedge clk); addr<=a; wdata<=v; be<=2'b11; we<=1; req<=1;
    @(posedge clk); while(!ack)@(posedge clk); @(negedge clk); req<=0; we<=0; repeat(2)@(negedge clk); end endtask
  task rd(input [23:0] a, output [15:0] v); begin
    @(negedge clk); addr<=a; we<=0; req<=1;
    @(posedge clk); while(!ack)@(posedge clk); v=rdata; @(negedge clk); req<=0; repeat(2)@(negedge clk); end endtask
  initial begin
    repeat(4)@(negedge clk); reset=0; wait(ready); repeat(4)@(negedge clk);
    // write 16 distinct locations
    for(i=0;i<16;i=i+1) wr(i*7+24'h100, 16'hA000+i);
    // hammer with delays so refreshes fire between, then verify retention
    for(i=0;i<16;i=i+1) begin
      repeat(30) @(negedge clk);   // let refresh fire
      rd(i*7+24'h100, d);
      if (d !== 16'hA000+i) begin $display("FAIL loc %0d: %h",i,d); errors=errors+1; end
    end
    if(errors==0) $display("== REFRESH RETENTION ALL PASS (16 locs) ==");
    else $display("== %0d ERRORS ==",errors);
    $finish;
  end
  initial begin #2000000 $display("TIMEOUT"); $finish; end
endmodule
