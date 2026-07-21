`timescale 1ns / 1ps
`default_nettype none
//
// tb_sdram_earlywrite.v — verifies the SDRAM controller's "activate early,
// write on data-valid" path against REALISTIC 68000 write timing.
//
// The hazard this catches (which the forgiving tb_sdram missed): on a real
// 68000 WRITE, the data strobes (and therefore valid write DATA) assert LATE —
// one CPU period after AS. If the controller starts the access early (at req,
// before data is valid) it must NOT capture the write data until the data is
// actually valid. This tb drives req early but presents wdata/byte_en only
// after a delay, and checks the correct value lands.
//
// The controller contract under test:
//   - req may assert before wdata/byte_en are valid (early start).
//   - wr_valid indicates when wdata/byte_en are valid; the controller must not
//     issue the SDRAM WRITE command until wr_valid is high.
//   - For reads, wr_valid is irrelevant.
//
module tb_sdram_earlywrite;
    reg clk = 0; always #5.87 clk = ~clk;

    reg reset = 1;
    reg        req = 0, we = 0, wr_valid = 0;
    reg [23:0] addr = 0;
    reg [15:0] wdata = 0;
    reg [1:0]  byte_en = 2'b11;
    wire        ack, ready;
    wire [15:0] rdata;

    wire [12:0] sa; wire [1:0] sba; wire [15:0] dq; wire [1:0] dqm;
    wire sclk,scke,scs,sras,scas,swe;

    sdram_ctrl #(.T_INIT_US(1)) dut (
        .clk(clk), .reset(reset),
        .req(req), .we(we), .wr_valid(wr_valid),
        .addr(addr), .wdata(wdata), .byte_en(byte_en),
        .ack(ack), .rdata(rdata), .ready(ready),
        .sdram_a(sa), .sdram_ba(sba), .sdram_dq(dq), .sdram_dqm(dqm),
        .sdram_clk(sclk), .sdram_cke(scke), .sdram_cs_n(scs),
        .sdram_ras_n(sras), .sdram_cas_n(scas), .sdram_we_n(swe)
    );
    is42s16160b_model sdram (
        .clk(clk), .cke(scke), .cs_n(scs), .ras_n(sras), .cas_n(scas),
        .we_n(swe), .a(sa), .ba(sba), .dq(dq), .dqm(dqm)
    );

    integer errors = 0;

    // EARLY-START write: assert req with address & we, but present wdata/wr_valid
    // only after `data_delay` clocks (models the 68000 late data strobe).
    task early_write(input [23:0] a, input [15:0] d, input [1:0] be,
                     input integer data_delay);
        integer i;
        begin
            @(negedge clk);
            addr <= a; we <= 1; byte_en <= 2'bxx; wdata <= 16'hxxxx;
            wr_valid <= 1'b0; req <= 1'b1;      // req early, data NOT yet valid
            // hold data invalid for data_delay clocks
            for (i=0;i<data_delay;i=i+1) @(negedge clk);
            wdata <= d; byte_en <= be; wr_valid <= 1'b1;   // data now valid
            @(posedge clk);
            while (!ack) @(posedge clk);
            @(negedge clk); req <= 1'b0; we <= 1'b0; wr_valid <= 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    task rd(input [23:0] a, output [15:0] v);
        begin
            @(negedge clk); addr <= a; we <= 0; wr_valid <= 0; req <= 1;
            @(posedge clk); while (!ack) @(posedge clk);
            v = rdata;
            @(negedge clk); req <= 0; repeat (2) @(negedge clk);
        end
    endtask

    task chk(input [15:0] got, input [15:0] exp, input [255:0] nm);
        begin
            if (got!==exp) begin $display("FAIL %0s got %h exp %h",nm,got,exp); errors=errors+1; end
            else $display("PASS %0s = %h", nm, got);
        end
    endtask

    reg [15:0] d;
    initial begin
        sdram.bank_active = 4'b0000; sdram.dq_en = 0;
        repeat (4) @(negedge clk); reset = 0;
        wait (ready); repeat (4) @(negedge clk); $display("INIT DONE");

        // Write with data valid immediately (delay 0) - baseline
        early_write(24'h000010, 16'hCAFE, 2'b11, 0);
        rd(24'h000010, d); chk(d, 16'hCAFE, "delay0 write"); $display("M1");

        // Write with data valid 3 clocks late (models 68000 late DS)
        early_write(24'h000020, 16'h1234, 2'b11, 3);
        rd(24'h000020, d); chk(d, 16'h1234, "delay3 write");

        // Write with data valid 6 clocks late (worst case)
        early_write(24'h000030, 16'hBEEF, 2'b11, 6);
        rd(24'h000030, d); chk(d, 16'hBEEF, "delay6 write");

        // Same-row (open-row HIT) early write - the riskiest: hit path is
        // fast, so the WRITE command could fire before data valid if ungated
        early_write(24'h000021, 16'hAAAA, 2'b11, 4);   // same row as 0x20
        rd(24'h000021, d); chk(d, 16'hAAAA, "hit early-write");
        rd(24'h000020, d); chk(d, 16'h1234, "hit neighbour intact");

        // Byte-enable with late data
        early_write(24'h000040, 16'hFFFF, 2'b11, 0);
        early_write(24'h000040, 16'h77FF, 2'b10, 3);   // high byte only, late
        rd(24'h000040, d); chk(d, 16'h77FF, "byte_en high late");

        // Interleave a read between early writes (read must not be confused
        // with the write path)
        early_write(24'h000050, 16'hDEAD, 2'b11, 2);
        rd(24'h000050, d); chk(d, 16'hDEAD, "read after early-write");
        early_write(24'h000060, 16'hC0DE, 2'b11, 5);
        rd(24'h000060, d); chk(d, 16'hC0DE, "second early-write");
        rd(24'h000050, d); chk(d, 16'hDEAD, "first still intact");

        if (errors==0) $display("== EARLYWRITE ALL PASS ==");
        else $display("== %0d ERRORS ==", errors);
        $finish;
    end
    initial begin #4000000 $display("TIMEOUT"); $finish; end
endmodule
