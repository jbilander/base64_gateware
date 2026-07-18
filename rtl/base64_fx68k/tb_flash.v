`timescale 1ns/1ps
module USRMCLK(input USRMCLKI, input USRMCLKTS);
  // stub: expose the clock for the flash model
  wire sck = USRMCLKI;
endmodule

module tb_flash;
reg clk=0; always #5.87 clk=~clk;
wire cs_n, mosi, done, we;
wire [14:0] waddr; wire [7:0] wdata;
reg miso;

flash_preload #(.FLASH_ADDR(24'h100000), .LEN_M1(16'd31)) dut(
  .clk(clk), .load_done(done), .rom_we(we), .rom_waddr(waddr),
  .rom_wdata(wdata), .spi_cs_n(cs_n), .spi_mosi(mosi), .spi_miso(miso));

wire sck = dut.sck;

// behavioral flash: capture 32 bits (cmd+addr) on rising sck, then stream
// bytes mem[a] = a[7:0] ^ 8'hA5 on falling edges
reg [31:0] shin; integer bits=0; reg [23:0] fa; reg [7:0] outb; integer obit=7;
reg streaming=0;
always @(posedge sck) if(!cs_n) begin
  if(!streaming) begin
    shin={shin[30:0],mosi}; bits=bits+1;
    if(bits==32) begin
      if(shin[31:24]!==8'h03) $display("FAIL cmd=%h",shin[31:24]);
      fa=shin[23:0];
      if(fa!==24'h100000) $display("FAIL addr=%h",fa);
      streaming=1; outb=fa[7:0]^8'hA5; obit=7;
    end
  end
end
always @(negedge sck) if(!cs_n && streaming) begin
  miso <= outb[obit];
  if(obit==0) begin obit=7; fa=fa+1; outb=(fa[7:0])^8'hA5; end
  else obit=obit-1;
end
// preload first miso bit before first rising edge of data phase
always @(*) if(!streaming) miso = 1'b1;

integer errors=0; integer n=0;
always @(posedge clk) if(we) begin
  if(waddr!==n[14:0] || wdata!==((n[7:0])^8'hA5)) begin
    $display("FAIL byte %0d: waddr=%0d wdata=%h exp=%h",n,waddr,wdata,(n[7:0])^8'hA5);
    errors=errors+1;
  end
  n=n+1;
end
initial begin
  wait(done); repeat(10) @(posedge clk);
  if(n!==32) begin $display("FAIL count=%0d",n); errors=errors+1; end
  if(cs_n!==1'b1) begin $display("FAIL cs not released"); errors=errors+1; end
  if(errors==0) $display("== FLASH PRELOAD ALL PASS (%0d bytes) ==",n);
  $finish;
end
initial begin #2_000_000 $display("TIMEOUT, done=%b n=%0d",done,n); $finish; end
endmodule
