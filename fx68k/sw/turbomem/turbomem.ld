/* turbomem.ld -- force the entry point to offset 0.
 *
 * WHY THIS EXISTS
 *
 * elf2hunk makes the START OF THE FIRST CODE HUNK the entry point. It does
 * not read ENTRY() and it does not care which symbol the ELF nominates. So
 * whichever function the compiler happens to emit first is what DOS jumps
 * to.
 *
 * Without this script the layout came out putch, cprintf, turbomem_add,
 * _start -- so running the tool entered putch with garbage in d0/a3, did a
 * double-indirect write through a wild pointer, and fell through into the
 * following functions. The result was Guru 81000005, AN_MemCorrupt.
 *
 * Source order does not fix it: turbomem_add is defined above putch in the
 * file and still landed third. -O2 reorders freely.
 *
 * The ROM build needs the identical guarantee for a different reason: the
 * autoconfig ROM vector points at offset 0, so the DiagArea header must be
 * the first thing in the image. Same script, same .text.entry section.
 */

ENTRY(_start)

SECTIONS
{
    . = 0;

    .text : {
        *(.text.entry)          /* _start, or later the DiagArea header */
        *(.text .text.* .gnu.linkonce.t.*)
    }

    .rodata : {
        *(.rodata .rodata.* .gnu.linkonce.r.*)
    }

    .data : {
        *(.data .data.* .gnu.linkonce.d.*)
    }

    .bss : {
        *(.bss .bss.* COMMON)
    }

    /* Image size, for the DiagArea's da_Size. Works because the script
     * starts at 0, so the end address IS the length. .data and .bss are
     * empty by construction -- check-pic enforces that -- so this lands
     * immediately after .rodata.
     *
     * ROUNDED UP TO A WHOLE WORD, deliberately. expansion.library copies a
     * DAC_WORDWIDE diag area wordwise, and an odd da_Size invites a
     * (size >> 1) loop to drop the final byte. The final byte of this
     * image is the NUL terminating the name string exec keeps a pointer
     * to for the life of the machine. One byte of padding costs nothing
     * and removes the question -- and the Makefile already pads the .bin
     * to the same boundary for $readmemh, so the two now agree. */
    . = ALIGN(2);
    __rom_end = .;

    /DISCARD/ : { *(.comment) *(.note*) }
}
