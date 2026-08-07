/* hello.c -- the smallest thing that can print, to find out which layer
 * is broken.
 *
 * Three confident diagnoses in a row have now failed to explain why
 * TestAddTurboMem produces no output. Rather than a fourth theory, this
 * strips everything back and adds one piece at a time.
 *
 *   make hello STAGE=1   OpenLibrary + Write of a literal.
 *                        No varargs, no RawDoFmt, no callback, no probe.
 *
 *   make hello STAGE=2   adds the RawDoFmt/putch formatting path.
 *
 *   make hello STAGE=3   adds the probe loop against $08000000,
 *                        reporting but NOT calling AddMemList.
 *
 * Whichever stage stops printing is the one that is broken, and every
 * stage below it is proven. That is worth more than another guess.
 *
 * Build:  make hello STAGE=1   (then 2, then 3)
 */

#include <exec/types.h>
#include <exec/memory.h>
#include <exec/execbase.h>
#include <proto/exec.h>
#include <proto/dos.h>
#if STAGE >= 2
#include <stdarg.h>
#endif
#include <ks13_compat.h>

struct ExecBase   *SysBase;
struct DosLibrary *DOSBase;

static void put_lit(const char *s)
{
    ULONG n = 0;
    while (s[n]) n++;
    if (n) Write(Output(), (CONST_APTR)s, (LONG)n);
}

#if STAGE >= 2
static void putch(UBYTE c asm("d0"), APTR data asm("a3"))
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
#endif

#if STAGE >= 3
#define TURBO_BASE 0x08000000UL
static const ULONG probe_offsets[] = {
    0x00000000UL, 0x00000004UL, 0x00400000UL, 0x00800000UL,
    0x00C00000UL, 0x00FFFFF8UL, 0x00FFFFFCUL
};
#define NPROBES (sizeof(probe_offsets)/sizeof(probe_offsets[0]))
#define PATTERN(off) ((off) ^ 0xA5A5A5A5UL)
#endif

int _start(void) __attribute__((section(".text.entry")));

int _start(void)
{
    asm volatile ("move.l 4.w,%0" : "=r"(SysBase));

    DOSBase = (struct DosLibrary *)
        OpenLibrary((CONST_STRPTR)"dos.library", 0);
    if (!DOSBase)
        return 20;

    /* If this line does not appear, the problem is below all of our own
     * logic: the entry point, elf2hunk, the linker script, or Write
     * itself. Nothing above this point does anything clever. */
    put_lit("stage 1: Write works\n");

#if STAGE >= 2
    cprintf((CONST_STRPTR)"stage 2: RawDoFmt works, exec V%ld, base $%08lx\n",
            (ULONG)SysBase->LibNode.lib_Version, (ULONG)SysBase);
#endif

#if STAGE >= 3
    {
        volatile ULONG *p;
        ULONG i, bad = 0;

        put_lit("stage 3: writing probes ...\n");
        for (i = 0; i < NPROBES; i++) {
            p  = (volatile ULONG *)(TURBO_BASE + probe_offsets[i]);
            *p = PATTERN(probe_offsets[i]);
        }

        put_lit("stage 3: reading back ...\n");
        for (i = 0; i < NPROBES; i++) {
            p = (volatile ULONG *)(TURBO_BASE + probe_offsets[i]);
            cprintf((CONST_STRPTR)"  $%08lx wrote $%08lx read $%08lx %s\n",
                    (ULONG)p,
                    PATTERN(probe_offsets[i]),
                    (ULONG)*p,
                    (CONST_STRPTR)(*p == PATTERN(probe_offsets[i])
                                   ? "ok" : "BAD"));
            if (*p != PATTERN(probe_offsets[i])) bad++;
        }

        cprintf((CONST_STRPTR)"stage 3: %ld of %ld probes bad\n",
                bad, (ULONG)NPROBES);
        put_lit("AddMemList deliberately NOT called\n");
    }
#endif

    CloseLibrary((struct Library *)DOSBase);
    return 0;
}
