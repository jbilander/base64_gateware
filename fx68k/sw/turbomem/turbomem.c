/* turbomem.c -- register the $08000000 CPU-space fast RAM with exec.
 *
 * This one file is BOTH the CLI test tool and the payload that will later
 * become the autoconfig ROM's DiagPoint routine. That is the point: the
 * code you validate from the Shell is byte-for-byte the code that ends up
 * in the ROM, so when the ROM build misbehaves you already know the
 * payload is not at fault and the problem is in the delivery.
 *
 * Build as a CLI tool:
 *   make            ->  TestAddTurboMem
 *
 * The name is about what it proves: not that the memory works -- the
 * probe is only a guard -- but that AddMemList registers it correctly
 * under the constraints the ROM will impose.
 *
 * Build as a ROM payload: drop -DTURBOMEM_CLI, add -Ttext=0, and link
 * with the DiagArea header object first.
 *
 * CONSTRAINTS THAT APPLY TO turbomem_add() AND MUST NOT BE RELAXED
 *
 *   - No absolute addressing except *(void**)4, which assembles to
 *     "move.l 4.w,a6" (absolute SHORT) and needs no relocation entry.
 *   - No writable globals. In the ROM build the image is copied to RAM
 *     and run from wherever it lands; a global would need either a GOT or
 *     a relocation table, and avoiding both is what keeps the DiagArea
 *     relocation format out of this project entirely.
 *   - No library calls other than exec, and those go through the explicit
 *     register form below rather than proto/exec.h inlines, because those
 *     inlines reference a global SysBase.
 *
 * Check the objdump after building the ROM variant: if there are any
 * absolute relocations against .text or .data, one of the above has been
 * violated and the ROM will run wherever it was copied and jump wherever
 * it was linked.
 */

#include <exec/types.h>
#include <exec/memory.h>
#include <exec/execbase.h>

#ifdef TURBOMEM_CLI
#include <proto/exec.h>
#include <proto/dos.h>
#include <stdarg.h>
#endif

/* MUST come after every NDK header, not before.
 *
 * It works by #pragma GCC poison, and a poisoned identifier cannot appear
 * ANYWHERE -- including in a declaration. Put this first and
 * clib/exec_protos.h fails on its own prototypes for CacheClearU,
 * CreateIORequest and the rest, none of which we call. Put it last and
 * those declarations are already in, so the poison only bites on code
 * written below this line, which is what we actually want.
 *
 * It earns its place: the first version of the harness used Printf and
 * PutStr, both V36+, which on 1.3 would have entered dos.library at
 * offsets belonging to something else entirely.
 *
 * Confirmed NOT poisoned, so safe: AddMemList, RawDoFmt, OpenLibrary,
 * CloseLibrary, Write, Output. */
#include <ks13_compat.h>

#define TURBO_BASE   0x08000000UL
#define TURBO_SIZE   (16UL * 1024 * 1024)

/* Lower than the Z2 block on purpose. exec allocates from higher priority
 * pools first, so the 24-bit-safe $200000 memory gets consumed before
 * anything lands above 16 MB. On 1.3 that matters: Zorro II bus masters
 * drive only 24 address bits and there is no MEMF_24BITDMA for a driver
 * to ask for DMA-safe memory with. */
#define TURBO_PRI    (-5)

static const char TURBO_NAME[] = "turbo memory";

/* exec.library LVO. VERIFY THIS against the NDK before trusting it --
 * a wrong LVO here jumps into a neighbouring function with our arguments
 * in the registers, which is a far more entertaining failure than a
 * simple crash. */
#define LVO_AddMemList  (-618)

/* Explicit-register call. Avoids proto/exec.h, whose inlines reference a
 * global SysBase we are not allowed to have. */
static void call_AddMemList(struct ExecBase *sysbase,
                            ULONG size, ULONG attrs, LONG pri,
                            APTR base, CONST_STRPTR name)
{
    register struct ExecBase *a6 asm("a6") = sysbase;
    register ULONG            d0 asm("d0") = size;
    register ULONG            d1 asm("d1") = attrs;
    register LONG             d2 asm("d2") = pri;
    register APTR             a0 asm("a0") = base;
    register CONST_STRPTR     a1 asm("a1") = name;

    asm volatile ("jsr %c6(%0)"
                  :
                  : "r"(a6), "r"(d0), "r"(d1), "r"(d2), "r"(a0), "r"(a1),
                    "i"(LVO_AddMemList)
                  : "cc", "memory");
}

