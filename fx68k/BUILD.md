# Building the fx68k gateware

How to get from a fresh clone to a bitstream. For what the design *is* —
architecture, memory map, autoconfig layout, current status and known
limitations — see [README.md](README.md).

## What you need

* **Lattice Diamond** (Linux) with **Synplify Pro**. Not LSE.
* A **USB-C cable**. That is the whole toolchain for programming — see below.

A JTAG adapter and `ecpprog` are **not** required. They are only worth setting
up if you want Reveal Analyzer, and doing so costs you the easy route.

## Repo setup

    git clone -b fx68k --recurse-submodules git@github.com:jbilander/base64_gateware.git

If you cloned without submodules: `git submodule update --init`

## Diamond project

File > New > Project:

* Device family **ECP5**, LFE5U-25F, package CABGA256, speed grade **6**,
  part **LFE5U-25F-6BG256C** — the part on the iCESugar-Pro module.
* Synthesis tool: **Synplify Pro** (not LSE).
* Top-level unit: `base64_top` (Project > Active Implementation >
  Set Top-Level Unit).
* Constraints: `constraints/base64.lpf` — replace the blank default — and
  `constraints/base64.fdc`.

Sources: everything in `rtl/base64_fx68k/`, plus the fx68k core —
`rtl/fx68k/fx68k_pkg.sv`, `fx68k.sv`, `fx68kAlu.sv`, `uaddrPla.sv`,
`rtl/fx68k/bram/fx68kRegs_generic.sv` and `bram/fx68kRom_generic.sv` — and the
SDRAM controller.

The fx68k sources are the **fredrequin fork with the three bug fixes applied**;
see the core section of the README. An unfixed fork will not boot.

## Memory initialisation files — read this before the first build

Four `.mem` files are loaded by `$readmemh`/`$readmemb` at synthesis:

| File | Where it comes from |
| --- | --- |
| `microrom.mem`, `nanorom.mem` | ship with the fx68k core |
| `turbomem.mem` | built by `make rom` in `sw/turbomem` |
| `sfsd.mem` | converted by hand from LIV2's `sfsd.rom`, see below |

**All four must be members of the Diamond project**, and they resolve against
the directory synthesis runs in — the implementation directory, not the RTL
tree. Putting them in `rtl/` is not enough.

**Diamond's Clean deletes them from `impl1/`.** Reinstate them afterwards.
`make install-mem` in `sw/turbomem` handles `turbomem.mem` and takes an
`IMPLDIR=` override if your path differs.

When one is missing the failure is silent and convincing: the array
constant-folds to zero, Synplify prunes the read register, and the design
builds and runs while that ROM serves nothing but zeroes. A missing
`microrom.mem` gives a CPU that executes garbage with no error at all.

### Regenerating a .mem from a ROM image

