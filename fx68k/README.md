# Base64 fx68k gateware

An implementation of the gateware for jbilander's Base64 MC68000 accelerator,
built around the **fx68k** cycle-accurate 68000 core.

This lives alongside the TG68k implementation by Alastair M. Robinson in the
[parent repository](../README.md). Both target the same hardware; this one is
a separate design rather than a modification of it, and the TG68k gateware is
untouched.

**Status: working.** Boots AmigaOS from SD card on Kickstart 1.3 and above,
with fast RAM in both Zorro II and 32-bit CPU space, from a cold start.

---

## The CPU core

fx68k is [Jorge Cwik's (ijor)](https://github.com/ijor/fx68k) cycle-accurate
68000, by way
of **Frédéric Requin's** performance and size rework in
[PR #6](https://github.com/ijor/fx68k/pull/6). That rework is what makes the
clock rate here possible — on his Stratix target it took Fmax from under
100 MHz to 130–135 MHz and the core from 5180 to under 3000 LEs, through:

* a rewritten ALU adder and reordered ALU opcodes,
* IR pre-decoding,
* one-hot `tState` encoding,
* the register file and microcode/nanocode ROMs moved into block RAM,
* a 32-bit address bus,
* Verilator lint cleanliness.

Three bugs in that fork had to be fixed before it would boot on an Amiga. All
three are documented with test data in the PR thread:

**Word/long subtract borrow.** The `a + ~b + 1` adder used the raw carry-out
directly as C and X. On the 68000 the carry flag for subtraction is the
*borrow*, its complement, so every word and long subtract set C and X
inverted together.

**Byte carry pollution.** At byte width the adder still sums all 16 bits, so
the bit read as the byte carry-out is a sum bit contaminated by the operand
bits at that position. Wrong roughly half the time when the upper bytes are
non-zero, corrupting byte add and subtract and the BCD instructions that
consume the same carry.

**Rx write mux.** One character. The Rx low-word write mux selected on
`rRyIsAreg_t4` instead of `rRxIsAreg_t4`, apparently copy-pasted from the Ry
mux below it. Any microinstruction writing Rx low while Rx and Ry were
different register types — `MOVE.L D0,A0`, for instance — wrote the wrong
internal bus into Rx. Since address registers include A7, the stack pointer
was corrupted during Exec init, giving a deterministic Guru 81000005 on every
boot.

Verification used a Verilator harness around the
[SingleStepTests m68000](https://github.com/SingleStepTests/m68000) vectors:
+3651 tests fixed with zero regressions, and parity with ijor's upstream core
across all 80 instruction families with bit-identical bus traces.

---

## Architecture

**Clocking.** The motherboard 7 MHz is multiplied by 12 in an external
ICS570B to give the single 85.13 MHz core clock (PAL; 85.909 MHz on NTSC,
which is what the timing constraint targets). fx68k runs at an effective 6x,
about 42.5 MHz. A phase aligner locks the core's cycle grid to the 7 MHz edge
so motherboard cycles land where the custom chips expect them.

**Bus interface.** A bus interface unit runs external cycles on the 7 MHz
grid regardless of core speed. CBT bus switches isolate the FPGA's fast
signalling from the motherboard, and are opened whenever another master owns
the bus.

**Internal slaves** answer without the cycle ever reaching the motherboard:
SDRAM fast RAM, the turbomem DiagArea ROM, and the SD card. They decode the
core's internal address bus, so they are invisible to external bus masters —
see *Known limitations*.

### Memory map

| Range | |
| --- | --- |
| `$200000`–`$9FFFFF` | Zorro II fast RAM, up to 8 MB, autoconfigured |
| `$08000000` | 16 MB fast RAM in 32-bit CPU space, added by `AddMemList` |
| assigned by autoconfig | 64 KB turbomem ROM window |
| assigned by autoconfig | 64 KB SD card window |

### Autoconfig boards

Three entries under OAHR manufacturer **5194**:

| Product | Board |
| --- | --- |
| 13 | Zorro II fast RAM |
| 14 | AutoConfig ROM — carries the DiagArea that calls `AddMemList` for the 16 MB at `$08000000` |
| 11 | SD card |

13 and 14 were assigned to Base64 by [OAHR](https://oahr.github.io/oahr/)
in August 2026.

Product 11 is deliberately *reused* rather than newly allocated: the SD card
is a port of the SF2000's and presents byte-identical autoconfig registers so
the unmodified `sfsd.device` binds without a driver fork. That ID is
registered to Niklas Ekström and Matt Harlum, whose design it is.

The chain is `cfgin -> fastmem -> turbomem -> SD -> cfgout`. J2 carries
/CFGIN, /CFGOUT and GND; a shunt on /CFGIN and GND is the normal
configuration. Jumper wires let another card configure first — an A590 on the
A500 expansion edge, or a Zorro card in a 2000.

### Why there is a ROM board at all

Memory at `$08000000` is outside the Zorro II autoconfig region, so no
`ERTF_MEMLIST` board can advertise it. The 64 KB I/O board carries a
`DiagArea` with `DAC_CONFIGTIME` set; expansion.library copies it into RAM and
calls its `DiagPoint`, which calls `AddMemList`. Same shape as CIDER's
separate Control Registers entry.

---

## Cold boot

The FPGA is the reset source. It drives /RESET and /HALT low through the
power-up hold, so the machine is reset with the CPU present rather than being
joined late by a CPU that missed the motherboard's own power-on reset. If the
core still double bus faults, it resets and retries, up to 15 attempts.

Boot statistics are published as four read-only words at offset `$F000` of the
turbomem window and printed by `cfgdump`:

```
  boot statistics:
    resets needed  1
    booted at      147 ms after the power-up hold
    phase slip     no
    boot_ok        yes
    core halted    no
    passive        no
```

Measured behaviour: the machine consistently needs exactly one extra reset,
promptly applied. *Why* it needs a second reset is not yet understood.

### Passive mode

An SF2000 on the A500 expansion edge takes the bus by asserting and holding
/BR — it avoids /BGACK because Gary adds a wait state to chip RAM cycles while
BGACK is asserted. Base64 watches /BR for ~1.5 ms after the power-up hold and,
if it is still held, hands the bus over for good: outputs tri-stated, CBT
switches open. The switches stay open for the whole decision window, so there
is no interval in which both boards drive.

Implemented but **not yet tested on hardware** — no second accelerator has
been available.

---

## Known limitations

**DMA into the Zorro II fast RAM is not supported.** The fast RAM decodes the
core's internal address bus, and the CBT switches are open while another
master owns the bus, so DMA cycles are invisible and never get DTACK. A Zorro
II DMA device targeting that range will hang. Set the mountlist `Mask` so the
filesystem bounces through chip RAM — `0x001FFFFE` — which is required for the
32-bit fast RAM anyway, since Kickstart 1.3 has no `MEMF_24BITDMA`.

Supporting it means reversing 28 of the most timing-critical pins to
bidirectional, a slave state machine, and CBT rework. Planned, but gated on
having a DMA device to test against.

**Timing margin is thin.** The design meets its 85.9 MHz constraint by around
+0.06 ns on a good placement run, and placement variance across builds is
larger than that. The underlying constraint is the **-6 speed grade**, the
slowest ECP5 for this part; a -7 would turn this into real margin. Expect to
re-run place and route after any change.

**MapROM is not implemented yet.**

---

## Building

Lattice Diamond, as for the parent project. Two traps have cost real time and
are worth knowing before the first build.

### The .mem files must be members of the Diamond project

`turbomem.mem` and `sfsd.mem` are loaded by `$readmemh`, which resolves
against the directory synthesis runs in — not the RTL tree. Putting them in
`rtl/` is not enough. **Diamond's Clean deletes them from `impl1/`**, along
with `microrom.mem` and `nanorom.mem`, so they need reinstating afterwards.

When one is missing the failure is silent and convincing: the array
constant-folds to zero, Synplify prunes the read register, and the board
enumerates perfectly while serving nothing but zeroes.

### Check the build log

```sh
grep -c CG371 <log>                  # $readmemh data file not found -- must be 0
grep -c CS101 <log>                  # index out of range        -- must be 0
grep -c BN105 <log>                  # must be 0
grep -m1 'Number of SLICEs'          # ~5000. If it says ~29, the design collapsed
grep -m1 'Number of block RAMs'      # 21 of 56. Fewer means a .mem did not load
```

The resource counts are the checks that cannot be misread. A `CS101` from a
parameter indexing past the end of a counter once produced a 29-SLICE
bitstream that held /RESET low forever.

### Strategy settings that meet timing

```
Path-based Placement            Off
Placement Effort Level          5
Placement Iteration Start Pt    2
Placement Iterations            20
Placement Sort Best Run         Worst Slack
Routing Delay Reduction Passes  10
Routing Passes                  20
Routing Resource Optimization   6
```

**Do not turn Path-based Placement on.** It is catastrophic here — 4096 of
4096 items failing at -1.870 ns, with the microcode address path dominant.
With it off the same design reaches +0.06 ns.

---

## Tools

Under `sw/turbomem`:

* `make rom` / `make install-mem` — build the DiagArea ROM image and install
  it to both the RTL tree and the Diamond implementation directory.
* `make check-diag` — validates the DiagArea header before it can reach
  hardware: bus width, boot-time field, entry offsets, size against the real
  image, name termination. Every defect it checks for was once silent at build
  time and cost a hardware round trip.
* `make cfgdump` — prints what expansion.library actually recorded for every
  board, reads each DiagArea back through its window, and prints the boot
  statistics.
* `make hello STAGE=n` — staged bring-up harness.

---

## Credits

* **Alastair M. Robinson** — the parent project and its TG68k gateware.
* **Jorge Cwik (ijor)** — the fx68k core.
* **Frédéric Requin** — the fx68k performance and size rework this build
  depends on.
* **Niklas Ekström** and **Matt Harlum** — the SF2000 SD card design and
  `sfsd.device`, ported here unchanged.
* **Tobias Gubener** — TG68k, used by the parent implementation.
* The **[Open Amiga Hardware Repository](https://oahr.github.io/oahr/)** for
  manufacturer ID 5194 and the product ID allocations.