/* Disable is exec LVO -120, Enable -126. Both V33, both take only A6.
 * VERIFY WITH `make check-lvo` before trusting these: a wrong LVO here lands
 * in a neighbouring function while interrupts are in an unknown state. */
#define LVO_Disable  (-120)
#define LVO_Enable   (-126)

static void call_Disable(struct ExecBase *sysbase)
{
    register struct ExecBase *a6 asm("a6") = sysbase;
    asm volatile ("jsr %c1(%0)"
                  : : "r"(a6), "i"(LVO_Disable)
                  : "d0", "d1", "a0", "a1", "cc", "memory");
}

static void call_Enable(struct ExecBase *sysbase)
{
    register struct ExecBase *a6 asm("a6") = sysbase;
    asm volatile ("jsr %c1(%0)"
                  : : "r"(a6), "i"(LVO_Enable)
                  : "d0", "d1", "a0", "a1", "cc", "memory");
}

/* AllocMem is exec LVO -198, V33, not poisoned. Same explicit-register
 * form as call_AddMemList and for the same reason. CLI build only -- the
 * ROM has no use for it, see the note at the call site. */
#ifdef TURBOMEM_CLI
#define LVO_AllocMem  (-198)

static APTR call_AllocMem(struct ExecBase *sysbase, ULONG size, ULONG reqs)
{
    register struct ExecBase *a6 asm("a6") = sysbase;
    register ULONG            d0 asm("d0") = size;
    register ULONG            d1 asm("d1") = reqs;
    register APTR             ret asm("d0");

    asm volatile ("jsr %c3(%1)"
                  : "=r"(ret)
                  : "r"(a6), "r"(d0), "i"(LVO_AllocMem), "r"(d1)
                  : "a0", "a1", "cc", "memory");
    /* d1 is an INPUT bound to the d1 register, so it must not also appear
     * in the clobber list -- GCC rejects that outright. It is dead after
     * the call, which is what matters. Same reason "d0" is absent: it is
     * the output. debug.c can clobber d1 freely only because it does not
     * pass anything in it. */
    return ret;
}
#endif /* TURBOMEM_CLI */

/* Probe offsets. The failure this is really hunting is ALIASING -- a
 * window that decodes fewer address bits than it claims wraps, and a
 * test that writes-then-reads each address in turn sails straight past
 * it. So every address is written before any address is read, and the
 * pattern is derived from the offset so a correct-looking value arriving
 * from the wrong place is still caught.
 *
 * The 0x00800000 entry is the important one: it is exactly where a
 * window that only decoded 8 MB would fold back onto offset 0. */
static const ULONG probe_offsets[] = {
    0x00000000UL,
    0x00000004UL,
    0x00400000UL,
    0x00800000UL,
    0x00C00000UL,
    0x00FFFFF8UL,
    0x00FFFFFCUL
};
#define NPROBES  (sizeof(probe_offsets) / sizeof(probe_offsets[0]))

#define PATTERN(off)  ((off) ^ 0xA5A5A5A5UL)

/* Returned by turbomem_add() when exec is too old to have AddMemList. */
#define TURBOMEM_BAD_VERSION  0xFFFFFFFFUL

/* Returns 0 on success, TURBOMEM_BAD_VERSION if exec is too old, or the
 * 1-based index of the first probe that failed. Does not add the memory
 * unless every probe passes. */