`turbomem.mem` is produced by `make rom`. `sfsd.mem` is not: the SD card boot
ROM is maintained upstream in
[LIV2/amiga-par-to-spi-adapter](https://github.com/LIV2/amiga-par-to-spi-adapter)
and published as `sfsd.rom`, so it has to be converted whenever a new one
appears.

```sh
hexdump -v -e '1/1 "%02X" "\n"' sfsd.rom      > sfsd.mem       # BYTE-wide
hexdump -v -e '2/1 "%02x" "\n"' turbomem.bin  > turbomem.mem   # WORD-wide
```

**Note `1/1` against `2/1`.** The two files are not the same shape.
`sfsd.mem` is byte-wide, one byte per line, because the SD boot ROM is served
on D[7:0] at odd addresses. `turbomem.mem` is word-wide, two bytes per line,
because the DiagArea is `DAC_WORDWIDE`. Use the wrong one and you get a file
that loads without complaint and serves nonsense.

Worth checking after a conversion — a truncated or wrongly cased file will
still load:

```sh
wc -l sfsd.mem                        # 32768
grep -cvE '^[0-9A-F]{2}$' sfsd.mem    # 0
```

`sfsd.mem` has to be copied to both `rtl/base64_fx68k/` and the Diamond
implementation directory by hand; `make install-mem` only handles
`turbomem.mem`.

## Strategy settings

These meet timing. The design has little margin, so they matter:

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
With it off the same design closes.

Expect to re-run place and route after any change: placement variance between
builds is larger than the margin.

## Check the build log

```sh
grep -c CG371 <log>                  # $readmemh data file not found -- must be 0
grep -c CS101 <log>                  # index out of range           -- must be 0
grep -c BN105 <log>                  # must be 0
grep -m1 'Number of SLICEs'          # ~5000. If it says ~29, the design collapsed
grep -m1 'Number of block RAMs'      # 21 of 56. Fewer means a .mem did not load
```

Then the Place & Route Trace report (`.twr`): hold errors first, then setup.
Both must be zero.

The resource counts are the checks that cannot be misread — a `CS101` from a
parameter indexing past the end of a counter once produced a 29-SLICE
bitstream that held /RESET low forever, and the SLICE count would have caught
it instantly.

## Programming

> ### Program the module OUT of the Amiga
>
> Do it before seating the module in the SO-DIMM DDR2 socket.
>
> The iCESugar-Pro has **no protection between its 5V rail and USB 5V**, so
> plugging in USB while the module is installed ties the Amiga's 5V to the
> host's with nothing in between, and whichever is higher back-drives the
> other. In practice USB is closer to a true 5.0V while the Amiga usually
> sits nearer 4.9V, so the direction ends up being your PC powering the
> Amiga's 5V rail rather than the reverse — which is not what you want
> either. Two unprotected supplies tied together is not a state to leave a
> machine in, whichever way the current happens to flow.
>
> If you need USB attached while the module is installed — capturing with
> Reveal, for instance — use a **data-only cable** with the 5V conductor
> cut, leaving D+, D- and GND. Check the 5V pin on the JTAG header the same
> way if your external adapter drives it rather than just sensing it.

### Normally: drag and drop

Plug a USB-C cable from your PC into the module. The on-board **iCELink**
debugger (DAPLink-based) appears as a virtual disk. Drop
`prj/base64_fx68k/impl1/base64_fx68k_impl1.bit` onto it and wait a few
seconds while it programs the SPI flash. That is all — no adapter, no
`ecpprog`, no drivers.

Muse Lab's `icesprog` tool does the same from the command line if you prefer.

### With an external JTAG adapter

Only needed if you want **Reveal Analyzer**, which requires the ECP5's native
JTAG, and the iCELink drives those same pins.

**This is a hardware modification.** To use an external adapter you must
disable the iCELink by connecting the designated pad — near the 3.3V rail by
the JTAG header — to GND. Once you do, **drag-and-drop programming stops
working** and the adapter becomes the only way in. Do not do this unless you
actually need on-chip debug.

The 6-pin header next to it is, in order: 5V, TDO, TDI, TMS, TCK, GND.

With the adapter connected, to SPI flash:

    ecpprog -d i:0x0403:0x6010 -I A prj/base64_fx68k/impl1/base64_fx68k_impl1.bit

Add `-S` to load SRAM instead: volatile, lost on power-off, but much faster
for iterating.

Check the VID:PID against your adapter — FT2232H is `0x6010`, FT4232H is
`0x6011`.

## If the flow itself is suspect

`rtl/blink/blink_top.v` with `constraints/blink.lpf` is a minimal design that
runs on a bare iCESugar-Pro over USB power, no carrier needed. Top module
`blink_top`; a green LED blinking at roughly 1.5 Hz means Diamond, the LPF and
your programming route are all working. Worth doing once on a new machine
before blaming the real design.

---

*Historical: this file used to carry an fx68k fmax trial as milestone 2, to
find out whether 42.5 MHz effective was reachable. It is, and the design runs
there — 85.13 MHz master clock, 6x effective — so the trial has been removed.
The note about connecting only `eab[23:1]` has gone too: the design now uses
the full 32-bit address bus, decoding `a[31:24] == $08` for the CPU-space
window.*
