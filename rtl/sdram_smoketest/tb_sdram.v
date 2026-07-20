`timescale 1ns / 1ps
`default_nettype none
//
// tb_sdram.v — verify sdram_ctrl.v against the behavioural IS42S16160B model.
// Uses a SHORT init wait so the sim finishes fast (real T_INIT_US=100 would be
// ~8500 clks before anything happens).
//
module tb_sdram;
    reg clk = 0;
    always #5.87 clk = ~clk;     // ~85.13 MHz

    reg reset = 1;
    reg        req = 0, we = 0;
    reg [23:0] addr = 0;
    reg [15:0] wdata = 0;
    reg [1:0]  byte_en = 2'b11;
    wire        ack, ready;
    wire [15:0] rdata;

    wire [12:0] sa;  wire [1:0] sba; wire [15:0] dq; wire [1:0] dqm;
    wire sclk, scke, scs, sras, scas, swe;

    sdram_ctrl #(
        .T_INIT_US(1)            // 1 us init for fast sim (~85 clks)
    ) dut (
        .clk(clk), .reset(reset),
        .req(req), .we(we), .addr(addr), .wdata(wdata), .byte_en(byte_en),
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

    task do_write(input [23:0] a, input [15:0] d, input [1:0] be);
        begin
            @(negedge clk);
            addr <= a; wdata <= d; byte_en <= be; we <= 1; req <= 1;
            @(posedge clk);
            while (!ack) @(posedge clk);
            @(negedge clk); req <= 0; we <= 0;
            repeat (2) @(negedge clk);
        end
    endtask

    task do_read(input [23:0] a, output [15:0] d);
        begin
            @(negedge clk);
            addr <= a; we <= 0; req <= 1;
            @(posedge clk);
            while (!ack) @(posedge clk);
            d = rdata;
            @(negedge clk); req <= 0;
            repeat (2) @(negedge clk);
        end
    endtask

    task check(input [15:0] got, input [15:0] exp, input [255:0] name);
        begin
            if (got !== exp) begin
                $display("FAIL %0s: got %h exp %h", name, got, exp);
                errors = errors + 1;
            end else
                $display("PASS %0s: %h", name, got);
        end
    endtask

    reg [15:0] d;
    initial begin
        repeat (4) @(negedge clk);
        reset = 0;

        // wait for init done
        wait (ready);
        $display("init complete at t=%0t", $time);
        repeat (4) @(negedge clk);

        // basic write/read back
        do_write(24'h000010, 16'hCAFE, 2'b11);
        do_read (24'h000010, d); check(d, 16'hCAFE, "wr/rd 0x10");

        do_write(24'h000011, 16'h1234, 2'b11);
        do_read (24'h000011, d); check(d, 16'h1234, "wr/rd 0x11 (adjacent col)");
        do_read (24'h000010, d); check(d, 16'hCAFE, "reread 0x10 unchanged");

        // different bank & row
        do_write(24'h123456, 16'hBEEF, 2'b11);
        do_read (24'h123456, d); check(d, 16'hBEEF, "wr/rd 0x123456 (bank/row)");

        // byte-enable: write only low byte over CAFE -> should become CA(new)
        do_write(24'h000010, 16'hFF99, 2'b01);   // be=01 -> low byte only
        do_read (24'h000010, d); check(d, 16'hCA99, "byte_en low only");
        do_write(24'h000010, 16'h77FF, 2'b10);   // be=10 -> high byte only
        do_read (24'h000010, d); check(d, 16'h7799, "byte_en high only");

        // top of range word address
        do_write(24'hFFFFFF, 16'hABCD, 2'b11);
        do_read (24'hFFFFFF, d); check(d, 16'hABCD, "top-of-range 0xFFFFFF");

        // back-to-back different rows (force activate each time)
        do_write(24'h000800, 16'h0001, 2'b11);   // row change
        do_write(24'h001000, 16'h0002, 2'b11);
        do_read (24'h000800, d); check(d, 16'h0001, "row A after row B");
        do_read (24'h001000, d); check(d, 16'h0002, "row B");

        if (errors == 0) $display("== SDRAM CTRL ALL PASS ==");
        else $display("== %0d ERRORS ==", errors);
        $finish;
    end

    initial begin #500000 $display("TIMEOUT"); $finish; end
endmodule
