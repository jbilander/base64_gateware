# =====================================================================
# fx68k/sw/turbomem/Makefile
#
# Lives under fx68k/ rather than a top-level sw/ because this repo is
# shared: prj/ carries tg68test alongside base64_fx68k, and fx68k/ is
# already where the fx68k-specific BUILD.md, constraints and docs live.
# Nothing here should ever be reachable from a tg68k build.
#
# Two products from one source file:
#
#   make test   ->  TestAddTurboMem       CLI tool, run it from the Shell
#   make rom    ->  turbomem.bin       raw image for the autoconfig ROM
#                   turbomem.mem       EBR init file for synthesis
#
# The ROM build compiles the SAME turbomem_add() the CLI tool exercises,
# just without the harness. That is the whole point of the arrangement:
# validate the payload from the Shell first, so that when the ROM does
# not work you know the fault is in the delivery, not the code.
#
# Adapted from the simple.device Makefile. Differences worth knowing:
#
#   - The ROM target does NOT run elf2hunk. A hunk file has headers and
#     relocation hunks; the ROM needs raw bytes, so objcopy -O binary.
#   - -Ttext=0 on the ROM link. Combined with the no-globals /
#     no-absolute-addressing rules in turbomem.c, that gives an image
#     which runs correctly wherever expansion.library copies it, with
#     no DiagArea relocation table needed.
#   - No -s on either build while bringing this up. The map and the
#     disassembly are the only way to check the PIC constraints held,
#     and stripping throws them away.
# =====================================================================

NDK      ?= $(HOME)/AMIGA_GCC/NDK_3.2_elf
INCDIRS   = . $(NDK)/sys-include

CC        = m68k-amiga-elf-gcc
OBJCOPY   = m68k-amiga-elf-objcopy
OBJDUMP   = m68k-amiga-elf-objdump

TESTDIR   = build-test
ROMDIR    = build-rom

# Where synthesis expects to find the EBR init file.
#
# COMMIT the installed .mem. Synthesis needs it, but it is produced by an
# m68k cross-compiler that a gateware-only contributor has no reason to
# have installed. Checking in the generated file keeps "clone and build
# in Diamond" working without an Amiga toolchain -- the source of truth
# stays here, the product lives where the RTL can reach it.
RTLDIR    = ../../../rtl/base64_fx68k

# -ffixed-a6 IS NOT OPTIONAL.
#
# a6 is the Amiga library base register: every NDK inline loads it before
# the jsr. GCC does not know that and treats a6 as an ordinary
# callee-saved register, so under pressure it will park a live value there
# and expect it to survive a library call. It does not.
#
# That is exactly what happened here. GCC emitted "movea.l d0,a6" to hold
# lib_Version across a cprintf call, RawDoFmt overwrote a6 with SysBase,
# and the program misbehaved from that point -- no output on 3.1.4, a hang
# with the floppy motor on under 1.3. The bug only appeared once
# dump_memlist raised register pressure enough for GCC to reach for a6;
# the identical code compiled correctly before that.
#
# -Wno-volatile-register-var: the NDK's LPxNR inline macros pin arguments
# to registers, and GCC warns about every one. The simple.device Makefile
# carries the same flag for the same reason.
CFLAGS    = -m68000 -Wall -Wextra -Wno-unused-parameter \
            -Wno-volatile-register-var -Wno-array-bounds \
            -ffixed-a6 \
            -fomit-frame-pointer -O2 $(addprefix -I,$(INCDIRS))

# ROM build only. -mpcrel makes GCC reference data PC-relative instead of
# absolutely, which is what keeps .rodata usable from a copied image. The
# first ROM build without it produced three R_68K_32 relocations into
# .rodata -- the probe table and the name string -- so the image would
# have run where it was copied and read its data from where it was
# linked. Range is +/-32K, which a ROM this size is nowhere near.
ROMFLAGS  = -mpcrel
# --emit-relocs IS REQUIRED FOR THE HUNK BUILD.
#
# DOS loads a hunk executable wherever it likes and fixes up absolute
# references from HUNK_RELOC32 entries. elf2hunk can only produce those if
# the ELF still carries its relocations, which ld discards by default.
#
# Without it the code keeps its link-time addresses: "lea 60,a1" for the
# "dos.library" string still says $60 after DOS has loaded the program at
# $23C010, so OpenLibrary gets a pointer into the exception vector table,
# fails, and the program exits silently. That is what produced an empty
# prompt on 3.1.4, a hang on 1.3, and the original Guru 81000005 -- every
# one of those was this, not the entry point, not a6, and not the name
# pointer.
#
# simple.device's Makefile has this flag. It belongs in LDFLAGS so both
# the test and ROM builds get it, not just the ROM.
LDFLAGS   = -nostdlib -nostartfiles -T turbomem.ld -Wl,--emit-relocs