ULONG turbomem_add(struct ExecBase *sysbase)
{
    volatile ULONG *p;
    ULONG i;

    /* AddMemList appeared in exec V33 (Kickstart 1.2). V34 is 1.3, which
     * is the oldest we care about and is known to work -- expansion.library
     * itself uses AddMemList to add Zorro RAM on 1.2/1.3, so this is well
     * trodden ground rather than something we are getting away with.
     *
     * Note what is deliberately NOT here: on V36+ there is a MEMF_24BITDMA
     * attribute for memory a Zorro II bus master can reach. We correctly
     * omit it, because $08000000 is not 24-bit reachable. On V34 the flag
     * does not exist at all and there is nothing a driver can test, which
     * is exactly why TURBO_PRI is negative -- keeping 24-bit-safe memory
     * at the front of the free list is the only protection 1.3 offers. */
    if (sysbase->LibNode.lib_Version < 33)
        return TURBOMEM_BAD_VERSION;

    for (i = 0; i < NPROBES; i++) {
        p  = (volatile ULONG *)(TURBO_BASE + probe_offsets[i]);
        *p = PATTERN(probe_offsets[i]);
    }

    for (i = 0; i < NPROBES; i++) {
        p = (volatile ULONG *)(TURBO_BASE + probe_offsets[i]);
        if (*p != PATTERN(probe_offsets[i]))
            return i + 1;
    }

    /* AddMemList STORES THE NAME POINTER, it does not copy the string.
     *
     * CLI build: the string lives in the program's own .rodata, which DOS
     * frees when the program exits, leaving the MemHeader's ln_Name
     * dangling. yKick's AddMem allocates a copy for exactly this reason,
     * so we do too, and deliberately never free it -- exec owns it now.
     *
     * ROM build: expansion.library copies the image to RAM and keeps it
     * for the life of the machine, so the literal is already permanent.
     * Allocating would be pointless, and worse, it would put an AllocMem
     * call inside DiagPoint -- a library call during expansion.library's
     * own configuration walk, which is not somewhere to be doing
     * unnecessary work. */
#ifdef TURBOMEM_CLI
    {
        UBYTE *heap = (UBYTE *)call_AllocMem(sysbase, sizeof(TURBO_NAME),
                                             MEMF_PUBLIC | MEMF_CLEAR);
        ULONG k;
        CONST_STRPTR use = (CONST_STRPTR)TURBO_NAME;

        if (heap) {
            for (k = 0; k < sizeof(TURBO_NAME); k++)
                heap[k] = (UBYTE)TURBO_NAME[k];
            use = (CONST_STRPTR)heap;
        }

        call_AddMemList(sysbase, TURBO_SIZE, MEMF_FAST | MEMF_PUBLIC,
                        TURBO_PRI, (APTR)TURBO_BASE, use);
    }
#else
    call_AddMemList(sysbase, TURBO_SIZE, MEMF_FAST | MEMF_PUBLIC,
                    TURBO_PRI, (APTR)TURBO_BASE,
                    (CONST_STRPTR)TURBO_NAME);
#endif

    return 0;
}

/* ==================================================================== */
/* ROM build: DiagArea header + DiagPoint                               */
/* ==================================================================== */
#ifndef TURBOMEM_CLI

#include <libraries/configregs.h>

/* Set 1 for bring-up: DiagPoint returns without touching anything, which
 * proves the FPGA ROM window and the autoconfig entry in isolation. Set 0
 * once the board enumerates and DiagPoint is demonstrably reached. */
/* DIAG_TRACE -- bring-up only, off by default.
 *
 * DiagPoint runs long before dos.library exists, so there is nowhere to
 * print. The background colour is the only channel available this early,
 * and it is the classic one. Each colour is held by a busy loop because
 * the OS overwrites COLOR00 as soon as the boot screen appears, and a
 * single-frame flash is not something you can reliably catch.
 *
 * The point is to separate failures that look identical from the outside:
 *
 *   no colour at all  DiagPoint was never called. The problem is the copy
 *                     gate, the ROM window, or autoconfig -- not this code.
 *   red then green    called, probed, AddMemList done. Working.
 *   red then blue     called, but exec is older than V33.
 *   red then white    called, but a probe read back wrong. The window at
 *                     $08000000 is the suspect, not the ROM path.
 *
 * One build answers "was it called" and "did it work", instead of two.
 */
#ifndef DIAG_TRACE
#define DIAG_TRACE 0
#endif

/* How long each colour is held. This has to be long enough to catch by eye
 * on a machine you are not filming: DiagPoint runs during expansion
 * configuration, so the colours appear in the second or two before the boot
 * screen, and if you are not already staring at the monitor you will miss a
 * flash. Roughly 3 seconds per colour at 7 MHz, less on a turbo. Bring-up
 * only -- it delays every boot by twice this. */
#ifndef DIAG_TRACE_LOOPS
#define DIAG_TRACE_LOOPS 1500000UL
#endif

