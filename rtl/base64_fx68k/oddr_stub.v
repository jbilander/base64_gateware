`timescale 1ns/100ps
// Simulation-only stand-in for the Lattice ODDRX1F primitive.
module ODDRX1F(input D0, input D1, input SCLK, input RST, output reg Q);
  initial Q = 1'b0;
  always @(posedge SCLK) Q <= RST ? 1'b0 : D0;
  always @(negedge SCLK) Q <= RST ? 1'b0 : D1;
endmodule