.PHONY: all test rom hello check-lvo check-pic check-a6 check-entry check-relocs install-mem clean
all: test

# ---------------------------------------------------------------------
# CLI test tool
# ---------------------------------------------------------------------
test: $(TESTDIR)/TestAddTurboMem

$(TESTDIR):
	@mkdir -p $@

$(TESTDIR)/TestAddTurboMem: turbomem.c turbomem.ld | $(TESTDIR)
	$(CC) $(CFLAGS) -DTURBOMEM_CLI -o $@.elf turbomem.c $(LDFLAGS) \
	    -Wl,-Map=$@.map
	elf2hunk $@.elf $@
	$(OBJDUMP) -D $@.elf > $@.s
	@$(MAKE) --no-print-directory check-entry ENTRY_ELF=$@.elf
	@echo "--> $@   copy to the Amiga and run it from the Shell"

# ---------------------------------------------------------------------
# Bisect harness
#
#   make hello STAGE=1   OpenLibrary + Write of a literal
#   make hello STAGE=2   adds RawDoFmt / putch formatting
#   make hello STAGE=3   adds the $08000000 probe loop, reporting only
#
# Whichever stage stops printing is the broken one, and everything below
# it is proven. Run them in order.
# ---------------------------------------------------------------------
STAGE ?= 1

hello: | $(TESTDIR)
	$(CC) $(CFLAGS) -DSTAGE=$(STAGE) -o $(TESTDIR)/Hello$(STAGE).elf \
	    hello.c $(LDFLAGS) -Wl,-Map=$(TESTDIR)/Hello$(STAGE).map
	elf2hunk $(TESTDIR)/Hello$(STAGE).elf $(TESTDIR)/Hello$(STAGE)
	$(OBJDUMP) -D $(TESTDIR)/Hello$(STAGE).elf > $(TESTDIR)/Hello$(STAGE).s
	@$(MAKE) --no-print-directory check-entry \
	    ENTRY_ELF=$(TESTDIR)/Hello$(STAGE).elf
	@echo "--> $(TESTDIR)/Hello$(STAGE)"

# ---------------------------------------------------------------------
# ROM image
# ---------------------------------------------------------------------
rom: $(ROMDIR)/turbomem.mem check-pic

$(ROMDIR):
	@mkdir -p $@

$(ROMDIR)/turbomem.elf: turbomem.c turbomem.ld | $(ROMDIR)
	$(CC) $(CFLAGS) $(ROMFLAGS) -o $@ turbomem.c $(LDFLAGS) \
	    -Wl,-Map=$(ROMDIR)/turbomem.map
	$(OBJDUMP) -D $@ > $(ROMDIR)/turbomem.s

# Pad to a whole number of 16-bit words.
#
# The image came out 167 bytes: .text 0x7e plus .rodata 0x29. hexdump's
# "2/1" format then read a single byte on its last iteration and emitted a
# two-character line, which $readmemh parses as a small value and loads
# into the wrong half of the final word -- quietly corrupting the last
# byte of the name string. Padding with a zero byte keeps every line four
# characters wide. Harmless to the ROM itself, since da_Size states the
# real length.
$(ROMDIR)/turbomem.bin: $(ROMDIR)/turbomem.elf
	$(OBJCOPY) -O binary $< $@
	@sz=$$(stat -c%s $@); \
	 if [ $$((sz % 2)) -ne 0 ]; then \
	   printf '\0' >> $@; \
	   echo "    padded 1 byte for word alignment"; \
	 fi
	@echo "--> $@  $$(stat -c%s $@) bytes"

