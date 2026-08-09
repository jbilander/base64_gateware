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
/* proto/expansion.h already declares this as struct ExpansionBase *, so the
 * definition has to match or GCC reports conflicting types. OpenLibrary
 * returns struct Library *, hence the cast at the call. */
struct ExpansionBase *ExpansionBase;

/* A MACRO, not a function, and deliberately so.
 *
 * GCC at -O2 recognises a counting loop as strlen and emits a call to it.
 * This toolchain is -nostdlib, so there is nothing to link that against, and
 * writing strlen ourselves does not help -- the same loop idiom inside it
 * would be turned into a recursive call to itself. Every use here is a string
 * literal, so take the length at compile time and the problem cannot arise.
 *
 * The cost is that it must ONLY ever be given a literal. Handing it a char *
 * would silently measure the pointer instead of the string. Where a runtime
 * length is genuinely needed, call Write() directly, as dump_diagarea does
 * for the board name. */
#define put_lit(s) Write(Output(), (CONST_APTR)(s), (LONG)(sizeof(s) - 1))

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

/* Read a word from a POSSIBLY ODD address, as two byte accesses.
 *
 * A UWORD access at an odd address is an address error on a 68000, and the
 * SD card board advertises er_InitDiagVec = $0001 -- odd on purpose, because
 * its diag area is byte-wide on the low data lane. The first version of this
 * tool read a word there and took exactly the Software Error you would
 * expect. Never dereference a board window at an alignment you have not
 * checked. */
static UWORD rdw(volatile UBYTE *p)
{
    return (UWORD)(((UWORD)p[0] << 8) | (UWORD)p[1]);
}

/* The DiagArea header, read back through the board window. Laid out by
 * hand rather than using struct DiagArea so the field offsets are visible
 * at the point of use -- this is the structure under investigation.
 *
 * shift 0  word-wide: the information is contiguous.
 * shift 1  byte-wide on the LOW lane: information byte n lives at address
 *          offset 2n. An ODD er_InitDiagVec is what tells you so. */
static void dump_diagarea(volatile UBYTE *p, ULONG span, UBYTE shift)
{
    UBYTE  cfg   = p[0];
    UBYTE  flags = p[1 << shift];
    UWORD  size  = (UWORD)((p[2 << shift] << 8) | p[3 << shift]);
    UWORD  diag  = (UWORD)((p[4 << shift] << 8) | p[5 << shift]);
    UWORD  boot  = (UWORD)((p[6 << shift] << 8) | p[7 << shift]);
    UWORD  name  = (UWORD)((p[8 << shift] << 8) | p[9 << shift]);

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
    if (shift) put_lit("    (byte-wide: fields read with stride 2)\n");

    cprintf((CONST_STRPTR)"    da_Name      %ld  \"",  (ULONG)name);
    if (name && name < size && ((ULONG)size << shift) <= span) {
        char  tmp[80];
        ULONG k = 0;
        while (k < 79 && (name + k) < size && p[(name + k) << shift]) {
            tmp[k] = (char)p[(name + k) << shift];
            k++;
        }
        if (k) Write(Output(), (CONST_APTR)tmp, (LONG)k);
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

    ExpansionBase = (struct ExpansionBase *)
        OpenLibrary((CONST_STRPTR)"expansion.library", 0);
    if (!ExpansionBase) {
        put_lit("cannot open expansion.library\n");
        CloseLibrary((struct Library *)DOSBase);
        return 20;
    }

    while ((cd = FindConfigDev(cd, -1, -1)) != NULL) {
        UBYTE  type = cd->cd_Rom.er_Type;
        UWORD  vec  = cd->cd_Rom.er_InitDiagVec;
        volatile UBYTE *base = (volatile UBYTE *)cd->cd_BoardAddr;
        UBYTE  shift = (UBYTE)((vec & 1) ? 1 : 0);

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
                (ULONG)rdw(base + 0), (ULONG)rdw(base + 2));
        cprintf((CONST_STRPTR)"  window +$%04lx: %04lx %04lx\n", (ULONG)vec,
                (ULONG)rdw(base + vec), (ULONG)rdw(base + vec + 2));

        put_lit("  DiagArea at cd_BoardAddr + er_InitDiagVec:\n");
        dump_diagarea(base + vec, (ULONG)cd->cd_BoardSize - vec, shift);

        /* Boot statistics, if this board publishes them. The magic is what
         * distinguishes a real status window from ROM mirrored into the top
         * of the window, so check it before believing anything else. */
        {
            volatile UBYTE *st = base + 0xF000;
            if (rdw(st) == 0x544D) {
                UWORD fl = rdw(st + 2);
                put_lit("  boot statistics:\n");
                cprintf((CONST_STRPTR)"    resets needed  %ld\n",
                        (ULONG)rdw(st + 4));
                cprintf((CONST_STRPTR)"    booted at      %ld ms after the "
                                     "power-up hold\n", (ULONG)rdw(st + 6));
                cprintf((CONST_STRPTR)"    phase slip     %s\n",
                        (CONST_STRPTR)((fl & 0x0004) ? "YES - the 7M phase "
                                       "aligner re-acquired" : "no"));
                cprintf((CONST_STRPTR)"    boot_ok        %s\n",
                        (CONST_STRPTR)((fl & 0x0002) ? "yes" : "no"));
                cprintf((CONST_STRPTR)"    core halted    %s\n",
                        (CONST_STRPTR)((fl & 0x0001) ? "YES" : "no"));
                cprintf((CONST_STRPTR)"    passive        %s\n",
                        (CONST_STRPTR)((fl & 0x0008) ? "YES - another master "
                                       "holds /BR, we are off the bus"
                                     : "no"));
            }
        }
    }

    if (!n)
        put_lit("no autoconfig boards found\n");

    CloseLibrary((struct Library *)ExpansionBase);
    CloseLibrary((struct Library *)DOSBase);
    return 0;
}