/* DIAG_MAPROM -- shadow Kickstart into SDRAM at DiagPoint time.
 *
 * Kickstart answers at 7 MHz with a wait state while the core runs at
 * 42.5 MHz, and most of what the OS executes is ROM code. Copying it into
 * the SDRAM shadow and serving it on-chip measures about 2x on word reads
 * and 4x on multiple reads.
 *
 * Doing it here rather than from a CLI tool means it is in effect before
 * DOS, with nothing for the user to run. Unlike a mapROM that loads a
 * DIFFERENT Kickstart, no second reset is needed: the shadow holds the same
 * bytes as the ROM it replaces, verified by checksum, so nothing the system
 * has already built from ROM becomes stale.
 *
 * Off by default. Build with DIAG_MAPROM=1. Keeping it a build flag is the
 * rollback: if mapROM ever turns out to upset something, a ROM image without
 * it is one make away, which matters because a machine that will not boot
 * cannot run MapROM OFF.
 */
#ifndef DIAG_MAPROM
#define DIAG_MAPROM 0
#endif

#ifndef DIAG_STUB
#define DIAG_STUB 0
#endif

/* The header MUST be at offset 0 -- the autoconfig ROM vector points at
 * it. It goes
 * in .text.entry, which turbomem.ld places ahead of everything else; the
 * same mechanism that puts _start first in the CLI build.
 *
 * FIELD NOTES
 *
 *   da_Config MUST HAVE A BOOT-TIME BIT SET OR NOTHING HAPPENS. This was
 *   a real bug in the first version: DAC_WORDWIDE on its own leaves the
 *   boot-time field at DAC_NEVER, and expansion.library tests that field
 *   BEFORE it will copy anything. No copy means no DiagPoint call, ever.
 *   The board still enumerates and still appears in ShowConfig, so the
 *   failure is invisible until you check whether DiagPoint actually ran.
 *   DAC_CONFIGTIME it is.
 *
 *   da_BootPoint MUST BE NON-ZERO for the same reason. RKM Libraries,
 *   "Events At DIAG Time": "Note that the da_BootPoint offset must be
 *   non-NULL, or else no copy will occur." Hence diag_boot below.
 *
 *   diag_boot is never reached in practice. BootPoint is only called
 *   through a BootNode on eb_MountList, and nothing here creates one, so
 *   the stub exists purely to satisfy that test. It returns 0 rather than
 *   falling through into whatever the linker puts after it.
 *
 *   er_InitDiagVec is a BYTE offset from the board base. The note that
 *   used to be here said word offset, on the strength of a comment in
 *   Commodore's own libraries/configregs.i. That comment is wrong, and
 *   Commodore's own documentation contradicts it three ways:
 *
 *     - RKM Libraries worked example: er_InitDiagVec reads $0080 and the
 *       DiagArea hex dump is shown at board offset $0080.
 *     - The RKM sample source codes it as (DiagStart-RomStart), a plain
 *       byte difference, and asserts the block ahead of it is exactly
 *       $80 BYTES: "IFNE *-RomStart-$80 / FAIL".
 *     - UAE's expansion.c writes $1000 and memcpy()s its DiagArea to
 *       expamem + 0x1000. That bootrom works on Kickstart 1.3 upwards.
 *
 *   turbomem_zii.v sidesteps the argument by serving this image at board
 *   offset 0 and advertising a vector of $0000, which resolves to the
 *   same address under either reading. Nothing here depends on winning
 *   it -- but the SD card entry will, so do not carry the word-offset
 *   claim across to it.
 *
 *   da_Size is rounded up to a whole word by turbomem.ld. The copy is
 *   wordwise, and an odd da_Size invites a (size >> 1) loop to drop the
 *   final byte -- which in this image is the NUL terminating the name
 *   string exec keeps a pointer to forever. One pad byte removes the
 *   question. The configregs.h note about size being "the size of the
 *   actual information, not how much address space is required to store
 *   it" is about NIBBLEWIDE and BYTEWIDE ROMs, where the information is
 *   spread over 4x or 2x the address space. It is not an argument
 *   against word alignment.
 *
 *   DAC_BYTEWIDE carries "BUG: Will not work under V34 Kickstart!" in the
 *   header, and V34 is 1.3. DAC_WORDWIDE it is.
 *
 * __rom_end comes from the linker script and equals the image size,
 * because the script starts at 0. */
