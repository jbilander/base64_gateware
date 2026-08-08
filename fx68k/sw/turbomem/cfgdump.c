/* cfgdump.c -- print what expansion.library actually recorded for every
 * autoconfig board, and read the DiagArea back through the board window.
 *
 * This exists because "the board enumerates but DiagPoint never runs" has
 * several causes that look identical from the outside, and an FPGA rebuild
 * costs far more than a CLI run. It answers, in one go:
 *
 *   - Did exec record ERTF_DIAGVALID? If not, the er_Type nibbles are wrong
 *     and nothing downstream matters.
 *   - What er_InitDiagVec did it read back? This is the number that decides
 *     where -- and whether -- expansion.library goes looking. If the FPGA
 *     says $2000 and this prints $2000, the nibble encoding is proven and
 *     the fault is in the copy, not the wiring.
 *   - Does the window actually serve the DiagArea at that offset? It reads
 *     cd_BoardAddr + er_InitDiagVec directly and decodes the header, so a
 *     stale or empty ROM shows up as $0000 or the wrong da_Size instead of
 *     being invisible.
 *
 * Reading the board window from the CLI is safe here: it is a plain ROM
 * with no side effects, and reads at the assigned base are exactly what
 * expansion.library would do.
 *
 * NOT COMPILE-TESTED -- there is no m68k-amiga-elf toolchain on the machine
 * this was written on. It follows hello.c's structure exactly, which does
 * build, but treat the first compile as part of the experiment.
 *
 * Build:  make cfgdump
 */

#include <exec/types.h>
#include <exec/execbase.h>
#include <libraries/configvars.h>
#include <libraries/configregs.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/expansion.h>
#include <stdarg.h>
#include <ks13_compat.h>

struct ExecBase   *SysBase;
struct DosLibrary *DOSBase;
struct Library    *ExpansionBase;

static void put_lit(const char *s)
{
    ULONG n = 0;
    while (s[n]) n++;
    if (n) Write(Output(), (CONST_APTR)s, (LONG)n);
}

static void putch(UBYTE c asm("d0"), APTR data asm("a3"))
{
    char **pp = (char **)data;
    *(*pp)++ = (char)c;
}

static void cprintf(CONST_STRPTR fmt, ...)
{
    char    buf[200];
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

/* The DiagArea header, read back through the board window. Laid out by
 * hand rather than using struct DiagArea so the field offsets are visible
 * at the point of use -- this is the structure under investigation. */
static void dump_diagarea(UBYTE *p, ULONG size_limit)
{
    UBYTE  cfg   = p[0];
    UBYTE  flags = p[1];
    UWORD  size  = (UWORD)((p[2] << 8) | p[3]);
    UWORD  diag  = (UWORD)((p[4] << 8) | p[5]);
    UWORD  boot  = (UWORD)((p[6] << 8) | p[7]);
    UWORD  name  = (UWORD)((p[8] << 8) | p[9]);
    ULONG  i;

    cprintf((CONST_STRPTR)"    da_Config    $%02lx  ", (ULONG)cfg);
    switch (cfg & 0xC0) {
        case 0x80: put_lit("WORDWIDE"); break;
        case 0x40: put_lit("BYTEWIDE (broken on KS 1.3!)"); break;
        case 0x00: put_lit("NIBBLEWIDE"); break;
        default:   put_lit("bad buswidth"); break;
    }
    switch (cfg & 0x30) {
        case 0x10: put_lit(" + CONFIGTIME\n"); break;
        case 0x20: put_lit(" + BINDTIME\n");   break;
        case 0x00: put_lit(" + NEVER  <-- nothing will be copied\n"); break;
        default:   put_lit(" + bad boottime\n"); break;
    }
    cprintf((CONST_STRPTR)"    da_Flags     $%02lx\n", (ULONG)flags);
    cprintf((CONST_STRPTR)"    da_Size      %ld\n",    (ULONG)size);
    cprintf((CONST_STRPTR)"    da_DiagPoint %ld\n",    (ULONG)diag);
    cprintf((CONST_STRPTR)"    da_BootPoint %ld%s\n",  (ULONG)boot,
            (CONST_STRPTR)(boot ? "" : "   <-- zero, nothing will be copied"));
    cprintf((CONST_STRPTR)"    da_Name      %ld  \"",  (ULONG)name);
    if (name && name < size && size <= size_limit) {
        for (i = name; i < size && p[i]; i++)
            cprintf((CONST_STRPTR)"%lc", (ULONG)p[i]);
    }
    put_lit("\"\n");
}

int _start(void) __attribute__((section(".text.entry")));

int _start(void)
{
    struct ConfigDev *cd = NULL;
    ULONG n = 0;

    asm volatile ("move.l 4.w,%0" : "=r"(SysBase));

    DOSBase = (struct DosLibrary *)
        OpenLibrary((CONST_STRPTR)"dos.library", 0);
    if (!DOSBase)
        return 20;

    ExpansionBase = OpenLibrary((CONST_STRPTR)"expansion.library", 0);
    if (!ExpansionBase) {
        put_lit("cannot open expansion.library\n");
        CloseLibrary((struct Library *)DOSBase);
        return 20;
    }

    while ((cd = FindConfigDev(cd, -1, -1)) != NULL) {
        UBYTE  type = cd->cd_Rom.er_Type;
        UWORD  vec  = cd->cd_Rom.er_InitDiagVec;
        UBYTE *base = (UBYTE *)cd->cd_BoardAddr;

        n++;
        put_lit("\n");
        cprintf((CONST_STRPTR)"board %ld: mfg %ld product %ld\n",
                n, (ULONG)cd->cd_Rom.er_Manufacturer,
                (ULONG)cd->cd_Rom.er_Product);
        cprintf((CONST_STRPTR)"  addr $%08lx  size $%08lx\n",
                (ULONG)base, (ULONG)cd->cd_BoardSize);
        cprintf((CONST_STRPTR)"  er_Type $%02lx  %s%s%s\n",
                (ULONG)type,
                (CONST_STRPTR)((type & 0xC0) == 0xC0 ? "ZorroII " : "ZorroIII/other "),
                (CONST_STRPTR)((type & ERTF_MEMLIST)   ? "MEMLIST "   : ""),
                (CONST_STRPTR)((type & ERTF_DIAGVALID) ? "DIAGVALID" : "no-diag"));
        cprintf((CONST_STRPTR)"  er_InitDiagVec $%04lx%s\n", (ULONG)vec,
                (CONST_STRPTR)(vec ? "" : "   <-- zero: never followed"));

        if (!(type & ERTF_DIAGVALID))
            continue;

        /* First two words straight off the window, so an empty or stale ROM
         * is visible as data rather than as an absence of behaviour. */
        cprintf((CONST_STRPTR)"  window +$0000: %04lx %04lx\n",
                (ULONG)*(volatile UWORD *)(base + 0),
                (ULONG)*(volatile UWORD *)(base + 2));
        cprintf((CONST_STRPTR)"  window +$%04lx: %04lx %04lx\n", (ULONG)vec,
                (ULONG)*(volatile UWORD *)(base + vec),
                (ULONG)*(volatile UWORD *)(base + vec + 2));

        put_lit("  DiagArea at cd_BoardAddr + er_InitDiagVec:\n");
        dump_diagarea(base + vec, (ULONG)cd->cd_BoardSize - vec);
    }

    if (!n)
        put_lit("no autoconfig boards found\n");

    CloseLibrary(ExpansionBase);
    CloseLibrary((struct Library *)DOSBase);
    return 0;
}
