# Gateware for jbilander's Base64 MC68000 accelerator project
by Alastair M. Robinson
making use of the TG68k CPU core by Tobias Gubener

> **This fork also contains a second, independent gateware implementation
> built around the fx68k cycle-accurate 68000 core, in
> [`fx68k/`](fx68k/README.md).** It targets the same hardware and is a
> separate design rather than a modification of the one described below,
> which is unchanged and still builds as documented here.
>
> The fx68k build boots AmigaOS from SD card on Kickstart 1.3 and above with
> fast RAM in both Zorro II and 32-bit CPU space. See
> [fx68k/README.md](fx68k/README.md) for its architecture, autoconfig
> layout, build notes and current status.

## Hardware

The Base64 is a carrier board that fits the MC68000 socket and hosts an
[iCESugar-Pro](https://github.com/wuxx/icesugar-pro) FPGA module by Muse Lab.
The module is open hardware, with the schematic published as a PDF in that
repository, and carries:

* a Lattice **LFE5U-25F-6BG256C** ECP5 in DDR2 SODIMM form factor, 106 usable IOs
* **32MB SDRAM** (IS42S16160B)
* 32MB SPI flash (W25Q256JV)
* a 25MHz crystal, a micro-SD slot and an RGB LED

Modules can be bought from Muse Lab's store on AliExpress, Tindie or Amazon.

Carrier board design, schematics and gerbers:
[github.com/jbilander/Base64](https://github.com/jbilander/Base64)

## Programming the module

Bitstreams go on over the module's USB-C connector. The on-board iCELink
debugger appears as a virtual disk — drop the `.bit` file onto it and wait a
few seconds while it writes the SPI flash. No adapter, no drivers, no extra
tools.

> ### Do this with the module OUT of the Amiga
>
> Program it before seating it in the SO-DIMM socket.
>
> There is **no protection on the module between its 5V rail and USB 5V**, so
> plugging in USB while it is installed ties the Amiga's 5V to the host's with
> nothing in between, and whichever is higher back-drives the other. In
> practice USB is closer to a true 5.0V while the Amiga usually sits nearer
> 4.9V, so what happens is your PC powering the Amiga's 5V rail rather than
> the reverse — which is not what you want either. Two unprotected supplies
> tied together is not a state to leave a machine in, whichever way the
> current flows.
>
> If USB has to stay attached while the module is installed, use a **data-only
> cable** with the 5V conductor cut, leaving D+, D- and GND.

Building from source is covered below for this implementation, and in
[fx68k/BUILD.md](fx68k/BUILD.md) for the fx68k one. The external-JTAG route —
needed only for Reveal Analyzer, and requiring the iCELink to be disabled by a
hardware modification — is described there too.

## General structure:

### Clock recovery:
The incoming 7MHz Amiga clock is multiplied on the carrier board. On Rev B this
was an ICS501 (501MLFT) doubling it to 14MHz, to give the ECP5's PLLs a fast
enough base clock. Rev C replaces that with an ICS570B (570BLFT) which
generates a 12x clock directly.

A high frequency clock of an integer multiple is generated, then _pos and _neg strobe signals
are generated to mark the rising and falling edges of the 7MHz clock.
  
### MC68000 bus state machine
Has responsibility for the 24-bit address space
Handles communication with the motherboard
Can intercept Autoconfig accesses in order to configure 32-bit Fast RAM and potentially
other devices such as SD card.
  
### CPU Wrapper
A shim around TG68K which does basic address decoding, directing addresses in 24-bit space
to the bus state machine, and addresses in 32-bit space to the SDRAM controller / cache.
Potentially reserve some RAM space for a kickstart ROM, in which case some of the 24-bit address
will have to be decoded too.
  
### SDRAM controller and cache
SDRAM controller will run in burst mode - 4 words or words

## Building

There are a few paths that need to be set so that the project can find the
required tools - this is done by copying the "site.template" file to "site.mk"
then editing site.mk to set the paths.

The following tools are required to build this project:

### Lattice Diamond
To build bitstreams for the FPGA you'll need Lattice Diamond. Version 3.11 is
recommended (newer versions may work, but have been known to cause problems
with the Minimig core on ECP5-based boards, so 3.11 is the safest option.)

Lattice Diamond is provided as a .rpm file, which is a bit awkward to install
on .deb-based distributions such as Ubuntu or Mint (or Debian, of course!) -
some information on the subject can be found at
https://retroramblings.net/?p=1917

### openFPGALoader
You can use whichever tool you like to load bitstreams onto the FPGA, but the
makefiles expect to use openFPGALoader.

### Verilator
Makefiles with a "sim" target will expect to use Verilator for simulation. It
will need to be at least version 5.
In order to build with verilator, it's necessary to set the path to
Verilator's  includes in the site.mk file.  (If Verilator is installed 
systemwide this will probably be /usr/share/verilator/include - or if you're
using oss-cad-suite,  it will likely be
/path/to/oss-cad-suite/share/verilator/include

### OpenOCD
Some projects are able to capture data from the running design over JTAG.
This is done using OpenOCD.

The easiest way to obtain openFPGALoader, Verilator and OpenOCD (if your
distro of choice doesn't supply new enough versions) is to install
oss-cad-suite from https://github.com/YosysHQ/oss-cad-suite-build

### Open-source tooling
While yosys and nextpnr have mature and dependable support for the Lattice
ECP5 FPGAs, the last time I checked they struggled to build the TG68K CPU,
which is why this project uses Diamond.