asm(
"       .section .text.entry,\"ax\"\n"
"       .globl  diag_area\n"
"diag_area:\n"
"       .byte   0x90\n"                     /* da_Config: DAC_WORDWIDE  */
                                            /*          | DAC_CONFIGTIME*/
"       .byte   0\n"                        /* da_Flags                 */
"       .word   __rom_end\n"                /* da_Size                  */
"       .word   diag_point - diag_area\n"   /* da_DiagPoint             */
"       .word   diag_boot  - diag_area\n"   /* da_BootPoint             */
"       .word   diag_name  - diag_area\n"   /* da_Name                  */
"       .word   0\n"                        /* da_Reserved01            */
"       .word   0\n"                        /* da_Reserved02            */
/* Raw opcodes rather than mnemonics. This is a top-level basic asm(), so
 * GCC passes the text through untouched, and spelling the two
 * instructions as data keeps the block free of any question about whether
 * this assembler wants "moveq #0,d0" or "moveq #0,%d0". Four bytes. */
"diag_boot:\n"
"       .word   0x7000\n"                   /* moveq #0,d0              */
"       .word   0x4e75\n"                   /* rts                      */
"       .even\n"
"       .text\n"
"diag_name:\n"
"       .asciz  \"turbo memory\"\n"
"       .even\n"
);

/* Calling convention, verbatim from configregs.h:
 *
 *   A7  at least 2K of stack
 *   A6  ExecBase
 *   A5  ExpansionBase
 *   A3  your board's ConfigDev
 *   A2  base of the diag/init area that was copied
 *   A0  base of your board
 *
 * SysBase is read from address 4 rather than taken from A6: the build
 * uses -ffixed-a6, so binding a parameter to it is asking for trouble,
 * and address 4 is authoritative anyway.
 *
 * RETURN VALUE IS NOT A SUCCESS FLAG, AND IT MUST NEVER BE ZERO. Per the
 * header, returning NULL tells expansion.library to hand the copied area
 * back to the free memory pool.
 *
 * The note that used to be here reasoned that nothing needed to persist
 * after the call, so zero would be tidier. That is wrong, and the reason
 * is two screens up in this same file: AddMemList STORES the name
 * pointer, it does not copy the string. In the ROM build that pointer is
 * -mpcrel relative, so it points into THIS COPY. Return zero and exec's
 * memory list is left with ln_Name dangling into reclaimed memory, which
 * every tool that prints the list -- Avail, AmigaTestKit, dump_memlist
 * below -- will then walk.
 *
 * So: non-zero, permanently. Not just during bring-up. The copy is ~200
 * bytes and exec owns it for the life of the machine, exactly as it owns
 * the AllocMem'd copy the CLI build makes. */
/* No forward declaration: a register parameter is only allowed on a
 * definition, and nothing in C calls this -- expansion.library reaches it
 * through the da_DiagPoint offset in the asm block above. */

#if DIAG_MAPROM && !DIAG_STUB

/* The status window in this board's own address space. */
#define MR_MAGIC_OFS  0xF000
#define MR_CTRL_OFS   0xF008
#define MR_MAGIC      0x544D

/* Writes need $5A in the high byte or the gateware ignores them. */
#define MR_OFF        0x5A00
#define MR_LOAD       0x5A01
#define MR_ACTIVE     0x5A02

#define MR_BOOT_BASE  0x00F80000UL
#define MR_EXT_BASE   0x00E00000UL
#define MR_BANK_SIZE  0x00080000UL      /* 512 KB per bank */

/* Order dependent on purpose. A plain sum would not notice a copy that
 * landed in the wrong order, which is exactly the address-mapping mistake
 * this is here to catch. */
static ULONG mr_sum(ULONG base)
{
    volatile ULONG *p = (volatile ULONG *)base;
    ULONG i, s = 0;

    for (i = 0; i < MR_BANK_SIZE / 4; i++)
        s = ((s << 1) | (s >> 31)) + p[i];
    return s;
}

/* With LOAD set and ACTIVE clear the same address does different things for
 * read and write: the read goes to the motherboard ROM, the write lands in
 * the shadow. So the copy needs no second window. */
static void mr_copy(ULONG base)
{
    volatile ULONG *src = (volatile ULONG *)base;
    ULONG          *dst = (ULONG *)base;
    ULONG i;

    for (i = 0; i < MR_BANK_SIZE / 4; i++)
        dst[i] = src[i];
}

/* BOTH BANKS ARE ALWAYS COPIED, VERBATIM, WITH NO INSPECTION.
 *
 * There is one ACTIVE bit covering both ranges, so a bank that is skipped is
 * still redirected - to shadow nobody filled. On a 1 MB Kickstart that is
 * live code and the CPU executes noise. Copying whatever the motherboard
 * returns, whether that is real ROM or an alias of the other bank because
 * the chip has no A19 to tell them apart, means switching over cannot change
 * what the machine sees.
 *
 * Returns 1 if mapROM is left active.
 */
