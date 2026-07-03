# fx68k branch — build milestones

Prereqs: Diamond (Linux) with Synplify Pro, ecpprog + FT4232H on module JTAG.
All milestones run on the bare iCESugar-Pro over USB power; no carrier needed
until milestone 3 goes into a machine.

## Repo setup
    git clone -b fx68k --recurse-submodules git@github.com:jbilander/base64_gateware.git
    (if cloned without submodules: git submodule update --init)

## Milestone 1 — blink (verifies the whole flow)

Diamond: File > New > Project
  - Device family ECP5, LFE5U-25F, package CABGA256, grade 6, part LFE5U-25F-6BG256C
  - Synthesis tool: **Synplify Pro** (not LSE)
  - Add source: rtl/blink/blink_top.v
  - Add/import LPF: constraints/blink.lpf (replace the default blank one)
  - Set top module: blink_top (Project > Active Implementation > Set Top-Level Unit)
Run: double-click "Bitstream File" in the Process pane.
Program:  ecpprog -d i:0x0403:0x6011 -I A -S <impl dir>/<project>_impl1.bit
Expected: green LED blinking ~1.5 Hz. If yes: toolchain, LPF, JTAG all good.

## Milestone 2 — fx68k fmax trial (answers the 42.5 MHz question)

New implementation (or project) with:
  - rtl/fx68k/fx68k_pkg.sv, fx68k.sv, fx68kAlu.sv, uaddrPla.sv,
    rtl/fx68k/bram/fx68kRegs_generic.sv, bram/fx68kRom_generic.sv
  - rtl/common/pll_25_85.v
  - rtl/fx68k_trial/fx68k_fmax_top.sv          (top: fx68k_fmax_top)
  - constraints/fx68k_trial.lpf
  - copy microrom.mem + nanorom.mem into the implementation directory
    (Synplify resolves $readmemb relative to it; a missing file = CPU
    that executes garbage with no error)

Run map + PAR, open the **Place & Route Trace** report (.twr):
  - "FREQUENCY NET clk_sys 85.000000 MHz": PASS/FAIL and worst slack
  - note the 5 worst paths (they tell us whether the documented
    Ir->microAddr/nanoAddr multicycles are the fix or not)

Interpretation:
  - PASS at 85 MHz          -> 42.5 MHz effective turbo is on the table
  - FAIL, slack > -3 ns     -> try the commented MULTICYCLE lines +
                               PAR strategy (more effort / timing-driven)
  - FAIL, slack much worse  -> 21.3 MHz effective is the fx68k turbo
                               ceiling here; compat mode unaffected either way
On hardware the trial also sanity-runs the core: red until reset releases,
then green toggling and blue flickering dimly (bus cycles executing).

## Milestone 3 — full socket top (compat mode, needs the carrier + Amiga)

  - rtl/base64_fx68k/base64_top.sv + constraints/base64.lpf + fx68k sources
  - NOTE: base64_top.sv was written against the upstream ijor port list;
    the fredrequin fork adds eab[31:24] — connect eab[23:1], leave the
    rest open, or take the small port-name diff from docs/ notes.
  - PHASE_OFS in base64_top.sv is the 7M alignment trim (see docs/clocking.md)
