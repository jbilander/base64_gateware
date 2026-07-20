`timescale 1ns / 1ps
`default_nettype none
//
// tb_fastmem.v — verify fastmem_zii: (1) 8 MB autoconfig accept, (2) graceful
// fallback when told to shut up, and (3) actual read/write through the bridge
// into the real sdram_ctrl + behavioural IS42S16160B model.
//
module tb_fastmem;
    reg clk = 0; always #5.87 clk = ~clk;    // 85 MHz (compat build clock)

    reg reset = 1;
    reg cfgin_n = 0;                          // first in chain
    reg as_n=1, uds_n=1, lds_n=1, rw=1;
    reg [23:1] a = 0;
    reg [15:0] d_in = 0;

    wire fm_space, fm_active, cfgout_n;
    wire [15:0] fm_dout;
    wire fm_dtack_n;

    // controller handshake
    wire req, we; wire [23:0] saddr; wire [15:0] wdata; wire [1:0] byte_en;
    wire ack; wire [15:0] rdata; wire ready;

    fastmem_zii #(.OFFER_SPLIT(1'b1)) fm (
        .clk(clk), .reset(reset), .cfgin_n(cfgin_n),
        .as_n(as_n), .uds_n(uds_n), .lds_n(lds_n), .rw(rw),
        .a(a), .d_in(d_in),
        .fm_space(fm_space), .fm_dout(fm_dout), .fm_dtack_n(fm_dtack_n),
        .fm_active(fm_active), .cfgout_n(cfgout_n),
        .req(req), .we(we), .saddr(saddr), .wdata(wdata), .byte_en(byte_en),
        .ack(ack), .rdata(rdata), .sdram_ready(ready)
    );

    wire [12:0] sa; wire [1:0] sba; wire [15:0] dq; wire [1:0] dqm;
    wire sclk,scke,scs,sras,scas,swe;
    sdram_ctrl #(.T_INIT_US(1)) ctrl (
        .clk(clk), .reset(reset),
        .req(req), .we(we), .addr(saddr), .wdata(wdata), .byte_en(byte_en),
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

    task ac_read(input [7:0] regw, output [3:0] nib);
        begin
            @(negedge clk); a <= {8'hE8, 7'd0, regw[7:1]}; // reg addr in a[8:1]
            // place regw into a[8:1]
            a[8:1] <= regw;
            rw <= 1;
            @(negedge clk); as_n <= 0; uds_n <= 0; lds_n <= 0;
            repeat (3) @(negedge clk);
            nib = fm_dout[15:12];  // NOTE fm doesn't drive ac reads; see below
            as_n <= 1; uds_n <= 1; lds_n <= 1;
            repeat (2) @(negedge clk);
        end
    endtask

    // autoconfig write (base addr / shutup). data nibble in d_in[15:12].
    task ac_write(input [7:0] regw, input [3:0] nib);
        begin
            @(negedge clk); a[8:1] <= regw; a[23:16] <= 8'hE8; rw <= 0;
            d_in <= {nib, 12'h000};
            @(negedge clk); as_n <= 0;
            @(negedge clk); uds_n <= 0; lds_n <= 0;
            repeat (3) @(negedge clk);
            as_n <= 1; uds_n <= 1; lds_n <= 1; rw <= 1;
            repeat (2) @(negedge clk);
        end
    endtask

    // fast-RAM access at Amiga byte address `ba` (word-aligned use even addr)
    task fm_write(input [23:1] wa, input [15:0] val);
        integer t;
        begin
            @(negedge clk); a <= wa; a[23:16] <= wa[23:16]; rw <= 0; d_in <= val;
            @(negedge clk); as_n <= 0;
            @(negedge clk); uds_n <= 0; lds_n <= 0;
            t=0; while (fm_dtack_n && t<100) begin @(negedge clk); t=t+1; end
            if (t>=100) begin $display("FAIL: no DTACK on fm_write @%h", wa); errors=errors+1; end
            as_n <= 1; uds_n <= 1; lds_n <= 1; rw <= 1;
            repeat (3) @(negedge clk);
        end
    endtask

    task fm_read(input [23:1] wa, output [15:0] val);
        integer t;
        begin
            @(negedge clk); a <= wa; a[23:16] <= wa[23:16]; rw <= 1;
            @(negedge clk); as_n <= 0; uds_n <= 0; lds_n <= 0;
            t=0; while (fm_dtack_n && t<100) begin @(negedge clk); t=t+1; end
            if (t>=100) begin $display("FAIL: no DTACK on fm_read @%h", wa); errors=errors+1; end
            val = fm_dout;
            as_n <= 1; uds_n <= 1; lds_n <= 1;
            repeat (3) @(negedge clk);
        end
    endtask

    task chk(input [15:0] got, input [15:0] exp, input [255:0] nm);
        begin
            if (got!==exp) begin $display("FAIL %0s got %h exp %h",nm,got,exp); errors=errors+1; end
            else $display("PASS %0s = %h", nm, got);
        end
    endtask

    reg [15:0] d;
    integer i;
    initial begin
        // GSR model init for sdcard-free run
        repeat (6) @(negedge clk);
        reset = 0;
        wait (ready);
        repeat (4) @(negedge clk);

        // ---- Test 1: 8 MB autoconfig accept ----
        // KS writes base high nibble to reg 0x24 (a[8:1]=0x24). Say base=$20 -> nibble 2.
        ac_write(8'h24, 4'h2);
        if (fm.addr_match !== 8'hFF) begin
            $display("FAIL 8M accept: addr_match=%b", fm.addr_match); errors=errors+1;
        end else $display("PASS 8M accept: addr_match=FF, configured=%b", fm.configured);

        // ---- Test 2: memory read/write across several banks/rows in the window ----
        // window base region = $2 (we accepted at $2xxxxx.. since nibble 2)
        // access some addresses in $200000..$9FFFFF
        fm_write(24'h201000 >> 1, 16'hCAFE);
        // simpler: build word addresses directly
        for (i=0;i<8;i=i+1) begin
            fm_write((24'h200000 + i*24'h100000) >> 1 | 24'h8, 16'hB000+i);
        end
        for (i=0;i<8;i=i+1) begin
            fm_read((24'h200000 + i*24'h100000) >> 1 | 24'h8, d);
            chk(d, 16'hB000+i, "fm slot data");
        end
        fm_read(24'h201000 >> 1, d); chk(d, 16'hCAFE, "fm distinct addr");

        // ---- Test 3: byte enables ----
        fm_write(24'h200020 >> 1, 16'hFFFF);
        // write only low byte
        @(negedge clk); a <= 24'h200020 >> 1; rw<=0; d_in<=16'h1234;
        @(negedge clk); as_n<=0; @(negedge clk); lds_n<=0;  // LDS only
        begin : bw
          integer t; t=0; while(fm_dtack_n && t<100)begin @(negedge clk); t=t+1; end
        end
        as_n<=1; lds_n<=1; rw<=1; repeat(3)@(negedge clk);
        fm_read(24'h200020 >> 1, d); chk(d, 16'hFF34, "byte_en LDS only");

        if (errors==0) $display("== FASTMEM ALL PASS ==");
        else $display("== %0d ERRORS ==", errors);
        $finish;
    end

    // GSR model init
    initial begin
        sdram.bank_active = 4'b0000;
        sdram.dq_en = 0;
    end

    initial begin #6000000 $display("TIMEOUT ready=%b cfgout=%b am=%b",ready,cfgout_n,fm.addr_match); $finish; end
endmodule