static int maprom_fill(APTR board, struct ExecBase *sysbase)
{
    volatile UWORD *magic = (volatile UWORD *)((UBYTE *)board + MR_MAGIC_OFS);
    volatile UWORD *ctrl  = (volatile UWORD *)((UBYTE *)board + MR_CTRL_OFS);
    ULONG boot_sum, ext_sum;
    int   ok;

    /* Gateware without the mapROM window reads as ROM here, not as $544D. */
    if (*magic != MR_MAGIC)
        return 0;

    boot_sum = mr_sum(MR_BOOT_BASE);
    ext_sum  = mr_sum(MR_EXT_BASE);

    *ctrl = MR_LOAD;
    mr_copy(MR_BOOT_BASE);
    mr_copy(MR_EXT_BASE);
    *ctrl = MR_OFF;                     /* close the write window again */

    /* From the moment ACTIVE is set until it is cleared again, every ROM
     * fetch comes from the shadow -- including any interrupt handler that
     * happens to fire. So: interrupts off, and call NOTHING that lives in
     * ROM until we have decided.
     *
     * call_Enable is a ROM call, but by then either the shadow verified
     * (so it is safe to run from) or ACTIVE is already back off (so it
     * comes from the motherboard as before). Either way it is reached. */
    call_Disable(sysbase);

    *ctrl = MR_ACTIVE;

    ok = (mr_sum(MR_BOOT_BASE) == boot_sum) &&
         (mr_sum(MR_EXT_BASE)  == ext_sum);

    if (!ok)
        *ctrl = MR_OFF;

    call_Enable(sysbase);
    return ok;
}
#endif /* DIAG_MAPROM && !DIAG_STUB */

#if DIAG_TRACE && !DIAG_STUB
static void diag_flash(UWORD colour)
{
    volatile UWORD *color00 = (volatile UWORD *)0xDFF180UL;
    volatile ULONG  i;

    *color00 = colour;
    for (i = 0; i < DIAG_TRACE_LOOPS; i++) { }
}
#endif

ULONG diag_point(APTR board asm("a0"))
{
#if DIAG_STUB
    (void)board;
    return 1;
#else
    struct ExecBase *sysbase;

    asm volatile ("move.l 4.w,%0" : "=r"(sysbase));

#if DIAG_TRACE
    {
        ULONG rc;

        diag_flash(0x0F00);                 /* red   -- we got called      */
        rc = turbomem_add(sysbase);
        diag_flash(rc == 0                   ? 0x00F0   /* green -- added   */
                 : rc == TURBOMEM_BAD_VERSION ? 0x000F   /* blue  -- old exec*/
                                              : 0x0FFF); /* white -- probe   */
    }
#else
    /* Ignore the result. There is nowhere to report a failed probe from
     * here, and adding nothing is the correct outcome either way. */
    (void)turbomem_add(sysbase);
#endif

#if DIAG_MAPROM
    /* AFTER turbomem_add, deliberately. The memory is the proven feature;
     * if mapROM ever misbehaves, having the fast RAM already added narrows
     * the fault to this call rather than to both. There is nowhere to
     * report a failure from here either, but a shadow that does not verify
     * simply leaves mapROM off and the machine boots as before -- and
     * cfgdump can read the control register afterwards to say which. */
    (void)maprom_fill(board, sysbase);
#endif

    return 1;
#endif
}

#endif /* !TURBOMEM_CLI */

/* ------------------------------------------------------------------ */
/* CLI harness. Everything below is excluded from the ROM build.      */
/* ------------------------------------------------------------------ */
#ifdef TURBOMEM_CLI

struct ExecBase   *SysBase;
struct DosLibrary *DOSBase;

/* Printf and PutStr are V36+. RawDoFmt is V33, so formatting goes through
 * that instead -- the same approach as debug.c's KPrintF, except the
 * callback fills a buffer rather than driving the serial port, so the
 * result can reach the console via Write().
 *
 * Exec calls the callback with the byte in d0 and our user data in a3,
 * hence the register pinning. RawDoFmt terminates the stream with a NUL
 * of its own, which is why the length below subtracts one. */
static void putch(UBYTE c    asm("d0"),
                  APTR  data asm("a3"))
{
    char **pp = (char **)data;
    *(*pp)++ = (char)c;
}