# One 16-bit word per line, big-endian, which is both what the 68000
# expects and what $readmemh / the Lattice EBR init wants. Note the
# format is 2/1 "%02x" -- two separate BYTES -- not 1/2, which would
# emit the word in the build host's byte order and quietly give you a
# ROM with every halfword swapped.
$(ROMDIR)/turbomem.mem: $(ROMDIR)/turbomem.bin
	hexdump -v -e '2/1 "%02x" "\n"' $< > $@
	@bad=$$(grep -cvE '^[0-9a-f]{4}$$' $@ || true); \
	 if [ "$$bad" -ne 0 ]; then \
	   echo "*** $$bad malformed line(s) - not 4 hex digits ***"; exit 1; \
	 fi
	@echo "--> $@  $$(wc -l < $@) words, all 4 digits"

install-mem: $(ROMDIR)/turbomem.mem
	cp $< $(RTLDIR)/turbomem.mem
	@echo "--> installed into $(RTLDIR)/"

# ---------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------

# The ROM image must contain no absolute relocations. If this prints
# anything, one of the rules at the top of turbomem.c has been broken and
# the image will run where it was copied but jump where it was linked.
check-pic: $(ROMDIR)/turbomem.elf
	@echo "=== absolute relocations (expect none) ==="
	@$(OBJDUMP) -r $< | grep -E "R_68K_32|R_68K_16" || echo "  clean"
	@echo "=== sections (.data/.bss empty; .rodata may exist but must"
	@echo "    not be referenced absolutely - see the check above) ==="
	@$(OBJDUMP) -h $< | grep -E "\.data|\.bss|\.text|\.rodata"

# Verify the AddMemList LVO before trusting it. A wrong offset jumps into
# a neighbouring exec function with our arguments already in registers.
check-lvo:
	@echo "=== inline header ==="
	@grep -rn -A4 "AddMemList" $(NDK)/sys-include/inline/exec.h || true
	@echo "=== assembler LVO equates ==="
	@grep -rn "_LVOAddMemList" $(NDK) || true
	@echo "=== DiagArea layout and DAC_ flags, for the next stage ==="
	@grep -rn "da_DiagPoint\|DAC_WORDWIDE\|struct DiagArea" $(NDK)/sys-include/ || true
	@echo "=== DiagPoint calling convention (autodocs, if shipped) ==="
	@grep -rln "DiagPoint" $(NDK) --include="*.doc" --include="*.guide" || true

# elf2hunk enters at the start of the first code hunk, so _start must be
# at the lowest address in .text. If it is not, DOS jumps into whatever
# function the compiler emitted first.
# A hunk build with no relocations loads at one address and refers to
# another. Catch it here rather than on the Amiga.
check-relocs: $(TESTDIR)/TestAddTurboMem
	@echo "=== relocations in the ELF (hunk build needs these) ==="
	@n=$$($(OBJDUMP) -r $(TESTDIR)/TestAddTurboMem.elf | grep -c R_68K_32 || true); \
	 echo "  R_68K_32 count: $$n"; \
	 if [ "$$n" -eq 0 ]; then \
	   echo "  *** NONE - elf2hunk cannot emit HUNK_RELOC32 ***"; exit 1; \
	 else echo "  OK"; fi

ENTRY_ELF ?= $(TESTDIR)/TestAddTurboMem.elf
check-entry:
	@first=$$($(OBJDUMP) -d $(ENTRY_ELF) | grep -E "^[0-9a-f]{8} <" | head -1); \
	echo "first symbol in .text: $$first"; \
	case "$$first" in *"<_start>"*) echo "  OK - entry is at offset 0" ;; \
	  *) echo "  *** WRONG - DOS will jump here instead of _start ***"; exit 1 ;; \
	esac

# a6 must never appear as a destination outside the library-call stubs.
# If this finds anything, -ffixed-a6 is missing or has been dropped.
check-a6: $(TESTDIR)/TestAddTurboMem
	@echo "=== a6 used as a general register (expect none) ==="
	@grep -E "movea?\.[lw][^,]*,%?a6|,a6$$" $(TESTDIR)/TestAddTurboMem.s \
	   | grep -v "4 <_start" | grep -v "SysBase" || echo "  clean"

clean:
	rm -rf $(TESTDIR) $(ROMDIR)
