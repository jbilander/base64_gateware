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

/* AllocMem is exec LVO -198, V33, not poisoned. Same explicit-register
 * form as call_AddMemList and for the same reason. */
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
     * Point it at our own .rodata and the MemHeader's ln_Name dangles the
     * moment this program exits and DOS frees its segments -- which is
     * why yKick's AddMem allocates a copy before calling. Same here: this
     * block is deliberately never freed, because exec now owns it.
     *
     * In the ROM build the image is copied to RAM by expansion.library and
     * kept for the life of the machine, so the literal would be safe
     * there -- but doing it the same way in both keeps one code path. */
    {
        static const char nm[] = "turbo memory";
        UBYTE *heap = (UBYTE *)call_AllocMem(sysbase, sizeof(nm),
                                             MEMF_PUBLIC | MEMF_CLEAR);
        ULONG k;
        CONST_STRPTR use = (CONST_STRPTR)nm;

        if (heap) {
            for (k = 0; k < sizeof(nm); k++)
                heap[k] = (UBYTE)nm[k];
            use = (CONST_STRPTR)heap;
        }

        call_AddMemList(sysbase,
                        TURBO_SIZE,
                        MEMF_FAST | MEMF_PUBLIC,
                        TURBO_PRI,
                        (APTR)TURBO_BASE,
                        use);
    }

    return 0;
}

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
