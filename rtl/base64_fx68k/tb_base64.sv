`timescale 1ns/100ps
//
// tb_base64.sv -- regression bench for the base64 6x accelerator.
//
// WHY THIS EXISTS
//   The earlier bench only checked that data came back correct. Three separate
//   changes passed it and then cost real performance on hardware, because a
//   stall is not a correctness failure. This bench therefore asserts on
//   THROUGHPUT and on FORWARD PROGRESS, not just on values.
//
// RUN
//   $ verilator --binary -j 4 -Wno-fatal --top-module tb -o tb tb_base64.sv \
//       base64_top_6x.sv fastmem_zii.v sdram_ctrl.v sdram_model_checked.v \
//       oddr_stub.v fx68k_pkg.sv fx68kAlu.sv uaddrPla.sv \
//       fx68kRegs_generic.sv fx68kRom_generic.sv fx68k.sv
//   ./obj_dir/tb +workload=0     0 chip RAM  1 CIA/VPA  2 fastmem hit  3 fastmem miss
//
// Exit code is non-zero if any check fails, so it drops straight into CI.
//
module tb;

  // ---------------------------------------------------------------- clocks
  reg clk12 = 0;
  always #5.874 clk12 = ~clk12;              // 85.13 MHz (PAL x12)
  localparam real TCK = 11.7474;             // one master clock, ns
  localparam real T7M = 140.98;              // one 7 MHz period, ns

  reg ph7 = 0; integer c = 0;
  always @(posedge clk12) begin
    c <= (c==11) ? 0 : c + 1;
    if (c==11) ph7 <= 1; else if (c==5) ph7 <= 0;
  end
  wire #6.0 clk_7m = ph7;                    // 74LVC1G17 propagation

  // ---------------------------------------------------------------- config
  integer workload;
  integer dtack_ns, dvalid_ns;
  initial begin
    if (!$value$plusargs("workload=%d", workload)) workload = 0;
    if (!$value$plusargs("dtack=%d",    dtack_ns)) dtack_ns  = 294;  // measured
    if (!$value$plusargs("dvalid=%d",   dvalid_ns)) dvalid_ns = 400;
  end

  // ------------------------------------------------------------------- bus
  wire [23:1] cpu_a;  wire [15:0] cpu_d;  wire [2:0] cpu_fc;
  wire cpu_rw, cpu_as_n, cpu_uds_n, cpu_lds_n, cpu_vma_n, cpu_e, cpu_bg_n;
  wire cpu_reset_n, cpu_halt_n;
  reg  dtack_n = 1, vpa_n = 1, berr_n = 1, br_n = 1, bgack_n = 1;
  reg  [2:0] ipl_n = 3'b111;
  reg  cfgin_n = 0;
  pullup(cpu_reset_n); pullup(cpu_halt_n);

  // ------------------------------------------------------- mock Gary + RAM
  reg [15:0] mem [0:16383];
  integer i;
  wire cia_sp  = (workload == 1) && (cpu_a[14:1] == 14'h0800);
  wire [13:0] wa = cpu_a[14:1];
  reg  [15:0] gary_d;
  always @(*) gary_d = mem[wa];
  always @(*) vpa_n = !(cia_sp && !cpu_as_n);

  reg d_valid = 0;
  always @(negedge cpu_as_n) begin #(dvalid_ns) d_valid = 1; end
  always @(posedge cpu_as_n) begin #2 d_valid = 0; end
  assign cpu_d = (!cpu_as_n && cpu_rw && d_valid && !cia_sp) ? gary_d :
                 (cia_sp && !cpu_vma_n && cpu_e && cpu_rw)   ? 16'h1234 : 16'bz;

  always @(negedge cpu_as_n) begin #(dtack_ns) if (!cia_sp) dtack_n <= 0; end
  always @(posedge cpu_as_n) dtack_n <= 1;
  always @(posedge cpu_as_n) if (!cpu_rw) mem[wa] <= cpu_d;

  // ------------------------------------------------------------------ DUT
  wire [15:0] sdq; wire [12:0] sda; wire [1:0] sdba;
  base64_top #(.CPU_MULT(6), .RETIME(1'b1), .PWRUP_BIT(7),
               .DBG_BUNDLE(1'b0), .LAT_DEBUG(1'b0)) dut (
    .clk_7m(clk_7m), .clk_12x(clk12),
    .cpu_a(cpu_a), .cpu_d(cpu_d), .cpu_fc(cpu_fc),
    .cpu_rw(cpu_rw), .cpu_as_n(cpu_as_n),
    .cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n),
    .cpu_dtack_n(dtack_n), .cpu_vpa_n(vpa_n), .cpu_vma_n(cpu_vma_n),
    .cpu_e(cpu_e), .cpu_berr_n(berr_n),
    .cpu_br_n(br_n), .cpu_bg_n(cpu_bg_n), .cpu_bgack_n(bgack_n),
    .cpu_ipl_n(ipl_n), .cpu_reset_n(cpu_reset_n), .cpu_halt_n(cpu_halt_n),
    .cfgin_n(cfgin_n), .cfgout_n(),
    .cbt_oe_d0_7_n(), .cbt_oe_d8_15_n(), .cbt_oe_ctl_hi_n(),
    .cbt_oe_a8_17_n(), .cbt_oe_a1_7_n(),
    .sdram_dq(sdq), .sdram_a(sda), .sdram_ba(sdba),
    .sdram_clk(), .sdram_cke(), .sdram_cs_n(), .sdram_ras_n(),
    .sdram_cas_n(), .sdram_we_n(), .sdram_dqm(),
    .sd_clk(), .sd_cmd(), .sd_d(),
    .led_r(), .led_g(), .led_b()
  );

  sdram_model_checked #(.CAS_LAT(2)) u_mem (
    .clk(dut.sdram_clk), .a(sda), .ba(sdba), .dq(sdq), .dqm(dut.sdram_dqm),
    .cke(dut.sdram_cke), .cs_n(dut.sdram_cs_n), .ras_n(dut.sdram_ras_n),
    .cas_n(dut.sdram_cas_n), .we_n(dut.sdram_we_n));

  // ------------------------------------------------------------- workloads
  // 0/1 run from chip RAM.  2/3 run from fastmem, which is force-configured
  // at $200000 once the controller reports ready (skips Kickstart's
  // autoconfig negotiation, which this bench has no Kickstart to perform).
  //
  //   SDRAM word address maps as {row[12:0], bank[1:0], col[8:0]}, so
  //     word 0x000 -> bank 0 row 0    word 0x200 -> bank 1 row 0
  //     word 0x800 -> bank 0 row 1    <- thrashes bank 0 against word 0
  //   Workload 4 thrashes BANK 1 rather than bank 0. This matters: a bug that
  //   stops the per-bank tRAS counters advancing may still leave bank 0
  //   working, so a bank-0-only workload passes while real code stalls. The
  //   missing begin/end regression did exactly that (ras_timer 14 0 0 0
  //   instead of 14 15 0 0) and workloads 2/3 could not see it.
  localparam [15:0] FM_RD_HIT  = 16'h0000;   // $200000, bank 0 row 0
  localparam [15:0] FM_RD_MISS = 16'h1000;   // $201000, bank 0 row 1

  initial begin
    for (i=0;i<16384;i=i+1) mem[i] = 16'h4E71;              // NOP fill
    mem[0] = 16'h0000; mem[1] = 16'h8000;                   // SSP
    if (workload < 2) begin
      mem[2] = 16'h0000; mem[3] = 16'h0400;                 // PC = $000400
      mem[16'h0400>>1] = 16'h3038; mem[16'h0402>>1] = 16'h1000;
      mem[16'h0404>>1] = 16'h31C0; mem[16'h0406>>1] = 16'h1002;
      mem[16'h0408>>1] = 16'h60F6;
      mem[16'h1000>>1] = 16'h4321;
    end else begin
      mem[2] = 16'h0020;
      mem[3] = (workload == 4) ? 16'h0000 : 16'h0400;      // PC in fastmem
    end
  end

  reg fm_ready = 0;
  // NOTE: do NOT hold the CPU in reset to wait for the SDRAM. In the DUT
  // slave_reset = ext_reset, so asserting reset also holds the SDRAM
  // controller in reset and it never finishes its init -- a deadlock. The
  // core simply stalls on its first fastmem fetch until sdram_ready comes
  // up, which is the correct behaviour anyway. (Worth noting for hardware:
  // every warm reset re-runs the ~100 us SDRAM init, so fast RAM is
  // unavailable for that long after Ctrl-A-A.)

  initial if (workload == 4) begin
    // code in bank 0 row 0; data thrashes BANK 1 between row 1 and row 0
    force dut.u_fastmem.configured = 1'b1;
    force dut.u_fastmem.addr_match = 8'h01;
    u_mem.mem[16'h000] = 16'h3039; u_mem.mem[16'h001] = 16'h0020;
    u_mem.mem[16'h002] = 16'h1400;                 // read  $201400 -> bank1 row1
    u_mem.mem[16'h003] = 16'h33C0; u_mem.mem[16'h004] = 16'h0020;
    u_mem.mem[16'h005] = 16'h0400;                 // write $200400 -> bank1 row0
    u_mem.mem[16'h006] = 16'h60F2;
    u_mem.mem[16'hA00] = 16'h4321;
    wait (dut.u_fastmem.sdram_ready === 1'b1);
    repeat (8) @(posedge clk12);
    fm_ready = 1;
  end

  initial if (workload >= 2 && workload != 4) begin
    // force, not assign: `configured` is cleared every clock while the DUT is
    // in reset, so a one-shot poke gets wiped before it ever takes effect.
    force dut.u_fastmem.configured = 1'b1;
    force dut.u_fastmem.addr_match = 8'h01;      // slot 0 -> $200000..$2FFFFF
    u_mem.mem[(workload==2 ? FM_RD_HIT : FM_RD_MISS) >> 1] = 16'h4321;
    u_mem.mem[16'h200] = 16'h3039;               // MOVE.W (xxx).L,D0
    u_mem.mem[16'h201] = 16'h0020;
    u_mem.mem[16'h202] = (workload==2) ? FM_RD_HIT : FM_RD_MISS;
    u_mem.mem[16'h203] = 16'h33C0;               // MOVE.W D0,(xxx).L
    u_mem.mem[16'h204] = 16'h0020;
    u_mem.mem[16'h205] = 16'h0002;
    u_mem.mem[16'h206] = 16'h60F2;               // BRA loop
    wait (dut.u_fastmem.sdram_ready === 1'b1);
    repeat (8) @(posedge clk12);
    fm_ready = 1;   // gates the stall watchdog only
  end

  // ------------------------------------------------------------- iteration
  // The loop writes to +2, so one write there is one completed iteration.
  integer n_iter = 0, n_core_as = 0, n_ack = 0, n_fmspace = 0;
  always @(negedge dut.core_as_n) n_core_as = n_core_as + 1;
  always @(posedge clk12) if (dut.u_sdram.ack) n_ack = n_ack + 1;
  always @(posedge clk12) if (dut.fm_space)    n_fmspace = n_fmspace + 1;
  always @(posedge cpu_as_n)
    if (!cpu_rw && cpu_a[14:1] == 14'h0801 && workload < 2) n_iter = n_iter + 1;
  always @(posedge clk12)
    if (workload >= 2 && dut.u_sdram.ack && dut.u_sdram.cur_we) n_iter = n_iter + 1;

  // ------------------------------------------------- STALL WATCHDOG (key!)
  // This is the check the old bench lacked. A stall is not a data error, so
  // nothing caught it; the machine simply got slower. Any gap in forward
  // progress longer than WD_LIMIT master clocks fails the run outright.
  localparam integer WD_LIMIT = 400;          // ~4.7 us, >> any legal cycle
  integer wd = 0, n_fail = 0, stalled = 0, n_stall = 0;
  reg as_d = 1;
  always @(posedge clk12) begin
    as_d <= cpu_as_n;
    if ((cpu_as_n != as_d) || (workload >= 2 && dut.u_sdram.ack)) wd <= 0;
    else if (dut.ext_reset || (workload >= 2 && !fm_ready))       wd <= 0;
    else begin
      wd <= wd + 1;
      if (wd == WD_LIMIT) begin
        n_stall = n_stall + 1;
        if (!stalled) begin
          $display("  *** STALL at %0.1f us: no forward progress for %0d master clocks",
                   $realtime/1000.0, WD_LIMIT);
          stalled = 1; n_fail = n_fail + 1;
        end
        wd <= 0;
      end
    end
  end

  // ---- fastmem latency vs the 68000's 3-master-clock DTACK budget -------
  real fl_t=0, fl_sum=0, fl_min=1e9; integer fl_n=0;
  always @(negedge dut.core_as_n) if (dut.core_a[23:20]==4'h2) fl_t = $realtime;
  always @(negedge dut.u_fastmem.fm_dtack_n) if (fl_t>0) begin
     fl_sum = fl_sum + ($realtime-fl_t); fl_n = fl_n+1;
     if (($realtime-fl_t) < fl_min) fl_min = $realtime-fl_t;
     fl_t = 0;
  end
  // ------------------------------------------------------- bus protocol
  real e_hi=0, e_lo=0, e_last=0; integer n_e=0, vma_bad=0;
  always @(posedge cpu_e) begin if (e_last>0) e_lo = $realtime-e_last; e_last=$realtime; end
  always @(negedge cpu_e) begin if (e_last>0) begin e_hi = $realtime-e_last; n_e=n_e+1; end e_last=$realtime; end
  // 6800 rule: VMA is asserted BEFORE E rises and held through E high. The
  // violation is asserting VMA while E is ALREADY high, so check the edge.
  reg vma_d = 1;
  always @(posedge clk12) begin
    vma_d <= cpu_vma_n;
    if (vma_d && !cpu_vma_n && cpu_e) vma_bad = vma_bad + 1;
  end

  real as_t=0, as_min=1e9; integer n_as=0;
  always @(negedge cpu_as_n) as_t = $realtime;
  always @(posedge cpu_as_n) if (as_t>0) begin
    if (($realtime-as_t) < as_min) as_min = $realtime-as_t;
    n_as = n_as + 1;
  end

  // ------------------------------------------------------------- thresholds
  // Set from the measured known-good design with ~10% headroom. Any change
  // that drops below these FAILS, which is the whole point.
  function integer min_iter(input integer w);
    case (w)
      0: min_iter = 78;      // chip RAM,         measured 87
      1: min_iter = 63;      // CIA/VPA,          measured 70
      2: min_iter = 500;     // fastmem row hit,  measured 556
      3: min_iter = 447;     // fastmem row miss, measured 497
      4: min_iter = 447;     // BANK 1 row thrash, measured 497
      default: min_iter = 1;
    endcase
  endfunction

  task chk(input cond, input [639:0] what);
    begin
      if (!cond) begin n_fail = n_fail + 1; $display("  FAIL: %0s", what); end
      else                                  $display("  ok  : %0s", what);
    end
  endtask

  initial begin
    if (workload >= 2) #800000; else #400000;
    $display("");
    $display("================ base64 6x regression ================");
    $display(" workload %0d   DTACK AS+%0d ns   data AS+%0d ns", workload, dtack_ns, dvalid_ns);
    $display(" loop iterations : %0d   (threshold %0d)", n_iter, min_iter(workload));
    $display(" bus cycles      : %0d", n_as);
    if (workload >= 2)
      $display(" DIAG: fm_ready=%b configured=%b ready=%b coreAS_cycles=%0d sdram_acks=%0d fm_space_seen=%0d",
               fm_ready, dut.u_fastmem.configured, dut.u_fastmem.sdram_ready,
               n_core_as, n_ack, n_fmspace);
    if (n_e>0) $display(" E clock         : high %0.1f ns  low %0.1f ns -> %0.1f kHz",
                        e_hi, e_lo, 1e6/(e_hi+e_lo));
    if (fl_n>0) $display(" AS->fm_dtack    : min %0.2f  mean %0.2f master clocks   (budget 3.00 = zero wait)",
                         fl_min/TCK, (fl_sum/fl_n)/TCK);
    u_mem.report();
    $display(" ---- checks ----");
    if (n_stall > 0) $display(" stall events    : %0d", n_stall);
    chk(!stalled,                      "no stall (forward progress watchdog)");
    chk(n_iter >= min_iter(workload),  "throughput above threshold");
    chk(u_mem.n_err == 0,              "no SDRAM timing violations");
    chk(vma_bad == 0,                  "VMA never newly asserted while E already high");
    chk(n_as == 0 || as_min > 300.0,   "AS low width >= 300 ns");
    if (workload >= 2)
      chk(u_mem.mem[(workload==4) ? 16'h200 : 16'h1] == 16'h4321, "fastmem read/write data correct");
    else
      chk(mem[16'h1002>>1] == 16'h4321 || workload==1, "chip RAM data correct");
    $display("");
    if (n_fail == 0) $display(" RESULT: PASS");
    else             $display(" RESULT: *** %0d FAILURE(S) ***", n_fail);
    $display("=====================================================");
    if (n_fail != 0) $fatal(1);
    $finish;
  end
endmodule