static void cprintf(CONST_STRPTR fmt, ...)
{
    char    buf[160];
    char   *p = buf;
    LONG    n;
    va_list ap;

    va_start(ap, fmt);
    RawDoFmt((CONST_STRPTR)fmt, ap, (void (*)())putch, &p);
    va_end(ap);

    n = (LONG)(p - buf) - 1;
    if (n > 0)
        Write(Output(), (CONST_APTR)buf, n);
}

/* MUST be the first thing in .text -- elf2hunk enters at the start of the
 * first code hunk regardless of ENTRY(). turbomem.ld places .text.entry
 * ahead of everything else; without it the compiler emitted putch first
 * and DOS jumped straight into the RawDoFmt callback with garbage
 * registers, which cost a Guru 81000005 (AN_MemCorrupt). Verify with
 * "make check-entry" after any change here. */
/* Walk SysBase->MemList and print every region. AddMemList returns void,
 * so this is the only way to tell whether it actually took -- rather than
 * inferring from the absence of a crash. Pure structure access, no
 * library calls, nothing poisoned. */
static void dump_memlist(struct ExecBase *sysbase)
{
    struct MemHeader *mh;
    ULONG n = 0;

    cprintf((CONST_STRPTR)"  lower     upper     free      attr pri name\n");

    for (mh = (struct MemHeader *)sysbase->MemList.lh_Head;
         mh->mh_Node.ln_Succ != NULL;
         mh = (struct MemHeader *)mh->mh_Node.ln_Succ)
    {
        CONST_STRPTR nm = (CONST_STRPTR)mh->mh_Node.ln_Name;

        /* ln_Name is allowed to be NULL, and RawDoFmt's %s would follow
         * it straight into address zero. */
        if (!nm) nm = (CONST_STRPTR)"(none)";

        cprintf((CONST_STRPTR)"  $%08lx $%08lx $%08lx %4lx %3ld %s\n",
                (ULONG)mh->mh_Lower,
                (ULONG)mh->mh_Upper,
                (ULONG)mh->mh_Free,
                (ULONG)mh->mh_Attributes,
                (LONG)mh->mh_Node.ln_Pri,
                nm);
        n++;
    }

    cprintf((CONST_STRPTR)"  %ld region(s)\n", n);
}

int _start(void) __attribute__((section(".text.entry")));

int _start(void)
{
    ULONG failed, ver;

    /* Absolute address 4, in asm because GCC 15 reports any dereference
     * near zero as a null-pointer access whatever volatile says. Also
     * guarantees absolute-SHORT, which needs no relocation entry. */
    asm volatile ("move.l 4.w,%0" : "=r"(SysBase));

    DOSBase = (struct DosLibrary *)
        OpenLibrary((CONST_STRPTR)"dos.library", 0);
    if (!DOSBase)
        return 20;

    ver = SysBase->LibNode.lib_Version;
    cprintf((CONST_STRPTR)"probing $%08lx ... ", TURBO_BASE);

    failed = turbomem_add(SysBase);

    if (failed == TURBOMEM_BAD_VERSION) {
        cprintf((CONST_STRPTR)
                "\nexec V%ld is too old - AddMemList needs V33\n", ver);
        CloseLibrary((struct Library *)DOSBase);
        return 20;
    }

    if (failed) {
        ULONG off = probe_offsets[failed - 1];
        cprintf((CONST_STRPTR)
                "\nFAILED at $%08lx (probe %ld of %ld) - NOT added\n",
                TURBO_BASE + off, failed, (ULONG)NPROBES);
        if (off == 0x00800000UL)
            cprintf((CONST_STRPTR)
                    "that is where an 8 MB window aliases back to zero - "
                    "check the decode width\n");
        CloseLibrary((struct Library *)DOSBase);
        return 20;
    }

    cprintf((CONST_STRPTR)"ok\nadded %ld MB at $%08lx, pri %ld, exec V%ld\n",
            TURBO_SIZE >> 20, TURBO_BASE, (LONG)TURBO_PRI, ver);

    /* Read the list back rather than trusting the call. A region at
     * $08000000 here means AddMemList worked and anything AddMem ? shows
     * is a separate question; no region means it was rejected, and the
     * arguments in the disassembly are the next place to look. */
    cprintf((CONST_STRPTR)"\nexec memory list:\n");
    dump_memlist(SysBase);

    CloseLibrary((struct Library *)DOSBase);
    return 0;
}

#endif /* TURBOMEM_CLI */
